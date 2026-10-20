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

<*
 Metres the medium's top lies under the deepest trough, so no drawn surface falls inside it.
*>
const float MEDIUM_SKIN = 0.02f; // clears a depth rebuild's float noise; costs that much of the water's absorption

// Clear water absorbs nothing, and scatters nothing because its scattering is a multiple of its absorption.
fn bool is_clear(WaterDesc* desc) @private {
    Vec3 color = desc.absorption_color;
    return color.x == 1 && color.y == 1 && color.z == 1;
}

fn MediumVolume water_medium(WaterDesc* desc, Vec2 rest_min, Vec2 rest_max, float depth) @private {
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
        .depth       = depth,
    };
}

// The medium's node hangs under the body's deepest trough with its bottom where the desc's depth puts it, and
// follows the body's layers. Water shallower than its troughs has no medium.
fn void write_medium(Scene* scene, Node* node, WaterRuntime* runtime) @private {
    Node* medium_node = scene.node(runtime.medium_node);
    float offset = vertical_reach(runtime) + MEDIUM_SKIN;
    medium_node.layers = node.layers;
    medium_node.local.position = { 0, -offset, 0 };
    // The value update_world writes, so the medium is current whichever runs first.
    medium_node.world = node.world.mul(medium_node.local.to_mat4());

    float depth = runtime.desc.depth - offset;
    if (is_clear(&runtime.desc) || !(depth > 0)) {
        if (scene.has(medium_node, MediumVolume)) scene.remove_component(medium_node, MediumVolume);
        return;
    }

    MediumVolume medium = water_medium(&runtime.desc, runtime.rest_min, runtime.rest_max, depth);
    MediumVolume* existing = scene.get(medium_node, MediumVolume);
    if (existing) {
        *existing = medium;
        return;
    }
    scene.add(medium_node, medium);
}
