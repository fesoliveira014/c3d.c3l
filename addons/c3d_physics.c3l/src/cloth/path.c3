module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;

enum ClothPathKind @private {
    LINEAR,
    OFFSET,
    PLANE,
}

struct ClothPathNode @private {
    ClothPathKind kind;
    usz parent;
    ContactVector start;
    ContactVector end;
    double begin;
    double speed;
    ContactVector normal;
    double level;
    double support;
    ClothCandidate obstacle;
    bool curved;
}

fn void? prepare_body_motions(ClothState* state, bool publication) @private {
    if (!state.desc.collisions.continuous) return;
    foreach (index, &body : state.bodies) {
        if (!body.live) continue;
        state.body_motions[index] = physics::contact_motion(publication ? body.published : body.solved, body.current)!;
    }
}

fn ContactInterval? path_body_time(ClothState* state, ContactInterval time) @local {
    return physics::contact_add(physics::contact_value(state.sweep_begin), physics::contact_multiply(
        physics::contact_subtract(physics::contact_value(state.sweep_end), physics::contact_value(state.sweep_begin))!, time)!)!;
}

fn ContactFrame? path_shape_frame(ClothState* state, uint shape_index, ContactInterval time) @private {
    ClothShape* shape = &state.shapes[shape_index];
    return physics::contact_motion_leaf(&state.body_motions[shape.body], shape.local, path_body_time(state, time)!);
}

fn double? path_shape_speed(ClothState* state, uint shape_index, bool centre_only = false) @private {
    ClothShape* shape = &state.shapes[shape_index];
    ContactMotion* motion = &state.body_motions[shape.body];
    ContactIntervals extent = physics::contact_vector((ContactVector)shape.local.position);
    double radius = physics::contact_length(extent)!.max;
    if (!centre_only) {
        ContactVector reach = math::max(math::abs((ContactVector)shape.bounds.min), math::abs((ContactVector)shape.bounds.max));
        radius = physics::contact_add(physics::contact_value(radius), physics::contact_length(physics::contact_vector(reach))!)!.max;
    }
    ContactInterval speed = physics::contact_add(physics::contact_value(motion.translation_speed),
        physics::contact_multiply(physics::contact_value(motion.angular_speed), physics::contact_value(radius))!)!;
    return physics::contact_multiply(speed,
        physics::contact_subtract(physics::contact_value(state.sweep_end), physics::contact_value(state.sweep_begin))!)!.max;
}

fn void? evaluate_paths(ClothState* state, ContactInterval time) @private {
    for (usz index = 0; index < state.path_count; index++) {
        ClothPathNode* node = &state.path_nodes[index];
        ContactIntervals value;
        switch (node.kind) {
            case LINEAR:
                value = physics::contact_vector_add(physics::contact_vector(node.start), physics::contact_vector_scale(
                    physics::contact_vector_subtract(physics::contact_vector(node.end), physics::contact_vector(node.start))!, time)!)!;
            case OFFSET:
                ContactInterval progress = physics::contact_divide(
                    physics::contact_subtract(time, physics::contact_value(node.begin))!,
                    physics::contact_subtract(physics::contact_value(1), physics::contact_value(node.begin))!,
                )!;
                progress.min = math::max(0.0, progress.min);
                progress.max = math::max(0.0, progress.max);
                value = physics::contact_vector_add(state.path_values[node.parent],
                    physics::contact_vector_scale(physics::contact_vector(node.end), progress)!)!;
            case PLANE:
                value = state.path_values[node.parent];
                ContactIntervals normal = physics::contact_vector(node.normal);
                ContactIntervals centre = physics::contact_vector((ContactVector){});
                if (node.obstacle.kind != GROUND) {
                    ContactFrame frame = path_shape_frame(state, node.obstacle.shape, time)!;
                    normal = physics::contact_rotate(&frame, normal)!;
                    centre = frame.position;
                }
                ContactInterval gap = physics::contact_subtract(physics::contact_value(node.level),
                    physics::contact_dot(normal, physics::contact_vector_subtract(value, centre)!)!)!;
                gap.min = math::max(0.0, gap.min);
                gap.max = math::max(0.0, gap.max);
                ContactInterval squared = physics::contact_dot(physics::contact_vector(node.normal), physics::contact_vector(node.normal))!;
                value = physics::contact_vector_add(value, physics::contact_vector_scale(normal, physics::contact_divide(gap, squared)!)!)!;
        }
        state.path_values[index] = value;
    }
}

fn void? path_bounds(ClothState* state) @private {
    evaluate_paths(state, { .min = 0, .max = 1 })!;
    foreach (particle, head : state.path_heads) {
        ContactIntervals value = state.path_values[head];
        for (uint axis = 0; axis < 3; axis++) {
            state.sweep_bounds[particle].min[axis] = physics::contact_float_bound(value[axis].min, false)!;
            state.sweep_bounds[particle].max[axis] = physics::contact_float_bound(value[axis].max, true)!;
        }
    }
}

