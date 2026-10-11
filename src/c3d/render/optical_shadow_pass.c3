module c3d::render;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;

fn bool shadow_caster_material(Material* material, bool optical) @private {
    return material.common.alpha_mode != AlphaMode.BLEND
      || (optical && material.kind == MaterialKind.PHYSICAL && material.physical.transmission > 0);
}

fn PipelineKey optical_shadow_pipeline_key(ShaderVariant vertex, gpu::PolygonMode polygon, bool product) @private {
    vertex.flags |= shader::SHADER_FLAG_LAYERED | shader::SHADER_FLAG_OPTICAL_SHADOW;
    return {
        .vertex = vertex,
        .fragment = { .shader = OPTICAL_SHADOW },
        .color_formats = { [0] = gpu::Format.RGBA32_FLOAT },
        .color_count = 1,
        .depth_format = product ? gpu::Format.UNDEFINED : DEPTH_FORMAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = polygon,
    };
}

fn PipelineKey optical_store_pipeline_key() @private {
    return {
        .vertex = { .shader = FULLSCREEN },
        .fragment = { .shader = OPTICAL_STORE },
        .color_formats = { [0] = gpu::Format.RGBA16_FLOAT },
        .color_count = 1,
        .samples = gpu::SampleCount.ONE,
        .polygon = gpu::PolygonMode.FILL,
    };
}

fn DrawItem[]? prepare_optical_shadow_draws(
    Renderer* renderer,
    MeshCandidate[] candidates,
    InstanceEffectsView* effects_view,
) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    DrawItem[] items = alloc::new_array(tmem, DrawItem, candidates.len);
    uint count;
    foreach (&candidate : candidates) {
        Material* material = candidate_material(renderer, candidate);
        if (candidate.impostor || material.kind != MaterialKind.PHYSICAL) continue;

        GpuGeometry* geometry = resolve_geometry(renderer, candidate.geometry)!;
        MaterialRes* published = resolve_material(renderer, candidate.material)!;
        ShaderVariant vertex = candidate_vertex_variant(
            flags: geometry.layout.flags,
            candidate: candidate,
            base_flags: shader::SHADER_FLAG_LAYERED | shader::SHADER_FLAG_OPTICAL_SHADOW,
        );
        DrawItem* item = &items[count++];
        *item = {
            .candidate = candidate,
            .geometry = geometry,
            .material = published,
            .vertex = vertex,
            .skin = resolve_candidate_skin(renderer, candidate)!,
            .morph = resolve_candidate_morph(renderer, candidate, vertex)!,
            .instance_data = candidate_instanced(candidate) ? resolve_instances(renderer, candidate)! : (gpu::GpuAddress)0,
            .range = { .count = candidate.instance_count, .first = candidate.instance_first },
        };
        item.effects = resolve_instance_effects(
            renderer: renderer,
            effects_view: effects_view,
            candidate: candidate,
            geometry: geometry,
        )!;
        gpu::MappedGpuSpan root = frame.upload.take(&renderer.device, DrawRoot::size, STREAM_ALIGNMENT)!;
        item.root = root.address;
        item.draw = (DrawRoot*)root.bytes.ptr;
        write_draw_root(
            root: item.draw,
            world: maths::rebase(candidate.node.world, renderer.frame_origin),
            prev_world: maths::rebase(candidate.node.world, renderer.frame_origin),
            frame: (gpu::GpuAddress)0,
            geometry: geometry.root,
            material: published.address,
            object_id: candidate.node.id.index,
            layers: candidate.node.layers,
            flags: batch_effect_flags(candidate),
            skin: item.skin,
            morph: item.morph,
            instance_data: item.instance_data,
            skin_stride: candidate_skin_stride(candidate),
            instance_effects: item.effects,
        );
        item.draw.lod_part = resolve_lod_part(renderer, candidate)!;
    }

    return prepare_transparency_order(renderer, items[:count])!.items;
}

