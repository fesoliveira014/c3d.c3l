module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Whether every referenced rigid part remains drawable.
 @param [&in] assets : "Store the ids were issued by."
 @param [&in] group : "Any group component."
*>
fn bool lod_group_is_live(AssetStore* assets, LodGroup* group) {
    foreach (part : group.state.desc.parts) {
        if (!assets.geometries.is_live(part.geometry) || !assets.materials.is_live(part.material)) return false;
        GeometryAsset* geometry = assets.geometry(part.geometry);
        if (geometry.target_count || geometry.skin_bounds.joints.len || geometry.data.joints.len) return false;
        Material* material = &assets.material(part.material).data;
        if (material.kind == MaterialKind.CUSTOM) {
            if (!assets.shaders.is_live(material.custom.shader)) return false;
            CustomVertex* vertex = &assets.shader(material.custom.shader).desc.vertex;
            if (vertex.shaded.len && (!group.state.desc.has_bounds_override
              || (group.state.mode == LodMode.INSTANCED && !vertex.instanced_shaded.len))) return false;
        }
    }
    return true;
}

<*
 World bound of every placement and level, including sway.
 @param [&in] assets : "Resolves every referenced geometry."
 @param [&in] node : "World matrix follows the last update_world."
 @param [&inout] group : "Live group with at least one placement."
 @require group.state.count > 0
*>
fn Aabb lod_world_bounds(AssetStore* assets, Node* node, LodGroup* group) {
    Aabb bounds = maths::aabb_transform(group.state.placement_bounds(assets), node.world);
    Vec3 reach = group.state.effects.sway.reach();
    return { .min = bounds.min - reach, .max = bounds.max + reach };
}

<*
 Composed world transform of a group part and placement.
 @param [&in] node : "World matrix follows the last update_world."
 @param [&in] state : "Contains the referenced placement and part."
 @param instance : "Original placement index; zero for an ordinary group."
 @param part : "Flat descriptor part index."
*>
fn Mat4 lod_part_world(
    Node* node,
    LodGroupState* state,
    uint instance,
    uint part,
) {
    Mat4 world = node.world;
    if (state.mode == LodMode.INSTANCED) world = world.mul(state.transforms[instance].to_mat4());
    return world.mul(state.desc.parts[part].local);
}

fn SceneEntry lod_entry(
    AssetStore* assets,
    Node* node,
    LodGroupState* state,
    uint instance,
    uint part,
) @private {
    GeometryId geometry = state.desc.parts[part].geometry;
    GeometryAsset* record = assets.geometry(geometry);
    bool deformed = state.desc.has_bounds_override || state.effects.sway.amplitude != 0;
    Aabb bounds;
    if (deformed) {
        Mat4 placement = node.world;
        if (state.mode == LodMode.INSTANCED) placement = placement.mul(state.transforms[instance].to_mat4());
        bounds = maths::aabb_transform(state.local_bounds(assets), placement);
        Vec3 reach = state.effects.sway.reach();
        bounds.min -= reach;
        bounds.max += reach;
    } else {
        bounds = maths::aabb_transform(record.data.bounds, lod_part_world(
            node: node,
            state: state,
            instance: instance,
            part: part,
        ));
    }
    return {
        .node = node,
        .instance_index = instance,
        .part_index = part,
        .geometry = geometry,
        .flags = {
            .lod_group = true,
            .instanced = state.mode == LodMode.INSTANCED,
            .static_triangles = triangles_are_static(record, false, deformed) && record.data.positions.len > 0,
        },
        .bounds = bounds,
    };
}
