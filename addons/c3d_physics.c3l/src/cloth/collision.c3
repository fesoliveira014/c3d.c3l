module c3d::physics::cloth;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math::vector;

struct ClothCapture @private {
    ClothBody[] bodies;
    ClothShape[] shapes;
}

fn void? check_collider_owners(Scene* scene, Entity[] owners) @private {
    if (owners.len > MAX_CLOTH_COLLIDERS) return c3d::CAPACITY_EXCEEDED~;
    foreach (index, owner : owners) {
        if (!scene.world.is_alive(owner)) return c3d::INVALID_ID~;
        foreach (earlier : owners[:index]) {
            if (c3d::same_id(earlier, owner)) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn ClothCapture? capture_colliders(
    Scene* scene,
    Entity[] owners,
    uint max_shapes,
    PhysicsWorld* world = null,
) @private {
    check_collider_owners(scene, owners)!;
    ClothCapture capture = {
        .bodies = alloc::new_array(tmem, ClothBody, (sz)owners.len),
        .shapes = alloc::new_array(tmem, ClothShape, (sz)max_shapes),
    };

    usz count;
    foreach (index, owner : owners) {
        RigidBody* body = scene.get(scene.node(owner), RigidBody);
        if (!physics::cloth_body_live(body)) return physics::NO_BODY~;
        capture.bodies[index] = { .owner = owner, .native_identity = physics::cloth_body_identity(body) };
        count += physics::capture_cloth_shapes(
            world: world,
            body: body,
            body_index: (uint)index,
            output: capture.shapes[count..],
        )!;
    }

    capture.shapes = capture.shapes[:count];
    return capture;
}

fn bool same_body_identity(uint[4] first, uint[4] second) @local {
    foreach (index, value : first) if (value != second[index]) return false;
    return true;
}

fn bool same_shape_binding(ClothShape* first, ClothShape* second) @local {
    if (first.kind != second.kind || first.collider != second.collider || first.compound_child != second.compound_child
        || first.child != second.child || first.snapshot.index != second.snapshot.index || first.snapshot.generation != second.snapshot.generation) return false;
    foreach (index, value : first.native_identity) if (value != second.native_identity[index]) return false;
    return first.start == second.start && first.end == second.end && first.radius == second.radius
      && first.local.position == second.local.position && first.local.rotation.v == second.local.rotation.v
      && first.bounds.min == second.bounds.min && first.bounds.max == second.bounds.max;
}

fn void? refresh_colliders(PhysicsWorld* world, ClothState* state) @private {
    ClothShape[] previous = state.shapes;
    usz count;
    foreach (body_index, &body : state.bodies) {
        body.live = world.scene.world.is_alive(body.owner);
        RigidBody* rigid = body.live ? world.scene.get(world.scene.node(body.owner), RigidBody) : null;
        body.live = physics::cloth_body_live(rigid);
        if (!body.live) {
            body.observed = body.published_observed = false;
            continue;
        }

        uint[4] identity = physics::cloth_body_identity(rigid);
        if (!same_body_identity(body.native_identity, identity)) body.observed = body.published_observed = false;
        body.native_identity = identity;

        usz first = count;
        count += physics::capture_cloth_shapes(
            world: world,
            body: rigid,
            body_index: (uint)body_index,
            output: state.shape_storage[count..],
        )!;

        usz matching = first;
        foreach (&old : previous) {
            if (old.body != body_index) continue;
            if (matching == count || !same_shape_binding(old, &state.shape_storage[matching])) {
                body.observed = body.published_observed = false;
                break;
            }
            matching++;
        }
        if (matching != count) body.observed = body.published_observed = false;
    }

    state.shapes = state.shape_storage[:count];
}

fn void sample_bodies(Scene* scene, ClothState* state) @private {
    foreach (&body : state.bodies) {
        body.live = scene.world.is_alive(body.owner);
        RigidBody* rigid = body.live ? scene.get(scene.node(body.owner), RigidBody) : null;
        body.live = physics::cloth_body_live(rigid);
        if (!body.live) {
            body.observed = body.published_observed = false;
            continue;
        }

        uint[4] identity = physics::cloth_body_identity(rigid);
        if (!same_body_identity(body.native_identity, identity)) body.observed = body.published_observed = false;
        body.native_identity = identity;

        body.current = maths::transform_from_mat4(scene.node(body.owner).world);
        body.current.scale = { 1, 1, 1 };
        if (!body.observed) {
            body.solved = body.current;
            body.observed = true;
        }
        if (!body.published_observed) body.published = body.current;
    }
}

fn void? place_shapes(ClothState* state, double progress) @private {
    foreach (index, &shape : state.shapes) {
        ClothBody* body = &state.bodies[shape.body];
        if (!body.live) continue;
        maths::Transform pose = interpolate_body(body.solved, body.current, (float)progress);
        state.frames[index] = state.desc.collisions.continuous
          ? physics::contact_motion_leaf(&state.body_motions[shape.body], shape.local, physics::contact_value(progress))!
          : physics::contact_frame(pose, shape.local)!;
        state.shape_starts[index] = (Vec3)physics::contact_middle(physics::contact_point(&state.frames[index], shape.start)!);
        state.shape_ends[index] = (Vec3)physics::contact_middle(physics::contact_point(&state.frames[index], shape.end)!);
        if (!finite_vector(state.shape_starts[index]) || !finite_vector(state.shape_ends[index])) return CONTACT_PRECISION_EXCEEDED~;
    }
}

fn void finish_body_poses(ClothState* state) @private {
    foreach (&body : state.bodies) {
        if (!body.live) continue;
        body.solved = body.current;
        body.observed = true;
    }
}

fn maths::Transform interpolate_body(maths::Transform solved, maths::Transform current, float progress) @local {
    if (progress == 0) return solved;
    if (progress == 1) return current;
    return {
        .position = solved.position + (current.position - solved.position) * progress,
        .rotation = solved.rotation.slerp(current.rotation, progress),
        .scale = { 1, 1, 1 },
    };
}
