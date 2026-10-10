module c3d::anim;

import c3d;
import std::math;

struct BlendSpaceFade @private {
    float* weight;
    float* target;
    float* rate;
}

struct BlendPhaseStep @private {
    double start;
    double travel;
    double phase;
}

fn bool? stop_blend_space_weight(BlendSpaceFade fade, float duration) @private {
    if (!math::is_finite(duration) || duration < 0) return c3d::INVALID_ARGUMENT~;
    if (duration == 0) return true;

    *fade.target = 0;
    *fade.rate = *fade.weight / duration;
    return false;
}

fn void? fade_blend_space_weight(BlendSpaceFade fade, float target, float duration) @private {
    if (!math::is_finite(target) || target < 0 || target > 1
      || !math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;

    *fade.target = target;
    *fade.rate = math::abs(target - *fade.weight) / duration;
}

fn bool advance_blend_space_weight(BlendSpaceFade fade, float dt) @private {
    float step = *fade.rate * dt;
    float remaining = *fade.target - *fade.weight;

    if (*fade.rate > 0) {
        if (math::abs(remaining) <= step) {
            *fade.weight = *fade.target;
            *fade.rate = 0;
        } else {
            *fade.weight += remaining < 0 ? -step : step;
        }
    }

    return *fade.weight == 0 && *fade.target == 0;
}

fn BlendPhaseStep advance_blend_phase(
    double phase,
    float dt,
    float speed,
    bool playing,
    double duration,
) @private {
    double travel = playing ? (double)dt * speed / duration : 0;
    double start = phase;
    if (start == 0 && travel < 0) start = 1;
    double end = start + travel;

    return { .start = start, .travel = travel, .phase = end - math::floor(end) };
}

fn void write_blend_space_member(
    Action* action,
    BlendPhaseStep phase,
    float duration,
    float normalized,
    float weight,
) @private {
    action.previous_time = phase.start * duration;
    action.clock_delta = phase.travel * duration;
    action.clock_time = phase.phase * duration;
    action.time = (float)action.clock_time;
    action.published_time = action.time;

    action.weight = weight * normalized;
}

fn void remove_blend_space_members(PlaybackView* playback, AnimationActionId[] members) @private {
    foreach (id : members) {
        playback.actions.get(id).blend_space = 0;
        playback.stop(id)!!;
    }
}
