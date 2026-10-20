module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;
import std::time;
import std::time::clock;

const double CLOTH_ADVANCE_FRACTION @local = 0.9;
const double MIN_RESPONSE_SHARE @local = 0.25; // torn seams only; coincident seam halves stall on near-zero barycentric weights

struct ClothPathDistance @local {
    double lower;
    double upper;
    ContactVector direction;
}

struct ClothImpact @private {
    bool hit;
    double time;
    ContactVector direction;
    uint[4] vertices;
    double[4] coefficients;
    uint first_count;
}

fn bool self_candidate(ClothCandidate candidate) @private {
    return candidate.kind == SELF_VERTEX_FACE || candidate.kind == SELF_EDGE_EDGE;
}

fn void? sample_path_pair(
    PhysicsWorld* world,
    ClothState* state,
    ClothCandidate* candidate,
    ContactInterval time,
    ContactPairSample* sample,
) @local {
    *sample = {};
    evaluate_paths(state, time)!;
    if (!self_candidate(*candidate)) {
        ContactIntervals particle = state.path_values[state.path_heads[candidate.particle]];
        if (candidate.kind == GROUND) {
            sample.first_count = sample.second_count = 1;
            sample.first[0] = sample.witness_first = particle;
            sample.second[0] = sample.witness_second = { particle[0], physics::contact_value(state.desc.ground_height), particle[2] };
            sample.vertices[0] = candidate.particle;
            sample.coefficients[0] = 1;
            return;
        }
        ContactFrame frame = path_shape_frame(state, candidate.shape, time)!;
        return physics::sample_cloth_external(
            world: world,
            state: state,
            candidate: candidate,
            frame: &frame,
            particle: particle,
            sample: sample,
        );
    }

    bool vertex_face = candidate.kind == SELF_VERTEX_FACE;
    if (vertex_face) {
        uint[3] face = state.faces[candidate.self_pair[1]].vertices;
        sample.vertices = { candidate.self_pair[0], face[0], face[1], face[2] };
    } else {
        ClothConstraint first = state.edges[candidate.self_pair[0]];
        ClothConstraint second = state.edges[candidate.self_pair[1]];
        sample.vertices = { first.first, first.second, second.first, second.second };
    }
    sample.first_count = vertex_face ? 1 : 2;
    sample.second_count = 4 - sample.first_count;
    for (uint index = 0; index < sample.first_count; index++) sample.first[index] = state.path_values[state.path_heads[sample.vertices[index]]];
    for (uint index = 0; index < sample.second_count; index++) sample.second[index] = state.path_values[state.path_heads[sample.vertices[index + sample.first_count]]];

    if (vertex_face) {
        ContactVector weights = physics::contact_triangle_weights(
            point: physics::contact_middle(sample.first[0]),
            first: physics::contact_middle(sample.second[0]),
            second: physics::contact_middle(sample.second[1]),
            third: physics::contact_middle(sample.second[2]),
        );
        sample.witness_first = sample.first[0];
        sample.witness_second = physics::contact_triangle_witness(
            first: sample.second[0],
            second: sample.second[1],
            third: sample.second[2],
            weights: weights,
        )!;
        double total = weights.x + weights.y + weights.z;
        if (!(total > 0) || !math::is_finite(total)) return CONTACT_PRECISION_EXCEEDED~;
        weights /= total;
        sample.coefficients = { 1, -weights.x, -weights.y, -weights.z };
    } else {
        double[2] along = self_edge_weights(
            first_start: physics::contact_middle(sample.first[0]),
            first_end: physics::contact_middle(sample.first[1]),
            second_start: physics::contact_middle(sample.second[0]),
            second_end: physics::contact_middle(sample.second[1]),
        );
        sample.witness_first = physics::contact_vector_add(
            first: sample.first[0],
            second: physics::contact_vector_scale(
                value: physics::contact_vector_subtract(sample.first[1], sample.first[0])!,
                scale: physics::contact_value(along[0]),
            )!,
        )!;
        sample.witness_second = physics::contact_vector_add(
            first: sample.second[0],
            second: physics::contact_vector_scale(
                value: physics::contact_vector_subtract(sample.second[1], sample.second[0])!,
                scale: physics::contact_value(along[1]),
            )!,
        )!;
        sample.coefficients = { 1 - along[0], along[0], -(1 - along[1]), -along[1] };
    }
}

