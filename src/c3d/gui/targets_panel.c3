module c3d::gui;

import c3d;
import c3d::material;
import c3d::render;
import gpu;
import imgui;
import std::collections::list;
import std::math;

<*
 Panel entries a targets panel can keep open.
*>
const uint TARGETS_PANEL_ENTRIES = 64;

const float PREVIEW_EXPOSURE_DEFAULT @local = 1;
const float PREVIEW_DEPTH_RANGE_DEFAULT @local = 50;
const float PREVIEW_VELOCITY_RANGE_DEFAULT @local = 32;
const uint PREVIEW_SIZE_DEFAULT @local = 256;
const uint PREVIEW_SIZE_MIN @local = 16;
const uint VIEW_IMAGE_KINDS @local = 8;

<*
 Visualization scales and open entries of a targets panel.
*>
struct TargetsPanelState {
    float                       exposure;
    float                       depth_range;
    float                       velocity_range;
    uint                        preview_size;
    uint                        cluster_slice;
    bool[TARGETS_PANEL_ENTRIES] open;
}

struct PanelEntry @local {
    ZString       label;
    PreviewSource source;
    uint          width;
    uint          height;
}

<*
 Panel state with unit exposure and default ranges, every entry closed.
*>
fn TargetsPanelState default_targets_panel_state() {
    return {
        .exposure       = PREVIEW_EXPOSURE_DEFAULT,
        .depth_range    = PREVIEW_DEPTH_RANGE_DEFAULT,
        .velocity_range = PREVIEW_VELOCITY_RANGE_DEFAULT,
        .preview_size   = PREVIEW_SIZE_DEFAULT,
    };
}

<*
 Show the view's images, render targets, shadow layers and environment faces as previews.
 @param [&inout] renderer : "Receives preview requests for the next overlay; no frame open."
 @param [&inout] state : "Open entries and scales retained between frames."
 @param environment : "Faces of this environment are listed when it is uploaded."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::UNSUPPORTED_FEATURE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn void? targets_panel(
    Renderer* renderer,
    ViewId view,
    TargetsPanelState* state,
    EnvironmentId environment = {},
) {
    bool visible = imgui::begin("Targets", null, {});
    defer imgui::end();
    if (!visible) return;

    if (renderer.views.is_live(view)) {
        ViewRecord* record = renderer.views.get(view);
        ViewDesc desc = record.desc;
        imgui::separator_text("Shading");
        if (imgui::radio_button("Forward", desc.shading == FORWARD)) desc.shading = FORWARD;
        imgui::same_line();
        imgui::begin_disabled(true);
        imgui::radio_button("Deferred (unsupported)", false);
        imgui::end_disabled();
        if (imgui::radio_button("Flat", desc.lights == FLAT)) desc.lights = FLAT;
        imgui::same_line();
        if (imgui::radio_button("Clustered", desc.lights == CLUSTERED)) desc.lights = CLUSTERED;
        if (desc.shading != record.desc.shading || desc.lights != record.desc.lights) {
            render::configure_view(renderer, view, desc)!;
        }

        if (record.desc.lights == CLUSTERED) {
            imgui::input_scalar("Cluster slice", imgui::DATA_TYPE_U32, &state.cluster_slice);
            state.cluster_slice = math::min(state.cluster_slice, record.desc.clusters.depth_slices - 1);
            ClusterDepth depth = record.cluster_depth;
            if (depth.near < depth.far && depth.slices == record.desc.clusters.depth_slices
                && state.cluster_slice < depth.slices) {
                Vec2 bounds = render::cluster_slice_bounds(depth, state.cluster_slice);
                imgui::text("Slice depth: %.3f to %.3f", (double)bounds.x, (double)bounds.y);
            } else {
                imgui::text_unformatted("Slice depth: unavailable");
            }
        }
        imgui::separator();
    }

    imgui::drag_float("Exposure", &state.exposure);
    imgui::drag_float("Depth range", &state.depth_range);
    imgui::drag_float("Velocity range", &state.velocity_range);
    if (imgui::input_scalar("Preview size", imgui::DATA_TYPE_U32, &state.preview_size)) {
        state.preview_size = math::clamp(state.preview_size, PREVIEW_SIZE_MIN, render::PREVIEW_MAX_SIZE);
    }

    @pool() {
        PanelEntry[] entries = collect_entries(renderer, view, environment);
        uint slot;
        foreach (index, &entry : entries) {
            if (index >= TARGETS_PANEL_ENTRIES) break;
            imgui::push_id_int((int)index);
            defer imgui::pop_id();

            imgui::TreeNodeFlags flags = { .default_open = state.open[index] };
            state.open[index] = imgui::collapsing_header(entry.label, flags);
            if (!state.open[index]) continue;
            if (slot == render::PREVIEW_CAPACITY) {
                imgui::text_unformatted("No preview slot free");
                continue;
            }

            uint width = state.preview_size;
            uint height = (uint)math::max(1ul, (ulong)width * entry.height / entry.width);
            if (entry.source.kind == VIEW_CLUSTERS) entry.source.level = state.cluster_slice;
            renderer.request_preview(slot, entry.source, {
                .width    = width,
                .height   = math::min(height, render::PREVIEW_MAX_SIZE),
                .exposure = state.exposure,
                .range    = preview_range(entry.source.kind, state),
            })!;
            imgui::image(imgui::texture_ref_from_id((ulong)(uint)renderer.preview_texture(slot)),
                { (float)width, (float)height });
            slot++;
        }
    };
}

