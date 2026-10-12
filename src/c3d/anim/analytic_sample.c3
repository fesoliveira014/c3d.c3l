module c3d::anim;

import std::math;

const double ANALYTIC_NLERP_DOT_THRESHOLD @private = (double)0.95f; // Mirrors the standard quaternion slerp fallback.

enum StepSampleSide @private {
    EXACT,
    LEFT,
    RIGHT,
}

// STEP tracks keep `time` while the other tracks of the action sample at `ahead`.
struct ClipTime @private {
    float time;
    float ahead;
    StepSampleSide side;
}

<*
 @param [&in] track : "Ascending times."
 @param [&inout] cursor : "Normal key cursor; independent of boundary side."
 @param value : "One complete track stride."
 @require track.times.len > 0
 @require value.len == track.stride() && value.len <= 4
 @require math::is_finite(time)
*>
fn void sample_track_analytic(
    Track* track,
    float time,
    uint* cursor,
    double[] value,
    StepSampleSide side = StepSampleSide.EXACT,
) @private {
    uint last = (uint)track.times.len - 1;
    if (!last || time < track.times[0] || time > track.times[last]) {
        *cursor = time < track.times[0] ? 0 : last;
        analytic_copy_key(track, *cursor, value);
        if (track.path == TargetPath.ROTATION) analytic_normalize_rotation(value);
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
        if (track.path == TargetPath.ROTATION) analytic_normalize_rotation(value);
        return;
    }

    if (key == last) key--;
    double duration = (double)track.times[key + 1] - (double)track.times[key];
    double fraction = ((double)time - (double)track.times[key]) / duration;

    switch (track.interpolation) {
        case STEP: unreachable();
        case LINEAR:
            analytic_linear(
                track: track,
                key: key,
                fraction: fraction,
                value: value,
            );
        case CUBIC_SPLINE:
            analytic_cubic(
                track: track,
                key: key,
                fraction: fraction,
                duration: duration,
                value: value,
            );
    }

    if (track.path == TargetPath.ROTATION) analytic_normalize_rotation(value);
}

<* @require track.times.len > 0 && out.len == track.stride() *>
fn void sample_track_on_side(
    Track* track,
    float time,
    uint* cursor,
    float[] out,
    StepSampleSide side,
) @private {
    sample_track(
        track: track,
        time: time,
        cursor: cursor,
        out: out,
    );
    if (side != StepSampleSide.LEFT || track.interpolation != Interpolation.STEP) return;
    if (!*cursor || time != track.times[*cursor]) return;

    out[..] = analytic_key_values(track, *cursor - 1, CUBIC_SLOT_VALUE)[..];
}

fn double action_clock_rate(Action* action) @private {
    if (action.blend_space) return action.clock_rate;

    return action.playing ? (double)action.speed : 0;
}

fn StepSampleSide action_sample_side(Action* action, bool onset) @private {
    double rate = action_clock_rate(action);
    if (!onset || rate == 0) return StepSampleSide.EXACT;

    return rate < 0 ? StepSampleSide.LEFT : StepSampleSide.RIGHT;
}

<* @param lead : "Signed update seconds ahead of the clock; zero samples the current time." *>
fn ClipTime action_clip_time(
    Action* action,
    AnimationClip* clip,
    bool onset,
    float lead = 0,
) @private {
    ClipTime sampled = { .time = action.time, .ahead = action.time, .side = action_sample_side(action, onset) };
    double rate = action_clock_rate(action);
    if (lead == 0 || rate == 0) return sampled;

    // Clamping rather than wrapping keeps a loop seam out of the difference; the caller steps backward near one.
    sampled.ahead = (float)math::clamp((double)action.time + rate * lead, 0.0, (double)clip.duration);
    return sampled;
}

fn float track_clip_time(Track* track, ClipTime time) @private {
    return track.interpolation == Interpolation.STEP ? time.time : time.ahead;
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
    double[] value,
) @private {
    float[] first = analytic_key_values(track, key, CUBIC_SLOT_VALUE);
    float[] second = analytic_key_values(track, key + 1, CUBIC_SLOT_VALUE);
    if (track.path == TargetPath.ROTATION) {
        analytic_linear_rotation(
            first: first,
            second: second,
            fraction: fraction,
            value: value,
        );
        return;
    }

    foreach (index, component : first) {
        value[index] = (double)component + ((double)second[index] - (double)component) * fraction;
    }
}

fn void analytic_cubic(
    Track* track,
    uint key,
    double fraction,
    double duration,
    double[] value,
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

    foreach (index, component : first) {
        value[index] = h00 * component + h10 * duration * first_tangent[index]
          + h01 * second[index] + h11 * duration * second_tangent[index];
    }
}

fn void analytic_linear_rotation(
    float[] first,
    float[] second,
    double fraction,
    double[] value,
) @private {
    double[<4>] from = analytic_unit_rotation({ first[0], first[1], first[2], first[3] });
    double[<4>] to = analytic_unit_rotation({ second[0], second[1], second[2], second[3] });
    double dot = from.dot(to);
    if (dot < 0) {
        to = -to;
        dot = -dot;
    }

    double[<4>] sampled;
    if (dot > ANALYTIC_NLERP_DOT_THRESHOLD) {
        sampled = from + (to - from) * fraction;
    } else {
        double angle = math::acos(dot);
        double sine = math::sqrt(1 - dot * dot);
        sampled = from * (math::sin((1 - fraction) * angle) / sine) + to * (math::sin(fraction * angle) / sine);
    }

    for (uint component = 0; component < 4; component++) value[component] = sampled[component];
}

// A zero quaternion, such as a cubic segment crossing zero, samples as identity.
fn double[<4>] analytic_unit_rotation(double[<4>] rotation) @private {
    double maximum = math::max(math::max(math::abs(rotation.x), math::abs(rotation.y)),
      math::max(math::abs(rotation.z), math::abs(rotation.w)));
    if (maximum == 0) return { 0, 0, 0, 1 };

    double[<4>] scaled = rotation / maximum;

    return scaled / scaled.length();
}

fn void analytic_normalize_rotation(double[] value) @private {
    double[<4>] unit = analytic_unit_rotation({ value[0], value[1], value[2], value[3] });
    for (uint component = 0; component < 4; component++) value[component] = unit[component];
}
