module c3d::render;

import c3d;
import c3d::light;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert SkyFogGpu::size == 176;
$assert SkyTableRoot::size == 32;

<*
 Atmospheres of rendered scenes whose tables and lighting the renderer keeps at once.
*>
const uint ATMOSPHERE_CAPACITY = 4; // one per scene rendered in a frame; each holds about 0.6 MiB and 46 heap slots

<*
 Face size of an atmosphere's source and specular cubes.
*>
const uint SKY_ENVIRONMENT_SIZE = 64; // 192 KiB and 256 KiB; a regeneration marches 24,576 texels and prefilters 32,760

<*
 Sun motion that regenerates an atmosphere's lighting.
*>
const float SKY_REGENERATION_SUN_ANGLE = 0.0087266463f; // 0.5°; tuned by eye for popping at sky.c3's fastest time-lapse

<*
 Observer altitude change that regenerates an atmosphere's lighting.
*>
const float SKY_REGENERATION_ALTITUDE = 500; // metres; below it the sky seen from the observer barely changes

<*
 Distance the aerial perspective volume covers.
*>
const float AERIAL_PERSPECTIVE_DISTANCE = 128_000; // metres; 4 km a slice, squared toward the camera: the first at 31 m

const ulong ATMOSPHERE_ABSENCE_FRAMES @local = FRAMES_IN_FLIGHT + 1; // longer holds an idle mirror longer

<*
 The scene's atmosphere and the directional light that is its sun.
*>
struct AtmosphereSelection {
    Entity      entity;  // zero generation: the scene has none
    Atmosphere* atmosphere;
    Light*      sun;
    Node*       node;
    uint        ignored; // extras, invalid ones and ones without a directional Light
}

<*
 The height fog one view draws.
*>
struct FogSelection {
    Entity     entity;      // zero generation: the view has none
    HeightFog* fog;
    float      base_height; // world y of its node
    uint       ignored;     // extras and invalid ones visible to the view
}

<*
 Sun and air an atmosphere's lighting cubes were generated for.
*>
struct SkyRegeneration {
    Atmosphere atmosphere;
    Vec3       to_sun;
    Vec3       sun_color;
    bool       valid;
}

<*
 Renderer-owned tables and lighting of one Atmosphere component of one scene.
*>
struct AtmosphereRes {
    ulong              scene;
    Entity             entity;           // a zero generation marks a free slot
    ulong              last_frame;       // last frame the scene was rendered with the component selected
    gpu::TextureHandle transmittance;
    gpu::TextureView   transmittance_view;
    gpu::TextureHandle multi_scattering;
    gpu::TextureView   multi_scattering_view;
    EnvironmentRes     lighting;         // cubes at SKY_ENVIRONMENT_SIZE; lighting_revision advances per regeneration
    SkyRegeneration    generated;        // what the submitted tables and cubes hold
    SkyRegeneration    pending;          // what this frame's recorded work makes them hold
    bool               tables_pending;
    bool               lighting_pending;
    bool               sheen_pending;
    bool               recorded;
    bool               written;          // the tables and cubes hold a submitted result
    bool               sheen_written;    // the Charlie cube holds a submitted result
}

struct SkyFogTables @private {
    gpu::TextureIndex transmittance;
    gpu::TextureIndex multi_scattering;
    gpu::TextureIndex sky_view;
    gpu::TextureIndex aerial_perspective;
    gpu::SamplerIndex sampler;
}

struct SkyPipelines @private {
    gpu::PipelineHandle transmittance;
    gpu::PipelineHandle multi_scattering;
    gpu::PipelineHandle sky_view;
    gpu::PipelineHandle aerial_perspective;
    gpu::PipelineHandle environment;
    gpu::PipelineHandle fog;
}

<*
 The first valid atmosphere in store order whose node carries a directional Light.
 @param [&in] scene : "Current world transforms."
*>
fn AtmosphereSelection select_atmosphere(Scene* scene) {
    AtmosphereSelection selection;
    scene.@each(Atmosphere; Entity entity, Atmosphere* atmosphere) {
        Light* sun = scene.world.get(entity, Light);
        bool usable = sun && sun.kind == LightKind.DIRECTIONAL && light::atmosphere_valid(atmosphere);
        if (usable && !selection.atmosphere) {
            selection.entity = entity;
            selection.atmosphere = atmosphere;
            selection.sun = sun;
            selection.node = scene.node(entity);
        } else {
            selection.ignored++;
        }
    };
    return selection;
}

