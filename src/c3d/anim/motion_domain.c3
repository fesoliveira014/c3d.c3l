module c3d::anim;

import c3d;
import std::math;

const double MOTION_SCALE_EPSILON @local = 1e-5; // Relative component tolerance of a uniform scale.

enum ConsumedScaleDomain @private {
    ADMITTED,
    SAMPLING_UNPROVEN,
}

fn void? validate_motion_rotation_track(Track* track) @private {
    validate_motion_track_storage(track, TargetPath.ROTATION)!;

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        bool nonzero;
        foreach (component : value) nonzero |= component != 0;
        if (!nonzero) return c3d::INVALID_ARGUMENT~;
    }
}

// A result rather than a fault lets the caller check every track for INVALID_ARGUMENT first.
fn ConsumedScaleDomain? classify_consumed_scale_track(Track* track, bool additive) @private {
    validate_motion_track_storage(track, TargetPath.SCALE)!;

    float[] reference = motion_domain_key(track, 0, CUBIC_SLOT_VALUE);

    uint key_count = (uint)track.times.len;
    for (uint key = 0; key < key_count; key++) {
        float[] value = motion_domain_key(track, (uint)key, CUBIC_SLOT_VALUE);
        if (additive) {
            for (uint component = 0; component < 3; component++) {
                if (value[component] != reference[component]) return c3d::INVALID_ARGUMENT~;
            }
        } else {
            for (uint component = 0; component < 3; component++) {
                if (!(value[component] > 0)) return c3d::INVALID_ARGUMENT~;
            }

            if (!motion_scale_uniform(value)) return c3d::INVALID_ARGUMENT~;
        }
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            return ConsumedScaleDomain.ADMITTED;
        case CUBIC_SPLINE:
            return ConsumedScaleDomain.SAMPLING_UNPROVEN;
    }
}

fn void? validate_motion_track_storage(Track* track, TargetPath path) @local {
    usz stride = path == TargetPath.ROTATION ? 4 : 3;
    usz slots = track.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOTS_PER_KEY : 1;
    if (track.path != path || track.times.len == 0 || track.times.len > uint::max
        || track.times.len > usz::max / (slots * stride)
        || track.values.len != track.times.len * slots * stride) return c3d::INVALID_ARGUMENT~;

    foreach (key, time : track.times) {
        if (!math::is_finite(time) || (key && time <= track.times[key - 1])) return c3d::INVALID_ARGUMENT~;
    }

    foreach (value : track.values) {
        if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
}

fn float[] motion_domain_key(Track* track, uint key, uint slot) @local {
    usz stride = track.stride();
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? ((usz)key * CUBIC_SLOTS_PER_KEY + slot) * stride : (usz)key * stride;

    return track.values[offset : stride];
}

fn bool motion_scale_uniform(float[] value) @local {
    foreach (smaller : value) foreach (larger : value) {
        if (smaller >= larger) continue;
        if ((double)smaller < (double)larger * 0.5) return false;

        // Within a factor of two the difference is exact, and the single fma rounding keeps its sign.
        if (math::fma((double)larger, MOTION_SCALE_EPSILON, (double)smaller - (double)larger) < 0) return false;
    }

    return true;
}