fn double? pair_separation(ContactPairSample* sample, ContactVector direction) @local {
    ContactInterval length = physics::contact_length(physics::contact_vector(direction))!;
    if (!(length.min > 0)) return 0;
    double lower = double::max;
    for (uint first = 0; first < sample.first_count; first++) {
        for (uint second = 0; second < sample.second_count; second++) {
            ContactInterval projected = physics::contact_dot(
                first: physics::contact_vector(direction),
                second: physics::contact_vector_subtract(sample.first[first], sample.second[second])!,
            )!;
            lower = math::min(lower, projected.min);
        }
    }
    if (lower <= 0) return 0;
    return math::max(
        x: 0.0,
        y: physics::contact_subtract(
            first: physics::contact_divide(physics::contact_value(lower), length)!,
            second: physics::contact_value(sample.radius),
        )!.min
    );
}

fn ClothPathDistance? path_distance(ContactPairSample* sample) @local {
    ContactIntervals delta = physics::contact_vector_subtract(sample.witness_first, sample.witness_second)!;
    ContactVector direction = physics::contact_middle(delta);
    return {
        .lower = pair_separation(sample, direction)!,
        .upper = math::max(
            x: 0.0,
            y: physics::contact_subtract(physics::contact_length(delta)!, physics::contact_value(sample.radius))!.max
        ),
        .direction = direction,
    };
}

fn double? pair_speed(ClothState* state, ClothCandidate* candidate, ContactPairSample* sample) @local {
    if (!self_candidate(*candidate)) {
        double speed = state.path_nodes[state.path_heads[candidate.particle]].speed;
        if (candidate.kind == GROUND) return speed;
        return physics::contact_add(
            first: physics::contact_value(speed),
            second: physics::contact_value(path_shape_speed(state, candidate.shape)!),
        )!.max;
    }
    double speed;
    for (uint first = 0; first < sample.first_count; first++) {
        for (uint second = sample.first_count; second < 4; second++) {
            double first_speed = state.path_nodes[state.path_heads[sample.vertices[first]]].speed;
            double second_speed = state.path_nodes[state.path_heads[sample.vertices[second]]].speed;
            speed = math::max(
                x: speed,
                y: physics::contact_add(physics::contact_value(first_speed), physics::contact_value(second_speed))!.max
            );
        }
    }
    return speed;
}

fn double? remaining_separation(
    PhysicsWorld* world,
    ClothState* state,
    ClothCandidate* candidate,
    ContactPairSample* sample,
    double begin,
    ContactVector direction,
) @local {
    bool affine = true;
    if (!self_candidate(*candidate)) {
        ClothPathNode* head = &state.path_nodes[state.path_heads[candidate.particle]];
        if (head.kind == PLANE && same_path_obstacle(head.obstacle, *candidate)) {
            return physics::contact_divide(
                numerator: physics::contact_subtract(
                    first: physics::contact_value(head.level),
                    second: physics::contact_value(head.support),
                )!,
                denominator: physics::contact_length(physics::contact_vector(head.normal))!,
            )!.min;
        }
        affine = !head.curved;
        if (candidate.kind != GROUND) {
            affine &= state.sweep_begin == state.sweep_end || state.body_motions[state.shapes[candidate.shape].body].constant_rotation;
        }
    } else {
        foreach (vertex : sample.vertices) affine &= !state.path_nodes[state.path_heads[vertex]].curved;
    }

    if (!affine) {
        sample_path_pair(
            world: world,
            state: state,
            candidate: candidate,
            time: { .min = begin, .max = 1 },
            sample: sample,
        )!;
        return pair_separation(sample, direction);
    }

    sample_path_pair(
        world: world,
        state: state,
        candidate: candidate,
        time: physics::contact_value(begin),
        sample: sample,
    )!;
    double lower = pair_separation(sample, direction)!;
    sample_path_pair(
        world: world,
        state: state,
        candidate: candidate,
        time: physics::contact_value(1),
        sample: sample,
    )!;
    lower = math::min(lower, pair_separation(sample, direction)!);
    for (usz index = state.path_heads.len; index < state.path_count; index++) {
        ClothPathNode* node = &state.path_nodes[index];
        if (node.kind != OFFSET || node.begin <= begin) continue;
        sample_path_pair(
            world: world,
            state: state,
            candidate: candidate,
            time: physics::contact_value(node.begin),
            sample: sample,
        )!;
        lower = math::min(lower, pair_separation(sample, direction)!);
    }
    return lower;
}

