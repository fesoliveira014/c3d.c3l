module c3d::physics::cloth;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;

const float MIN_CONTACT_DISTANCE @private = 1e-7f; // metres; a closer particle leaves along a fixed perpendicular
const Vec3 SPHERE_EXIT @private = { 0, 1, 0 }; // exit direction of a particle at a sphere's centre
const float AXIS_ALIGNMENT_LIMIT @private = 0.9f; // above this, the perpendicular is built from X instead of Y

struct ClothCapture @private {
    ClothBody[]  bodies;
    ClothShape[] shapes;
}

fn ClothCapture? capture_colliders(Scene* scene, Entity[] owners) @private {
    if (owners.len > MAX_CLOTH_COLLIDERS) return c3d::CAPACITY_EXCEEDED~;
    ClothCapture capture = {
        .bodies = alloc::new_array(tmem, ClothBody, (sz)owners.len),
        .shapes = alloc::new_array(tmem, ClothShape, MAX_CLOTH_COLLIDERS),
    };
    usz shape_count;
    foreach (index, owner : owners) {
        if (!scene.world.is_alive(owner)) return c3d::INVALID_ID~;
        foreach (earlier : owners[:index]) {
            if (c3d::same_id(earlier, owner)) return c3d::INVALID_ARGUMENT~;
        }
        RigidBody* body = scene.get(scene.node(owner), RigidBody);
        if (!body) return physics::NO_BODY~;
        capture.bodies[index] = { .owner = owner };
        foreach (&collider : body.colliders) {
            if (collider.kind != SPHERE && collider.kind != CAPSULE) continue;
            if (shape_count == MAX_CLOTH_COLLIDERS) return c3d::CAPACITY_EXCEEDED~;
            float half_height = collider.kind == CAPSULE ? collider.half_height : 0;
            Vec3 half = collider.local.rotation.rotate_vec3({ 0, half_height, 0 });
            capture.shapes[shape_count++] = {
                .body   = (uint)index,
                .start  = collider.local.position - half,
                .end    = collider.local.position + half,
                .radius = collider.radius,
            };
        }
    }
    capture.shapes = capture.shapes[:shape_count];
    return capture;
}

fn void sample_bodies(Scene* scene, ClothState* state) @private {
    foreach (&body : state.bodies) {
        body.live = scene.world.is_alive(body.owner) && scene.has(scene.node(body.owner), RigidBody);
        if (!body.live) {
            body.observed = false;
            continue;
        }
        body.current = maths::transform_from_mat4(scene.node(body.owner).world);
        body.current.scale = { 1, 1, 1 };
        if (body.observed) continue;
        body.solved = body.current;
        body.observed = true;
    }
}

fn void place_shapes(ClothState* state, float progress) @private {
    foreach (index, &shape : state.shapes) {
        ClothBody* body = &state.bodies[shape.body];
        if (!body.live) continue;
        maths::Transform pose = interpolate_body(body.solved, body.current, progress);
        state.shape_starts[index] = pose.position + pose.rotation.rotate_vec3(shape.start);
        state.shape_ends[index] = pose.position + pose.rotation.rotate_vec3(shape.end);
    }
}

fn void project_shapes(ClothState* state, Vec3[] positions) @private {
    foreach (shape_index, &shape : state.shapes) {
        if (!state.bodies[shape.body].live) continue;
        Vec3 start = state.shape_starts[shape_index];
        Vec3 end = state.shape_ends[shape_index];
        float radius = shape.radius + state.desc.thickness;
        foreach (index, &position : positions) {
            if (state.inverse_masses[index] == 0) continue;
            *position = outside_capsule(
                point:  *position,
                start:  start,
                end:    end,
                radius: radius,
            );
        }
    }
}

fn void finish_body_poses(ClothState* state) @private {
    foreach (&body : state.bodies) {
        if (body.live) body.solved = body.current;
    }
}

fn maths::Transform interpolate_body(maths::Transform solved, maths::Transform current, float progress) @local {
    return {
        .position = solved.position + (current.position - solved.position) * progress,
        .rotation = solved.rotation.slerp(current.rotation, progress),
        .scale    = { 1, 1, 1 },
    };
}

fn Vec3 outside_capsule(
    Vec3 point,
    Vec3 start,
    Vec3 end,
    float radius,
) @private {
    Vec3 axis = end - start;
    float length_squared = axis.dot(axis);
    float along = length_squared > 0 ? math::clamp((point - start).dot(axis) / length_squared, 0.0f, 1.0f) : 0;
    Vec3 closest = start + axis * along;
    Vec3 offset = point - closest;
    float distance = offset.length();
    if (distance >= radius) return point;
    Vec3 direction = distance > MIN_CONTACT_DISTANCE ? offset / distance : centreline_exit(axis, length_squared);
    return closest + direction * radius;
}

fn Vec3 centreline_exit(Vec3 axis, float length_squared) @local {
    if (length_squared == 0) return SPHERE_EXIT;
    Vec3 unit = axis / math::sqrt(length_squared);
    Vec3 reference = math::abs(unit.y) < AXIS_ALIGNMENT_LIMIT ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    return unit.cross(reference).normalize();
}
