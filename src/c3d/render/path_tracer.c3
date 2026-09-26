module c3d::render;

import c3d;
import c3d::camera;
import c3d::instrumentation @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert PathTraceRoot::size == 64;

<*
 Most bounces a path-traced view accepts.
*>
const uint PATH_TRACE_BOUNCES_MAX = 16; // each bounce is one traced ray plus one shadow ray per light

<*
 Most samples one path-traced frame folds into the image.
*>
const uint PATH_TRACE_SAMPLES_PER_FRAME_MAX = 16; // 16 samples at 1080p and 6 bounces trace about 200 M rays a frame

<*
 Path-traced rendering of one view.
*>
struct PathTraceDesc {
    uint max_bounces;
    uint samples_per_frame;
    uint max_samples;
}

<*
 Six bounces, one sample per frame, no sample cap.
*>
const PathTraceDesc PATH_TRACE_DEFAULT = {
    .max_bounces       = 6,
    .samples_per_frame = 1,
};

struct SbtLayout @private {
    usz record_stride;
    usz miss_offset;
    usz hit_offset;
    usz total_bytes;
}

struct PathTracer @private {
    gpu::PipelineHandle               pipeline;
    gpu::GpuAllocation                sbt;
    gpu::RayTracingShaderBindingTable regions;
}

<*
 @pure
*>
fn bool path_trace_desc_valid(PathTraceDesc* desc) @private {
    return desc.max_bounces >= 1 && desc.max_bounces <= PATH_TRACE_BOUNCES_MAX
        && desc.samples_per_frame >= 1 && desc.samples_per_frame <= PATH_TRACE_SAMPLES_PER_FRAME_MAX;
}

<*
 @pure
*>
fn SbtLayout sbt_layout(uint handle_size, uint handle_alignment, uint base_alignment) @private {
    usz stride = align_up(handle_size, handle_alignment);
    usz miss_offset = align_up(stride, base_alignment);
    usz hit_offset = align_up(miss_offset + stride, base_alignment);
    return {
        .record_stride = stride,
        .miss_offset   = miss_offset,
        .hit_offset    = hit_offset,
        .total_bytes   = hit_offset + stride,
    };
}

fn bool accumulation_reset_needed(
    ViewHistory* history,
    ulong scene,
    ulong trace_revision,
    Mat4 view_proj,
) @private {
    return !history.valid || history.scene != scene || history.trace_revision != trace_revision
        || !(history.view_proj == view_proj);
}

