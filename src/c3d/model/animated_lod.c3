module c3d::model;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::scene @public;
import std::math;

struct AnimatedLodSource @local {
    Scene* scene;
    Node* owner;
    ModelAsset* model;
    ModelInstance* instance;
    AnimatedCrowd* crowd;
}

<*
 Attach copied alternatives to a model or crowd.
 @param [&in] assets : "Resolves borrowed asset identities."
 @param [&inout] scene : "Owns the copied alternatives."
 @param [&in] owner : "Existing model or crowd owner."
 @param desc : "Arrays are copied after complete admission."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? attach_animated_lod(
    AssetStore* assets,
    Scene* scene,
    Node* owner,
    AnimatedLodDesc desc,
) {
    AnimatedLodSource source = animated_lod_source(assets, scene, owner)!;
    if (scene.has(owner, LodGroup)) return c3d::INVALID_ARGUMENT~;

    LodGroup group = build_animated_lod(
        allocator: scene.allocator,
        assets: assets,
        source: source,
        desc: desc,
    )!;
    defer catch scene::destroy_lod_group(scene.allocator, &group);

    initialize_animated_lod_source(group.state, source);
    (void)group.state.local_bounds(assets);
    scene.add(owner, group);
}

fn AnimatedLodSource? animated_lod_source(AssetStore* assets, Scene* scene, Node* owner) @local {
    if (!scene.world.is_alive(owner.id)) return c3d::INVALID_ID~;

    ModelInstance* instance = scene.get(owner, ModelInstance);
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    if ((instance != null) == (crowd != null)) return c3d::INVALID_ARGUMENT~;

    ModelAsset* model = assets.models.try_get(instance ? instance.source : crowd.model)!;
    ModelTemplate* template = &model.data;

    if (!template.nodes.len || !template.meshes.len || template.meshes.len > uint::max
      || template.nodes.len > uint::max) return c3d::INVALID_ARGUMENT~;
    if (template.lod_groups.len) return c3d::UNSUPPORTED~;

    if (instance && (instance.mesh_nodes.len != template.meshes.len
      || instance.base_morph_weights.len != template.meshes.len
      || instance.nodes.len != template.nodes.len || instance.node_entities.len != template.nodes.len)) {
        return c3d::INVALID_ARGUMENT~;
    }

    if (crowd && (!crowd.placements.len || crowd.count > crowd.placements.len)) return c3d::INVALID_ARGUMENT~;

    if (instance) {
        foreach (index, mesh : template.meshes) {
            if (mesh.node >= instance.nodes.len || instance.mesh_nodes[index] != mesh.node) {
                return c3d::INVALID_ARGUMENT~;
            }

            Node* part = instance.present_node(mesh.node);
            if (!part) return c3d::INVALID_ID~;

            Mesh* live = scene.get(part, Mesh);
            if (!live || !c3d::same_id(live.geometry, mesh.geometry)
              || !c3d::same_id(live.material, mesh.material)
              || live.morph_weights.len != instance.base_morph_weights[index].len) {
                return c3d::INVALID_ARGUMENT~;
            }

            ModelSkin* skin = skin_at(template, mesh.node);
            if (skin) {
                SkinBinding* binding = scene.get(part, SkinBinding);
                if (!binding || !c3d::same_id(binding.skeleton, skin.skeleton)
                  || binding.joints.len != skin.joint_nodes.len) return c3d::INVALID_ARGUMENT~;

                foreach (joint_index, template_node : skin.joint_nodes) {
                    if (template_node >= instance.nodes.len) return c3d::INVALID_ARGUMENT~;

                    Node* joint = instance.present_node(template_node);
                    if (!joint) return c3d::INVALID_ID~;
                    if (binding.joints[joint_index] != joint) return c3d::INVALID_ARGUMENT~;
                }
            }
        }
    }

    if (crowd && crowd.is_prepared()) {
        if (crowd.parts.len != template.meshes.len || crowd.playback.slots.len != crowd.placements.len) {
            return c3d::INVALID_ARGUMENT~;
        }

        foreach (index, part : crowd.parts) {
            if (!scene.world.is_alive(part.batch)) return c3d::INVALID_ID~;
            InstancedMesh* live = scene.world.get(part.batch, InstancedMesh);
            ModelMesh mesh = template.meshes[index];
            if (!live || part.mesh_index != index || part.template_node != mesh.node
              || !c3d::same_id(live.geometry, mesh.geometry) || !c3d::same_id(live.material, mesh.material)) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
    }

    return {
        .scene = scene,
        .owner = owner,
        .model = model,
        .instance = instance,
        .crowd = crowd,
    };
}

fn float[] source_defaults(AnimatedLodSource source, uint mesh_index) @local {
    if (source.instance) return source.instance.base_morph_weights[mesh_index];
    if (source.crowd.playback) return source.crowd.playback.base_morph_weights[mesh_index];
    return source.model.data.meshes[mesh_index].default_morph_weights;
}

<* Null denotes a logical mesh without an authored skin. *>
fn ModelSkin* skin_at(ModelTemplate* template, uint mesh_node) @local {
    foreach (&skin : template.skins) {
        if (skin.mesh_node == mesh_node) return skin;
    }
    return null;
}

fn bool geometry_is_skinned(GeometryAsset* geometry) @local {
    return geometry.skin_bounds.joints.len != 0 || geometry.data.joints.len != 0;
}

fn usz weight_width(GeometryAsset* geometry) @local {
    return geometry.data.channels.len ? geometry.data.channels.len : geometry.target_count;
}

fn bool identity_matrix(Mat4 value) @local {
    Mat4 identity = matrix::IDENTITY4;
    foreach (index, lane : value.m[..]) {
        if (lane != identity.m[index]) return false;
    }
    return true;
}

fn void? validate_shared_skin(
    AssetStore* assets,
    ModelTemplate* template,
    ModelSkin skin,
    uint[] expected_nodes,
    Mat4[] expected_bind,
) @local {
    Skeleton* skeleton = &assets.skeletons.try_get(skin.skeleton)!.data;
    if (!skin.joint_nodes.len || skin.joint_nodes.len != skeleton.inverse_bind.len
      || skin.joint_nodes.len != expected_nodes.len) return c3d::INVALID_ARGUMENT~;

    foreach (index, node : skin.joint_nodes) {
        if (node >= template.nodes.len || node != expected_nodes[index]) return c3d::INVALID_ARGUMENT~;
    }

    if (!mem::equals(skeleton.inverse_bind.ptr, expected_bind.ptr, (sz)(expected_bind.len * Mat4::size))) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn void? validate_source_shape(AssetStore* assets, AnimatedLodSource source) @local {
    ModelTemplate* template = &source.model.data;
    check_crowd_template(assets, template)!;

    foreach (index, mesh : template.meshes) {
        GeometryAsset* geometry = assets.geometry(mesh.geometry);
        float[] defaults = source_defaults(source, (uint)index);
        if (defaults.len != weight_width(geometry)) return c3d::INVALID_ARGUMENT~;
        foreach (weight : defaults) {
            if (!math::is_finite(weight)) return c3d::INVALID_ARGUMENT~;
        }

        if (geometry_is_skinned(geometry) && !skin_at(template, mesh.node)) return c3d::INVALID_ARGUMENT~;
    }
}

fn uint? mapped_weight(
    GeometryAsset* base,
    GeometryAsset* selected,
    uint weight,
) @local {
    String name = selected.data.channels.len ? selected.data.channels[weight].name : "";
    if (name.len) {
        if (!base.data.channels.len) return c3d::INVALID_ARGUMENT~;
        foreach (index, channel : base.data.channels) {
            if (channel.name == name) return (uint)index;
        }
        return c3d::INVALID_ARGUMENT~;
    }

    if (weight_width(base) != weight_width(selected)) return c3d::INVALID_ARGUMENT~;
    if (base.data.channels.len && base.data.channels[weight].name.len) return c3d::INVALID_ARGUMENT~;
    return weight;
}

fn LodGroup? build_animated_lod(
    Allocator allocator,
    AssetStore* assets,
    AnimatedLodSource source,
    AnimatedLodDesc desc,
) @local {
    validate_source_shape(assets, source)!;

    ModelTemplate* template = &source.model.data;
    if (source.crowd && desc.has_bounds_override) return c3d::INVALID_ARGUMENT~;

    @pool() {
        LodPart[] draws = alloc::new_array_try(tmem, LodPart, desc.parts.len)
          ?? c3d::CAPACITY_EXCEEDED~!;

        foreach (index, part : desc.parts) draws[index] = part.draw;

        LodDesc layout = {
            .levels = desc.levels,
            .parts = draws,
            .has_bounds_override = source.crowd ? true : desc.has_bounds_override,
            .local_bounds = source.crowd ? source.crowd.pose_bounds : desc.local_bounds,
        };

        scene::validate_lod_layout(layout)!;
        if (desc.levels[0].part_count != template.meshes.len) return c3d::INVALID_ARGUMENT~;

        uint[] offsets = alloc::new_array_try(tmem, uint, template.meshes.len + 1)
          ?? c3d::CAPACITY_EXCEEDED~!;
        usz logical_count;

        foreach (index, mesh : template.meshes) {
            logical_count += source_defaults(source, (uint)index).len;
            if (logical_count > uint::max) return c3d::CAPACITY_EXCEEDED~;

            offsets[index + 1] = (uint)logical_count;
        }

        float[] defaults = alloc::new_array_try(tmem, float, (sz)logical_count)
          ?? c3d::CAPACITY_EXCEEDED~!;

        foreach (index, mesh : template.meshes) {
            float[] baseline = source_defaults(source, (uint)index);
            defaults[offsets[index]:baseline.len] = baseline[..];
        }

        usz selected_count;
        foreach (part : desc.parts) {
            selected_count += part.default_morph_weights.len;
            if (selected_count > uint::max) return c3d::CAPACITY_EXCEEDED~;
        }

        uint[] indices = alloc::new_array_try(tmem, uint, (sz)selected_count)
          ?? c3d::CAPACITY_EXCEEDED~!;
        AnimatedLodPartBinding[] parts = alloc::new_array_try(tmem, AnimatedLodPartBinding, desc.parts.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        bool[] seen = alloc::new_array_try(tmem, bool, template.meshes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        usz next_weight;

        foreach (level_index, level : desc.levels) {
            seen[..] = false;
            foreach (usz local_index, part : desc.parts[level.first_part:level.part_count]) {
                uint representation = level.first_part + (uint)local_index;
                if (part.mesh_index >= template.meshes.len || seen[part.mesh_index]) return c3d::INVALID_ARGUMENT~;
                seen[part.mesh_index] = true;

                ModelMesh mesh = template.meshes[part.mesh_index];
                GeometryAsset* base = assets.geometry(mesh.geometry);
                GeometryAsset* selected = assets.geometries.try_get(part.draw.geometry)!;
                bool skinned = geometry_is_skinned(base);
                if (geometry_is_skinned(selected) != skinned) return c3d::INVALID_ARGUMENT~;

                ModelSkin* skin = skin_at(template, mesh.node);
                if (skin) {
                    Skeleton* skeleton = &assets.skeleton(skin.skeleton).data;
                    if (part.skin.mesh_node != mesh.node) return c3d::INVALID_ARGUMENT~;
                    validate_shared_skin(
                        assets: assets,
                        template: template,
                        skin: part.skin,
                        expected_nodes: skin.joint_nodes,
                        expected_bind: skeleton.inverse_bind,
                    )!;
                    if (selected.skin_bounds.joints.len > skin.joint_nodes.len) return c3d::INVALID_ARGUMENT~;
                } else if (part.skin.skeleton.generation || part.skin.joint_nodes.len) {
                    return c3d::INVALID_ARGUMENT~;
                }

                if ((level_index == 0 || skinned) && !identity_matrix(part.draw.local)) {
                    return c3d::INVALID_ARGUMENT~;
                }

                float[] baseline = source_defaults(source, part.mesh_index);
                if (part.default_morph_weights.len != weight_width(selected)) return c3d::INVALID_ARGUMENT~;
                if (level_index == 0 && (!c3d::same_id(part.draw.geometry, mesh.geometry)
                  || !c3d::same_id(part.draw.material, mesh.material))) return c3d::INVALID_ARGUMENT~;

                scene::validate_lod_material(
                    assets: assets,
                    material_id: part.draw.material,
                    mode: source.crowd ? LodMode.INSTANCED : LodMode.SINGLE,
                    bounds_override: layout.has_bounds_override,
                )!;

                uint first_weight = (uint)next_weight;
                bool[] selected_seen = alloc::new_array_try(tmem, bool, baseline.len)
                  ?? c3d::CAPACITY_EXCEEDED~!;

                foreach (uint weight, value : part.default_morph_weights) {
                    if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
                    uint mapped = mapped_weight(base, selected, weight)!;
                    if (mapped >= baseline.len || selected_seen[mapped]
                      || bitcast(value, uint) != bitcast(baseline[mapped], uint)) return c3d::INVALID_ARGUMENT~;
                    selected_seen[mapped] = true;
                    indices[next_weight++] = mapped;
                }

                parts[representation] = {
                    .mesh_index = part.mesh_index,
                    .template_node = mesh.node,
                    .skinned = skinned,
                    .skeleton = part.skin.skeleton,
                    .source_skeleton = skin ? skin.skeleton : (SkeletonId){},
                    .source_skeleton_revision = skin ? assets.skeleton(skin.skeleton).header.revision : 0,
                    .geometry_revision = selected.header.revision,
                    .skeleton_revision = skin ? assets.skeleton(part.skin.skeleton).header.revision : 0,
                    .weight_offset = first_weight,
                    .weight_count = (uint)part.default_morph_weights.len,
                };
            }
        }

        uint[] joints;
        Mat4[] inverse_bind;

        if (template.skins.len) {
            joints = template.skins[0].joint_nodes;
            inverse_bind = assets.skeleton(template.skins[0].skeleton).data.inverse_bind;
        }

        AnimatedLodBinding binding = {
            .source_owner = source.owner.id,
            .source_model = source.instance ? source.instance.source : source.crowd.model,
            .model_revision = source.model.header.revision,
            .parts = parts,
            .weight_indices = indices,
            .channel_offsets = offsets,
            .defaults = defaults,
            .joint_nodes = joints,
            .inverse_bind = inverse_bind,
        };

        LodGroup group = scene::create_animated_lod_group(
            allocator: allocator,
            desc: layout,
            binding: binding,
            capacity: source.crowd ? (uint)source.crowd.placements.len : 0,
        )!;

        if (source.crowd) group.state.effects.trace = source.crowd.trace;

        return group;
    };
}

fn void initialize_animated_lod_source(LodGroupState* state, AnimatedLodSource source) @local {
    if (!source.crowd) {
        state.count = 1;
        return;
    }

    scene::publish_crowd_lod_source(source.scene, state, source.crowd);
}

<*
 Check a published source without changing scene or asset data.
 @param [&in] assets : "Resolves the admitted source and representations."
 @param [&in] scene : "Owns the current source components."
 @param [&in] owner : "Node carrying the copied group."
 @param [&in] state : "Previously admitted and published source snapshot."
*>
fn bool animated_lod_source_is_live(
    AssetStore* assets,
    Scene* scene,
    Node* owner,
    LodGroupState* state,
) {
    AnimatedLodSource? candidate = animated_lod_source(assets, scene, owner);
    if (catch excuse = candidate) return false;
    AnimatedLodSource source = candidate;

    AnimatedLodBinding* binding = state.animated;
    if (!c3d::same_id(binding.source_owner, owner.id)
      || !c3d::same_id(binding.source_model, source.instance ? source.instance.source : source.crowd.model)
      || binding.model_revision != source.model.header.revision) return false;

    if (source.instance && state.mode != LodMode.SINGLE) return false;

    if (source.crowd) {
        if (state.transforms.ptr != source.crowd.placements.ptr || state.colors.ptr != source.crowd.colors.ptr) return false;
        if (state.count != (source.crowd.is_prepared() ? source.crowd.count : 0)) return false;
    }

    return true;
}