fn float preview_range(PreviewKind kind, TargetsPanelState* state) @local {
    switch (kind) {
        case VIEW_DEPTH:    return state.depth_range;
        case VIEW_VELOCITY: return state.velocity_range;
        default:            return 1;
    }
}

fn PanelEntry[] collect_entries(Renderer* renderer, ViewId view, EnvironmentId environment) @local {
    List{PanelEntry} entries;
    entries.tinit();

    if (renderer.views.is_live(view)) {
        ViewRecord* record = renderer.views.get(view);
        push_view_image(&entries, "hdr_color", { .kind = VIEW_COLOR, .view = view }, &record.hdr_color);
        push_view_image(&entries, "depth", { .kind = VIEW_DEPTH, .view = view }, &record.depth);
        push_view_image(&entries, "velocity", { .kind = VIEW_VELOCITY, .view = view }, &record.velocity);
        push_view_image(&entries, "scene_color", { .kind = VIEW_SCENE_COLOR, .view = view }, &record.scene_color);
        for (uint level = 0; level < record.bloom_levels; level++) {
            ZString label = string::tformat("bloom %d", level).zstr_tcopy();
            push_view_image(&entries, label, { .kind = VIEW_BLOOM, .view = view, .level = level }, &record.bloom[level]);
        }
        push_view_image(&entries, "dof_near", { .kind = VIEW_DOF_NEAR, .view = view }, &record.dof_near);
        push_view_image(&entries, "dof_far", { .kind = VIEW_DOF_FAR, .view = view }, &record.dof_far);
        push_view_image(&entries, "motion_blur_out", { .kind = VIEW_MOTION_BLUR, .view = view }, &record.motion_blur_out);
        if (record.desc.lights == CLUSTERED) {
            entries.push({
                .label  = "clusters",
                .source = { .kind = VIEW_CLUSTERS, .view = view },
                .width  = record.desc.clusters.tiles_x,
                .height = record.desc.clusters.tiles_y,
            });
        }
    }

    foreach (index, &record : renderer.targets.items) {
        if (!record.target.texture.is_valid()) continue;
        RenderTargetId target = { .index = (uint)index, .generation = renderer.targets.generations[index] };
        entries.push({
            .label  = string::tformat("target %d", index).zstr_tcopy(),
            .source = { .kind = RENDER_TARGET, .target = target },
            .width  = record.target.width,
            .height = record.target.height,
        });
    }

    foreach (layer, &shadow_layer : renderer.shadow_atlas.layers) {
        entries.push({
            .label  = string::tformat("shadow layer %d", layer).zstr_tcopy(),
            .source = { .kind = SHADOW_LAYER, .layer = (uint)layer },
            .width  = renderer.shadow_atlas.resolution,
            .height = renderer.shadow_atlas.resolution,
        });
    }

    if (renderer.assets.environments.is_live(environment)) {
        ZString[6] face_labels = {
            "environment +X", "environment -X", "environment +Y",
            "environment -Y", "environment +Z", "environment -Z",
        };
        foreach (index, label : face_labels) {
            entries.push({
                .label  = label,
                .source = { .kind = ENVIRONMENT_FACE, .environment = environment, .face = CubeFace::from_ordinal(index) },
                .width  = 1,
                .height = 1,
            });
        }
    }

    return entries.array_view();
}

fn void push_view_image(List{PanelEntry}* entries, ZString label, PreviewSource source, Target* target) @local {
    if (!target.texture.is_valid()) return;
    entries.push({ .label = label, .source = source, .width = target.width, .height = target.height });
}