fn void? start_paths(
    ClothState* state,
    Vec3[] start,
    Vec3[] end,
    double begin,
    double finish,
) @private {
    state.sweep_begin = begin;
    state.sweep_end = finish;
    state.path_count = start.len;
    foreach (index, position : start) {
        if (!finite_vector(position) || !finite_vector(end[index])) return CONTACT_PRECISION_EXCEEDED~;
        state.path_nodes[index] = {
            .kind = LINEAR,
            .start = (ContactVector)position,
            .end = (ContactVector)end[index],
            .speed = physics::contact_length(physics::contact_vector_subtract(
                physics::contact_vector((ContactVector)end[index]), physics::contact_vector((ContactVector)position))!)!.max,
        };
        state.path_heads[index] = (usz)index;
    }
}

fn bool same_path_obstacle(ClothCandidate first, ClothCandidate second) @private {
    if (first.kind != second.kind) return false;
    if (first.kind == GROUND) return true;
    return first.shape == second.shape && (first.kind != TRIANGLE || first.triangle_index == second.triangle_index);
}

fn void? append_plane_path(
    PhysicsWorld* world,
    ClothState* state,
    ClothCandidate candidate,
    ContactVector direction,
    double time,
) @private {
    usz parent = state.path_heads[candidate.particle];
    if (state.path_count == state.path_nodes.len) return c3d::CAPACITY_EXCEEDED~;
    ClothPathNode node = { .kind = PLANE, .parent = parent, .obstacle = candidate, .curved = true };
    double offset = math::max(0.0, (double)state.desc.thickness - (double)state.desc.collisions.contact_tolerance / 4);
    ContactFrame frame;
    if (candidate.kind == GROUND) {
        node.normal = { 0, 1, 0 };
        node.support = state.desc.ground_height;
        node.level = physics::contact_add(physics::contact_value(node.support), physics::contact_value(offset))!.max;
    } else {
        frame = path_shape_frame(state, candidate.shape, physics::contact_value(time))!;
        node.normal = physics::contact_middle(physics::contact_inverse_rotate(&frame, physics::contact_vector(direction))!);
        ContactInterval length = physics::contact_length(physics::contact_vector(node.normal))!;
        if (!(length.min > 0)) return CONTACT_PRECISION_EXCEEDED~;
        node.support = physics::cloth_local_support(world: world, state: state, candidate: &candidate, normal: node.normal,)!;
        node.level = physics::contact_add(physics::contact_value(node.support), physics::contact_multiply(physics::contact_value(offset), length)!)!.max;
    }
    evaluate_paths(state, physics::contact_value(0))!;
    ContactIntervals normal = physics::contact_vector(node.normal);
    ContactIntervals centre = physics::contact_vector((ContactVector){});
    if (candidate.kind != GROUND) {
        frame = path_shape_frame(state, candidate.shape, physics::contact_value(0))!;
        normal = physics::contact_rotate(&frame, normal)!;
        centre = frame.position;
    }
    double initial = physics::contact_dot(normal, physics::contact_vector_subtract(state.path_values[parent], centre)!)!.min;
    if (initial < node.level) return CONTACT_UNRESOLVED~;

    double parent_speed = state.path_nodes[parent].speed;
    node.speed = physics::contact_multiply(physics::contact_value(parent_speed), physics::contact_value(2))!.max;
    if (candidate.kind != GROUND) {
        evaluate_paths(state, { .min = 0, .max = 1 })!;
        frame = path_shape_frame(state, candidate.shape, { .min = 0, .max = 1 })!;
        double radius = physics::contact_length(physics::contact_vector_subtract(state.path_values[parent], frame.position)!)!.max;
        double length = physics::contact_length(physics::contact_vector(node.normal))!.min;
        double centre_speed = path_shape_speed(state, candidate.shape, true)!;
        double angular = physics::contact_multiply(physics::contact_value(state.body_motions[state.shapes[candidate.shape].body].angular_speed),
            physics::contact_subtract(physics::contact_value(state.sweep_end), physics::contact_value(state.sweep_begin))!)!.max;
        ContactInterval lever = physics::contact_add(
            physics::contact_divide(physics::contact_value(math::abs(node.level)), physics::contact_value(length))!,
            physics::contact_multiply(physics::contact_value(radius), physics::contact_value(2))!,
        )!;
        node.speed = physics::contact_add(physics::contact_add(physics::contact_value(node.speed), physics::contact_value(centre_speed))!,
            physics::contact_multiply(physics::contact_value(angular), lever)!)!.max;
    }
    state.path_nodes[state.path_count] = node;
    state.path_heads[candidate.particle] = state.path_count++;
}

fn void? append_offset_path(
    ClothState* state,
    uint particle,
    ContactVector displacement,
    double begin,
) @private {
    if (state.path_count == state.path_nodes.len) return c3d::CAPACITY_EXCEEDED~;
    usz parent = state.path_heads[particle];
    ContactInterval speed = physics::contact_divide(physics::contact_length(physics::contact_vector(displacement))!,
        physics::contact_subtract(physics::contact_value(1), physics::contact_value(begin))!)!;
    state.path_nodes[state.path_count] = {
        .kind = OFFSET,
        .parent = parent,
        .end = displacement,
        .begin = begin,
        .speed = physics::contact_add(physics::contact_value(state.path_nodes[parent].speed), speed)!.max,
        .curved = state.path_nodes[parent].curved,
    };
    state.path_heads[particle] = state.path_count++;
}
