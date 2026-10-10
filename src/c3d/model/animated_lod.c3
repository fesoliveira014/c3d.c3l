module c3d::model;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
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

<* Attach copied alternatives; playback and source components remain owned by the model. *>
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
    scene.add(owner, group);
}

<* Replace only the descriptor after complete validation and allocation. *>
fn void? replace_animated_lod(
    AssetStore* assets,
    Scene* scene,
    Node* owner,
    AnimatedLodDesc desc,
) {
    AnimatedLodSource source = animated_lod_source(assets, scene, owner)!;
    LodGroup* existing = scene.get(owner, LodGroup);
    if (!existing || !existing.state.animated) return c3d::INVALID_ARGUMENT~;

    LodGroup next = build_animated_lod(
        allocator: scene.allocator,
        assets: assets,
        source: source,
        desc: desc,
    )!;
    next.state.effects = existing.state.effects;
    initialize_animated_lod_source(next.state, source);
    LodGroup previous = *existing;
    *existing = next;

    scene::destroy_lod_group(scene.allocator, &previous);
}

<* Reacquire source data; admitted bind/channel invariants are rescanned only after asset changes. *>
fn void? sync_animated_lod(AssetStore* assets, Scene* scene, Node* owner) {
    AnimatedLodSource source = animated_lod_source(assets, scene, owner)!;
    LodGroup* group = scene.get(owner, LodGroup);
    if (!group || !group.state.animated) return c3d::INVALID_ARGUMENT~;
    AnimatedLodBinding* binding = group.state.animated;
    if (source.crowd && group.state.slot_generations.len != source.crowd.placements.len) {
        return c3d::INVALID_ARGUMENT~;
    }

    if (!c3d::same_id(binding.source_owner, owner.id)
      || !c3d::same_id(binding.source_model, source.instance ? source.instance.source : source.crowd.model)) {
        return c3d::INVALID_ARGUMENT~;
    }

    bool changed = binding.model_revision != source.model.header.revision;
    foreach (index, &part : binding.parts) {
        GeometryAsset* geometry = assets.geometries.try_get(group.state.desc.parts[index].geometry)!;
        validate_material(
            assets: assets,
            material_id: group.state.desc.parts[index].material,
            mode: group.state.mode,
            bounds_override: group.state.desc.has_bounds_override,
        )!;
        changed |= part.geometry_revision != geometry.header.revision;
        if (part.source_skeleton.generation) {
            SkeletonAsset* source_skeleton = assets.skeletons.try_get(part.source_skeleton)!;
            changed |= part.source_skeleton_revision != source_skeleton.header.revision;
        }
        if (part.skeleton.generation) {
            SkeletonAsset* skeleton = assets.skeletons.try_get(part.skeleton)!;
            changed |= part.skeleton_revision != skeleton.header.revision;
        }
    }
    if (changed) validate_animated_lod_binding(assets, source, group.state)!;

    initialize_animated_lod_source(group.state, source);
}

