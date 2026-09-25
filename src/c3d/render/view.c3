module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::instrumentation @public;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::render::post @public;
import gpu;
import std::collections::map;
import std::math;
import std::sort;

alias PreviousInstanceCache @private = HashMap{ulong, gpu::GpuAddress};

<*
 Color format of the view targets.
*>
const gpu::Format HDR_FORMAT = gpu::Format.RGBA16_FLOAT;

<*
 Depth format of the view targets.
*>
const gpu::Format DEPTH_FORMAT = gpu::Format.D32_FLOAT;

const float DEPTH_CLEAR @private = 0; // reverse-Z far

struct DrawItem @private {
    ulong           sort_key;
    MeshCandidate*  candidate;
    GpuGeometry*    geometry;
    MaterialRes*    material;
    ShaderVariant   vertex;
    gpu::PipelineHandle pipeline;
    gpu::GpuAddress skin;
    gpu::GpuAddress morph;
    gpu::GpuAddress instance_data;
    uint            instance_count;
    gpu::GpuAddress root;
    gpu::FrontFace  front_face;
    bool            moved;
}

struct MeshPreparation @private {
    bool sheen;
    bool transmission;
}

struct DrawState @private {
    gpu::PipelineHandle    pipeline;
    gpu::CullMode          cull;
    gpu::FrontFace         front_face;
    gpu::PrimitiveTopology topology;
    bool                   depth_test;
    bool                   depth_write;
    bool                   blend;
}

struct DrawPassState @private {
    gpu::ColorTargetState[] color_targets;
    gpu::CompareOp          depth_compare;
    bool                    depth_write;
}

<*
 Render one frame of the scene from the camera to the window.
 Material, environment and source descriptions remain stable for the call.
 @param [&inout] self : "Owns recording, submission and window presentation."
 @param [&in] scene : "Pose as left by the last update_world; not advanced."
 @param [&in] camera_node : "Carries a Camera component."
 @return? c3d::INVALID_ARGUMENT, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SURFACE_LOST
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE, gpu::DESCRIPTOR_HEAP_FULL
 @return? c3d::INVALID_ID, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require !self.frame_open
 @require environment_view_valid(self.assets, scene)
*>
fn void? Renderer.render(
    &self,
    Scene* scene,
    Node* camera_node,
    FrameInfo info = {},
) {
    self.begin_frame(info)!;
    defer catch abort_frame(self);

    self.render_view(scene, camera_node, self.default_view)!;
    self.finish_view(self.default_view)!;

    return self.end_frame();
}

<*
 Extract, upload and record the scene passes from the camera into the view; finish_view writes its output.
 A window view records nothing without an acquired image; authoring inputs stay stable until end_frame.
 @param [&inout] self : "Records into the current frame before composition."
 @param [&in] scene : "Pose as left by the last update_world; not advanced."
 @param [&in] camera_node : "Carries a Camera component."
 @param [in] debug : "Null draws nothing; lines drawn after transparency; not cleared."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE, gpu::DEVICE_BUSY
 @return? gpu::RESOURCE_IN_USE, gpu::DESCRIPTOR_HEAP_FULL, gpu::WAIT_TIMEOUT
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @require self.frame_open, !self.overlay_open
 @require environment_view_valid(self.assets, scene)
*>
fn void? Renderer.render_view(
    &self,
    Scene* scene,
    Node* camera_node,
    ViewId view,
    DebugDraw* debug = null,
) {
    ViewRecord* record = self.views.try_get(view)!;
    if (record.desc.output == ViewOutput.WINDOW && !self.has_output) return;
    defer catch abort_frame(self);
    begin_material_scope(self);
    defer end_material_scope(self);
    instrumentation::@scope("renderer.render_view") {
        begin_profile_view(self, view, "view.render")!;
        Camera* camera = scene.get(camera_node, Camera);
        if (!camera) return c3d::INVALID_ARGUMENT~;
        record.exposure = camera.exposure;

        Vec2 viewport = { (float)record.hdr_color.width, (float)record.hdr_color.height };
        CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
        record.projection_terms = {
            .m22          = matrices.proj.m22,
            .m23          = matrices.proj.m23,
            .orthographic = camera.projection == Projection.ORTHOGRAPHIC,
        };

        switch (record.desc.shading) {
            case FORWARD:
            case DEFERRED:
                record_raster_view(
                    renderer: self,
                    view:     view,
                    record:   record,
                    scene:    scene,
                    camera:   camera,
                    matrices: &matrices,
                    debug:    debug,
                )!;
            case PATH_TRACED:
                record_path_traced_view(
                    renderer: self,
                    record:   record,
                    scene:    scene,
                    camera:   camera,
                    matrices: &matrices,
                )!;
        }
        post::close_post_chain(self, record)!;
        end_profile_view(self)!;
        self.frame_recorded = true;
        self.work_recorded = true;
        record.rendered = true;
    };
}

<*
 @require renderer.frame_open, record.desc.shading != ShadingPath.PATH_TRACED