<*
 The first valid height fog in store order whose node the view's layers see.
 @param [&in] scene : "Current world transforms."
 @param view_layers : "Camera visibility mask."
*>
fn FogSelection select_height_fog(Scene* scene, uint view_layers) {
    FogSelection selection;
    scene.@each(HeightFog; Entity entity, HeightFog* fog) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (node.layers & view_layers)) {
            if (light::height_fog_valid(fog) && !selection.fog) {
                selection.entity = entity;
                selection.fog = fog;
                selection.base_height = node.world_position().y;
            } else {
                selection.ignored++;
            }
        }
    };
    return selection;
}

fn Vec3 sun_direction(Node* node) @private {
    return -maths::transform_dir(node.world, { 0, 0, -1 }).normalize();
}

fn bool sky_regeneration_due(
    SkyRegeneration* generated,
    Atmosphere* atmosphere,
    Vec3 to_sun,
    Vec3 sun_color,
) @private {
    if (!generated.valid || !same_air(&generated.atmosphere, atmosphere)) return true;
    if (sun_color != generated.sun_color) return true;
    float altitude_change = math::abs(atmosphere.observer_altitude - generated.atmosphere.observer_altitude);
    if (altitude_change > SKY_REGENERATION_ALTITUDE) return true;
    float angle = math::atan2(to_sun.cross(generated.to_sun).length(), to_sun.dot(generated.to_sun));
    return angle > SKY_REGENERATION_SUN_ANGLE;
}

<*
 @pure
*>
fn bool same_air(Atmosphere* first, Atmosphere* second) @local {
    return first.planet_radius == second.planet_radius
        && first.atmosphere_height == second.atmosphere_height
        && first.rayleigh_scattering == second.rayleigh_scattering
        && first.rayleigh_scale_height == second.rayleigh_scale_height
        && first.mie_scattering == second.mie_scattering
        && first.mie_absorption == second.mie_absorption
        && first.mie_scale_height == second.mie_scale_height
        && first.mie_anisotropy == second.mie_anisotropy
        && first.ozone_absorption == second.ozone_absorption
        && first.ozone_center_altitude == second.ozone_center_altitude
        && first.ozone_half_width == second.ozone_half_width
        && first.ground_albedo == second.ground_albedo
        && first.sun_angular_radius == second.sun_angular_radius;
}

fn void write_sky_fog(
    SkyFogGpu* root,
    Atmosphere* atmosphere,
    Vec3 to_sun,
    Vec3 sun_illuminance,
    float altitude,
    FogSelection* fog,
    SkyFogTables tables,
) @private {
    *root = {
        .transmittance_lut      = tables.transmittance,
        .multi_scattering_lut   = tables.multi_scattering,
        .sky_view_lut           = tables.sky_view,
        .aerial_perspective_lut = tables.aerial_perspective,
        .lut_sampler            = tables.sampler,
    };
    if (atmosphere) {
        float top = atmosphere.planet_radius + atmosphere.atmosphere_height;
        root.flags |= shader::SKY_FOG_ATMOSPHERE;
        root.sun_direction_cos_radius = { to_sun.x, to_sun.y, to_sun.z, math::cos(atmosphere.sun_angular_radius) };
        root.sun_illuminance = { sun_illuminance.x, sun_illuminance.y, sun_illuminance.z, 0 };
        root.rayleigh_scattering_height = {
            atmosphere.rayleigh_scattering.x,
            atmosphere.rayleigh_scattering.y,
            atmosphere.rayleigh_scattering.z,
            atmosphere.rayleigh_scale_height,
        };
        root.mie = {
            atmosphere.mie_scattering,
            atmosphere.mie_absorption,
            atmosphere.mie_scale_height,
            atmosphere.mie_anisotropy,
        };
        root.ozone_absorption_center = {
            atmosphere.ozone_absorption.x,
            atmosphere.ozone_absorption.y,
            atmosphere.ozone_absorption.z,
            atmosphere.ozone_center_altitude,
        };
        root.ground_albedo_ozone_width = {
            atmosphere.ground_albedo.x,
            atmosphere.ground_albedo.y,
            atmosphere.ground_albedo.z,
            atmosphere.ozone_half_width,
        };
        root.planet_radius = atmosphere.planet_radius;
        root.top_radius = top;
        root.camera_altitude = math::clamp(altitude, 0.0f, atmosphere.atmosphere_height);
        root.aerial_perspective_distance = AERIAL_PERSPECTIVE_DISTANCE;
    }
    if (fog.fog) {
        HeightFog* medium = fog.fog;
        root.flags |= shader::SKY_FOG_HEIGHT_FOG;
        root.fog_albedo_density = { medium.albedo.x, medium.albedo.y, medium.albedo.z, medium.density };
        root.fog_base_height = fog.base_height;
        root.fog_falloff = medium.falloff;
        root.fog_max_distance = medium.max_distance;
    }
}

