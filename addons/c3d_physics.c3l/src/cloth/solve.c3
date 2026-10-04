module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics @public;
import std::math;

const float MIN_CONSTRAINT_LENGTH @private = 1e-7f; // metres; a shorter pair separates along its rest direction

fn void solve_cloth(
    ClothState* state,
    Wind* wind,
    Vec3 gravity,
    float step_dt,
    uint steps,
) @private {
    ClothDesc* desc = &state.desc;
    uint total = steps * desc.substeps;
    float dt = step_dt / (float)desc.substeps;
    float stretch = pass_stiffness(desc.stretch_stiffness, desc.iterations);
    float bend = pass_stiffness(desc.bend_stiffness, desc.iterations);
    float damping = math::max(0.0f, 1 - desc.damping * dt);
    Vec3 acceleration = gravity * desc.gravity_scale;
    uint[] indices = state.assets.geometry(state.geometry).data.indices;
    for (uint substep = 1; substep <= total; substep++) {
        accumulate_wind(state, wind, indices);
        foreach (index, position : state.positions) {
            if (state.inverse_masses[index] == 0) continue;
            Vec3 velocity = (state.velocities[index] + (acceleration + state.accelerations[index]) * dt) * damping;
            state.velocities[index] = velocity;
            state.predicted[index] = position + velocity * dt;
        }
        float progress = (float)substep / (float)total;
        foreach (slot, pin : state.pins) {
            state.predicted[pin] = substep == total
              ? state.pin_targets[slot]
              : state.pin_anchors[slot] + (state.pin_targets[slot] - state.pin_anchors[slot]) * progress;
        }
        place_shapes(state, progress);
        for (uint iteration = 0; iteration < desc.iterations; iteration++) {
            project_constraints(state, state.edges, stretch);
            project_constraints(state, state.bends, bend);
            project_contacts(state, state.predicted);
        }
        foreach (index, &position : state.positions) {
            state.velocities[index] = (state.predicted[index] - *position) / dt;
            *position = state.predicted[index];
        }
    }
    state.pin_anchors[..] = state.pin_targets[..];
    finish_body_poses(state);
}

fn void publish_cloth(ClothState* state, Mat4 world) @private {
    state.published[..] = state.positions[..];
    foreach (slot, pin : state.pins) state.published[pin] = state.pin_targets[slot];
    place_shapes(state, 1);
    project_contacts(state, state.published);
    Mat4 to_local = maths::inverse_affine(world);
    GeometryAsset* geometry = state.assets.geometry(state.geometry);
    bool changed;
    foreach (index, &local : geometry.data.positions) {
        Vec3 position = maths::transform_point(to_local, state.published[index]);
        if (position == *local) continue;
        *local = position;
        changed = true;
    }
    if (!changed) return;
    geometry.data.compute_normals(state.assets.allocator);
    geometry.data.finalize();
    state.assets.mark_geometry_dirty(state.geometry);
}

fn void accumulate_wind(ClothState* state, Wind* wind, uint[] indices) @local {
    state.accelerations[..] = (Vec3){};
    if (!wind || wind.drag == 0) return;
    for (usz corner = 0; corner < indices.len; corner += 3) {
        uint first = indices[corner];
        uint second = indices[corner + 1];
        uint third = indices[corner + 2];
        Vec3 cross = (state.positions[second] - state.positions[first]).cross(state.positions[third] - state.positions[first]);
        float doubled_area = cross.length();
        if (doubled_area == 0) continue;
        Vec3 normal = cross / doubled_area;
        Vec3 relative = wind.velocity
          - (state.velocities[first] + state.velocities[second] + state.velocities[third]) / 3;
        float speed = relative.length();
        if (wind.max_speed > 0 && speed > wind.max_speed) relative *= wind.max_speed / speed;
        Vec3 share = normal * (wind.drag * doubled_area * 0.5f * relative.dot(normal) / 3);
        state.accelerations[first] += share;
        state.accelerations[second] += share;
        state.accelerations[third] += share;
    }
}

fn void project_constraints(ClothState* state, ClothConstraint[] constraints, float stiffness) @local {
    foreach (&constraint : constraints) {
        float first_weight = state.inverse_masses[constraint.first];
        float second_weight = state.inverse_masses[constraint.second];
        float total = first_weight + second_weight;
        if (total == 0) continue;
        Vec3 delta = state.predicted[constraint.second] - state.predicted[constraint.first];
        float length = delta.length();
        Vec3 direction = length > MIN_CONSTRAINT_LENGTH ? delta / length : constraint.rest_direction;
        Vec3 correction = direction * ((length - constraint.rest_length) * stiffness / total);
        state.predicted[constraint.first] += correction * first_weight;
        state.predicted[constraint.second] -= correction * second_weight;
    }
}

fn void project_contacts(ClothState* state, Vec3[] positions) @local {
    if (state.desc.collide_ground) project_ground(state, positions);
    project_shapes(state, positions);
}

fn void project_ground(ClothState* state, Vec3[] positions) @private {
    float floor = state.desc.ground_height + state.desc.thickness;
    foreach (index, &position : positions) {
        if (state.inverse_masses[index] != 0 && position.y < floor) position.y = floor;
    }
}

fn float pass_stiffness(float stiffness, uint iterations) @local {
    return 1 - math::pow(1 - stiffness, 1 / (float)iterations);
}
