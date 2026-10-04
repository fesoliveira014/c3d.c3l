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
 Ray-query effects of a view; zero disables all.
*>
struct RayTracingDesc {
    bool  shadows;
    bool  reflections;
    float max_reflection_roughness;
}

<*
 CPU configuration of one view; copied into its record.
*>
struct ViewDesc {
    ViewOutput           output;
    RenderTargetId       target;
    PixelRect            viewport;
    float                render_scale;
    float                lod_bias;
    OutputMode           color;
    PostStack            post;
    ShadingPath          shading;
    bool                 depth_prepass;
    LightSelection       lights;
    ClusterDesc          clusters;
    RayTracingDesc       ray_tracing;
    AmbientOcclusionDesc ambient_occlusion;
    ScreenSpaceGiDesc    screen_space_gi;
    PathTraceDesc        path_trace;
    bool                 instance_culling;
    Plane                clip_plane; // world space; the zero plane clips nothing
    bool                 volumetric_fog; // a froxel volume for the view's HeightFog; allocated with the view
}

<*
 Working images one view owns, in view_targets order.
*>
const uint VIEW_TARGET_COUNT = 5 + post::BLOOM_MAX_LEVELS + 8 + GBUFFER_CHANNEL_COUNT
  + 3 * post::TAA_HISTORY_SLOTS + 1 + 2 + 2 + 1 + 1 + 2 * SSGI_HISTORY_SLOTS + 2 + 1 + 3;

<*
 Reverse-Z projection terms that recover forward distance from stored depth.
*>
struct ProjectionTerms {
    float m22;
    float m23;
    bool  orthographic;
}

<*
 Deformation, instance matrices and sway a node had when the view last rendered it.
*>
struct PoseRecord {
    Mat4f[]           palette;
    // Node-local, unlike the world-space instance records: a node moves between renderings without an
    // edit, and the root's prev_model carries that motion, so these follow the batch revision alone.
    Mat4f[]           instances;
    uint              instance_count;
    uint              instance_revision; // batch revision of instances; 0 = none
    MorphWeightsGpu   morph;
    MorphWeightsGpu[] morphs;
    bool              morphed;
    InstanceSway      sway;
    Vec3[]            vertices;        // base positions of a vertex_motion mesh; capacity outlives tracking
    GeometryId        vertex_geometry; // source of vertices; zero when the last rendering did not track
    uint              vertex_revision; // geometry revision vertices were copied at
}

<*
 Camera, time and tagged node poses of the view's last rendering.
*>
struct ViewHistory {
    bool         valid;
    bool         pending;
    ulong        scene;
    ulong        serial;
    Mat4         view_proj;
    Vec3         origin;
    double       time;
    Mat4[]       models;
    Entity[]     owners;
    ulong[]      seen;
    PoseRecord[] poses;
    uint         sample_index;
    uint         slot;
    uint         accumulated_samples;
    uint         pending_samples;
    ulong        trace_revision;
}

<*
 Whether the node was drawn by the last published rendering of this view.
 @param [&in] scene : "Scene the node belongs to."
 @param [&in] node : "Live node."
*>
fn bool ViewHistory.has_previous(&self, Scene* scene, Node* node) {
    if (!self.valid || scene.identity != self.scene || node.id.index >= self.owners.len) return false;
    Entity owner = self.owners[node.id.index];
    return c3d::same_id(owner, node.id) && self.seen[node.id.index] == self.serial;
}

<*
 World matrix the node had when this view last rendered it.
 @param [&in] scene : "Scene the node belongs to."
 @param [&in] node : "Live node."
 @require self.has_previous(scene, node)
*>
fn Mat4 ViewHistory.previous_model(&self, Scene* scene, Node* node) {
    return self.models[node.id.index];
}

<*
 Deformation and instances the node had when this view last rendered it.
 @param [&in] scene : "Scene the node belongs to."
 @param [&in] node : "Live node."
 @require self.has_previous(scene, node)
*>
fn PoseRecord* ViewHistory.previous_pose(&self, Scene* scene, Node* node) {
    return &self.poses[node.id.index];
}

