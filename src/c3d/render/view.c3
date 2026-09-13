module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;
import std::sort;

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
    gpu::GpuAddress root;
    gpu::FrontFace  front_face;
}

struct DrawState @private {
    gpu::PipelineHandle    pipeline;
    gpu::CullMode          cull;
    gpu::FrontFace         front_face;
    gpu::PrimitiveTopology topology;
    bool                   depth_test;
    bool                   depth_write;
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

    self.render_view(scene, camera_node)!;
    self.composite_view()!;

    return self.end_frame();
}

<*
 Extract, upload and record the scene from the camera into the view targets.
 Records nothing without output; authoring inputs stay stable until end_frame.
 @param [&inout] self : "Records into the current frame before composition."
 @param [&in] scene : "Pose as left by the last update_world; not advanced."
 @param [&in] camera_node : "Carries a Camera component."
 @return? c3d::INVALID_ARGUMENT, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE, gpu::DEVICE_BUSY
 @return? gpu::RESOURCE_IN_USE, gpu::DESCRIPTOR_HEAP_FULL, gpu::WAIT_TIMEOUT
 @return? c3d::INVALID_ID, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @require self.frame_open, !self.overlay_open
 @require environment_view_valid(self.assets, scene)
*>
fn void? Renderer.render_view(&self, Scene* scene, Node* camera_node) {
    if (!self.has_output) return;
    Camera* camera = scene.get(camera_node, Camera);
    if (!camera) return c3d::INVALID_ARGUMENT~;

    Vec2 viewport = { (float)self.hdr_color.width, (float)self.hdr_color.height };
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
    Frame* slot = &self.frames[self.frame_index % FRAMES_IN_FLIGHT];
    bool view_reflected = matrices.view.determinant() < 0;

    @pool() {
        ExtractCounts counts;
        MeshCandidate[] candidates = extract_candidates(
            allocator: tmem,
            scene:     scene,
            assets:    self.assets,
            camera:    &matrices,
            layers:    camera.layers,
            counts:    &counts,
        );
        self.stats.culled += counts.culled;
        self.stats.dangling_refs += counts.dangling;

        DrawItem[] items = alloc::new_array(tmem, DrawItem, candidates.len);
        usz opaque_count;
        usz transparent_count;
        bool sheen;
        foreach (&candidate : candidates) {
            GpuGeometry* geometry = ensure_geometry(self, candidate.geometry)!;
            MaterialRes* material = ensure_material(self, candidate.material)!;
            Material* material_description = &self.assets.material(candidate.material).data;
            sheen |= material_uses_sheen(material_description);
            validate_normal_geometry(
                geometry: geometry,
                material: material_description,
                bindings: &material.bindings,
                line_polygon_mode: self.caps.line_polygon_mode,
            )!;
            usz index;
            if (material_description.common.alpha_mode == AlphaMode.BLEND) {
                transparent_count++;
                index = candidates.len - transparent_count;
            } else {
                index = opaque_count++;
            }
            bool model_reflected = candidate.node.world.determinant() < 0;
            items[index] = {
                .sort_key  = draw_sort_key(
                    fragment:  material_fragment(material_description.kind),
                    material:  candidate.material,
                    geometry:  candidate.geometry,
                    ndc_depth: candidate.ndc_depth,
                ),
                .candidate = candidate,
                .geometry  = geometry,
                .material  = material,
                .front_face = model_reflected != view_reflected
                  ? gpu::FrontFace.CLOCKWISE : gpu::FrontFace.COUNTER_CLOCKWISE,
            };
        }
        DrawItem[] opaque_items = items[:opaque_count];
        DrawItem[] transparent_items = items[opaque_count:transparent_count];
        sort::quicksort(opaque_items, &by_sort_key);
        sort::quicksort(transparent_items, &by_transparent_depth);
        ViewEnvironments environments = resolve_view_environments(self, scene, sheen)!;
        record_pending_copies(self, &self.commands)!;

        LightCounts light_counts;
        LightExtraction extraction = extract_lights(
            allocator: tmem,
            scene: scene,
            frustum: &matrices.frustum,
            view_layers: camera.layers,
            capacity: self.max_lights,
            counts: &light_counts,
        );
        ShadowGpu[] shadows = record_shadows(
            renderer: self,
            scene: scene,
            camera: camera,
            matrices: &matrices,
            extraction: &extraction,
        )!;
        gpu::GpuAddress shadow_address;
        if (shadows.len) {
            gpu::MappedGpuSpan shadow_span = slot.upload.take(
                device: &self.device,
                size: shadows.len * ShadowGpu::size,
                alignment: STREAM_ALIGNMENT,
            )!;
            mem::copy(shadow_span.bytes.ptr, shadows.ptr, shadows.len * ShadowGpu::size);
            shadow_address = shadow_span.address;
        }
        LightGpu[] lights = extraction.lights;
        gpu::GpuAddress light_address;
        if (lights.len) {
            gpu::MappedGpuSpan light_span = slot.upload.take(
                device: &self.device,
                size: lights.len * LightGpu::size,
                alignment: STREAM_ALIGNMENT,
            )!;
            mem::copy(light_span.bytes.ptr, lights.ptr, lights.len * LightGpu::size);
            light_address = light_span.address;
        }
        self.stats.lights += light_counts.packed;
        self.stats.lights_dropped += light_counts.dropped;

        gpu::GpuAddress environment_address;
        if (environments.lighting) {
            environment_address = pack_lighting_environment(
                renderer: self,
                environment: environments.lighting,
                intensity: scene.environment_intensity,
                rotation: scene.environment_rotation,
                sheen: sheen,
            )!;
        }
        Vec3 ambient = environments.lighting && !scene.ambient_add
          ? (Vec3){} : scene.ambient_color * scene.ambient_intensity;
        gpu::MappedGpuSpan frame_span = slot.upload.take(&self.device, FrameRoot::size, STREAM_ALIGNMENT)!;
        write_frame_root(
            root:        (FrameRoot*)frame_span.bytes.ptr,
            matrices:    &matrices,
            camera:      camera,
            viewport:    viewport,
            info:        self.info,
            frame_index: self.frame_index,
            lights:      light_address,
            light_count: light_counts.packed,
            ambient:     { ambient.r, ambient.g, ambient.b, 0 },
            shadows:     shadow_address,
            shadow_count: (uint)shadows.len,
            environment: environment_address,
        );
        foreach (&item : items) {
            gpu::MappedGpuSpan draw_span = slot.upload.take(&self.device, DrawRoot::size, STREAM_ALIGNMENT)!;
            write_draw_root(
                root:          (DrawRoot*)draw_span.bytes.ptr,
                world:         item.candidate.node.world,
                frame:         frame_span.address,
                geometry:      item.geometry.root,
                material:      item.material.address,
                object_id:     item.candidate.node.id.index,
                layers:        item.candidate.node.layers,
                flags:         item.candidate.receive_shadow ? shader::DRAW_RECEIVE_SHADOW : 0,
                sheen_lut:     sheen ? self.environment_state.sheen_lut.view.index : (gpu::TextureIndex)0,
                sheen_sampler: sheen ? self.environment_state.sheen_sampler : (gpu::SamplerIndex)0,
            );
            item.root = draw_span.address;
        }

        self.hdr_color.transition(&self.commands, COLOR_ATTACHMENT_STATE)!;
        self.depth.transition(&self.commands, DEPTH_ATTACHMENT_STATE)!;
        if (self.timestamps_enabled && slot.timed[Pass.FORWARD_OPAQUE.ordinal]) {
            gpu::cmd_reset_timestamps(
                commands: &self.commands,
                pool: self.timestamps,
                first: pass_timestamp_slot(self.frame_index, Pass.FORWARD_OPAQUE.ordinal),
                count: TIMESTAMPS_PER_PASS,
            )!;
        }
        write_pass_timestamp(
            renderer:    self,
            frame_index: self.frame_index,
            pass:        Pass.FORWARD_OPAQUE,
            half:        TIMESTAMP_BEGIN,
        )!;
        record_opaque_pass(self, opaque_items, environments.clear_color)!;
        write_pass_timestamp(
            renderer:    self,
            frame_index: self.frame_index,
            pass:        Pass.FORWARD_OPAQUE,
            half:        TIMESTAMP_END,
        )!;
        slot.timed[Pass.FORWARD_OPAQUE.ordinal] = true;

        if (environments.sky) {
            gpu::GpuAddress sky_root = pack_sky(
                renderer: self,
                environment: environments.sky,
                frame: frame_span.address,
                intensity: scene.background.intensity,
                rotation: scene.background.rotation,
            )!;
            record_sky(self, sky_root)!;
        } else {
            reset_sky_timing(self)!;
        }

        reset_transparent_timing(self)!;
        if (transparent_items.len) {
            write_pass_timestamp(
                renderer: self,
                frame_index: self.frame_index,
                pass: Pass.FORWARD_TRANSPARENT,
                half: TIMESTAMP_BEGIN,
            )!;
            record_transparent_pass(self, transparent_items)!;
            write_pass_timestamp(
                renderer: self,
                frame_index: self.frame_index,
                pass: Pass.FORWARD_TRANSPARENT,
                half: TIMESTAMP_END,
            )!;
            slot.timed[Pass.FORWARD_TRANSPARENT.ordinal] = true;
        }
    };
}

