module c3d::render;

import c3d;
import c3d::asset;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert CloudNoiseRoot::size == 16;
$assert CloudsRoot::size == 128;
$assert CloudShadowRoot::size == 64;
$assert CloudsCompositeRoot::size == 48;
$assert CloudsTemporalRoot::size == 112;

const uint CLOUD_SLOTS @private = 2; // a temporal view ping-pongs the images; any other view uses slot 0
const uint CLOUD_TEMPORAL_SAMPLES @private = 16; // jitter cycle; the history spans about ten frames, more repeats
const float CLOUD_HISTORY_SUN_DEGREES @private = 0.1f; // a faster sun rejects history; slower trails under a degree

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
    bool              shadowed;      // the sun is up and the layer casts its shadow
    gpu::GpuAddress   shadow;        // the frame's CloudShadowRoot
}

// What a march was made under; the sun's direction is compared by angle, the layer field by field but for its wind.
struct CloudFrame @private {
    ulong      scene;
    CloudLayer layer;
    float      planet_radius;
    Vec3       to_sun;
    Vec3       origin;
    Mat4       view_proj;
    float      pre_exposure;
}

struct CloudHistory @private {
    CloudFrame committed;
    CloudFrame pending;
    bool       valid;    // the images hold what the view's last submitted frame marched
    bool       recorded; // a recording this frame wrote them
    uint       slot;     // images that hold the history; the march writes the other pair
    uint       sample;   // jitter index of the next frame
}

<*
 Whether the history stands for a march made under these conditions.
 @param [&in] frame : "Conditions of the recording about to be made."
*>
fn bool CloudHistory.accepts(&self, CloudFrame* frame) {
    if (!self.valid || self.recorded) return false;

    CloudFrame* previous = &self.committed;
    float sun_cosine = math::cos(math::deg_to_rad(CLOUD_HISTORY_SUN_DEGREES));
    bool same_sun = previous.to_sun == frame.to_sun || previous.to_sun.dot(frame.to_sun) >= sun_cosine;
    return previous.scene == frame.scene
      && same_cloud_layer(&previous.layer, &frame.layer)
      && previous.planet_radius == frame.planet_radius
      && previous.origin == frame.origin
      && same_sun;
}

<*
 Remember the recording's conditions, pending publication.
 @param [&in] frame : "Conditions the recording was made under."
*>
fn void CloudHistory.record(&self, CloudFrame* frame) {
    self.pending = *frame;
    self.recorded = true;
}

<*
 Commit a submitted frame's recording and swap the images; a view that recorded nothing loses its history.
*>
fn void CloudHistory.publish(&self) {
    self.valid = self.recorded;
    if (self.recorded) {
        self.committed = self.pending;
        self.slot ^= 1;
        self.sample = (self.sample + 1) % CLOUD_TEMPORAL_SAMPLES;
    }
    self.recorded = false;
}

<*
 Drop the pending recording; the committed history stays.
*>
fn void CloudHistory.discard(&self) {
    self.recorded = false;
}

fn bool same_cloud_layer(CloudLayer* first, CloudLayer* second) @local {
    return first.bottom == second.bottom
      && first.top == second.top
      && first.density == second.density
      && c3d::same_id(first.coverage, second.coverage)
      && first.coverage_extent == second.coverage_extent
      && first.noise_scale == second.noise_scale
      && first.erosion == second.erosion
      && first.albedo == second.albedo
      && first.anisotropy == second.anisotropy
      && first.cast_shadows == second.cast_shadows;
}

fn uint cloud_written_slot(ViewRecord* record) @local {
    return record.desc.cloud_temporal ? record.cloud_history.slot ^ 1 : 0;
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

fn void? acquire_cloud_shadow(Renderer* renderer, ViewRecord* record) @private {
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.cloud_shadows, CLOUD_SHADOWS)!;
    if (record.cloud_shadow.texture.is_valid()) return;

    record.cloud_shadow = allocate_storage_target(
        device:     &renderer.device,
        width:      shader::CLOUD_SHADOW_SIZE,
        height:     shader::CLOUD_SHADOW_SIZE,
        format:     gpu::Format.R16_FLOAT,
        debug_name: "cloud_shadow",
    )!;
}