*>
fn void? record_raster_view(
    Renderer* renderer,
    ViewId view,
    ViewRecord* record,
    Scene* scene,
    Camera* camera,
    CameraMatrices* matrices,
    DebugDraw* debug,
) @private {
    Vec2 viewport = { (float)record.hdr_color.width, (float)record.hdr_color.height };
    bool taa = record.desc.post.anti_aliasing == AntiAliasing.TAA;
    bool temporal = taa || record.desc.post.motion_blur;
    bool ambient_occlusion = record.desc.ambient_occlusion.kind != AoKind.NONE;
    bool forward_prepass = record.desc.depth_prepass || ambient_occlusion;
    Vec2 jitter = taa
      ? post::taa_jitter(record.history.sample_index, record.hdr_color.width, record.hdr_color.height)
      : (Vec2){};
    CameraMatrices raster = taa ? camera::jitter_matrices(*matrices, jitter) : *matrices;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    bool view_reflected = matrices.view.determinant() < 0;

    @pool() {
        MeshCandidate[] candidates;
        instrumentation::@scope("view.extract") {
            ExtractCounts counts;
            candidates = extract_candidates(
                allocator: tmem,
                scene:     scene,
                assets:    renderer.assets,
                camera:    matrices,
                layers:    camera.layers,
                counts:    &counts,
            );
            renderer.stats.culled += counts.culled;
            renderer.stats.dangling_refs += counts.dangling;
        };

        DrawItem[] items;
        usz gbuffer_count;
        usz transmission_start;
        usz transparent_start;
        usz gbuffer_filled;
        usz opaque_filled;
        usz transmission_filled;
        usz transparent_filled;
        bool sheen;
        ShadingPath shading = record.desc.shading;
        instrumentation::@scope("view.resolve") {
            items = alloc::new_array(tmem, DrawItem, candidates.len);
            usz transmission_count;
            usz transparent_count;
            foreach (&candidate : candidates) {
                Material* material_data = &renderer.assets.material(candidate.material).data;
                switch (view_draw_list(material_data, shading, custom_gbuffer_stage(renderer, material_data))) {
                    case GBUFFER: gbuffer_count++;
                    case OPAQUE: break;
                    case TRANSMISSION: transmission_count++;
                    case TRANSPARENT: transparent_count++;
                }
            }
            transmission_start = candidates.len - transmission_count - transparent_count;
            transparent_start = candidates.len - transparent_count;
            foreach (&candidate : candidates) {
                GpuGeometry* geometry = resolve_geometry(renderer, candidate.geometry)!;
                Material* material_description = &renderer.assets.material(candidate.material).data;
                MaterialRes*? resolved = resolve_material(renderer, candidate.material);
                if (catch excuse = resolved) {
                    if (!custom_material_unavailable(material_description, excuse)) return excuse~;
                    renderer.stats.dangling_refs++;
                    continue;
                }
                MaterialRes* material = resolved;
                sheen |= material_uses_sheen(material_description);
                validate_normal_geometry(
                    geometry: geometry,
                    material: material_description,
                    bindings: &material.bindings,
                    line_polygon_mode: renderer.caps.line_polygon_mode,
                )!;
                ShaderVariant vertex = candidate_vertex_variant(geometry.layout.flags, candidate);
                bool custom_gbuffer = custom_gbuffer_stage(renderer, material_description);
                DrawList list = view_draw_list(material_description, shading, custom_gbuffer);
                gpu::PipelineHandle? pipeline = list == DrawList.GBUFFER
                  ? gbuffer_pipeline_for(renderer, material_description, vertex)
                  : pipeline_for(renderer, material_description, vertex, record.desc.ray_tracing.shadows);
                if (catch excuse = pipeline) {
                    if (!custom_pipeline_rejected(renderer, material_description, excuse)) return excuse~;
                    continue;
                }
                usz index;
                switch (list) {
                    case GBUFFER: index = gbuffer_filled++;
                    case OPAQUE: index = gbuffer_count + opaque_filled++;
                    case TRANSMISSION: index = transmission_start + transmission_filled++;
                    case TRANSPARENT: index = transparent_start + transparent_filled++;
                }
                bool model_reflected = (candidate.node.world.determinant() < 0) != candidate.mirrored;
                items[index] = {
                    .sort_key  = draw_sort_key(
                        vertex:    vertex,
                        fragment:  list == DrawList.GBUFFER
                          ? gbuffer_fragment(material_description)
                          : material_fragment(material_description, record.desc.ray_tracing.shadows),
                        material:  candidate.material,
                        geometry:  candidate.geometry,
                        ndc_depth: candidate.ndc_depth,
                        custom:    material_description.kind == MaterialKind.CUSTOM
                          ? material_description.custom.shader : (ShaderId){},
                    ),
                    .candidate = candidate,
                    .geometry  = geometry,
                    .material  = material,
                    .vertex    = vertex,
                    .pipeline  = pipeline,
                    .skin      = candidate.skin ? resolve_palette(renderer, candidate.node, candidate.skin)! : (gpu::GpuAddress)0,
                    .morph     = vertex.flags & shader::SHADER_FLAG_MORPH
                      ? resolve_morph_block(renderer, candidate)! : (gpu::GpuAddress)0,
                    .instance_data  = candidate.batch ? resolve_instances(renderer, candidate)! : (gpu::GpuAddress)0,
                    .instance_count = candidate.instance_count,
                    .front_face = model_reflected != view_reflected
                      ? gpu::FrontFace.CLOCKWISE : gpu::FrontFace.COUNTER_CLOCKWISE,
                };
            }
        };
        DrawItem[] gbuffer_items = items[:gbuffer_filled];
        DrawItem[] opaque_items = items[gbuffer_count:opaque_filled];
        DrawItem[] depth_items = items[:gbuffer_count + opaque_filled];
        DrawItem[] transmission_items = items[transmission_start:transmission_filled];
        DrawItem[] transparent_items = items[transparent_start:transparent_filled];
        instrumentation::@scope("view.sort") {
            sort::quicksort(gbuffer_items, &by_sort_key);
            sort::quicksort(opaque_items, &by_sort_key);
            sort::quicksort(transmission_items, &by_transparent_depth);
            sort::quicksort(transparent_items, &by_transparent_depth);
        };

        ViewEnvironments environments;
        instrumentation::@scope("view.uploads") {
            if (transmission_items.len) acquire_scene_color(renderer, record)!;
            environments = resolve_view_environments(renderer, scene, sheen)!;
            if (record.desc.ray_tracing.reflections) acquire_environment_lut(renderer)!;
            record_pending_copies(renderer, &renderer.commands)!;
            prepare_sampled_targets(renderer, record)!;
        };

        gpu::GpuAddress trace_root;
        bool traces = record.desc.ray_tracing.shadows || record.desc.ray_tracing.reflections
          || record.desc.ambient_occlusion.kind == AoKind.RAY_TRACED;
        if (traces) {
            instrumentation::@scope("view.trace") {
                trace_root = renderer.prepare_scene_trace(scene, TraceKind.HARDWARE)!;
            };
        }

        LightCounts light_counts;
        ShadowGpu[] shadows;
        gpu::GpuAddress shadow_address;
        gpu::GpuAddress light_address;
        ClusterFrame cluster_frame;
        instrumentation::@scope("view.lights") {
            LightExtraction extraction = extract_lights(
                allocator: tmem,
                scene: scene,
                frustum: &matrices.frustum,
                view_layers: camera.layers,
                capacity: renderer.max_lights,
                counts: &light_counts,
                ray_tracing: record.desc.ray_tracing,
            );
            shadows = record_shadows(
                renderer: renderer,
                scene: scene,
                camera: camera,
                matrices: matrices,
                extraction: &extraction,
            )!;
            if (shadows.len) {
                gpu::MappedGpuSpan shadow_span = slot.upload.take(
                    device: &renderer.device,
                    size: shadows.len * ShadowGpu::size,
                    alignment: STREAM_ALIGNMENT,
                )!;
                mem::copy(shadow_span.bytes.ptr, shadows.ptr, shadows.len * ShadowGpu::size);
                shadow_address = shadow_span.address;
            }
            LightGpu[] lights = extraction.lights;
            reset_cluster_recording(renderer, record);
            if (record.desc.lights == LightSelection.CLUSTERED) {
                cluster_frame = prepare_cluster_frame(
                    renderer: renderer,
                    record: record,
                    camera: camera,
                    matrices: matrices,
                    lights: lights,
                )!;
                light_address = cluster_frame.lights;
            } else {
                light_address = upload_lights(renderer, lights)!;
            }
            renderer.stats.lights += light_counts.packed;
            renderer.stats.lights_dropped += light_counts.dropped;
            record.stats.lights = light_counts.packed;
            record.stats.lights_dropped = light_counts.dropped;
        };

        gpu::GpuAddress environment_address;
        gpu::MappedGpuSpan frame_span;
        instrumentation::@scope("view.roots") {
            if (environments.lighting) {
                environment_address = pack_lighting_environment(
                    renderer: renderer,
                    environment: environments.lighting,
                    intensity: scene.environment_intensity,
                    rotation: scene.environment_rotation,
                    sheen: sheen,
                )!;
            }
            Vec3 ambient = environments.lighting && !scene.ambient_add
              ? (Vec3){} : scene.ambient_color * scene.ambient_intensity;
            frame_span = slot.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
            write_frame_root(
                root:        (FrameRoot*)frame_span.bytes.ptr,
                matrices:    &raster,
                camera:      camera,
                viewport:    viewport,
                info:        renderer.info,
                frame_index: renderer.frame_index,
                lights:      light_address,
                light_count: light_counts.packed,
                ambient:     { ambient.r, ambient.g, ambient.b, 0 },
                shadows:     shadow_address,
                shadow_count: (uint)shadows.len,
                environment: environment_address,
                scene_color: transmission_items.len ? record.scene_color.view.index : (gpu::TextureIndex)0,
                scene_sampler: transmission_items.len ? renderer.linear_clamp_sampler : (gpu::SamplerIndex)0,
                prev_view_proj: temporal && record.history.valid ? &record.history.view_proj : &matrices.view_proj,
                clusters: cluster_frame.clusters,
                trace: trace_root,
                jitter: jitter,
                mip_bias: taa ? record.desc.post.taa_params.mip_bias : 0,
                ao_texture: ambient_occlusion ? record.ao.view.index : (gpu::TextureIndex)0,
            );
            if (record.desc.lights == LightSelection.CLUSTERED) {
                record_clusters(
                    renderer: renderer,
                    record: record,
                    view: view,
                    frame: frame_span,
                )!;
                record.cluster_root = cluster_frame.clusters;
                record.cluster_depth = cluster_frame.depth;
            }
            PreviousInstanceCache previous_instances;
            previous_instances.init(tmem);
            DrawItem[][3] draw_groups = { depth_items, transmission_items, transparent_items };
            foreach (group_index, group : draw_groups) foreach (&item : group) {
                Node* node = item.candidate.node;
                Mat4 prev_world = node.world;
                bool has_previous = temporal && record.history.has_previous(scene, node);
                if (has_previous) prev_world = record.history.previous_model(scene, node);
                bool posed = item.skin != (gpu::GpuAddress)0 || item.morph != (gpu::GpuAddress)0
                  || item.candidate.batch;
                item.moved = has_previous && (posed || !(prev_world == node.world));
                gpu::GpuAddress previous_pose;
                if (has_previous && posed && group_index == 0) {
                    previous_pose = upload_previous_pose(
                        renderer:  renderer,
                        item:      item,
                        pose:      record.history.previous_pose(scene, node),
                        instances: &previous_instances,
                    )!;
                }
                if (item.candidate.batch) prev_world = prev_world.mul(maths::inverse_affine(node.world));
                gpu::MappedGpuSpan draw_span = slot.upload.take(&renderer.device, DrawRoot::size, STREAM_ALIGNMENT)!;
                write_draw_root(
                    root:          (DrawRoot*)draw_span.bytes.ptr,
                    world:         node.world,
                    prev_world:    prev_world,
                    frame:         frame_span.address,
                    geometry:      item.geometry.root,
                    material:      item.material.address,
                    object_id:     item.candidate.node.id.index,
                    layers:        item.candidate.node.layers,
                    flags:         (item.candidate.receive_shadow ? shader::DRAW_RECEIVE_SHADOW : 0)
                      | (ambient_occlusion && group_index == 0 ? shader::DRAW_AMBIENT_OCCLUSION : 0),
                    sheen_lut:     sheen ? renderer.environment_state.sheen_lut.view.index : (gpu::TextureIndex)0,
                    sheen_sampler: sheen ? renderer.environment_state.sheen_sampler : (gpu::SamplerIndex)0,
                    skin:          item.skin,
                    morph:         item.morph,
                    instance_data: item.instance_data,
                    previous_pose: previous_pose,
                );
                item.root = draw_span.address;
            }
        };

        instrumentation::@scope("view.record") {
            record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
            record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
            gpu::GpuAddress sky_root;
            if (environments.sky) {
                sky_root = pack_sky(
                    renderer: renderer,
                    environment: environments.sky,
                    frame: frame_span.address,
                    intensity: scene.background.intensity,
                    rotation: scene.background.rotation,
                )!;
            }
            switch (shading) {
                case FORWARD:
                    if (forward_prepass) {
                        record_depth_prepass(
                            renderer:       renderer,
                            record:         record,
                            frame:          frame_span.address,
                            view_reflected: view_reflected,
                            gbuffer:        {},
                            opaque:         opaque_items,
                        )!;
                    }
                    if (ambient_occlusion) {
                        record_ambient_occlusion(renderer, record, frame_span.address)!;
                        record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
                    }
                    record_forward_pass(
                        renderer:      renderer,
                        record:        record,
                        opaque:        opaque_items,
                        transparent:   transmission_items.len ? (DrawItem[]){} : transparent_items,
                        sky_root:      sky_root,
                        sky:           environments.sky != null,
                        clear_color:   environments.clear_color,
                        color_loaded:  false,
                        depth_matched: forward_prepass,
                    )!;
                case DEFERRED:
                    record_deferred_scene(
                        renderer:       renderer,
                        record:         record,
                        frame:          frame_span.address,
                        view_reflected: view_reflected,
                        gbuffer:        gbuffer_items,
                        opaque:         opaque_items,
                        transparent:    transmission_items.len ? (DrawItem[]){} : transparent_items,
                        sky_root:       sky_root,
                        sky:            environments.sky != null,
                        clear_color:    environments.clear_color,
                    )!;
                case PATH_TRACED:
            }

            if (transmission_items.len) {
                begin_profile_pass(renderer, Pass.TRANSMISSION)!;
                record_scene_color_snapshot(renderer, record)!;
                record_loaded_pass(renderer, record, transmission_items)!;
                end_profile_pass(renderer, Pass.TRANSMISSION)!;
                if (transparent_items.len) {
                    begin_profile_pass(renderer, Pass.FORWARD_TRANSPARENT)!;
                    record_loaded_pass(renderer, record, transparent_items)!;
                    end_profile_pass(renderer, Pass.FORWARD_TRANSPARENT)!;
                }
            }

            if (debug && debug.vertices.len()) {
                record_debug_lines(renderer, record, raster.view_proj, debug)!;
            }

            if (temporal) {
                post::record_velocity(
                    renderer:  renderer,
                    record:    record,
                    items:     depth_items,
                    raster:    &raster,
                    view_proj: matrices.view_proj,
                    jitter:    jitter,
                )!;
            }
            if (taa) {
                post::record_taa(
                    renderer: renderer,
                    record:   record,
                    scene:    scene,
                    jitter:   jitter,
                )!;
            }
            if (record.desc.post.motion_blur && !post::taa_debug_enabled(&record.desc.post)) {
                post::record_motion_blur(renderer, record)!;
            }
            if (temporal) {
                record.history.commit(
                    allocator:  renderer.allocator,
                    assets:     renderer.assets,
                    scene:      scene,
                    candidates: candidates,
                    view_proj:  matrices.view_proj,
                );
            }
        };
    };
}