fn gpu::GpuAddress? upload_optical_shadow_frame(
    Renderer* renderer,
    CameraMatrices* matrices,
    LightGpu light,
    OpticalShadowPassGpu phase,
) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    phase.light_position_kind = light.position_range;
    phase.light_position_kind.w = (float)light.kind;
    phase.light_direction = light.direction_cos_outer;
    gpu::MappedGpuSpan pass = frame.upload.take(&renderer.device, OpticalShadowPassGpu::size, STREAM_ALIGNMENT)!;
    *(OpticalShadowPassGpu*)pass.bytes.ptr = phase;
    gpu::MappedGpuSpan optical = frame.upload.take(&renderer.device, OpticalShadowsGpu::size, STREAM_ALIGNMENT)!;
    *(OpticalShadowsGpu*)optical.bytes.ptr = { .pass = pass.address };
    gpu::MappedGpuSpan root = frame.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
    Camera camera;
    camera.projection = matrices.proj.m33 == 1 ? Projection.ORTHOGRAPHIC : Projection.PERSPECTIVE;
    uint resolution = renderer.shadow_resolution;
    write_frame_root(
        root: (FrameRoot*)root.bytes.ptr,
        matrices: matrices,
        camera: &camera,
        viewport: { (float)resolution, (float)resolution },
        info: renderer.info,
        frame_index: renderer.frame_index,
        sky_fog: (gpu::GpuAddress)0,
        origin: renderer.frame_origin,
    );
    ((FrameRoot*)root.bytes.ptr).optical_shadows = optical.address;
    return root.address;
}

fn void? record_optical_shadow_geometry(
    Renderer* renderer,
    CameraMatrices* matrices,
    DrawItem[] items,
    LightGpu light,
    uint layer,
    ShadowAtlas* depth,
    OpticalShadowPassGpu phase,
    bool clear_depth,
) @private {
    OpticalShadowAtlas* atlas = &renderer.optical_shadow_atlas;
    Target* accumulation = &atlas.accumulation;
    bool product = phase.phase == shader::OPTICAL_SHADOW_PRODUCT;
    accumulation.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    if (depth) transition_shadow_atlas(depth, &renderer.commands, DEPTH_ATTACHMENT_STATE)!;

    gpu::ColorTargetDesc[1] colors = {{
        .view = accumulation.attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 1, 1, 1, 1 } },
    }};
    gpu::DepthTargetDesc depth_target;
    if (depth) {
        depth_target = {
            .view = depth.layers[layer].attachment,
            .load_op = clear_depth ? gpu::LoadOp.CLEAR : gpu::LoadOp.LOAD,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .depth = 0 },
        };
    }
    uint resolution = renderer.shadow_resolution;
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth = depth ? &depth_target : null,
        .width = resolution,
        .height = resolution,
    };
    gpu::ColorTargetState[1] outputs = { gpu::color_blend_disabled() };
    if (product) {
        outputs[0].blend = {
            .enable = true,
            .src_color = gpu::BlendFactor.ZERO,
            .dst_color = gpu::BlendFactor.SRC_COLOR,
            .color_op = gpu::BlendOp.ADD,
            .src_alpha = gpu::BlendFactor.ZERO,
            .dst_alpha = gpu::BlendFactor.ONE,
            .alpha_op = gpu::BlendOp.ADD,
        };
    }
    gpu::GraphicsState state = gpu::render_geometry_state(resolution, resolution)!;
    state.viewport = flipped_viewport(resolution, resolution);
    state.color.targets = outputs[..];
    state.depth = { .test_enable = !product, .write_enable = !product, .compare = gpu::CompareOp.GREATER };
    gpu::GpuAddress frame_address = upload_optical_shadow_frame(
        renderer: renderer,
        matrices: matrices,
        light: light,
        phase: phase,
    )!;
    if (items.len) {
        Material* material = candidate_material(renderer, items[0].candidate);
        gpu::PolygonMode polygon = material.common.wireframe && renderer.caps.line_polygon_mode
          ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
        gpu::PipelineHandle first = renderer.pipelines.get(
            &renderer.device,
            optical_shadow_pipeline_key(items[0].vertex, polygon, product),
        )!;
        gpu::cmd_bind_pipeline(&renderer.commands, first)!;
    }

    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    foreach (&item : items) {
        MeshCandidate* candidate = item.candidate;
        if ((candidate.node.layers & light.layers) == 0
          || !maths::frustum_intersects_aabb(&matrices.frustum, candidate.world_bounds)) continue;

        Material* material = candidate_material(renderer, candidate);
        gpu::PolygonMode polygon = material.common.wireframe && renderer.caps.line_polygon_mode
          ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
        gpu::PipelineHandle pipeline = renderer.pipelines.get(
            &renderer.device,
            optical_shadow_pipeline_key(item.vertex, polygon, product),
        )!;
        gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
        state.raster.cull_mode = material.common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK;
        bool reflected = (candidate_world(candidate).determinant() < 0) != candidate.mirrored;
        state.raster.front_face = reflected != (matrices.view.determinant() < 0)
          ? gpu::FrontFace.CLOCKWISE : gpu::FrontFace.COUNTER_CLOCKWISE;
        state.raster.topology = primitive_topology(item.geometry.topology);
        gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
        gpu::MappedGpuSpan draw = frame.upload.take(&renderer.device, DrawRoot::size, STREAM_ALIGNMENT)!;
        *(DrawRoot*)draw.bytes.ptr = *item.draw;
        ((DrawRoot*)draw.bytes.ptr).frame = frame_address;
        if (candidate_instanced(candidate)) {
            record_batch_draw(
                renderer: renderer,
                root: draw.address,
                geometry: item.geometry,
                range: item.range,
            )!;
        } else {
            record_geometry_draw(renderer, draw.address, item.geometry)!;
        }
    }

    gpu::cmd_end_render_pass(&renderer.commands)!;
    if (depth) transition_shadow_atlas(depth, &renderer.commands, FRAGMENT_READ_STATE)!;
    renderer.work_recorded = true;
}

