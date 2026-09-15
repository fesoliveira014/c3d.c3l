module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import c3d::render::post;
import gpu;

<*
 Pooled views a renderer holds at once.
*>
const uint VIEW_CAPACITY = 1; // the default window view; off-screen views raise this later

<*
 Color space the view's output keeps.
*>
enum OutputMode {
    DISPLAY_LDR,
    LINEAR_HDR,
}

<*
 CPU configuration of one view; copied into its record.
*>
struct ViewDesc {
    OutputMode color;
    PostStack  post;
}

<*
 Working images one view owns, in view_targets order.
*>
const uint VIEW_TARGET_COUNT = 2 + post::BLOOM_MAX_LEVELS + 6;

<*
 Reverse-Z projection terms that recover forward distance from stored depth.
*>
struct ProjectionTerms {
    float m22;
    float m23;
    bool  orthographic;
}

<*
 Renderer-owned view: its configuration and working images.
*>
struct ViewRecord {
    ViewDesc                             desc;
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
    targets[0] = &record.post_a;
    targets[1] = &record.post_b;
    foreach (level, &target : record.bloom) targets[2 + level] = target;
    uint next = 2 + post::BLOOM_MAX_LEVELS;
    targets[next] = &record.dof_near;
    targets[next + 1] = &record.dof_far;
    targets[next + 2] = &record.dof_near_blur;
    targets[next + 3] = &record.dof_far_blur;
    targets[next + 4] = &record.tile_max;
    targets[next + 5] = &record.tile_neighbor;
    return targets;
}

<*
 View records addressed by ViewId.
*>
alias ViewPool = Pool{ViewRecord, ViewId};

<*
 Display output with neutral grading.
*>
fn ViewDesc default_view_desc() {
    return { .color = OutputMode.DISPLAY_LDR, .post = post::default_post_stack() };
}

<*
 Replace the view's configuration; allocates or retires its working images.
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
    if (desc.color == OutputMode.LINEAR_HDR) return c3d::INVALID_ARGUMENT~;
    if (!post::post_stack_valid(&desc.post)) return c3d::INVALID_ARGUMENT~;
    if (desc.post.grade.lut.generation) {
        TextureAsset* lut = renderer.assets.textures.try_get(desc.post.grade.lut)!;
        if (!lut_desc_valid(&lut.desc)) return c3d::INVALID_ARGUMENT~;
        renderer.upload_texture(desc.post.grade.lut)!;
    }

    if (desc.post.fxaa) {
        post::ensure_post_targets(renderer, record)!;
    } else {
        post::retire_post_targets(renderer, record);
    }
    record.desc = desc;
    post::retire_effect_targets(renderer, record);
    post::ensure_effect_targets(renderer, record)!;
}

fn bool lut_desc_valid(material::TextureDesc* desc) @private {
    bool rgba8 = desc.format == PixelFormat.RGBA8_UNORM || desc.format == PixelFormat.RGBA8_SRGB;
    return desc.depth > 0 && desc.layers == 1 && desc.mip_levels == 1 && !desc.generate_mips && !desc.is_cube && rgba8;
}