<*
 Remember the rendering's candidates, deformation, camera and time, pending publication.
 @param [&in] assets : "Resolves skeleton inverse binds."
 @param [&in] scene : "Sizes the tables to its node capacity and identifies the history."
 @param candidates : "Every mesh this rendering drew."
 @param time : "FrameInfo.time of this rendering."
 @param origin : "Absolute origin of the supplied view projection."
*>
fn void ViewHistory.commit(
    &self,
    Allocator allocator,
    AssetStore* assets,
    Scene* scene,
    MeshCandidate[] candidates,
    Mat4 view_proj,
    double time,
    Vec3 origin = {},
) {
    if (self.models.len != scene.nodes.len) {
        uint sample_index = self.sample_index;
        uint slot = self.slot;
        free_view_history(allocator, self);
        self.sample_index = sample_index;
        self.slot = slot;
        self.models = alloc::new_array(allocator, Mat4, scene.nodes.len);
        self.owners = alloc::new_array(allocator, Entity, scene.nodes.len);
        self.seen = alloc::new_array(allocator, ulong, scene.nodes.len);
        self.poses = alloc::new_array(allocator, PoseRecord, scene.nodes.len);
    }
    bool same_scene = self.scene == scene.identity;
    self.scene = scene.identity;
    self.serial++;
    foreach (&candidate : candidates) {
        usz index = candidate.node.id.index;
        if (!same_scene || !c3d::same_id(self.owners[index], candidate.node.id)) {
            self.poses[index].instance_revision = 0;
            self.poses[index].vertex_geometry = {};
        }
        self.models[index] = candidate.node.world;
        self.owners[index] = candidate.node.id;
        self.seen[index] = self.serial;
        commit_pose(
            allocator: allocator,
            assets:    assets,
            pose:      &self.poses[index],
            candidate: candidate,
            origin:    origin,
        );
        if (!candidate.crowd) continue;
        Node* crowd_node = candidate.node.parent;
        usz crowd_index = crowd_node.id.index;
        if (c3d::same_id(self.owners[crowd_index], crowd_node.id) && self.seen[crowd_index] == self.serial) continue;
        self.models[crowd_index] = crowd_node.world;
        self.owners[crowd_index] = crowd_node.id;
        self.seen[crowd_index] = self.serial;
        commit_crowd_pose(allocator, &self.poses[crowd_index], candidate.crowd);
    }
    self.view_proj = view_proj;
    self.origin = origin;
    self.time = time;
    self.pending = true;
}

<*
 Remember the camera, scene and sample count a path-traced image holds, pending publication.
 @param scene : "Identity of the traced scene."
 @param samples : "Samples the image holds after this rendering."
 @param origin : "Absolute origin of the supplied view projection."
*>
fn void ViewHistory.commit_accumulation(
    &self,
    ulong scene,
    ulong trace_revision,
    Mat4 view_proj,
    uint samples,
    Vec3 origin = {},
) {
    self.scene = scene;
    self.trace_revision = trace_revision;
    self.view_proj = view_proj;
    self.origin = origin;
    self.pending_samples = samples;
    self.pending = true;
}

<*
 Publish the pending rendering as the previous pose and advance the temporal sample.
*>
fn void ViewHistory.publish(&self) {
    if (!self.pending) return;
    self.valid = true;
    self.pending = false;
    self.accumulated_samples = self.pending_samples;
    self.sample_index = (self.sample_index + 1) % post::TAA_SAMPLE_COUNT;
    self.slot = (self.slot + 1) % post::TAA_HISTORY_SLOTS;
}

<*
 Drop the pending rendering; the next rendering carries no motion.
*>
fn void ViewHistory.discard(&self) {
    if (!self.pending) return;
    self.valid = false;
    self.pending = false;
}

<*
 Free the history tables.
 @param [&inout] history : "Left zeroed."
