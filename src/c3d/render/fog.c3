module c3d::render;

import c3d::light;
import c3d::maths;
import c3d::shader;
import gpu;
import std::math;

$assert FogPassRoot::size == 32;
$assert FogVolumeRoot::size == 128;

const uint FOG_VOLUME_SLOTS @private = 2; // a temporal view ping-pongs the pair; any other view uses slot 0
const uint FOG_TEMPORAL_SAMPLES @private = 16; // jitter cycle; the history spans about ten frames, so more only repeats
const float FOG_HISTORY_SUN_DEGREES @private = 0.1f; // a faster sun rejects history; slower trails under a degree
const ulong LIGHT_HASH_BASIS @private = 0xcbf29ce484222325;
const ulong LIGHT_HASH_PRIME @private = 0x100000001b3;

<*
 Grid of a view's fog volume; MEDIUM is the zero value.
*>
enum FogQuality : int (uint froxel_pixels, uint slices) {
    MEDIUM { 16, 64 }, // 7.03 MiB of RGBA16F per view at 2560 x 1440
    LOW { 16, 32 },    // 3.52 MiB: half of MEDIUM, with slices twice as deep
    HIGH { 8, 128 },   // 56.25 MiB: 8x MEDIUM, so opt-in
}

macro bool @fog_presets_fit_volume() @private {
    $foreach $quality : FogQuality::values:
        $if $quality.slices > shader::FOG_VOLUME_MAX_SLICES:
            return false;
        $endif
    $endforeach
    return true;
}

$assert @fog_presets_fit_volume();

macro bool @fog_slices_fill_chunks() @private {
    $foreach $quality : FogQuality::values:
        $if $quality.slices % shader::FOG_SCATTERING_CHUNK != 0:
            return false;
        $endif
    $endforeach
    return true;
}

$assert @fog_slices_fill_chunks();

// What a volume pair was injected under; the sun's direction is compared by angle, everything else exactly.
struct FogFrame @private {
    ulong     scene;
    HeightFog medium;
    float     base_height;
    Vec3      to_sun;
    ulong     lights;
    Vec3      origin;
    Mat4      view_proj;
    Vec3      camera_position;
    float     pre_exposure;
}

struct FogLighting @private {
    Vec3  to_sun;
    ulong hash;
}

struct FogHistory @private {
    FogFrame committed;
    FogFrame pending;
    bool     valid;    // the pair holds the scattering the view's last submitted frame injected
    bool     recorded; // a recording this frame wrote the pair
    uint     slot;     // volume that holds the history and receives the integration
    uint     sample;   // jitter index of the next frame
}

<*
 Whether the pair's history stands for a frame injected under these conditions.
 @param [&in] frame : "Conditions of the recording about to be made."
*>
fn bool FogHistory.accepts(&self, FogFrame* frame) {
    if (!self.valid || self.recorded) return false;

    FogFrame* previous = &self.committed;
    float sun_cosine = math::cos(math::deg_to_rad(FOG_HISTORY_SUN_DEGREES));
    bool same_sun = previous.to_sun == frame.to_sun || previous.to_sun.dot(frame.to_sun) >= sun_cosine;
    return previous.scene == frame.scene
      && same_fog(&previous.medium, &frame.medium)
      && previous.base_height == frame.base_height
      && previous.lights == frame.lights
      && previous.origin == frame.origin
      && same_sun;
}

<*
 Remember the recording's conditions, pending publication.
 @param [&in] frame : "Conditions the recording was made under."
*>
fn void FogHistory.record(&self, FogFrame* frame) {
    self.pending = *frame;
    self.recorded = true;
}

<*
 Commit a submitted frame's recording and swap the pair; a view that recorded nothing loses its history.
*>
fn void FogHistory.publish(&self) {
    self.valid = self.recorded;
    if (self.recorded) {
        self.committed = self.pending;
        self.slot ^= 1;
        self.sample = (self.sample + 1) % FOG_TEMPORAL_SAMPLES;
    }
    self.recorded = false;
}