fn void? acquire_path_tracer(Renderer* renderer) @private {
    PathTracer* path_tracer = &renderer.path_tracer;
    if (path_tracer.pipeline.is_valid()) return;

    ShaderRegistry* registry = &renderer.pipelines.registry;
    gpu::ShaderDesc[1] ray_generation = {{
        .spirv      = registry.get({ .shader = ShaderName.PATH_TRACE })!,
        .debug_name = "path_trace",
    }};
    gpu::ShaderDesc[1] miss = {{
        .spirv      = registry.get({ .shader = ShaderName.PATH_TRACE_MISS })!,
        .debug_name = "path_trace_miss",
    }};
    gpu::ShaderDesc closest_hit = {
        .spirv      = registry.get({ .shader = ShaderName.PATH_TRACE_HIT })!,
        .debug_name = "path_trace_hit",
    };
    gpu::ShaderDesc any_hit = {
        .spirv      = registry.get({ .shader = ShaderName.PATH_TRACE_ANY_HIT })!,
        .debug_name = "path_trace_any_hit",
    };
    gpu::RayTracingHitGroupDesc[1] hit_groups = {{
        .kind               = gpu::RayTracingHitGroupKind.TRIANGLES,
        .closest_hit_shader = &closest_hit,
        .any_hit_shader     = &any_hit,
    }};
    gpu::RayTracingPipelineDesc description = {
        .ray_generation_shaders = ray_generation[..],
        .miss_shaders           = miss[..],
        .hit_groups             = hit_groups[..],
        .max_recursion_depth    = 1,
        .debug_name             = "path_tracer",
    };
    gpu::PipelineHandle pipeline = gpu::create_ray_tracing_pipeline(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_pipeline(&renderer.device, pipeline);

    gpu::RayTracingPipelineCaps* caps = &renderer.caps.ray_tracing_pipelines;
    SbtLayout layout = sbt_layout(
        caps.shader_group_handle_size,
        caps.shader_group_handle_alignment,
        caps.shader_group_base_alignment,
    );
    gpu::AllocationDesc sbt_desc = {
        .size         = layout.total_bytes,
        .alignment    = caps.shader_group_base_alignment,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "path_tracer_sbt",
    };
    gpu::GpuAllocation sbt = gpu::allocate_memory(&renderer.device, &sbt_desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &sbt);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, sbt)!;
    gpu::MappedGpuSpan mapped = gpu::mapped_gpu_span(&renderer.device, span)!;

    gpu::RayTracingPipelineInfo info = gpu::get_ray_tracing_pipeline_info(&renderer.device, pipeline)!;
    usz handle_size = caps.shader_group_handle_size;
    @pool() {
        char[] handles = alloc::new_array(tmem, char, (sz)(info.total_group_count * handle_size));
        gpu::get_ray_tracing_shader_group_handles(
            device:      &renderer.device,
            pipeline:    pipeline,
            first_group: 0,
            group_count: info.total_group_count,
            out:         handles,
        )!;
        usz[3] groups = { info.ray_generation.first_group, info.miss.first_group, info.hit.first_group };
        usz[3] offsets = { 0, layout.miss_offset, layout.hit_offset };
        foreach (index, group : groups) {
            mapped.bytes[offsets[index]:handle_size] = handles[group * handle_size:handle_size];
        }
    };
    gpu::flush_mapped_span(&renderer.device, span)!;

    usz stride = layout.record_stride;
    path_tracer.regions = {
        .ray_generation = { .span = span.checked_subspan(0, stride)!, .stride = stride },
        .miss           = { .span = span.checked_subspan(layout.miss_offset, stride)!, .stride = stride },
        .hit            = { .span = span.checked_subspan(layout.hit_offset, stride)!, .stride = stride },
    };
    path_tracer.pipeline = pipeline;
    path_tracer.sbt = sbt;
}

fn void destroy_path_tracer(gpu::Device* device, PathTracer* path_tracer) @private {
    if (path_tracer.pipeline.is_valid()) (void)gpu::destroy_pipeline(device, path_tracer.pipeline);
    if (path_tracer.sbt.is_valid()) (void)gpu::free_allocation(device, &path_tracer.sbt);
    *path_tracer = {};
}

fn void? acquire_accumulation(Renderer* renderer, ViewRecord* record) @private {
    if (record.desc.shading != ShadingPath.PATH_TRACED || record.accumulation.texture.is_valid()) return;
    if (!record.hdr_color.texture.is_valid()) return;

    record.accumulation = allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     gpu::Format.RGBA32_FLOAT,
        debug_name: "accumulation",
    )!;
}

fn void retire_accumulation(Renderer* renderer, ViewRecord* record) @private {
    if (!record.accumulation.texture.is_valid()) return;
    retire_storage_target(last_submitted_retire(renderer), &record.accumulation);
}

fn void release_accumulation(gpu::Device* device, ViewRecord* record) @private {
    if (record.accumulation.texture.is_valid()) release_storage_target(device, &record.accumulation);
}

<*
 @require record.desc.shading == ShadingPath.PATH_TRACED
 @require record.accumulation.texture.is_valid()
