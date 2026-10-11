module c3d::anim;

import c3d;
import std::math;

fn void? validate_multiplicative_scale(AnimationClip* clip) @private {
    foreach (&track : clip.tracks) {
        if (track.path != TargetPath.SCALE) continue;

        validate_multiplicative_scale_track(track)!;

        Vec3 reference = sample_multiplicative_scale_reference(track);
        if (!positive_scale_vector(reference)) return c3d::INVALID_ARGUMENT~;
    }
}

fn Vec3 sample_multiplicative_scale_reference(Track* track) @private {
    uint cursor;
    return sample_multiplicative_scale(track, 0, &cursor);
}

fn Vec3 sample_multiplicative_scale(Track* track, float time, uint* cursor) @private {
    uint last = (uint)track.times.len - 1;
    if (time <= track.times[0]) {
        *cursor = 0;
        return scale_key(track, 0, CUBIC_SLOT_VALUE);
    }

    if (time >= track.times[last]) {
        *cursor = last;
        return scale_key(track, last, CUBIC_SLOT_VALUE);
    }

    if (*cursor >= last || time < track.times[*cursor]) {
        uint low;
        uint high = last;
        while (high - low > 1) {
            uint middle = (low + high) / 2;
            if (track.times[middle] <= time) {
                low = middle;
            } else {
                high = middle;
            }
        }
        *cursor = low;
    } else {
        while (track.times[*cursor + 1] <= time) (*cursor)++;
    }

    uint key = *cursor;
    Vec3 start = scale_key(track, key, CUBIC_SLOT_VALUE);
    Vec3 end = scale_key(track, key + 1, CUBIC_SLOT_VALUE);
    double duration = (double)track.times[key + 1] - (double)track.times[key];
    double fraction = ((double)time - (double)track.times[key]) / duration;
    Vec3 result;

    switch (track.interpolation) {
        case STEP:
            return start;
        case LINEAR:
            for (uint component = 0; component < 3; component++) {
                result[component] = (float)((1 - fraction) * (double)start[component]
                  + fraction * (double)end[component]);
            }
        case CUBIC_SPLINE:
            Vec3 start_tangent = scale_key(track, key, CUBIC_SLOT_OUT_TANGENT);
            Vec3 end_tangent = scale_key(track, key + 1, CUBIC_SLOT_IN_TANGENT);
            double complement = 1 - fraction;
            double h00 = complement * complement * (1 + 2 * fraction);
            double h10 = fraction * complement * complement;
            double h01 = fraction * fraction * (3 - 2 * fraction);
            double h11 = -fraction * fraction * complement;

            for (uint component = 0; component < 3; component++) {
                result[component] = (float)(h00 * (double)start[component]
                  + h10 * duration * (double)start_tangent[component]
                  + h01 * (double)end[component]
                  + h11 * duration * (double)end_tangent[component]);
            }
    }

    return result;
}

fn void? validate_multiplicative_scale_track(Track* track) @local {
    usz slots = track.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOTS_PER_KEY : 1;
    if (track.times.len == 0 || track.times.len > uint::max
        || track.times.len > usz::max / (slots * 3)
        || track.values.len != track.times.len * slots * 3) return c3d::INVALID_ARGUMENT~;

    foreach (key, time : track.times) {
        if (!math::is_finite(time)
            || (key && time <= track.times[key - 1])) return c3d::INVALID_ARGUMENT~;

        if (!positive_scale_vector(scale_key(track, (uint)key, CUBIC_SLOT_VALUE))) {
            return c3d::INVALID_ARGUMENT~;
        }
    }

    switch (track.interpolation) {
        case STEP:
        case LINEAR:
            return;
        case CUBIC_SPLINE:
            foreach (value : track.values) {
                if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
            }

            return c3d::UNSUPPORTED~;
    }
}

fn Vec3 scale_key(Track* track, uint key, uint slot) @local {
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? ((usz)key * CUBIC_SLOTS_PER_KEY + slot) * 3 : (usz)key * 3;
    return { track.values[offset], track.values[offset + 1], track.values[offset + 2] };
}

fn bool positive_scale_vector(Vec3 scale) @local {
    return math::is_finite(scale.x) && math::is_finite(scale.y) && math::is_finite(scale.z)
      && scale.x > 0 && scale.y > 0 && scale.z > 0;
}
