module c3d::render;

import c3d;
import c3d::maths;
import std::math;

<*
 Most refractive layers a view records.
*>
const uint MAX_TRANSMISSION_LAYERS = 4; // each layer past the first costs a snapshot copy and maybe a mip chain

const ScreenRect FULL_SCREEN_RECT @private = { .min = { -1, -1 }, .max = { 1, 1 } };

<*
 Screen rectangle in normalized device coordinates, inside [-1, 1] on both axes.
*>
struct ScreenRect {
    Vec2 min;
    Vec2 max;
}

<*
 Whether the rectangles share area; touching edges do not count.
 @pure
*>
fn bool ScreenRect.overlaps(self, ScreenRect other) {
    return self.min.x < other.max.x && other.min.x < self.max.x
        && self.min.y < other.max.y && other.min.y < self.max.y;
}

<*
 Project a world box to a screen rectangle.
 A corner at or behind the near plane makes it the whole screen.
 @param view_proj : "Reverse-Z view-projection matrix."
*>
fn ScreenRect project_bounds_to_screen_rect(Mat4 view_proj, Aabb bounds) {
    ScreenRect rect = { .min = { 1, 1 }, .max = { -1, -1 } };
    for (uint corner = 0; corner < 8; corner++) {
        Vec4 clip = view_proj.apply({
            (corner & 1) != 0 ? bounds.max.x : bounds.min.x,
            (corner & 2) != 0 ? bounds.max.y : bounds.min.y,
            (corner & 4) != 0 ? bounds.max.z : bounds.min.z,
            1.0f,
        });
        // Reverse-Z puts the near plane at clip z == clip w; a corner on or past it has no usable projection.
        if (clip.z >= clip.w) return FULL_SCREEN_RECT;
        Vec2 ndc = { clip.x / clip.w, clip.y / clip.w };
        rect.min = math::min(rect.min, ndc);
        rect.max = math::max(rect.max, ndc);
    }
    return {
        .min = math::clamp(rect.min, FULL_SCREEN_RECT.min, FULL_SCREEN_RECT.max),
        .max = math::clamp(rect.max, FULL_SCREEN_RECT.min, FULL_SCREEN_RECT.max),
    };
}

<*
 Assign each draw a layer above the earlier draws it overlaps.
 @param rects : "One per draw, in back-to-front order."
 @param layer_count : "Layers available; deeper overlaps share the last."
 @param layers : "Receives one layer per draw."
 @require layer_count >= 1, layers.len == rects.len
*>
fn void assign_transmission_layers(ScreenRect[] rects, uint layer_count, uint[] layers) {
    uint last_layer = layer_count - 1;
    for (usz draw = 0; draw < rects.len; draw++) {
        uint layer;
        for (usz earlier = 0; earlier < draw && layer < last_layer; earlier++) {
            if (rects[draw].overlaps(rects[earlier])) layer = math::max(layer, layers[earlier] + 1);
        }
        layers[draw] = math::min(layer, last_layer);
    }
}

struct SceneReadLayers @private {
    uint                         count;
    usz[MAX_TRANSMISSION_LAYERS] ends; // exclusive end of each layer in the ordered draws
}

fn SceneReadLayers split_scene_reads_by_layer(DrawItem[] items, Mat4 view_proj, uint layer_count) @private {
    @pool() {
        ScreenRect[] rects = alloc::new_array(tmem, ScreenRect, items.len);
        foreach (index, &item : items) {
            rects[index] = project_bounds_to_screen_rect(view_proj, item.candidate.world_bounds);
        }
        uint[] layers = alloc::new_array(tmem, uint, items.len);
        assign_transmission_layers(rects, layer_count, layers);

        DrawItem[] ordered = alloc::new_array(tmem, DrawItem, items.len);
        SceneReadLayers split = { .count = layer_count };
        usz filled;
        for (uint layer = 0; layer < layer_count; layer++) {
            foreach (index, &item : items) {
                if (layers[index] == layer) ordered[filled++] = *item;
            }
            split.ends[layer] = filled;
        }
        items[..] = ordered[..];
        return split;
    };
}
