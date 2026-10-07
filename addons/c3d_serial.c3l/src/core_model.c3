module c3d::serial;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

const ulong MODEL_SIGNATURE_LAYOUT @local = 0x3a25f0a009df0545;
const ulong MORPH_BASELINE_LAYOUT @local = 0xed25f1e3932180db;
const ulong MODEL_AUTHORING_LAYOUT @local = 0x95952b5d313f9752;

struct ModelNodeSignature @private {
    int parent;
    uint mesh_slot;
    GeometryId geometry;
    MaterialId material;
    uint morph_targets;
    SkeletonId skeleton;
    uint skeleton_joints;
    uint[] joints;
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
    describe::register_reflected(ModelNodeSignature)!;
    describe::register_reflected(MorphBaseline)!;
    describe::register_reflected(ModelAuthoring)!;
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

fn void defaults_model_signature(void* value) @local {
    *(ModelNodeSignature*)value = { .parent = -1, .mesh_slot = INDEX_NONE };
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
    ModelNodeSignature result = { .parent = template.nodes[index].parent, .mesh_slot = INDEX_NONE };
    foreach (mesh_slot, mesh : template.meshes) {
        if (mesh.node != index) continue;
        result.mesh_slot = (uint)mesh_slot;
        result.geometry = mesh.geometry;
        result.material = mesh.material;
        result.morph_targets = assets.geometries.try_get(mesh.geometry)!.target_count;
    }
    foreach (skin : template.skins) {
        if (skin.mesh_node != index) continue;
        result.skeleton = skin.skeleton;
        result.skeleton_joints = (uint)assets.skeletons.try_get(skin.skeleton)!.data.parents.len;
        result.joints = skin.joint_nodes;
    }
    foreach (&group : template.lod_groups) {
        if (group.node == index) result.lod = (&group.desc)[:1];
    }
    return result;
}

fn bool same_model_signature(ModelNodeSignature* first, ModelNodeSignature* second) @local {
    if (first.parent != second.parent || first.mesh_slot != second.mesh_slot
        || !c3d::same_id(first.geometry, second.geometry) || !c3d::same_id(first.material, second.material)
        || first.morph_targets != second.morph_targets || !c3d::same_id(first.skeleton, second.skeleton)
        || first.skeleton_joints != second.skeleton_joints || first.joints != second.joints
        || first.lod.len != second.lod.len) return false;
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
            || instance.base_morph_weights[index].len != signature[mesh.node].morph_targets) {
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
            || source.base_morph_weights[index].weights.len != source.signature[mesh.node].morph_targets) {
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
