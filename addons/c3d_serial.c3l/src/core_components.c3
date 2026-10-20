module c3d::serial;

import c3d;
import c3d::anim;
import c3d::camera;
import c3d::describe;
import c3d::light;
import c3d::scene;
import std::math;

const ulong SHADOW_LAYOUT @local = 0x79ccc384defd9804;
const ulong PROBE_UPDATE_LAYOUT @local = 0x92e32fe9bced397e;
const ulong DECAL_WEIGHTS_LAYOUT @local = 0x985beb1deac562f9;
const ulong CAMERA_LAYOUT @local = 0x5dd0d6ce96e600ac;
const ulong LIGHT_LAYOUT @local = 0x89bf800250a191bf;
const ulong LIGHT_V1_LAYOUT @local = 0xa41c0d2284b8d046;
const ulong LIGHT_V2_LAYOUT @local = 0x4fe02031be92ca17;
const ulong PROBE_LAYOUT @local = 0xaed5ed822ebdf51a;
const ulong ATMOSPHERE_LAYOUT @local = 0x0a0ac3087385a43b;
const ulong FOG_LAYOUT @local = 0x1b730abab72fb88f;
const ulong REFLECTION_LAYOUT @local = 0x7654f53807d7357a;
const ulong DECAL_LAYOUT @local = 0xa4dd177052750847;
const ulong CLOUD_LAYOUT @local = 0x5aed71b1b6ed4a13;
const ulong MEDIUM_LAYOUT @local = 0x0f39aa907b19ac0c;

struct LightV1 @private {
    LightKind kind;
    Vec3 color;
    float intensity;
    float range;
    float inner_cone;
    float outer_cone;
    uint layers;
    ShadowSettings shadow;
}

struct LightV2 @private {
    LightKind kind;
    Vec3 color;
    float intensity;
    float range;
    float inner_cone;
    float outer_cone;
    uint layers;
    bool volumetric;
    ShadowSettings shadow;
}

BinaryCompatibility[2] light_binary_compatibility @local = {
    { .version = 1, .read = &read_light_v1 },
    { .version = 2, .read = &read_light_v2 },
};
uint[2] light_text_default_versions @local = { 1, 2 };

BinaryCompatibility[2] mesh_binary_compatibility @local = {
    { .version = 1, .read = &read_mesh_v1, .upgrade = &upgrade_mesh_v1 },
    { .version = 2, .read = &read_mesh_v2, .upgrade = &upgrade_mesh_v2 },
};
uint[2] mesh_text_default_versions @local = { 1, 2 };

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
    describe::register_reflected(LightV1)!;
    register_core_value(LightV1, LIGHT_V1_LAYOUT, &defaults_light_v1)!;
    describe::register_reflected(LightV2)!;
    register_described_type(
        $Type: LightV2,
        version: 2,
        layout: LIGHT_V2_LAYOUT,
        defaults: &defaults_light_v2,
    )!;
    register_described_type(
        $Type: Light,
        version: 3,
        layout: LIGHT_LAYOUT,
        defaults: &defaults_light,
    )!;
    register_core_value(ProbeVolume, PROBE_LAYOUT, &defaults_probe)!;
    register_core_value(Atmosphere, ATMOSPHERE_LAYOUT, &defaults_atmosphere)!;
    register_core_value(HeightFog, FOG_LAYOUT, &defaults_fog)!;
    register_core_value(ReflectionProbe, REFLECTION_LAYOUT, &defaults_reflection)!;
    register_core_value(Decal, DECAL_LAYOUT, &defaults_decal)!;
    register_core_value(CloudLayer, CLOUD_LAYOUT, &defaults_cloud)!;
    register_core_value(MediumVolume, MEDIUM_LAYOUT, &defaults_medium)!;
    register_described(Mesh, {
        .name = "c3d.Mesh",
        .project = &project_mesh,
        .attach = &attach_mesh,
        .binary_compatibility = mesh_binary_compatibility[..],
        .text_default_versions = mesh_text_default_versions[..],
    })!;
    register_described(Camera, { .name = "c3d.Camera" })!;
    register_described(Light, {
        .name = "c3d.Light",
        .project = &project_light,
        .validate = &validate_light,
        .binary_compatibility = light_binary_compatibility[..],
        .text_default_versions = light_text_default_versions[..],
    })!;
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
    register_described(CloudLayer, {
        .name = "c3d.CloudLayer", .project = &project_cloud, .validate = &validate_cloud,
    })!;
    register_described(MediumVolume, {
        .name = "c3d.MediumVolume", .project = &project_medium, .validate = &validate_medium,
    })!;
    register_core_batch_codecs()!;
    register_model_codec()!;
    register_rig_codecs()!;
    register_animator_codec()!;
    register_crowd_codec()!;
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

fn void defaults_light_v1(void* value) @local {
    Light defaults;
    defaults_light(&defaults);
    *(LightV1*)value = {
        .kind = defaults.kind,
        .color = defaults.color,
        .intensity = defaults.intensity,
        .range = defaults.range,
        .inner_cone = defaults.inner_cone,
        .outer_cone = defaults.outer_cone,
        .layers = defaults.layers,
        .shadow = defaults.shadow,
    };
}

