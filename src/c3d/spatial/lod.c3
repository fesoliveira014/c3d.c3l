module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

<*
 Check admitted assets and optional published source components.
 @param [&in] assets : "Resolves every referenced asset."
 @param [&in] group : "Copied group being inspected."
 @param [in] scene : "Optional source scene; unchanged by this query."
 @param [in] node : "Source owner when scene is supplied."
*>
fn bool lod_group_is_live(
    AssetStore* assets,
    LodGroup* group,
    Scene* scene = null,
    Node* node = null,
) {
    LodGroupState* state = group.state;
    if (state.animated) {
        if (scene && node && !model::animated_lod_source_is_live(assets, scene, node, state)) return false;
        if (!assets.models.is_live(state.animated.source_model)) return false;
        if (assets.model(state.animated.source_model).header.revision != state.animated.model_revision) return false;
    }
    foreach (index, part : state.desc.parts) {
        if (!assets.geometries.is_live(part.geometry) || !assets.materials.is_live(part.material)) return false;
        GeometryAsset* geometry = assets.geometry(part.geometry);
        if (!state.animated && (geometry.target_count || geometry.skin_bounds.joints.len || geometry.data.joints.len)) {
            return false;
        }
        if (state.animated) {
            AnimatedLodPartBinding binding = state.animated.parts[index];
            if (binding.geometry_revision != geometry.header.revision) return false;
            if ((binding.skeleton.generation && !assets.skeletons.is_live(binding.skeleton))
              || (binding.source_skeleton.generation && !assets.skeletons.is_live(binding.source_skeleton))) return false;
            if (binding.skeleton.generation
              && binding.skeleton_revision != assets.skeleton(binding.skeleton).header.revision) return false;
            if (binding.source_skeleton.generation
              && binding.source_skeleton_revision != assets.skeleton(binding.source_skeleton).header.revision) return false;
        }
        Material* material = &assets.material(part.material).data;
        if (material.kind == MaterialKind.CUSTOM) {
            if (!assets.shaders.is_live(material.custom.shader)) return false;
            CustomVertex* vertex = &assets.shader(material.custom.shader).desc.vertex;
            if (vertex.shaded.len && (!state.desc.has_bounds_override
              || (state.mode == LodMode.INSTANCED && !vertex.instanced_shaded.len))) return false;
        }
    }
    return true;
}

<*
 Read current selectable bounds from a live source.
 @param [&in] assets : "Retained geometry bounds."
 @param [&in] node : "Owner with updated world transform."
 @param [&in] group : "Admitted group with a live source."
 @param origin : "World origin subtracted from the result."
 @param [in] scene : "Required for animated groups."
 @require group.state.count > 0
 @require !group.state.animated || scene != null
*>
fn Aabb lod_world_bounds(
    AssetStore* assets,
    Node* node,
    LodGroup* group,
    Vec3 origin = {},
    Scene* scene = null,
) {
    LodGroupState* state = group.state;
    if (state.animated) {
        Aabb bounds;
        bool first = true;
        for (uint instance = 0; instance < state.count; instance++) {
            foreach (uint part, draw : state.desc.parts) {
                Aabb current = animated_lod_part_bounds(
                    assets: assets,
                    scene: scene,
                    node: node,
                    state: state,
                    instance: instance,
                    part: part,
                    origin: origin,
                );
                bounds = first ? current : maths::aabb_merge(bounds, current);
                first = false;
            }
        }
        return bounds;
    }
    Aabb bounds = maths::aabb_transform(state.placement_bounds(assets), maths::rebase(node.world, origin));
    Vec3 reach = state.effects.sway.reach();
    return { .min = bounds.min - reach, .max = bounds.max + reach };
}

<*
 Read the world transform of one admitted representation.
 @param [&in] node : "Owner with updated world transform."
 @param [&in] state : "Admitted copied representation."
 @param instance : "Live logical placement index."
 @param part : "Flat representation index."
 @param [in] scene : "Required for animated groups."
 @require !state.animated || scene != null
*>
fn Mat4 lod_part_world(
    Node* node,
    LodGroupState* state,
    uint instance,
    uint part,
    Scene* scene = null,
) {
    if (state.animated) {
        AnimatedLodPartBinding binding = state.animated.parts[part];
        AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
        if (crowd) {
            Mat4 world = node.world.mul(crowd.part_transform(instance, binding.mesh_index));
            return binding.skinned ? world : world.mul(state.desc.parts[part].local);
        }
        if (binding.skinned) return node.world;
        ModelInstance* source = scene.get(node, ModelInstance);
        return source.present_node(binding.template_node).world.mul(state.desc.parts[part].local);
    }
    Mat4 world = node.world;
    if (state.mode == LodMode.INSTANCED) world = world.mul(state.transforms[instance].to_mat4());
    return world.mul(state.desc.parts[part].local);
}

