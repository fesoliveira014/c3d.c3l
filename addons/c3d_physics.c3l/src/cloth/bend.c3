module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;

const double MIN_HINGE_EDGE @local = 1e-8; // metres; a shorter hinge axis has no stable unit direction
const double MIN_HINGE_GRADIENT @local = 1e-12; // rad^2/m^2 floor before XPBD scalar division
const double HALF_TURN_TIE_EPSILON @local = 1e-15; // radians; snaps the -pi half-turn tie onto +pi
const double MAX_HINGE_START_OFFSET @local = math::PI * 0.5; // radians; a path start further from the tracked angle is unresolved
const double MAX_HINGE_PROJECTION_TURN @local = 1.25; // radians; bounds one Newton step and the solver's turn away from the committed angle per substep, keeping the unwrap on the committed branch
const usz MAX_HINGE_SUBDIVISIONS @local = 64; // interval stack bound; cost linear in bisections per hinge

<* Bending constraint formulation across interior triangle hinges. *>
enum ClothBendMode : uint {
    DISTANCE,
    DIHEDRAL,
}

<* Explicit rest dihedral angle override on an interior physical edge. *>
struct ClothRestAngle {
    uint  first;
    uint  second;
    float angle;
}

<* Oriented interior physical edge and adjacent opposite vertices for dihedral bending. *>
struct ClothHinge {
    uint  p0;
    uint  p1;
    uint  p2;
    uint  p3;
    float rest_angle;
    float last_angle;
    float lambda;
}

struct ClothHingeSample @private {
    double           angle;
    ContactVector[4] gradients;
}

struct ClothHingeFrame @local {
    ContactVector edge_vector;
    ContactVector first_wing;
    ContactVector second_wing;
    ContactVector edge_axis;
    ContactVector n0;
    ContactVector n1;
    ContactVector normal_cross;
    double        edge_length;
    double        area0;
    double        area1;
    double        sine;
    double        cosine;
    double        angle;
}

