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
    Material* material;
    ShaderVariant vertex;
    gpu::PipelineHandle pipeline;
    gpu::GpuAddress skin;
    gpu::GpuAddress morph;
    gpu::GpuAddress alpha;
    gpu::GpuAddress instance_data;
    uint instance_count;
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

fn gpu::PipelineHandle? shadow_pipeline_for(
    Renderer* renderer,
    bool wireframe,
    ShaderVariant vertex,
    Material* material = null,
    bool vertex_color = false,
) @private {
    renderer.stats.pipeline_lookups++;
    PipelineKey key = {
        .vertex = vertex,
        .fragment = { .shader = DEPTH_ONLY, .flags = vertex_color ? shader::SHADER_FLAG_VERTEX_COLOR : 0 },
        .depth_format = DEPTH_FORMAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
    };
    if (material && material.kind == MaterialKind.CUSTOM) {
        asset::ShaderDesc* stages = &renderer.assets.shader(material.custom.shader).desc;
        if (stages.vertex.depth.len) {
            uint instanced = vertex.flags & shader::SHADER_FLAG_INSTANCED;
            key.vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_DEPTH_ONLY | instanced };
            key.shader = material.custom.shader;
            key.shader_revision = renderer.shaders[material.custom.shader.index].revision;
            key.custom = { .vertex = true };
            CustomStageSource source = custom_stage_source(stages, key);
            return renderer.pipelines.get(&renderer.device, key, &source);
        }
    }
    return renderer.pipelines.get(&renderer.device, key);
}

<*
 Depth-only vertex stage for the geometry's deformation streams.
 @param morphed : "The mesh carries morph weights."
 @param skinned : "The mesh node carries a live skin binding."
 @pure
*>
fn ShaderVariant depth_only_vertex_variant(GeometryFlags flags, bool morphed = false, bool skinned = true) {
    return mesh_vertex_variant(
        flags:      flags,
        morphed:    morphed,
        skinned:    skinned,
        base_flags: shader::SHADER_FLAG_DEPTH_ONLY,
    );
}

fn ShadowDraw[]? prepare_shadow_draws(Renderer* renderer, MeshCandidate[] candidates) @private {
    ShadowDraw[] draws = alloc::new_array(tmem, ShadowDraw, candidates.len);
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    usz count;
    foreach (&candidate : candidates) {
        Material* material = &renderer.assets.material(candidate.material).data;
        gpu::GpuAddress custom_header;
        if (material.kind == MaterialKind.CUSTOM) {
            MaterialRes*? resolved = resolve_material(renderer, candidate.material);
            if (catch excuse = resolved) {
                if (!custom_material_unavailable(material, excuse)) return excuse~;
                renderer.stats.dangling_refs++;
                continue;
            }
            custom_header = resolved.address;
        }
        ShadowDraw* draw = &draws[count];
        GpuGeometry* geometry = resolve_geometry(renderer, candidate.geometry)!;
        ShaderVariant vertex = candidate_vertex_variant(
            flags:      geometry.layout.flags,
            candidate:  candidate,
            base_flags: shader::SHADER_FLAG_DEPTH_ONLY,
        );
        *draw = {
            .candidate = candidate,
            .geometry = geometry,
            .vertex = vertex,
            .skin = candidate.skin ? resolve_palette(renderer, candidate.node, candidate.skin)! : (gpu::GpuAddress)0,
            .morph = vertex.flags & shader::SHADER_FLAG_MORPH
              ? resolve_morph_block(renderer, candidate)! : (gpu::GpuAddress)0,
            .alpha = custom_header,
            .instance_data = candidate.batch ? resolve_instances(renderer, candidate)! : (gpu::GpuAddress)0,
            .instance_count = candidate.instance_count,
            .masked = material.common.alpha_mode == AlphaMode.MASK,
            .wireframe = material.common.wireframe && renderer.caps.line_polygon_mode,
            .reflected = (candidate.node.world.determinant() < 0) != candidate.mirrored,
            .cull = material.common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK,
        };
        gpu::PipelineHandle? pipeline = shadow_pipeline_for(
            renderer:     renderer,
            wireframe:    draw.wireframe,
            vertex:       vertex,
            material:     material,
            vertex_color: draw.masked && (geometry.layout.flags.has_colors || candidate.batch != null),
        );
        if (catch excuse = pipeline) {
            if (material.kind != MaterialKind.CUSTOM || !pipeline_rejected(renderer, material.custom.shader, excuse)) {
                return excuse~;
            }
            continue;
        }
        draw.material = material;
        draw.pipeline = pipeline;
        count++;
        if (!draw.masked || material.kind == MaterialKind.CUSTOM) continue;
        TextureSlot base_map;
        switch (material.kind) {
            case BASIC: base_map = material.basic.map;
            case STANDARD: base_map = material.standard.base_color_map;
            case PHYSICAL: base_map = material.physical.standard.base_color_map;
            case TOON: base_map = material.toon.map;
            case CUSTOM: unreachable();
        }
        TextureBinding binding = resolve_texture_slot(renderer, base_map)!;
        gpu::MappedGpuSpan alpha = slot.upload.take(&renderer.device, BasicMaterialGpu::size, STREAM_ALIGNMENT)!;
        write_shadow_material_block((BasicMaterialGpu*)alpha.bytes.ptr, material, binding);
        draw.alpha = alpha.address;
    }
    return draws[:count];
}

