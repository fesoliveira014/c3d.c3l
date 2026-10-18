module c3d::physics;

import c3d;
import c3d::maths;
import std::collections::list;
import std::math;
import b3;

const uint BREAKABLE_PAIR_BATCH @local = 1024; // pairs per range; most end at a bounds test, so ranges stay long to amortize one claim; 512 ranges at 1,024 pieces

enum BreakablePairState : uint @local {
    NONE,
    FOUND,
    FAILED,
}

struct BreakablePairSlot @local {
    BreakablePairState state;
    float distance;
    uint first_hull;
    uint second_hull;
}

struct BreakablePairJob @local {
    uint piece_count;
    float gap;
    maths::Transform[] poses;
    uint[] offsets;
    b3::HullData*[] hulls;
    b3::Aabb[] bounds;
    BreakablePairSlot[] slots;
}

fn bool breakable_bounds_near(b3::Aabb first, b3::Aabb second, float gap) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (first.lower_bound[axis] > second.upper_bound[axis] + gap
            || second.lower_bound[axis] > first.upper_bound[axis] + gap) return false;
    }
    return true;
}

fn b3::DistanceOutput? hull_pair_distance(
    b3::HullData* hull_a,
    b3::HullData* hull_b,
    b3::Transform placement,
) @local {
    return b3::shape_distance({
        .proxy_a = {
            .points = (Vec3*)((char*)hull_a + hull_a.point_offset),
            .count = hull_a.vertex_count,
        },
        .proxy_b = {
            .points = (Vec3*)((char*)hull_b + hull_b.point_offset),
            .count = hull_b.vertex_count,
        },
        .transform = placement,
    });
}

fn BreakablePairSlot nearest_hull_pair(BreakablePairJob* job, uint first, uint second) @local {
    BreakablePairSlot nearest;

    for (uint first_hull = job.offsets[first]; first_hull < job.offsets[first + 1]; first_hull++) {
        for (uint second_hull = job.offsets[second]; second_hull < job.offsets[second + 1]; second_hull++) {
            if (!breakable_bounds_near(job.bounds[first_hull], job.bounds[second_hull], job.gap)) continue;

            b3::DistanceOutput? closest = hull_pair_distance(
                job.hulls[first_hull],
                job.hulls[second_hull],
                body_frame(relative_breakable_pose(job.poses[first], job.poses[second])),
            );
            if (catch excuse = closest) {
                // The owner thread evaluates this hull pair again and propagates the same fault.
                return { .state = FAILED, .first_hull = first_hull, .second_hull = second_hull };
            }
            if (closest.distance > job.gap || (nearest.state == FOUND && closest.distance >= nearest.distance)) continue;

            nearest = {
                .state = FOUND,
                .distance = closest.distance,
                .first_hull = first_hull,
                .second_hull = second_hull,
            };
        }
    }
    return nearest;
}

fn ulong breakable_row_start(uint piece_count, uint row) @local {
    return (ulong)row * (2 * (ulong)piece_count - row - 1) / 2;
}

fn uint breakable_pair_row(uint piece_count, uint pair) @local {
    uint low;
    uint high = piece_count - 2;
    while (low < high) {
        uint middle = (low + high + 1) / 2;
        if (breakable_row_start(piece_count, middle) <= pair) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    return low;
}

fn void evaluate_breakable_pairs(void* data, uint first_pair, uint count) @local {
    BreakablePairJob* job = data;

    uint first = breakable_pair_row(job.piece_count, first_pair);
    uint second = first + 1 + (uint)(first_pair - breakable_row_start(job.piece_count, first));
    foreach (&slot : job.slots[first_pair:count]) {
        *slot = nearest_hull_pair(job, first, second);

        second++;
        if (second == job.piece_count) {
            first++;
            second = first + 1;
        }
    }
}

fn Weld[]? build_breakable_graph(
    PhysicsWorld* world,
    maths::Transform[] poses,
    SnapshotHandle[] held,
    uint[] offsets,
    float gap,
) @private {
    sz pair_count = (sz)poses.len * ((sz)poses.len - 1) / 2;
    if (pair_count > uint::max) return c3d::CAPACITY_EXCEEDED~;

    b3::HullData*[] hulls = alloc::new_array(tmem, b3::HullData*, held.len);
    b3::Aabb[] bounds = alloc::new_array(tmem, b3::Aabb, held.len);
    foreach (index, pose : poses) {
        for (uint hull = offsets[index]; hull < offsets[index + 1]; hull++) {
            hulls[hull] = snapshot_of(world.snapshots, held[hull]).hull;
            bounds[hull] = hulls[hull].compute_aabb(body_frame(pose));
        }
    }

    BreakablePairSlot[] slots = alloc::alloc_array_try(tmem, BreakablePairSlot, pair_count) ?? c3d::CAPACITY_EXCEEDED~!;

    BreakablePairJob job = {
        .piece_count = (uint)poses.len,
        .gap = gap,
        .poses = poses,
        .offsets = offsets,
        .hulls = hulls,
        .bounds = bounds,
        .slots = slots,
    };
    if (world.parallel.run) {
        world.parallel.run(
            context: world.parallel.context,
            range:   &evaluate_breakable_pairs,
            data:    &job,
            count:   (uint)pair_count,
            batch:   BREAKABLE_PAIR_BATCH,
        );
    } else {
        evaluate_breakable_pairs(&job, 0, (uint)pair_count);
    }

    List{Weld} edges;
    edges.init(tmem);
    uint pair;
    for (uint first = 0; first < poses.len; first++) {
        for (uint second = first + 1; second < poses.len; second++) {
            BreakablePairSlot slot = slots[pair++];
            if (slot.state == NONE) continue;

            b3::DistanceOutput nearest = hull_pair_distance(
                hulls[slot.first_hull],
                hulls[slot.second_hull],
                body_frame(relative_breakable_pose(poses[first], poses[second])),
            )!;
            Vec3 anchor = (nearest.point_a + nearest.point_b) * 0.5f;
            maths::Transform frame = poses[first];
            frame.position += frame.rotation.rotate_vec3(anchor);
            edges.push({
                .piece_a = first,
                .piece_b = second,
                .anchor = anchor,
                .frame_b = relative_breakable_pose(poses[second], frame),
                .frame_a = { .position = anchor, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
                .moment_axis = { 1, 0, 0 },
            });
        }
    }
    return edges.array_view();
}