<*
 Record the view's depth of field and its output after its scene passes.
 A window view records nothing without an acquired image.
 @param [&inout] self : "Records into the current frame after render_view of the same view."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, !self.overlay_open
*>
fn void? Renderer.finish_view(&self, ViewId view) {
    ViewRecord* record = self.views.try_get(view)!;
    if (record.desc.output == ViewOutput.WINDOW && !self.has_output) return;
    if (!record.rendered) return c3d::INVALID_ARGUMENT~;
    defer catch abort_frame(self);
    instrumentation::@scope("renderer.finish_view") {
        begin_profile_view(self, view, "view.finish")!;
        record.rendered = false;
        bool taa_debug = post::taa_debug_enabled(&record.desc.post);
        if (record.desc.post.depth_of_field && !taa_debug) post::record_dof(self, record)!;
        record_view_output(self, record)!;
        post::close_post_chain(self, record)!;
        end_profile_view(self)!;
    };
}

<*
 Render the scene from the camera into the target once, with default post settings and no history.
 The window shows nothing new for this call.
 @param [&inout] self : "Creates and destroys a view around one frame."
 @param [&in] scene : "Pose as left by the last update_world; not advanced."
 @param [&in] camera_node : "Carries a Camera component."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SURFACE_LOST
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require !self.frame_open
 @require environment_view_valid(self.assets, scene)