*>
fn void free_view_history(Allocator allocator, ViewHistory* history) {
    if (history.models.len) {
        foreach (&pose : history.poses) {
            alloc::free(allocator, pose.palette.ptr);
            alloc::free(allocator, pose.instances.ptr);
            alloc::free(allocator, pose.morphs.ptr);
            alloc::free(allocator, pose.vertices.ptr);
        }
        alloc::free(allocator, history.models.ptr);
        alloc::free(allocator, history.owners.ptr);
        alloc::free(allocator, history.seen.ptr);
        alloc::free(allocator, history.poses.ptr);
    }
    *history = {};
}

fn void commit_pose(
    Allocator allocator,
    AssetStore* assets,
    PoseRecord* pose,
    MeshCandidate* candidate,
    Vec3 origin,
) @local {
    Node* node = candidate.node;
    pose.sway = candidate.batch ? candidate.batch.sway : (InstanceSway){};
    if (candidate.vertex_motion) {
        capture_vertices(allocator, assets, pose, candidate.geometry);
    } else {
        pose.vertex_geometry = {};
        pose.vertex_revision = 0;
    }
    if (candidate.skin) {
        SkinBinding* binding = candidate.skin;
        if (pose.palette.len != binding.joints.len) {
            alloc::free(allocator, pose.palette.ptr);
            pose.palette = alloc::new_array(allocator, Mat4f, binding.joints.len);
        }
        evaluate_palette(
            palette:      pose.palette,
            mesh_node:    node,
            binding:      binding,
            inverse_bind: assets.skeleton(binding.skeleton).data.inverse_bind,
            origin:       origin,
        );
    }
    pose.morphed = candidate.morph_weights.len > 0;
    if (pose.morphed) {
        geometry::MorphSelection selection = geometry::select_morph_targets(
            candidate.morph_channels,
            candidate.morph_weights,
        );
        pose.morph = pack_morph_selection(selection);
    }
    if (candidate.crowd && candidate.crowd.parts[candidate.crowd_part].target_count) {
        AnimatedCrowd* crowd = candidate.crowd;
        if (pose.morphs.len != crowd.placements.len) {
            alloc::free(allocator, pose.morphs.ptr);
            pose.morphs = alloc::new_array(allocator, MorphWeightsGpu, crowd.placements.len);
        }
        pack_crowd_morphs(
            blocks:   pose.morphs[:crowd.count],
            crowd:    crowd,
            part:     candidate.crowd_part,
            channels: assets.geometry(candidate.geometry).data.channels,
        );
    }
    if (candidate.batch) {
        InstancedMesh* batch = candidate.batch;
        if (pose.instances.len != batch.transforms.len) {
            alloc::free(allocator, pose.instances.ptr);
            pose.instances = alloc::new_array(allocator, Mat4f, batch.transforms.len);
            pose.instance_revision = 0;
        }
        if (pose.instance_revision != batch.revision) {
            write_instance_locals(pose.instances, batch);
            pose.instance_revision = batch.revision;
        }
        pose.instance_count = batch.count;
    }
}

fn void capture_vertices(
    Allocator allocator,
    AssetStore* assets,
    PoseRecord* pose,
    GeometryId geometry_id,
) @local {
    GeometryAsset* geometry = assets.geometry(geometry_id);
    Vec3[] positions = geometry.data.positions;
    if (pose.vertices.len != positions.len) {
        alloc::free(allocator, pose.vertices.ptr);
        pose.vertices = alloc::new_array(allocator, Vec3, positions.len);
        pose.vertex_geometry = {};
    }
    if (c3d::same_id(pose.vertex_geometry, geometry_id) && pose.vertex_revision == geometry.header.revision) return;
    pose.vertices[..] = positions[..];
    pose.vertex_geometry = geometry_id;
    pose.vertex_revision = geometry.header.revision;
}

<*
 Previous-frame counters and completed GPU timings of one view.
*>
struct ViewStats {
    uint              lights;
    uint              lights_dropped;
    uint              cluster_count;
    uint              cluster_overflows;
    uint              accumulated_samples;
    float[PASS_COUNT] gpu_pass_ms;
    bool[PASS_COUNT]  gpu_pass_valid @if($feat(C3D_PROFILE_GPU));
}

