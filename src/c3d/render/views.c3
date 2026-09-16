module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import c3d::render::post;
import c3d::scene;
import gpu;
import std::math;

<*
 Pooled views a renderer holds at once.
*>
const uint VIEW_CAPACITY = 8; // each view owns its working images; a 1080p view is about 16 MiB before effects

<*
 Largest render scale a view accepts.
*>
const float MAX_RENDER_SCALE = 2.0f; // four times the viewport's pixels; the supersampling ceiling

<*
 Where a view's output goes.
*>
enum ViewOutput {
    WINDOW,
    TEXTURE,
}

<*
 Color space the view's output keeps.
*>
enum OutputMode {
    DISPLAY_LDR,
    LINEAR_HDR,
}

<*
 Rectangle in output pixels; a zero extent means the whole output.
*>
struct PixelRect {
    uint x;
    uint y;
    uint width;
    uint height;
}

<*
 CPU configuration of one view; copied into its record.
*>
struct ViewDesc {
    ViewOutput     output;
    RenderTargetId target;
    PixelRect      viewport;
    float          render_scale;
    OutputMode     color;
    PostStack      post;
}

<*
 Working images one view owns, in view_targets order.
*>
const uint VIEW_TARGET_COUNT = 5 + post::BLOOM_MAX_LEVELS + 8;

<*
 Reverse-Z projection terms that recover forward distance from stored depth.
*>
struct ProjectionTerms {
    float m22;
    float m23;
    bool  orthographic;
}

<*
 Pose the view last rendered: its camera and every node it drew, tagged by entity.
*>
struct ViewHistory {
    bool     valid;
    Mat4     view_proj;
    Mat4[]   models;
    Entity[] owners;
}

<*
 Whether the node was drawn by the last rendering of this view.
 @param [&in] node : "Live node."
*>
fn bool ViewHistory.has_previous(&self, Node* node) {
    if (!self.valid || node.id.index >= self.owners.len) return false;
    Entity owner = self.owners[node.id.index];
    return owner.index == node.id.index && owner.generation == node.id.generation;
}

<*
 World matrix the node had when this view last rendered it.
 @param [&in] node : "Live node."
 @require self.has_previous(node)
*>
fn Mat4 ViewHistory.previous_model(&self, Node* node) {
    return self.models[node.id.index];
}

<*
 Remember the drawn candidates' world matrices and the camera for the next rendering.
 @param [&in] scene : "Sizes the tables to its node capacity."
 @param candidates : "Every mesh this rendering drew."
*>
fn void ViewHistory.commit(
    &self,
    Allocator allocator,
    Scene* scene,
    MeshCandidate[] candidates,
    Mat4 view_proj,
) {
    if (self.models.len != scene.nodes.len) {
        free_view_history(allocator, self);
        self.models = alloc::new_array(allocator, Mat4, scene.nodes.len);
        self.owners = alloc::new_array(allocator, Entity, scene.nodes.len);
    }
    foreach (&candidate : candidates) {
        self.models[candidate.node.id.index] = candidate.node.world;
        self.owners[candidate.node.id.index] = candidate.node.id;
    }
    self.view_proj = view_proj;
    self.valid = true;
}

<*
 Free the history tables.
 @param [&inout] history : "Left zeroed."
*>
fn void free_view_history(Allocator allocator, ViewHistory* history) {
    if (history.models.len) {
        alloc::free(allocator, history.models.ptr);
        alloc::free(allocator, history.owners.ptr);
    }
    *history = {};
}

<*
 Renderer-owned view: its configuration, working images and recording state.
*>
struct ViewRecord {
    bool                                 live;
    ViewDesc                             desc;
    Target                               hdr_color;
    Target                               depth;
    Target                               scene_color;
    Target                               post_a;
    Target                               post_b;
    Target[post::BLOOM_MAX_LEVELS]       bloom;
    uint                                 bloom_levels;
    Target                               dof_near;
    Target                               dof_far;
    Target                               dof_near_blur;
    Target                               dof_far_blur;
    Target                               tile_max;
    Target                               tile_neighbor;
    Target                               velocity;
    Target                               motion_blur_out;
    Target*                              scene_input;
    bool                                 post_chain_open;
    ProjectionTerms                      projection_terms;
    float                                exposure;
    ViewHistory                          history;
    gpu::TextureState[VIEW_TARGET_COUNT] frame_states;
}

<*
 Remember every working image's state at the start of a frame.
*>
fn void ViewRecord.snapshot_states(&self) {
    Target*[VIEW_TARGET_COUNT] targets = view_targets(self);
    foreach (index, target : targets) self.frame_states[index] = target.state;
}

<*
 Put every working image back to its start-of-frame state.
