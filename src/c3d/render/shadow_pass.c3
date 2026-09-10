module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

struct ShadowDraw @private {
    MeshCandidate* candidate;
    GpuGeometry* geometry;
    gpu::GpuAddress alpha;
    bool masked;
    bool wireframe;
    bool reflected;
    gpu::CullMode cull;
}

struct ShadowDrawState @private {
    gpu::PipelineHandle pipeline;
    gpu::CullMode cull;
    gpu::FrontFace front_face;
    gpu::PrimitiveTopology topology;
}

fn gpu::PipelineHandle? shadow_pipeline_for(Renderer* renderer, bool wireframe) @private {
    PipelineKey key = {
        .vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_DEPTH_ONLY },
        .fragment = { .shader = DEPTH_ONLY },
        .depth_format = DEPTH_FORMAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
    };
    return renderer.pipelines.get(&renderer.device, key);
}

fn ShadowDraw[]? prepare_shadow_draws(Renderer* renderer, MeshCandidate[] candidates) @private {
    ShadowDraw[] draws = alloc::new_array(tmem, ShadowDraw, candidates.len);
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    foreach (index, &candidate : candidates) {
        Material* material = &renderer.assets.material(candidate.material).data;
        if (material.kind == MaterialKind.STANDARD && material.common.alpha_mode == AlphaMode.BLEND) {
            return c3d::UNSUPPORTED~;
        }
        ShadowDraw* draw = &draws[index];
        *draw = {
            .candidate = candidate,
            .geometry = ensure_geometry(renderer, candidate.geometry)!,
            .masked = material.common.alpha_mode == AlphaMode.MASK,
            .wireframe = material.common.wireframe && renderer.caps.line_polygon_mode,
            .reflected = candidate.node.world.determinant() < 0,
            .cull = material.common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK,
        };
        shadow_pipeline_for(renderer, draw.wireframe)!;
        if (!draw.masked) continue;
        TextureSlot base_map;
        switch (material.kind) {
            case BASIC: base_map = material.basic.map;
            case STANDARD: base_map = material.standard.base_color_map;
        }
        TextureBinding binding = resolve_texture_slot(renderer, base_map)!;
        gpu::MappedGpuSpan alpha = slot.upload.take(&renderer.device, BasicMaterialGpu::size, STREAM_ALIGNMENT)!;
        write_shadow_material_block((BasicMaterialGpu*)alpha.bytes.ptr, material, binding);
        draw.alpha = alpha.address;
    }
    return draws;
}

fn void? record_shadow_layer(
    Renderer* renderer,
    ShadowCascade* cascade,
    ShadowDraw[] draws,
    uint layer,
    float bias,
) @private {
    uint resolution = renderer.shadow_atlas.resolution;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan frame = slot.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
    Camera camera; // Depth-only stages consume only the fitted matrices.
    write_frame_root(
        root: (FrameRoot*)frame.bytes.ptr,
        matrices: &cascade.camera,
        camera: &camera,
        viewport: { (float)resolution, (float)resolution },
        info: renderer.info,
        frame_index: renderer.frame_index,
    );
    gpu::DepthTargetDesc depth = {
        .view = renderer.shadow_atlas.layers[layer].attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = 0 },
    };
    gpu::RenderPassDesc pass = { .depth = &depth, .width = resolution, .height = resolution };
    gpu::GraphicsState state = gpu::render_geometry_state(resolution, resolution)!;
    state.viewport = flipped_viewport(resolution, resolution);
    state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };
    state.raster.depth_bias_enable = bias != 0;
    state.raster.depth_bias_slope = -bias;
    bool view_reflected = cascade.camera.view.determinant() < 0;
    ShadowDrawState bound = {
        .pipeline = shadow_pipeline_for(renderer, draws.len ? draws[0].wireframe : false)!,
    };
    bool state_set;
    gpu::cmd_bind_pipeline(&renderer.commands, bound.pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    foreach (draw : draws) {
        ShadowDrawState wanted = {
            .pipeline = shadow_pipeline_for(renderer, draw.wireframe)!,
            .cull = draw.cull,
            .front_face = draw.reflected != view_reflected
              ? gpu::FrontFace.CLOCKWISE : gpu::FrontFace.COUNTER_CLOCKWISE,
            .topology = primitive_topology(draw.geometry.topology),
        };
        if (wanted.pipeline.index != bound.pipeline.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, wanted.pipeline)!;
        }
        if (!state_set || wanted.cull != bound.cull || wanted.front_face != bound.front_face
            || wanted.topology != bound.topology) {
            state.raster.cull_mode = wanted.cull;
            state.raster.front_face = wanted.front_face;
            state.raster.topology = wanted.topology;
            gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
            state_set = true;
        }
        bound = wanted;

        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, DrawRoot::size, STREAM_ALIGNMENT)!;
        write_draw_root(
            root: (DrawRoot*)root.bytes.ptr,
            world: draw.candidate.node.world,
            frame: frame.address,
            geometry: draw.geometry.root,
            material: draw.alpha,
            object_id: draw.candidate.node.id.index,
            flags: draw.masked ? shader::DRAW_ALPHA_MASK : 0,
        );
        GeometryLayout* layout = &draw.geometry.layout;
        if (layout.index_count) {
            gpu::cmd_draw_indexed(
                commands: &renderer.commands,
                vertex_root: root.address,
                fragment_root: root.address,
                index_span: draw.geometry.indices,
                index_count: layout.index_count,
                instance_count: 1,
                index_type: layout.flags.indices_u16 ? gpu::IndexType.U16 : gpu::IndexType.U32,
            )!;
        } else {
            gpu::cmd_draw(
                commands: &renderer.commands,
                vertex_root: root.address,
                fragment_root: root.address,
                vertex_count: layout.vertex_count,
                instance_count: 1,
            )!;
        }
        renderer.stats.draws++;
        if (draw.geometry.topology == Topology.TRIANGLES) {
            renderer.stats.triangles += (layout.index_count ? layout.index_count : layout.vertex_count) / 3;
        }
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.stats.shadow_layers++;
}

