module c3d::render;

import c3d;
import c3d::asset;
import c3d::light;
import c3d::material;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert CloudNoiseRoot::size == 16;
$assert CloudsRoot::size == 128;
$assert CloudsCompositeRoot::size == 48;

<*
 The cloud layer one view draws.
*>
struct CloudSelection {
    CloudLayer* layer;   // null: the view has none
    uint        ignored; // extras and invalid ones visible to the view
}

struct CloudCoverage @private {
    bool              drawn;   // false: the weather map is dangling and the layer draws nothing
    gpu::TextureIndex texture; // zero: no map, the layer covers the sky fully
}

struct CloudSun @private {
    Vec3 to_sun;
    Vec3 illuminance;
}

struct CloudPass @private {
    CloudLayer*       layer;
    gpu::TextureIndex coverage;
    CloudSun          sun;
    float             planet_radius; // zero: a flat slab
}

<*
 The first valid cloud layer in store order whose node the view's layers see.
 @param [&in] scene : "Current node visibility."
 @param view_layers : "Camera visibility mask."
*>
fn CloudSelection select_cloud_layer(Scene* scene, uint view_layers) {
    CloudSelection selection;
    scene.@each(CloudLayer; Entity entity, CloudLayer* layer) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (node.layers & view_layers)) {
            if (light::cloud_layer_valid(layer) && !selection.layer) {
                selection.layer = layer;
            } else {
                selection.ignored++;
            }
        }
    };
    return selection;
}

fn CloudCoverage? resolve_cloud_coverage(Renderer* renderer, CloudLayer* layer) @private {
    if (!layer.coverage.generation) return { .drawn = true };
    if (!renderer.assets.textures.is_live(layer.coverage)) {
        renderer.stats.dangling_refs++;
        return {};
    }
    material::TextureDesc desc = renderer.assets.texture(layer.coverage).desc;
    if (desc.is_cube || desc.depth != 0 || desc.layers != 1 || desc.format == R16_UINT) return c3d::UNSUPPORTED~;

    TextureRes* mirror = resolve_texture(renderer, layer.coverage, full_reader: true)!;
    return { .drawn = true, .texture = mirror.view.index };
}

fn CloudSun cloud_sun(
    LightExtraction* extraction,
    uint sun_light,
    AtmosphereSelection* atmosphere,
    bool atmospheric,
    float pre_exposure,
) @private {
    if (atmospheric) {
        return {
            .to_sun      = sun_direction(atmosphere.node),
            .illuminance = atmosphere.sun.color * atmosphere.sun.intensity * pre_exposure,
        };
    }
    if (!sun_light) return {};

    LightGpu* sun = &extraction.lights[sun_light - 1];
    return {
        .to_sun      = -sun.direction_cos_outer.xyz,
        .illuminance = sun.color_intensity.xyz * sun.color_intensity.w,
    };
}

fn void? acquire_cloud_noise(Renderer* renderer) @private {
    EnvironmentLut* noise = &renderer.environment_state.cloud_noise;
    if (noise.state != EnvironmentLutState.NONE) return;

    gpu::TextureDesc description = {
        .width        = shader::CLOUD_NOISE_SIZE,
        .height       = shader::CLOUD_NOISE_SIZE,
        .depth        = shader::CLOUD_NOISE_SIZE,
        .mip_levels   = 1,
        .array_layers = 1,
        .format       = gpu::Format.RGBA8_UNORM,
        .usage        = { .sampled, .storage },
        .access       = { .graphics },
        .debug_name   = "cloud_noise",
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    noise.view = gpu::create_texture_view(&renderer.device, texture, null)!;
    noise.texture = texture;
    noise.state = EnvironmentLutState.PENDING;
}

fn void? acquire_cloud_pipelines(Renderer* renderer) @private {
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.clouds, CLOUDS)!;
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.clouds_composite, CLOUDS_COMPOSITE)!;
}

fn void? acquire_cloud_targets(Renderer* renderer, ViewRecord* record) @private {
    if (record.clouds.texture.is_valid()) return;

    uint[<2>] extent = ambient_occlusion_extent(record.hdr_color.width, record.hdr_color.height, false);
    record.clouds = allocate_storage_target(
        device:     &renderer.device,
        width:      extent.x,
        height:     extent.y,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "clouds",
    )!;
    defer catch release_storage_target(&renderer.device, &record.clouds);
    record.cloud_distance = allocate_storage_target(
        device:     &renderer.device,
        width:      extent.x,
        height:     extent.y,
        format:     gpu::Format.R32_FLOAT,
        debug_name: "cloud_distance",
    )!;
}