*>
fn void ViewRecord.restore_states(&self) {
    Target*[VIEW_TARGET_COUNT] targets = view_targets(self);
    foreach (index, target : targets) target.state = self.frame_states[index];
}

<*
 Every working image of the view, allocated or not, in a fixed order.
 @param [&in] record : "Outlives the returned pointers."
*>
fn Target*[VIEW_TARGET_COUNT] view_targets(ViewRecord* record) {
    Target*[VIEW_TARGET_COUNT] targets;
    targets[0] = &record.hdr_color;
    targets[1] = &record.depth;
    targets[2] = &record.scene_color;
    targets[3] = &record.post_a;
    targets[4] = &record.post_b;
    foreach (level, &target : record.bloom) targets[5 + level] = target;
    uint next = 5 + post::BLOOM_MAX_LEVELS;
    targets[next] = &record.dof_near;
    targets[next + 1] = &record.dof_far;
    targets[next + 2] = &record.dof_near_blur;
    targets[next + 3] = &record.dof_far_blur;
    targets[next + 4] = &record.tile_max;
    targets[next + 5] = &record.tile_neighbor;
    targets[next + 6] = &record.velocity;
    targets[next + 7] = &record.motion_blur_out;
    return targets;
}

<*
 View records addressed by ViewId.
*>
alias ViewPool = Pool{ViewRecord, ViewId};

<*
 Window output at full size with neutral grading.
*>
fn ViewDesc default_view_desc() {
    return {
        .output       = ViewOutput.WINDOW,
        .render_scale = 1,
        .color        = OutputMode.DISPLAY_LDR,
        .post         = post::default_post_stack(),
    };
}

<*
 Texture output covering the whole target with neutral grading.
*>
fn ViewDesc texture_view_desc(RenderTargetId target, OutputMode color = OutputMode.LINEAR_HDR) {
    return {
        .output       = ViewOutput.TEXTURE,
        .target       = target,
        .render_scale = 1,
        .color        = color,
        .post         = post::default_post_stack(),
    };
}

<*
 Working extent of a view: the viewport or the whole output, scaled, at least one pixel.
*>
fn uint[<2>] working_extent(
    PixelRect viewport,
    uint output_width,
    uint output_height,
    float render_scale,
) {
    uint width = viewport.width ? viewport.width : output_width;
    uint height = viewport.height ? viewport.height : output_height;
    return {
        math::max((uint)math::round((float)width * render_scale), 1u),
        math::max((uint)math::round((float)height * render_scale), 1u),
    };
}

<*
 Whether the rectangle lies inside the output; a zero extent always does.
 @pure
*>
fn bool viewport_within(PixelRect viewport, uint output_width, uint output_height) {
    if (viewport.width == 0 && viewport.height == 0) return true;
    return viewport.width > 0 && viewport.height > 0
        && viewport.x + viewport.width <= output_width
        && viewport.y + viewport.height <= output_height;
}

<*
 Whether the output mode may write the format; scene-linear output needs a float format.
 @pure
*>
fn bool output_mode_allows_format(OutputMode color, PixelFormat format) {
    switch (color) {
        case DISPLAY_LDR: return true;
        case LINEAR_HDR: return format == PixelFormat.RGBA16_FLOAT || format == PixelFormat.RGBA32_FLOAT;
    }
}

<*
 Create a view and allocate its working images.
 @param [&inout] renderer : "No open frame."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::UNSUPPORTED_FEATURE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn ViewId? create_view(Renderer* renderer, ViewDesc desc) {
    validate_view_desc(renderer, &desc)!;
    ViewId view = renderer.views.add({ .live = true, .desc = desc })!;
    ViewRecord* record = renderer.views.get(view);
    defer catch {
        *record = {};
        renderer.views.remove(view);
    }
    acquire_view_images(renderer, record)!;
    return view;
}

<*
 Replace the view's configuration; resizes or retires its working images and forgets its history.
 @param [&inout] renderer : "No open frame."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::UNSUPPORTED_FEATURE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn void? configure_view(Renderer* renderer, ViewId view, ViewDesc desc) {
    ViewRecord* record = renderer.views.try_get(view)!;
    validate_view_desc(renderer, &desc)!;

    ViewRecord wanted = { .live = true, .desc = desc };
    uint[<2>] current_extent = view_working_extent(renderer, record);
    uint[<2>] wanted_extent = view_working_extent(renderer, &wanted);
    bool same_output = record.desc.output == desc.output
        && record.desc.target.index == desc.target.index
        && record.desc.target.generation == desc.target.generation;
    if (!same_output || current_extent != wanted_extent) {
        wait_frames(renderer)!;
        record.desc = desc;
        return resize_view(renderer, record);
    }

    if (desc.post.fxaa) {
        post::acquire_post_targets(renderer, record)!;
    } else {
        post::retire_post_targets(renderer, record);
    }
    record.desc = desc;
    record.history.valid = false;
    post::retire_effect_targets(renderer, record);
    post::acquire_effect_targets(renderer, record)!;
}