<*
 Renderer-owned view: its configuration, working images and recording state.
*>
struct ViewRecord {
    bool                                 live;
    ViewDesc                             desc;
    Frustum                              frustum; // of the rendering in progress; the depth prepass culls with it
    Target                               hdr_color;
    Target                               depth;
    Target                               scene_color;
    Target                               scene_depth;
    Target                               post_a;
    Target                               post_b;
    Target[post::BLOOM_MAX_LEVELS]       bloom;
    uint                                 bloom_levels;
    bool                                 bloom_recorded;
    Target                               dof_near;
    Target                               dof_far;
    Target                               dof_near_blur;
    Target                               dof_far_blur;
    Target                               tile_max;
    Target                               tile_neighbor;
    Target                               velocity;
    Target                               motion_blur_out;
    Target[GBUFFER_CHANNEL_COUNT]        gbuffer;
    Target[post::TAA_HISTORY_SLOTS]      taa_color;
    Target[post::TAA_HISTORY_SLOTS]      taa_depth;
    Target[post::TAA_HISTORY_SLOTS]      taa_velocity;
    Target                               taa_debug;
    Target                               ao_raw;
    Target                               ao;
    Target                               reflection;
    Target                               reflection_blur;
    Target                               accumulation;
    Target                               ssgi_raw;
    Target[SSGI_HISTORY_SLOTS]           ssgi_history;
    Target[SSGI_HISTORY_SLOTS]           ssgi_depth;
    Target                               ssgi_color;
    Target                               ssgi;
    Target                               sky_view;
    Target                               aerial_perspective;
    Target                               fog_volume;
    Target*                              scene_input;
    bool                                 post_chain_open;
    bool                                 rendered;
    ProjectionTerms                      projection_terms;
    float                                exposure;
    ViewHistory                          history;
    LodHistory                          lod_history;
    gpu::TextureState[VIEW_TARGET_COUNT] frame_states;
    ClusterBuffers                       clusters;
    gpu::GpuAddress                      cluster_root;
    ClusterDepth                         cluster_depth;
    ClusterReadback[FRAMES_IN_FLIGHT]    cluster_readback;
    ViewStats                            stats;
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
    foreach (channel, &target : record.gbuffer) targets[next + 8 + (uint)channel] = target;
    next += 8 + GBUFFER_CHANNEL_COUNT;
    uint slots = post::TAA_HISTORY_SLOTS;
    for (uint slot = 0; slot < slots; slot++) {
        targets[next + slot] = &record.taa_color[slot];
        targets[next + slots + slot] = &record.taa_depth[slot];
        targets[next + 2 * slots + slot] = &record.taa_velocity[slot];
    }
    targets[next + 3 * slots] = &record.taa_debug;
    targets[next + 3 * slots + 1] = &record.ao_raw;
    targets[next + 3 * slots + 2] = &record.ao;
    targets[next + 3 * slots + 3] = &record.reflection;
    targets[next + 3 * slots + 4] = &record.reflection_blur;
    targets[next + 3 * slots + 5] = &record.accumulation;
    next += 3 * slots + 6;
    targets[next] = &record.ssgi_raw;
    for (uint slot = 0; slot < SSGI_HISTORY_SLOTS; slot++) {
        targets[next + 1 + slot] = &record.ssgi_history[slot];
        targets[next + 1 + SSGI_HISTORY_SLOTS + slot] = &record.ssgi_depth[slot];
    }
    targets[next + 1 + 2 * SSGI_HISTORY_SLOTS] = &record.ssgi_color;
    targets[next + 2 + 2 * SSGI_HISTORY_SLOTS] = &record.ssgi;
    targets[next + 3 + 2 * SSGI_HISTORY_SLOTS] = &record.scene_depth;
    targets[next + 4 + 2 * SSGI_HISTORY_SLOTS] = &record.sky_view;
    targets[next + 5 + 2 * SSGI_HISTORY_SLOTS] = &record.aerial_perspective;
    targets[next + 6 + 2 * SSGI_HISTORY_SLOTS] = &record.fog_volume;
    return targets;
}

