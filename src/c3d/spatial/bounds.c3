module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::geometry;
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
 Relative bound of the mesh, including overrides and joint deformation.
 @param [&in] assets : "Resolves the live geometry record."
 @param [&in] node : "World matrix as left by the last update_world."
 @param [&in] mesh : "Live geometry id."
 @param [in] skin : "Null for an unskinned mesh; joints with current world matrices otherwise."
 @param origin : "Absolute origin of the returned bounds; zero preserves world."
*>
fn Aabb mesh_world_bounds(
    AssetStore* assets,
    Node* node,
    Mesh* mesh,
    SkinBinding* skin,
    Vec3 origin = {},
) {
    Mat4 world = maths::rebase(node.world, origin);
    if (mesh.has_bounds_override) return maths::aabb_transform(mesh.local_bounds, world);
    GeometryAsset* record = assets.geometry(mesh.geometry);
    Aabb rest = maths::aabb_transform(record.data.bounds, world);
    if (!skin || !record.skin_bounds.joints.len) return rest;
    MorphSelection selection = geometry::select_morph_targets(record.data.channels, mesh.morph_weights);
    return skinned_world_bounds(
        bounds:       &record.skin_bounds,
        binding:      skin,
        inverse_bind: assets.skeleton(skin.skeleton).data.inverse_bind,
        selection:    &selection,
        rest:         rest,
        origin:       origin,
    );
}

<*
 Whether the batch's geometry and material ids resolve.
 @param [&in] assets : "Store the ids were issued by."
 @param [&in] batch : "Any batch component."
*>
fn bool instanced_mesh_is_live(AssetStore* assets, InstancedMesh* batch) {
    return assets.geometries.is_live(batch.geometry) && assets.materials.is_live(batch.material);
}

<*
 Relative bound of the live instances, including their sway reach.
 @param [&in] assets : "Resolves the live geometry record."
 @param [&in] node : "World matrix as left by the last update_world."
 @param [&inout] batch : "Live geometry id and live count above zero."
 @param origin : "Absolute origin of the returned bounds; zero preserves world."
*>
fn Aabb instanced_world_bounds(
    AssetStore* assets,
    Node* node,
    InstancedMesh* batch,
    Vec3 origin = {},
) {
    Aabb local = batch.has_bounds_override ? batch.local_bounds : kept_instance_bounds(assets, batch);
    Aabb world = maths::aabb_transform(local, maths::rebase(node.world, origin));
    Vec3 reach = batch.sway.reach();
    return { .min = world.min - reach, .max = world.max + reach };
}

fn Aabb kept_instance_bounds(AssetStore* assets, InstancedMesh* batch) @local {
    GeometryAsset* record = assets.geometry(batch.geometry);
    InstanceAggregate* aggregate = &batch.aggregate;
    bool current = aggregate.bounds_revision == batch.revision && c3d::same_id(aggregate.geometry, batch.geometry)
      && aggregate.geometry_revision == record.header.revision;
    if (current) return aggregate.bounds;
    Aabb local = record.data.bounds;
    aggregate.bounds = maths::aabb_transform(local, batch.transforms[0].to_mat4());
    foreach (transform : batch.transforms[1:batch.count - 1]) {
        aggregate.bounds = maths::aabb_merge(aggregate.bounds, maths::aabb_transform(local, transform.to_mat4()));
    }
    aggregate.geometry = batch.geometry;
    aggregate.geometry_revision = record.header.revision;
    aggregate.bounds_revision = batch.revision;
    return aggregate.bounds;
}

<*
 Relative bound of retained joint bounds under the current pose.
 @param [&in] bounds : "Retained per-joint bounds of the geometry."
 @param [&in] binding : "Joints with current world matrices."
 @param inverse_bind : "One matrix per skeleton joint."
 @param [&in] selection : "Active morph targets of the mesh."
 @param rest : "Relative fallback when no joint bound applies."
 @param origin : "Absolute origin shared by rest and returned bounds."
*>
fn Aabb skinned_world_bounds(
    SkinBounds* bounds,
    SkinBinding* binding,
    Mat4[] inverse_bind,
    MorphSelection* selection,
    Aabb rest,
    Vec3 origin = {},
) {
    usz joint_count = math::min((usz)bounds.joints.len, math::min((usz)binding.joints.len, (usz)inverse_bind.len));
    Aabb result;
    bool first = true;
    for (uint joint = 0; joint < joint_count; joint++) {
        if (!bounds.used[joint]) continue;
        Aabb local = geometry::joint_morph_bounds(bounds, joint, selection);
        Mat4 transform = maths::rebase(binding.joints[joint].world, origin).mul(inverse_bind[joint]);
        Aabb world = maths::aabb_transform(local, transform);
        result = first ? world : maths::aabb_merge(result, world);
        first = false;
    }
    return first ? rest : result;
}
