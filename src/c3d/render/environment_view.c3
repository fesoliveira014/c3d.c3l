module c3d::render;

import c3d;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

struct ViewEnvironments @private {
    EnvironmentRes* lighting;
    EnvironmentRes* sky;
    Vec4             clear_color;
}

fn ViewEnvironments? resolve_view_environments(Renderer* renderer, Scene* scene_data, bool sheen) @private {
    ViewEnvironments selected = { .clear_color = scene_data.background.color };
    if (renderer.assets.environments.is_live(scene_data.environment)) {
        selected.lighting = ensure_environment(
            renderer: renderer,
            environment: scene_data.environment,
            lighting: true,
            sheen: sheen,
        )!;
    } else if (scene_data.environment.generation) {
        renderer.stats.dangling_refs++;
    }
    if (scene_data.background.kind == BackgroundKind.ENVIRONMENT) {
        EnvironmentId environment = scene_data.background.environment;
        if (renderer.assets.environments.is_live(environment)) {
            selected.sky = ensure_environment(
                renderer: renderer,
                environment: environment,
                lighting: false,
                sheen: false,
            )!;
            sky_pipeline(renderer)!;
        } else if (environment.generation) {
            renderer.stats.dangling_refs++;
        }
    }
    return selected;
}

fn gpu::GpuAddress? pack_lighting_environment(
    Renderer* renderer,
    EnvironmentRes* environment,
    float intensity,
    Quat rotation,
    bool sheen,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, EnvironmentGpu::size, STREAM_ALIGNMENT)!;
    *(EnvironmentGpu*)span.bytes.ptr = {
        .specular_cube = environment.specular_view.index,
        .sampler_index = renderer.environment_state.sampler,
        .brdf_lut      = renderer.environment_state.brdf_view.index,
        .intensity     = intensity,
        .sh            = environment.irradiance_address,
        .sheen_cube    = sheen ? environment.sheen_view.index : (gpu::TextureIndex)0,
        .rotation      = pack_environment_rotation(rotation),
    };
    return span.address;
}

fn gpu::GpuAddress? pack_sky(
    Renderer* renderer,
    EnvironmentRes* environment,
    gpu::GpuAddress frame,
    float intensity,
    Quat rotation,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, SkyRoot::size, STREAM_ALIGNMENT)!;
    *(SkyRoot*)span.bytes.ptr = {
        .frame         = frame,
        .source_cube   = environment.source_view.index,
        .sampler_index = renderer.environment_state.sampler,
        .intensity     = intensity,
        .rotation      = pack_environment_rotation(rotation),
    };
    return span.address;
}

fn EnvironmentRotationGpu pack_environment_rotation(Quat rotation) @private {
    Mat4 matrix = rotation.to_matrix();
    return {
        .row0 = { matrix.m00, matrix.m10, matrix.m20, 0 },
        .row1 = { matrix.m01, matrix.m11, matrix.m21, 0 },
        .row2 = { matrix.m02, matrix.m12, matrix.m22, 0 },
    };
}

fn gpu::PipelineHandle? sky_pipeline(Renderer* renderer) @private {
    PipelineKey key = {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = SKY },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = DEPTH_FORMAT,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    return renderer.pipelines.get(&renderer.device, key);
}

fn void? record_sky(Renderer* renderer, gpu::GpuAddress root) @private {
    renderer.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    renderer.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    reset_sky_timing(renderer)!;

    write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.SKY,
        half:        TIMESTAMP_BEGIN,
    )!;

    gpu::ColorTargetDesc[1] colors = {{
        .view     = renderer.hdr_color.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::DepthTargetDesc depth = {
        .view     = renderer.depth.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = renderer.hdr_color.width,
        .height = renderer.hdr_color.height,
    };
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    gpu::GraphicsState state = fullscreen_state(
        renderer.hdr_color.width,
        renderer.hdr_color.height,
        color_targets[..],
    )!;
    state.depth = {
        .test_enable  = true,
        .write_enable = false,
        .compare      = gpu::CompareOp.GREATER_EQUAL,
    };

    gpu::cmd_bind_pipeline(&renderer.commands, sky_pipeline(renderer)!)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    gpu::cmd_draw(
        commands:       &renderer.commands,
        vertex_root:    (gpu::GpuAddress)0,
        fragment_root:  root,
        vertex_count:   FULLSCREEN_VERTEX_COUNT,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&renderer.commands)!;

    write_pass_timestamp(
        renderer:    renderer,
        frame_index: renderer.frame_index,
        pass:        Pass.SKY,
        half:        TIMESTAMP_END,
    )!;
    renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT].timed[Pass.SKY.ordinal] = true;
    renderer.stats.draws++;
}

fn void? reset_sky_timing(Renderer* renderer) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    if (!slot.timed[Pass.SKY.ordinal]) return;
    if (renderer.timestamps_enabled) {
        gpu::cmd_reset_timestamps(
            commands: &renderer.commands,
            pool:     renderer.timestamps,
            first:    pass_timestamp_slot(renderer.frame_index, Pass.SKY.ordinal),
            count:    TIMESTAMPS_PER_PASS,
        )!;
    }
    slot.timed[Pass.SKY.ordinal] = false;
}