fn ShadowGpu[]? record_directional_shadows(
    Renderer* renderer,
    Scene* scene,
    Camera* camera,
    CameraMatrices* matrices,
    LightExtraction* extraction,
) @private {
    reset_shadow_timings(renderer)!;
    uint covered;
    foreach (request : extraction.shadows) {
        Light* light = scene.get(scene.node(request.light), Light);
        if (directional_cascade_splits(*camera, light.shadow).count) extraction.shadows[covered++] = request;
    }
    ShadowAllocation allocation = assign_shadow_layers(extraction.shadows[:covered], renderer.max_shadow_layers);
    renderer.stats.shadow_requests_dropped += allocation.dropped;
    if (!allocation.layer_count) return (ShadowGpu[]){};
    ensure_shadow_atlas(renderer)!;
    ExtractCounts counts;
    MeshCandidate[] candidates = extract_shadow_candidates(
        allocator: tmem,
        scene: scene,
        assets: renderer.assets,
        counts: &counts,
    );
    renderer.stats.dangling_refs += counts.dangling;
    ShadowCascade[] cascades = alloc::new_array(tmem, ShadowCascade, allocation.layer_count);
    bool[] participating = alloc::new_array(tmem, bool, candidates.len);
    ShadowGpu[] shadows = alloc::new_array(tmem, ShadowGpu, allocation.layer_count);
    foreach (request : allocation.requests) {
        Light* light = scene.get(scene.node(request.light), Light);
        CascadeSplits splits = directional_cascade_splits(*camera, light.shadow);
        LightGpu* packed = &extraction.lights[request.light_index];
        packed.shadow_first = request.first_layer;
        packed.shadow_count = request.layer_count;
        for (uint index = 0; index < request.layer_count; index++) {
            uint layer = request.first_layer + index;
            cascades[layer] = fit_directional_cascade(
                view: matrices,
                near_depth: index ? splits.far_depths[index - 1] : splits.near_depth,
                far_depth: splits.far_depths[index],
                light_direction: packed.direction_cos_outer.xyz,
                casters: candidates,
                resolution: renderer.shadow_resolution,
                normal_bias: light.shadow.normal_bias,
            );
            foreach (candidate_index, candidate : candidates) {
                if (maths::frustum_intersects_aabb(&cascades[layer].camera.frustum, candidate.world_bounds)) {
                    participating[candidate_index] = true;
                }
            }
            shadows[layer] = {
                .view_proj = bitcast(cascades[layer].camera.view_proj, Mat4f),
                .texture_index = renderer.shadow_atlas.layers[layer].view.index,
                .sampler_index = renderer.shadow_atlas.sampler,
                .normal_bias = light.shadow.normal_bias,
                .split_depth = cascades[layer].split_depth,
                .texel_size = 1.0f / (float)renderer.shadow_resolution,
            };
        }
    }
    uint included;
    foreach (index, candidate : candidates) {
        if (participating[index]) candidates[included++] = candidate;
    }
    ShadowDraw[] draws = prepare_shadow_draws(renderer, candidates[:included])!;
    ShadowDraw[] layer_draws = alloc::new_array(tmem, ShadowDraw, draws.len);
    record_pending_copies(renderer, &renderer.commands)!;
    transition_shadow_atlas(&renderer.shadow_atlas, &renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    write_pass_timestamp(
        renderer: renderer,
        frame_index: renderer.frame_index,
        pass: Pass.SHADOW_ATLAS,
        half: TIMESTAMP_BEGIN,
    )!;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    foreach (request : allocation.requests) {
        Light* light = scene.get(scene.node(request.light), Light);
        for (uint index = 0; index < request.layer_count; index++) {
            uint layer = request.first_layer + index;
            uint count;
            foreach (draw : draws) {
                if (maths::frustum_intersects_aabb(&cascades[layer].camera.frustum, draw.candidate.world_bounds)) {
                    layer_draws[count++] = draw;
                }
            }
            write_shadow_timestamp(renderer, layer, TIMESTAMP_BEGIN)!;
            record_shadow_layer(
                renderer: renderer,
                cascade: &cascades[layer],
                draws: layer_draws[:count],
                layer: layer,
                bias: light.shadow.bias,
            )!;
            write_shadow_timestamp(renderer, layer, TIMESTAMP_END)!;
            if (renderer.timestamps_enabled) slot.shadow_timings[layer] = { .light = request.light, .cascade = index };
        }
    }
    write_pass_timestamp(
        renderer: renderer,
        frame_index: renderer.frame_index,
        pass: Pass.SHADOW_ATLAS,
        half: TIMESTAMP_END,
    )!;
    slot.timed[Pass.SHADOW_ATLAS.ordinal] = true;
    if (renderer.timestamps_enabled) slot.shadow_timing_count = allocation.layer_count;
    transition_shadow_atlas(
        atlas: &renderer.shadow_atlas,
        commands: &renderer.commands,
        next: gpu::sampled_at({ .fragment_shader }),
    )!;
    return shadows;
}
