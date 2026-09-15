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
const uint VIEW_TARGET_COUNT = 2 + post::BLOOM_MAX_LEVELS + 8;

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
    Target                               velocity;
    Target                               motion_blur_out;
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
    targets[next + 6] = &record.velocity;
    targets[next + 7] = &record.motion_blur_out;
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
 Forget the view's previous pose so the next rendering carries no motion; a camera cut.
 @param [&inout] renderer : "No open frame."
 @return? c3d::INVALID_ID
 @require !renderer.frame_open
*>
fn void? reset_view_history(Renderer* renderer, ViewId view) {
    ViewRecord* record = renderer.views.try_get(view)!;
    record.history.valid = false;
}

fn bool lut_desc_valid(material::TextureDesc* desc) @private {
    bool rgba8 = desc.format == PixelFormat.RGBA8_UNORM || desc.format == PixelFormat.RGBA8_SRGB;
    return desc.depth > 0 && desc.layers == 1 && desc.mip_levels == 1 && !desc.generate_mips && !desc.is_cube && rgba8;
}
