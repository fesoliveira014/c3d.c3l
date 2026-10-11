module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

const gpu::TextureState TRANSPARENCY_COMPUTE_READ @private = {
    .layout = gpu::TextureLayout.SAMPLED,
    .stages = { .compute },
    .access = { .read },
};

const gpu::TextureState TRANSPARENCY_COMPUTE_STORAGE @private = {
    .layout = gpu::TextureLayout.STORAGE,
    .stages = { .compute },
    .access = { .read, .write },
};

fn PipelineKey transparency_resolve_key(gpu::Format color_format) @private {
    return {
        .vertex = { .shader = FULLSCREEN },
        .fragment = { .shader = TRANSPARENCY },
        .color_formats = { [0] = color_format, [1] = gpu::Format.R32_FLOAT },
        .color_count = 2,
        .samples = gpu::SampleCount.ONE,
        .polygon = gpu::PolygonMode.FILL,
    };
}

fn void? acquire_transparency_sampler(Renderer* renderer) @private {
    if ((uint)renderer.transparency_sampler) return;

    gpu::SamplerDesc desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .max_lod = material::TEXTURE_MIP_CAPACITY - 1,
        .debug_name = "transparency_filter",
    };
    renderer.transparency_sampler = gpu::intern_sampler(&renderer.device, &desc)!;
}

fn void? prepare_transparency_view_pipelines(Renderer* renderer) @private {
    acquire_transparency_sampler(renderer)!;

    renderer.pipelines.get(&renderer.device, composite_pipeline_key(HDR_FORMAT))!;
    renderer.pipelines.get(&renderer.device, composite_pipeline_key(gpu::Format.R32_FLOAT))!;
    renderer.pipelines.get(&renderer.device, transparency_resolve_key(HDR_FORMAT))!;
    renderer.pipelines.get(&renderer.device, transparency_resolve_key(TRANSPARENCY_COMPOSITION_FORMAT))!;
    renderer.pipelines.get(&renderer.device, composite_pipeline_key(TRANSPARENCY_COMPOSITION_FORMAT))!;
    acquire_compute_pipeline(
        renderer: renderer,
        pipeline: &renderer.transparency_order_pipeline,
        shader: TRANSPARENCY_ORDER,
        debug_name: "transparency_order",
    )!;
    acquire_compute_pipeline(
        renderer: renderer,
        pipeline: &renderer.transparency_mip_pipeline,
        shader: TRANSPARENCY_MIP,
        debug_name: "transparency_mip",
    )!;
    acquire_compute_pipeline(
        renderer: renderer,
        pipeline: &renderer.transparency_overflow_pipeline,
        shader: TRANSPARENCY_OVERFLOW,
        debug_name: "transparency_overflow",
    )!;
}

fn gpu::GpuAddress? upload_transparency_frame(
    Renderer* renderer,
    FrameRoot frame,
    TransparencyGpu transparency,
    gpu::TextureIndex source,
) @private {
    frame.scene_color = source;
    frame.scene_sampler = transparency.mip_count > 1 ? renderer.transparency_sampler : renderer.linear_clamp_sampler;
    frame.transparency = upload_bytes(renderer, &transparency, TransparencyGpu::size)!;
    return upload_bytes(renderer, &frame, FrameRoot::size);
}

fn void? record_transparency_resolve(
    Renderer* renderer,
    ViewRecord* record,
    FrameRoot frame,
    TransparencyGpu transparency,
    Target* source,
    Target* color,
    Target* anchor,
) @private {
    source.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    anchor.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

    gpu::GpuAddress root = upload_transparency_frame(
        renderer: renderer,
        frame: frame,
        transparency: transparency,
        source: source.view.index,
    )!;
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, transparency_resolve_key(color.format))!;
    gpu::ColorTargetDesc[2] colors = {
        { .view = color.attachment, .load_op = gpu::LoadOp.DONT_CARE, .store_op = gpu::StoreOp.STORE },
        { .view = anchor.attachment, .load_op = gpu::LoadOp.DONT_CARE, .store_op = gpu::StoreOp.STORE },
    };
    gpu::RenderPassDesc pass = { .colors = colors[..], .width = color.width, .height = color.height };
    gpu::ColorTargetState[2] outputs = { gpu::color_blend_disabled(), gpu::color_blend_disabled() };
    gpu::GraphicsState state = fullscreen_state(
        width: color.width,
        height: color.height,
        rect: {},
        color_targets: outputs[..],
    )!;

    @profile_pass(renderer, Pass.TRANSPARENCY_RESOLVE) {
        gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
        gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
        gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
        gpu::cmd_draw(
            commands: &renderer.commands,
            vertex_root: (gpu::GpuAddress)0,
            fragment_root: root,
            vertex_count: FULLSCREEN_VERTEX_COUNT,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&renderer.commands)!;
    }!;
    count_transparency_work(renderer, &record.stats.transparency, TransparencyWork.RESOLVE);
}

