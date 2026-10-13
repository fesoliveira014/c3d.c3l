module c3d::render::post;

import c3d;
import c3d::camera;
import c3d::material;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

struct VelocityTargets @private {
    Target*           color;
    Target*           depth;
    gpu::TextureState depth_state;
    gpu::SampleCount  samples;
}

<*
 Record camera and geometry velocity of the view into its velocity image.
 A multisample view draws opaque motion at its sample count and keeps sample 0.
 @param [&inout] renderer : "Open frame with the view's scene passes recorded."
 @param [&inout] record : "Its velocity and depth change state."
 @param items : "Opaque draw items with their roots written; moved ones are redrawn."
 @param [&in] raster : "Rendered matrices, jittered on a TAA view."
 @param view_proj : "Unjittered current view-projection; the previous one without history."
 @param jitter : "NDC offset of the rendered matrices."
 @param after_opaque : "Scene-read items already drawn; moved depth writers are redrawn."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require record.velocity.texture.is_valid()
*>
fn void? record_velocity(
    Renderer* renderer,
    ViewRecord* record,
    DrawItem[] items,
    CameraMatrices* raster,
    Mat4 view_proj,
    Vec2 jitter,
    DrawItem[] after_opaque = {},
) {
    VelocityTargets opaque = opaque_velocity_targets(record);
    acquire_velocity_pipelines(renderer, record.velocity.format, opaque.samples)!;
    render::@profile_pass(renderer, Pass.VELOCITY) {
        record_camera_velocity(
            renderer:  renderer,
            record:    record,
            raster:    raster,
            view_proj: view_proj,
            jitter:    jitter,
            output:    &opaque,
        )!;
        record_geometry_velocity_passes(
            renderer:     renderer,
            record:       record,
            items:        items,
            after_opaque: after_opaque,
        )!;
    }!;
}

<*
 Record the motion-blur filter over the scene input into motion_blur_out.
 @param [&inout] renderer : "Open frame with the view's velocity recorded; scene_input moves to motion_blur_out."
 @param [&inout] record : "Its tile and output images change state."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require record.velocity.texture.is_valid(), record.tile_max.texture.is_valid()
*>
fn void? record_motion_blur(Renderer* renderer, ViewRecord* record) {
    acquire_motion_blur_pipelines(renderer)!;
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    uint width = record.velocity.width;
    uint height = record.velocity.height;

    open_post_chain(renderer, record)!;
    record_tiles(
        renderer: renderer,
        input:    &record.velocity,
        record:   record,
        mode:     shader::TILE_MODE_VELOCITY,
        tiles_x:  tile_count(width),
        tiles_y:  tile_count(height),
    )!;

    Target* input = record.scene_input;
    input.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.velocity.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.motion_blur_out.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    MotionBlurParams* params = &record.desc.post.motion_blur_params;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, MotionBlurRoot::size)!;
    *(MotionBlurRoot*)root.bytes.ptr = {
        .color_texture    = input.view.index,
        .depth_texture    = record.depth.view.index,
        .velocity_texture = record.velocity.view.index,
        .tile_texture     = record.tile_neighbor.view.index,
        .output_texture   = record.motion_blur_out.view.index,
        .sampler_index    = renderer.linear_clamp_sampler,
        .width            = width,
        .height           = height,
        .samples          = params.samples,
        .shutter          = params.shutter,
        .max_velocity     = params.max_velocity,
        .texel            = { 1.0f / (float)width, 1.0f / (float)height },
    };
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.motion_blur)!;
    render::dispatch_over(renderer, root.address, &record.motion_blur_out)!;
    renderer.stats.post_dispatches += 1;
    record.scene_input = &record.motion_blur_out;
}

fn void? acquire_motion_blur_pipelines(Renderer* renderer) @private {
    render::acquire_compute_slot(renderer, ComputeSlot.MOTION_BLUR)!;
}

fn void? acquire_velocity_pipelines(
    Renderer* renderer,
    gpu::Format format,
    gpu::SampleCount samples,
) @private {
    renderer.pipelines.get(&renderer.device, camera_velocity_pipeline_key(format, samples))!;
}

