module c3d::anim;

import std::math;

const double DOUBLE_NLERP_DOT_THRESHOLD @private = (double)0.95f; // Mirrors the standard quaternion slerp fallback.
const float LEAD_SECONDS @private = 1.0f / 256; // Short against key spacing; long against float time rounding.

enum StepSampleSide @private {
    EXACT,
    LEFT,
    RIGHT,
}

// FORWARD advances fades and every clock that stays on its clip; BACKWARD steps back the looping clocks
// that would cross their clip end, holding everything else.
enum LeadStep @private {
    NONE,
    FORWARD,
    BACKWARD,
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
 @require track.key_count() > 0
 @require value.len == track.stride() && value.len <= 4
 @require math::is_finite(time)
*>
fn void sample_track_double(
    Track* track,
    float time,
    uint* cursor,
    double[] value,
    StepSampleSide side = StepSampleSide.EXACT,
) @private {
    uint last = track.key_count() - 1;
    if (!last || time < track.key_time(0) || time > track.key_time(last)) {
        *cursor = time < track.key_time(0) ? 0 : last;
        copy_key_double(track, *cursor, value);
        if (track.path == TargetPath.ROTATION) normalize_rotation_double(value);
        return;
    }

    if (time == track.key_time(0)) {
        *cursor = 0;
    } else if (time == track.key_time(last)) {
        *cursor = last;
    } else if (*cursor >= last || time < track.key_time(*cursor)) {
        uint low;
        uint high = last;
        while (high - low > 1) {
            uint middle = (low + high) / 2;
            if (track.key_time(middle) <= time) {
                low = middle;
            } else {
                high = middle;
            }
        }
        *cursor = low;
    } else {
        while (track.key_time(*cursor + 1) <= time) (*cursor)++;
    }

    uint key = *cursor;
    if (track.interpolation == Interpolation.STEP) {
        uint sampled = key;
        if (side == StepSampleSide.LEFT && sampled && time == track.key_time(sampled)) sampled--;

        copy_key_double(track, sampled, value);
        if (track.path == TargetPath.ROTATION) normalize_rotation_double(value);
        return;
    }

    if (key == last) key--;
    double duration = (double)track.key_time(key + 1) - (double)track.key_time(key);
    double fraction = ((double)time - (double)track.key_time(key)) / duration;

    switch (track.interpolation) {
        case STEP: unreachable();
        case LINEAR:
            interpolate_linear_double(
                track: track,
                key: key,
                fraction: fraction,
                value: value,
            );
        case CUBIC_SPLINE:
            interpolate_cubic_double(
                track: track,
                key: key,
                fraction: fraction,
                duration: duration,
                value: value,
            );
    }

    if (track.path == TargetPath.ROTATION) normalize_rotation_double(value);
}

<* @require track.key_count() > 0 && out.len == track.stride() *>
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
    if (!*cursor || time != track.key_time(*cursor)) return;

    track.read_key(*cursor - 1, track.value_slot(), out);
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

fn ClipTime action_clip_time(
    Action* action,
    AnimationClip* clip,
    bool onset,
    LeadStep lead = LeadStep.NONE,
) @private {
    ClipTime sampled = { .time = action.time, .ahead = action.time, .side = action_sample_side(action, onset) };
    double rate = action_clock_rate(action);
    if (lead == LeadStep.NONE || rate == 0) return sampled;
    if ((lead == LeadStep.BACKWARD) != lead_crosses_clip_end(action, clip)) return sampled;

    double step = lead == LeadStep.FORWARD ? LEAD_SECONDS : -LEAD_SECONDS;
    sampled.ahead = (float)math::clamp((double)action.time + rate * step, 0.0, (double)clip.duration);
    return sampled;
}

fn bool lead_crosses_clip_end(Action* action, AnimationClip* clip) @private {
    if (!action.loop && !action.blend_space) return false;

    double ahead = (double)action.time + action_clock_rate(action) * LEAD_SECONDS;
    return ahead < 0 || ahead > (double)clip.duration;
}

fn float track_clip_time(Track* track, ClipTime time) @private {
    return track.interpolation == Interpolation.STEP ? time.time : time.ahead;
}

fn void copy_key_double(Track* track, uint key, double[] value) @private {
    float[4] stored;
    track.read_key(key, track.value_slot(), stored[..]);
    foreach (index, component : stored[:track.stride()]) value[index] = component;
}

fn void interpolate_linear_double(
    Track* track,
    uint key,
    double fraction,
    double[] value,
) @private {
    usz stride = track.stride();
    float[4] first_key;
    float[4] second_key;
    track.read_key(key, track.value_slot(), first_key[..]);
    track.read_key(key + 1, track.value_slot(), second_key[..]);
    float[] first = first_key[:stride];
    float[] second = second_key[:stride];
    if (track.path == TargetPath.ROTATION) {
        interpolate_rotation_double(
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

fn void interpolate_cubic_double(
    Track* track,
    uint key,
    double fraction,
    double duration,
    double[] value,
) @private {
    usz stride = track.stride();
    float[4] first_key;
    float[4] first_tangent;
    float[4] second_key;
    float[4] second_tangent;
    track.read_key(key, CUBIC_SLOT_VALUE, first_key[..]);
    track.read_key(key, CUBIC_SLOT_OUT_TANGENT, first_tangent[..]);
    track.read_key(key + 1, CUBIC_SLOT_VALUE, second_key[..]);
    track.read_key(key + 1, CUBIC_SLOT_IN_TANGENT, second_tangent[..]);
    float[] first = first_key[:stride];
    float[] second = second_key[:stride];

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

fn void interpolate_rotation_double(
    float[] first,
    float[] second,
    double fraction,
    double[] value,
) @private {
    double[<4>] from = unit_rotation_double({ first[0], first[1], first[2], first[3] });
    double[<4>] to = unit_rotation_double({ second[0], second[1], second[2], second[3] });
    double dot = from.dot(to);
    if (dot < 0) {
        to = -to;
        dot = -dot;
    }

    double[<4>] sampled;
    if (dot > DOUBLE_NLERP_DOT_THRESHOLD) {
        sampled = from + (to - from) * fraction;
    } else {
        double angle = math::acos(dot);
        double sine = math::sqrt(1 - dot * dot);
        sampled = from * (math::sin((1 - fraction) * angle) / sine) + to * (math::sin(fraction * angle) / sine);
    }

    for (uint component = 0; component < 4; component++) value[component] = sampled[component];
}

// A zero quaternion, such as a cubic segment crossing zero, samples as identity.
fn double[<4>] unit_rotation_double(double[<4>] rotation) @private {
    double maximum = math::max(math::max(math::abs(rotation.x), math::abs(rotation.y)),
      math::max(math::abs(rotation.z), math::abs(rotation.w)));
    if (maximum == 0) return { 0, 0, 0, 1 };

    double[<4>] scaled = rotation / maximum;

    return scaled / scaled.length();
}

fn void normalize_rotation_double(double[] value) @private {
    double[<4>] unit = unit_rotation_double({ value[0], value[1], value[2], value[3] });
    for (uint component = 0; component < 4; component++) value[component] = unit[component];
}