fn AnimatedLodSource? animated_lod_source(AssetStore* assets, Scene* scene, Node* owner) @local {
    if (!owner || !scene.world.is_alive(owner.id)) return c3d::INVALID_ID~;
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
    foreach (index, node : template.nodes) {
        if (node.parent < -1 || node.parent >= (int)index) return c3d::INVALID_ARGUMENT~;
    }
    foreach (index, mesh : template.meshes) {
        if (mesh.node >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
        foreach (previous : template.meshes[:index]) {
            if (previous.node == mesh.node) return c3d::INVALID_ARGUMENT~;
        }
        GeometryAsset* geometry = assets.geometries.try_get(mesh.geometry)!;
        assets.materials.try_get(mesh.material)!;
        float[] defaults = source_defaults(source, (uint)index);
        if (defaults.len != weight_width(geometry)) return c3d::INVALID_ARGUMENT~;
        foreach (weight : defaults) {
            if (!math::is_finite(weight)) return c3d::INVALID_ARGUMENT~;
        }
        foreach (channel_index, channel : geometry.data.channels) {
            if (!channel.name.len) continue;
            foreach (previous : geometry.data.channels[:channel_index]) {
                if (channel.name == previous.name) return c3d::INVALID_ARGUMENT~;
            }
        }
        if (geometry_is_skinned(geometry) && !skin_at(template, mesh.node)) return c3d::INVALID_ARGUMENT~;
    }
    if (!template.skins.len) return;

    ModelSkin first = template.skins[0];
    Skeleton* skeleton = &assets.skeletons.try_get(first.skeleton)!.data;
    foreach (skin : template.skins) {
        bool mesh_exists;
        foreach (mesh : template.meshes) mesh_exists |= mesh.node == skin.mesh_node;
        if (!mesh_exists) return c3d::INVALID_ARGUMENT~;
        validate_shared_skin(
            assets: assets,
            template: template,
            skin: skin,
            expected_nodes: first.joint_nodes,
            expected_bind: skeleton.inverse_bind,
        )!;
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

fn void? validate_material(
    AssetStore* assets,
    MaterialId material_id,
    LodMode mode,
    bool bounds_override,
) @local {
    Material* material = &assets.materials.try_get(material_id)!.data;
    if (material.kind != MaterialKind.CUSTOM) return;
    CustomVertex* vertex = &assets.shaders.try_get(material.custom.shader)!.desc.vertex;
    if (vertex.shaded.len && (!bounds_override
      || (mode == LodMode.INSTANCED && !vertex.instanced_shaded.len))) return c3d::UNSUPPORTED~;
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
        String[] names = alloc::new_array_try(tmem, String, (sz)logical_count)
          ?? c3d::CAPACITY_EXCEEDED~!;
        float[] defaults = alloc::new_array_try(tmem, float, (sz)logical_count)
          ?? c3d::CAPACITY_EXCEEDED~!;
        foreach (index, mesh : template.meshes) {
            GeometryAsset* geometry = assets.geometry(mesh.geometry);
            float[] baseline = source_defaults(source, (uint)index);
            defaults[offsets[index]:baseline.len] = baseline[..];
            foreach (weight, channel : geometry.data.channels) names[offsets[index] + weight] = channel.name;
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
                validate_material(
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
            .channel_names = names,
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
    AnimatedCrowd* crowd = source.crowd;
    state.transforms = crowd.placements;
    state.colors = crowd.colors;
    uint count = crowd.is_prepared() ? crowd.count : 0;
    ulong epoch = crowd.playback ? crowd.playback.identity : 1;
    uint revision;
    if (crowd.parts.len) revision = source.scene.world.get(crowd.parts[0].batch, InstancedMesh).revision;
    bool changed = state.count != count || state.instance_epoch != epoch
      || state.animated.source_revision != revision;
    state.animated.source_revision = revision;
    state.count = count;
    state.instance_epoch = epoch;
    if (crowd.playback) {
        foreach (index, slot : crowd.playback.slots) {
            changed |= state.slot_generations[index] != slot.generation;
            state.slot_generations[index] = slot.generation;
        }
    }
    if (changed) scene::publish_animated_lod_source(state);
}

fn void? validate_animated_lod_binding(
    AssetStore* assets,
    AnimatedLodSource source,
    LodGroupState* state,
) @local {
    validate_source_shape(assets, source)!;
    AnimatedLodBinding* binding = state.animated;
    ModelTemplate* template = &source.model.data;
    if (binding.channel_offsets.len != template.meshes.len + 1) return c3d::INVALID_ARGUMENT~;
    foreach (skin : template.skins) {
        validate_shared_skin(
            assets: assets,
            template: template,
            skin: skin,
            expected_nodes: binding.joint_nodes,
            expected_bind: binding.inverse_bind,
        )!;
    }
    foreach (index, mesh : template.meshes) {
        GeometryAsset* base = assets.geometry(mesh.geometry);
        float[] baseline = source_defaults(source, (uint)index);
        uint first = binding.channel_offsets[index];
        uint last = binding.channel_offsets[index + 1];
        if (baseline.len != last - first) return c3d::INVALID_ARGUMENT~;
        for (uint weight = 0; weight < baseline.len; weight++) {
            String name = base.data.channels.len ? base.data.channels[weight].name : "";
            if (name != binding.channel_names[first + weight]) return c3d::INVALID_ARGUMENT~;
        }
        if (baseline.len && !mem::equals(baseline.ptr, binding.defaults[first:baseline.len].ptr, (sz)(baseline.len * float::size))) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    foreach (index, part : binding.parts) {
        if (part.mesh_index >= template.meshes.len || template.meshes[part.mesh_index].node != part.template_node) {
            return c3d::INVALID_ARGUMENT~;
        }
        GeometryAsset* selected = assets.geometries.try_get(state.desc.parts[index].geometry)!;
        GeometryAsset* base = assets.geometries.try_get(template.meshes[part.mesh_index].geometry)!;
        if (geometry_is_skinned(selected) != part.skinned || weight_width(selected) != part.weight_count) {
            return c3d::INVALID_ARGUMENT~;
        }
        for (uint weight = 0; weight < part.weight_count; weight++) {
            if (mapped_weight(base, selected, weight)! != binding.weight_indices[part.weight_offset + weight]) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
        if (part.skeleton.generation) {
            validate_shared_skin(
                assets: assets,
                template: template,
                skin: { .mesh_node = part.template_node, .skeleton = part.skeleton, .joint_nodes = binding.joint_nodes },
                expected_nodes: binding.joint_nodes,
                expected_bind: binding.inverse_bind,
            )!;
        }
    }
    binding.model_revision = source.model.header.revision;
    foreach (index, &part : binding.parts) {
        part.geometry_revision = assets.geometry(state.desc.parts[index].geometry).header.revision;
        if (part.source_skeleton.generation) {
            part.source_skeleton_revision = assets.skeleton(part.source_skeleton).header.revision;
        }
        if (part.skeleton.generation) part.skeleton_revision = assets.skeleton(part.skeleton).header.revision;
    }
}