fn VelocityTargets single_velocity_targets(ViewRecord* record) @private {
    return {
        .color       = &record.velocity,
        .depth       = &record.depth,
        .depth_state = render::DEPTH_ATTACHMENT_STATE,
        .samples     = gpu::SampleCount.ONE,
    };
}

fn VelocityTargets opaque_velocity_targets(ViewRecord* record) @private {
    if (record.desc.msaa == MsaaSamples.ONE) return single_velocity_targets(record);

    return {
        .color       = &record.msaa_velocity,
        .depth       = &record.msaa_depth,
        .depth_state = render::DEPTH_RESOLVE_STATE,
        .samples     = render::msaa_sample_count(record.desc.msaa),
    };
}

fn void? record_camera_velocity(
    Renderer* renderer,
    ViewRecord* record,
    CameraMatrices* raster,
    Mat4 view_proj,
    Vec2 jitter,
    VelocityTargets* output,
) @private {
    record.depth.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    output.color.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, VelocityRoot::size)!;
    Mat4 reprojection = render::camera_clip_reprojection(
        current_view_proj: view_proj,
        previous_view_proj: record.history.valid ? record.history.view_proj : view_proj,
        previous_origin: record.history.valid ? record.history.origin : renderer.frame_origin,
        current_origin: renderer.frame_origin,
        jitter: jitter,
    );
    Mat4 inverse_projection = raster.proj.inverse()!!;
    float background_near_ratio = inverse_projection.m33 / (inverse_projection.m32 + inverse_projection.m33);
    *(VelocityRoot*)root.bytes.ptr = {
        .depth_texture  = record.depth.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .orthographic   = record.projection_terms.orthographic ? 1 : 0,
        .jitter_uv      = jitter_uv(jitter),
        .background_near_ratio = background_near_ratio,
        .clip_to_previous = bitcast(reprojection, Mat4f),
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(
        &renderer.device,
        camera_velocity_pipeline_key(record.velocity.format, output.samples),
    )!;
    return render::record_fullscreen_pass(
        renderer:      renderer,
        target:        output.color,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          {},
        load:          gpu::LoadOp.DONT_CARE,
    );
}

// Opaque motion is drawn at the view's count and copied to the single-sample image first; scene-read depth
// writers were drawn single-sample, so they redraw last against the resolved depth.
fn void? record_geometry_velocity_passes(
    Renderer* renderer,
    ViewRecord* record,
    DrawItem[] items,
    DrawItem[] after_opaque,
) @private {
    VelocityTargets opaque = opaque_velocity_targets(record);
    if (record.desc.msaa == MsaaSamples.ONE) {
        DrawItem[][2] groups = { items, after_opaque };
        return record_geometry_velocity(
            renderer:           renderer,
            groups:             groups[..],
            after_opaque_first: 1,
            targets:            &opaque,
        );
    }

    DrawItem[][1] opaque_groups = { items };
    record_geometry_velocity(
        renderer:           renderer,
        groups:             opaque_groups[..],
        after_opaque_first: 1,
        targets:            &opaque,
    )!;
    render::record_sample_zero(renderer, &record.msaa_velocity, &record.velocity)!;

    VelocityTargets single = single_velocity_targets(record);
    DrawItem[][1] late_groups = { after_opaque };
    return record_geometry_velocity(
        renderer:           renderer,
        groups:             late_groups[..],
        after_opaque_first: 0,
        targets:            &single,
    );
}