fn ClothImpact? sweep_candidate(PhysicsWorld* world, ClothState* state, ClothCandidate* candidate) @private {
    state.contact_result.sweeps++;
    double reach = state.desc.thickness * (self_candidate(*candidate) ? 2.0 : 1.0);
    double tolerance = state.desc.collisions.contact_tolerance;
    double separation = math::max(0.0, reach - tolerance / 2);
    ClothImpact impact;
    ContactPairSample sample;
    sample_path_pair(
        world: world,
        state: state,
        candidate: candidate,
        time: physics::contact_value(0),
        sample: &sample,
    )!;
    double speed = pair_speed(state, candidate, &sample)!;

    for (uint iteration = 0; iteration < state.desc.collisions.max_ccd_iterations; iteration++) {
        state.contact_result.ccd_iterations++;
        sample_path_pair(
            world: world,
            state: state,
            candidate: candidate,
            time: physics::contact_value(impact.time),
            sample: &sample,
        )!;
        ClothPathDistance distance = path_distance(&sample)!;
        if (candidate.kind == GROUND) {
            ContactInterval height = physics::contact_subtract(
                first: sample.first[0][1],
                second: physics::contact_value(state.desc.ground_height),
            )!;
            distance = { .lower = height.min, .upper = height.max, .direction = { 0, 1, 0 } };
        }
        impact.direction = distance.direction;
        impact.vertices = sample.vertices;
        impact.coefficients = sample.coefficients;
        impact.first_count = sample.first_count;

        if (remaining_separation(
            world: world,
            state: state,
            candidate: candidate,
            sample: &sample,
            begin: impact.time,
            direction: distance.direction,
        )! > separation) return impact;
        if (distance.direction.dot(distance.direction) == 0) {
            bool fixed = self_candidate(*candidate);
            if (fixed) foreach (vertex : impact.vertices) fixed &= state.inverse_masses[vertex] == 0;
            return fixed ? CONTACT_UNRESOLVED~ : CONTACT_PRECISION_EXCEEDED~;
        }

        bool respond = true;
        if (self_candidate(*candidate) && state.path_count > state.path_heads.len) {
            evaluate_paths(state, physics::contact_value(1))!;
            double normal_length = distance.direction.length();
            respond = false;
            for (uint first = 0; first < impact.first_count; first++) {
                for (uint second = impact.first_count; second < 4; second++) {
                    ContactVector delta = physics::contact_middle(
                        value: state.path_values[state.path_heads[impact.vertices[first]]],
                    )
                      - physics::contact_middle(state.path_values[state.path_heads[impact.vertices[second]]]);
                    respond |= normal_length > 0 && delta.dot(distance.direction) < reach * normal_length;
                }
            }
        }
        if (respond && distance.upper <= separation + tolerance / 4) {
            if (!(distance.lower > separation)) return CONTACT_UNRESOLVED~;
            impact.hit = true;
            return impact;
        }
        if (!(distance.lower > separation) || !(speed > 0)) return CONTACT_PRECISION_EXCEEDED~;

        if (self_candidate(*candidate) && state.path_count > state.path_heads.len) {
            double certified = certified_self_prefix(
                world: world,
                state: state,
                candidate: candidate,
                impact: impact,
                separation: separation,
            )!;
            if (certified > impact.time) {
                if (certified == 1) return impact;
                impact.time = certified;
                continue;
            }
        }

        ContactInterval step = physics::contact_multiply(
            first: physics::contact_value(CLOTH_ADVANCE_FRACTION),
            second: physics::contact_divide(
                numerator: physics::contact_subtract(
                    first: physics::contact_value(distance.lower),
                    second: physics::contact_value(separation),
                )!,
                denominator: physics::contact_value(speed),
            )!,
        )!;
        double next = physics::contact_add(physics::contact_value(impact.time), step)!.min;
        if (next >= 1) return impact;
        if (next <= impact.time) return CONTACT_NONCONVERGENT~;
        impact.time = next;
    }
    return CONTACT_NONCONVERGENT~;
}