fn void? acquire_sky_pipeline(Renderer* renderer, gpu::PipelineHandle* pipeline, ShaderName shader) @private {
    return acquire_compute_pipeline(renderer, pipeline, shader, "sky");
}

fn gpu::PipelineHandle? sky_atmosphere_pipeline(Renderer* renderer) @private {
    PipelineKey key = {
        .vertex        = { .shader = FULLSCREEN },
        .fragment      = { .shader = SKY_ATMOSPHERE },
        .color_formats = { [0] = HDR_FORMAT },
        .color_count   = 1,
        .depth_format  = DEPTH_FORMAT,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    return renderer.pipelines.get(&renderer.device, key);
}

fn AtmosphereRes* find_atmosphere(Renderer* renderer, ulong scene, Entity entity) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (mirror.scene == scene && c3d::same_id(mirror.entity, entity)) return mirror;
    }
    return null;
}

fn usz? choose_atmosphere_slot(AtmosphereRes[] mirrors, ulong scene, ulong frame_index) @private {
    foreach (usz index, &mirror : mirrors) {
        if (mirror.entity.generation == 0) return index;
    }
    usz chosen = mirrors.len;
    foreach (usz index, &mirror : mirrors) {
        if (mirror.scene == scene || frame_index - mirror.last_frame <= ATMOSPHERE_ABSENCE_FRAMES) continue;
        if (chosen == mirrors.len || mirror.last_frame < mirrors[chosen].last_frame) chosen = index;
    }
    if (chosen == mirrors.len) return NO_ATMOSPHERE_SLOT~;
    return chosen;
}

fn void sweep_atmospheres(Renderer* renderer, Scene* scene, Entity selected) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (mirror.entity.generation == 0 || mirror.scene != scene.identity) continue;
        if (c3d::same_id(mirror.entity, selected)) continue;
        retire_atmosphere(&renderer.pending_upload_retire, mirror);
        *mirror = {};
    }
}

fn AtmosphereRes*? resolve_atmosphere(
    Renderer* renderer,
    Scene* scene,
    AtmosphereSelection* selection,
    bool sheen,
) @private {
    renderer.stats.atmospheres_ignored += selection.ignored;
    sweep_atmospheres(renderer, scene, selection.entity);
    if (!selection.atmosphere) return null;

    AtmosphereRes* mirror = find_atmosphere(renderer, scene.identity, selection.entity);
    if (!mirror) {
        usz? slot = choose_atmosphere_slot(&renderer.atmospheres, scene.identity, renderer.frame_index);
        if (catch slot) {
            renderer.stats.atmospheres_dropped++;
            return null;
        }
        mirror = &renderer.atmospheres[slot];
        if (mirror.entity.generation) retire_atmosphere(&renderer.pending_upload_retire, mirror);
        *mirror = { .scene = scene.identity, .entity = selection.entity };
        defer catch {
            release_atmosphere(&renderer.device, mirror);
            *mirror = {};
        }
        create_atmosphere(renderer, mirror)!;
    }
    mirror.last_frame = renderer.frame_index;

    Vec3 to_sun = sun_direction(selection.node);
    Vec3 sun_color = selection.sun.color;
    bool due = sky_regeneration_due(
        generated:  &mirror.generated,
        atmosphere: selection.atmosphere,
        to_sun:     to_sun,
        sun_color:  sun_color,
    );
    if (!mirror.lighting_pending && due) {
        SkyRegeneration* generated = &mirror.generated;
        mirror.tables_pending = !generated.valid || !same_air(&generated.atmosphere, selection.atmosphere);
        mirror.lighting_pending = true;
        mirror.sheen_pending = mirror.lighting.sheen_cube.is_valid();
        mirror.pending = {
            .atmosphere = *selection.atmosphere,
            .to_sun     = to_sun,
            .sun_color  = sun_color,
            .valid      = true,
        };
        mirror.lighting.lighting_revision = ++renderer.environment_state.lighting_serial;
        renderer.stats.sky_regenerations++;
    }
    if (sheen && !mirror.lighting.sheen_cube.is_valid()) {
        mirror.lighting.sheen_size = SKY_ENVIRONMENT_SIZE;
        create_environment_sheen(renderer, &mirror.lighting)!;
        mirror.sheen_written = false;
        acquire_sheen_lut(renderer)!;
        mirror.sheen_pending = true;
    }
    acquire_environment_lut(renderer)!;
    acquire_environment_samplers(renderer)!;
    mirror.lighting.lighting_ready = true;
    mirror.lighting.sheen_ready = mirror.lighting.sheen_cube.is_valid();
    return mirror;
}