*>
fn void? Renderer.render_to(
    &self,
    Scene* scene,
    Node* camera_node,
    RenderTargetId target,
    OutputMode color = OutputMode.LINEAR_HDR,
    FrameInfo info = {},
) {
    ViewId view = create_view(self, texture_view_desc(target, color))!;
    defer catch (void)destroy_view(self, view);

    self.output_suppressed = true;
    defer self.output_suppressed = false;
    self.begin_frame(info)!;
    defer catch abort_frame(self);
    self.render_view(scene, camera_node, view)!;
    self.finish_view(view)!;
    self.end_frame()!;

    wait_frames(self)!;
    return destroy_view(self, view);
}

<*
 Prepare the scene's referenced assets and pipelines, then wait.
 Material, environment and source descriptions remain stable for the call.
 @param [&inout] self : "Completes preparation outside an open frame."
 @param [&in] scene : "Read only."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::DEVICE_BUSY, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE, gpu::COMMAND_RECORDING_ERROR
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::DESCRIPTOR_HEAP_FULL
 @return? c3d::INVALID_ID, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require !self.frame_open
*>
fn void? Renderer.prepare_scene(&self, Scene* scene) {
    instrumentation::@scope("renderer.prepare_scene") {
        begin_material_scope(self);
        defer end_material_scope(self);
        open_closed_frame_slot(self)!;
        defer catch discard_uploads(self);
        bool sheen;
        bool transmission;
        bool shadows_enabled;
        bool deferred = self.has_deferred_view();
        bool prepass = self.has_depth_prepass_view();
        @pool() {
            LightCounts counts;
            ShadowRequest[] requests = collect_shadow_requests(
                allocator: tmem,
                scene: scene,
                packed: {},
                frustum: null,
                view_layers: uint::max,
                capacity: scene.count(Light),
                counts: &counts,
            );
            shadows_enabled = assign_shadow_layers(requests, self.max_shadow_layers).layer_count > 0;
        };
        if (shadows_enabled) {
            acquire_shadow_atlas(self)!;
            shadow_pipeline_for(self, false, depth_only_vertex_variant({}))!;
        }
        scene.@each(Mesh; Entity entity, Mesh* mesh) {
            bool casts = shadows_enabled && mesh.cast_shadow && scene.node(entity).visible_effective;
            MeshPreparation prepared = prepare_mesh(
                renderer:    self,
                geometry_id: mesh.geometry,
                material_id: mesh.material,
                morphed:     mesh.morph_weights.len > 0,
                depth:       casts || prepass,
                gbuffer:     deferred,
            )!;
            sheen |= prepared.sheen;
            transmission |= prepared.transmission;
        };
        scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
            bool casts = shadows_enabled && batch.cast_shadow && scene.node(entity).visible_effective;
            MeshPreparation prepared = prepare_mesh(
                renderer:    self,
                geometry_id: batch.geometry,
                material_id: batch.material,
                morphed:     false,
                depth:       casts || prepass,
                gbuffer:     deferred,
                instanced:   true,
            )!;
            sheen |= prepared.sheen;
            transmission |= prepared.transmission;
        };
        if (transmission) self.pipelines.get(&self.device, snapshot_pipeline_key())!;
        prepare_views(self)!;
        (void)resolve_view_environments(self, scene, sheen)!;
        if (!has_environment_preparations(self) && !self.pending_copies.len()
            && !self.pending_texture_uploads.len() && !self.pending_upload_retire.len()) return;
        submit_pending(self)!;
    };
}

<*
 Prepare every asset and pipeline the model's instances need, then wait.
 Material and source descriptions remain stable for the call.
 @param [&inout] self : "Completes preparation outside an open frame."
 @return? c3d::INVALID_ID, c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::DEVICE_BUSY, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require !self.frame_open
*>
fn void? Renderer.prepare_model(&self, ModelId model) {
    ModelAsset* record = self.assets.models.try_get(model)!;
    instrumentation::@scope("renderer.prepare_model") {
        begin_material_scope(self);
        defer end_material_scope(self);
        open_closed_frame_slot(self)!;
        defer catch discard_uploads(self);
        bool transmission;
        bool deferred = self.has_deferred_view();
        foreach (&mesh : record.data.meshes) {
            MeshPreparation prepared = prepare_mesh(
                renderer:    self,
                geometry_id: mesh.geometry,
                material_id: mesh.material,
                morphed:     mesh.default_morph_weights.len > 0,
                depth:       true,
                gbuffer:     deferred,
            )!;
            transmission |= prepared.transmission;
        }
        if (transmission) self.pipelines.get(&self.device, snapshot_pipeline_key())!;
        prepare_views(self)!;
        if (!self.pending_copies.len() && !self.pending_texture_uploads.len() && !self.pending_upload_retire.len()) {
            return;
        }
        submit_pending(self)!;
    };
}