<*
 Drop the pending recording; the committed history stays.
*>
fn void FogHistory.discard(&self) {
    self.recorded = false;
}

fn bool same_fog(HeightFog* first, HeightFog* second) @local {
    return first.density == second.density
      && first.falloff == second.falloff
      && first.albedo == second.albedo
      && first.max_distance == second.max_distance
      && first.anisotropy == second.anisotropy;
}

<*
 @require record.hdr_color.texture.is_valid()
*>
fn void? record_fog_pass(Renderer* renderer, ViewRecord* record, gpu::GpuAddress frame) @private {
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.fog, FOG)!;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @profile_pass(renderer, Pass.FOG) {
        record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
        record.hdr_color.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, FogPassRoot::size, STREAM_ALIGNMENT)!;
        *(FogPassRoot*)root.bytes.ptr = {
            .frame  = frame,
            .color  = record.hdr_color.view.index,
            .depth  = record.depth.view.index,
            .width  = record.hdr_color.width,
            .height = record.hdr_color.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.fog)!;
        dispatch_over(renderer, root.address, &record.hdr_color)!;
    }!;
    renderer.stats.post_dispatches++;
}

fn uint[<2>] fog_volume_extent(uint width, uint height, uint froxel_pixels) @private {
    return {
        (width + froxel_pixels - 1) / froxel_pixels,
        (height + froxel_pixels - 1) / froxel_pixels,
    };
}

fn void? acquire_fog_volume(Renderer* renderer, ViewRecord* record) @private {
    bool wanted = record.desc.volumetric_fog && record.desc.shading != ShadingPath.PATH_TRACED;
    if (!wanted || !record.hdr_color.texture.is_valid()) return;
    FogQuality quality = record.desc.fog_quality;
    uint[<2>] extent = fog_volume_extent(record.hdr_color.width, record.hdr_color.height, quality.froxel_pixels);
    uint count = record.desc.fog_temporal ? FOG_VOLUME_SLOTS : 1;
    foreach (&volume : record.fog_volumes[:count]) {
        if (volume.texture.is_valid()) continue;
        *volume = allocate_storage_target(
            device:     &renderer.device,
            width:      extent.x,
            height:     extent.y,
            format:     gpu::Format.RGBA16_FLOAT,
            debug_name: "fog_volume",
            depth:      quality.slices,
        )!;
    }
}

fn gpu::PipelineHandle* fog_scattering_pipeline(Renderer* renderer, bool traced, bool temporal) @local {
    SkyPipelines* pipelines = &renderer.sky_pipelines;
    if (temporal) return traced ? &pipelines.fog_scattering_temporal_traced : &pipelines.fog_scattering_temporal;
    return traced ? &pipelines.fog_scattering_traced : &pipelines.fog_scattering;
}

fn Target* fog_integrated_volume(ViewRecord* record) @private {
    return &record.fog_volumes[record.desc.fog_temporal ? record.fog_history.slot : 0];
}

fn ulong fog_hash_bytes(ulong hash, char[] bytes) @local {
    foreach (byte : bytes) hash = (hash ^ byte) * LIGHT_HASH_PRIME;
    return hash;
}

// An atmosphere's sun colour follows its direction, so under one it is left to the angle test with the direction.
// Pre-exposure is divided out so an exposure change rescales the history instead of rejecting it.
fn FogLighting fog_lighting_of(LightGpu[] lights, uint sun_light, bool atmosphere, float pre_exposure) @private {
    FogLighting lighting = { .hash = LIGHT_HASH_BASIS };
    foreach (index, light : lights) {
        bool sun = index + 1 == sun_light;
        if (!sun && !(light.flags & shader::LIGHT_VOLUMETRIC)) continue;

        light.color_intensity.w /= pre_exposure;
        light.shadow_first = 0;
        light.shadow_count = light.shadow_count > 0 ? 1 : 0;
        if (sun) {
            lighting.to_sun = -light.direction_cos_outer.xyz;
            light.position_range = {};
            light.direction_cos_outer = {};
            if (atmosphere) light.color_intensity = {};
        }
        lighting.hash = fog_hash_bytes(lighting.hash, ((char*)&light)[:LightGpu::size]);
    }
    return lighting;
}