fn void? record_cloud_noise(Renderer* renderer, gpu::CommandList* commands) @private {
    EnvironmentLut* noise = &renderer.environment_state.cloud_noise;
    acquire_environment_pipeline(renderer, &renderer.environment_state.pipelines.cloud_noise, CLOUD_NOISE)!;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: noise.texture,
        before:  {},
        after:   gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CloudNoiseRoot::size)!;
    *(CloudNoiseRoot*)root.bytes.ptr = {
        .output_texture = noise.view.index,
        .size           = shader::CLOUD_NOISE_SIZE,
    };
    uint groups = shader::CLOUD_NOISE_SIZE / shader::CLOUD_NOISE_GROUP_SIZE;
    gpu::cmd_bind_pipeline(commands, renderer.environment_state.pipelines.cloud_noise)!;
    gpu::cmd_dispatch(commands, root.address, { groups, groups, groups })!;
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: noise.texture,
        before:  write.after,
        after:   renderer.sampled_state,
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
    noise.state = EnvironmentLutState.RECORDED;
}

<*
 @require record.clouds.texture.is_valid() && record.hdr_color.texture.is_valid()
*>
fn void? record_clouds(
    Renderer* renderer,
    ViewRecord* record,
    CloudPass* cloud,
    gpu::GpuAddress frame,
) @private {
    CloudLayer* layer = cloud.layer;
    gpu::SamplerIndex repeat_sampler = resolve_sampler(renderer, c3d::asset::SAMPLER_LINEAR_REPEAT)!.index;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @profile_pass(renderer, Pass.CLOUDS) {
        record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        record.clouds.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        record.cloud_distance.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan march = slot.upload.take(&renderer.device, CloudsRoot::size, STREAM_ALIGNMENT)!;
        *(CloudsRoot*)march.bytes.ptr = {
            .sun_direction    = { cloud.sun.to_sun.x, cloud.sun.to_sun.y, cloud.sun.to_sun.z, 0 },
            .sun_illuminance  = { cloud.sun.illuminance.x, cloud.sun.illuminance.y, cloud.sun.illuminance.z, 0 },
            .wind_offset      = { layer.wind_offset.x, layer.wind_offset.y, layer.wind_offset.z, 0 },
            .frame            = frame,
            .output_texture   = record.clouds.view.index,
            .distance_texture = record.cloud_distance.view.index,
            .depth            = record.depth.view.index,
            .noise            = renderer.environment_state.cloud_noise.view.index,
            .coverage         = cloud.coverage,
            .noise_sampler    = repeat_sampler,
            .coverage_sampler = repeat_sampler,
            .width            = record.clouds.width,
            .height           = record.clouds.height,
            .planet_radius    = cloud.planet_radius,
            .bottom           = layer.bottom,
            .top              = layer.top,
            .density          = layer.density,
            .albedo           = layer.albedo,
            .anisotropy       = layer.anisotropy,
            .coverage_extent  = layer.coverage_extent,
            .noise_scale      = layer.noise_scale,
            .erosion          = layer.erosion,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.clouds)!;
        dispatch_over(renderer, march.address, &record.clouds)!;

        record.clouds.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        record.cloud_distance.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        record.hdr_color.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        gpu::MappedGpuSpan composite = slot.upload.take(&renderer.device, CloudsCompositeRoot::size, STREAM_ALIGNMENT)!;
        *(CloudsCompositeRoot*)composite.bytes.ptr = {
            .frame            = frame,
            .color            = record.hdr_color.view.index,
            .depth            = record.depth.view.index,
            .clouds           = record.clouds.view.index,
            .distance_texture = record.cloud_distance.view.index,
            .width            = record.hdr_color.width,
            .height           = record.hdr_color.height,
            .cloud_width      = record.clouds.width,
            .cloud_height     = record.clouds.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.clouds_composite)!;
        dispatch_over(renderer, composite.address, &record.hdr_color)!;
    }!;
    renderer.stats.post_dispatches += 2;
}
