module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<* Events retained by an animator after one update. *>
const uint MAX_FIRED_EVENTS = 16; // 384 bytes of event values per animator; later crossings are counted

<* Event crossed by a retained action during the last update. *>
struct FiredEvent {
    AnimationActionId action;
    ClipId clip;
    uint id;
    float time;
}

struct EventStream @private {
    double next;
    double remaining;
}

fn void publish_events(Animator* animator, AssetStore* assets) @private {
    foreach (id : animator.order[:animator.action_count]) {
        Action* action = animator.actions.get(id);
        if (action.clock_delta == 0) continue;
        AnimationClip* clip = &assets.clip(action.clip).data;
        if (!clip.events.len) continue;

        EventStream[] streams = alloc::new_array(tmem, EventStream, clip.events.len);
        bool forward = action.clock_delta > 0;
        double start = action.previous_time;
        double end = start + action.clock_delta;
        double total;
        foreach (index, event : clip.events) {
            double time = event.time;
            double first;
            double count;
            if (!action.loop) {
                bool crossed = forward
                    ? time >= start && (time < end || (end == clip.duration && time == end))
                    : time <= start && (time > end || (end == 0 && time == end));
                count = crossed ? 1 : 0;
            } else if (forward) {
                bool closing = event.time == clip.duration;
                first = closing ? math::floor((start - time) / clip.duration) + 1
                    : math::ceil((start - time) / clip.duration);
                double last = closing ? math::floor((end - time) / clip.duration)
                    : math::ceil((end - time) / clip.duration) - 1;
                count = math::max(0.0, last - first + 1);
            } else {
                bool closing = event.time == 0;
                first = closing ? math::ceil((start - time) / clip.duration) - 1
                    : math::floor((start - time) / clip.duration);
                double last = closing ? math::ceil((end - time) / clip.duration)
                    : math::floor((end - time) / clip.duration) + 1;
                count = math::max(0.0, first - last + 1);
            }
            streams[index] = { .next = time + first * clip.duration, .remaining = count };
            total += count;
        }

        uint emitted;
        while (animator.event_count < MAX_FIRED_EVENTS && emitted < total) {
            usz selected;
            bool found;
            foreach (usz index, stream : streams) {
                if (stream.remaining < 1) continue;
                if (!found || event_before(
                    time: stream.next,
                    event: clip.events[index],
                    previous_time: streams[selected].next,
                    previous: clip.events[selected],
                    forward: forward,
                )) {
                    selected = index;
                    found = true;
                }
            }

            ClipEvent event = clip.events[selected];
            animator.events[animator.event_count++] = {
                .action = id,
                .clip = action.clip,
                .id = event.id,
                .time = event.time,
            };
            streams[selected].remaining--;
            streams[selected].next += forward ? (double)clip.duration : -(double)clip.duration;
            emitted++;
        }

        double dropped = total - emitted;
        uint room = uint::max - animator.events_dropped;
        animator.events_dropped += (uint)math::min(dropped, (double)room);
    }
}

fn bool event_before(
    double time,
    ClipEvent event,
    double previous_time,
    ClipEvent previous,
    bool forward,
) @private {
    if (time != previous_time) return forward ? time < previous_time : time > previous_time;
    return forward ? event.time > previous.time : event.time < previous.time;
}