fn void? acquire_cloud_targets(Renderer* renderer, ViewRecord* record) @private {
    uint[<2>] extent = ambient_occlusion_extent(record.hdr_color.width, record.hdr_color.height, false);
    uint count = record.desc.cloud_temporal ? CLOUD_SLOTS : 1;
    for (uint slot = 0; slot < count; slot++) {
        if (record.clouds[slot].texture.is_valid()) continue;

        record.clouds[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      extent.x,
            height:     extent.y,
            format:     gpu::Format.RGBA16_FLOAT,
            debug_name: "clouds",
        )!;
        defer catch release_storage_target(&renderer.device, &record.clouds[slot]);
        record.cloud_distances[slot] = allocate_storage_target(
            device:     &renderer.device,
            width:      extent.x,
            height:     extent.y,
            format:     gpu::Format.R32_FLOAT,
            debug_name: "cloud_distance",
        )!;
    }
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

fn void? write_cloud_march_root(
    Renderer* renderer,
    ViewRecord* record,
    CloudPass* cloud,
    gpu::GpuAddress frame,
    CloudsRoot* root,
) @local {
    CloudLayer* layer = cloud.layer;
    uint written = cloud_written_slot(record);
    gpu::SamplerIndex repeat_sampler = resolve_sampler(renderer, c3d::asset::SAMPLER_LINEAR_REPEAT)!.index;
    *root = {
        .sun_direction    = { cloud.sun.to_sun.x, cloud.sun.to_sun.y, cloud.sun.to_sun.z, 0 },
        .sun_illuminance  = { cloud.sun.illuminance.x, cloud.sun.illuminance.y, cloud.sun.illuminance.z, 0 },
        .wind_offset      = { layer.wind_offset.x, layer.wind_offset.y, layer.wind_offset.z, 0 },
        .frame            = frame,
        .output_texture   = record.clouds[written].view.index,
        .distance_texture = record.cloud_distances[written].view.index,
        .depth            = record.depth.view.index,
        .noise            = renderer.environment_state.cloud_noise.view.index,
        .coverage         = cloud.coverage,
        .noise_sampler    = repeat_sampler,
        .coverage_sampler = repeat_sampler,
        .width            = record.clouds[written].width,
        .height           = record.clouds[written].height,
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
}

// Centred on the camera's footprint along the sun: from its own altitude between the datum and the layer's bottom, from
// the datum at or above the bottom or below the datum itself (a reflected camera), which keeps the ground under the camera
// at the centre. The window steps at those altitudes; the content is anchored to the world and snapped to its texel grid,
// so a receiver inside both windows reads the same.
fn Vec2 cloud_shadow_corner(CloudPass* cloud, Vec3 camera_position, Vec3 frame_origin) @local {
    Vec3 to_sun = cloud.sun.to_sun;
    float camera_altitude = camera_position.y + frame_origin.y;
    float altitude = camera_altitude > 0 && camera_altitude < cloud.layer.bottom ? camera_altitude : 0;
    float lean = (cloud.layer.bottom - altitude) / math::max(to_sun.y, shader::CLOUD_SUN_FLOOR);
    float texel = shader::CLOUD_SHADOW_EXTENT / (float)shader::CLOUD_SHADOW_SIZE;
    Vec2 footprint = {
        camera_position.x + frame_origin.x + to_sun.x * lean,
        camera_position.z + frame_origin.z + to_sun.z * lean,
    };
    Vec2 snapped = {
        math::floor(footprint.x / texel + 0.5f) * texel,
        math::floor(footprint.y / texel + 0.5f) * texel,
    };
    return snapped - 0.5f * shader::CLOUD_SHADOW_EXTENT - (Vec2){ frame_origin.x, frame_origin.z };
}

<*
 @require cloud.shadowed
 @require record.cloud_shadow.texture.is_valid()
*>
fn gpu::GpuAddress? upload_cloud_shadow(
    Renderer* renderer,
    ViewRecord* record,
    CloudPass* cloud,
    Vec3 camera_position,
    gpu::GpuAddress frame,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan march = slot.upload.take(&renderer.device, CloudsRoot::size, STREAM_ALIGNMENT)!;
    write_cloud_march_root(renderer, record, cloud, frame, (CloudsRoot*)march.bytes.ptr)!;

    Vec2 corner = cloud_shadow_corner(cloud, camera_position, renderer.frame_origin);
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CloudShadowRoot::size, STREAM_ALIGNMENT)!;
    *(CloudShadowRoot*)root.bytes.ptr = {
        .to_sun        = { cloud.sun.to_sun.x, cloud.sun.to_sun.y, cloud.sun.to_sun.z, 0 },
        .map           = { corner.x, corner.y, 0, 0 },
        .clouds        = march.address,
        .texture       = record.cloud_shadow.view.index,
        .sampler_index = renderer.linear_clamp_sampler,
        .bottom        = cloud.layer.bottom,
        .top           = cloud.layer.top,
    };
    return root.address;
}

<*
 @require cloud.shadowed
 @require record.cloud_shadow.texture.is_valid()
*>
fn void? record_cloud_shadows(Renderer* renderer, ViewRecord* record, CloudPass* cloud) @private {
    @profile_pass(renderer, Pass.CLOUD_SHADOWS) {
        record.cloud_shadow.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.cloud_shadows)!;
        dispatch_over(renderer, cloud.shadow, &record.cloud_shadow)!;
        record.cloud_shadow.transition(&renderer.commands, renderer.sampled_state)!;
    }!;
    renderer.stats.post_dispatches++;
}