fn double? certified_self_prefix(
    PhysicsWorld* world,
    ClothState* state,
    ClothCandidate* candidate,
    ClothImpact impact,
    double separation,
) @local {
    foreach (vertex : impact.vertices) if (state.path_nodes[state.path_heads[vertex]].curved) return impact.time;
    double end = 1;
    for (usz index = state.path_heads.len; index < state.path_count; index++) {
        ClothPathNode* node = &state.path_nodes[index];
        if (node.kind == OFFSET && node.begin > impact.time) end = math::min(end, node.begin);
    }

    ContactPairSample first_sample;
    ContactPairSample last_sample;
    sample_path_pair(
        world: world,
        state: state,
        candidate: candidate,
        time: physics::contact_value(impact.time),
        sample: &first_sample,
    )!;
    sample_path_pair(
        world: world,
        state: state,
        candidate: candidate,
        time: physics::contact_value(end),
        sample: &last_sample,
    )!;
    ContactIntervals direction = physics::contact_vector(impact.direction);
    ContactInterval length = physics::contact_length(direction)!;
    if (!(length.min > 0)) return impact.time;

    double fraction = 1;
    for (uint first = 0; first < impact.first_count; first++) {
        for (uint second = 0; second < last_sample.second_count; second++) {
            double first_gap = physics::contact_divide(
                numerator: physics::contact_dot(
                    first: direction,
                    second: physics::contact_vector_subtract(first_sample.first[first], first_sample.second[second])!,
                )!,
                denominator: length,
            )!.min;
            double last_gap = physics::contact_divide(
                numerator: physics::contact_dot(direction,
                    physics::contact_vector_subtract(last_sample.first[first], last_sample.second[second])!)!,
                denominator: length,
            )!.min;
            if (!(first_gap > separation)) return impact.time;
            if (last_gap > separation) continue;
            ContactInterval numerator = physics::contact_subtract(
                first: physics::contact_value(first_gap),
                second: physics::contact_value(separation),
            )!;
            ContactInterval denominator = physics::contact_subtract(
                first: physics::contact_value(first_gap),
                second: physics::contact_value(last_gap),
            )!;
            fraction = math::min(
                x: fraction,
                y: physics::contact_multiply(
                    first: physics::contact_value(CLOTH_ADVANCE_FRACTION),
                    second: physics::contact_divide(numerator, denominator)!,
                )!.min
            );
        }
    }
    if (fraction == 1) return end;
    return physics::contact_add(
        first: physics::contact_value(impact.time),
        second: physics::contact_multiply(
            first: physics::contact_subtract(physics::contact_value(end), physics::contact_value(impact.time))!,
            second: physics::contact_value(fraction),
        )!,
    )!.min;
}

fn void? respond_self_path(ClothState* state, ClothImpact impact) @local {
    ContactVector[4] starts;
    evaluate_paths(state, physics::contact_value(impact.time))!;
    foreach (index, vertex : impact.vertices) starts[index] = physics::contact_middle(
        value: state.path_values[state.path_heads[vertex]],
    );
    double squared = impact.direction.dot(impact.direction);
    if (!(squared > 0) || !math::is_finite(squared)) return CONTACT_PRECISION_EXCEEDED~;

    if (torn_seam_contact(state, impact)) balance_self_coefficients(state, &impact, starts)!;

    double impulse = self_path_impulse(
        state: state,
        impact: impact,
        starts: starts,
        time: 1,
    )!;
    for (usz index = state.path_heads.len; index < state.path_count; index++) {
        ClothPathNode* node = &state.path_nodes[index];
        if (node.kind != OFFSET || node.begin <= impact.time) continue;
        impulse = math::max(impulse, self_path_impulse(
            state: state,
            impact: impact,
            starts: starts,
            time: node.begin,
        )!);
    }
    if (!(impulse > 0)) return CONTACT_UNRESOLVED~;
    if (!math::is_finite(impulse)) return CONTACT_PRECISION_EXCEEDED~;

    foreach (index, vertex : impact.vertices) {
        double weight = state.inverse_masses[vertex];
        if (weight == 0 || impact.coefficients[index] == 0) continue;
        append_offset_path(
            state: state,
            particle: vertex,
            displacement: impact.direction * (impulse * impact.coefficients[index] * weight),
            begin: impact.time,
        )!;
    }
}