*>
fn void? record_path_traced_view(
    Renderer* renderer,
    ViewRecord* record,
    Scene* scene,
    Camera* camera,
    CameraMatrices* matrices,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @pool() {
        ViewEnvironments environments;
        instrumentation::@scope("view.uploads") {
            environments = resolve_view_environments(renderer, scene, false)!;
            record_pending_copies(renderer, &renderer.commands)!;
            prepare_sampled_targets(renderer, record)!;
        };

        gpu::GpuAddress trace_root;
        instrumentation::@scope("view.trace") {
            trace_root = renderer.prepare_scene_trace(scene, TraceKind.HARDWARE)!;
        };

        LightCounts light_counts;
        gpu::GpuAddress light_address;
        instrumentation::@scope("view.lights") {
            LightExtraction extraction = extract_lights(
                allocator:     tmem,
                scene:         scene,
                frustum:       null,
                view_layers:   camera.layers,
                capacity:      renderer.max_lights,
                counts:        &light_counts,
                trace_shadows: true,
            );
            light_address = upload_lights(renderer, extraction.lights)!;
            renderer.stats.lights += light_counts.packed;
            renderer.stats.lights_dropped += light_counts.dropped;
            record.stats.lights = light_counts.packed;
            record.stats.lights_dropped = light_counts.dropped;
        };

        gpu::MappedGpuSpan frame_span;
        gpu::GpuAddress sky_root;
        instrumentation::@scope("view.roots") {
            gpu::GpuAddress environment_address;
            if (environments.lighting) {
                environment_address = pack_lighting_environment(
                    renderer: renderer,
                    environment: environments.lighting,
                    intensity: scene.environment_intensity,
                    rotation: scene.environment_rotation,
                    sheen: false,
                )!;
            }
            Vec3 ambient = environments.lighting && !scene.ambient_add
              ? (Vec3){} : scene.ambient_color * scene.ambient_intensity;
            frame_span = slot.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
            write_frame_root(
                root:        (FrameRoot*)frame_span.bytes.ptr,
                matrices:    matrices,
                camera:      camera,
                viewport:    { (float)record.hdr_color.width, (float)record.hdr_color.height },
                info:        renderer.info,
                frame_index: renderer.frame_index,
                lights:      light_address,
                light_count: light_counts.packed,
                ambient:     { ambient.r, ambient.g, ambient.b, 0 },
                environment: environment_address,
                trace:       trace_root,
            );
            if (environments.sky) {
                sky_root = pack_sky(
                    renderer: renderer,
                    environment: environments.sky,
                    frame: frame_span.address,
                    intensity: scene.background.intensity,
                    rotation: scene.background.rotation,
                )!;
            }
        };

        instrumentation::@scope("view.record") {
            PathTraceDesc* settings = &record.desc.path_trace;
            ulong revision = renderer.scene_trace.revision;
            bool reset = accumulation_reset_needed(
                history:        &record.history,
                scene:          scene.identity,
                trace_revision: revision,
                view_proj:      matrices.view_proj,
            );
            uint held = reset ? 0 : record.history.accumulated_samples;
            uint count = settings.samples_per_frame;
            if (settings.max_samples) {
                count = math::min(count, settings.max_samples - math::min(held, settings.max_samples));
            }

            acquire_path_tracer(renderer)!;
            record.accumulation.transition(&renderer.commands, gpu::storage_at({ .ray_tracing }, { .read, .write }))!;
            record.hdr_color.transition(&renderer.commands, gpu::storage_at({ .ray_tracing }, { .write }))!;
            gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, PathTraceRoot::size, STREAM_ALIGNMENT)!;
            *(PathTraceRoot*)root.bytes.ptr = {
                .frame            = frame_span.address,
                .sky              = sky_root,
                .background_color = environments.clear_color,
                .accumulation     = record.accumulation.view.index,
                .output_texture   = record.hdr_color.view.index,
                .width            = record.accumulation.width,
                .height           = record.accumulation.height,
                .sample_index     = held,
                .sample_count     = count,
                .max_bounces      = settings.max_bounces,
            };

            @profile_pass(renderer, Pass.PATH_TRACE) {
                gpu::cmd_bind_pipeline(&renderer.commands, renderer.path_tracer.pipeline)!;
                gpu::cmd_trace_rays(
                    commands:             &renderer.commands,
                    root:                 root.address,
                    shader_binding_table: &renderer.path_tracer.regions,
                    dimensions:           { record.accumulation.width, record.accumulation.height, 1 },
                )!;
            }!;

            record.history.commit_accumulation(
                scene:          scene.identity,
                trace_revision: revision,
                view_proj:      matrices.view_proj,
                samples:        held + count,
            );
            renderer.stats.path_trace_samples += count;
            record.stats.accumulated_samples = held + count;
        };
    };
}
