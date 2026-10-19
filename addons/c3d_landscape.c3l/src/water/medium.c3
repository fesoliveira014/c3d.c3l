module c3d::landscape::water;

import c3d;
import c3d::light;
import c3d::scene;
import std::math;

<*
 Henyey-Greenstein g of the sun term in a water body's medium.
*>
const float MEDIUM_ANISOTROPY = 0.6f; // forward-leaning, as suspended particles; 0.9 would show the sun only toward it

<*
 Largest single-scattering albedo a water body's scatter colour maps to.
*>
const float MAX_SCATTER_ALBEDO = 0.98f; // albedo 1 scatters without end per unit of absorption; 49 times at the clamp

// Clear water absorbs nothing, and scatters nothing because its scattering is a multiple of its absorption.
fn bool is_clear(WaterDesc* desc) @private {
    Vec3 color = desc.absorption_color;
    return color.x == 1 && color.y == 1 && color.z == 1;
}

fn MediumVolume water_medium(WaterDesc* desc, Vec2 rest_min, Vec2 rest_max) @private {
    Vec3 color = desc.absorption_color;
    Vec3 absorption = {
        -math::ln(color.x) / desc.absorption_distance,
        -math::ln(color.y) / desc.absorption_distance,
        -math::ln(color.z) / desc.absorption_distance,
    };
    Vec3 scatter = desc.scatter_color;
    Vec3 albedo = {
        min(scatter.x, MAX_SCATTER_ALBEDO),
        min(scatter.y, MAX_SCATTER_ALBEDO),
        min(scatter.z, MAX_SCATTER_ALBEDO),
    };
    Vec3 scattering = {
        absorption.x * albedo.x / (1 - albedo.x),
        absorption.y * albedo.y / (1 - albedo.y),
        absorption.z * albedo.z / (1 - albedo.z),
    };

    return {
        .absorption  = absorption,
        .scattering  = scattering,
        .anisotropy  = MEDIUM_ANISOTROPY,
        .center      = (rest_min + rest_max) * 0.5f,
        .half_extent = (rest_max - rest_min) * 0.5f,
        .depth       = desc.depth,
    };
}

// The node's medium follows the desc: written, updated in place, or removed when the water turns clear.
fn void write_medium(Scene* scene, Node* node, WaterDesc* desc, Vec2 rest_min, Vec2 rest_max) @private {
    if (is_clear(desc)) {
        if (scene.has(node, MediumVolume)) scene.remove_component(node, MediumVolume);
        return;
    }

    MediumVolume medium = water_medium(desc, rest_min, rest_max);
    MediumVolume* existing = scene.get(node, MediumVolume);
    if (existing) {
        *existing = medium;
        return;
    }
    scene.add(node, medium);
}