fn MeshPreparation? prepare_mesh(
    Renderer* renderer,
    GeometryId geometry_id,
    MaterialId material_id,
    bool morphed,
    bool depth,
    bool gbuffer,
    bool instanced = false,
) @private {
    if (!renderer.assets.geometries.is_live(geometry_id) || !renderer.assets.materials.is_live(material_id)) {
        renderer.stats.dangling_refs++;
        return {};
    }
    GpuGeometry* geometry = resolve_geometry(renderer, geometry_id)!;
    Material* data = &renderer.assets.material(material_id).data;
    MaterialRes*? resolved = resolve_material(renderer, material_id);
    if (catch excuse = resolved) {
        if (!custom_material_unavailable(data, excuse)) return excuse~;
        renderer.stats.dangling_refs++;
        return {};
    }
    MaterialRes* material = resolved;
    validate_normal_geometry(
        geometry:          geometry,
        material:          data,
        bindings:          &material.bindings,
        line_polygon_mode: renderer.caps.line_polygon_mode,
    )!;
    uint instanced_flag = instanced ? shader::SHADER_FLAG_INSTANCED : 0;
    ShaderVariant vertex = mesh_vertex_variant(
        flags:      geometry.layout.flags,
        morphed:    morphed,
        skinned:    !instanced,
        base_flags: instanced_flag,
    );
    if (catch excuse = pipeline_for(renderer, data, vertex)) {
        if (!custom_pipeline_rejected(renderer, data, excuse)) return excuse~;
        return {};
    }
    if (gbuffer && gbuffer_encodable(data, custom_gbuffer_stage(renderer, data))) {
        if (catch excuse = gbuffer_pipeline_for(renderer, data, vertex)) {
            if (!custom_pipeline_rejected(renderer, data, excuse)) return excuse~;
            return {};
        }
    }
    if (depth && data.common.alpha_mode != AlphaMode.BLEND) {
        if (catch excuse = shadow_pipeline_for(
            renderer:     renderer,
            wireframe:    data.common.wireframe && renderer.caps.line_polygon_mode,
            vertex:       mesh_vertex_variant(
                flags:      geometry.layout.flags,
                morphed:    morphed,
                skinned:    !instanced,
                base_flags: shader::SHADER_FLAG_DEPTH_ONLY | instanced_flag,
            ),
            material:     data,
            vertex_color: data.common.alpha_mode == AlphaMode.MASK && (geometry.layout.flags.has_colors || instanced),
        )) {
            if (!custom_pipeline_rejected(renderer, data, excuse)) return excuse~;
            return {};
        }
    }
    return { .sheen = material_uses_sheen(data), .transmission = draw_list(data) == DrawList.TRANSMISSION };
}

fn void? prepare_views(Renderer* renderer) @private {
    foreach (&record : renderer.views.items) {
        if (!record.live) continue;
        post::prepare_display(renderer, record)!;
        if (record.desc.lights == LightSelection.CLUSTERED) {
            acquire_environment_pipeline(renderer, &renderer.cluster_pipeline, LIGHT_CULL)!;
        }
        if (record.desc.shading == ShadingPath.DEFERRED) {
            renderer.pipelines.get(&renderer.device, lighting_resolve_pipeline_key(record.desc.ray_tracing.shadows))!;
        }
        if (record.desc.ambient_occlusion.kind != AoKind.NONE) {
            acquire_ambient_occlusion_pipelines(renderer, record.desc.ambient_occlusion.kind)!;
        }
        if (record.desc.ray_tracing.reflections) acquire_reflection_pipelines(renderer)!;
        if (record.desc.shading == ShadingPath.PATH_TRACED) acquire_path_tracer(renderer)!;
    }
}

<*
 Write the per-view root.
 @param [&out] root : "Overwritten whole."
 @param [&in] matrices : "Rendered matrices, jittered on a TAA view."
 @param [&in] camera : "Supplies near, far and exposure."
 @param viewport : "Pixels."
 @param [in] prev_view_proj : "Unjittered; null repeats the current view-projection."
 @param clusters : "Matching frame-ring cluster root borrowed through frame completion."
 @param trace : "SceneTraceRoot address with a hardware half; zero when the view traces nothing."
 @param jitter : "NDC offset already applied to the rendered matrices."
 @param mip_bias : "Added to material texture level of detail."
 @param ao_texture : "AO sampled view; zero when the view has none."
*>
fn void write_frame_root(
    FrameRoot* root,
    CameraMatrices* matrices,
    Camera* camera,
    Vec2 viewport,
    FrameInfo info,
    ulong frame_index,
    gpu::GpuAddress lights = (gpu::GpuAddress)0,
    uint light_count = 0,
    Vec4 ambient = {},
    gpu::GpuAddress shadows = (gpu::GpuAddress)0,
    uint shadow_count = 0,
    gpu::GpuAddress environment = (gpu::GpuAddress)0,
    gpu::TextureIndex scene_color = (gpu::TextureIndex)0,
    gpu::SamplerIndex scene_sampler = (gpu::SamplerIndex)0,
    Mat4* prev_view_proj = null,
    gpu::GpuAddress clusters = (gpu::GpuAddress)0,
    gpu::GpuAddress trace = (gpu::GpuAddress)0,
    Vec2 jitter = {},
    float mip_bias = 0,
    gpu::TextureIndex ao_texture = (gpu::TextureIndex)0,
) {
    *root = {
        .view            = bitcast(matrices.view, Mat4f),
        .proj            = bitcast(matrices.proj, Mat4f),
        .view_proj       = bitcast(matrices.view_proj, Mat4f),
        .inv_view_proj   = bitcast(matrices.inv_view_proj, Mat4f),
        .prev_view_proj  = bitcast(prev_view_proj ? *prev_view_proj : matrices.view_proj, Mat4f),
        .camera_position = { matrices.position.x, matrices.position.y, matrices.position.z, camera.exposure },
        .camera_params   = { camera.near, camera.far, viewport.x, viewport.y },
        .jitter_time     = { jitter.x, jitter.y, (float)info.time, info.delta },
        .frame_index     = (uint)frame_index,
        .lights          = lights,
        .light_count     = light_count,
        .ambient         = ambient,
        .shadows         = shadows,
        .shadow_count    = shadow_count,
        .environment     = environment,
        .scene_color     = scene_color,
        .scene_sampler   = scene_sampler,
        .clusters        = clusters,
        .trace           = trace,
        .flags           = (clusters != (gpu::GpuAddress)0 ? shader::FRAME_LIGHTS_CLUSTERED : 0)
          | (trace != (gpu::GpuAddress)0 ? shader::FRAME_TRACE_PRESENT : 0)
          | (ao_texture != (gpu::TextureIndex)0 ? shader::FRAME_AO_PRESENT : 0),
        .mip_bias        = mip_bias,
        .ao_texture      = ao_texture,
    };
}

fn gpu::GpuAddress? upload_lights(Renderer* renderer, LightGpu[] lights) @private {
    if (!lights.len) return (gpu::GpuAddress)0;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(
        device:    &renderer.device,
        size:      lights.len * LightGpu::size,
        alignment: STREAM_ALIGNMENT,
    )!;
    mem::copy(span.bytes.ptr, lights.ptr, lights.len * LightGpu::size);
    return span.address;
}

<*
 Write the per-draw root.
 @param [&out] root : "Overwritten whole."
 @param world : "Affine model matrix."
 @param prev_world : "Previous model matrix; a batch's previous node motion."
 @param skin : "Joint palette address; zero when unskinned."
 @param morph : "Morph block address; zero when unmorphed."
 @param instance_data : "First instance record; zero for a mesh."
 @param previous_pose : "PreviousPoseGpu of a deformed or instanced velocity draw; zero otherwise."