<* Whether this node is an imported source mesh/batch owned by an animated group. *>
fn bool animated_lod_owns_node(Scene* scene, Node* node) @private {
    for (Node* owner = node; owner; owner = owner.parent) {
        LodGroup* group = scene.get(owner, LodGroup);
        if (!group || !group.state.animated || !c3d::same_id(group.state.animated.source_owner, owner.id)) continue;
        ModelInstance* source = scene.get(owner, ModelInstance);
        if (source) {
            foreach (template_node : source.mesh_nodes) {
                if (source.present_node(template_node) == node) return true;
            }
        }
        AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
        if (crowd) {
            foreach (part : crowd.parts) {
                if (c3d::same_id(part.batch, node.id)) return true;
            }
        }
    }
    return false;
}

<*
 Read a logical part's guaranteed level-zero representation.
 @param [&in] state : "Admitted level zero covers every logical mesh."
 @require !state.animated || logical_part < state.animated.channel_offsets.len - 1
 @ensure return < state.desc.parts.len
*>
fn uint lod_base_representation(LodGroupState* state, uint logical_part) @private {
    if (!state.animated) return logical_part;
    LodLevel level = state.desc.levels[0];
    for (uint part = level.first_part; part < level.first_part + level.part_count; part++) {
        if (state.animated.parts[part].mesh_index == logical_part) return part;
    }
    unreachable();
}

<* Current bounds of one admitted animated LOD representation.
 @param [&in] assets : "Retained geometry and skin metadata."
 @param [&in] scene : "Current synchronized source components."
 @param [&in] node : "Owner with updated world transform."
 @param [&in] state : "Admitted copied representation and source binding."
 @require state.animated != null, instance < state.count, part < state.desc.parts.len
*>
fn Aabb animated_lod_part_bounds(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    LodGroupState* state,
    uint instance,
    uint part,
    Vec3 origin = {},
) {
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    Aabb bounds;
    if (crowd) {
        Mat4 placement = maths::rebase(node.world, origin).mul(crowd.placements[instance].to_mat4());
        bounds = maths::aabb_transform(crowd.pose_bounds, placement);
    } else if (state.desc.has_bounds_override) {
        bounds = maths::aabb_transform(state.desc.local_bounds, maths::rebase(node.world, origin));
    } else {
        AnimatedLodPartBinding binding = state.animated.parts[part];
        ModelInstance* source = scene.get(node, ModelInstance);
        Node* source_node = source.present_node(binding.template_node);
        Mesh* mesh = scene.get(source_node, Mesh);
        GeometryAsset* record = assets.geometry(state.desc.parts[part].geometry);
        MorphSelection selection;
        if (record.target_count && binding.weight_count) {
            selection = geometry::select_morph_targets(
                record.data.channels,
                mesh.morph_weights,
                state.animated.weight_indices[binding.weight_offset:binding.weight_count],
            );
        }
        Mat4 world = maths::rebase(source_node.world.mul(state.desc.parts[part].local), origin);
        if (!binding.skinned || !record.skin_bounds.joints.len) {
            Aabb local = geometry::widen_by_morphs(record.data.bounds, record.morph_bounds, &selection);
            bounds = maths::aabb_transform(local, world);
        } else {
            SkinBinding* skin = scene.get(source_node, SkinBinding);
            bounds = skinned_world_bounds(
                bounds: &record.skin_bounds,
                binding: skin,
                inverse_bind: state.animated.inverse_bind,
                selection: &selection,
                rest: maths::aabb_transform(record.data.bounds, world),
                origin: origin,
            );
        }
    }
    Vec3 reach = state.effects.sway.reach();
    return { .min = bounds.min - reach, .max = bounds.max + reach };
}

fn SceneEntry lod_entry(
    AssetStore* assets,
    Node* node,
    LodGroupState* state,
    uint instance,
    uint part,
    Scene* scene = null,
) @private {
    GeometryId geometry = state.desc.parts[part].geometry;
    GeometryAsset* record = assets.geometry(geometry);
    if (state.animated) {
        AnimatedLodPartBinding binding = state.animated.parts[part];
        bool deformed = binding.skinned || record.target_count || state.desc.has_bounds_override
          || state.effects.sway.amplitude != 0;
        return {
            .node = node,
            .instance_index = instance,
            .part_index = binding.mesh_index,
            .geometry = geometry,
            .flags = {
                .lod_group = true,
                .instanced = state.mode == LodMode.INSTANCED,
                .skinned = binding.skinned,
                .static_triangles = triangles_are_static(record, binding.skinned, deformed)
                  && record.data.positions.len > 0,
            },
            .bounds = animated_lod_part_bounds(
                assets: assets,
                scene: scene,
                node: node,
                state: state,
                instance: instance,
                part: part,
            ),
        };
    }
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