<*
 Composite the default view into the window output.
 @param [&inout] self : "Open frame with its scene view already recorded."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::UNSUPPORTED_FEATURE, c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID
 @return? gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @require self.frame_open, !self.overlay_open
*>
fn void? Renderer.composite_view(&self) {
    if (!self.has_output) return;

    return composite_target(self, &self.hdr_color);
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
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    bool sheen;
    bool shadows_enabled;
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
        ensure_shadow_atlas(self)!;
        shadow_pipeline_for(self, false)!;
    }
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        if (!self.assets.geometries.is_live(mesh.geometry) || !self.assets.materials.is_live(mesh.material)) {
            self.stats.dangling_refs++;
        } else {
            GpuGeometry* geometry = ensure_geometry(self, mesh.geometry)!;
            MaterialRes* material = ensure_material(self, mesh.material)!;
            validate_normal_geometry(
                geometry: geometry,
                material: &self.assets.material(mesh.material).data,
                bindings: &material.bindings,
                line_polygon_mode: self.caps.line_polygon_mode,
            )!;
            Material* data = &self.assets.material(material.asset).data;
            sheen |= material_uses_sheen(data);
            pipeline_for(self, data)!;
            if (shadows_enabled && mesh.cast_shadow && scene.node(entity).visible_effective
                && data.common.alpha_mode != AlphaMode.BLEND) {
                shadow_pipeline_for(self, data.common.wireframe && self.caps.line_polygon_mode)!;
            }
        }
    };
    (void)resolve_view_environments(self, scene, sheen)!;
    if (!has_environment_preparations(self) && !self.pending_copies.len()
        && !self.pending_texture_uploads.len() && !self.pending_upload_retire.len()) return;
    return submit_pending(self);
}

