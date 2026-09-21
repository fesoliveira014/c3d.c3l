module c3d::render::post;

import c3d;
import c3d::camera;
import c3d::material;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

const gpu::Format VELOCITY_TARGET_FORMAT @private = gpu::Format.RG16_FLOAT;

<*
 Record velocity and the motion-blur filter over the scene input into motion_blur_out.
 @param [&inout] renderer : "Open frame with its forward passes recorded; scene_input moves to motion_blur_out."
 @param [&inout] record : "Its velocity, tile and output images change state."
 @param items : "Opaque draw items with their roots written; moved ones are redrawn."
 @param [&in] matrices : "Current view matrices."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require record.velocity.texture.is_valid(), record.tile_max.texture.is_valid()
*>
fn void? record_motion_blur(
    Renderer* renderer,
    ViewRecord* record,
    DrawItem[] items,
    CameraMatrices* matrices,
) {
    acquire_motion_blur_pipelines(renderer)!;
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    uint width = record.velocity.width;
    uint height = record.velocity.height;

    render::begin_profile_pass(renderer, Pass.VELOCITY)!;
    record_camera_velocity(renderer, record, matrices)!;
    record_geometry_velocity(renderer, record, items)!;
    render::end_profile_pass(renderer, Pass.VELOCITY)!;

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
    dispatch_over(renderer, root.address, &record.motion_blur_out)!;
    renderer.stats.post_dispatches += 1;
    record.scene_input = &record.motion_blur_out;
}

fn void? acquire_motion_blur_pipelines(Renderer* renderer) @private {
    acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.motion_blur,
        shader:     ShaderName.MOTION_BLUR,
        debug_name: "post_motion_blur",
    )!;
    renderer.pipelines.get(&renderer.device, camera_velocity_pipeline_key())!;
}

fn void? record_camera_velocity(Renderer* renderer, ViewRecord* record, CameraMatrices* matrices) @private {
    record.depth.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    record.velocity.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, VelocityRoot::size)!;
    Mat4 prev_view_proj = record.history.valid ? record.history.view_proj : matrices.view_proj;
    *(VelocityRoot*)root.bytes.ptr = {
        .depth_texture  = record.depth.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .orthographic   = record.projection_terms.orthographic ? 1 : 0,
        .inv_view_proj  = bitcast(matrices.inv_view_proj, Mat4f),
        .prev_view_proj = bitcast(prev_view_proj, Mat4f),
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, camera_velocity_pipeline_key())!;
    return render::record_fullscreen_pass(
        renderer:      renderer,
        target:        &record.velocity,
        pipeline:      pipeline,
        fragment_root: root.address,
        rect:          {},
        load:          gpu::LoadOp.DONT_CARE,
    );
}

fn void? record_geometry_velocity(Renderer* renderer, ViewRecord* record, DrawItem[] items) @private {
    DrawItem* first;
    foreach (&item : items) {
        if (item.moved) {
            first = item;
            break;
        }
    }
    if (!first) return;

    uint width = record.velocity.width;
    uint height = record.velocity.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view     = record.velocity.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::DepthTargetDesc depth = {
        .view     = record.depth.attachment,
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
    gpu::PipelineHandle bound = velocity_pipeline_for(renderer, first)!;
    gpu::cmd_bind_pipeline(&renderer.commands, bound)!;
    record.depth.transition(&renderer.commands, render::DEPTH_ATTACHMENT_STATE)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    bool state_set;
    foreach (&item : items) {
        if (!item.moved) continue;

        Material* material = &renderer.assets.material(item.material.asset).data;
        gpu::PipelineHandle wanted = velocity_pipeline_for(renderer, item)!;
        if (wanted.index != bound.index) {
            gpu::cmd_bind_pipeline(&renderer.commands, wanted)!;
            bound = wanted;
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

        GeometryLayout* layout = &item.geometry.layout;
        if (layout.index_count) {
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
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn gpu::PipelineHandle? velocity_pipeline_for(Renderer* renderer, DrawItem* item) @private {
    Material* material = &renderer.assets.material(item.material.asset).data;
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    PipelineKey key = {
        .vertex        = { .shader = MESH, .flags = item.vertex.flags | shader::SHADER_FLAG_VELOCITY },
        .fragment      = { .shader = VELOCITY },
        .color_formats = { [0] = VELOCITY_TARGET_FORMAT },
        .color_count   = 1,
        .depth_format  = render::DEPTH_FORMAT,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL,
    };
    return renderer.pipelines.get(&renderer.device, key);
}

fn PipelineKey camera_velocity_pipeline_key() @private {
    return {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = VELOCITY_CAMERA },
        .color_formats = { [0] = VELOCITY_TARGET_FORMAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}