fn void defaults_light_v2(void* value) @local {
    Light defaults;
    defaults_light(&defaults);
    *(LightV2*)value = {
        .kind = defaults.kind,
        .color = defaults.color,
        .intensity = defaults.intensity,
        .range = defaults.range,
        .inner_cone = defaults.inner_cone,
        .outer_cone = defaults.outer_cone,
        .layers = defaults.layers,
        .volumetric = defaults.volumetric,
        .shadow = defaults.shadow,
    };
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

fn void defaults_cloud(void* value) @local {
    *(CloudLayer*)value = light::CLOUD_LAYER_DEFAULT;
}

fn void defaults_medium(void* value) @local {
    *(MediumVolume*)value = { .half_extent = { 1, 1 }, .depth = 1 };
}

fn void defaults_reflection(void* value) @local {
    *(ReflectionProbe*)value = light::reflection_probe({ 1, 1, 1 }, {});
}

fn void defaults_decal(void* value) @local {
    *(Decal*)value = scene::default_decal_desc({}).decal;
}

fn void? read_light_v1(Reader* reader, ReadContext* context) @local {
    LightV1 legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();
    read_described_value(
        type: described_type(LightV1)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;
    context.scene.add(context.node, (Light){
        .kind = legacy.kind,
        .color = legacy.color,
        .intensity = legacy.intensity,
        .range = legacy.range,
        .inner_cone = legacy.inner_cone,
        .outer_cone = legacy.outer_cone,
        .layers = legacy.layers,
        .volumetric = true,
        .shadow = legacy.shadow,
    });
}

fn void? read_light_v2(Reader* reader, ReadContext* context) @local {
    LightV2 legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();
    read_described_value(
        type: described_type(LightV2)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;

    context.scene.add(context.node, (Light){
        .kind = legacy.kind,
        .color = legacy.color,
        .intensity = legacy.intensity,
        .range = legacy.range,
        .inner_cone = legacy.inner_cone,
        .outer_cone = legacy.outer_cone,
        .layers = legacy.layers,
        .volumetric = legacy.volumetric,
        .shadow = legacy.shadow,
    });
}

fn void? attach_mesh(void* value, ReadContext* context) @local {
    Mesh mesh = *(Mesh*)value;
    float[]? weights = alloc::new_array_try(context.scene.allocator, float, (sz)mesh.morph_weights.len);
    if (catch weights) return c3d::CAPACITY_EXCEEDED~;
    weights[..] = mesh.morph_weights[..];
    mesh.morph_weights = weights;
    context.scene.add(context.node, mesh);
}

fn void? upgrade_mesh_v1(Reader* reader, ReadContext* context, void* value) @local {
    MeshV1* legacy = context.read_value(MeshV1, reader)!;
    *(Mesh*)value = {
        .geometry = legacy.geometry,
        .material = legacy.material,
        .cast_shadow = legacy.cast_shadow,
        .receive_shadow = legacy.receive_shadow,
        .trace = legacy.trace,
        .morph_weights = legacy.morph_weights,
        .has_bounds_override = legacy.has_bounds_override,
        .local_bounds = legacy.local_bounds,
        .vertex_motion = legacy.vertex_motion,
    };
}

fn void? read_mesh_v1(Reader* reader, ReadContext* context) @local {
    Mesh mesh;
    upgrade_mesh_v1(reader, context, &mesh)!;
    attach_mesh(&mesh, context)!;
}

fn void? upgrade_mesh_v2(Reader* reader, ReadContext* context, void* value) @local {
    MeshV2* legacy = context.read_value(MeshV2, reader)!;
    *(Mesh*)value = {
        .geometry = legacy.geometry,
        .material = legacy.material,
        .cast_shadow = legacy.cast_shadow,
        .receive_shadow = legacy.receive_shadow,
        .trace = legacy.trace,
        .trace_only = legacy.trace_only,
        .morph_weights = legacy.morph_weights,
        .has_bounds_override = legacy.has_bounds_override,
        .local_bounds = legacy.local_bounds,
        .vertex_motion = legacy.vertex_motion,
    };
}

fn void? read_mesh_v2(Reader* reader, ReadContext* context) @local {
    Mesh mesh;
    upgrade_mesh_v2(reader, context, &mesh)!;
    attach_mesh(&mesh, context)!;
}

fn void? project_mesh(void* component, void* value, WriteContext* context) @local {
    Mesh mesh = *(Mesh*)component;
    ExportNodeOwners* owners = &context.state.projection[context.node.id.index].owners;
    if (owners.model.generation && owners.baseline_slot != INDEX_NONE) {
        Node* root = context.scene.node(owners.model);
        if (context.scene.has(root, anim::Animator)) {
            ModelInstance* instance = context.scene.get(root, ModelInstance);
            mesh.morph_weights = instance.base_morph_weights[owners.baseline_slot];
        }
    }
    *(Mesh*)value = mesh;
}

fn void? validate_light(void* value, ReadContext* context) @local {
    if (!light::light_source_valid((Light*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_light(void* component, void* value, WriteContext* context) @local {
    if (!light::light_source_valid((Light*)component)) return c3d::INVALID_ARGUMENT~;
    *(Light*)value = *(Light*)component;
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

fn void? validate_cloud(void* value, ReadContext* context) @local {
    if (!light::cloud_layer_valid((CloudLayer*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_cloud(void* component, void* value, WriteContext* context) @local {
    if (!light::cloud_layer_valid((CloudLayer*)component)) return c3d::INVALID_ARGUMENT~;
    *(CloudLayer*)value = *(CloudLayer*)component;
}

fn void? validate_medium(void* value, ReadContext* context) @local {
    if (!light::medium_volume_valid((MediumVolume*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_medium(void* component, void* value, WriteContext* context) @local {
    if (!light::medium_volume_valid((MediumVolume*)component)) return c3d::INVALID_ARGUMENT~;
    *(MediumVolume*)value = *(MediumVolume*)component;
}

fn void? validate_reflection(void* value, ReadContext* context) @local {
    if (!light::reflection_probe_valid((ReflectionProbe*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_reflection(void* component, void* value, WriteContext* context) @local {
    if (!light::reflection_probe_valid((ReflectionProbe*)component)) return c3d::INVALID_ARGUMENT~;
    *(ReflectionProbe*)value = *(ReflectionProbe*)component;
}