fn void? check_bend_desc(ClothDesc desc) @private {
    if ((uint)desc.bend_mode > (uint)ClothBendMode.DIHEDRAL) return c3d::INVALID_ARGUMENT~;
    if (!(desc.bend_compliance >= 0) || !math::is_finite(desc.bend_compliance)) return c3d::INVALID_ARGUMENT~;
    if (desc.bend_mode == DISTANCE && (desc.bend_compliance > 0 || desc.rest_angles.len > 0)) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (index, entry : desc.rest_angles) {
        if (entry.first >= entry.second) return c3d::INVALID_ARGUMENT~;
        if (!math::is_finite(entry.angle) || !(entry.angle > -(float)math::PI) || !(entry.angle <= (float)math::PI)) {
            return c3d::INVALID_ARGUMENT~;
        }
        foreach (earlier : desc.rest_angles[:index]) {
            if (earlier.first == entry.first && earlier.second == entry.second) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn double wrap_dihedral_angle(double angle) @private {
    double wrapped = angle;
    while (wrapped <= -math::PI) wrapped += 2.0 * math::PI;
    while (wrapped > math::PI) wrapped -= 2.0 * math::PI;
    if (math::abs(wrapped + math::PI) <= HALF_TURN_TIE_EPSILON) return math::PI;
    return wrapped;
}

fn ClothHingeFrame? evaluate_hinge_frame(Vec3[4] points) @local {
    foreach (point : points) {
        if (!finite_vector(point)) return BEND_UNRESOLVED~;
    }

    ContactVector p0 = (ContactVector)points[0];
    ClothHingeFrame frame = {
        .edge_vector = (ContactVector)points[1] - p0,
        .first_wing  = (ContactVector)points[2] - p0,
        .second_wing = (ContactVector)points[3] - p0,
    };

    frame.edge_length = frame.edge_vector.length();
    if (!(frame.edge_length > MIN_HINGE_EDGE) || !math::is_finite(frame.edge_length)) return BEND_UNRESOLVED~;
    frame.edge_axis = frame.edge_vector / frame.edge_length;

    ContactVector n0_raw = frame.edge_vector.cross(frame.first_wing);
    ContactVector n1_raw = frame.second_wing.cross(frame.edge_vector);
    frame.area0 = n0_raw.length();
    frame.area1 = n1_raw.length();
    if (!(frame.area0 > 2.0 * MIN_TRIANGLE_AREA) || !(frame.area1 > 2.0 * MIN_TRIANGLE_AREA)
        || !math::is_finite(frame.area0) || !math::is_finite(frame.area1)) {
        return BEND_UNRESOLVED~;
    }

    frame.n0 = n0_raw / frame.area0;
    frame.n1 = n1_raw / frame.area1;
    frame.normal_cross = frame.n0.cross(frame.n1);
    frame.sine = frame.edge_axis.dot(frame.normal_cross);
    frame.cosine = frame.n0.dot(frame.n1);
    frame.angle = math::abs(frame.sine) <= HALF_TURN_TIE_EPSILON && frame.cosine < 0
      ? math::PI
      : math::atan2(frame.sine, frame.cosine);
    return frame;
}

fn double? evaluate_hinge_angle(Vec3[4] points) @private {
    return evaluate_hinge_frame(points).angle;
}

fn ClothHingeSample? evaluate_hinge_sample(Vec3[4] points) @private {
    ClothHingeFrame frame = evaluate_hinge_frame(points)!;

    ClothHingeSample sample = { .angle = frame.angle };
    for (uint vertex = 0; vertex < 4; vertex++) {
        for (uint axis = 0; axis < 3; axis++) {
            ContactVector basis;
            basis[axis] = 1.0;

            ContactVector d_edge = vertex == 0 ? -basis : (vertex == 1 ? basis : (ContactVector){});
            ContactVector d_first = vertex == 0 ? -basis : (vertex == 2 ? basis : (ContactVector){});
            ContactVector d_second = vertex == 0 ? -basis : (vertex == 3 ? basis : (ContactVector){});

            ContactVector dn0_raw = d_edge.cross(frame.first_wing) + frame.edge_vector.cross(d_first);
            ContactVector dn1_raw = d_second.cross(frame.edge_vector) + frame.second_wing.cross(d_edge);

            ContactVector d_axis = (d_edge - frame.edge_axis * frame.edge_axis.dot(d_edge)) / frame.edge_length;
            ContactVector dn0 = (dn0_raw - frame.n0 * frame.n0.dot(dn0_raw)) / frame.area0;
            ContactVector dn1 = (dn1_raw - frame.n1 * frame.n1.dot(dn1_raw)) / frame.area1;

            double d_sine = d_axis.dot(frame.normal_cross)
              + frame.edge_axis.dot(dn0.cross(frame.n1) + frame.n0.cross(dn1));
            double d_cosine = dn0.dot(frame.n1) + frame.n0.dot(dn1);
            // Unit normals orthogonal to the unit axis keep sine^2 + cosine^2 == 1, the atan2 denominator.
            double d_angle = frame.cosine * d_sine - frame.sine * d_cosine;
            if (!math::is_finite(d_angle)) return BEND_UNRESOLVED~;
            sample.gradients[vertex][axis] = d_angle;
        }
    }

    return sample;
}

fn ContactIntervals? hinge_interval_cross(ContactIntervals first, ContactIntervals second) @local {
    return {
        physics::contact_subtract(
            physics::contact_multiply(first[1], second[2])!,
            physics::contact_multiply(first[2], second[1])!,
        )!,
        physics::contact_subtract(
            physics::contact_multiply(first[2], second[0])!,
            physics::contact_multiply(first[0], second[2])!,
        )!,
        physics::contact_subtract(
            physics::contact_multiply(first[0], second[1])!,
            physics::contact_multiply(first[1], second[0])!,
        )!,
    };
}

fn ContactIntervals? hinge_edge_interval(
    Vec3 start_edge,
    Vec3 end_edge,
    ContactInterval span,
) @local {
    ContactVector base = (ContactVector)start_edge;
    ContactVector delta = (ContactVector)end_edge - base;
    return physics::contact_vector_add(
        physics::contact_vector(base),
        physics::contact_vector_scale(physics::contact_vector(delta), span)!,
    );
}

fn float? certify_hinge_path(
    Vec3[4] start_points,
    Vec3[4] end_points,
    float last_angle,
) @private {
    double start_angle = evaluate_hinge_angle(start_points)!;
    double initial_offset = wrap_dihedral_angle(start_angle - (double)last_angle);
    if (math::abs(initial_offset) >= MAX_HINGE_START_OFFSET) return BEND_UNRESOLVED~;

    bool moved;
    for (uint index = 0; index < 4; index++) {
        moved |= start_points[index] != end_points[index];
    }
    if (!moved) return (float)((double)last_angle + initial_offset);

    ContactInterval[MAX_HINGE_SUBDIVISIONS] stack;
    stack[0] = { .min = 0.0, .max = 1.0 };
    usz pending = 1;
    usz steps;
    double previous_angle = start_angle;
    double total_turn;
    double min_area_squared = 4.0 * (double)MIN_TRIANGLE_AREA * (double)MIN_TRIANGLE_AREA;

    Vec3 start_edge = start_points[1] - start_points[0];
    Vec3 end_edge = end_points[1] - end_points[0];
    Vec3 start_first = start_points[2] - start_points[0];
    Vec3 end_first = end_points[2] - end_points[0];
    Vec3 start_second = start_points[3] - start_points[0];
    Vec3 end_second = end_points[3] - end_points[0];

    while (pending > 0) {
        steps++;
        if (steps > MAX_HINGE_SUBDIVISIONS) return BEND_UNRESOLVED~;

        ContactInterval span = stack[--pending];

        ContactIntervals edge_interval = hinge_edge_interval(start_edge, end_edge, span)!;
        ContactIntervals first_interval = hinge_edge_interval(start_first, end_first, span)!;
        ContactIntervals second_interval = hinge_edge_interval(start_second, end_second, span)!;

        ContactIntervals n0 = hinge_interval_cross(edge_interval, first_interval)!;
        ContactIntervals n1 = hinge_interval_cross(second_interval, edge_interval)!;
        ContactIntervals normal_cross = hinge_interval_cross(n0, n1)!;

        ContactInterval edge_length_squared = physics::contact_dot(edge_interval, edge_interval)!;
        ContactInterval area0_squared = physics::contact_dot(n0, n0)!;
        ContactInterval area1_squared = physics::contact_dot(n1, n1)!;
        ContactInterval cosine_interval = physics::contact_dot(n0, n1)!;
        ContactInterval sine_interval = physics::contact_dot(edge_interval, normal_cross)!;

        bool non_degenerate = edge_length_squared.min > MIN_HINGE_EDGE * MIN_HINGE_EDGE
          && area0_squared.min > min_area_squared
          && area1_squared.min > min_area_squared;
        bool branch_safe = cosine_interval.min > 0 || cosine_interval.max < 0
          || sine_interval.min > 0 || sine_interval.max < 0;

        if (non_degenerate && branch_safe) {
            float progress = (float)span.max;
            Vec3[4] sub_end;
            for (uint index = 0; index < 4; index++) {
                sub_end[index] = start_points[index] + (end_points[index] - start_points[index]) * progress;
            }
            double sub_angle = evaluate_hinge_angle(sub_end)!;
            total_turn += wrap_dihedral_angle(sub_angle - previous_angle);
            if (math::abs(total_turn) >= math::PI) return BEND_UNRESOLVED~;
            previous_angle = sub_angle;
            continue;
        }

        double midpoint = 0.5 * (span.min + span.max);
        if (midpoint <= span.min || midpoint >= span.max || pending + 2 > stack.len) return BEND_UNRESOLVED~;
        stack[pending++] = { .min = midpoint, .max = span.max };
        stack[pending++] = { .min = span.min, .max = midpoint };
    }

    double unwrapped_end = (double)last_angle + initial_offset + total_turn;
    if (!math::is_finite(unwrapped_end)) return BEND_UNRESOLVED~;
    return (float)unwrapped_end;
}

fn void? reseed_hinge_angles(ClothState* state) @private {
    foreach (index, &hinge : state.hinges) {
        Vec3[4] points = {
            state.positions[hinge.p0],
            state.positions[hinge.p1],
            state.positions[hinge.p2],
            state.positions[hinge.p3],
        };
        double? angle = evaluate_hinge_angle(points);
        if (catch angle) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        hinge.last_angle = (float)angle;
        if (index < state.interior_edges.len) state.interior_edges[index].base_hinge.last_angle = hinge.last_angle;
    }
}

fn void? project_dihedral_bends(ClothState* state, float dt) @private {
    if (!state.hinges.len) return;
    double step_squared = (double)dt * (double)dt;
    double alpha_h = state.desc.bend_compliance > 0 ? (double)state.desc.bend_compliance / step_squared : 0.0;

    foreach (&hinge : state.hinges) {
        uint[4] indices = { hinge.p0, hinge.p1, hinge.p2, hinge.p3 };
        Vec3[4] start_points;
        double[4] weights;
        for (uint corner = 0; corner < 4; corner++) {
            start_points[corner] = state.predicted[indices[corner]];
            weights[corner] = (double)state.inverse_masses[indices[corner]];
        }

        ClothHingeSample? evaluated = evaluate_hinge_sample(start_points);
        if (catch evaluated) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        double weight_sum = weights[0] + weights[1] + weights[2] + weights[3];
        if (weight_sum == 0) continue;

        double gradient_sum;
        for (uint corner = 0; corner < 4; corner++) {
            gradient_sum += weights[corner] * evaluated.gradients[corner].dot(evaluated.gradients[corner]);
        }
        if (!math::is_finite(gradient_sum) || !(gradient_sum > MIN_HINGE_GRADIENT)) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        double committed_angle = (double)hinge.last_angle;
        double unwrapped_angle = committed_angle + wrap_dihedral_angle(evaluated.angle - committed_angle);
        double residual = unwrapped_angle - (double)hinge.rest_angle;
        double delta_lambda = -(residual + alpha_h * (double)hinge.lambda) / (gradient_sum + alpha_h);

        // Bounding the turn, not the target, keeps the compliant equilibrium; the window stops a
        // substep from turning past pi, where the unwrap against the committed angle would flip branch.
        double linear_turn = gradient_sum * delta_lambda;
        double committed_offset = unwrapped_angle - committed_angle;
        double allowed_turn = committed_offset * linear_turn > 0
          ? math::max(0.0, MAX_HINGE_PROJECTION_TURN - math::abs(committed_offset))
          : MAX_HINGE_PROJECTION_TURN;
        if (math::abs(linear_turn) > allowed_turn) {
            delta_lambda *= allowed_turn / math::abs(linear_turn);
        }

        double next_lambda = (double)hinge.lambda + delta_lambda;
        if (!math::is_finite(delta_lambda) || !math::is_finite(next_lambda) || !math::is_finite((float)next_lambda)) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        Vec3[4] end_points;
        for (uint corner = 0; corner < 4; corner++) {
            if (weights[corner] == 0) {
                end_points[corner] = start_points[corner];
                continue;
            }
            ContactVector corrected = (ContactVector)start_points[corner]
              + evaluated.gradients[corner] * (weights[corner] * delta_lambda);
            Vec3 rounded = (Vec3)corrected;
            if (!finite_vector(rounded)) {
                state.contact_result.stage = ClothContactStage.BEND;
                return BEND_UNRESOLVED~;
            }
            end_points[corner] = rounded;
        }

        if (catch certify_hinge_path(start_points, end_points, (float)unwrapped_angle)) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        hinge.lambda = (float)next_lambda;
        for (uint corner = 0; corner < 4; corner++) {
            state.predicted[indices[corner]] = end_points[corner];
        }
    }
}
