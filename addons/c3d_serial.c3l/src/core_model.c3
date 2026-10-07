module c3d::serial;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

const ulong MODEL_MESH_LAYOUT @local = 0x8f6dc559d5c94149;
const ulong MODEL_SKIN_LAYOUT @local = 0xc991f818eff08d05;
const ulong MODEL_SIGNATURE_LAYOUT @local = 0x90a76547fe77d954;
const ulong MORPH_BASELINE_LAYOUT @local = 0xed25f1e3932180db;
const ulong MODEL_AUTHORING_LAYOUT @local = 0xaba8fe418addb2df;

struct ModelMeshSignature @private {
    uint slot;
    GeometryId geometry;
    MaterialId material;
    uint morph_targets;
}

struct ModelSkinSignature @private {
    uint slot;
    SkeletonId skeleton;
    uint skeleton_joints;
    uint[] joints;
}

struct ModelNodeSignature @private {
    int parent;
    ModelMeshSignature[] meshes;
    ModelSkinSignature[] skins;
    LodDesc[] lod;
}

struct MorphBaseline @private {
    float[] weights;
}

struct ModelAuthoring @private {
    ModelId source;
    ModelNodeSignature[] signature;
    Entity[] nodes;
    uint[] absent;
    Transform[] base_pose;
    uint[] mesh_nodes;
    MorphBaseline[] base_morph_weights;
    ClipId[] clips;
}

fn void? register_model_codec() @private {
    describe::register_reflected(ModelMeshSignature)!;
    describe::register_reflected(ModelSkinSignature)!;
    describe::register_reflected(ModelNodeSignature)!;
    describe::register_reflected(MorphBaseline)!;
    describe::register_reflected(ModelAuthoring)!;
    register_core_value(ModelMeshSignature, MODEL_MESH_LAYOUT, &defaults_model_mesh)!;
    register_core_value(ModelSkinSignature, MODEL_SKIN_LAYOUT, &defaults_model_skin)!;
    register_core_value(ModelNodeSignature, MODEL_SIGNATURE_LAYOUT, &defaults_model_signature)!;
    register_core_value(MorphBaseline, MORPH_BASELINE_LAYOUT, &defaults_morph_baseline)!;
    register_core_value(ModelAuthoring, MODEL_AUTHORING_LAYOUT, &defaults_model_authoring)!;
    register_described_owner(ModelInstance, ModelAuthoring, {
        .name = "c3d.ModelInstance",
        .phase = REFERENCES,
        .project = &project_model,
        .validate = &validate_model,
        .attach = &attach_model,
    })!;
}

fn void defaults_model_mesh(void* value) @local {
    *(ModelMeshSignature*)value = {};
}

fn void defaults_model_skin(void* value) @local {
    *(ModelSkinSignature*)value = {};
}

fn void defaults_model_signature(void* value) @local {
    *(ModelNodeSignature*)value = { .parent = -1 };
}

fn void defaults_morph_baseline(void* value) @local {
    *(MorphBaseline*)value = {};
}

fn void defaults_model_authoring(void* value) @local {
    *(ModelAuthoring*)value = {};
}

fn ModelNodeSignature? model_node_signature(
    AssetStore* assets,
    ModelTemplate* template,
    uint index,
) @local {
    ModelNodeSignature result = { .parent = template.nodes[index].parent };
    uint mesh_count;
    uint skin_count;
    foreach (mesh : template.meshes) if (mesh.node == index) mesh_count++;
    foreach (skin : template.skins) if (skin.mesh_node == index) skin_count++;
    result.meshes = alloc::new_array_try(tmem, ModelMeshSignature, mesh_count) ?? c3d::CAPACITY_EXCEEDED~!;
    result.skins = alloc::new_array_try(tmem, ModelSkinSignature, skin_count) ?? c3d::CAPACITY_EXCEEDED~!;
    uint mesh_entry;
    foreach (mesh_slot, mesh : template.meshes) {
        if (mesh.node != index) continue;
        result.meshes[mesh_entry++] = {
            .slot = (uint)mesh_slot, .geometry = mesh.geometry, .material = mesh.material,
            .morph_targets = assets.geometries.try_get(mesh.geometry)!.target_count,
        };
    }
    uint skin_entry;
    foreach (skin_slot, skin : template.skins) {
        if (skin.mesh_node != index) continue;
        result.skins[skin_entry++] = {
            .slot = (uint)skin_slot, .skeleton = skin.skeleton,
            .skeleton_joints = (uint)assets.skeletons.try_get(skin.skeleton)!.data.parents.len,
            .joints = skin.joint_nodes,
        };
    }
    foreach (&group : template.lod_groups) {
        if (group.node == index) result.lod = (&group.desc)[:1];
    }
    return result;
}