fn void? record_optical_shadow_product(
    Renderer* renderer,
    CameraMatrices* matrices,
    LightGpu light,
    uint layer,
    uint group,
) @private {
    OpticalShadowAtlas* atlas = &renderer.optical_shadow_atlas;
    atlas.accumulation.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    ShadowAtlas* product = &atlas.products[group];
    transition_shadow_atlas(product, &renderer.commands, COLOR_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[1] colors = {{
        .view = product.layers[layer].attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 1, 1, 1, 1 } },
    }};
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width = renderer.shadow_resolution,
        .height = renderer.shadow_resolution,
    };
    gpu::GpuAddress frame = upload_optical_shadow_frame(
        renderer: renderer,
        matrices: matrices,
        light: light,
        phase: { .source_product = atlas.accumulation.view.index, .phase = shader::OPTICAL_SHADOW_STORE },
    )!;
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, optical_store_pipeline_key())!;
    gpu::ColorTargetState[1] outputs = { gpu::color_blend_disabled() };
    gpu::GraphicsState state = fullscreen_state(
        width: renderer.shadow_resolution,
        height: renderer.shadow_resolution,
        rect: {},
        color_targets: outputs[..],
    )!;
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    gpu::cmd_draw(
        commands: &renderer.commands,
        vertex_root: (gpu::GpuAddress)0,
        fragment_root: frame,
        vertex_count: FULLSCREEN_VERTEX_COUNT,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    transition_shadow_atlas(product, &renderer.commands, FRAGMENT_READ_STATE)!;
}

