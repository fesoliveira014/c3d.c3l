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
    bool                 share_shadows;  // binds an earlier view's matching shadow set and publishes its own
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
    // Node-local matrices: ordinary batches use packed order; crowds retain logical source order.
    Mat4f[]           instances;
    uint              instance_count;
    uint              instance_revision; // batch revision of instances; 0 = none
    ulong             crowd_identity;
    ModelId           crowd_model;
    uint              crowd_model_revision;
    SkeletonId        crowd_skeleton;
    uint              crowd_skeleton_revision;
    uint[]            crowd_generations;
    GeometryId        crowd_geometry;
    uint              crowd_geometry_revision;
    uint              crowd_part;
    MorphWeightsGpu   morph;
    MorphWeightsGpu[] morphs;
    bool              morphed;
    InstanceSway      sway;
    Vec3[]            vertices;        // base positions of a vertex_motion mesh; capacity outlives tracking
    GeometryId        vertex_geometry; // source of vertices; zero when the last rendering did not track
    uint              vertex_revision; // geometry revision vertices were copied at
    AnimatedLodPoseHistory* animated_lod;
}

struct AnimatedLodPartPose @private {
    ulong seen;
    uint part;
    uint mesh_index;
    Entity source_node;
    GeometryId geometry;
    uint geometry_revision;
    SkeletonId skeleton;
    uint skeleton_revision;
    SkeletonId source_skeleton;
    uint source_skeleton_revision;
    PoseRecord pose;
}

struct AnimatedLodPoseHistory @private {
    ulong identity;
    uint descriptor_revision;
    ModelId model;
    uint model_revision;
    ulong seen;
    AnimatedLodPartPose[] parts;
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
 Borrow compatible deformation from this view's previous submitted representation.
 @param [&in] scene : "Scene containing the live candidate."
 @param [&in] assets : "Owns the admitted representation's assets."
 @param [&in] candidate : "Current selected draw representation."
 @return "Null when compatible submitted history is unavailable."
*>
fn PoseRecord* ViewHistory.previous_candidate_pose(
    &self,
    Scene* scene,
    AssetStore* assets,
    MeshCandidate* candidate,
) {
    if (!self.has_previous(scene, candidate.node)) return null;
    PoseRecord* owner = &self.poses[candidate.node.id.index];
    if (!candidate.animated_lod) return owner;

    AnimatedLodPoseHistory* history = owner.animated_lod;
    LodGroupState* state = candidate.lod.state;
    AnimatedLodBinding* binding = state.animated;
    if (!history || history.identity != state.identity
      || history.descriptor_revision != state.descriptor_revision
      || !c3d::same_id(history.model, binding.source_model)
      || history.model_revision != assets.model(binding.source_model).header.revision) return null;

    AnimatedLodPartPose* exact = &history.parts[candidate.lod_part];
    if (exact.seen == self.serial && animated_lod_representation_matches(assets, exact, candidate)) {
        return &exact.pose;
    }

    foreach (&part : history.parts) {
        if (part.seen == self.serial && animated_lod_representation_matches(assets, part, candidate)) {
            return &part.pose;
        }
    }

    return null;
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
            if (self.seen[index] != self.serial) {
                free_animated_lod_pose(allocator, self.poses[index].animated_lod);
                self.poses[index].animated_lod = null;
            }
        }
        self.models[index] = candidate.node.world;
        self.owners[index] = candidate.node.id;
        self.seen[index] = self.serial;

        if (candidate.animated_lod) {
            commit_animated_lod_pose(
                allocator: allocator,
                assets: assets,
                owner: &self.poses[index],
                candidate: candidate,
                serial: self.serial,
                origin: origin,
            );
            continue;
        }

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
            free_animated_lod_pose(allocator, pose.animated_lod);
            alloc::free(allocator, pose.palette.ptr);
            alloc::free(allocator, pose.instances.ptr);
            alloc::free(allocator, pose.morphs.ptr);
            alloc::free(allocator, pose.vertices.ptr);
            alloc::free(allocator, pose.crowd_generations.ptr);
        }
        alloc::free(allocator, history.models.ptr);
        alloc::free(allocator, history.owners.ptr);
        alloc::free(allocator, history.seen.ptr);
        alloc::free(allocator, history.poses.ptr);
    }
    *history = {};
}

