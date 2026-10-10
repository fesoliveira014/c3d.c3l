module c3d::anim;

import std::math;

const double ANALYTIC_NLERP_DOT_THRESHOLD @private = (double)0.95f; // Mirrors the standard quaternion slerp fallback.

enum StepSampleSide @private {
    EXACT,
    LEFT,
    RIGHT,
}

<*
 Sample admitted track values and clip-time derivatives into prepared arrays.
 @param [&in] track : "Ascending times and admitted rotation domain."
 @param [&inout] cursor : "Normal key cursor; independent of boundary side."
 @param value : "One complete track stride."
 @param rate : "Derivative per clip second; caller applies clock rate."
 @require track.times.len > 0
 @require value.len == track.stride() && rate.len == value.len
 @require math::is_finite(time)
*>
fn void sample_track_analytic(
    Track* track,
    float time,
    uint* cursor,
    double[] value,
    double[] rate,
    StepSampleSide side = StepSampleSide.EXACT,
) @private {
    uint last = (uint)track.times.len - 1;
    rate[..] = 0;
    if (!last || time < track.times[0] || time > track.times[last]) {
        *cursor = time < track.times[0] ? 0 : last;
        analytic_copy_key(track, *cursor, value);
        if (track.path == TargetPath.ROTATION) analytic_normalize_rotation(value, rate);
        return;
    }

    if (time == track.times[0]) {
        *cursor = 0;
    } else if (time == track.times[last]) {
        *cursor = last;
    } else if (*cursor >= last || time < track.times[*cursor]) {
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
    if (track.interpolation == Interpolation.STEP) {
        uint sampled = key;
        if (side == StepSampleSide.LEFT && sampled && time == track.times[sampled]) sampled--;

        analytic_copy_key(track, sampled, value);
        if (track.path == TargetPath.ROTATION) analytic_normalize_rotation(value, rate);
        return;
    }

    if (key == last) key--;
    if (side == StepSampleSide.LEFT && *cursor && time == track.times[*cursor]) key = *cursor - 1;
    double duration = (double)track.times[key + 1] - (double)track.times[key];
    double fraction = ((double)time - (double)track.times[key]) / duration;

    switch (track.interpolation) {
        case STEP: unreachable();
        case LINEAR:
            analytic_linear(
                track: track,
                key: key,
                fraction: fraction,
                duration: duration,
                value: value,
                rate: rate,
            );
        case CUBIC_SPLINE:
            analytic_cubic(
                track: track,
                key: key,
                fraction: fraction,
                duration: duration,
                value: value,
                rate: rate,
            );
    }

    if (track.path == TargetPath.ROTATION) analytic_normalize_rotation(value, rate);
}

fn float[] analytic_key_values(Track* track, uint key, uint slot) @private {
    uint stride = track.stride();
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? (usz)(key * CUBIC_SLOTS_PER_KEY + slot) * stride : (usz)key * stride;

    return track.values[offset:stride];
}

fn void analytic_copy_key(Track* track, uint key, double[] value) @private {
    float[] stored = analytic_key_values(track, key, CUBIC_SLOT_VALUE);
    foreach (index, component : stored) value[index] = component;
}

fn void analytic_linear(
    Track* track,
    uint key,
    double fraction,
    double duration,
    double[] value,
    double[] rate,
) @private {
    float[] first = analytic_key_values(track, key, CUBIC_SLOT_VALUE);
    float[] second = analytic_key_values(track, key + 1, CUBIC_SLOT_VALUE);
    if (track.path == TargetPath.ROTATION) {
        analytic_linear_rotation(
            first: first,
            second: second,
            fraction: fraction,
            duration: duration,
            value: value,
            rate: rate,
        );
        return;
    }

    foreach (index, component : first) {
        double difference = (double)second[index] - (double)component;
        value[index] = (double)component + difference * fraction;
        rate[index] = difference / duration;
    }
}

fn void analytic_cubic(
    Track* track,
    uint key,
    double fraction,
    double duration,
    double[] value,
    double[] rate,
) @private {
    float[] first = analytic_key_values(track, key, CUBIC_SLOT_VALUE);
    float[] first_tangent = analytic_key_values(track, key, CUBIC_SLOT_OUT_TANGENT);
    float[] second = analytic_key_values(track, key + 1, CUBIC_SLOT_VALUE);
    float[] second_tangent = analytic_key_values(track, key + 1, CUBIC_SLOT_IN_TANGENT);
    double complement = 1 - fraction;
    double square = fraction * fraction;
    double h00 = complement * complement * (1 + 2 * fraction);
    double h10 = fraction * complement * complement;
    double h01 = square * (3 - 2 * fraction);
    double h11 = -square * complement;
    double h00_rate = -6 * fraction * complement / duration;
    double h10_rate = 3 * square - 4 * fraction + 1;
    double h01_rate = 6 * fraction * complement / duration;
    double h11_rate = 3 * square - 2 * fraction;

    foreach (index, component : first) {
        value[index] = h00 * component + h10 * duration * first_tangent[index]
          + h01 * second[index] + h11 * duration * second_tangent[index];
        rate[index] = h00_rate * component + h10_rate * first_tangent[index]
          + h01_rate * second[index] + h11_rate * second_tangent[index];
    }
}

fn void analytic_linear_rotation(
    float[] first,
    float[] second,
    double fraction,
    double duration,
    double[] value,
    double[] rate,
) @private {
    double[<4>] from = { first[0], first[1], first[2], first[3] };
    double[<4>] to = { second[0], second[1], second[2], second[3] };
    from = analytic_unit_rotation(from);
    to = analytic_unit_rotation(to);
    double dot = from.dot(to);
    if (dot < 0) {
        to = -to;
        dot = -dot;
    }

    double[<4>] sampled;
    double[<4>] derivative;
    if (dot > ANALYTIC_NLERP_DOT_THRESHOLD) {
        sampled = from + (to - from) * fraction;
        derivative = (to - from) / duration;
    } else {
        double angle = math::acos(dot);
        double sine = math::sqrt(1 - dot * dot);
        double first_weight = math::sin((1 - fraction) * angle) / sine;
        double second_weight = math::sin(fraction * angle) / sine;
        double first_rate = -angle * math::cos((1 - fraction) * angle) / (sine * duration);
        double second_rate = angle * math::cos(fraction * angle) / (sine * duration);
        sampled = from * first_weight + to * second_weight;
        derivative = from * first_rate + to * second_rate;
    }

    for (uint component = 0; component < 4; component++) {
        value[component] = sampled[component];
        rate[component] = derivative[component];
    }
}

<* Normalize admitted quaternion components without magnitude thresholds.
   @require rotation.x != 0 || rotation.y != 0 || rotation.z != 0 || rotation.w != 0 *>
fn double[<4>] analytic_unit_rotation(double[<4>] rotation) @private {
    double maximum = math::max(math::max(math::abs(rotation.x), math::abs(rotation.y)),
      math::max(math::abs(rotation.z), math::abs(rotation.w)));
    double[<4>] scaled = rotation / maximum;

    return scaled / scaled.length();
}

fn void analytic_normalize_rotation(double[] value, double[] rate) @private {
    double[<4>] rotation = { value[0], value[1], value[2], value[3] };
    double[<4>] derivative = { rate[0], rate[1], rate[2], rate[3] };
    double maximum = math::max(math::max(math::abs(rotation.x), math::abs(rotation.y)),
      math::max(math::abs(rotation.z), math::abs(rotation.w)));
    double[<4>] scaled = rotation / maximum;
    double length = scaled.length();
    double[<4>] unit = scaled / length;
    double[<4>] scaled_rate = derivative / maximum;
    double[<4>] unit_rate = (scaled_rate - unit * unit.dot(scaled_rate)) / length;

    for (uint component = 0; component < 4; component++) {
        value[component] = unit[component];
        rate[component] = unit_rate[component];
    }
}
