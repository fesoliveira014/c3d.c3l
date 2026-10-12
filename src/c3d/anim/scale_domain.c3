module c3d::anim;

import c3d;
import std::math;

fn void? validate_multiplicative_scale(AnimationClip* clip) @private {
    bool unsupported;
    foreach (&track : clip.tracks) {
        if (track.path != TargetPath.SCALE) continue;

        for (uint key = 0; key < track.times.len; key++) {
            if (!positive_scale(analytic_key_values(track, key, CUBIC_SLOT_VALUE))) return c3d::INVALID_ARGUMENT~;
        }

        float[3] reference;
        uint cursor;
        sample_track(
            track: track,
            time: 0,
            cursor: &cursor,
            out: reference[..],
        );
        if (!positive_scale(reference[..])) return c3d::INVALID_ARGUMENT~;

        unsupported |= track.interpolation == Interpolation.CUBIC_SPLINE;
    }

    if (unsupported) return c3d::UNSUPPORTED~;
}

fn bool positive_scale(float[] scale) @local {
    foreach (component : scale) {
        if (!math::is_finite(component) || component <= 0) return false;
    }

    return true;
}
