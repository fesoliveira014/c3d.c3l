module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::math;

<*
 Fewest rays per texel.
*>
const uint SSGI_RAYS_MIN = 1;

<*
 Most rays per texel.
*>
const uint SSGI_RAYS_MAX = 8; // 8 rays x 24 steps over a half-resolution 1080p view: 99 M depth reads a frame

<*
 Fewest march steps per ray.
*>
const uint SSGI_STEPS_MIN = 4;

<*
 Most march steps per ray.
*>
const uint SSGI_STEPS_MAX = 64;

<*
 Four rays of 24 steps over two view units, full strength.
*>
const ScreenSpaceGiDesc SCREEN_SPACE_GI_DEFAULT = {
    .enabled        = true,
    .rays           = 4,
    .max_steps      = 24,
    .max_distance   = 2,
    .thickness      = 0.2f,
    .intensity      = 1,
    .history_weight = 0.9f,
};

<*
 History images per kind; they follow ViewHistory.slot.
*>
const uint SSGI_HISTORY_SLOTS = 2; // 1920 x 1080: 8.3 MB of accumulation and 4.1 MB of depth history

const float SSGI_DEPTH_TOLERANCE @private = 0.05f;   // relative linear depth, TAA's default
const float SSGI_VELOCITY_THRESHOLD @private = 2;    // full-resolution pixels a frame, TAA's default
const uint SSGI_NOISE_PERIOD @private = 64;          // frames; at 8 rays the noise's float offset stays precise
const ZString[SSGI_HISTORY_SLOTS] SSGI_HISTORY_NAMES @private = { "ssgi_history_0", "ssgi_history_1" };
const ZString[SSGI_HISTORY_SLOTS] SSGI_DEPTH_NAMES @private = { "ssgi_depth_0", "ssgi_depth_1" };
const float SSGI_BACKGROUND_DISTANCE @private = 1e30f; // mirrored as BACKGROUND_VIEW_DISTANCE in gbuffer.glsl

<*
 Screen-space indirect diffuse of one view; a zeroed value is off.
*>
struct ScreenSpaceGiDesc {
    bool  enabled;
    uint  rays;           // per half-resolution texel and frame
    uint  max_steps;      // march steps per ray
    float max_distance;   // view-space units a ray marches
    float thickness;      // view-space depth a marched point may sit behind a stored surface and hit
    float intensity;      // blend strength in [0, 1]
    float history_weight; // share of the accumulation kept per frame, in [0, 1)
}

struct ScreenSpaceGiPipelines @private {
    gpu::PipelineHandle trace;
    gpu::PipelineHandle temporal;
    gpu::PipelineHandle filter;
}

<*
 Whether the settings can configure a view.
 @param [&in] desc : "Settings to check."
 @pure
*>
fn bool screen_space_gi_desc_valid(ScreenSpaceGiDesc* desc) {
    if (!desc.enabled) return true;
    return desc.rays >= SSGI_RAYS_MIN && desc.rays <= SSGI_RAYS_MAX
        && desc.max_steps >= SSGI_STEPS_MIN && desc.max_steps <= SSGI_STEPS_MAX
        && math::is_finite(desc.max_distance) && desc.max_distance > 0
        && math::is_finite(desc.thickness) && desc.thickness > 0
        && math::is_finite(desc.intensity) && desc.intensity >= 0 && desc.intensity <= 1
        && math::is_finite(desc.history_weight) && desc.history_weight >= 0 && desc.history_weight < 1;
}

// Mirrored as view_distance in gbuffer.glsl.
fn float projected_view_distance(ProjectionTerms terms, float depth) @private {
    if (terms.orthographic) return (terms.m23 - depth) / terms.m22;
    float denominator = depth + terms.m22;
    return denominator > 0 ? terms.m23 / denominator : SSGI_BACKGROUND_DISTANCE;
}

// Mirrored as ssgi_depth_matches in screen_space_gi.glsl: any texel of the footprint within the relative tolerance.
fn bool ssgi_depth_matches(ProjectionTerms terms, float expected, float[4] stored, float tolerance) @private {
    float expected_distance = projected_view_distance(terms, expected);
    foreach (depth : stored) {
        if (expected == 0 && depth == 0) return true;
        if (expected == 0 || depth == 0) continue;
        if (math::abs(projected_view_distance(terms, depth) - expected_distance) <= tolerance * expected_distance) {
            return true;
        }
    }
    return false;
}