// Groups from after_opaque_first on were drawn after the opaque pass; only their depth writers are redrawn.
fn void? record_geometry_velocity(
    Renderer* renderer,
    DrawItem[][] groups,
    uint after_opaque_first,
    VelocityTargets* targets,
) @private {
    Target* velocity = targets.color;
    gpu::PipelineHandle bound = resolve_velocity_pipelines(
        renderer:           renderer,
        groups:             groups,
        after_opaque_first: after_opaque_first,
        format:             velocity.format,
        samples:            targets.samples,
    )!;
    if (!bound.is_valid()) return;

    uint width = velocity.width;
    uint height = velocity.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view     = velocity.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::DepthTargetDesc depth = {
        .view     = targets.depth.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = width,
        .height = height,
    };
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    gpu::GraphicsState state = render::fullscreen_state(
        width:         width,
        height:        height,
        rect:          {},
        color_targets: color_targets[..],
    )!;
    state.depth = {
        .test_enable  = true,
        .write_enable = false,
        .compare      = gpu::CompareOp.EQUAL,
    };

    // Bound before the pass begins: the backend checks the bound pipeline against the pass formats at begin.
    gpu::cmd_bind_pipeline(&renderer.commands, bound)!;
    targets.depth.transition(&renderer.commands, targets.depth_state)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    bool state_set;
    foreach (group : groups) foreach (&item : group) {
        if (!item.velocity_pipeline.is_valid()) continue;

        Material* material = render::material_data(renderer, item.material);
        if (item.velocity_pipeline.index != bound.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, item.velocity_pipeline)!;
            bound = item.velocity_pipeline;
        }
        gpu::CullMode cull = material.common.double_sided ? gpu::CullMode.NONE : gpu::CullMode.BACK;
        gpu::PrimitiveTopology topology = render::primitive_topology(item.geometry.topology);
        if (!state_set || cull != state.raster.cull_mode || item.front_face != state.raster.front_face
            || topology != state.raster.topology) {
            state.raster.cull_mode = cull;
            state.raster.front_face = item.front_face;
            state.raster.topology = topology;
            gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
            state_set = true;
        }

        draw_velocity_item(renderer, item)!;

        if (item.outline_velocity_pipeline.is_valid()) {
            gpu::cmd_bind_pipeline(&renderer.commands, item.outline_velocity_pipeline)!;
            bound = item.outline_velocity_pipeline;
            state.raster.cull_mode = gpu::CullMode.FRONT;
            gpu::cmd_set_graphics_state(&renderer.commands, &state)!;

            draw_velocity_item(renderer, item)!;
        }
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? draw_velocity_item(Renderer* renderer, DrawItem* item) @private {
    GeometryLayout* layout = &item.geometry.layout;
    if (render::candidate_instanced(item.candidate)) {
        render::issue_batch_draw(
            renderer: renderer,
            root:     item.root,
            geometry: item.geometry,
            range:    item.range,
        )!;
    } else if (layout.index_count) {
        gpu::cmd_draw_indexed(
            commands:       &renderer.commands,
            vertex_root:    item.root,
            fragment_root:  item.root,
            index_span:     item.geometry.indices,
            index_count:    layout.index_count,
            instance_count: 1,
            index_type:     layout.flags.indices_u16 ? gpu::IndexType.U16 : gpu::IndexType.U32,
        )!;
    } else {
        gpu::cmd_draw(
            commands:       &renderer.commands,
            vertex_root:    item.root,
            fragment_root:  item.root,
            vertex_count:   layout.vertex_count,
            instance_count: 1,
        )!;
    }

    renderer.stats.draws++;
}

// An invalid result means no item is redrawn, so the pass is not begun.
fn gpu::PipelineHandle? resolve_velocity_pipelines(
    Renderer* renderer,
    DrawItem[][] groups,
    uint after_opaque_first,
    gpu::Format format,
    gpu::SampleCount samples,
) @private {
    gpu::PipelineHandle first;
    foreach (group_index, group : groups) foreach (&item : group) {
        if (!velocity_redrawn(renderer, item, group_index >= after_opaque_first)) continue;
        gpu::PipelineHandle? pipeline = velocity_pipeline_for(
            renderer: renderer,
            item:     item,
            format:   format,
            samples:  samples,
        );
        if (catch excuse = pipeline) {
            if (!velocity_form_rejected(renderer, item, excuse)) return excuse~;
            continue;
        }
        item.velocity_pipeline = pipeline;
        if (item.outline_pipeline.is_valid()) {
            item.outline_velocity_pipeline = velocity_pipeline_for(
                renderer: renderer,
                item:     item,
                format:   format,
                outline:  true,
                samples:  samples,
            )!;
        }

        if (!first.is_valid()) first = pipeline;
    }
    return first;
}

fn bool velocity_redrawn(Renderer* renderer, DrawItem* item, bool after_opaque) @private {
    if (!item.moved) return false;
    return !after_opaque || render::writes_own_depth(render::material_data(renderer, item.material));
}

fn bool velocity_form_rejected(Renderer* renderer, DrawItem* item, fault excuse) @private {
    if (!item.custom_velocity) return false;
    return render::custom_pipeline_rejected(renderer, render::material_data(renderer, item.material), excuse);
}

fn PipelineKey geometry_velocity_pipeline_key(
    ShaderVariant vertex,
    gpu::PolygonMode polygon,
    gpu::Format format,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
) @private {
    return {
        .vertex = { .shader = MESH, .flags = vertex.flags | shader::SHADER_FLAG_VELOCITY },
        .fragment = { .shader = VELOCITY },
        .color_formats = { [0] = format },
        .color_count = 1,
        .depth_format = render::DEPTH_FORMAT,
        .samples = samples,
        .polygon = polygon,
    };
}

fn gpu::PipelineHandle? velocity_pipeline_for(
    Renderer* renderer,
    DrawItem* item,
    gpu::Format format,
    bool outline = false,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
) @private {
    Material* material = render::material_data(renderer, item.material);
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = geometry_velocity_pipeline_key(
        vertex: outline ? render::outline_vertex_variant(item.vertex) : item.vertex,
        polygon: wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
        format: format,
        samples: samples,
    );
    if (item.candidate.impostor) {
        key.vertex = { .shader = IMPOSTOR_VERTEX };
        key.fragment = { .shader = IMPOSTOR_VELOCITY };
    }
    if (!item.custom_velocity) return renderer.pipelines.get(&renderer.device, key);

    ShaderRes* published = render::resolve_shader(renderer, material.custom.shader)!;
    uint instanced = item.vertex.flags & shader::SHADER_FLAG_INSTANCED;
    key.vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_VELOCITY | instanced };
    key.custom = { .vertex = true };
    return render::custom_pipeline(renderer, published, key);
}

