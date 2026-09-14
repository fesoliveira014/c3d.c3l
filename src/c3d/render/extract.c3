module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
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
const uint SHADER_FLAG_SHIFT @private = 8; // ShaderVariant.flags start at bit 8; the shader ordinal fills the byte below

<*
 Per-view list a material's draws belong to.
*>
enum DrawList {
    OPAQUE,
    TRANSMISSION,
    TRANSPARENT,
}

<*
 Mesh that passed inclusion for one view, with its bounds in world space.
*>
struct MeshCandidate {
    Node*        node;
    GeometryId   geometry;
    MaterialId   material;
    SkinBinding* skin;
    float[]      morph_weights;
    Aabb         world_bounds;
    float        ndc_depth;
    float        view_depth;
    bool         receive_shadow;
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
            include_mesh(candidates, scene, node, mesh, assets, camera, counts);
        }
    };
    return candidates[:counts.visible];
}

<*
 Select the draw list: transmission first, then blend, else opaque.
 @param [&in] material : "Valid active arm."
 @pure
*>
fn DrawList draw_list(Material* material) {
    if (material.kind == MaterialKind.PHYSICAL && material.physical.transmission > 0) {
        return DrawList.TRANSMISSION;
    }
    return material.common.alpha_mode == AlphaMode.BLEND ? DrawList.TRANSPARENT : DrawList.OPAQUE;
}

<*
 Ordering key: pipeline, material, geometry, then front to back.
 @param vertex : "Its flags distinguish deformed pipelines."
 @param ndc_depth : "Reverse-Z depth of the bounds center, clamped to [0, 1]."
*>
fn ulong draw_sort_key(
    ShaderVariant vertex,
    ShaderVariant fragment,
    MaterialId material,
    GeometryId geometry,
    float ndc_depth,
) {
    ulong slot_mask = (1UL << SORT_KEY_SLOT_BITS) - 1;
    ulong depth = (ulong)(ushort)((1.0f - ndc_depth) * (float)ushort::max);
    ulong pipeline = (ulong)fragment.shader.ordinal | (ulong)vertex.flags << SHADER_FLAG_SHIFT;
    return (pipeline & slot_mask) << SORT_KEY_PIPELINE_SHIFT
        | ((ulong)material.index & slot_mask) << SORT_KEY_MATERIAL_SHIFT
        | ((ulong)geometry.index & slot_mask) << SORT_KEY_GEOMETRY_SHIFT
        | depth;
}

fn void include_mesh(MeshCandidate[] candidates, Scene* scene, Node* node, Mesh* mesh, AssetStore* assets,
  CameraMatrices* camera, ExtractCounts* counts) @local {
    SkinBinding* skin = scene.get(node, SkinBinding);
    if (!mesh_is_live(assets, mesh, skin)) {
        counts.dangling++;
        return;
    }
    Aabb world = candidate_bounds(assets, node, mesh, skin);
    if (!maths::frustum_intersects_aabb(&camera.frustum, world)) {
        counts.culled++;
        return;
    }
    candidates[counts.visible] = {
        .node           = node,
        .geometry       = mesh.geometry,
        .material       = mesh.material,
        .skin           = skin,
        .morph_weights  = morph_weights_of(assets, mesh),
        .world_bounds   = world,
        .ndc_depth      = center_depth(camera, world),
        .view_depth     = center_view_depth(camera, world),
        .receive_shadow = mesh.receive_shadow,
    };
    counts.visible++;
}

fn bool mesh_is_live(AssetStore* assets, Mesh* mesh, SkinBinding* skin) @local {
    return assets.geometries.is_live(mesh.geometry) && assets.materials.is_live(mesh.material)
        && (!skin || assets.skeletons.is_live(skin.skeleton));
}

