module c3d::anim;

import c3d::maths;
import std::math;

fn RootMotionDelta publish_generalized_owner_motion(
    PlaybackView* playback,
    PoseDestination destination,
    GeneralizedMotion motion,
    double dt,
    PoseScratch scratch,
) @private {
    GeneralizedPlaybackState* state = playback.generalized;
    double[<3>] up = { state.extraction.up.x, state.extraction.up.y, state.extraction.up.z };
    up /= up.length();

    if (playback.inertial && dt > 0) {
        InertialRow* row = playback.inertial;
        if (row.control.active) {
            if (row.root.target_rate_pending) {
                row.root.residual_translation_rate = row.root.source_translation_rate - motion.translation / dt;
                row.root.residual_twist_rate = row.root.source_twist_rate - motion.twist / dt;
                row.root.target_rate_pending = false;
            }

            InertialQuinticBasis basis = inertial_quintic_basis(row.control.elapsed / row.control.duration);
            motion.translation += row.root.residual_translation_rate * (basis.value * dt);
            motion.twist += row.root.residual_twist_rate * (basis.value * dt);
            double[<3>] pivot = generalized_pivot_displacement(up, motion.twist, row.root.pivot);
            motion.translation = (motion.translation - pivot) + pivot;
        }
    }

    RootMotionDelta published = {
        .translation = inertial_publish_vector(motion.translation),
        .rotation = inertial_publish_rotation(inertial_rotation_exp(up * motion.twist)),
    };

    if (playback.inertial && dt > 0) {
        InertialRow* row = playback.inertial;
        row.root.published_translation = { published.translation.x, published.translation.y, published.translation.z };
        row.root.published_twist = motion.twist;
        row.root.latest_up = up;
        row.root.translation_rate = row.root.published_translation / dt;
        row.root.twist_rate = motion.twist / dt;
        if (!row.control.active) row.root.target_rate_pending = false;
    }

    finish_generalized_playback(
        state: state,
        playback: playback,
        destination: destination,
        final_motion: motion,
        published: &published,
        dt: dt,
        velocity: scratch.derivative ? scratch.derivative.velocity : (PoseVelocity[]) {},
    );

    if (playback.inertial) {
        correct_inertial_pose(
            playback: playback,
            destination: destination,
            scratch: scratch,
            dt: 0,
        );
    }

    return published;
}