fn void? create_atmosphere(Renderer* renderer, AtmosphereRes* mirror) @private {
    mirror.transmittance = create_sky_table(
        renderer: renderer,
        width:    shader::SKY_TRANSMITTANCE_WIDTH,
        height:   shader::SKY_TRANSMITTANCE_HEIGHT,
        view:     &mirror.transmittance_view,
        debug_name: "sky_transmittance",
    )!;
    mirror.multi_scattering = create_sky_table(
        renderer: renderer,
        width:    shader::SKY_MULTI_SCATTERING_SIZE,
        height:   shader::SKY_MULTI_SCATTERING_SIZE,
        view:     &mirror.multi_scattering_view,
        debug_name: "sky_multi_scattering",
    )!;
    EnvironmentRes* lighting = &mirror.lighting;
    lighting.source_owned = true;
    lighting.source_size = SKY_ENVIRONMENT_SIZE;
    lighting.specular_size = SKY_ENVIRONMENT_SIZE;
    lighting.source_ready = true;
    create_environment_cube(renderer, lighting, false)!;
    create_environment_cube(renderer, lighting, true)!;
    lighting.irradiance = allocate_environment_buffer(renderer, IrradianceGpu::size, "sky_irradiance")!;
    lighting.irradiance_address = environment_buffer_address(renderer, lighting.irradiance)!;
    lighting.irradiance_partials = allocate_environment_buffer(
        renderer,
        IrradianceGpu::size * shader::ENVIRONMENT_SH_GROUPS,
        "sky_irradiance_partials",
    )!;
    lighting.partials_address = environment_buffer_address(renderer, lighting.irradiance_partials)!;
}

fn gpu::TextureHandle? create_sky_table(
    Renderer* renderer,
    uint width,
    uint height,
    gpu::TextureView* view,
    ZString debug_name,
) @private {
    gpu::TextureDesc description = {
        .width      = width,
        .height     = height,
        .mip_levels = 1,
        .array_layers = 1,
        .format     = gpu::Format.RGBA16_FLOAT,
        .usage      = { .sampled, .storage },
        .access     = { .graphics },
        .debug_name = debug_name,
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    *view = gpu::create_texture_view(&renderer.device, texture, null)!;
    return texture;
}

fn void release_atmosphere(gpu::Device* device, AtmosphereRes* mirror) @private {
    if (mirror.transmittance_view.is_valid()) (void)gpu::destroy_texture_view(device, mirror.transmittance_view);
    if (mirror.transmittance.is_valid()) (void)gpu::destroy_texture(device, mirror.transmittance);
    if (mirror.multi_scattering_view.is_valid()) (void)gpu::destroy_texture_view(device, mirror.multi_scattering_view);
    if (mirror.multi_scattering.is_valid()) (void)gpu::destroy_texture(device, mirror.multi_scattering);
    release_environment_source(device, &mirror.lighting);
    release_environment_lighting(device, &mirror.lighting);
    release_environment_sheen(device, &mirror.lighting);
}

fn void retire_atmosphere(RetireList* retire, AtmosphereRes* mirror) @private {
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = mirror.transmittance_view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = mirror.transmittance });
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = mirror.multi_scattering_view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = mirror.multi_scattering });
    retire_environment_source(retire, &mirror.lighting);
    retire_environment_lighting(retire, &mirror.lighting);
    retire_environment_sheen(retire, &mirror.lighting);
}

fn bool atmosphere_work_unrecorded(Renderer* renderer) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (mirror.entity.generation && (mirror.tables_pending || mirror.lighting_pending || mirror.sheen_pending)
            && !mirror.recorded) {
            return true;
        }
    }
    return false;
}