<*
 Write the per-view root.
 @param [&out] root : "Overwritten whole."
 @param [&in] matrices : "Derived for the viewport."
 @param [&in] camera : "Supplies near, far and exposure."
 @param viewport : "Pixels."
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
) {
    *root = {
        .view            = bitcast(matrices.view, Mat4f),
        .proj            = bitcast(matrices.proj, Mat4f),
        .view_proj       = bitcast(matrices.view_proj, Mat4f),
        .inv_view_proj   = bitcast(matrices.inv_view_proj, Mat4f),
        .camera_position = { matrices.position.x, matrices.position.y, matrices.position.z, camera.exposure },
        .camera_params   = { camera.near, camera.far, viewport.x, viewport.y },
        .jitter_time     = { 0, 0, (float)info.time, info.delta },
        .frame_index     = (uint)frame_index,
        .lights          = lights,
        .light_count     = light_count,
        .ambient         = ambient,
        .shadows         = shadows,
        .shadow_count    = shadow_count,
        .environment     = environment,
    };
}

<*
 Write the per-draw root.
 @param [&out] root : "Overwritten whole."
 @param world : "Affine model matrix."
*>
fn void write_draw_root(
    DrawRoot* root,
    Mat4 world,
    gpu::GpuAddress frame,
    gpu::GpuAddress geometry,
    gpu::GpuAddress material,
    uint object_id,
    uint layers = scene::DEFAULT_LAYERS,
    uint flags = 0,
    gpu::TextureIndex sheen_lut = (gpu::TextureIndex)0,
    gpu::SamplerIndex sheen_sampler = (gpu::SamplerIndex)0,
) {
    Mat3 normal = maths::normal_matrix(world);
    *root = {
        .model     = bitcast(world, Mat4f),
        .normal_0  = { normal.m00, normal.m10, normal.m20, 0 },
        .normal_1  = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2  = { normal.m02, normal.m12, normal.m22, 0 },
        .frame     = frame,
        .geometry  = geometry,
        .material  = material,
        .object_id = object_id,
        .sheen_lut = sheen_lut,
        .sheen_sampler = sheen_sampler,
        .layers    = layers,
        .flags     = flags,
    };
}