fn void? record_optical_shadow_blockers(
    Renderer* renderer,
    CameraMatrices* matrices,
    ShadowDraw[] draws,
    uint layer,
    uint layers,
) @private {
    ShadowAtlas* opaque = &renderer.optical_shadow_atlas.opaque;
    transition_shadow_atlas(opaque, &renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    ShadowDraw[] visible = alloc::new_array(tmem, ShadowDraw, draws.len);
    uint count;
    foreach (draw : draws) {
        if ((draw.candidate.node.layers & layers) == 0
          || !maths::frustum_intersects_aabb(&matrices.frustum, draw.candidate.world_bounds)) continue;

        visible[count++] = draw;
    }
    CullRange[] ranges = alloc::new_array(tmem, CullRange, count);
    foreach (index, draw : visible[:count]) {
        ranges[index] = { .count = draw.candidate.instance_count, .first = draw.candidate.instance_first };
    }
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan frame = slot.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
    Camera camera;
    camera.projection = matrices.proj.m33 == 1 ? Projection.ORTHOGRAPHIC : Projection.PERSPECTIVE;
    uint resolution = renderer.shadow_resolution;
    write_frame_root(
        root: (FrameRoot*)frame.bytes.ptr,
        matrices: matrices,
        camera: &camera,
        viewport: { (float)resolution, (float)resolution },
        info: renderer.info,
        frame_index: renderer.frame_index,
        sky_fog: (gpu::GpuAddress)0,
        origin: renderer.frame_origin,
    );
    gpu::DepthTargetDesc depth = {
        .view = opaque.layers[layer].attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = 0 },
    };
    gpu::RenderPassDesc pass = { .depth = &depth, .width = resolution, .height = resolution };
    gpu::GraphicsState state = gpu::render_geometry_state(resolution, resolution)!;
    state.viewport = flipped_viewport(resolution, resolution);
    state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };
    gpu::PipelineHandle first = count ? visible[0].pipeline
      : shadow_pipeline_for(renderer, false, depth_only_vertex_variant({}))!;
    gpu::cmd_bind_pipeline(&renderer.commands, first)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    record_depth_draws(
        renderer: renderer,
        draws: visible[:count],
        ranges: ranges,
        frame: frame.address,
        view_reflected: matrices.view.determinant() < 0,
        state: &state,
        first: first,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
    transition_shadow_atlas(opaque, &renderer.commands, FRAGMENT_READ_STATE)!;
}

