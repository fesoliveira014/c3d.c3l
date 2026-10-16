module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics @public;
import std::math;

const float MIN_CONSTRAINT_LENGTH @private = 1e-7f; // metres; a shorter pair separates along its rest direction

fn void? solve_cloth(
    PhysicsWorld* world,
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
    prepare_body_motions(state, false)!;
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
        filter_displacement(
            world: world, state: state, start: state.positions, proposed: state.predicted,
            begin: (double)(substep - 1) / total, end: (double)substep / total,
        )!;
        place_shapes(state, (double)substep / total)!;
        for (uint iteration = 0; iteration < desc.iterations; iteration++) {
            if (desc.collisions.continuous) state.sweep_start[..] = state.predicted[..];
            project_constraints(state, state.edges, stretch);
            filter_displacement(
                world: world, state: state, start: state.sweep_start, proposed: state.predicted,
                begin: (double)substep / total, end: (double)substep / total,
            )!;
            if (desc.collisions.continuous) state.sweep_start[..] = state.predicted[..];
            project_constraints(state, state.bends, bend);
            filter_displacement(
                world: world, state: state, start: state.sweep_start, proposed: state.predicted,
                begin: (double)substep / total, end: (double)substep / total,
            )!;
            (void)contact_pass(world: world, state: state, positions: state.predicted, apply: true)!;
        }
        resolve_contacts(world, state, state.predicted)!;
        foreach (index, &position : state.positions) {
            state.velocities[index] = (state.predicted[index] - *position) / dt;
            *position = state.predicted[index];
        }
    }
    state.pin_anchors[..] = state.pin_targets[..];
    finish_body_poses(state);
}

fn void? prepare_publication(PhysicsWorld* world, ClothState* state, bool solved) @private {
    if (state.desc.collisions.continuous) {
        state.sweep_start[..] = (solved ? state.positions : state.published)[..];
        prepare_body_motions(state, !solved)!;
    }
    state.published[..] = state.positions[..];
    foreach (slot, pin : state.pins) state.published[pin] = state.pin_targets[slot];
    filter_displacement(
        world: world, state: state, start: state.sweep_start, proposed: state.published,
        begin: solved ? 1 : 0, end: 1,
    )!;
    place_shapes(state, 1)!;
    resolve_contacts(world, state, state.published)!;
    foreach (&body : state.bodies) {
        if (!body.live) continue;
        body.published = body.current;
        body.published_observed = true;
    }
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

fn float pass_stiffness(float stiffness, uint iterations) @local {
    return 1 - math::pow(1 - stiffness, 1 / (float)iterations);
}