// Mirrored as ssgi_history_confidence in ssgi_temporal.comp.glsl.
fn float ssgi_history_confidence(bool depth_match, float velocity_pixels, float threshold) @private {
    if (!depth_match) return 0;
    float ramp = math::clamp((velocity_pixels - threshold) / threshold, 0.0f, 1.0f);
    return 1 - ramp * ramp * (3 - 2 * ramp);
}

// Mirrored as screen_space_base_share in screen_space_gi.glsl.
fn float screen_space_base_share(float occlusion, float ambient_occlusion, Vec4 screen_indirect) @private {
    return math::min(occlusion, ambient_occlusion, 1 - screen_indirect.w);
}

fn void? acquire_screen_space_gi_pipelines(Renderer* renderer) @private {
    ScreenSpaceGiPipelines* pipelines = &renderer.screen_space_gi_pipelines;
    acquire_compute_pipeline(renderer, &pipelines.trace, SSGI_TRACE, "ssgi_trace")!;
    acquire_compute_pipeline(renderer, &pipelines.temporal, SSGI_TEMPORAL, "ssgi_temporal")!;
    acquire_compute_pipeline(renderer, &pipelines.filter, SSGI_FILTER, "ssgi_filter")!;
}

fn void destroy_screen_space_gi_pipelines(gpu::Device* device, ScreenSpaceGiPipelines* pipelines) @private {
    if (pipelines.trace.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.trace);
    if (pipelines.temporal.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.temporal);
    if (pipelines.filter.is_valid()) (void)gpu::destroy_pipeline(device, pipelines.filter);
    *pipelines = {};
}

fn void? acquire_ssgi_images(Renderer* renderer, ViewRecord* record) @private {
    bool present = record.ssgi.texture.is_valid();
    if (!record.desc.screen_space_gi.enabled || present || !record.hdr_color.texture.is_valid()) return;

    defer catch release_ssgi_images(&renderer.device, record);
    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    uint[<2>] half = ambient_occlusion_extent(width, height, false);
    record.ssgi_raw = allocate_storage_target(
        device:     &renderer.device,
        width:      half.x,
        height:     half.y,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "ssgi_raw",
    )!;
    for (uint slot = 0; slot < SSGI_HISTORY_SLOTS; slot++) {
        record.ssgi_history[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      half.x,
            height:     half.y,
            format:     gpu::Format.RGBA16_FLOAT,
            debug_name: SSGI_HISTORY_NAMES[slot],
        )!;
        record.ssgi_depth[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      half.x,
            height:     half.y,
            format:     gpu::Format.R32_FLOAT,
            debug_name: SSGI_DEPTH_NAMES[slot],
        )!;
    }
    record.ssgi_color = allocate_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     HDR_FORMAT,
        usage:      { .color_attach, .sampled },
        debug_name: "ssgi_color",
    )!;
    record.ssgi = allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "ssgi",
    )!;
}

fn void release_ssgi_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.ssgi_raw.texture.is_valid()) release_storage_target(device, &record.ssgi_raw);
    foreach (&image : record.ssgi_history) {
        if (image.texture.is_valid()) release_storage_target(device, image);
    }
    foreach (&image : record.ssgi_depth) {
        if (image.texture.is_valid()) release_storage_target(device, image);
    }
    if (record.ssgi_color.texture.is_valid()) release_target(device, &record.ssgi_color);
    if (record.ssgi.texture.is_valid()) release_storage_target(device, &record.ssgi);
}

<*
 @require record.ssgi.texture.is_valid() && record.velocity.texture.is_valid()
