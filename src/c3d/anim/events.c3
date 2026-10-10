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

fn EventStream event_stream(Action* action, AnimationClip* clip, ClipEvent event) @private {
    bool forward = action.clock_delta > 0;
    double start = action.previous_time;
    double end = start + action.clock_delta;
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

    return { .next = time + first * clip.duration, .remaining = count };
}

fn EventReport publish_events(
    PlaybackView* playback,
    AssetStore* assets,
    EventOutput events,
    EventBookmark[] bookmarks,
) @private {
    EventReport report;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.clock_delta == 0) continue;
        AnimationClip* clip = &assets.clip(action.clip).data;
        if (!clip.events.len) continue;

        bool forward = action.clock_delta > 0;
        double total;
        foreach (event : clip.events) total += event_stream(action, clip, event).remaining;

        uint emitted;
        usz bookmark_count;
        while (report.count < events.capacity && emitted < total) {
            usz selected;
            usz selected_bookmark;
            EventStream selected_stream;
            bool found;
            foreach (usz index, event : clip.events) {
                usz bookmark;
                while (bookmark < bookmark_count && bookmarks[bookmark].index != index) bookmark++;
                EventStream stream = bookmark < bookmark_count
                    ? (EventStream){ .next = bookmarks[bookmark].next, .remaining = bookmarks[bookmark].remaining }
                    : event_stream(action, clip, event);
                if (stream.remaining < 1) continue;
                if (!found || event_before(
                    time: stream.next,
                    event: event,
                    previous_time: selected_stream.next,
                    previous: clip.events[selected],
                    forward: forward,
                )) {
                    selected = index;
                    selected_bookmark = bookmark;
                    selected_stream = stream;
                    found = true;
                }
            }

            ClipEvent event = clip.events[selected];
            FiredEvent* output = (FiredEvent*)((char*)events.first + events.stride * report.count++);
            *output = {
                .action = id,
                .clip = action.clip,
                .id = event.id,
                .time = event.time,
            };

            if (selected_bookmark == bookmark_count) bookmark_count++;
            bookmarks[selected_bookmark] = {
                .index = selected,
                .next = selected_stream.next + (forward ? (double)clip.duration : -(double)clip.duration),
                .remaining = selected_stream.remaining - 1,
            };

            emitted++;
        }

        double dropped = total - emitted;
        uint room = uint::max - report.dropped;
        report.dropped += (uint)math::min(dropped, (double)room);
    }

    return report;
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