<*
 Packed index plus one of the light the volumetric fog scatters; zero for none.
 @param [&in] extraction
*>
fn uint fog_sun_light(LightExtraction* extraction, bool atmosphere) {
    if (atmosphere) return extraction.sun_light;
    foreach (index, light : extraction.lights) {
        if (light.kind == (uint)LightKind.DIRECTIONAL.ordinal) return (uint)index + 1;
    }
    return 0;
}

<*
 @require record.fog_volumes[0].texture.is_valid()
 @require !record.desc.fog_temporal || record.fog_volumes[1].texture.is_valid()
*>
fn void? record_fog_volume(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress frame,
    uint sun_light,
    bool atlas_shadows,
    FogFrame* current,
) @private {
    bool traced = record.desc.ray_tracing.shadows;
    bool temporal = record.desc.fog_temporal;
    gpu::PipelineHandle* scattering_pipeline = fog_scattering_pipeline(renderer, traced, temporal);
    acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   scattering_pipeline,
        shader:     FOG_SCATTERING,
        debug_name: "sky",
        flags:      rt_shadow_flags(renderer, traced) | (temporal ? shader::SHADER_FLAG_TEMPORAL : 0),
    )!;
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.fog_integration, FOG_INTEGRATION)!;
    if (atlas_shadows) {
        // The shadow pass leaves the atlas readable by fragments only.
        transition_shadow_atlas(
            atlas:    &renderer.shadow_atlas,
            commands: &renderer.commands,
            next:     gpu::sampled_at({ .compute, .fragment_shader }),
        )!;
    }
    FogHistory* history = &record.fog_history;
    Target* integrated = fog_integrated_volume(record);
    Target* scattering = temporal ? &record.fog_volumes[history.slot ^ 1] : integrated;
    bool reproject = temporal && history.accepts(current);
    Vec3 previous_camera = history.committed.camera_position;
    float pre_exposure_ratio = reproject ? current.pre_exposure / history.committed.pre_exposure : 1;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, FogVolumeRoot::size, STREAM_ALIGNMENT)!;
    *(FogVolumeRoot*)root.bytes.ptr = {
        .previous_view_proj       = bitcast(history.committed.view_proj, Mat4f),
        .previous_camera_position = { previous_camera.x, previous_camera.y, previous_camera.z, 0 },
        .frame                    = frame,
        .scattering               = scattering.view.index,
        .history                  = reproject ? integrated.view.index : (gpu::TextureIndex)0,
        .integrated               = integrated.view.index,
        .width                    = scattering.width,
        .height                   = scattering.height,
        .sun_light                = sun_light,
        .slices                   = scattering.depth,
        .flags                    = reproject ? shader::FOG_VOLUME_HISTORY : 0,
        .jitter                   = temporal ? maths::halton(history.sample + 1, 2) : 0,
        .pre_exposure_ratio       = pre_exposure_ratio,
    };
    if (temporal) history.record(current);

    @profile_pass(renderer, Pass.FOG_SCATTERING) {
        scattering.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        if (reproject) integrated.transition(&renderer.commands, renderer.sampled_state)!;
        uint columns = (scattering.width + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
        uint rows = (scattering.height + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
        gpu::cmd_bind_pipeline(&renderer.commands, *scattering_pipeline)!;
        uint slice_groups = temporal ? scattering.depth / shader::FOG_SCATTERING_CHUNK : scattering.depth;
        gpu::cmd_dispatch(&renderer.commands, root.address, { columns, rows, slice_groups })!;
    }!;
    @profile_pass(renderer, Pass.FOG_INTEGRATION) {
        scattering.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        if (temporal) integrated.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.fog_integration)!;
        dispatch_over(renderer, root.address, integrated)!;
        integrated.transition(&renderer.commands, renderer.sampled_state)!;
    }!;
    renderer.stats.post_dispatches += 2;
}
