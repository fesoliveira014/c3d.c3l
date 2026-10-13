module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::math;

struct OverlayProjection @private {
    Mat4 view_proj; // unjittered, relative to the frame origin
    Vec2 axis_scale; // the projection's x and y scales: clip units per world unit at unit distance
}

<*
 Draw the list in world space over the view's output, after its post, tested against the view's depth.
 The renderer prepares the list for that output when finish_view records the view.
 @param [in] list : "Every item under an anchor; unchanged until end_frame; null clears."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require self.frame_open
 @require list == null || list.entries.len > 0 : "The list was destroyed."
*>
fn void? Renderer.set_view_overlay(&self, ViewId view, OverlayList* list) {
    ViewRecord* record = self.views.try_get(view)!;
    if (!list) {
        record.world_overlay = null;
        return;
    }
    if (record.desc.color == OutputMode.LINEAR_HDR || record.desc.shading == ShadingPath.PATH_TRACED) {
        return c3d::UNSUPPORTED~;
    }
    if (list.backdrop_count) return c3d::INVALID_ARGUMENT~;

    foreach (&entry : list.entries[:list.item_count]) {
        if (!list.anchor_roots[entry.transform]) return c3d::INVALID_ARGUMENT~;
    }
    RenderTargetId target = record.desc.output == ViewOutput.TEXTURE ? record.desc.target : (RenderTargetId){};
    check_overlay_refs(self.assets, &self.targets, list, target)!;

    record.world_overlay = list;
}

fn void? record_world_overlay(Renderer* renderer, ViewRecord* record) @private {
    OverlayList* list = record.world_overlay;
    if (!list.item_count) return;

    RenderTargetId target = record.desc.output == ViewOutput.TEXTURE ? record.desc.target : (RenderTargetId){};
    Target* output = overlay_output(renderer, target);
    PixelRect rect = clip_rect(record.desc.viewport, output.width, output.height);
    if (record.desc.viewport.width && (rect.width == 0 || rect.height == 0)) return;
    if (rect.width == 0) rect = { .width = output.width, .height = output.height };

    @pool() {
        OverlayWorld world = {
            .table = alloc::new_array(tmem, shader::OverlayTransformGpu, list.transform_count),
            .view  = { .depth = record.depth.view.index, .rect = rect, .enabled = true },
        };
        resolve_world_anchors(renderer, &record.overlay_projection, list, &world);
        prepare_overlay(renderer, list, target, &world)!;
    };
    if (!list.prepared.run_count) return;

    record.depth.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    output.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    begin_overlay_pass(renderer, output)!;
    renderer.overlay_open = true;

    OverlayContext context = {
        .renderer     = renderer,
        .commands     = &renderer.commands,
        .width        = output.width,
        .height       = output.height,
        .color_format = output.format,
        .target       = target,
    };
    context.draw_list(list)!;

    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.overlay_open = false;
    renderer.work_recorded = true;
}

// Entries are created after the anchor they lie under, so an anchor's own entry is resolved before its descendants.
fn void resolve_world_anchors(
    Renderer* renderer,
    OverlayProjection* projection,
    OverlayList* list,
    OverlayWorld* world,
) @local {
    PixelRect rect = world.view.rect;
    Vec2 size = { (float)rect.width, (float)rect.height };
    foreach (entry, &resolved : world.table) {
        uint root = list.anchor_roots[entry];
        if (!root) {
            *resolved = list.transforms[entry];
            continue;
        }
        if (root != entry) {
            *resolved = resolve_anchored_entry(&world.table[root], &list.transforms[entry]);
            continue;
        }

        Vec4 point = list.anchor_points[entry];
        Vec4 clip = projection.view_proj.apply({
            point.x - renderer.frame_origin.x,
            point.y - renderer.frame_origin.y,
            point.z - renderer.frame_origin.z,
            1,
        });
        float depth = clip.z / clip.w;
        bool visible = clip.w > 0 && depth >= 0 && depth <= 1;
        if (!visible) {
            *resolved = { .depth = -1 };
            continue;
        }

        Vec2 pixel = {
            rect.x + (clip.x / clip.w * 0.5f + 0.5f) * size.x,
            rect.y + (0.5f - clip.y / clip.w * 0.5f) * size.y,
        };
        float pixels_per_unit = point.w;
        Vec2 scale = pixels_per_unit > 0
            ? (Vec2){ pixels_per_unit, pixels_per_unit }
            : projection.axis_scale * size * 0.5f / clip.w;
        *resolved = {
            .x_axis         = { scale.x, 0 },
            .y_axis         = { 0, scale.y },
            .offset         = pixel,
            .inverse_x_axis = { 1 / scale.x, 0 },
            .inverse_y_axis = { 0, 1 / scale.y },
            .inverse_offset = -pixel / scale,
            .depth          = depth,
        };
    }
}

// The inverse composes in the opposite order, so the anchor's inverse applies first.
fn shader::OverlayTransformGpu resolve_anchored_entry(
    shader::OverlayTransformGpu* anchor,
    shader::OverlayTransformGpu* local,
) @local {
    shader::OverlayTransformGpu entry = *local;
    entry.x_axis = anchor.x_axis * local.x_axis.x + anchor.y_axis * local.x_axis.y;
    entry.y_axis = anchor.x_axis * local.y_axis.x + anchor.y_axis * local.y_axis.y;
    entry.offset = anchor.x_axis * local.offset.x + anchor.y_axis * local.offset.y + anchor.offset;
    entry.inverse_x_axis = local.inverse_x_axis * anchor.inverse_x_axis.x
        + local.inverse_y_axis * anchor.inverse_x_axis.y;
    entry.inverse_y_axis = local.inverse_x_axis * anchor.inverse_y_axis.x
        + local.inverse_y_axis * anchor.inverse_y_axis.y;
    entry.inverse_offset = local.inverse_x_axis * anchor.inverse_offset.x
        + local.inverse_y_axis * anchor.inverse_offset.y
        + local.inverse_offset;
    entry.depth = anchor.depth;
    return entry;
}