fn bool has_atmosphere_preparations(Renderer* renderer) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (mirror.tables_pending || mirror.lighting_pending || mirror.sheen_pending) return true;
    }
    return false;
}

fn void? record_atmosphere_preparations(Renderer* renderer, gpu::CommandList* commands) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (mirror.entity.generation == 0 || mirror.recorded) continue;
        if (!mirror.tables_pending && !mirror.lighting_pending && !mirror.sheen_pending) continue;
        gpu::GpuAddress sky_fog = upload_atmosphere_block(renderer, commands, mirror)!;
        if (mirror.tables_pending) {
            @profile_stage(renderer, EnvironmentStage.SKY_TRANSMITTANCE) {
                record_sky_table(
                    renderer:  renderer,
                    commands:  commands,
                    pipeline:  SKY_TRANSMITTANCE,
                    handle:    &renderer.sky_pipelines.transmittance,
                    texture:   mirror.transmittance,
                    view:      mirror.transmittance_view,
                    width:     shader::SKY_TRANSMITTANCE_WIDTH,
                    height:    shader::SKY_TRANSMITTANCE_HEIGHT,
                    sky_fog:   sky_fog,
                    previous:  mirror.written ? renderer.sampled_state : (gpu::TextureState){},
                )!;
            }!;
            @profile_stage(renderer, EnvironmentStage.SKY_MULTI_SCATTERING) {
                record_sky_table(
                    renderer:  renderer,
                    commands:  commands,
                    pipeline:  SKY_MULTI_SCATTERING,
                    handle:    &renderer.sky_pipelines.multi_scattering,
                    texture:   mirror.multi_scattering,
                    view:      mirror.multi_scattering_view,
                    width:     shader::SKY_MULTI_SCATTERING_SIZE,
                    height:    shader::SKY_MULTI_SCATTERING_SIZE,
                    sky_fog:   sky_fog,
                    previous:  mirror.written ? renderer.sampled_state : (gpu::TextureState){},
                )!;
            }!;
        }
        gpu::TextureState previous = mirror.written ? renderer.sampled_state : (gpu::TextureState){};
        if (mirror.lighting_pending) {
            @profile_stage(renderer, EnvironmentStage.SKY) {
                record_sky_environment(
                    renderer: renderer,
                    commands: commands,
                    mirror:   mirror,
                    sky_fog:  sky_fog,
                    previous: previous,
                )!;
            }!;
            @profile_stage(renderer, EnvironmentStage.PREFILTER) {
                record_environment_prefilter(
                    renderer: renderer,
                    commands: commands,
                    result:   &mirror.lighting,
                    previous: previous,
                )!;
            }!;
            @profile_stage(renderer, EnvironmentStage.IRRADIANCE) {
                record_environment_irradiance(renderer, commands, &mirror.lighting)!;
            }!;
        }
        if (mirror.sheen_pending) {
            @profile_stage(renderer, EnvironmentStage.SHEEN) {
                record_environment_sheen(
                    renderer: renderer,
                    commands: commands,
                    result:   &mirror.lighting,
                    previous: mirror.sheen_written ? renderer.sampled_state : (gpu::TextureState){},
                )!;
            }!;
        }
        mirror.recorded = true;
    }
}

fn gpu::GpuAddress? upload_atmosphere_block(
    Renderer* renderer,
    gpu::CommandList* commands,
    AtmosphereRes* mirror,
) @private {
    SkyRegeneration* target = mirror.lighting_pending ? &mirror.pending : &mirror.generated;
    Frame* slot = recording_frame(renderer, commands);
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, SkyFogGpu::size, STREAM_ALIGNMENT)!;
    FogSelection no_fog;
    write_sky_fog(
        root:            (SkyFogGpu*)span.bytes.ptr,
        atmosphere:      &target.atmosphere,
        to_sun:          target.to_sun,
        sun_illuminance: target.sun_color,
        altitude:        target.atmosphere.observer_altitude,
        fog:             &no_fog,
        tables:          {
            .transmittance    = mirror.transmittance_view.index,
            .multi_scattering = mirror.multi_scattering_view.index,
            .sampler          = renderer.linear_clamp_sampler,
        },
    );
    return span.address;
}

