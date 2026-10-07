module c3d::serial;

import c3d;
import c3d::describe;
import c3d::maths;
import c3d::scene;
import std::math;

const ulong TRANSFORM_LAYOUT @local = 0x7cf817e880017c9c;
const ulong AABB_LAYOUT @local = 0xf8d61510a7f38293;
const ulong SPHERE_LAYOUT @local = 0x9640fdd53be2f810;
const ulong SWAY_LAYOUT @local = 0x11af37ae59834a58;
const ulong FADE_LAYOUT @local = 0x679d213a5a3ae902;
const ulong IMPOSTOR_LAYOUT @local = 0x323ef7f725b2c310;
const ulong LOD_PART_LAYOUT @local = 0x5c34bf1e202331d1;
const ulong LOD_LEVEL_LAYOUT @local = 0x0f3cb1108b618099;
const ulong LOD_DESC_LAYOUT @local = 0xefefc2e5eb2ac7ff;
const ulong LOD_EFFECTS_LAYOUT @local = 0xf3d91f0510c4f53d;
const ulong BILLBOARD_LAYOUT @local = 0x2a7839a4c39e5ee2;
const ulong MESH_LAYOUT @local = 0x5e1d3cb5a05dfe89;

<*
 Register shared scene field layouts and semantic defaults.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION, c3d::INVALID_ARGUMENT
*>
fn void? register_core_value_types() {
    describe::register_core_values()!;
    register_core_value(Transform, TRANSFORM_LAYOUT, &defaults_transform)!;
    register_core_value(Aabb, AABB_LAYOUT, &defaults_aabb)!;
    register_core_value(Sphere, SPHERE_LAYOUT, &defaults_sphere)!;
    register_core_value(InstanceSway, SWAY_LAYOUT, &defaults_sway)!;
    register_core_value(InstanceFade, FADE_LAYOUT, &defaults_fade)!;
    register_core_value(Impostor, IMPOSTOR_LAYOUT, &defaults_impostor)!;
    register_core_value(LodPart, LOD_PART_LAYOUT, &defaults_lod_part)!;
    register_core_value(LodLevel, LOD_LEVEL_LAYOUT, &defaults_lod_level)!;
    register_core_value(LodDesc, LOD_DESC_LAYOUT, &defaults_lod_desc)!;
    register_core_value(LodEffects, LOD_EFFECTS_LAYOUT, &defaults_lod_effects)!;
    register_core_value(Billboard, BILLBOARD_LAYOUT, &defaults_billboard)!;
    register_core_value(Mesh, MESH_LAYOUT, &defaults_mesh)!;
}

macro void? register_core_value($Type, ulong layout, DefaultsFn defaults) @private {
    register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_transform(void* value) @local {
    *(Transform*)value = maths::TRANSFORM_IDENTITY;
}

fn void defaults_aabb(void* value) @local {
    *(Aabb*)value = {};
}

fn void defaults_sphere(void* value) @local {
    *(Sphere*)value = {};
}

fn void defaults_sway(void* value) @local {
    *(InstanceSway*)value = {};
}

fn void defaults_fade(void* value) @local {
    *(InstanceFade*)value = {};
}

fn void defaults_impostor(void* value) @local {
    *(Impostor*)value = {};
}

fn void defaults_lod_part(void* value) @local {
    *(LodPart*)value = { .local = matrix::IDENTITY4 };
}

fn void defaults_lod_level(void* value) @local {
    *(LodLevel*)value = {};
}

fn void defaults_lod_desc(void* value) @local {
    *(LodDesc*)value = {};
}

fn void defaults_lod_effects(void* value) @local {
    *(LodEffects*)value = { .cast_shadow = true, .receive_shadow = true, .trace = true };
}

fn void defaults_billboard(void* value) @local {
    *(Billboard*)value = scene::BILLBOARD_DEFAULT;
}

fn void defaults_mesh(void* value) @local {
    *(Mesh*)value = { .cast_shadow = true, .receive_shadow = true, .trace = true };
}
