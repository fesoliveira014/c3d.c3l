module c3d::anim;

import c3d::maths;
import std::math;

fn RootMotionDelta publish_inertial_root_motion(
    InertialRow* row,
    RootMotionDelta target,
    double target_twist,
    double[<3>] up,
    double[<3>] pivot,
    double dt,
) @private {
    if (dt == 0) return target;

    double[<3>] displacement = { target.translation.x, target.translation.y, target.translation.z };
    double twist = target_twist;
    if (row.control.active) {
        if (row.root.target_rate_pending) {
            row.root.residual_translation_rate = row.root.source_translation_rate - displacement / dt;
            row.root.residual_twist_rate = row.root.source_twist_rate - twist / dt;
            row.root.target_rate_pending = false;
        }

        InertialQuinticBasis basis = inertial_quintic_basis(row.control.elapsed / row.control.duration);
        displacement += row.root.residual_translation_rate * (basis.value * dt);
        twist += row.root.residual_twist_rate * (basis.value * dt);
        double[<3>] pivot_displacement = generalized_pivot_displacement(up, twist, pivot);
        double[<3>] represented = displacement - pivot_displacement;
        displacement = represented + pivot_displacement;
        Quaternion rotation = inertial_rotation_exp(up * twist);
        target = {
            .translation = inertial_publish_vector(displacement),
            .rotation = inertial_publish_rotation(rotation),
        };
    } else {
        row.root.target_rate_pending = false;
    }

    row.root.published_translation = { target.translation.x, target.translation.y, target.translation.z };
    row.root.published_twist = twist;
    row.root.latest_up = up;
    row.root.translation_rate = row.root.published_translation / dt;
    row.root.twist_rate = twist / dt;

    return target;
}

fn double[<3>] inertial_publication_up(InertialRow* row) @private {
    if (row.control.active) return row.root.source_up;

    return { 0, 1, 0 };
}