fn void free_animated_lod_pose(Allocator allocator, AnimatedLodPoseHistory* history) @local {
    if (!history) return;

    foreach (&part : history.parts) {
        alloc::free(allocator, part.pose.instances.ptr);
        alloc::free(allocator, part.pose.morphs.ptr);
        alloc::free(allocator, part.pose.crowd_generations.ptr);
    }

    alloc::free(allocator, history.parts.ptr);
    alloc::free(allocator, history);
}

fn void commit_animated_lod_pose(
    Allocator allocator,
    AssetStore* assets,
    PoseRecord* owner,
    MeshCandidate* candidate,
    ulong serial,
    Vec3 origin,
) @local {
    LodGroupState* state = candidate.lod.state;
    AnimatedLodBinding* binding = state.animated;
    AnimatedLodPoseHistory* history = owner.animated_lod;
    if (!history || history.parts.len != binding.parts.len) {
        free_animated_lod_pose(allocator, history);
        history = alloc::new(allocator, AnimatedLodPoseHistory);
        history.parts = alloc::new_array(allocator, AnimatedLodPartPose, binding.parts.len);
        owner.animated_lod = history;
    }

    uint model_revision = assets.model(binding.source_model).header.revision;
    if (history.identity != state.identity || history.descriptor_revision != state.descriptor_revision
      || !c3d::same_id(history.model, binding.source_model) || history.model_revision != model_revision) {
        foreach (&part : history.parts) part.seen = 0;
        history.seen = 0;
        history.identity = state.identity;
        history.descriptor_revision = state.descriptor_revision;
        history.model = binding.source_model;
        history.model_revision = model_revision;
    }

    usz capacity = candidate.crowd ? candidate.crowd.placements.len : 1;
    uint count = candidate.crowd ? candidate.crowd.count : 1;
    if (history.seen != serial) {
        usz palette_size = capacity * binding.joint_nodes.len;
        if (owner.palette.len != palette_size) {
            alloc::free(allocator, owner.palette.ptr);
            owner.palette = alloc::new_array(allocator, Mat4f, (sz)palette_size);
        }

        if (palette_size) {
            write_animated_lod_palette(
                palette: owner.palette[:(usz)count * binding.joint_nodes.len],
                candidate: candidate,
                origin: origin,
            );
        }

        owner.instance_count = count;
        owner.crowd_identity = 0;
        if (candidate.crowd) capture_crowd_sources(allocator, assets, owner, candidate.crowd);
        history.seen = serial;
    }

    AnimatedLodPartPose* part = &history.parts[candidate.lod_part];
    if (part.seen == serial) return;

    AnimatedLodPartBinding* selected = candidate.animated_lod;
    part.seen = serial;
    part.part = candidate.lod_part;
    part.mesh_index = selected.mesh_index;
    part.source_node = candidate.source_node ? candidate.source_node.id : (Entity){};
    part.geometry = candidate.geometry;
    part.geometry_revision = assets.geometry(candidate.geometry).header.revision;
    part.skeleton = selected.skeleton;
    part.skeleton_revision = selected.skeleton.generation
      ? assets.skeleton(selected.skeleton).header.revision : 0;
    part.source_skeleton = selected.source_skeleton;
    part.source_skeleton_revision = selected.source_skeleton.generation
      ? assets.skeleton(selected.source_skeleton).header.revision : 0;

    PoseRecord* pose = &part.pose;
    if (pose.instances.len != capacity) {
        alloc::free(allocator, pose.instances.ptr);
        pose.instances = alloc::new_array(allocator, Mat4f, (sz)capacity);
    }

    pose.instance_count = count;
    pose.instance_revision = binding.source_revision;
    pose.sway = state.effects.sway;
    pose.crowd_identity = 0;
    if (candidate.crowd) capture_crowd_sources(allocator, assets, pose, candidate.crowd);

    pose.morphed = selected.weight_count > 0;
    if (pose.morphed && pose.morphs.len != capacity) {
        alloc::free(allocator, pose.morphs.ptr);
        pose.morphs = alloc::new_array(allocator, MorphWeightsGpu, (sz)capacity);
    }

    for (uint source = 0; source < count; source++) {
        pose.instances[source] = bitcast(animated_lod_part_local(candidate, source), Mat4f);
        if (pose.morphed) pose.morphs[source] = animated_lod_morph(assets, candidate, source);
    }

    if (pose.morphed && count) pose.morph = pose.morphs[0];
}