fn bool torn_seam_contact(ClothState* state, ClothImpact impact) @local {
    if (!state.cut_paths.len) return false;

    for (uint first = 0; first < impact.first_count; first++) {
        uint first_base = state.particle_bases[impact.vertices[first]];
        for (uint second = impact.first_count; second < 4; second++) {
            if (state.particle_bases[impact.vertices[second]] == first_base) return true;
        }
    }
    return false;
}

fn void? balance_self_coefficients(
    ClothState* state,
    ClothImpact* impact,
    ContactVector[4] starts,
) @local {
    bool[4] active;
    bool needs_balance = mark_deficit_vertices(
        state:   state,
        impact:  *impact,
        starts:  starts,
        time:    1,
        active:  &active,
    )!;
    for (usz index = state.path_heads.len; index < state.path_count; index++) {
        ClothPathNode* node = &state.path_nodes[index];
        if (node.kind != OFFSET || node.begin <= impact.time) continue;
        needs_balance |= mark_deficit_vertices(
            state:   state,
            impact:  *impact,
            starts:  starts,
            time:    node.begin,
            active:  &active,
        )!;
    }
    if (!needs_balance) return;

    double first_sum;
    for (uint first = 0; first < impact.first_count; first++) {
        double share = impact.coefficients[first];
        if (active[first] && share < MIN_RESPONSE_SHARE) share = MIN_RESPONSE_SHARE;
        impact.coefficients[first] = share;
        first_sum += share;
    }
    if (first_sum > 0) {
        for (uint first = 0; first < impact.first_count; first++) {
            impact.coefficients[first] /= first_sum;
        }
    }

    double second_sum;
    for (uint second = impact.first_count; second < 4; second++) {
        double share = -impact.coefficients[second];
        if (active[second] && share < MIN_RESPONSE_SHARE) share = MIN_RESPONSE_SHARE;
        impact.coefficients[second] = -share;
        second_sum += share;
    }
    if (second_sum > 0) {
        for (uint second = impact.first_count; second < 4; second++) {
            impact.coefficients[second] /= second_sum;
        }
    }
}

fn bool? mark_deficit_vertices(
    ClothState* state,
    ClothImpact impact,
    ContactVector[4] starts,
    double time,
    bool[4]* active,
) @local {
    evaluate_paths(state, physics::contact_value(time))!;
    double progress = (time - impact.time) / (1 - impact.time);
    double squared = impact.direction.dot(impact.direction);
    double target = (2.0 * state.desc.thickness + (double)state.desc.collisions.contact_tolerance / 4) * math::sqrt(squared);
    bool needs_balance;
    for (uint first = 0; first < impact.first_count; first++) {
        for (uint second = impact.first_count; second < 4; second++) {
            uint first_vertex = impact.vertices[first];
            uint second_vertex = impact.vertices[second];
            ContactVector delta = physics::contact_middle(state.path_values[state.path_heads[first_vertex]])
              - physics::contact_middle(state.path_values[state.path_heads[second_vertex]]);
            double initial = (starts[first] - starts[second]).dot(impact.direction);
            double deficit = initial * (1 - progress) + target * progress - delta.dot(impact.direction);
            if (deficit <= 0) continue;

            double first_mass = state.inverse_masses[first_vertex];
            double second_mass = state.inverse_masses[second_vertex];
            if (first_mass > 0) (*active)[first] = true;
            if (second_mass > 0) (*active)[second] = true;
            double weight = first_mass * impact.coefficients[first]
              - second_mass * impact.coefficients[second];
            if (weight < MIN_RESPONSE_SHARE * (first_mass + second_mass)) {
                needs_balance = true;
            }
        }
    }
    return needs_balance;
}

