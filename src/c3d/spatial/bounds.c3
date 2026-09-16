module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Whether the mesh's geometry, material and skeleton ids resolve.
 @param [&in] assets : "Store the ids were issued by."
 @param [&in] mesh : "Any mesh component."
 @param [in] skin : "Null for an unskinned mesh."
*>
fn bool mesh_is_live(AssetStore* assets, Mesh* mesh, SkinBinding* skin) {
    return assets.geometries.is_live(mesh.geometry) && assets.materials.is_live(mesh.material)
        && (!skin || assets.skeletons.is_live(skin.skeleton));
}

<*
 World bound of the mesh from its override, its geometry or its joints.
 @param [&in] assets : "Resolves the live geometry record."
 @param [&in] node : "World matrix as left by the last update_world."
 @param [&in] mesh : "Live geometry id."
 @param [in] skin : "Null for an unskinned mesh; joints with current world matrices otherwise."
*>
fn Aabb mesh_world_bounds(
    AssetStore* assets,
    Node* node,
    Mesh* mesh,
    SkinBinding* skin,
) {
    if (mesh.has_bounds_override) return maths::aabb_transform(mesh.local_bounds, node.world);
    Aabb local = assets.geometry(mesh.geometry).data.bounds;
    if (skin) return skinned_world_bounds(local, node.world, skin);
    return maths::aabb_transform(local, node.world);
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