fn void? record_shadow_layer(
    Renderer* renderer,
    CameraMatrices* matrices,
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
        matrices: matrices,
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
    gpu::PipelineHandle first = draws.len
      ? draws[0].pipeline : shadow_pipeline_for(renderer, false, depth_only_vertex_variant({}))!;
    gpu::cmd_bind_pipeline(&renderer.commands, first)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_depth_draws(
        renderer:       renderer,
        draws:          draws,
        frame:          frame.address,
        view_reflected: matrices.view.determinant() < 0,
        state:          &state,
        first:          first,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.stats.shadow_layers++;
}

fn void? record_depth_draws(
    Renderer* renderer,
    ShadowDraw[] draws,
    gpu::GpuAddress frame,
    bool view_reflected,
    gpu::GraphicsState* state,
    gpu::PipelineHandle first,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    ShadowDrawState bound = { .pipeline = first };
    bool state_set;
    foreach (draw : draws) {
        ShadowDrawState wanted = {
            .pipeline = draw.pipeline,
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
            gpu::cmd_set_graphics_state(&renderer.commands, state)!;
            state_set = true;
        }
        bound = wanted;

        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, DrawRoot::size, STREAM_ALIGNMENT)!;
        if (draw.material.kind == MaterialKind.CUSTOM) {
            write_draw_root(
                root: (DrawRoot*)root.bytes.ptr,
                world: draw.candidate.node.world,
                prev_world: draw.candidate.node.world,
                frame: frame,
                geometry: draw.geometry.root,
                material: draw.alpha,
                object_id: draw.candidate.node.id.index,
                flags: draw.masked ? shader::DRAW_ALPHA_MASK : 0,
                skin: draw.skin,
                morph: draw.morph,
                instance_data: draw.instance_data,
            );
        } else {
            write_depth_draw_root(
                root: (DrawRoot*)root.bytes.ptr,
                world: draw.candidate.node.world,
                frame: frame,
                geometry: draw.geometry.root,
                material: draw.alpha,
                object_id: draw.candidate.node.id.index,
                flags: draw.masked ? shader::DRAW_ALPHA_MASK : 0,
                skin: draw.skin,
                morph: draw.morph,
                instance_data: draw.instance_data,
            );
        }
        record_geometry_draw(
            renderer:       renderer,
            root:           root.address,
            geometry:       draw.geometry,
            instance_count: draw.instance_count,
        )!;
    }
}