fn PipelineKey camera_velocity_pipeline_key(
    gpu::Format format,
    gpu::SampleCount samples = gpu::SampleCount.ONE,
) @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = VELOCITY_CAMERA },
        .color_formats = { [0] = format },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = samples,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

// Mirrored as the body of velocity_camera.frag.glsl; the renderer records the shader, tests check this twin.
fn Vec3 camera_velocity(
    Vec2 uv,
    float depth,
    Mat4 inv_view_proj,
    Mat4 prev_view_proj,
    Vec2 jitter_offset,
    bool orthographic,
) @private {
    if (depth == 0 && orthographic) return {};
    Vec2 ndc = (uv * 2 - 1) * (Vec2){ 1, -1 };
    Vec4 world = inv_view_proj * (Vec4){ ndc.x, ndc.y, depth, 1 };
    Vec4 previous;
    if (depth > 0) {
        previous = prev_view_proj * (Vec4){ world.x / world.w, world.y / world.w, world.z / world.w, 1 };
    } else {
        // A finite far plane unprojects depth 0 to a point; the ray from the near plane to it is the direction.
        Vec4 near_point = inv_view_proj * (Vec4){ ndc.x, ndc.y, 1, 1 };
        Vec3 direction = world.xyz - near_point.xyz * (world.w / near_point.w);
        previous = prev_view_proj * (Vec4){ direction.x, direction.y, direction.z, 0 };
    }
    Vec2 previous_uv = (Vec2){ previous.x / previous.w, previous.y / previous.w } * (Vec2){ 0.5f, -0.5f } + 0.5f;
    float previous_depth = depth > 0 ? previous.z / previous.w : 0;
    Vec2 motion = uv - jitter_offset - previous_uv;
    return { motion.x, motion.y, previous_depth };
}

fn Vec2 jitter_uv(Vec2 jitter) @private {
    return jitter * (Vec2){ 0.5f, -0.5f };
}
