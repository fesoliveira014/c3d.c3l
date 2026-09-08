module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import std::math;

<*
 Slot bits the sort key gives each of the material and geometry ids.
*>
const uint SORT_KEY_SLOT_BITS = 16; // slots past 65535 alias in the key; ordering still holds within a slot

const uint SORT_KEY_PIPELINE_SHIFT @private = 48;
const uint SORT_KEY_MATERIAL_SHIFT @private = 32;
const uint SORT_KEY_GEOMETRY_SHIFT @private = 16;

<*
 Mesh that passed inclusion for one view, with its bounds in world space.
*>
struct MeshCandidate {
    Node*      node;
    GeometryId geometry;
    MaterialId material;
    Aabb       world_bounds;
    float      ndc_depth;
}

<*
 What extraction saw and why meshes were left out.
*>
struct ExtractCounts {
    uint visible;
    uint culled;
    uint dangling;
}

<*
 Meshes of the scene inside the camera's frustum and layers, in component order.
 @param allocator : "Owns the returned array."
 @param [&in] scene : "Pose as left by the last update_world."
 @param [&in] assets : "Resolves geometry bounds."
 @param [&in] camera : "Frustum and view-projection of the view."
 @param layers : "Camera layer mask."
 @param [&inout] counts : "Zeroed first, then accumulated."
*>
fn MeshCandidate[] extract_candidates(Allocator allocator, Scene* scene, AssetStore* assets,
  CameraMatrices* camera, uint layers, ExtractCounts* counts) {
    *counts = {};
    MeshCandidate[] candidates = alloc::new_array(allocator, MeshCandidate, scene.count(Mesh));
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (layers & node.layers) != 0) {
            include_mesh(candidates, node, mesh, assets, camera, counts);
        }
    };
    return candidates[:counts.visible];
}

<*
 Ordering key: pipeline, material, geometry, then front to back.
 @param ndc_depth : "Reverse-Z depth of the bounds center, clamped to [0, 1]."
*>
fn ulong draw_sort_key(ShaderVariant fragment, MaterialId material, GeometryId geometry, float ndc_depth) {
    ulong slot_mask = (1UL << SORT_KEY_SLOT_BITS) - 1;
    ulong depth = (ulong)(ushort)((1.0f - ndc_depth) * (float)ushort::max);
    return ((ulong)(uint)fragment & slot_mask) << SORT_KEY_PIPELINE_SHIFT
        | ((ulong)material.index & slot_mask) << SORT_KEY_MATERIAL_SHIFT
        | ((ulong)geometry.index & slot_mask) << SORT_KEY_GEOMETRY_SHIFT
        | depth;
}

fn void include_mesh(MeshCandidate[] candidates, Node* node, Mesh* mesh, AssetStore* assets,
  CameraMatrices* camera, ExtractCounts* counts) @local {
    if (!assets.geometries.is_live(mesh.geometry) || !assets.materials.is_live(mesh.material)) {
        counts.dangling++;
        return;
    }
    Aabb local = mesh.has_bounds_override ? mesh.local_bounds : assets.geometry(mesh.geometry).data.bounds;
    Aabb world = maths::aabb_transform(local, node.world);
    if (!maths::frustum_intersects_aabb(&camera.frustum, world)) {
        counts.culled++;
        return;
    }
    candidates[counts.visible] = {
        .node         = node,
        .geometry     = mesh.geometry,
        .material     = mesh.material,
        .world_bounds = world,
        .ndc_depth    = center_depth(camera, world),
    };
    counts.visible++;
}

fn float center_depth(CameraMatrices* camera, Aabb world) @local {
    Vec3 center = (world.min + world.max) * 0.5f;
    Vec4 clip = camera.view_proj.apply({ center.x, center.y, center.z, 1.0f });
    // A center on or behind the camera plane sorts as nearest; its box still straddles the near plane.
    return clip.w > 0 ? math::clamp(clip.z / clip.w, 0.0f, 1.0f) : 1.0f;
}