fn gpu::GpuAddress? record_optical_shadow_atlas(
    Renderer* renderer,
    Scene* scene,
    ShadowCamera* shadow_view,
    LightExtraction* extraction,
    InstanceEffectsView* effects_view,
    ShadowAllocation allocation,
    CameraMatrices[] legacy_matrices,
    ShadowGpu[] shadows,
) @private {
    bool demanded;
    foreach (request : allocation.requests) {
        demanded |= (extraction.lights[request.light_index].flags & shader::LIGHT_COLORED_TRANSMISSION) != 0;
    }
    if (!demanded) return (gpu::GpuAddress)0;

    acquire_optical_shadow_atlas(renderer)!;
    ExtractCounts counts;
    MeshCandidate[] candidates = extract_shadow_candidates(
        allocator: tmem,
        scene: scene,
        assets: renderer.assets,
        fade_origin: effects_view.fade_origin,
        counts: &counts,
        lod: effects_view.lod,
        origin: renderer.frame_origin,
        optical: true,
    );
    MeshCandidate[] blockers = alloc::new_array(tmem, MeshCandidate, candidates.len);
    uint blocker_count;
    foreach (candidate : candidates) {
        if (candidate_material(renderer, &candidate).kind != MaterialKind.PHYSICAL) blockers[blocker_count++] = candidate;
    }
    ShadowDraw[] blocker_draws = prepare_shadow_draws(renderer, blockers[:blocker_count], effects_view)!;
    DrawItem[] optical_draws = prepare_optical_shadow_draws(renderer, candidates, effects_view)!;
    record_pending_copies(renderer, &renderer.commands)!;
    OpticalShadowAtlas* atlas = &renderer.optical_shadow_atlas;
    OpticalShadowLayerGpu[] layers = alloc::new_array(tmem, OpticalShadowLayerGpu, allocation.layer_count);
    foreach (request : allocation.requests) {
        LightGpu light = extraction.lights[request.light_index];
        if ((light.flags & shader::LIGHT_COLORED_TRANSMISSION) == 0) continue;

        Light* source = scene.get(scene.node(request.light), Light);
        CascadeSplits splits;
        if (source.kind == LightKind.DIRECTIONAL) splits = directional_cascade_splits(shadow_view.lens, source.shadow);
        for (uint index = 0; index < request.layer_count; index++) {
            uint layer = request.first_layer + index;
            CameraMatrices matrices = legacy_matrices[layer];
            if (source.kind == LightKind.DIRECTIONAL) {
                matrices = fit_directional_cascade(
                    view: &shadow_view.matrices,
                    near_depth: index ? cascade_blend_depth(splits, index - 1, source.shadow.cascade_blend) : splits.near_depth,
                    far_depth: splits.far_depths[index],
                    light_direction: light.direction_cos_outer.xyz,
                    casters: candidates,
                    resolution: renderer.shadow_resolution,
                    normal_bias_texels: source.shadow.directional_normal_bias_texels,
                    origin: renderer.frame_origin,
                ).camera;
            }
            layers[layer] = {
                .opaque_depth = atlas.opaque.layers[layer].view.index,
                .overflow_depth = atlas.overflow.layers[layer].view.index,
                .view_proj = bitcast(matrices.view_proj, Mat4f),
            };
            shadows[layer].optical_index = layer + 1;
            record_optical_shadow_blockers(
                renderer: renderer,
                matrices: &matrices,
                draws: blocker_draws,
                layer: layer,
                layers: light.layers,
            )!;
            record_optical_shadow_geometry(
                renderer: renderer,
                matrices: &matrices,
                items: optical_draws,
                light: light,
                layer: layer,
                depth: &atlas.opaque,
                phase: { .phase = shader::OPTICAL_SHADOW_OPAQUE },
                clear_depth: false,
            )!;
            gpu::TextureIndex previous;
            for (uint group = 0; group < atlas.capacity; group++) {
                record_optical_shadow_geometry(
                    renderer: renderer,
                    matrices: &matrices,
                    items: optical_draws,
                    light: light,
                    layer: layer,
                    depth: &atlas.depths[group],
                    phase: { .previous_depth = previous, .phase = shader::OPTICAL_SHADOW_CAPTURE },
                    clear_depth: true,
                )!;
                layers[layer].depths[group] = atlas.depths[group].layers[layer].view.index;
                layers[layer].products[group] = atlas.products[group].layers[layer].view.index;
                previous = layers[layer].depths[group];
                record_optical_shadow_geometry(
                    renderer: renderer,
                    matrices: &matrices,
                    items: optical_draws,
                    light: light,
                    layer: layer,
                    depth: null,
                    phase: { .selected_depth = previous, .phase = shader::OPTICAL_SHADOW_PRODUCT },
                    clear_depth: false,
                )!;
                record_optical_shadow_product(
                    renderer: renderer,
                    matrices: &matrices,
                    light: light,
                    layer: layer,
                    group: group,
                )!;
            }
            record_optical_shadow_geometry(
                renderer: renderer,
                matrices: &matrices,
                items: optical_draws,
                light: light,
                layer: layer,
                depth: &atlas.overflow,
                phase: { .previous_depth = previous, .phase = shader::OPTICAL_SHADOW_CAPTURE },
                clear_depth: true,
            )!;
        }
    }

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan layer_array = frame.upload.take(
        &renderer.device,
        layers.len * OpticalShadowLayerGpu::size,
        STREAM_ALIGNMENT,
    )!;
    mem::copy(layer_array.bytes.ptr, layers.ptr, layers.len * OpticalShadowLayerGpu::size);
    return layer_array.address;
}