fn bool animated_lod_representation_matches(
    AssetStore* assets,
    AnimatedLodPartPose* previous,
    MeshCandidate* candidate,
) @local {
    AnimatedLodPartBinding* selected = candidate.animated_lod;
    if (previous.mesh_index != selected.mesh_index
      || !c3d::same_id(previous.geometry, candidate.geometry)
      || previous.geometry_revision != assets.geometry(candidate.geometry).header.revision) return false;

    if (candidate.source_node && !c3d::same_id(previous.source_node, candidate.source_node.id)) return false;
    if (previous.skeleton.generation && (!assets.skeletons.is_live(previous.skeleton)
      || previous.skeleton_revision != assets.skeleton(previous.skeleton).header.revision)) return false;
    if (previous.source_skeleton.generation && (!assets.skeletons.is_live(previous.source_skeleton)
      || previous.source_skeleton_revision != assets.skeleton(previous.source_skeleton).header.revision)) return false;

    return animated_lod_representations_match(candidate.lod.state, previous.part, candidate.lod_part);
}

fn bool animated_lod_representations_match(LodGroupState* state, uint first, uint second) @private {
    AnimatedLodBinding* binding = state.animated;
    AnimatedLodPartBinding* previous = &binding.parts[first];
    AnimatedLodPartBinding* current = &binding.parts[second];
    LodPart* previous_draw = &state.desc.parts[first];
    LodPart* current_draw = &state.desc.parts[second];
    if (previous.mesh_index != current.mesh_index || previous.template_node != current.template_node
      || previous.skinned != current.skinned || previous.weight_count != current.weight_count
      || !c3d::same_id(previous_draw.geometry, current_draw.geometry)
      || previous.geometry_revision != current.geometry_revision
      || !mem::equals(&previous_draw.local, &current_draw.local, Mat4::size)) return false;

    uint[] previous_weights = binding.weight_indices[previous.weight_offset:previous.weight_count];
    uint[] current_weights = binding.weight_indices[current.weight_offset:current.weight_count];
    foreach (index, weight : previous_weights) {
        if (weight != current_weights[index]) return false;
    }

    return true;
}

fn bool animated_lod_previous_valid(PoseRecord* pose, MeshCandidate* candidate, uint source) @private {
    if (!pose || source >= pose.instance_count) return false;
    if (!candidate.crowd) return source == 0;

    AnimatedCrowd* crowd = candidate.crowd;
    return source < crowd.count && pose.crowd_identity == crowd.playback.identity
      && source < pose.crowd_generations.len
      && pose.crowd_generations[source] == crowd.playback.slots[source].generation;
}