<*
 Release the view's working images after every submitted use completes. The id is dead afterwards.
 @param [&inout] renderer : "No open frame."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY
 @return? gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn void? destroy_view(Renderer* renderer, ViewId view) {
    ViewRecord* record = renderer.views.try_get(view)!;
    if (view.index == renderer.default_view.index) return c3d::INVALID_ARGUMENT~;
    wait_frames(renderer)!;
    release_view_images(renderer, record);
    *record = {};
    renderer.views.remove(view);
}

<*
 Forget the view's previous pose so the next rendering carries no motion; a camera cut.
 @param [&inout] renderer : "No open frame."
 @return? c3d::INVALID_ID
 @require !renderer.frame_open
*>
fn void? reset_view_history(Renderer* renderer, ViewId view) {
    ViewRecord* record = renderer.views.try_get(view)!;
    record.history.valid = false;
}

fn void? validate_view_desc(Renderer* renderer, ViewDesc* desc) @private {
    switch (desc.output) {
        case WINDOW:
            if (desc.color == OutputMode.LINEAR_HDR) return c3d::INVALID_ARGUMENT~;
        case TEXTURE:
            TargetRecord* target = renderer.targets.try_get(desc.target)!;
            if (!output_mode_allows_format(desc.color, target.format)) return c3d::INVALID_ARGUMENT~;
    }
    uint[<2>] output = view_output_extent(renderer, desc);
    if (!viewport_within(desc.viewport, output.x, output.y)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(desc.render_scale) || desc.render_scale <= 0 || desc.render_scale > MAX_RENDER_SCALE) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!post::post_stack_valid(&desc.post)) return c3d::INVALID_ARGUMENT~;
    if (desc.post.grade.lut.generation) {
        TextureAsset* lut = renderer.assets.textures.try_get(desc.post.grade.lut)!;
        if (!lut_desc_valid(&lut.desc)) return c3d::INVALID_ARGUMENT~;
        renderer.upload_texture(desc.post.grade.lut)!;
    }
}

fn uint[<2>] view_output_extent(Renderer* renderer, ViewDesc* desc) @private {
    switch (desc.output) {
        case WINDOW:
            if (!renderer.swapchain.is_valid()) return { 0, 0 };
            return { renderer.swapchain_info.width, renderer.swapchain_info.height };
        case TEXTURE:
            Target* target = &renderer.targets.get(desc.target).target;
            return { target.width, target.height };
    }
}

fn gpu::Format view_output_format(Renderer* renderer, ViewDesc* desc) @private {
    switch (desc.output) {
        case WINDOW: return renderer.swapchain_info.format;
        case TEXTURE: return renderer.targets.get(desc.target).target.format;
    }
}

fn uint[<2>] view_working_extent(Renderer* renderer, ViewRecord* record) @private {
    uint[<2>] output = view_output_extent(renderer, &record.desc);
    if (output.x == 0 || output.y == 0) return { 0, 0 };
    return working_extent(record.desc.viewport, output.x, output.y, record.desc.render_scale);
}

fn void? acquire_view_images(Renderer* renderer, ViewRecord* record) @private {
    uint[<2>] extent = view_working_extent(renderer, record);
    if (extent.x == 0 || extent.y == 0) return;
    defer catch release_view_images(renderer, record);
    acquire_view_targets(renderer, record, extent.x, extent.y)!;
    if (record.desc.post.fxaa) post::acquire_post_targets(renderer, record)!;
    post::acquire_effect_targets(renderer, record)!;
}

fn void release_view_images(Renderer* renderer, ViewRecord* record) @private {
    release_scene_color(&renderer.device, record);
    release_view_targets(&renderer.device, record);
    post::release_post_targets(&renderer.device, record);
    post::release_effect_targets(&renderer.device, record);
    free_view_history(renderer.allocator, &record.history);
}

fn void? resize_view(Renderer* renderer, ViewRecord* record) @private {
    release_view_images(renderer, record);
    record.history.valid = false;
    return acquire_view_images(renderer, record);
}

fn bool lut_desc_valid(material::TextureDesc* desc) @private {
    bool rgba8 = desc.format == PixelFormat.RGBA8_UNORM || desc.format == PixelFormat.RGBA8_SRGB;
    return desc.depth > 0 && desc.layers == 1 && desc.mip_levels == 1 && !desc.generate_mips && !desc.is_cube && rgba8;
}