*>
fn void? record_screen_space_gi(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    bool history_valid,
) @private {
    ScreenSpaceGiDesc* desc = &record.desc.screen_space_gi;
    acquire_screen_space_gi_pipelines(renderer)!;
    ScreenSpaceGiPipelines* pipelines = &renderer.screen_space_gi_pipelines;
    bool deferred = record.desc.shading == ShadingPath.DEFERRED;
    Target* normals = &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS.ordinal];
    gpu::TextureIndex normals_index = deferred ? normals.view.index : (gpu::TextureIndex)0;
    uint normal_flag = deferred ? shader::SSGI_FLAG_GBUFFER_NORMALS : 0;
    uint history_flag = history_valid ? shader::SSGI_FLAG_HISTORY_VALID : 0;
    uint previous = record.history.slot;
    uint next = (previous + 1) % SSGI_HISTORY_SLOTS;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::TextureState compute_read = gpu::sampled_at({ .compute });
    gpu::TextureState compute_write = gpu::storage_at({ .compute }, { .write });

    @profile_pass(renderer, Pass.SCREEN_SPACE_GI) {
        record.depth.transition(&renderer.commands, compute_read)!;
        if (deferred) normals.transition(&renderer.commands, compute_read)!;
        record.velocity.transition(&renderer.commands, compute_read)!;
        record.ssgi_color.transition(&renderer.commands, compute_read)!;
        record.ssgi_depth[previous].transition(&renderer.commands, compute_read)!;
        record.ssgi_history[previous].transition(&renderer.commands, compute_read)!;
        record.ssgi_raw.transition(&renderer.commands, compute_write)!;
        gpu::MappedGpuSpan trace_root = slot.upload.take(&renderer.device, SsgiTraceRoot::size, STREAM_ALIGNMENT)!;
        *(SsgiTraceRoot*)trace_root.bytes.ptr = {
            .frame           = frame,
            .depth           = record.depth.view.index,
            .normals         = normals_index,
            .velocity        = record.velocity.view.index,
            .previous_color  = record.ssgi_color.view.index,
            .previous_depth  = record.ssgi_depth[previous].view.index,
            .output_texture  = record.ssgi_raw.view.index,
            .sampler_index   = renderer.linear_clamp_sampler,
            .width           = record.ssgi_raw.width,
            .height          = record.ssgi_raw.height,
            .rays            = desc.rays,
            .max_steps       = desc.max_steps,
            .max_distance    = desc.max_distance,
            .thickness       = desc.thickness,
            .depth_tolerance = SSGI_DEPTH_TOLERANCE,
            .noise_frame     = (uint)(renderer.frame_index % SSGI_NOISE_PERIOD),
            .flags           = normal_flag | history_flag,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, pipelines.trace)!;
        dispatch_over(renderer, trace_root.address, &record.ssgi_raw)!;

        record.ssgi_raw.transition(&renderer.commands, compute_read)!;
        record.ssgi_history[next].transition(&renderer.commands, compute_write)!;
        record.ssgi_depth[next].transition(&renderer.commands, compute_write)!;
        gpu::MappedGpuSpan temporal_root = slot.upload.take(
            &renderer.device,
            SsgiTemporalRoot::size,
            STREAM_ALIGNMENT,
        )!;
        *(SsgiTemporalRoot*)temporal_root.bytes.ptr = {
            .frame              = frame,
            .raw                = record.ssgi_raw.view.index,
            .history            = record.ssgi_history[previous].view.index,
            .previous_depth     = record.ssgi_depth[previous].view.index,
            .depth              = record.depth.view.index,
            .velocity           = record.velocity.view.index,
            .output_texture     = record.ssgi_history[next].view.index,
            .output_depth       = record.ssgi_depth[next].view.index,
            .sampler_index      = renderer.linear_clamp_sampler,
            .width              = record.ssgi_raw.width,
            .height             = record.ssgi_raw.height,
            .history_weight     = desc.history_weight,
            .depth_tolerance    = SSGI_DEPTH_TOLERANCE,
            .velocity_threshold = SSGI_VELOCITY_THRESHOLD,
            .flags              = history_flag,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, pipelines.temporal)!;
        dispatch_over(renderer, temporal_root.address, &record.ssgi_history[next])!;

        record.ssgi_history[next].transition(&renderer.commands, compute_read)!;
        record.ssgi.transition(&renderer.commands, compute_write)!;
        gpu::MappedGpuSpan filter_root = slot.upload.take(&renderer.device, SsgiFilterRoot::size, STREAM_ALIGNMENT)!;
        *(SsgiFilterRoot*)filter_root.bytes.ptr = {
            .frame          = frame,
            .input_texture  = record.ssgi_history[next].view.index,
            .depth          = record.depth.view.index,
            .normals        = normals_index,
            .output_texture = record.ssgi.view.index,
            .input_width    = record.ssgi_raw.width,
            .input_height   = record.ssgi_raw.height,
            .width          = record.ssgi.width,
            .height         = record.ssgi.height,
            .intensity      = desc.intensity,
            .flags          = normal_flag,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, pipelines.filter)!;
        dispatch_over(renderer, filter_root.address, &record.ssgi)!;
    }!;

    record.ssgi.transition(&renderer.commands, gpu::sampled_at({ .fragment_shader }))!;
    renderer.stats.post_dispatches += 3;
}

<*
 @require record.ssgi_color.texture.is_valid()
*>
fn void? record_ssgi_color_copy(Renderer* renderer, ViewRecord* record) @private {
    @profile_pass(renderer, Pass.SSGI_COLOR_COPY) {
        composite_target(renderer, &record.hdr_color, &record.ssgi_color, {})!;
    }!;
    record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
}
