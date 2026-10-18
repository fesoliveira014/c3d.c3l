module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics @public;
import std::math;

const float MIN_CONSTRAINT_LENGTH @private = 1e-7f; // metres; a shorter pair separates along its rest direction

fn void? certify_hinge_step(
    ClothState* state,
    Vec3[] start_positions,
    Vec3[] end_positions,
    bool commit_angle = true,
) @local {
    if (!state.hinges.len) return;
    foreach (&hinge : state.hinges) {
        Vec3[4] start_points = {
            start_positions[hinge.p0],
            start_positions[hinge.p1],
            start_positions[hinge.p2],
            start_positions[hinge.p3],
        };
        Vec3[4] end_points = {
            end_positions[hinge.p0],
            end_positions[hinge.p1],
            end_positions[hinge.p2],
            end_positions[hinge.p3],
        };
        float? angle = certify_hinge_path(start_points, end_points, hinge.last_angle);
        if (catch angle) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }
        if (commit_angle) hinge.last_angle = angle;
    }
}

fn Vec3 substep_transport(
    ClothState* state,
    sz index,
    uint substep,
    uint total,
    float previous_progress,
    float progress,
) @local {
    Vec3 solved = state.solved_reference[index];
    Vec3 current = state.current_reference[index];
    Vec3 delta = current - solved;
    Vec3 previous_reference = substep == 1 ? solved : solved + delta * previous_progress;
    Vec3 next_reference = substep == total ? current : solved + delta * progress;
    return (next_reference - previous_reference) * state.transport[index];
}

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
    prepare_body_motions(state, false)!;

    for (uint substep = 1; substep <= total; substep++) {
        float previous_progress = (float)(substep - 1) / (float)total;
        float progress = (float)substep / (float)total;
        accumulate_wind(state, wind);
        foreach (index, position : state.positions) {
            if (state.inverse_masses[index] == 0) continue;
            Vec3 transport = substep_transport(
                state:             state,
                index:             index,
                substep:           substep,
                total:             total,
                previous_progress: previous_progress,
                progress:          progress,
            );
            Vec3 velocity = (state.velocities[index] + (acceleration + state.accelerations[index]) * dt) * damping;
            state.velocities[index] = velocity;
            state.predicted[index] = position + transport + velocity * dt;
        }

        state.soft_lambdas[..] = (Vec3){};
        foreach (&hinge : state.hinges) hinge.lambda = 0;

        foreach (slot, pin : state.pins) {
            state.predicted[pin] = substep == total
              ? state.pin_targets[slot]
              : state.pin_anchors[slot] + (state.pin_targets[slot] - state.pin_anchors[slot]) * progress;
        }
        filter_displacement(
            world: world,
            state: state,
            start: state.positions,
            proposed: state.predicted,
            begin: (double)(substep - 1) / total,
            end: (double)substep / total,
        )!;
        certify_hinge_step(
            state:           state,
            start_positions: state.positions,
            end_positions:   state.predicted,
            commit_angle:    false,
        )!;
        place_shapes(state, (double)substep / total)!;

        for (uint iteration = 0; iteration < desc.iterations; iteration++) {
            if (state.soft_attachments.len) {
                if (desc.collisions.continuous) state.sweep_start[..] = state.predicted[..];
                project_soft_attachments(
                    state:         state,
                    dt:            dt,
                    progress:      progress,
                    final_substep: substep == total,
                )!;
                filter_displacement(
                    world:    world,
                    state:    state,
                    start:    state.sweep_start,
                    proposed: state.predicted,
                    begin:    (double)substep / total,
                    end:      (double)substep / total,
                )!;
            }

            if (desc.collisions.continuous) state.sweep_start[..] = state.predicted[..];
            project_constraints(state, state.edges, stretch);
            filter_displacement(
                world: world,
                state: state,
                start: state.sweep_start,
                proposed: state.predicted,
                begin: (double)substep / total,
                end: (double)substep / total,
            )!;

            if (desc.collisions.continuous) state.sweep_start[..] = state.predicted[..];
            if (desc.bend_mode == DISTANCE) {
                project_constraints(state, state.bends, bend);
            } else {
                project_dihedral_bends(state, dt)!;
            }
            filter_displacement(
                world: world,
                state: state,
                start: state.sweep_start,
                proposed: state.predicted,
                begin: (double)substep / total,
                end: (double)substep / total,
            )!;

            (void)contact_pass(world: world, state: state, positions: state.predicted, apply: true)!;
        }

        resolve_contacts(world, state, state.predicted)!;
        certify_hinge_step(state, state.positions, state.predicted)!;
        foreach (index, &position : state.positions) {
            Vec3 transport = substep_transport(
                state:             state,
                index:             index,
                substep:           substep,
                total:             total,
                previous_progress: previous_progress,
                progress:          progress,
            );
            state.velocities[index] = (state.predicted[index] - *position - transport) / dt;
            *position = state.predicted[index];
        }
    }

    state.solved_reference[..] = state.current_reference[..];
    state.pin_anchors[..] = state.pin_targets[..];
    state.soft_anchors[..] = state.soft_targets[..];
    finish_body_poses(state);
}

fn void? prepare_publication(PhysicsWorld* world, ClothState* state, bool solved) @private {
    if (state.desc.collisions.continuous) {
        state.sweep_start[..] = (solved ? state.positions : state.published)[..];
        prepare_body_motions(state, !solved)!;
    }
    if (solved) {
        state.published[..] = state.positions[..];
    } else {
        foreach (index, position : state.positions) {
            state.published[index] = position
              + (state.current_reference[index] - state.solved_reference[index]) * state.transport[index];
        }
    }
    foreach (slot, pin : state.pins) state.published[pin] = state.pin_targets[slot];
    filter_displacement(
        world: world,
        state: state,
        start: state.sweep_start,
        proposed: state.published,
        begin: solved ? 1 : 0,
        end: 1,
    )!;
    place_shapes(state, 1)!;
    resolve_contacts(world, state, state.published)!;
    certify_hinge_step(
        state:           state,
        start_positions: state.positions,
        end_positions:   state.published,
        commit_angle:    solved,
    )!;
    foreach (&body : state.bodies) {
        if (!body.live) continue;
        body.published = body.current;
        body.published_observed = true;
    }
}

fn void accumulate_wind(ClothState* state, Wind* wind) @local {
    state.accelerations[..] = (Vec3){};
    if (!wind || wind.drag == 0) return;
    for (usz corner = 0; corner < state.corners.len; corner += 3) {
        uint first = state.corners[corner].particle;
        uint second = state.corners[corner + 1].particle;
        uint third = state.corners[corner + 2].particle;
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
