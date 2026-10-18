module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;

const double MIN_HINGE_EDGE @local = 1e-8;
const double MIN_HINGE_TRIG @local = 0.25;
const double MIN_HINGE_GRADIENT @local = 1e-12;
const usz MAX_HINGE_SUBDIVISIONS @local = 64;

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
    if (math::abs(wrapped + math::PI) <= 1e-15) return math::PI;
    return wrapped;
}

fn ClothHingeSample? evaluate_hinge_sample(Vec3[4] points) @private {
    foreach (point : points) {
        if (!finite_vector(point)) return BEND_UNRESOLVED~;
    }

    ContactVector p0 = (ContactVector)points[0];
    ContactVector p1 = (ContactVector)points[1];
    ContactVector p2 = (ContactVector)points[2];
    ContactVector p3 = (ContactVector)points[3];

    ContactVector u = p1 - p0;
    ContactVector v = p2 - p0;
    ContactVector w = p3 - p0;

    double len_u = u.length();
    if (!(len_u > MIN_HINGE_EDGE) || !math::is_finite(len_u)) return BEND_UNRESOLVED~;
    ContactVector e = u / len_u;

    ContactVector n0_raw = u.cross(v);
    ContactVector n1_raw = w.cross(u);
    double area0 = n0_raw.length();
    double area1 = n1_raw.length();
    if (!(area0 > 2.0 * MIN_TRIANGLE_AREA) || !(area1 > 2.0 * MIN_TRIANGLE_AREA)
        || !math::is_finite(area0) || !math::is_finite(area1)) {
        return BEND_UNRESOLVED~;
    }

    ContactVector n0 = n0_raw / area0;
    ContactVector n1 = n1_raw / area1;
    ContactVector cross_n = n0.cross(n1);
    double s = e.dot(cross_n);
    double c = n0.dot(n1);
    double denom = s * s + c * c;
    if (!(denom > MIN_HINGE_TRIG) || !math::is_finite(denom)) return BEND_UNRESOLVED~;

    double angle = math::abs(s) <= 1e-15 && c < 0 ? math::PI : math::atan2(s, c);
    if (!math::is_finite(angle)) return BEND_UNRESOLVED~;

    ClothHingeSample sample = { .angle = angle };
    for (uint vertex = 0; vertex < 4; vertex++) {
        for (uint axis = 0; axis < 3; axis++) {
            ContactVector basis;
            basis[axis] = 1.0;

            ContactVector du = vertex == 0 ? -basis : (vertex == 1 ? basis : (ContactVector){});
            ContactVector dv = vertex == 0 ? -basis : (vertex == 2 ? basis : (ContactVector){});
            ContactVector dw = vertex == 0 ? -basis : (vertex == 3 ? basis : (ContactVector){});

            ContactVector dn0_raw = du.cross(v) + u.cross(dv);
            ContactVector dn1_raw = dw.cross(u) + w.cross(du);

            ContactVector de = (du - e * e.dot(du)) / len_u;
            ContactVector dn0 = (dn0_raw - n0 * n0.dot(dn0_raw)) / area0;
            ContactVector dn1 = (dn1_raw - n1 * n1.dot(dn1_raw)) / area1;

            double ds = de.dot(cross_n) + e.dot(dn0.cross(n1) + n0.cross(dn1));
            double dc = dn0.dot(n1) + n0.dot(dn1);
            double dtheta = (c * ds - s * dc) / denom;
            if (!math::is_finite(dtheta)) return BEND_UNRESOLVED~;
            sample.gradients[vertex][axis] = dtheta;
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
    ContactInterval t,
) @local {
    ContactVector base = (ContactVector)start_edge;
    ContactVector delta = (ContactVector)end_edge - base;
    return physics::contact_vector_add(
        physics::contact_vector(base),
        physics::contact_vector_scale(physics::contact_vector(delta), t)!,
    );
}

fn float? certify_hinge_path(
    Vec3[4] start_points,
    Vec3[4] end_points,
    float last_angle,
    uint max_steps,
) @private {
    if (!max_steps) return BEND_UNRESOLVED~;

    ClothHingeSample start_sample = evaluate_hinge_sample(start_points)!;
    ClothHingeSample end_sample = evaluate_hinge_sample(end_points)!;
    if (math::abs(wrap_dihedral_angle(start_sample.angle - (double)last_angle)) >= math::PI * 0.5) {
        return BEND_UNRESOLVED~;
    }

    bool moved;
    for (uint index = 0; index < 4; index++) {
        moved |= start_points[index] != end_points[index];
    }
    if (!moved) return (float)end_sample.angle;

    ContactInterval[MAX_HINGE_SUBDIVISIONS] stack;
    stack[0] = { .min = 0.0, .max = 1.0 };
    usz pending = 1;
    uint steps;
    uint step_budget = (uint)math::min((usz)max_steps * 8, MAX_HINGE_SUBDIVISIONS);
    double prev_angle = start_sample.angle;
    double total_turn;
    double min_area_sq = 4.0 * (double)MIN_TRIANGLE_AREA * (double)MIN_TRIANGLE_AREA;

    Vec3 start_u = start_points[1] - start_points[0];
    Vec3 end_u = end_points[1] - end_points[0];
    Vec3 start_v = start_points[2] - start_points[0];
    Vec3 end_v = end_points[2] - end_points[0];
    Vec3 start_w = start_points[3] - start_points[0];
    Vec3 end_w = end_points[3] - end_points[0];

    while (pending > 0) {
        steps++;
        if (steps > step_budget) return BEND_UNRESOLVED~;

        ContactInterval t = stack[--pending];

        ContactIntervals u = hinge_edge_interval(start_u, end_u, t)!;
        ContactIntervals v = hinge_edge_interval(start_v, end_v, t)!;
        ContactIntervals w = hinge_edge_interval(start_w, end_w, t)!;

        ContactIntervals n0 = hinge_interval_cross(u, v)!;
        ContactIntervals n1 = hinge_interval_cross(w, u)!;
        ContactIntervals cross_n = hinge_interval_cross(n0, n1)!;

        ContactInterval len_u_sq = physics::contact_dot(u, u)!;
        ContactInterval area0_sq = physics::contact_dot(n0, n0)!;
        ContactInterval area1_sq = physics::contact_dot(n1, n1)!;
        ContactInterval cos_int = physics::contact_dot(n0, n1)!;
        ContactInterval sin_int = physics::contact_dot(u, cross_n)!;

        bool non_degenerate = len_u_sq.min > MIN_HINGE_EDGE * MIN_HINGE_EDGE
          && area0_sq.min > min_area_sq
          && area1_sq.min > min_area_sq;
        bool branch_safe = cos_int.min > 0 || cos_int.max < 0 || sin_int.min > 0 || sin_int.max < 0;

        if (non_degenerate && branch_safe) {
            float progress = (float)t.max;
            Vec3[4] sub_end;
            for (uint index = 0; index < 4; index++) {
                sub_end[index] = start_points[index] + (end_points[index] - start_points[index]) * progress;
            }
            ClothHingeSample sub_sample = evaluate_hinge_sample(sub_end)!;
            double turn = wrap_dihedral_angle(sub_sample.angle - prev_angle);
            if (math::abs(turn) >= math::PI * 0.5) return BEND_UNRESOLVED~;
            total_turn += turn;
            if (math::abs(total_turn) >= math::PI) return BEND_UNRESOLVED~;
            prev_angle = sub_sample.angle;
            continue;
        }

        double mid = 0.5 * (t.min + t.max);
        if (mid <= t.min || mid >= t.max || pending + 2 > stack.len) return BEND_UNRESOLVED~;
        stack[pending++] = { .min = mid, .max = t.max };
        stack[pending++] = { .min = t.min, .max = mid };
    }

    return (float)end_sample.angle;
}

fn void? project_dihedral_bends(ClothState* state, float dt) @private {
    if (!state.hinges.len) return;
    double step_squared = (double)dt * (double)dt;
    if (!math::is_finite(step_squared) || !(step_squared > 0)) {
        state.contact_result.stage = ClothContactStage.BEND;
        return BEND_UNRESOLVED~;
    }

    double alpha_h;
    if (state.desc.bend_compliance > 0) {
        alpha_h = (double)state.desc.bend_compliance / step_squared;
        if (!math::is_finite(alpha_h) || !(alpha_h > 0)) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }
    }

    uint max_ccd = state.desc.collisions.max_ccd_iterations;
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

        double grad_sum;
        for (uint corner = 0; corner < 4; corner++) {
            grad_sum += weights[corner] * evaluated.gradients[corner].dot(evaluated.gradients[corner]);
        }
        double denominator = grad_sum + alpha_h;
        if (!math::is_finite(grad_sum) || !(grad_sum > MIN_HINGE_GRADIENT)
            || !math::is_finite(denominator) || !(denominator > 0)) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        double residual = wrap_dihedral_angle(evaluated.angle - (double)hinge.rest_angle);
        double delta_lambda = -(residual + alpha_h * (double)hinge.lambda) / denominator;
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

        if (catch certify_hinge_path(start_points, end_points, (float)evaluated.angle, max_ccd)) {
            state.contact_result.stage = ClothContactStage.BEND;
            return BEND_UNRESOLVED~;
        }

        hinge.lambda = (float)next_lambda;
        for (uint corner = 0; corner < 4; corner++) {
            state.predicted[indices[corner]] = end_points[corner];
        }
    }
}
