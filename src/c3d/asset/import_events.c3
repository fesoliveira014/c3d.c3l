module c3d::asset;

import c3d;
import c3d::anim;
import std::collections::object;
import std::encoding::json;
import std::math;
import std::sort;

const double EVENT_SCHEMA_VERSION @local = 1;

<*
 Import the event table from glTF animation extras when present.
 @param extras : "Extras text as cgltf stores it."
 @param duration : "Track-derived clip duration in seconds."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn ClipEvent[]? parse_gltf_clip_events(Allocator allocator, String extras, float duration) {
    // cgltf stores string extras without their quotes, so only object text can hold the table.
    if (!extras.trim().starts_with("{")) return {};

    @pool() {
        Object*? root = json::tparse(extras, JsonFlavor.JSON);
        if (catch root) {
            // Extras without the table keep loading when they exceed the parser's limits.
            if (extras.contains(`"c3d_events"`)) return c3d::ASSET_FORMAT_ERROR~;
            return {};
        }

        Object*? table = root.get("c3d_events");
        if (catch table) return {};

        return read_event_table(allocator, table, duration);
    };
}

<*
 Import a versioned event table with exact IDs and stable time order.
 @param source : "Raw inner event-schema JSON object."
 @param duration : "Track-derived clip duration in seconds."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn ClipEvent[]? parse_clip_events(Allocator allocator, String source, float duration) {
    @pool() {
        Object* table = json::tparse(source, JsonFlavor.JSON) ?? c3d::ASSET_FORMAT_ERROR~!;
        return read_event_table(allocator, table, duration);
    };
}

fn ClipEvent[]? read_event_table(Allocator allocator, Object* table, float duration) @local {
    if (!table.is_map()) return c3d::ASSET_FORMAT_ERROR~;

    double version = table.get_float("version") ?? c3d::ASSET_FORMAT_ERROR~!;
    if (version != math::floor(version)) return c3d::ASSET_FORMAT_ERROR~;
    if (version != EVENT_SCHEMA_VERSION) return c3d::UNSUPPORTED~;

    Object*? entries = table.get("events");
    if (catch entries) return c3d::ASSET_FORMAT_ERROR~;
    if (!entries.is_array() || !math::is_finite(duration) || duration < 0) return c3d::ASSET_FORMAT_ERROR~;

    ClipEvent[] events = alloc::new_array_try(allocator, ClipEvent, entries.len())
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, events.ptr);

    foreach (index, &event : events) {
        Object* entry = entries.get_at(index);
        if (!entry.is_map()) return c3d::ASSET_FORMAT_ERROR~;

        double time = entry.get_float("time") ?? c3d::ASSET_FORMAT_ERROR~!;
        double id = entry.get_float("id") ?? c3d::ASSET_FORMAT_ERROR~!;
        if (time < 0 || time > duration || id < 0 || id > uint::max || id != math::floor(id)) {
            return c3d::ASSET_FORMAT_ERROR~;
        }

        *event = { .time = (float)time, .id = (uint)id };
    }

    sort::mergesort(events, &compare_event_times);
    return events;
}

fn int compare_event_times(ClipEvent first, ClipEvent second) @local {
    if (first.time < second.time) return -1;
    return first.time > second.time ? 1 : 0;
}
