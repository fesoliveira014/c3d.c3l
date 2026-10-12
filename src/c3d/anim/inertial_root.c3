module c3d::anim;

import c3d::maths;
import std::math;

fn RootMotionDelta publish_root_motion(
    PlaybackView* playback,
    PoseReport* report,
    Vec3 reference,
    double dt,
) @private {
    if (!report.generalized) {
        RootMotionDelta delta = root_motion_delta(report.motion, reference);
        if (!playback.inertial) return delta;

        return publish_inertial_root_motion(
            row: playback.inertial,
            target: delta,
            translation: inertial_pose_vector(delta.translation),
            twist: (double)report.motion.yaw,
            up: inertial_publication_up(playback.inertial),
            dt: dt,
        );
    }

    GeneralizedMotion motion = report.generalized_motion;
    double[<3>] up = generalized_chain_up(report.consumed_chain);
    RootMotionDelta delta = {
        .translation = inertial_publish_vector(motion.translation),
        .rotation = inertial_publish_rotation(inertial_rotation_exp(up * motion.twist)),
    };
    if (!playback.inertial) return delta;

    return publish_inertial_root_motion(
        row: playback.inertial,
        target: delta,
        translation: motion.translation,
        twist: motion.twist,
        up: up,
        dt: dt,
    );
}

// The double translation and twist of the target keep the residual sum to one rounding.
fn RootMotionDelta publish_inertial_root_motion(
    InertialRow* row,
    RootMotionDelta target,
    double[<3>] translation,
    double twist,
    double[<3>] up,
    double dt,
) @private {
    if (dt == 0) return target;

    if (row.control.active) {
        if (row.root.target_rate_pending) {
            row.root.residual_translation_rate = row.root.source_translation_rate - translation / dt;
            row.root.residual_twist_rate = row.root.source_twist_rate - twist / dt;
            row.root.target_rate_pending = false;
        }

        InertialQuinticBasis basis = inertial_quintic_basis(row.control.elapsed / row.control.duration);
        translation += row.root.residual_translation_rate * (basis.value * dt);
        twist += row.root.residual_twist_rate * (basis.value * dt);

        target = {
            .translation = inertial_publish_vector(translation),
            .rotation = inertial_publish_rotation(inertial_rotation_exp(up * twist)),
        };
    } else {
        row.root.target_rate_pending = false;
    }

    row.root.published_translation = inertial_pose_vector(target.translation);
    row.root.latest_up = up;
    row.root.translation_rate = row.root.published_translation / dt;
    row.root.twist_rate = twist / dt;

    return target;
}

fn double[<3>] inertial_publication_up(InertialRow* row) @private {
    if (row.control.active) return row.root.source_up;

    return { 0, 1, 0 };
}