fn bool same_model_signature(ModelNodeSignature* first, ModelNodeSignature* second) @local {
    if (first.parent != second.parent || first.meshes.len != second.meshes.len
        || first.skins.len != second.skins.len || first.lod.len != second.lod.len) return false;
    foreach (index, mesh : first.meshes) {
        ModelMeshSignature other = second.meshes[index];
        if (mesh.slot != other.slot || !c3d::same_id(mesh.geometry, other.geometry)
            || !c3d::same_id(mesh.material, other.material) || mesh.morph_targets != other.morph_targets) return false;
    }
    foreach (index, skin : first.skins) {
        ModelSkinSignature other = second.skins[index];
        if (skin.slot != other.slot || !c3d::same_id(skin.skeleton, other.skeleton)
            || skin.skeleton_joints != other.skeleton_joints || skin.joints != other.joints) return false;
    }
    if (!first.lod.len) return true;
    LodDesc* first_lod = &first.lod[0];
    LodDesc* second_lod = &second.lod[0];
    if (first_lod.levels.len != second_lod.levels.len || first_lod.parts.len != second_lod.parts.len
        || first_lod.has_bounds_override != second_lod.has_bounds_override) return false;
    foreach (index, level : first_lod.levels) {
        LodLevel other = second_lod.levels[index];
        if (level.first_part != other.first_part || level.part_count != other.part_count
            || bitcast(level.min_screen_size, uint) != bitcast(other.min_screen_size, uint)) return false;
    }
    foreach (index, part : first_lod.parts) {
        LodPart other = second_lod.parts[index];
        if (!c3d::same_id(part.geometry, other.geometry) || !c3d::same_id(part.material, other.material)) return false;
        for (uint coefficient = 0; coefficient < 16; coefficient++) {
            if (bitcast(part.local.m[coefficient], uint) != bitcast(other.local.m[coefficient], uint)) return false;
        }
    }
    for (uint axis = 0; axis < 3; axis++) {
        if (bitcast(first_lod.local_bounds.min[axis], uint) != bitcast(second_lod.local_bounds.min[axis], uint)
            || bitcast(first_lod.local_bounds.max[axis], uint) != bitcast(second_lod.local_bounds.max[axis], uint)) {
            return false;
        }
    }
    return true;
}