<*
 View records addressed by ViewId.
*>
alias ViewPool = Pool{ViewRecord, ViewId};

<*
 Window output at full size with neutral grading and a depth prepass.
*>
fn ViewDesc default_view_desc() {
    return {
        .output           = ViewOutput.WINDOW,
        .render_scale     = 1,
        .color            = OutputMode.DISPLAY_LDR,
        .post             = post::default_post_stack(),
        .shading          = ShadingPath.FORWARD,
        .depth_prepass    = true,
        .lights           = LightSelection.FLAT,
        .clusters         = default_cluster_desc(),
        .ray_tracing      = { .max_reflection_roughness = RT_REFLECTION_ROUGHNESS_DEFAULT },
        .path_trace       = PATH_TRACE_DEFAULT,
        .instance_culling = true,
    };
}

<*
 Texture output covering the whole target with neutral grading and a depth prepass.
*>
fn ViewDesc texture_view_desc(RenderTargetId target, OutputMode color = OutputMode.LINEAR_HDR) {
    return {
        .output           = ViewOutput.TEXTURE,
        .target           = target,
        .render_scale     = 1,
        .color            = color,
        .post             = post::default_post_stack(),
        .shading          = ShadingPath.FORWARD,
        .depth_prepass    = true,
        .lights           = LightSelection.FLAT,
        .clusters         = default_cluster_desc(),
        .ray_tracing      = { .max_reflection_roughness = RT_REFLECTION_ROUGHNESS_DEFAULT },
        .path_trace       = PATH_TRACE_DEFAULT,
        .instance_culling = true,
    };
}

<*
 Whether any live view renders deferred.
*>
fn bool Renderer.has_deferred_view(&self) {
    foreach (&record : self.views.items) {
        if (record.live && record.desc.shading == ShadingPath.DEFERRED) return true;
    }
    return false;
}

<*
 Whether any live view draws a depth prepass before shading.
*>
fn bool Renderer.has_depth_prepass_view(&self) {
    foreach (&record : self.views.items) {
        if (!record.live || record.desc.shading == ShadingPath.PATH_TRACED) continue;
        if (record.desc.shading == ShadingPath.DEFERRED || record.desc.depth_prepass) return true;
        if (record.desc.ambient_occlusion.kind != AoKind.NONE || record.desc.screen_space_gi.enabled) return true;
    }
    return false;
}

<*
 Pixel size of the view's working images; zero while the view has none.
 @return? c3d::INVALID_ID
*>
fn uint[<2>]? Renderer.view_extent(&self, ViewId view) {
    ViewRecord* record = self.views.try_get(view)!;
    return { record.hdr_color.width, record.hdr_color.height };
}

<*
 Counters and completed GPU timings of the view.
 @return? c3d::INVALID_ID