fn Aabb candidate_bounds(AssetStore* assets, Node* node, Mesh* mesh, SkinBinding* skin) @local {
    if (mesh.has_bounds_override) return maths::aabb_transform(mesh.local_bounds, node.world);
    Aabb local = assets.geometry(mesh.geometry).data.bounds;
    if (skin) return skinned_world_bounds(local, node.world, skin);
    return maths::aabb_transform(local, node.world);
}

fn float[] morph_weights_of(AssetStore* assets, Mesh* mesh) @local {
    return assets.geometry(mesh.geometry).data.targets.len ? mesh.morph_weights : (float[]){};
}

<*
 World bound covering every joint of the binding at the mesh's bind-bound radius.
 @param local : "Bind-pose bounds of the geometry."
 @param world : "World matrix of the mesh node."
 @param [&in] binding : "Joints with current world matrices."
*>
fn Aabb skinned_world_bounds(Aabb local, Mat4 world, SkinBinding* binding) {
    Aabb bind = maths::aabb_transform(local, world);
    float radius = ((bind.max - bind.min) * 0.5f).length();
    Vec3 extent = { radius, radius, radius };
    Aabb bounds;
    foreach (index, joint : binding.joints) {
        Vec3 center = joint.world_position();
        Aabb around = { .min = center - extent, .max = center + extent };
        bounds = index == 0 ? around : maths::aabb_merge(bounds, around);
    }
    return bounds;
}

fn float center_view_depth(CameraMatrices* camera, Aabb world) @local {
    Vec3 center = (world.min + world.max) * 0.5f;
    return -camera.view.apply({ center.x, center.y, center.z, 1.0f }).z;
}

<*
 Order transparent bounds centers from far to near, then entity identity.
 @param first : "Live candidate with finite view depth."
 @param second : "Live candidate with finite view depth."
 @return "Negative when first orders earlier."
 @pure
*>
fn int compare_transparent_candidates(MeshCandidate first, MeshCandidate second) {
    if (first.view_depth > second.view_depth) return -1;
    if (first.view_depth < second.view_depth) return 1;
    if (first.node.id.index < second.node.id.index) return -1;
    if (first.node.id.index > second.node.id.index) return 1;
    if (first.node.id.generation < second.node.id.generation) return -1;
    return first.node.id.generation > second.node.id.generation ? 1 : 0;
}

fn float center_depth(CameraMatrices* camera, Aabb world) @local {
    Vec3 center = (world.min + world.max) * 0.5f;
    Vec4 clip = camera.view_proj.apply({ center.x, center.y, center.z, 1.0f });
    // A center on or behind the camera plane sorts as nearest; its box still straddles the near plane.
    return clip.w > 0 ? math::clamp(clip.z / clip.w, 0.0f, 1.0f) : 1.0f;
}

<*
 Collect live visible casters independently of layer masks.
 @param allocator : "Owns the returned candidate array."
 @param [&in] scene : "Current transforms; structurally unchanged during extraction."
 @param [&in] assets : "Supplies live ids and retained geometry bounds."
 @param [&inout] counts : "Reset, then populated for broad caster inclusion."
*>
fn MeshCandidate[] extract_shadow_candidates(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    ExtractCounts* counts,
) {
    *counts = {};
    MeshCandidate[] candidates = alloc::new_array(allocator, MeshCandidate, scene.count(Mesh));

    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && mesh.cast_shadow) {
            SkinBinding* skin = scene.get(node, SkinBinding);
            if (!mesh_is_live(assets, mesh, skin)) {
                counts.dangling++;
            } else {
                Material* material = &assets.material(mesh.material).data;
                if (material.common.alpha_mode != AlphaMode.BLEND) {
                    candidates[counts.visible++] = {
                        .node           = node,
                        .geometry       = mesh.geometry,
                        .material       = mesh.material,
                        .skin           = skin,
                        .morph_weights  = morph_weights_of(assets, mesh),
                        .world_bounds   = candidate_bounds(assets, node, mesh, skin),
                        .receive_shadow = mesh.receive_shadow,
                    };
                }
            }
        }
    };

    return candidates[:counts.visible];
}