fn ShadowGpu[]? record_shadows(
    Renderer* renderer,
    Scene* scene,
    Camera* camera,
    CameraMatrices* matrices,
    LightExtraction* extraction,
) @private {
    renderer.shadow_frustum_count = 0;
    uint covered;
    foreach (request : extraction.shadows) {
        Light* light = scene.get(scene.node(request.light), Light);
        if (light.kind != LightKind.DIRECTIONAL || directional_cascade_splits(*camera, light.shadow).count) {
            extraction.shadows[covered++] = request;
        }
    }
    ShadowAllocation allocation = assign_shadow_layers(extraction.shadows[:covered], renderer.max_shadow_layers);
    renderer.stats.shadow_requests_dropped += allocation.dropped;
    if (!allocation.layer_count) return (ShadowGpu[]){};
    acquire_shadow_atlas(renderer)!;
    ExtractCounts counts;
    MeshCandidate[] candidates = extract_shadow_candidates(
        allocator: tmem,
        scene: scene,
        assets: renderer.assets,
        counts: &counts,
    );
    renderer.stats.dangling_refs += counts.dangling;
    CameraMatrices[] shadow_matrices = alloc::new_array(tmem, CameraMatrices, allocation.layer_count);
    bool[] participating = alloc::new_array(tmem, bool, candidates.len);
    ShadowGpu[] shadows = alloc::new_array(tmem, ShadowGpu, allocation.layer_count);
    foreach (request : allocation.requests) {
        Light* light = scene.get(scene.node(request.light), Light);
        LightGpu* packed = &extraction.lights[request.light_index];
        packed.shadow_first = request.first_layer;
        packed.shadow_count = request.layer_count;
        CascadeSplits splits;
        float shadow_range = 0;
        if (light.kind == LightKind.DIRECTIONAL) {
            splits = directional_cascade_splits(*camera, light.shadow);
        } else {
            shadow_range = light.range > 0 ? light.range : light.shadow.max_distance;
        }
        for (uint index = 0; index < request.layer_count; index++) {
            uint layer = request.first_layer + index;
            float split_depth;
            switch (light.kind) {
                case DIRECTIONAL:
                    ShadowCascade cascade = fit_directional_cascade(
                        view: matrices,
                        near_depth: index ? splits.far_depths[index - 1] : splits.near_depth,
                        far_depth: splits.far_depths[index],
                        light_direction: packed.direction_cos_outer.xyz,
                        casters: candidates,
                        resolution: renderer.shadow_resolution,
                        normal_bias: light.shadow.normal_bias,
                    );
                    shadow_matrices[layer] = cascade.camera;
                    split_depth = cascade.split_depth;
                case SPOT:
                    shadow_matrices[layer] = spot_shadow_camera(
                        position: packed.position_range.xyz,
                        direction: packed.direction_cos_outer.xyz,
                        outer_cone: light.outer_cone,
                        shadow_range: shadow_range,
                    );
                case POINT:
                    shadow_matrices[layer] = point_shadow_camera(packed.position_range.xyz, index, shadow_range);
            }
            foreach (candidate_index, candidate : candidates) {
                if (maths::frustum_intersects_aabb(&shadow_matrices[layer].frustum, candidate.world_bounds)) {
                    participating[candidate_index] = true;
                }
            }
            renderer.shadow_frusta[layer] = {
                .inv_view_proj = shadow_matrices[layer].inv_view_proj,
                .kind          = light.kind,
            };
            renderer.shadow_frustum_count = math::max(renderer.shadow_frustum_count, layer + 1);
            shadows[layer] = {
                .view_proj = bitcast(shadow_matrices[layer].view_proj, Mat4f),
                .texture_index = renderer.shadow_atlas.layers[layer].view.index,
                .sampler_index = renderer.shadow_atlas.sampler,
                .normal_bias = light.shadow.normal_bias,
                .split_depth = split_depth,
                .texel_size = 1.0f / (float)renderer.shadow_resolution,
                .max_distance = shadow_range,
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
    @profile_pass(renderer, Pass.SHADOW_ATLAS) {
        foreach (request : allocation.requests) {
            Light* light = scene.get(scene.node(request.light), Light);
            for (uint index = 0; index < request.layer_count; index++) {
                uint layer = request.first_layer + index;
                uint count;
                foreach (draw : draws) {
                    if (maths::frustum_intersects_aabb(&shadow_matrices[layer].frustum, draw.candidate.world_bounds)) {
                        layer_draws[count++] = draw;
                    }
                }
                ProfileScopeToken layer_scope = begin_profile_shadow(
                    renderer: renderer,
                    light: request.light,
                    kind: light.kind,
                    layer_index: index,
                )!;
                record_shadow_layer(
                    renderer: renderer,
                    matrices: &shadow_matrices[layer],
                    draws: layer_draws[:count],
                    layer: layer,
                    bias: light.shadow.bias,
                )!;
                end_profile_scope(renderer, layer_scope)!;
            }
        }
    }!;
    transition_shadow_atlas(
        atlas: &renderer.shadow_atlas,
        commands: &renderer.commands,
        next: gpu::sampled_at({ .fragment_shader }),
    )!;
    return shadows;
}