*>
fn ViewStats? Renderer.view_stats(&self, ViewId view) {
    ViewRecord* record = self.views.try_get(view)!;
    return record.stats;
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
    bool same_output = record.desc.output == desc.output && c3d::same_id(record.desc.target, desc.target);
    if (!same_output || current_extent != wanted_extent) {
        wait_frames(renderer)!;
        record.cluster_root = (gpu::GpuAddress)0;
        record.cluster_depth = {};
        record.desc = desc;
        return resize_view(renderer, record);
    }

    if (desc.post.anti_aliasing == AntiAliasing.FXAA) {
        post::acquire_post_targets(renderer, record)!;
    } else {
        post::retire_post_targets(renderer, record);
    }
    if (desc.shading == ShadingPath.DEFERRED) {
        acquire_gbuffer(renderer, record)!;
    } else {
        retire_gbuffer(renderer, record);
    }
    ClusterBuffers replacement;
    bool replace_clusters = desc.lights == LightSelection.CLUSTERED && record.hdr_color.texture.is_valid()
      && (!record.clusters.allocation.is_valid()
        || record.desc.clusters.tiles_x != desc.clusters.tiles_x
        || record.desc.clusters.tiles_y != desc.clusters.tiles_y
        || record.desc.clusters.depth_slices != desc.clusters.depth_slices
        || record.desc.clusters.lights_per_cluster != desc.clusters.lights_per_cluster);
    if (replace_clusters) {
        ClusterLayout layout = cluster_layout(
            desc: desc.clusters,
            max_lights: renderer.max_lights,
            max_groups: {
                renderer.caps.max_compute_work_group_count.x,
                renderer.caps.max_compute_work_group_count.y,
                renderer.caps.max_compute_work_group_count.z,
            },
        )!;
        replacement = create_cluster_buffers(renderer, layout)!;
    }
    if (replace_clusters || desc.lights == LightSelection.FLAT) {
        retire_cluster_buffers(renderer, &record.clusters);
        record.clusters = replacement;
        record.cluster_root = (gpu::GpuAddress)0;
    }
    if (record.desc.lights != desc.lights
        || record.desc.clusters.depth_slices != desc.clusters.depth_slices
        || record.desc.clusters.far_distance != desc.clusters.far_distance) {
        record.cluster_root = (gpu::GpuAddress)0;
        record.cluster_depth = {};
    }
    AmbientOcclusionDesc* ambient_occlusion = &desc.ambient_occlusion;
    if (ambient_occlusion.kind == AoKind.NONE
        || ambient_occlusion.full_resolution != record.desc.ambient_occlusion.full_resolution) {
        retire_ao_images(renderer, record);
    }
    if (!desc.screen_space_gi.enabled) retire_ssgi_images(renderer, record);
    if (!desc.ray_tracing.reflections) retire_reflection_images(renderer, record);
    if (desc.shading != ShadingPath.PATH_TRACED) retire_accumulation(renderer, record);
    if (desc.shading == ShadingPath.PATH_TRACED) retire_sky_view_images(renderer, record);
    if (!desc.volumetric_fog || desc.shading == ShadingPath.PATH_TRACED) retire_fog_volume(renderer, record);
    record.desc = desc;
    record.history.valid = false;
    record.history.pending = false;
    record.stats.accumulated_samples = 0;
    post::retire_effect_targets(renderer, record);
    post::acquire_effect_targets(renderer, record)!;
    acquire_ao_images(renderer, record)!;
    acquire_ssgi_images(renderer, record)!;
    acquire_reflection_images(renderer, record)!;
    acquire_accumulation(renderer, record)!;
    acquire_sky_view_images(renderer, record)!;
    acquire_fog_volume(renderer, record)!;
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
    record.history.pending = false;
    reset_lod_history(&record.lod_history);
}