fn void? copy_transparency_color(Renderer* renderer, Target* source, Target* target) @private {
    source.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    target.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;

    CompositeRoot data = { .source_texture = source.view.index, .source_sampler = renderer.linear_clamp_sampler };
    gpu::GpuAddress root = upload_bytes(renderer, &data, CompositeRoot::size)!;
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, composite_pipeline_key(target.format))!;

    record_fullscreen_pass(
        renderer: renderer,
        target: target,
        pipeline: pipeline,
        fragment_root: root,
        rect: {},
        load: gpu::LoadOp.DONT_CARE,
    )!;
}

fn void? record_transparency_pyramid(
    Renderer* renderer,
    Target* source,
    TransparencyPyramid* pyramid,
) @private {
    acquire_compute_pipeline(
        renderer: renderer,
        pipeline: &renderer.transparency_mip_pipeline,
        shader: TRANSPARENCY_MIP,
        debug_name: "transparency_mip",
    )!;

    @profile_pass(renderer, Pass.TRANSPARENCY_FILTER) {
        source.transition(&renderer.commands, TRANSPARENCY_COMPUTE_READ)!;
        pyramid.image.transition(&renderer.commands, TRANSPARENCY_COMPUTE_STORAGE)!;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.transparency_mip_pipeline)!;

        for (uint mip = 0; mip < pyramid.mip_count; mip++) {
            uint width = material::texture_mip_extent(pyramid.image.width, mip);
            uint height = material::texture_mip_extent(pyramid.image.height, mip);
            TransparencyMipRoot data = {
                .source = mip == 0 ? source.view.index : pyramid.levels[mip - 1].index,
                .destination = pyramid.levels[mip].index,
                .width = width,
                .height = height,
                .source_width = mip == 0 ? width : material::texture_mip_extent(pyramid.image.width, mip - 1),
                .source_height = mip == 0 ? height : material::texture_mip_extent(pyramid.image.height, mip - 1),
                .source_storage = mip > 0 ? 1 : 0,
            };
            gpu::GpuAddress root = upload_bytes(renderer, &data, TransparencyMipRoot::size)!;
            uint dispatch_width = (width + shader::TRANSPARENCY_MIP_GROUP_SIZE - 1)
              / shader::TRANSPARENCY_MIP_GROUP_SIZE;
            uint dispatch_height = (height + shader::TRANSPARENCY_MIP_GROUP_SIZE - 1)
              / shader::TRANSPARENCY_MIP_GROUP_SIZE;
            gpu::cmd_dispatch(&renderer.commands, root, { dispatch_width, dispatch_height, 1 })!;

            gpu::Barrier next = { .before = { .compute }, .after = { .compute } };
            gpu::cmd_barrier(&renderer.commands, &next)!;
        }

        pyramid.image.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    }!;
}

fn void? record_transparency_order(Renderer* renderer, TransparencyOrderRoot[] roots) @private {
    if (!roots.len) return;

    acquire_compute_pipeline(
        renderer: renderer,
        pipeline: &renderer.transparency_order_pipeline,
        shader: TRANSPARENCY_ORDER,
        debug_name: "transparency_order",
    )!;

    gpu::Barrier sources = { .before = { .host, .compute }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &sources)!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.transparency_order_pipeline)!;

    foreach (&data : roots) {
        gpu::GpuAddress root = upload_bytes(renderer, data, TransparencyOrderRoot::size)!;
        uint groups = (data.count + shader::TRANSPARENCY_ORDER_GROUP_SIZE - 1) / shader::TRANSPARENCY_ORDER_GROUP_SIZE;
        gpu::cmd_dispatch(&renderer.commands, root, { groups, 1, 1 })!;
    }

    gpu::Barrier ordered = { .before = { .compute }, .after = { .indirect, .vertex_shader } };
    gpu::cmd_barrier(&renderer.commands, &ordered)!;
}