fn void? record_sky_table(
    Renderer* renderer,
    gpu::CommandList* commands,
    ShaderName pipeline,
    gpu::PipelineHandle* handle,
    gpu::TextureHandle texture,
    gpu::TextureView view,
    uint width,
    uint height,
    gpu::GpuAddress sky_fog,
    gpu::TextureState previous,
) @private {
    acquire_sky_pipeline(renderer, handle, pipeline)!;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: texture,
        before:  previous,
        after:   gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, SkyTableRoot::size, STREAM_ALIGNMENT)!;
    *(SkyTableRoot*)root.bytes.ptr = {
        .sky_fog        = sky_fog,
        .output_texture = view.index,
        .width          = width,
        .height         = height,
    };
    gpu::cmd_bind_pipeline(commands, *handle)!;
    gpu::cmd_dispatch(commands, root.address, {
        (width + shader::SKY_TABLE_GROUP_SIZE - 1) / shader::SKY_TABLE_GROUP_SIZE,
        (height + shader::SKY_TABLE_GROUP_SIZE - 1) / shader::SKY_TABLE_GROUP_SIZE,
        1,
    })!;
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: texture,
        before:  write.after,
        after:   renderer.sampled_state,
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
}

fn void? record_sky_environment(
    Renderer* renderer,
    gpu::CommandList* commands,
    AtmosphereRes* mirror,
    gpu::GpuAddress sky_fog,
    gpu::TextureState previous,
) @private {
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.environment, SKY_ENVIRONMENT)!;
    EnvironmentRes* lighting = &mirror.lighting;
    Frame* slot = recording_frame(renderer, commands);
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: lighting.source_cube,
        before:  previous,
        after:   gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(commands, &write)!;
    gpu::cmd_bind_pipeline(commands, renderer.sky_pipelines.environment)!;
    uint groups = (lighting.source_size + shader::SKY_TABLE_GROUP_SIZE - 1) / shader::SKY_TABLE_GROUP_SIZE;
    for (uint face = 0; face < shader::ENVIRONMENT_FACE_COUNT; face++) {
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, SkyTableRoot::size, STREAM_ALIGNMENT)!;
        *(SkyTableRoot*)root.bytes.ptr = {
            .sky_fog        = sky_fog,
            .output_texture = lighting.source_faces[face].index,
            .width          = lighting.source_size,
            .height         = lighting.source_size,
            .face           = face,
        };
        gpu::cmd_dispatch(commands, root.address, { groups, groups, 1 })!;
    }
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: lighting.source_cube,
        before:  write.after,
        after:   renderer.sampled_state,
    )!;
    gpu::cmd_texture_barrier(commands, &ready)!;
}

fn void commit_atmosphere_preparations(Renderer* renderer) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (!mirror.recorded) continue;
        if (mirror.lighting_pending) mirror.generated = mirror.pending;
        mirror.written = true;
        mirror.sheen_written |= mirror.sheen_pending;
        mirror.tables_pending = false;
        mirror.lighting_pending = false;
        mirror.sheen_pending = false;
        mirror.recorded = false;
    }
}

fn void discard_atmosphere_preparations(Renderer* renderer) @private {
    foreach (&mirror : renderer.atmospheres) {
        mirror.tables_pending = false;
        mirror.lighting_pending = false;
        mirror.sheen_pending = false;
        mirror.recorded = false;
    }
}

fn void free_atmospheres(Renderer* renderer) @private {
    foreach (&mirror : renderer.atmospheres) {
        if (mirror.entity.generation) release_atmosphere(&renderer.device, mirror);
        *mirror = {};
    }
    gpu::PipelineHandle[6] pipelines = {
        renderer.sky_pipelines.transmittance, renderer.sky_pipelines.multi_scattering,
        renderer.sky_pipelines.sky_view, renderer.sky_pipelines.aerial_perspective,
        renderer.sky_pipelines.environment, renderer.sky_pipelines.fog,
    };
    foreach (pipeline : pipelines) if (pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, pipeline);
    renderer.sky_pipelines = {};
}