fn void? validate_view_desc(Renderer* renderer, ViewDesc* desc) @private {
    if (!math::is_finite(desc.lod_bias)) return c3d::INVALID_ARGUMENT~;
    if (!clip_plane_valid(desc.clip_plane)) return c3d::INVALID_ARGUMENT~;
    if (!ambient_occlusion_desc_valid(&desc.ambient_occlusion)) return c3d::INVALID_ARGUMENT~;
    if (!screen_space_gi_desc_valid(&desc.screen_space_gi)) return c3d::INVALID_ARGUMENT~;
    RayTracingDesc* ray_tracing = &desc.ray_tracing;
    if (ray_tracing.reflections) {
        if (desc.shading != ShadingPath.DEFERRED) return c3d::UNSUPPORTED~;
        float roughness = ray_tracing.max_reflection_roughness;
        if (!math::is_finite(roughness) || roughness <= 0 || roughness > 1) return c3d::INVALID_ARGUMENT~;
    }
    if (desc.shading == ShadingPath.PATH_TRACED) {
        if (!renderer.caps.ray_tracing_pipelines.enabled) return c3d::UNSUPPORTED~;
        bool raster_only = desc.post.anti_aliasing == AntiAliasing.TAA || desc.post.motion_blur
          || desc.post.depth_of_field || desc.ambient_occlusion.kind != AoKind.NONE
          || ray_tracing.shadows || desc.lights == LightSelection.CLUSTERED || desc.screen_space_gi.enabled
          || desc.clip_plane.normal != (Vec3){} || desc.volumetric_fog;
        if (raster_only || !path_trace_desc_valid(&desc.path_trace)) return c3d::INVALID_ARGUMENT~;
    }
    if (desc.lights == LightSelection.CLUSTERED) {
        cluster_layout(
            desc: desc.clusters,
            max_lights: renderer.max_lights,
            max_groups: {
                renderer.caps.max_compute_work_group_count.x,
                renderer.caps.max_compute_work_group_count.y,
                renderer.caps.max_compute_work_group_count.z,
            },
        )!;
    }
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

fn bool clip_plane_valid(Plane plane) @local {
    if (plane.normal == (Vec3){} && plane.d == 0) return true;
    return math::is_finite(plane.d) && plane.normal.is_normalized();
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
    if (record.desc.post.anti_aliasing == AntiAliasing.FXAA) post::acquire_post_targets(renderer, record)!;
    post::acquire_effect_targets(renderer, record)!;
    if (record.desc.shading == ShadingPath.DEFERRED) acquire_gbuffer(renderer, record)!;
    acquire_ao_images(renderer, record)!;
    acquire_ssgi_images(renderer, record)!;
    acquire_reflection_images(renderer, record)!;
    acquire_accumulation(renderer, record)!;
    acquire_sky_view_images(renderer, record)!;
    acquire_fog_volume(renderer, record)!;
    if (record.desc.lights == LightSelection.CLUSTERED) {
        ClusterLayout layout = cluster_layout(
            desc: record.desc.clusters,
            max_lights: renderer.max_lights,
            max_groups: {
                renderer.caps.max_compute_work_group_count.x,
                renderer.caps.max_compute_work_group_count.y,
                renderer.caps.max_compute_work_group_count.z,
            },
        )!;
        record.clusters = create_cluster_buffers(renderer, layout)!;
    }
}

fn void release_view_images(Renderer* renderer, ViewRecord* record) @private {
    destroy_cluster_buffers(&renderer.device, &record.clusters);
    release_cluster_readback(&renderer.device, record);
    record.cluster_root = (gpu::GpuAddress)0;
    record.cluster_depth = {};
    release_scene_snapshots(&renderer.device, record);
    release_gbuffer(&renderer.device, record);
    release_ao_images(&renderer.device, record);
    release_ssgi_images(&renderer.device, record);
    release_reflection_images(&renderer.device, record);
    release_accumulation(&renderer.device, record);
    release_sky_view_images(&renderer.device, record);
    release_fog_volume(&renderer.device, record);
    release_view_targets(&renderer.device, record);
    post::release_post_targets(&renderer.device, record);
    post::release_effect_targets(&renderer.device, record);
    free_view_history(renderer.allocator, &record.history);
    free_lod_history(renderer, &record.lod_history);
    record.lod_history = {};
}

fn void? resize_view(Renderer* renderer, ViewRecord* record) @private {
    release_view_images(renderer, record);
    record.history.valid = false;
    record.history.pending = false;
    record.stats.accumulated_samples = 0;
    return acquire_view_images(renderer, record);
}

fn bool lut_desc_valid(material::TextureDesc* desc) @private {
    bool rgba8 = desc.format == PixelFormat.RGBA8_UNORM || desc.format == PixelFormat.RGBA8_SRGB;
    return desc.depth > 0 && desc.layers == 1 && desc.mip_levels == 1 && !desc.generate_mips && !desc.is_cube && rgba8;
}

fn void commit_crowd_pose(Allocator allocator, PoseRecord* pose, AnimatedCrowd* crowd) @local {
    usz capacity = (usz)crowd.joint_count * crowd.placements.len;
    if (pose.palette.len != capacity) {
        alloc::free(allocator, pose.palette.ptr);
        pose.palette = alloc::new_array(allocator, Mat4f, (sz)capacity);
    }
    pack_crowd_palettes(pose.palette[:(usz)crowd.joint_count * crowd.count], crowd);
    pose.instance_count = crowd.count;
}
