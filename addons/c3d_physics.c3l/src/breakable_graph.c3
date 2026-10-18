module c3d::physics;

import c3d;
import c3d::maths;
import std::atomic;
import std::collections::list;
import std::math;
import std::sort;
import b3;

const uint BREAKABLE_PAIR_BATCH @local = 1024; // pairs per range; amortizes one claim, 512 ranges at 1,024 pieces

struct BreakableEdgeCandidate @local {
    ulong key; // first piece in the high word, second piece in the low word
    float[3] anchor;
    bool failed;
}

$assert BreakableEdgeCandidate::size == 24; // the reserve per piece pair; a Vec3 anchor would make it 32

struct BreakablePairResult @local {
    bool connected;
    b3::DistanceOutput nearest;
}

struct BreakablePairJob @local {
    uint piece_count;
    float gap;
    maths::Transform[] poses;
    uint[] offsets;
    b3::HullData*[] hulls;
    b3::Aabb[] bounds;
    BreakableEdgeCandidate[] candidates;
    uint candidate_count;
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

fn BreakablePairResult? nearest_hull_pair(BreakablePairJob* job, uint first, uint second) @local {
    BreakablePairResult result;

    for (uint first_hull = job.offsets[first]; first_hull < job.offsets[first + 1]; first_hull++) {
        for (uint second_hull = job.offsets[second]; second_hull < job.offsets[second + 1]; second_hull++) {
            if (!breakable_bounds_near(job.bounds[first_hull], job.bounds[second_hull], job.gap)) continue;

            b3::DistanceOutput closest = hull_pair_distance(
                job.hulls[first_hull],
                job.hulls[second_hull],
                body_frame(relative_breakable_pose(job.poses[first], job.poses[second])),
            )!;
            bool rejected = closest.distance > job.gap
                || (result.connected && closest.distance >= result.nearest.distance);
            if (rejected) continue;

            result = { .connected = true, .nearest = closest };
        }
    }
    return result;
}

fn void add_breakable_candidate(
    BreakablePairJob* job,
    uint first,
    uint second,
    Vec3 anchor,
    bool failed,
) @local {
    uint index = atomic::fetch_add(&job.candidate_count, 1u, RELAXED);
    job.candidates[index] = {
        .key = (ulong)first << 32 | second,
        .anchor = { anchor.x, anchor.y, anchor.z },
        .failed = failed,
    };
}

fn bool in_breakable_pair_order(BreakableEdgeCandidate[] candidates) @local {
    for (usz index = 1; index < candidates.len; index++) {
        if (candidates[index - 1].key > candidates[index].key) return false;
    }
    return true;
}

fn int compare_breakable_candidates(BreakableEdgeCandidate first, BreakableEdgeCandidate second) @local {
    if (first.key == second.key) return 0;
    return first.key < second.key ? -1 : 1;
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

fn void evaluate_near_pair(BreakablePairJob* job, uint first, uint second) @local {
    if (try result = nearest_hull_pair(job, first, second)) {
        if (result.connected) {
            add_breakable_candidate(
                job: job,
                first: first,
                second: second,
                anchor: (result.nearest.point_a + result.nearest.point_b) * 0.5f,
                failed: false,
            );
        }
    } else {
        add_breakable_candidate(
            job: job,
            first: first,
            second: second,
            anchor: {},
            failed: true,
        );
    }
}

fn void evaluate_breakable_row(
    BreakablePairJob* job,
    uint first,
    uint second_begin,
    uint second_end,
) @local {
    uint[] offsets = job.offsets;
    b3::Aabb[] bounds = job.bounds;
    float gap = job.gap;
    uint first_begin = offsets[first];
    uint first_end = offsets[first + 1];

    // Most pairs are far apart: this screen keeps them out of the full evaluation.
    for (uint second = second_begin; second < second_end; second++) {
        bool near;
        for (uint first_hull = first_begin; first_hull < first_end && !near; first_hull++) {
            for (uint second_hull = offsets[second]; second_hull < offsets[second + 1]; second_hull++) {
                if (breakable_bounds_near(bounds[first_hull], bounds[second_hull], gap)) {
                    near = true;
                    break;
                }
            }
        }
        if (near) evaluate_near_pair(job, first, second);
    }
}

fn void evaluate_breakable_pairs(void* data, uint first_pair, uint count) @local {
    BreakablePairJob* job = data;

    uint first = breakable_pair_row(job.piece_count, first_pair);
    uint second = first + 1 + (uint)(first_pair - breakable_row_start(job.piece_count, first));
    uint remaining = count;
    while (remaining > 0) {
        uint row_count = math::min(job.piece_count - second, remaining);
        evaluate_breakable_row(
            job: job,
            first: first,
            second_begin: second,
            second_end: second + row_count,
        );

        remaining -= row_count;
        first++;
        second = first + 1;
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

    // One entry per pair is the worst case; only the connected pairs are ever written, so most of it stays untouched.
    BreakableEdgeCandidate[] candidates = alloc::alloc_array_try(tmem, BreakableEdgeCandidate, pair_count)
      ?? c3d::CAPACITY_EXCEEDED~!;

    BreakablePairJob job = {
        .piece_count = (uint)poses.len,
        .gap = gap,
        .poses = poses,
        .offsets = offsets,
        .hulls = hulls,
        .bounds = bounds,
        .candidates = candidates,
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

    BreakableEdgeCandidate[] found = candidates[:job.candidate_count];
    if (!in_breakable_pair_order(found)) sort::mergesort(found, &compare_breakable_candidates);

    List{Weld} edges;
    edges.init(tmem);
    foreach (candidate : found) {
        uint first = (uint)(candidate.key >> 32);
        uint second = (uint)(candidate.key & uint::max);
        if (candidate.failed) (void)nearest_hull_pair(&job, first, second)!; // the same pair fails the same way

        Vec3 anchor = { candidate.anchor[0], candidate.anchor[1], candidate.anchor[2] };
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
    return edges.array_view();
}