fn void? acquire_sky_view_images(Renderer* renderer, ViewRecord* record) @private {
    if (record.desc.shading == ShadingPath.PATH_TRACED || record.sky_view.texture.is_valid()) return;
    if (!record.hdr_color.texture.is_valid()) return;
    defer catch release_sky_view_images(&renderer.device, record);
    record.sky_view = allocate_storage_target(
        device:     &renderer.device,
        width:      shader::SKY_VIEW_WIDTH,
        height:     shader::SKY_VIEW_HEIGHT,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "sky_view",
    )!;
    record.aerial_perspective = allocate_storage_target(
        device:     &renderer.device,
        width:      shader::AERIAL_PERSPECTIVE_SIZE,
        height:     shader::AERIAL_PERSPECTIVE_SIZE,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "aerial_perspective",
        depth:      shader::AERIAL_PERSPECTIVE_SIZE,
    )!;
}

fn void retire_sky_view_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.sky_view.texture.is_valid()) return;
    RetireList* retire = last_submitted_retire(renderer);
    retire_storage_target(retire, &record.sky_view);
    retire_storage_target(retire, &record.aerial_perspective);
}

fn void release_sky_view_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.sky_view.texture.is_valid()) release_storage_target(device, &record.sky_view);
    if (record.aerial_perspective.texture.is_valid()) release_storage_target(device, &record.aerial_perspective);
}

<*
 @require !atmosphere || record.sky_view.texture.is_valid()
*>
fn gpu::GpuAddress? pack_view_sky_fog(
    Renderer* renderer,
    ViewRecord* record,
    AtmosphereRes* atmosphere,
    AtmosphereSelection* selection,
    FogSelection* fog,
    Vec3 camera_position,
) @private {
    if (!atmosphere && !fog.fog) return (gpu::GpuAddress)0;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, SkyFogGpu::size, STREAM_ALIGNMENT)!;
    SkyFogTables tables = { .sampler = renderer.linear_clamp_sampler };
    Vec3 to_sun;
    Vec3 illuminance;
    if (atmosphere) {
        tables.transmittance = atmosphere.transmittance_view.index;
        tables.multi_scattering = atmosphere.multi_scattering_view.index;
        tables.sky_view = record.sky_view.view.index;
        tables.aerial_perspective = record.aerial_perspective.view.index;
        to_sun = sun_direction(selection.node);
        illuminance = selection.sun.color * selection.sun.intensity;
    }
    write_sky_fog(
        root:            (SkyFogGpu*)span.bytes.ptr,
        atmosphere:      atmosphere ? selection.atmosphere : null,
        to_sun:          to_sun,
        sun_illuminance: illuminance,
        altitude:        camera_position.y,
        fog:             fog,
        tables:          tables,
    );
    return span.address;
}

<*
 @require record.sky_view.texture.is_valid()
*>
fn void? record_sky_view_tables(
    Renderer* renderer,
    ViewRecord* record,
    gpu::GpuAddress sky_fog,
    gpu::GpuAddress frame,
) @private {
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.sky_view, SKY_VIEW)!;
    acquire_sky_pipeline(renderer, &renderer.sky_pipelines.aerial_perspective, AERIAL_PERSPECTIVE)!;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];

    @profile_pass(renderer, Pass.SKY_VIEW) {
        record.sky_view.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, SkyTableRoot::size, STREAM_ALIGNMENT)!;
        *(SkyTableRoot*)root.bytes.ptr = {
            .sky_fog        = sky_fog,
            .frame          = frame,
            .output_texture = record.sky_view.view.index,
            .width          = record.sky_view.width,
            .height         = record.sky_view.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.sky_view)!;
        dispatch_over(renderer, root.address, &record.sky_view)!;
        record.sky_view.transition(&renderer.commands, renderer.sampled_state)!;
    }!;

    @profile_pass(renderer, Pass.AERIAL_PERSPECTIVE) {
        record.aerial_perspective.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, SkyTableRoot::size, STREAM_ALIGNMENT)!;
        *(SkyTableRoot*)root.bytes.ptr = {
            .sky_fog        = sky_fog,
            .frame          = frame,
            .output_texture = record.aerial_perspective.view.index,
            .width          = record.aerial_perspective.width,
            .height         = record.aerial_perspective.height,
        };
        uint groups = shader::AERIAL_PERSPECTIVE_SIZE / shader::SKY_TABLE_GROUP_SIZE;
        uint slices = shader::AERIAL_PERSPECTIVE_SIZE / shader::AERIAL_PERSPECTIVE_GROUP_DEPTH;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.sky_pipelines.aerial_perspective)!;
        gpu::cmd_dispatch(&renderer.commands, root.address, { groups, groups, slices })!;
        record.aerial_perspective.transition(&renderer.commands, renderer.sampled_state)!;
    }!;
}