fn void? project_model(void* component, void* value, WriteContext* context) @local {
    ModelInstance* instance = component;
    ModelTemplate* template = &context.assets.models.try_get(instance.source)!.data;
    if (instance.nodes.len != template.nodes.len || instance.node_entities.len != template.nodes.len
        || instance.base_pose.len != template.nodes.len || instance.mesh_nodes.len != template.meshes.len
        || instance.base_morph_weights.len != template.meshes.len) {
        return model_diagnostic(
            diagnostic: context.diagnostic,
            assets: context.assets,
            model: instance.source,
            index: 0,
            cause: INCOMPATIBLE_TEMPLATE,
        )~;
    }
    ModelNodeSignature[] signature = alloc::new_array_try(tmem, ModelNodeSignature, template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    Entity[] nodes = alloc::new_array_try(tmem, Entity, template.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    uint[] absent = alloc::new_array_try(tmem, uint, template.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    MorphBaseline[] morph = alloc::new_array_try(tmem, MorphBaseline, template.meshes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    uint absent_count;
    foreach (usz index, &entry : signature) {
        *entry = model_node_signature(context.assets, template, (uint)index)!;
        Node* node = instance.present_node(index);
        if (!node) {
            absent[absent_count++] = (uint)index;
            continue;
        }
        Node* ancestor = node.parent;
        while (ancestor && ancestor != context.node) ancestor = ancestor.parent;
        if (!ancestor) return c3d::INVALID_ARGUMENT~;
        (void)projection_of(context, node)!;
        nodes[index] = node.id;
    }
    foreach (index, &entry : morph) {
        ModelMesh* mesh = &template.meshes[index];
        if (instance.mesh_nodes[index] != mesh.node
            || instance.base_morph_weights[index].len != context.assets.geometries.try_get(mesh.geometry)!.target_count) {
            return model_diagnostic(
                diagnostic: context.diagnostic,
                assets: context.assets,
                model: instance.source,
                index: mesh.node,
                cause: INCOMPATIBLE_TEMPLATE,
            )~;
        }
        entry.weights = instance.base_morph_weights[index];
    }
    *(ModelAuthoring*)value = {
        .source = instance.source,
        .signature = signature,
        .nodes = nodes,
        .absent = absent[:absent_count],
        .base_pose = instance.base_pose,
        .mesh_nodes = instance.mesh_nodes,
        .base_morph_weights = morph,
        .clips = instance.clips,
    };
}

fn void? validate_model(void* value, ReadContext* context) @private {
    ModelAuthoring* source = value;
    ModelTemplate* template = &context.assets.models.try_get(source.source)!.data;
    if (source.signature.len != template.nodes.len) {
        return model_diagnostic(
            diagnostic: context.diagnostic,
            assets: context.assets,
            model: source.source,
            index: (uint)math::min(source.signature.len, template.nodes.len),
            cause: INCOMPATIBLE_TEMPLATE,
        )~;
    }
    if (source.nodes.len != source.signature.len || source.base_pose.len != source.signature.len
        || source.mesh_nodes.len != template.meshes.len || source.base_morph_weights.len != template.meshes.len) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    foreach (index, &saved : source.signature) {
        ModelNodeSignature current = model_node_signature(context.assets, template, (uint)index)!;
        if (!same_model_signature(saved, &current)) {
            return model_diagnostic(
                diagnostic: context.diagnostic,
                assets: context.assets,
                model: source.source,
                index: (uint)index,
                cause: INCOMPATIBLE_TEMPLATE,
            )~;
        }
    }
    foreach (index, mesh : template.meshes) {
        if (source.mesh_nodes[index] != mesh.node
            || source.base_morph_weights[index].weights.len != context.assets.geometries.try_get(mesh.geometry)!.target_count) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
    }
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();
    bool* absent = owned.acquire(source.nodes.len, bool::size, bool::alignment)!;
    foreach (index : source.absent) {
        if (index >= source.nodes.len || absent[index]) return c3d::ASSET_FORMAT_ERROR~;
        absent[index] = true;
    }
    foreach (index, entity : source.nodes) {
        if (absent[index] != !entity.generation) return c3d::ASSET_FORMAT_ERROR~;
        if (!entity.generation) continue;
        Node* node = context.scene.node(entity);
        Node* ancestor = node.parent;
        while (ancestor && ancestor != context.node) ancestor = ancestor.parent;
        if (!ancestor) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? attach_model(void* value, ReadContext* context) @local {
    ModelAuthoring* source = value;
    Allocator allocator = context.scene.allocator;
    ModelInstance instance = { .source = source.source };
    defer catch {
        foreach (weights : instance.base_morph_weights) alloc::free(allocator, weights.ptr);
        alloc::free(allocator, instance.base_morph_weights.ptr);
        alloc::free(allocator, instance.nodes.ptr);
        alloc::free(allocator, instance.node_entities.ptr);
        alloc::free(allocator, instance.base_pose.ptr);
        alloc::free(allocator, instance.mesh_nodes.ptr);
        alloc::free(allocator, instance.clips.ptr);
    }
    instance.nodes = alloc::new_array_try(allocator, Node*, source.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    instance.node_entities = copy_model_slice(allocator, source.nodes)!;
    instance.base_pose = copy_model_slice(allocator, source.base_pose)!;
    instance.mesh_nodes = copy_model_slice(allocator, source.mesh_nodes)!;
    instance.clips = copy_model_slice(allocator, source.clips)!;
    instance.base_morph_weights = alloc::new_array_try(allocator, float[], source.base_morph_weights.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, entity : source.nodes) {
        if (entity.generation) instance.nodes[index] = context.scene.node(entity);
    }
    foreach (index, morph : source.base_morph_weights) {
        instance.base_morph_weights[index] = copy_model_slice(allocator, morph.weights)!;
    }
    context.scene.add(context.node, instance);
}

macro copy_model_slice(Allocator allocator, slice) @local {
    var $Element = $Typeof(slice[0]);
    $Element[] copy = alloc::new_array_try(allocator, $Element, slice.len) ?? c3d::CAPACITY_EXCEEDED~!;
    copy[..] = slice[..];
    return copy;
}