fn void? record_transparency_own_depth(Renderer* renderer, ViewRecord* record, DrawItem[] items) @private {
    DrawItem[] depth_items = alloc::new_array(tmem, DrawItem, (sz)items.len);
    usz count;
    foreach (item : items) {
        Material* material = material_data(renderer, item.material);
        if (!writes_own_depth(material)) continue;

        ShaderVariant vertex = item.vertex;
        if (vertex.shader == MESH) vertex.flags |= shader::SHADER_FLAG_DEPTH_ONLY;
        item.pipeline = shadow_pipeline_for(
            renderer: renderer,
            wireframe: material.common.wireframe && renderer.caps.line_polygon_mode,
            vertex: vertex,
            material: material,
            vertex_color: material.common.alpha_mode == AlphaMode.MASK
              && (item.geometry.layout.flags.has_colors || candidate_instanced(item.candidate)),
        )!;
        depth_items[count++] = item;
    }
    if (!count) return;

    record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    gpu::DepthTargetDesc depth = {
        .view = record.depth.attachment,
        .load_op = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = { .depth = &depth, .width = record.depth.width, .height = record.depth.height };
    gpu::GraphicsState state = gpu::render_geometry_state(record.depth.width, record.depth.height)!;
    state.viewport = flipped_viewport(record.depth.width, record.depth.height);
    state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };

    gpu::cmd_bind_pipeline(&renderer.commands, depth_items[0].pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;

    foreach (&item : depth_items[:count]) {
        MaterialCommon* common = &material_data(renderer, item.material).common;
        gpu::cmd_bind_pipeline(&renderer.commands, item.pipeline)!;
        state.raster.cull_mode = common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK;
        state.raster.front_face = item.front_face;
        state.raster.topology = primitive_topology(item.geometry.topology);
        gpu::cmd_set_graphics_state(&renderer.commands, &state)!;

        if (candidate_instanced(item.candidate)) {
            record_batch_draw(
                renderer: renderer,
                root: item.root,
                geometry: item.geometry,
                range: item.range,
            )!;
        } else {
            record_geometry_draw(renderer, item.root, item.geometry)!;
        }
    }

    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? record_transparency_fallback(
    Renderer* renderer,
    ViewRecord* record,
    FrameRoot frame,
    DrawItem[] scene_read,
    DrawItem[] transparent,
) @private {
    uint fallback_count = (uint)(scene_read.len + transparent.len);
    count_transparency_fallback(renderer, &record.stats.transparency, fallback_count);

    if (scene_read.len) {
        if (frame.sky_fog != (gpu::GpuAddress)0) {
            TransparencyGpu data = {
                .phase = shader::TRANSPARENCY_UNFOG,
                .opaque_depth = record.scene_depth.view.index,
            };
            record_transparency_resolve(
                renderer: renderer,
                record: record,
                frame: frame,
                transparency: data,
                source: &record.hdr_color,
                color: &record.transparency.local_color[0],
                anchor: &record.transparency.continuation_depth[0],
            )!;
            copy_transparency_color(renderer, &record.transparency.local_color[0], &record.hdr_color)!;
        }

        record_loaded_pass(renderer, record, scene_read)!;
        if (frame.sky_fog != (gpu::GpuAddress)0) {
            gpu::GpuAddress root = upload_bytes(renderer, &frame, FrameRoot::size)!;
            record_fog_pass(renderer, record, root)!;
        }
    }

    if (transparent.len) record_loaded_pass(renderer, record, transparent)!;
}

fn void? record_layered_transparency(
    Renderer* renderer,
    ViewRecord* record,
    FrameRoot frame,
    DrawItem[] scene_read,
    DrawItem[] transparent,
) @private {
    DrawItem[] admitted = alloc::new_array(tmem, DrawItem, (sz)(scene_read.len + transparent.len));
    DrawItem[] fallback_scene_read = alloc::new_array(tmem, DrawItem, (sz)scene_read.len);
    DrawItem[] fallback_transparent = alloc::new_array(tmem, DrawItem, (sz)transparent.len);
    usz admitted_count;
    uint[2] fallback_counts;
    DrawItem[][2] groups = { scene_read, transparent };
    DrawItem[][2] fallbacks = { fallback_scene_read, fallback_transparent };
    foreach (group_index, group : groups) foreach (item : group) {
        if (item.layered) {
            admitted[admitted_count++] = item;
        } else {
            fallbacks[group_index][fallback_counts[group_index]++] = item;
        }
    }
    admitted = admitted[:admitted_count];
    fallback_scene_read = fallback_scene_read[:fallback_counts[0]];
    fallback_transparent = fallback_transparent[:fallback_counts[1]];

    if (!admitted.len) {
        if (frame.sky_fog != (gpu::GpuAddress)0) {
            gpu::GpuAddress root = upload_bytes(renderer, &frame, FrameRoot::size)!;
            record_fog_pass(renderer, record, root)!;
        }

        return record_transparency_fallback(
            renderer: renderer,
            record: record,
            frame: frame,
            scene_read: fallback_scene_read,
            transparent: fallback_transparent,
        );
    }

    TransparencyState* state = &record.transparency;
    acquire_transparency_sampler(renderer)!;
    TransparencyOrderPlan ordered = prepare_transparency_order(renderer, admitted)!;
    record_transparency_order(renderer, ordered.roots)!;

    TransparencyGpu data = {
        .opaque_depth = record.scene_depth.view.index,
        .opaque_color = record.scene_color.view.index,
        .continuation_depth = record.scene_depth.view.index,
        .mip_count = state.raw_pyramid[0].mip_count,
        .phase = shader::TRANSPARENCY_CAPTURE,
    };
    for (uint group = 0; group <= state.layer_capacity; group++) {
        data.previous_depth = group == 0 ? (gpu::TextureIndex)0 : state.depths[group - 1].view.index;
        record_transparency_geometry(
            renderer: renderer,
            record: record,
            frame: frame,
            transparency: data,
            items: admitted,
            color: &state.continuation_depth[0],
            anchor: &state.continuation_depth[1],
            depth: &state.depths[group],
            capture: true,
            clear_depth: true,
        )!;
        state.depths[group].transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    }

    record_transparency_overflow(
        renderer: renderer,
        readbacks: &record.transparency_readbacks,
        stats: &record.stats.transparency,
        depth: &state.depths[state.layer_capacity],
    )!;
    account_transparency_payload(
        renderer: renderer,
        stats: &record.stats.transparency,
        readbacks: &record.transparency_readbacks,
        image_bytes: state.texel_bytes + record.scene_pyramid.texel_bytes,
    );

    data.phase = shader::TRANSPARENCY_INITIAL;
    record_transparency_resolve(
        renderer: renderer,
        record: record,
        frame: frame,
        transparency: data,
        source: &record.scene_color,
        color: &record.hdr_color,
        anchor: &state.continuation_depth[0],
    )!;

    data.phase = shader::TRANSPARENCY_TAIL;
    data.selected_depth = state.depths[state.layer_capacity - 1].view.index;
    record_transparency_geometry(
        renderer: renderer,
        record: record,
        frame: frame,
        transparency: data,
        items: admitted,
        color: &record.hdr_color,
        anchor: &state.continuation_depth[1],
        depth: &record.depth,
        capture: false,
        clear_depth: false,
    )!;

    data.phase = shader::TRANSPARENCY_SEED;
    data.selected_depth = state.depths[state.layer_capacity].view.index;
    record_transparency_resolve(
        renderer: renderer,
        record: record,
        frame: frame,
        transparency: data,
        source: &record.hdr_color,
        color: &state.raw_color[0],
        anchor: &state.continuation_depth[0],
    )!;

    uint behind;
    for (uint group = state.layer_capacity; group > 0; group--) {
        uint front = behind ^ 1;
        state.continuation_depth[behind].transition(&renderer.commands, FRAGMENT_READ_STATE)!;
        record_transparency_pyramid(renderer, &state.raw_color[behind], &state.raw_pyramid[behind])!;
        count_transparency_filter(renderer, &record.stats.transparency, state.raw_pyramid[behind].mip_count);
        data.phase = shader::TRANSPARENCY_CONNECT;
        data.selected_depth = state.depths[group - 1].view.index;
        data.continuation_depth = state.continuation_depth[behind].view.index;
        record_transparency_resolve(
            renderer: renderer,
            record: record,
            frame: frame,
            transparency: data,
            source: &state.raw_color[behind],
            color: &state.local_color[front],
            anchor: &state.continuation_depth[front],
        )!;

        data.phase = shader::TRANSPARENCY_RETAINED;
        FrameRoot shaded = frame;
        shaded.scene_color = state.raw_pyramid[behind].image.view.index;
        record_transparency_geometry(
            renderer: renderer,
            record: record,
            frame: shaded,
            transparency: data,
            items: ordered.items,
            color: &state.local_color[front],
            anchor: &state.continuation_depth[front],
            depth: &record.depth,
            capture: false,
            clear_depth: false,
        )!;
        copy_transparency_color(renderer, &state.local_color[front], &state.raw_color[front])!;
        behind = front;
    }

    state.continuation_depth[behind].transition(&renderer.commands, FRAGMENT_READ_STATE)!;
    data.phase = shader::TRANSPARENCY_COMPOSITE;
    data.continuation_depth = state.continuation_depth[behind].view.index;
    record_transparency_resolve(
        renderer: renderer,
        record: record,
        frame: frame,
        transparency: data,
        source: &state.raw_color[behind],
        color: &record.hdr_color,
        anchor: &state.continuation_depth[behind ^ 1],
    )!;

    record_transparency_fallback(
        renderer: renderer,
        record: record,
        frame: frame,
        scene_read: fallback_scene_read,
        transparent: fallback_transparent,
    )!;
    record_transparency_own_depth(renderer, record, admitted)!;
}