*>
fn void write_draw_root(
    DrawRoot* root,
    Mat4 world,
    Mat4 prev_world,
    gpu::GpuAddress frame,
    gpu::GpuAddress geometry,
    gpu::GpuAddress material,
    uint object_id,
    uint layers = scene::DEFAULT_LAYERS,
    uint flags = 0,
    gpu::TextureIndex sheen_lut = (gpu::TextureIndex)0,
    gpu::SamplerIndex sheen_sampler = (gpu::SamplerIndex)0,
    gpu::GpuAddress skin = (gpu::GpuAddress)0,
    gpu::GpuAddress morph = (gpu::GpuAddress)0,
    gpu::GpuAddress instance_data = (gpu::GpuAddress)0,
    gpu::GpuAddress previous_pose = (gpu::GpuAddress)0,
) {
    Mat3 normal = maths::normal_matrix(world);
    *root = {
        .model         = bitcast(world, Mat4f),
        .prev_model    = bitcast(prev_world, Mat4f),
        .normal_0      = { normal.m00, normal.m10, normal.m20, 0 },
        .normal_1      = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2      = { normal.m02, normal.m12, normal.m22, 0 },
        .frame         = frame,
        .geometry      = geometry,
        .material      = material,
        .skin          = skin,
        .morph         = morph,
        .instance_data = instance_data,
        .previous_pose = previous_pose,
        .object_id     = object_id,
        .sheen_lut     = sheen_lut,
        .sheen_sampler = sheen_sampler,
        .layers        = layers,
        .flags         = flags,
    };
}

fn gpu::GpuAddress? upload_previous_pose(
    Renderer* renderer,
    DrawItem* item,
    PoseRecord* pose,
    PreviousInstanceCache* instances,
) @private {
    MeshCandidate* candidate = item.candidate;
    PreviousPoseGpu previous = { .skin = item.skin, .morph = item.morph };
    if (item.skin != (gpu::GpuAddress)0 && pose.palette.len == candidate.skin.joints.len) {
        previous.skin = upload_bytes(renderer, pose.palette.ptr, pose.palette.len * Mat4f::size)!;
    }
    if (item.morph != (gpu::GpuAddress)0 && pose.morphed) {
        previous.morph = upload_bytes(renderer, &pose.morph, MorphWeightsGpu::size)!;
    }
    if (candidate.batch && pose.instance_count == candidate.batch.count) {
        ulong key = (ulong)(uptr)candidate.node;
        gpu::GpuAddress base;
        if (try existing = instances.get(key)) {
            base = existing;
        } else {
            base = upload_bytes(renderer, pose.instances.ptr, pose.instance_count * Mat4f::size)!;
            instances.set(key, base);
        }
        previous.instances = (gpu::GpuAddress)((ulong)base + (ulong)candidate.instance_first * Mat4f::size);
    }
    return upload_bytes(renderer, &previous, PreviousPoseGpu::size);
}

fn gpu::GpuAddress? upload_bytes(Renderer* renderer, void* data, usz size) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, size, STREAM_ALIGNMENT)!;
    mem::copy(span.bytes.ptr, data, (sz)size);
    return span.address;
}

<*
 Write the per-draw root fields the depth-only stages read.
 @param [&out] root : "Overwritten whole; normal columns and previous pose stay zero."
 @param world : "Affine model matrix."
 @param skin : "Joint palette address; zero when unskinned."
 @param morph : "Morph block address; zero when unmorphed."
 @param instance_data : "First instance record; zero for a mesh."
*>
fn void write_depth_draw_root(
    DrawRoot* root,
    Mat4 world,
    gpu::GpuAddress frame,
    gpu::GpuAddress geometry,
    gpu::GpuAddress material,
    uint object_id,
    uint flags = 0,
    gpu::GpuAddress skin = (gpu::GpuAddress)0,
    gpu::GpuAddress morph = (gpu::GpuAddress)0,
    gpu::GpuAddress instance_data = (gpu::GpuAddress)0,
) {
    *root = {
        .model     = bitcast(world, Mat4f),
        .frame     = frame,
        .geometry  = geometry,
        .material  = material,
        .skin          = skin,
        .morph         = morph,
        .instance_data = instance_data,
        .object_id     = object_id,
        .flags         = flags,
    };
}

fn int by_sort_key(DrawItem first, DrawItem second) @local {
    if (first.sort_key < second.sort_key) return -1;
    return first.sort_key > second.sort_key ? 1 : 0;
}

fn int by_transparent_depth(DrawItem first, DrawItem second) @local {
    return compare_transparent_candidates(*first.candidate, *second.candidate);
}

fn void? record_forward_pass(
    Renderer* renderer,
    ViewRecord* record,
    DrawItem[] opaque,
    DrawItem[] transparent,
    gpu::GpuAddress sky_root,
    bool sky,
    Vec4 clear_color,
    bool color_loaded,
    bool depth_matched,
) @private {
    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view     = record.hdr_color.attachment,
        .load_op  = color_loaded ? gpu::LoadOp.LOAD : gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { clear_color.r, clear_color.g, clear_color.b, clear_color.a } },
    }};
    gpu::DepthTargetDesc depth = {
        .view     = record.depth.attachment,
        .load_op  = depth_matched ? gpu::LoadOp.LOAD : gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .depth = DEPTH_CLEAR },
    };
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    DrawPassState write_depth = {
        .color_targets = color_targets[..],
        .depth_compare = gpu::CompareOp.GREATER,
        .depth_write   = true,
    };
    DrawPassState match_depth = {
        .color_targets = color_targets[..],
        .depth_compare = gpu::CompareOp.EQUAL,
        .depth_write   = false,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = width,
        .height = height,
    };

    gpu::PipelineHandle bound = first_pipeline(renderer, opaque)!;
    begin_profile_pass(renderer, Pass.FORWARD_OPAQUE)!;
    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, bound)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_draws(
        renderer:   renderer,
        record:     record,
        items:      opaque,
        pipeline:   bound,
        pass_state: depth_matched ? match_depth : write_depth,
    )!;
    end_profile_pass(renderer, Pass.FORWARD_OPAQUE)!;
    if (sky) {
        begin_profile_pass(renderer, Pass.SKY)!;
        bound = record_sky_draw(renderer, record, sky_root)!;
        end_profile_pass(renderer, Pass.SKY)!;
    }
    if (transparent.len) {
        begin_profile_pass(renderer, Pass.FORWARD_TRANSPARENT)!;
        record_draws(
            renderer:   renderer,
            record:     record,
            items:      transparent,
            pipeline:   bound,
            pass_state: write_depth,
        )!;
        end_profile_pass(renderer, Pass.FORWARD_TRANSPARENT)!;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? record_depth_prepass(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    bool view_reflected,
    DrawItem[] gbuffer,
    DrawItem[] opaque,
) @private {
    MeshCandidate[] candidates = alloc::new_array(tmem, MeshCandidate, gbuffer.len + opaque.len);
    usz count;
    foreach (&item : gbuffer) candidates[count++] = *item.candidate;
    foreach (&item : opaque) candidates[count++] = *item.candidate;
    ShadowDraw[] draws = prepare_shadow_draws(renderer, candidates)!;

    uint width = record.depth.width;
    uint height = record.depth.height;
    gpu::DepthTargetDesc depth = {
        .view     = record.depth.attachment,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .depth = DEPTH_CLEAR },
    };
    gpu::RenderPassDesc pass = { .depth = &depth, .width = width, .height = height };
    gpu::GraphicsState state = gpu::render_geometry_state(width, height)!;
    state.viewport = flipped_viewport(width, height);
    state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };
    gpu::PipelineHandle first = draws.len
      ? draws[0].pipeline : shadow_pipeline_for(renderer, false, depth_only_vertex_variant({}))!;

    begin_profile_pass(renderer, Pass.DEPTH_PREPASS)!;
    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, first)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_depth_draws(
        renderer:       renderer,
        draws:          draws,
        frame:          frame,
        view_reflected: view_reflected,
        state:          &state,
        first:          first,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    end_profile_pass(renderer, Pass.DEPTH_PREPASS)!;
}