fn int by_sort_key(DrawItem first, DrawItem second) @local {
    if (first.sort_key < second.sort_key) return -1;
    return first.sort_key > second.sort_key ? 1 : 0;
}

fn int by_transparent_depth(DrawItem first, DrawItem second) @local {
    return compare_transparent_candidates(*first.candidate, *second.candidate);
}

fn void? record_opaque_pass(Renderer* renderer, DrawItem[] items, Vec4 clear_color) @private {
    uint width = renderer.hdr_color.width;
    uint height = renderer.hdr_color.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view     = renderer.hdr_color.attachment,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { clear_color.r, clear_color.g, clear_color.b, clear_color.a } },
    }};
    gpu::DepthTargetDesc depth = {
        .view     = renderer.depth.attachment,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .depth = DEPTH_CLEAR },
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = width,
        .height = height,
    };

    gpu::PipelineHandle pipeline;
    if (items.len) {
        pipeline = pipeline_for(renderer, material_data(renderer, items[0].material))!;
    } else {
        PipelineKey key = {
            .vertex = { .shader = MESH },
            .fragment = { .shader = BASIC },
            .color_formats = { [0] = HDR_FORMAT },
            .color_count = 1,
            .depth_format = DEPTH_FORMAT,
            .samples = gpu::SampleCount.ONE,
            .polygon = gpu::PolygonMode.FILL,
        };
        pipeline = renderer.pipelines.get(&renderer.device, key)!;
    }

    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_draws(
        renderer: renderer,
        items: items,
        transparent: false,
        pipeline: pipeline,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? record_transparent_pass(Renderer* renderer, DrawItem[] items) @private {
    uint width = renderer.hdr_color.width;
    uint height = renderer.hdr_color.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view = renderer.hdr_color.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::DepthTargetDesc depth = {
        .view = renderer.depth.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth = &depth,
        .width = width,
        .height = height,
    };
    gpu::PipelineHandle pipeline = pipeline_for(renderer, material_data(renderer, items[0].material))!;

    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    renderer.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    renderer.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_draws(
        renderer: renderer,
        items: items,
        transparent: true,
        pipeline: pipeline,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? record_draws(
    Renderer* renderer,
    DrawItem[] items,
    bool transparent,
    gpu::PipelineHandle pipeline,
) @private {
    uint width = renderer.hdr_color.width;
    uint height = renderer.hdr_color.height;
    gpu::ColorTargetState[1] color_targets = {
        transparent ? gpu::premultiplied_alpha_blend() : gpu::color_blend_disabled(),
    };
    gpu::GraphicsState state = gpu::render_geometry_state(width, height)!;
    state.viewport = flipped_viewport(width, height);
    state.color.targets = color_targets[..];
    state.raster.front_face = gpu::FrontFace.COUNTER_CLOCKWISE;

    DrawState bound;
    bound.pipeline = pipeline;
    bool state_set;
    foreach (&item : items) {
        Material* material = material_data(renderer, item.material);
        MaterialCommon* common = &material.common;
        DrawState wanted = {
            .pipeline = pipeline_for(renderer, material)!,
            .cull = common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK,
            .front_face = item.front_face,
            .topology = primitive_topology(item.geometry.topology),
            .depth_test = common.depth_test,
            .depth_write = transparent ? false : common.depth_write,
        };
        if (wanted.pipeline.index != bound.pipeline.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, wanted.pipeline)!;
        }
        if (!state_set || wanted.cull != bound.cull || wanted.front_face != bound.front_face
            || wanted.topology != bound.topology || wanted.depth_test != bound.depth_test
            || wanted.depth_write != bound.depth_write) {
            state.raster.cull_mode = wanted.cull;
            state.raster.front_face = wanted.front_face;
            state.raster.topology = wanted.topology;
            state.depth = {
                .test_enable = wanted.depth_test,
                .write_enable = wanted.depth_write,
                .compare = gpu::CompareOp.GREATER,
            };
            gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
            state_set = true;
        }
        bound = wanted;

        GeometryLayout* layout = &item.geometry.layout;
        if (layout.index_count) {
            gpu::cmd_draw_indexed(
                commands: &renderer.commands,
                vertex_root: item.root,
                fragment_root: item.root,
                index_span: item.geometry.indices,
                index_count: layout.index_count,
                instance_count: 1,
                index_type: layout.flags.indices_u16 ? gpu::IndexType.U16 : gpu::IndexType.U32,
            )!;
        } else {
            gpu::cmd_draw(
                commands: &renderer.commands,
                vertex_root: item.root,
                fragment_root: item.root,
                vertex_count: layout.vertex_count,
                instance_count: 1,
            )!;
        }
        renderer.stats.draws++;
        if (item.geometry.topology == Topology.TRIANGLES) {
            renderer.stats.triangles += (layout.index_count ? layout.index_count : layout.vertex_count) / 3;
        }
    }
}

fn void? reset_transparent_timing(Renderer* renderer) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    if (!slot.timed[Pass.FORWARD_TRANSPARENT.ordinal]) return;
    if (renderer.timestamps_enabled) {
        gpu::cmd_reset_timestamps(
            commands: &renderer.commands,
            pool: renderer.timestamps,
            first: pass_timestamp_slot(renderer.frame_index, Pass.FORWARD_TRANSPARENT.ordinal),
            count: TIMESTAMPS_PER_PASS,
        )!;
    }
    slot.timed[Pass.FORWARD_TRANSPARENT.ordinal] = false;
}

fn void? validate_normal_geometry(
    GpuGeometry* geometry,
    Material* material,
    MaterialBindings* bindings,
    bool line_polygon_mode,
) @private {
    if (geometry.layout.flags.has_tangents) return;

    StandardParams* standard;
    bool coat_derivatives;
    switch (material.kind) {
        case BASIC:
        case TOON: return;
        case STANDARD: standard = &material.standard;
        case PHYSICAL:
            standard = &material.physical.standard;
            coat_derivatives = material.physical.clearcoat > 0
                && material.physical.clearcoat_normal_scale != 0 && bindings.clearcoat_normal.present;
    }
    bool base_derivatives = bindings.normal.present && standard.normal_scale != 0;
    if (!base_derivatives && !coat_derivatives) return;

    if (geometry.topology != Topology.TRIANGLES || (material.common.wireframe && line_polygon_mode)) {
        return c3d::UNSUPPORTED~;
    }
}

fn Material* material_data(Renderer* renderer, MaterialRes* material) @local {
    return &renderer.assets.material(material.asset).data;
}

fn ShaderVariant material_fragment(MaterialKind kind) @local {
    switch (kind) {
        case BASIC: return { .shader = BASIC };
        case STANDARD: return { .shader = STANDARD };
        case TOON: return { .shader = TOON };
        case PHYSICAL: return { .shader = PHYSICAL };
    }
}

fn gpu::PipelineHandle? pipeline_for(Renderer* renderer, Material* material) @private {
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = {
        .vertex        = { .shader = MESH },
        .fragment      = material_fragment(material.kind),
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = DEPTH_FORMAT,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
    };
    return renderer.pipelines.get(&renderer.device, key);
}

fn gpu::PrimitiveTopology primitive_topology(Topology topology) @private {
    switch (topology) {
        case TRIANGLES: return gpu::PrimitiveTopology.TRIANGLES;
        case LINES:     return gpu::PrimitiveTopology.LINES;
        case POINTS:    return gpu::PrimitiveTopology.POINTS;
    }
}

fn void? allocate_view_targets(
    gpu::Device* device,
    uint width,
    uint height,
    Target* hdr_color,
    Target* depth,
) @private {
    *hdr_color = allocate_target(
        device:     device,
        width:      width,
        height:     height,
        format:     HDR_FORMAT,
        usage:      { .color_attach, .sampled, .storage },
        debug_name: "hdr_color",
    )!;
    defer catch release_target(device, hdr_color);
    *depth = allocate_target(
        device:     device,
        width:      width,
        height:     height,
        format:     DEPTH_FORMAT,
        usage:      { .depth_attach, .sampled },
        debug_name: "depth",
    )!;
}

fn void release_view_targets(gpu::Device* device, Target* hdr_color, Target* depth) @private {
    if (hdr_color.texture.is_valid()) release_target(device, hdr_color);
    if (depth.texture.is_valid()) release_target(device, depth);
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
