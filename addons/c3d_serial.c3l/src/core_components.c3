module c3d::serial;

import c3d;
import c3d::camera;
import c3d::describe;
import c3d::light;
import c3d::scene;
import std::math;

const ulong SHADOW_LAYOUT @local = 0x79ccc384defd9804;
const ulong PROBE_UPDATE_LAYOUT @local = 0x92e32fe9bced397e;
const ulong DECAL_WEIGHTS_LAYOUT @local = 0x985beb1deac562f9;
const ulong CAMERA_LAYOUT @local = 0x5dd0d6ce96e600ac;
const ulong LIGHT_LAYOUT @local = 0xa41c0d2284b8d046;
const ulong PROBE_LAYOUT @local = 0xaed5ed822ebdf51a;
const ulong ATMOSPHERE_LAYOUT @local = 0x0a0ac3087385a43b;
const ulong FOG_LAYOUT @local = 0x1b730abab72fb88f;
const ulong REFLECTION_LAYOUT @local = 0x7654f53807d7357a;
const ulong DECAL_LAYOUT @local = 0xa4dd177052750847;

<*
 Register portable core components and their semantic defaults.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? register_core_codecs() {
    register_core_value_types()!;
    describe::register_core_components()!;
    register_core_value(ShadowSettings, SHADOW_LAYOUT, &defaults_shadow)!;
    register_core_value(ProbeUpdateDesc, PROBE_UPDATE_LAYOUT, &defaults_probe_update)!;
    register_core_value(DecalWeights, DECAL_WEIGHTS_LAYOUT, &defaults_decal_weights)!;
    register_core_value(Camera, CAMERA_LAYOUT, &defaults_camera)!;
    register_core_value(Light, LIGHT_LAYOUT, &defaults_light)!;
    register_core_value(ProbeVolume, PROBE_LAYOUT, &defaults_probe)!;
    register_core_value(Atmosphere, ATMOSPHERE_LAYOUT, &defaults_atmosphere)!;
    register_core_value(HeightFog, FOG_LAYOUT, &defaults_fog)!;
    register_core_value(ReflectionProbe, REFLECTION_LAYOUT, &defaults_reflection)!;
    register_core_value(Decal, DECAL_LAYOUT, &defaults_decal)!;
    register_described(Mesh, { .name = "c3d.Mesh", .attach = &attach_mesh })!;
    register_described(Camera, { .name = "c3d.Camera" })!;
    register_described(Light, { .name = "c3d.Light" })!;
    register_described(ProbeVolume, {
        .name = "c3d.ProbeVolume", .project = &project_probe, .validate = &validate_probe,
    })!;
    register_described(Atmosphere, {
        .name = "c3d.Atmosphere", .project = &project_atmosphere, .validate = &validate_atmosphere,
    })!;
    register_described(HeightFog, { .name = "c3d.HeightFog", .project = &project_fog, .validate = &validate_fog })!;
    register_described(ReflectionProbe, {
        .name = "c3d.ReflectionProbe", .project = &project_reflection, .validate = &validate_reflection,
    })!;
    register_described(Decal, { .name = "c3d.Decal" })!;
}

fn void defaults_shadow(void* value) @local {
    *(ShadowSettings*)value = light::SHADOW_SETTINGS_DEFAULT;
}

fn void defaults_probe_update(void* value) @local {
    *(ProbeUpdateDesc*)value = light::PROBE_UPDATE_DEFAULT;
}

fn void defaults_decal_weights(void* value) @local {
    *(DecalWeights*)value = { .base_color = 1, .normal = 1, .roughness = 1, .metallic = 1 };
}

fn void defaults_camera(void* value) @local {
    *(Camera*)value = camera::perspective_deg(60, 0.1f);
}

fn void defaults_light(void* value) @local {
    *(Light*)value = light::directional({ 1, 1, 1 }, 1);
}

fn void defaults_probe(void* value) @local {
    *(ProbeVolume*)value = light::probe_volume({ 1, 1, 1 }, { 2, 2, 2 });
}

fn void defaults_atmosphere(void* value) @local {
    *(Atmosphere*)value = light::ATMOSPHERE_EARTH;
}

fn void defaults_fog(void* value) @local {
    *(HeightFog*)value = light::HEIGHT_FOG_DEFAULT;
}

fn void defaults_reflection(void* value) @local {
    *(ReflectionProbe*)value = light::reflection_probe({ 1, 1, 1 }, {});
}

fn void defaults_decal(void* value) @local {
    *(Decal*)value = scene::default_decal_desc({}).decal;
}

fn void? attach_mesh(void* value, ReadContext* context) @local {
    Mesh mesh = *(Mesh*)value;
    float[]? weights = alloc::new_array_try(context.scene.allocator, float, (sz)mesh.morph_weights.len);
    if (catch weights) return c3d::CAPACITY_EXCEEDED~;
    weights[..] = mesh.morph_weights[..];
    mesh.morph_weights = weights;
    context.scene.add(context.node, mesh);
}

fn void? validate_probe(void* value, ReadContext* context) @local {
    if (!light::probe_volume_valid((ProbeVolume*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_probe(void* component, void* value, WriteContext* context) @local {
    if (!light::probe_volume_valid((ProbeVolume*)component)) return c3d::INVALID_ARGUMENT~;
    *(ProbeVolume*)value = *(ProbeVolume*)component;
}

fn void? validate_atmosphere(void* value, ReadContext* context) @local {
    if (!light::atmosphere_valid((Atmosphere*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_atmosphere(void* component, void* value, WriteContext* context) @local {
    if (!light::atmosphere_valid((Atmosphere*)component)) return c3d::INVALID_ARGUMENT~;
    *(Atmosphere*)value = *(Atmosphere*)component;
}

fn void? validate_fog(void* value, ReadContext* context) @local {
    if (!light::height_fog_valid((HeightFog*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_fog(void* component, void* value, WriteContext* context) @local {
    if (!light::height_fog_valid((HeightFog*)component)) return c3d::INVALID_ARGUMENT~;
    *(HeightFog*)value = *(HeightFog*)component;
}

fn void? validate_reflection(void* value, ReadContext* context) @local {
    if (!light::reflection_probe_valid((ReflectionProbe*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_reflection(void* component, void* value, WriteContext* context) @local {
    if (!light::reflection_probe_valid((ReflectionProbe*)component)) return c3d::INVALID_ARGUMENT~;
    *(ReflectionProbe*)value = *(ReflectionProbe*)component;
}
