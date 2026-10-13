module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::math;

struct OverlayProjection @private {
    Mat4  view_proj;  // unjittered, relative to the frame origin
    Vec2  axis_scale; // the projection's x and y scales: clip units per world unit at unit distance
    Plane clip_plane; // relative to the frame origin; the zero plane clips nothing
    uint  layers;     // of the view's camera
    bool  reflected;  // the view matrix flips handedness, as a mirror camera's does
    bool  enabled;    // false while a reflection capture records
}

const float NEAREST_PLANE_W @local = 1e-6f; // a plane corner nearer the eye plane than this bounds the whole view

<*
 Draw the list in world space over the view's output, after its post, tested against the view's depth.
 The renderer prepares the list for that output when finish_view records the view.
 @param [in] list : "Every item under an anchor; unchanged until end_frame; null clears."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require self.frame_open
 @require overlay_list_live(list) : "The list was destroyed."
*>
fn void? Renderer.set_view_overlay(&self, ViewId view, OverlayList* list) {
    ViewRecord* record = self.views.try_get(view)!;
    if (!list) {
        record.world_overlay = null;
        return;
    }

    if (record.desc.shading == ShadingPath.PATH_TRACED) return c3d::UNSUPPORTED~;
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
    OverlayProjection* projection = &record.overlay_projection;

    if (!projection.enabled || !list.item_count || !(list.layers & projection.layers)) return;

    RenderTargetId target = record.desc.output == ViewOutput.TEXTURE ? record.desc.target : (RenderTargetId){};
    Target* output = overlay_output(renderer, target);
    PixelRect rect = clip_rect(record.desc.viewport, output.width, output.height);
    if (record.desc.viewport.width && (rect.width == 0 || rect.height == 0)) return;
    if (rect.width == 0) rect = { .width = output.width, .height = output.height };

    @pool() {
        OverlayWorld world = {
            .table = alloc::new_array(tmem, shader::OverlayTransformGpu, list.transform_count),
            .view  = {
                .depth       = record.depth.view.index,
                .rect        = rect,
                .color_scale = record.desc.color == OutputMode.LINEAR_HDR ? 1 / record.exposure : 1,
                .enabled     = true,
            },
        };

        if (list.plane_count) world.planes = alloc::new_array(tmem, shader::OverlayPlaneGpu, list.transform_count);

        resolve_world_anchors(renderer, projection, list, &world);
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

fn bool overlay_list_live(OverlayList* list) @private {
    return list == null || list.entries.len > 0;
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
            if (world.table[root].plane) {
                *resolved = list.transforms[entry];
                resolved.plane = 1;
                resolved.depth = world.table[root].depth;
                world.planes[entry] = world.planes[root];
            } else {
                *resolved = resolve_anchored_entry(&world.table[root], &list.transforms[entry]);
            }
            continue;
        }

        OverlayAnchor* anchor = &list.anchors[entry];
        Vec3 position = {
            anchor.position.x - renderer.frame_origin.x,
            anchor.position.y - renderer.frame_origin.y,
            anchor.position.z - renderer.frame_origin.z,
        };

        if (anchor.facing == PLANE) {
            *resolved = list.transforms[entry];
            resolve_plane_anchor(projection, anchor, position, resolved, &world.planes[entry]);
            continue;
        }

        Vec4 clip = projection.view_proj.apply({ position.x, position.y, position.z, 1 });
        float depth = clip.z / clip.w;
        bool visible = clip.w > 0 && depth >= 0 && depth <= 1 && !clipped_by_plane(projection.clip_plane, position);
        if (!visible) {
            *resolved = { .depth = -1 };
            continue;
        }

        Vec2 pixel = view_pixel(rect, clip);
        float pixels_per_unit = anchor.pixels_per_unit;
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

// Layout x runs along right and layout y against up, so a plane seen from its front reads left to right.
fn void resolve_plane_anchor(
    OverlayProjection* projection,
    OverlayAnchor* anchor,
    Vec3 position,
    shader::OverlayTransformGpu* resolved,
    shader::OverlayPlaneGpu* plane,
) @local {
    float unit = anchor.pixels_per_unit > 0 ? 1 / anchor.pixels_per_unit : 1;
    Vec3 x_step = anchor.right * unit;
    Vec3 y_step = -anchor.up * unit;
    plane.u_axis = projection.view_proj.apply({ x_step.x, x_step.y, x_step.z, 0 });
    plane.v_axis = projection.view_proj.apply({ y_step.x, y_step.y, y_step.z, 0 });
    plane.origin = projection.view_proj.apply({ position.x, position.y, position.z, 1 });

    Plane clip_plane = projection.clip_plane;
    plane.distance = clip_plane.normal != (Vec3){}
        ? (Vec4f){
            clip_plane.normal.dot(x_step),
            clip_plane.normal.dot(y_step),
            clip_plane.normal.dot(position) + clip_plane.d,
            0,
        }
        : (Vec4f){ 0, 0, 1, 0 };

    // The determinant of the map from layout units to (x, y, w) is negative where the front shows, and positive where
    // the view is reflected, so the test follows the plane's side of the camera and not the winding on screen.
    Vec3 x_column = { plane.u_axis.x, plane.u_axis.y, plane.u_axis.w };
    Vec3 y_column = { plane.v_axis.x, plane.v_axis.y, plane.v_axis.w };
    Vec3 origin_column = { plane.origin.x, plane.origin.y, plane.origin.w };
    float orientation = x_column.dot(y_column.cross(origin_column));
    bool front = (orientation < 0) != projection.reflected && orientation != 0;

    resolved.plane = 1;
    resolved.depth = front ? 0 : -1;
}

fn bool clipped_by_plane(Plane clip_plane, Vec3 position) @local {
    return clip_plane.normal != (Vec3){} && clip_plane.normal.dot(position) + clip_plane.d < 0;
}

fn Vec2 view_pixel(PixelRect rect, Vec4 clip) @local {
    return {
        rect.x + (clip.x / clip.w * 0.5f + 0.5f) * rect.width,
        rect.y + (0.5f - clip.y / clip.w * 0.5f) * rect.height,
    };
}

fn Vec4 view_bounds(PixelRect rect) @private {
    return { (float)rect.x, (float)rect.y, (float)(rect.x + rect.width), (float)(rect.y + rect.height) };
}

// The output pixels a box in the plane's units covers, or the whole view when a corner reaches the eye plane.
fn Vec4 plane_output_bounds(OverlayWorld* world, uint entry, Vec4 box) @private {
    shader::OverlayPlaneGpu* plane = &world.planes[entry];
    PixelRect rect = world.view.rect;
    Vec2 low = { float::max, float::max };
    Vec2 high = { -float::max, -float::max };

    Vec2[4] corners = { { box.x, box.y }, { box.z, box.y }, { box.x, box.w }, { box.z, box.w } };
    foreach (corner : corners) {
        Vec4 clip = plane.u_axis * corner.x + plane.v_axis * corner.y + plane.origin;
        Vec2 pixel = view_pixel(rect, clip);
        if (!(clip.w > NEAREST_PLANE_W) || !math::is_finite(pixel.x) || !math::is_finite(pixel.y)) {
            return view_bounds(rect);
        }

        low = math::min(low, pixel);
        high = math::max(high, pixel);
    }
    return { low.x, low.y, high.x, high.y };
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