fn void? record_scene_color_snapshot(Renderer* renderer, ViewRecord* record) @private {
    record.hdr_color.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    record.scene_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CompositeRoot::size)!;
    *(CompositeRoot*)root.bytes.ptr = {
        .source_texture = record.hdr_color.view.index,
        .source_sampler = renderer.linear_clamp_sampler,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, snapshot_pipeline_key())!;
    record_fullscreen_pass(
        renderer:      renderer,
        target:        &record.scene_color,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          {},
        load:          gpu::LoadOp.DONT_CARE,
    )!;

    record.scene_color.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
}

fn void? record_view_output(Renderer* renderer, ViewRecord* record) @private {
    Target* output;
    switch (record.desc.output) {
        case WINDOW: output = &renderer.window_target;
        case TEXTURE: output = &renderer.targets.get(record.desc.target).target;
    }
    // A window can shrink under an explicit viewport before the application reconfigures the view.
    PixelRect rect = clip_rect(record.desc.viewport, output.width, output.height);
    if (record.desc.viewport.width && (rect.width == 0 || rect.height == 0)) return;

    if (post::taa_debug_enabled(&record.desc.post)) {
        post::close_post_chain(renderer, record)!;
        return composite_target(
            renderer: renderer,
            source:   record.scene_input,
            output:   output,
            rect:     rect,
        );
    }

    switch (record.desc.color) {
        case DISPLAY_LDR:
            return post::record_display(
                renderer: renderer,
                record:   record,
                output:   output,
                rect:     rect,
            );
        case LINEAR_HDR:
            post::close_post_chain(renderer, record)!;
            return composite_target(
                renderer: renderer,
                source:   record.scene_input,
                output:   output,
                rect:     rect,
            );
    }
}

fn void? prepare_sampled_targets(Renderer* renderer, ViewRecord* record) @private {
    foreach (index, &target : renderer.targets.items) {
        if (!(renderer.sampled_target_bits & (1u << index)) || !target.target.texture.is_valid()) continue;
        // A producer never samples its own output; the barrier would only pair with the output stage's.
        if (record.desc.output == ViewOutput.TEXTURE && record.desc.target.index == index) continue;
        target.target.transition(&renderer.commands, renderer.sampled_state)!;
    }
    renderer.sampled_target_bits = 0;
}

fn PixelRect clip_rect(PixelRect rect, uint width, uint height) @local {
    if (rect.width == 0 || rect.height == 0) return rect;
    if (rect.x >= width || rect.y >= height) return {};
    return {
        .x      = rect.x,
        .y      = rect.y,
        .width  = math::min(rect.width, width - rect.x),
        .height = math::min(rect.height, height - rect.y),
    };
}

fn PipelineKey snapshot_pipeline_key() @local {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = COMPOSITE },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

