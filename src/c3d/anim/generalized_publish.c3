module c3d::anim;

fn RootMotionDelta publish_generalized_owner_motion(
    PlaybackView* playback,
    CapturedMotionChain* chain,
    GeneralizedMotion motion,
    double dt,
) @private {
    double[<3>] up = generalized_chain_up(chain);

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
        }
    }

    RootMotionDelta published = {
        .translation = inertial_publish_vector(motion.translation),
        .rotation = inertial_publish_rotation(inertial_rotation_exp(up * motion.twist)),
    };

    if (playback.inertial && dt > 0) {
        InertialRow* row = playback.inertial;
        row.root.published_translation = { published.translation.x, published.translation.y, published.translation.z };
        row.root.latest_up = up;
        row.root.translation_rate = row.root.published_translation / dt;
        row.root.twist_rate = motion.twist / dt;
        if (!row.control.active) row.root.target_rate_pending = false;
    }

    return published;
}