fn double? self_path_impulse(
    ClothState* state,
    ClothImpact impact,
    ContactVector[4] starts,
    double time,
) @local {
    evaluate_paths(state, physics::contact_value(time))!;
    double progress = (time - impact.time) / (1 - impact.time);
    double squared = impact.direction.dot(impact.direction);
    double target = (2.0 * state.desc.thickness + (double)state.desc.collisions.contact_tolerance / 4) * math::sqrt(squared);
    double impulse;
    for (uint first = 0; first < impact.first_count; first++) {
        for (uint second = impact.first_count; second < 4; second++) {
            uint first_vertex = impact.vertices[first];
            uint second_vertex = impact.vertices[second];
            ContactVector delta = physics::contact_middle(state.path_values[state.path_heads[first_vertex]])
              - physics::contact_middle(state.path_values[state.path_heads[second_vertex]]);
            double initial = (starts[first] - starts[second]).dot(impact.direction);
            double deficit = initial * (1 - progress) + target * progress - delta.dot(impact.direction);
            if (deficit <= 0) continue;
            double weight = state.inverse_masses[first_vertex] * impact.coefficients[first]
              - state.inverse_masses[second_vertex] * impact.coefficients[second];
            if (!(weight > 0)) return CONTACT_UNRESOLVED~;
            impulse = math::max(impulse, deficit / (weight * squared * progress));
        }
    }
    return impulse;
}

fn void? filter_displacement(
    PhysicsWorld* world,
    ClothState* state,
    Vec3[] start,
    Vec3[] proposed,
    double begin,
    double end,
) @private {
    if (!state.desc.collisions.continuous) return;
    time::Clock filter_started = clock::now();
    defer measure_add(FILTER_ALL, filter_started);
    start_paths(
        state: state,
        start: start,
        end: proposed,
        begin: begin,
        finish: end,
    )!;
    state.sweep_active = true;
    defer state.sweep_active = false;

    uint responses;
    while (true) {
        state.contact_result.stage = ClothContactStage.CANDIDATES;
        path_bounds(state)!;
        usz candidates = physics::gather_cloth_candidates(world, state, proposed)!;
        candidates = gather_self_candidates(state, proposed, candidates)!;
        state.contact_result.stage = ClothContactStage.CONTACTS;

        ClothImpact earliest = { .time = 1 };
        ClothCandidate obstacle;
        uint contacts;
        foreach (&candidate : state.candidates[:candidates]) {
            if (!self_candidate(*candidate) && state.inverse_masses[candidate.particle] == 0) continue;
            ClothImpact impact = sweep_candidate(world, state, candidate)!;
            if (!impact.hit) continue;
            if (contacts == state.contacts.len) return c3d::CAPACITY_EXCEEDED~;
            contacts++;
            state.contact_result.contacts++;
            state.contact_result.peak_contacts = math::max(state.contact_result.peak_contacts, contacts);
            if (!earliest.hit || impact.time < earliest.time) {
                earliest = impact;
                obstacle = *candidate;
            }
        }
        if (!earliest.hit) break;

        state.contact_result.stage = ClothContactStage.RESOLVE;
        if (responses == state.contacts.len) {
            state.contact_result.stage = ClothContactStage.CONTACTS;
            return c3d::CAPACITY_EXCEEDED~;
        }
        responses++;
        state.contact_result.peak_contacts = math::max(state.contact_result.peak_contacts, responses);
        state.contact_result.impacts++;
        if (obstacle.kind == SELF_VERTEX_FACE) state.contact_result.vertex_face_impacts++;
        if (obstacle.kind == SELF_EDGE_EDGE) state.contact_result.edge_edge_impacts++;
        if (self_candidate(obstacle)) {
            respond_self_path(state, earliest)!;
        } else {
            append_plane_path(
                world: world,
                state: state,
                candidate: obstacle,
                direction: earliest.direction,
                time: earliest.time,
            )!;
        }
        state.contact_result.resweeps++;
    }

    evaluate_paths(state, physics::contact_value(1))!;
    foreach (particle, head : state.path_heads) {
        ContactIntervals endpoint = state.path_values[head];
        Vec3 rounded = (Vec3)physics::contact_middle(endpoint);
        double error = physics::contact_length(
            value: physics::contact_vector_subtract(physics::contact_vector((ContactVector)rounded), endpoint)!,
        )!.max;
        if (!finite_vector(rounded) || error > (double)state.desc.collisions.contact_tolerance / 8) return CONTACT_PRECISION_EXCEEDED~;
        if (state.inverse_masses[particle] == 0 && rounded != proposed[particle]) return CONTACT_PRECISION_EXCEEDED~;
        proposed[particle] = rounded;
    }
}