fn void? record_loaded_pass(Renderer* renderer, ViewRecord* record, DrawItem[] items) @private {
    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view = record.hdr_color.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::DepthTargetDesc depth = {
        .view = record.depth.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth = &depth,
        .width = width,
        .height = height,
    };
    gpu::PipelineHandle pipeline = first_pipeline(renderer, items)!;

    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    record_draws(
        renderer:   renderer,
        record:     record,
        items:      items,
        pipeline:   pipeline,
        pass_state: { .color_targets = color_targets[..], .depth_compare = gpu::CompareOp.GREATER, .depth_write = true },
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? record_draws(
    Renderer* renderer,
    ViewRecord* record,
    DrawItem[] items,
    gpu::PipelineHandle pipeline,
    DrawPassState pass_state,
) @private {
    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    gpu::ColorTargetState[] color_targets = pass_state.color_targets;
    gpu::GraphicsState state = gpu::render_geometry_state(width, height)!;
    state.viewport = flipped_viewport(width, height);
    state.color.targets = color_targets;
    state.raster.front_face = gpu::FrontFace.COUNTER_CLOCKWISE;

    DrawState bound;
    bound.pipeline = pipeline;
    bool state_set;
    foreach (&item : items) {
        Material* material = material_data(renderer, item.material);
        MaterialCommon* common = &material.common;
        bool blend = common.alpha_mode == AlphaMode.BLEND;
        DrawState wanted = {
            .pipeline = item.pipeline,
            .cull = common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK,
            .front_face = item.front_face,
            .topology = primitive_topology(item.geometry.topology),
            .depth_test = common.depth_test,
            .depth_write = blend ? false : common.depth_write && pass_state.depth_write,
            .blend = blend,
        };
        if (wanted.pipeline.index != bound.pipeline.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, wanted.pipeline)!;
        }
        if (!state_set || wanted.cull != bound.cull || wanted.front_face != bound.front_face
            || wanted.topology != bound.topology || wanted.depth_test != bound.depth_test
            || wanted.depth_write != bound.depth_write || wanted.blend != bound.blend) {
            color_targets[0] = wanted.blend ? gpu::premultiplied_alpha_blend() : gpu::color_blend_disabled();
            state.raster.cull_mode = wanted.cull;
            state.raster.front_face = wanted.front_face;
            state.raster.topology = wanted.topology;
            state.depth = {
                .test_enable = wanted.depth_test,
                .write_enable = wanted.depth_write,
                .compare = pass_state.depth_compare,
            };
            gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
            state_set = true;
        }
        bound = wanted;

        record_geometry_draw(
            renderer:       renderer,
            root:           item.root,
            geometry:       item.geometry,
            instance_count: item.instance_count,
        )!;
    }
}

fn void? record_geometry_draw(
    Renderer* renderer,
    gpu::GpuAddress root,
    GpuGeometry* geometry,
    uint instance_count,
) @private {
    GeometryLayout* layout = &geometry.layout;
    if (layout.index_count) {
        gpu::cmd_draw_indexed(
            commands:       &renderer.commands,
            vertex_root:    root,
            fragment_root:  root,
            index_span:     geometry.indices,
            index_count:    layout.index_count,
            instance_count: instance_count,
            index_type:     layout.flags.indices_u16 ? gpu::IndexType.U16 : gpu::IndexType.U32,
        )!;
    } else {
        gpu::cmd_draw(
            commands:       &renderer.commands,
            vertex_root:    root,
            fragment_root:  root,
            vertex_count:   layout.vertex_count,
            instance_count: instance_count,
        )!;
    }
    renderer.stats.draws++;
    renderer.stats.instances += instance_count;
    if (geometry.topology == Topology.TRIANGLES) {
        uint triangles = (layout.index_count ? layout.index_count : layout.vertex_count) / 3;
        renderer.stats.triangles += triangles * instance_count;
    }
}


fn void? validate_normal_geometry(
    GpuGeometry* geometry,
    Material* material,
    MaterialBindings* bindings,
    bool line_polygon_mode,
) @private {
    if (geometry.layout.flags.has_tangents) return;

    StandardParams* standard;
    bool layer_derivatives;
    switch (material.kind) {
        case BASIC:
        case TOON:
        case CUSTOM: return;
        case STANDARD: standard = &material.standard;
        case PHYSICAL:
            standard = &material.physical.standard;
            bool coat_normal_derivatives = material.physical.clearcoat > 0
                && material.physical.clearcoat_normal_scale != 0 && bindings.clearcoat_normal.present;
            layer_derivatives = coat_normal_derivatives || material.physical.anisotropy > 0;
    }
    bool base_derivatives = bindings.normal.present && standard.normal_scale != 0;
    if (!base_derivatives && !layer_derivatives) return;

    if (geometry.topology != Topology.TRIANGLES || (material.common.wireframe && line_polygon_mode)) {
        return c3d::UNSUPPORTED~;
    }
}

fn Material* material_data(Renderer* renderer, MaterialRes* material) @local {
    return &renderer.assets.material(material.asset).data;
}

fn ShaderVariant material_fragment(Material* material, bool rt_shadows) @local {
    uint flags = rt_shadows ? shader::SHADER_FLAG_RT_SHADOWS : 0;
    switch (material.kind) {
        case BASIC: return { .shader = BASIC };
        case STANDARD: return { .shader = STANDARD, .flags = flags };
        case TOON: return { .shader = TOON, .flags = flags };
        case PHYSICAL: return { .shader = PHYSICAL, .flags = flags };
        case CUSTOM: return {};
    }
}

fn gpu::PipelineHandle? pipeline_for(
    Renderer* renderer,
    Material* material,
    ShaderVariant vertex,
    bool rt_shadows = false,
) @private {
    renderer.stats.pipeline_lookups++;
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = {
        .vertex        = vertex,
        .fragment      = material_fragment(material, rt_shadows),
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = DEPTH_FORMAT,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
    };
    if (material.kind != MaterialKind.CUSTOM) return renderer.pipelines.get(&renderer.device, key);

    ShaderId shader = material.custom.shader;
    asset::ShaderDesc* stages = &renderer.assets.shader(shader).desc;
    key.shader = shader;
    key.shader_revision = renderer.shaders[shader.index].revision;
    key.custom = { .vertex = stages.vertex.shaded.len > 0, .fragment = true };
    if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = vertex.flags & shader::SHADER_FLAG_INSTANCED };
    CustomStageSource source = custom_stage_source(stages, key);
    return renderer.pipelines.get(&renderer.device, key, &source);
}

fn gpu::PipelineHandle? first_pipeline(Renderer* renderer, DrawItem[] items) @private {
    if (items.len) return items[0].pipeline;
    renderer.stats.pipeline_lookups++;
    PipelineKey key = {
        .vertex = { .shader = MESH },
        .fragment = { .shader = BASIC },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count = 1,
        .depth_format = DEPTH_FORMAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = gpu::PolygonMode.FILL,
    };
    return renderer.pipelines.get(&renderer.device, key);
}

fn bool custom_gbuffer_stage(Renderer* renderer, Material* material) @private {
    if (material.kind != MaterialKind.CUSTOM) return false;
    ShaderId shader = material.custom.shader;
    return renderer.assets.shaders.is_live(shader) && renderer.assets.shader(shader).desc.gbuffer.len > 0;
}

fn bool custom_pipeline_rejected(Renderer* renderer, Material* material, fault excuse) @private {
    return material.kind == MaterialKind.CUSTOM && pipeline_rejected(renderer, material.custom.shader, excuse);
}

fn bool custom_material_unavailable(Material* material, fault excuse) @private {
    return material.kind == MaterialKind.CUSTOM
        && (excuse == c3d::INVALID_ID || excuse == c3d::INVALID_ARGUMENT);
}

fn gpu::PrimitiveTopology primitive_topology(Topology topology) @private {
    switch (topology) {
        case TRIANGLES: return gpu::PrimitiveTopology.TRIANGLES;
        case LINES:     return gpu::PrimitiveTopology.LINES;
        case POINTS:    return gpu::PrimitiveTopology.POINTS;
    }
}

fn void? acquire_view_targets(
    Renderer* renderer,
    ViewRecord* record,
    uint width,
    uint height,
) @private {
    record.hdr_color = allocate_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     HDR_FORMAT,
        usage:      { .color_attach, .sampled, .storage },
        debug_name: "hdr_color",
    )!;
    defer catch release_view_targets(&renderer.device, record);
    record.depth = allocate_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     DEPTH_FORMAT,
        usage:      { .depth_attach, .sampled },
        debug_name: "depth",
    )!;
}

fn void release_view_targets(gpu::Device* device, ViewRecord* record) @private {
    if (record.hdr_color.texture.is_valid()) release_target(device, &record.hdr_color);
    if (record.depth.texture.is_valid()) release_target(device, &record.depth);
}

fn void? acquire_scene_color(Renderer* renderer, ViewRecord* record) @private {
    if (record.scene_color.texture.is_valid()) return;
    record.scene_color = allocate_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     HDR_FORMAT,
        usage:      { .color_attach, .sampled },
        debug_name: "scene_color",
    )!;
}

fn void release_scene_color(gpu::Device* device, ViewRecord* record) @private {
    if (record.scene_color.texture.is_valid()) release_target(device, &record.scene_color);
}

fn bool environment_view_valid(AssetStore* assets, Scene* scene) @private {
    bool lighting_valid = !assets.environments.is_live(scene.environment)
      || (scene.environment_intensity >= 0 && math::is_finite(scene.environment_intensity)
        && scene.environment_rotation.is_normalized());
    bool background_valid = scene.background.kind != BackgroundKind.ENVIRONMENT
      || !assets.environments.is_live(scene.background.environment)
      || (scene.background.intensity >= 0 && math::is_finite(scene.background.intensity)
        && scene.background.rotation.is_normalized());
    return lighting_valid && background_valid;
}