fn void? record_cloud_march(
    Renderer* renderer,
    ViewRecord* record,
    CloudPass* cloud,
    gpu::GpuAddress frame,
    CloudFrame* current,
) @local {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan march = slot.upload.take(&renderer.device, CloudsRoot::size, STREAM_ALIGNMENT)!;
    write_cloud_march_root(renderer, record, cloud, frame, (CloudsRoot*)march.bytes.ptr)!;
    Target* written = &record.clouds[cloud_written_slot(record)];
    if (!record.desc.cloud_temporal) {
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.clouds)!;
        return dispatch_over(renderer, march.address, written);
    }

    acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.sky_pipelines.clouds_temporal,
        shader:     CLOUDS,
        debug_name: "sky",
        flags:      shader::SHADER_FLAG_TEMPORAL,
    )!;
    CloudHistory* history = &record.cloud_history;
    Target* history_clouds = &record.clouds[history.slot];
    Target* history_distances = &record.cloud_distances[history.slot];
    bool reproject = history.accepts(current);
    Vec3 wind_delta;
    float pre_exposure_ratio = 1;
    if (reproject) {
        history_clouds.transition(&renderer.commands, renderer.sampled_state)!;
        history_distances.transition(&renderer.commands, renderer.sampled_state)!;
        wind_delta = current.layer.wind_offset - history.committed.layer.wind_offset;
        pre_exposure_ratio = current.pre_exposure / history.committed.pre_exposure;
    }

    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, CloudsTemporalRoot::size, STREAM_ALIGNMENT)!;
    *(CloudsTemporalRoot*)root.bytes.ptr = {
        .previous_view_proj = bitcast(history.committed.view_proj, Mat4f),
        .wind_delta         = { wind_delta.x, wind_delta.y, wind_delta.z, 0 },
        .clouds             = march.address,
        .history            = reproject ? history_clouds.view.index : (gpu::TextureIndex)0,
        .history_distance   = reproject ? history_distances.view.index : (gpu::TextureIndex)0,
        .history_sampler    = renderer.linear_clamp_sampler,
        .jitter             = maths::halton(history.sample + 1, 2),
        .pre_exposure_ratio = pre_exposure_ratio,
    };
    history.record(current);

    gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.clouds_temporal)!;
    return dispatch_extent(
        renderer:   renderer,
        root:       root.address,
        width:      written.width,
        height:     written.height,
        group_size: shader::CLOUD_TEMPORAL_GROUP,
    );
}

<*
 @require record.clouds[cloud_written_slot(record)].texture.is_valid() && record.hdr_color.texture.is_valid()
 @param [&in] current : "Conditions of the march; kept as the history when the frame is submitted."
*>
fn void? record_clouds(
    Renderer* renderer,
    ViewRecord* record,
    CloudPass* cloud,
    gpu::GpuAddress frame,
    CloudFrame* current,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    uint written = cloud_written_slot(record);
    Target* clouds = &record.clouds[written];
    Target* distances = &record.cloud_distances[written];
    @profile_pass(renderer, Pass.CLOUDS) {
        record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        clouds.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        distances.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        record_cloud_march(
            renderer: renderer,
            record:   record,
            cloud:    cloud,
            frame:    frame,
            current:  current,
        )!;

        clouds.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        distances.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
        record.hdr_color.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        gpu::MappedGpuSpan composite = slot.upload.take(&renderer.device, CloudsCompositeRoot::size, STREAM_ALIGNMENT)!;
        *(CloudsCompositeRoot*)composite.bytes.ptr = {
            .frame            = frame,
            .color            = record.hdr_color.view.index,
            .depth            = record.depth.view.index,
            .clouds           = clouds.view.index,
            .distance_texture = distances.view.index,
            .width            = record.hdr_color.width,
            .height           = record.hdr_color.height,
            .cloud_width      = clouds.width,
            .cloud_height     = clouds.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.clouds_composite)!;
        dispatch_over(renderer, composite.address, &record.hdr_color)!;
    }!;
    renderer.stats.post_dispatches += 2;
}