fn void commit_pose(
    Allocator allocator,
    AssetStore* assets,
    PoseRecord* pose,
    MeshCandidate* candidate,
    Vec3 origin,
) @local {
    Node* node = candidate.node;
    pose.crowd_identity = 0;
    pose.sway = candidate.batch ? candidate.batch.sway : (InstanceSway){};
    if (candidate.vertex_motion) {
        capture_vertices(
            allocator:   allocator,
            assets:      assets,
            pose:        pose,
            geometry_id: candidate.geometry,
        );
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

    if (candidate.crowd) {
        AnimatedCrowd* crowd = candidate.crowd;

        capture_crowd_sources(
            allocator: allocator,
            assets: assets,
            pose: pose,
            crowd: crowd,
        );
        pose.crowd_geometry = candidate.geometry;
        pose.crowd_geometry_revision = assets.geometry(candidate.geometry).header.revision;
        pose.crowd_part = candidate.crowd_part;

        CrowdPart* part = &crowd.parts[candidate.crowd_part];
        if (part.weight_count) {
            if (pose.morphs.len != crowd.placements.len) {
                alloc::free(allocator, pose.morphs.ptr);
                pose.morphs = alloc::new_array(allocator, MorphWeightsGpu, crowd.placements.len);
            }

            for (uint instance = 0; instance < crowd.count; instance++) {
                usz first = (usz)instance * crowd.morph_stride + part.weight_offset;
                float[] weights = crowd.morph_weights[first:part.weight_count];
                pose.morphs[instance] = pack_morph_selection(geometry::select_morph_targets(
                    assets.geometry(candidate.geometry).data.channels,
                    weights,
                ));
            }
        }
    }

    if (candidate.batch) {
        InstancedMesh* batch = candidate.batch;
        if (pose.instances.len != batch.transforms.len) {
            alloc::free(allocator, pose.instances.ptr);
            pose.instances = alloc::new_array(allocator, Mat4f, batch.transforms.len);
            pose.instance_revision = 0;
        }

        if (candidate.crowd) {
            for (uint instance = 0; instance < batch.count; instance++) {
                pose.instances[instance] = bitcast(
                    candidate.crowd.part_transform(instance, candidate.crowd_part),
                    Mat4f,
                );
            }

            pose.instance_revision = batch.revision;
        } else if (pose.instance_revision != batch.revision) {
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
 Counters, frame-start images and completed GPU timings of one view.
*>
struct ViewStats {
    uint              images; // at frame start: live working images, scene snapshots included
    uint              lights;
    uint              lights_dropped;
    uint              decals;
    uint              decals_dropped;
    uint              cluster_count;
    uint              cluster_overflows;
    uint              decal_overflows;
    uint              accumulated_samples;
    bool              shadow_set_shared; // the last raster rendering bound a set an earlier view recorded
    float             exposure; // applied multiplier, FRAMES_IN_FLIGHT frames late under auto; LINEAR_HDR applies none
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
    ulong                                last_scene; // identity of the scene this view last rendered
    ProjectionTerms                      projection_terms;
    float                                exposure;
    ViewHistory                          history;
    post::ViewExposure                   auto_exposure;
    LodHistory                          lod_history;
    gpu::TextureState[VIEW_TARGET_COUNT] frame_states;
    ClusterBuffers                       clusters;
    gpu::GpuAddress                      cluster_root;
    ClusterDepth                         cluster_depth;
    ClusterReadback[FRAMES_IN_FLIGHT]    cluster_readback;
    ViewStats                            stats;
}

struct StagedView @private {
    ViewRecord* live;
    ViewRecord  images; // the configuration and image handles live adopts; nothing else is filled
    uint[<2>]   output_extent;
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

fn uint live_view_images(ViewRecord* record) @private {
    uint images;
    foreach (target : view_targets(record)) {
        if (target.texture.is_valid()) images++;
    }
    return images;
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
        .share_shadows    = true,
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
        .share_shadows    = true,
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
    post::acquire_view_exposure(renderer, record)!;
    defer catch post::release_view_exposure(&renderer.device, record);
    defer catch release_view_images(&renderer.device, record);
    acquire_view_images(renderer, record, view_output_extent(renderer, &desc))!;
    return view;
}

<*
 Replace the view's configuration, resizing or retiring its working images.
 Needs room for every new image before an old one goes; a fault changes nothing.
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

    @pool() {
        StagedView[] staged = alloc::new_array(tmem, StagedView, 1);
        staged[0] = {
            .live          = record,
            .images        = { .desc = desc },
            .output_extent = view_output_extent(renderer, &desc),
        };
        ViewRecord* images = &staged[0].images;
        uint[<2>] current_extent = view_working_extent(renderer, record);
        uint[<2>] wanted_extent = view_working_extent(renderer, images);
        bool same_output = record.desc.output == desc.output && c3d::same_id(record.desc.target, desc.target);
        if (!same_output || current_extent != wanted_extent) {
            wait_frames(renderer)!;
            stage_views(renderer, staged)!;
            commit_resized_views(renderer, staged);
            return;
        }

        copy_view_images(images, record);
        drop_unwanted_images(images, &record.desc);
        stage_views(renderer, staged)!;
        record.auto_exposure.reconfigure(&record.desc, &desc);
        adopt_view_images(record, images);
        retire_view_images(renderer, images);
        record.desc = desc;
        record.cluster_root = (gpu::GpuAddress)0;
        record.cluster_depth = {};
        record.history.valid = false;
        record.history.pending = false;
        record.stats.accumulated_samples = 0;
    };
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
    release_view(renderer, record);
    *record = {};
    renderer.views.remove(view);
}

<*
 Forget the view's previous pose and adapted exposure; a camera cut.
 @param [&inout] renderer : "No open frame."
 @return? c3d::INVALID_ID
 @require !renderer.frame_open
*>
fn void? reset_view_history(Renderer* renderer, ViewId view) {
    ViewRecord* record = renderer.views.try_get(view)!;
    record.history.valid = false;
    record.history.pending = false;
    record.auto_exposure.history.invalidate();
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

fn void? acquire_view_images(Renderer* renderer, ViewRecord* record, uint[<2>] output) @private {
    if (!record.hdr_color.texture.is_valid()) {
        if (output.x == 0 || output.y == 0) return;
        uint[<2>] extent = working_extent(
            viewport:      record.desc.viewport,
            output_width:  output.x,
            output_height: output.y,
            render_scale:  record.desc.render_scale,
        );
        acquire_view_targets(
            renderer: renderer,
            record:   record,
            width:    extent.x,
            height:   extent.y,
        )!;
    }
    if (record.desc.post.anti_aliasing == AntiAliasing.FXAA) post::acquire_post_targets(renderer, record)!;
    post::acquire_effect_targets(renderer, record)!;
    if (record.desc.shading == ShadingPath.DEFERRED) acquire_gbuffer(renderer, record)!;
    acquire_ao_images(renderer, record)!;
    acquire_ssgi_images(renderer, record)!;
    acquire_reflection_images(renderer, record)!;
    acquire_accumulation(renderer, record)!;
    acquire_sky_view_images(renderer, record)!;
    acquire_fog_volume(renderer, record)!;
    if (record.desc.lights == LightSelection.CLUSTERED && !record.clusters.allocation.is_valid()) {
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

fn void release_view_images(gpu::Device* device, ViewRecord* record) @private {
    foreach (image : view_targets(record)) {
        if (!image.texture.is_valid()) continue;
        if (image.attachment.is_valid()) (void)gpu::destroy_attachment_view(device, image.attachment);
        release_storage_target(device, image);
    }
    record.bloom_levels = 0;
    destroy_cluster_buffers(device, &record.clusters);
}

fn void retire_view_images(Renderer* renderer, ViewRecord* record) @private {
    RetireList* retire = last_submitted_retire(renderer);
    foreach (image : view_targets(record)) {
        if (!image.texture.is_valid()) continue;
        if (image.attachment.is_valid()) {
            retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = image.attachment });
        }
        retire_storage_target(retire, image);
    }
    record.bloom_levels = 0;
    retire_cluster_buffers(renderer, &record.clusters);
}

fn void forget_view_history(Renderer* renderer, ViewRecord* record) @private {
    free_view_history(renderer.allocator, &record.history);
    free_lod_history(renderer, &record.lod_history);
}

fn void release_view(Renderer* renderer, ViewRecord* record) @private {
    release_view_images(&renderer.device, record);
    release_cluster_readback(&renderer.device, record);
    forget_view_history(renderer, record);
    post::release_view_exposure(&renderer.device, record);
}

fn void copy_view_images(ViewRecord* staged, ViewRecord* live) @private {
    Target*[VIEW_TARGET_COUNT] staged_images = view_targets(staged);
    foreach (index, image : view_targets(live)) *staged_images[index] = *image;
    staged.bloom_levels = live.bloom_levels;
    staged.clusters = live.clusters;
}

fn void drop_unwanted_images(ViewRecord* staged, ViewDesc* previous) @private {
    ViewDesc* desc = &staged.desc;
    if (desc.post.anti_aliasing != AntiAliasing.FXAA) {
        staged.post_a = {};
        staged.post_b = {};
    }
    if (desc.shading != ShadingPath.DEFERRED) staged.gbuffer = {};
    if (desc.lights == LightSelection.FLAT
        || previous.clusters.tiles_x != desc.clusters.tiles_x
        || previous.clusters.tiles_y != desc.clusters.tiles_y
        || previous.clusters.depth_slices != desc.clusters.depth_slices
        || previous.clusters.lights_per_cluster != desc.clusters.lights_per_cluster) {
        staged.clusters = {};
    }
    AmbientOcclusionDesc* ambient_occlusion = &desc.ambient_occlusion;
    if (ambient_occlusion.kind == AoKind.NONE
        || ambient_occlusion.full_resolution != previous.ambient_occlusion.full_resolution) {
        staged.ao_raw = {};
        staged.ao = {};
    }
    if (!desc.screen_space_gi.enabled) {
        staged.ssgi_raw = {};
        staged.ssgi_history = {};
        staged.ssgi_depth = {};
        staged.ssgi_color = {};
        staged.ssgi = {};
    }
    if (!desc.ray_tracing.reflections) {
        staged.reflection = {};
        staged.reflection_blur = {};
    }
    if (desc.shading != ShadingPath.PATH_TRACED) staged.accumulation = {};
    if (desc.shading == ShadingPath.PATH_TRACED) {
        staged.sky_view = {};
        staged.aerial_perspective = {};
    }
    if (!desc.volumetric_fog || desc.shading == ShadingPath.PATH_TRACED) staged.fog_volume = {};
    post::drop_stale_effect_targets(staged);
}

fn bool view_writes(ViewRecord* record, ViewOutput output, RenderTargetId target) @private {
    if (!record.live || record.desc.output != output) return false;
    return output == ViewOutput.WINDOW || c3d::same_id(record.desc.target, target);
}

fn void? stage_views(Renderer* renderer, StagedView[] views) @private {
    foreach (index, &view : views) {
        if (catch excuse = acquire_view_images(renderer, &view.images, view.output_extent)) {
            foreach_r (&staged : views[:index + 1]) release_staged_images(renderer, staged);
            return excuse~;
        }
    }
}

fn void release_staged_images(Renderer* renderer, StagedView* view) @private {
    Target*[VIEW_TARGET_COUNT] live_images = view_targets(view.live);
    foreach (index, image : view_targets(&view.images)) {
        if (image.texture == live_images[index].texture) *image = {};
    }
    if (view.images.clusters.allocation == view.live.clusters.allocation) view.images.clusters = {};
    release_view_images(&renderer.device, &view.images);
}

// Afterwards staged holds exactly the images live gave up.
fn void adopt_view_images(ViewRecord* live, ViewRecord* staged) @private {
    Target*[VIEW_TARGET_COUNT] staged_images = view_targets(staged);
    foreach (index, image : view_targets(live)) {
        Target* replacement = staged_images[index];
        if (image.texture == replacement.texture) {
            *replacement = {};
        } else {
            @swap(*image, *replacement);
        }
    }
    @swap(live.bloom_levels, staged.bloom_levels);
    if (live.clusters.allocation == staged.clusters.allocation) {
        staged.clusters = {};
    } else {
        @swap(live.clusters, staged.clusters);
    }
}

fn void commit_resized_views(Renderer* renderer, StagedView[] views) @private {
    foreach (&view : views) {
        ViewRecord* record = view.live;
        record.auto_exposure.reconfigure(&record.desc, &view.images.desc);
        adopt_view_images(record, &view.images);
        release_view_images(&renderer.device, &view.images);
        release_cluster_readback(&renderer.device, record);
        forget_view_history(renderer, record);
        record.desc = view.images.desc;
        record.cluster_root = (gpu::GpuAddress)0;
        record.cluster_depth = {};
        record.stats.accumulated_samples = 0;
    }
}

fn void? resize_views(
    Renderer* renderer,
    ViewOutput output,
    uint[<2>] extent,
    RenderTargetId target = {},
) @private {
    uint count;
    foreach (&record : renderer.views.items) {
        if (view_writes(record, output, target)) count++;
    }
    @pool() {
        StagedView[] views = alloc::new_array(tmem, StagedView, count);
        uint next;
        foreach (&record : renderer.views.items) {
            if (!view_writes(record, output, target)) continue;
            views[next] = { .live = record, .images = { .desc = record.desc }, .output_extent = extent };
            next++;
        }
        stage_views(renderer, views)!;
        commit_resized_views(renderer, views);
    };
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
    foreach (usz index, palette : crowd.palettes[:(usz)crowd.joint_count * crowd.count]) {
        pose.palette[index] = bitcast(palette, Mat4f);
    }

    pose.instance_count = crowd.count;
    pose.crowd_identity = crowd.playback.identity;
}

fn void capture_crowd_sources(
    Allocator allocator,
    AssetStore* assets,
    PoseRecord* pose,
    AnimatedCrowd* crowd,
) @private {
    if (pose.crowd_generations.len != crowd.placements.len) {
        alloc::free(allocator, pose.crowd_generations.ptr);
        pose.crowd_generations = alloc::new_array(allocator, uint, crowd.placements.len);
    }

    for (uint instance = 0; instance < crowd.count; instance++) {
        pose.crowd_generations[instance] = crowd.playback.slots[instance].generation;
    }

    pose.crowd_identity = crowd.playback.identity;
    pose.crowd_model = crowd.model;
    pose.crowd_model_revision = assets.model(crowd.model).header.revision;

    ModelTemplate* template = &assets.model(crowd.model).data;
    pose.crowd_skeleton = template.skins.len ? template.skins[0].skeleton : (SkeletonId){};
    pose.crowd_skeleton_revision = template.skins.len
      ? assets.skeleton(pose.crowd_skeleton).header.revision : 0;
}

fn bool crowd_history_matches(
    AssetStore* assets,
    MeshCandidate* candidate,
    PoseRecord* pose,
    PoseRecord* crowd_pose,
) @private {
    AnimatedCrowd* crowd = candidate.crowd;
    if (!pose || !crowd_pose || pose.crowd_identity != crowd.playback.identity
      || crowd_pose.crowd_identity != crowd.playback.identity || pose.instance_count != crowd.count
      || crowd_pose.instance_count != crowd.count || pose.crowd_part != candidate.crowd_part
      || !c3d::same_id(pose.crowd_model, crowd.model)
      || pose.crowd_model_revision != assets.model(crowd.model).header.revision
      || !c3d::same_id(pose.crowd_geometry, candidate.geometry)
      || pose.crowd_geometry_revision != assets.geometry(candidate.geometry).header.revision) return false;

    for (uint instance = 0; instance < crowd.count; instance++) {
        if (pose.crowd_generations[instance] != crowd.playback.slots[instance].generation) return false;
    }

    ModelTemplate* template = &assets.model(crowd.model).data;
    if (template.skins.len && (!c3d::same_id(pose.crowd_skeleton, template.skins[0].skeleton)
      || pose.crowd_skeleton_revision != assets.skeleton(template.skins[0].skeleton).header.revision)) return false;

    return true;
}
