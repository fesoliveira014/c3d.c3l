module c3d::serial;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

const ulong INSTANCES_LAYOUT @local = 0x59d3aec48200fec8;
const ulong BILLBOARDS_LAYOUT @local = 0x0e6e17ed81a957bb;
const ulong LOD_V1_LAYOUT @local = 0xdb17924ea7b43e3f;
const ulong LOD_LAYOUT @local = 0x6927e4cf1a630b85;
const ulong ANIMATED_LOD_SKIN_LAYOUT @local = 0x084cf13a5d7629eb;
const ulong ANIMATED_LOD_PART_LAYOUT @local = 0xc8346be859102f7a;
const ulong ANIMATED_LOD_DESC_LAYOUT @local = 0x25fe0b941ac7d683;

struct InstanceAuthoring @private {
    GeometryId geometry;
    MaterialId material;
    uint capacity;
    Transform[] transforms;
    Vec4[] colors;
    bool cast_shadow;
    bool receive_shadow;
    bool trace;
    bool has_bounds_override;
    Aabb local_bounds;
    InstanceSway sway;
    InstanceFade fade;
}

struct BillboardAuthoring @private {
    MaterialId material;
    uint capacity;
    BillboardFacing facing;
    Billboard[] billboards;
}

struct LodAuthoringV1 @private {
    LodDesc desc;
    LodMode mode;
    uint capacity;
    Transform[] transforms;
    Vec4[] colors;
    LodEffects effects;
    bool has_impostor;
    Impostor impostor;
    float impostor_min_screen_size;
}

struct LodAuthoring @private {
    LodDesc desc;
    LodMode mode;
    uint capacity;
    Transform[] transforms;
    Vec4[] colors;
    LodEffects effects;
    bool has_impostor;
    Impostor impostor;
    float impostor_min_screen_size;
    bool animated;
    Entity source_owner;
    AnimatedLodDesc animated_desc;
}

BinaryCompatibility[1] lod_binary_compatibility @local = {
    { .version = 1, .read = &read_lod_v1 },
};
uint[1] lod_text_default_versions @local = { 1 };

fn void? register_core_batch_codecs() @private {
    describe::register_reflected(InstanceAuthoring)!;
    describe::register_reflected(BillboardAuthoring)!;
    describe::register_reflected(LodAuthoringV1)!;
    describe::register_reflected(ModelSkin)!;
    describe::register_reflected(AnimatedLodPart)!;
    describe::register_reflected(AnimatedLodDesc)!;
    describe::register_reflected(LodAuthoring)!;

    register_core_value(InstanceAuthoring, INSTANCES_LAYOUT, &defaults_instances)!;
    register_core_value(BillboardAuthoring, BILLBOARDS_LAYOUT, &defaults_billboards)!;
    register_core_value(LodAuthoringV1, LOD_V1_LAYOUT, &defaults_lod_v1)!;
    register_core_value(ModelSkin, ANIMATED_LOD_SKIN_LAYOUT, &defaults_animated_lod_skin)!;
    register_core_value(AnimatedLodPart, ANIMATED_LOD_PART_LAYOUT, &defaults_animated_lod_part)!;
    register_core_value(AnimatedLodDesc, ANIMATED_LOD_DESC_LAYOUT, &defaults_animated_lod_desc)!;
    register_described_type(
        $Type: LodAuthoring,
        version: 2,
        layout: LOD_LAYOUT,
        defaults: &defaults_lod,
    )!;

    register_described_owner(InstancedMesh, InstanceAuthoring, {
        .name = "c3d.InstancedMesh", .project = &project_instances, .attach = &attach_instances,
    })!;
    register_described_owner(BillboardBatch, BillboardAuthoring, {
        .name = "c3d.BillboardBatch", .project = &project_billboards, .attach = &attach_billboards,
    })!;
    register_described_owner(LodGroup, LodAuthoring, {
        .name = "c3d.LodGroup",
        .phase = BINDINGS,
        .project = &project_lod,
        .attach = &attach_lod,
        .binary_compatibility = lod_binary_compatibility[..],
        .text_default_versions = lod_text_default_versions[..],
    })!;
}

fn void defaults_instances(void* value) @local {
    *(InstanceAuthoring*)value = { .capacity = 1, .cast_shadow = true, .receive_shadow = true, .trace = true };
}

fn void defaults_billboards(void* value) @local {
    *(BillboardAuthoring*)value = { .capacity = 1 };
}

fn void defaults_lod_v1(void* value) @local {
    *(LodAuthoringV1*)value = { .effects = { .cast_shadow = true, .receive_shadow = true, .trace = true } };
}

fn void defaults_animated_lod_skin(void* value) @local {
    *(ModelSkin*)value = {};
}

fn void defaults_animated_lod_part(void* value) @local {
    *(AnimatedLodPart*)value = { .draw = { .local = matrix::IDENTITY4 } };
}

fn void defaults_animated_lod_desc(void* value) @local {
    *(AnimatedLodDesc*)value = {};
}

fn void defaults_lod(void* value) @local {
    *(LodAuthoring*)value = { .effects = { .cast_shadow = true, .receive_shadow = true, .trace = true } };
}

fn void? project_instances(void* component, void* value, WriteContext* context) @local {
    InstancedMesh* batch = component;
    if (!scene::instance_effects_valid(batch.sway, batch.fade)) return c3d::INVALID_ARGUMENT~;
    *(InstanceAuthoring*)value = {
        .geometry = batch.geometry,
        .material = batch.material,
        .capacity = (uint)batch.transforms.len,
        .transforms = batch.transforms[:batch.count],
        .colors = batch.colors[:batch.count],
        .cast_shadow = batch.cast_shadow,
        .receive_shadow = batch.receive_shadow,
        .trace = batch.trace,
        .has_bounds_override = batch.has_bounds_override,
        .local_bounds = batch.local_bounds,
        .sway = batch.sway,
        .fade = batch.fade,
    };
}

fn void? project_billboards(void* component, void* value, WriteContext* context) @local {
    BillboardBatch* batch = component;
    if (!scene::billboards_valid(batch.billboards[:batch.count])) return c3d::INVALID_ARGUMENT~;
    *(BillboardAuthoring*)value = {
        .material = batch.material,
        .capacity = (uint)batch.billboards.len,
        .facing = batch.facing,
        .billboards = batch.billboards[:batch.count],
    };
}

fn void? project_lod(void* component, void* value, WriteContext* context) @local {
    LodGroupState* state = ((LodGroup*)component).state;
    if (!scene::instance_effects_valid(state.effects.sway, state.effects.fade)) return c3d::INVALID_ARGUMENT~;

    if (state.animated) {
        *(LodAuthoring*)value = {
            .effects = state.effects,
            .animated = true,
            .source_owner = state.animated.source_owner,
            .animated_desc = project_animated_lod(state, context)!,
        };
        return;
    }

    scene::validate_lod_desc(context.assets, state.desc, state.mode)!;
    *(LodAuthoring*)value = {
        .desc = state.desc,
        .mode = state.mode,
        .capacity = (uint)state.transforms.len,
        .transforms = state.mode == INSTANCED ? state.transforms[:state.count] : (Transform[]) {},
        .colors = state.mode == INSTANCED ? state.colors[:state.count] : (Vec4[]) {},
        .effects = state.effects,
        .has_impostor = state.has_impostor,
        .impostor = state.impostor,
        .impostor_min_screen_size = state.impostor_min_screen_size,
    };
}

fn void? attach_instances(void* value, ReadContext* context) @local {
    InstanceAuthoring* source = value;
    if (!source.capacity || source.transforms.len > source.capacity || source.colors.len > source.transforms.len) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!scene::instance_effects_valid(source.sway, source.fade)) return c3d::INVALID_ARGUMENT~;
    Allocator allocator = context.scene.allocator;
    Transform[] transforms = alloc::new_array_try(allocator, Transform, (sz)source.capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, transforms.ptr);
    Vec4[] colors = alloc::new_array_try(allocator, Vec4, (sz)source.capacity) ?? c3d::CAPACITY_EXCEEDED~!;
    transforms[..] = maths::TRANSFORM_IDENTITY;
    colors[..] = (Vec4){ 1, 1, 1, 1 };
    transforms[:source.transforms.len] = source.transforms[..];
    colors[:source.colors.len] = source.colors[..];
    context.scene.add(context.node, (InstancedMesh){
        .geometry = source.geometry,
        .material = source.material,
        .transforms = transforms,
        .colors = colors,
        .count = (uint)source.transforms.len,
        .cast_shadow = source.cast_shadow,
        .receive_shadow = source.receive_shadow,
        .trace = source.trace,
        .has_bounds_override = source.has_bounds_override,
        .local_bounds = source.local_bounds,
        .sway = source.sway,
        .fade = source.fade,
        .revision = 1,
    });
}

fn void? attach_billboards(void* value, ReadContext* context) @local {
    BillboardAuthoring* source = value;
    if (!source.capacity || source.billboards.len > source.capacity) return c3d::INVALID_ARGUMENT~;
    if (!scene::billboards_valid(source.billboards)) return c3d::INVALID_ARGUMENT~;
    Billboard[] entries = alloc::new_array_try(context.scene.allocator, Billboard, (sz)source.capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    context.scene.add(context.node, (BillboardBatch){
        .material = source.material,
        .facing = source.facing,
        .billboards = entries,
        .revision = 1,
    });
    defer catch context.scene.remove_component(context.node, BillboardBatch);
    entries[..] = scene::BILLBOARD_DEFAULT;
    context.scene.set_billboards(context.node, source.billboards)!;
}

fn void? attach_lod(void* value, ReadContext* context) @local {
    LodAuthoring* source = value;
    if (source.animated) {
        if (!c3d::same_id(source.source_owner, context.node.id) || source.has_impostor
          || source.capacity || source.transforms.len || source.colors.len || source.desc.levels.len
          || source.desc.parts.len) return c3d::INVALID_ARGUMENT~;
        if (!scene::instance_effects_valid(source.effects.sway, source.effects.fade)) return c3d::INVALID_ARGUMENT~;

        model::attach_animated_lod(
            assets: context.assets,
            scene: context.scene,
            owner: context.node,
            desc: source.animated_desc,
        )!;
        context.scene.set_lod_effects(context.node, source.effects);
        return;
    }

    if (source.source_owner.generation || source.animated_desc.levels.len || source.animated_desc.parts.len) {
        return c3d::INVALID_ARGUMENT~;
    }

    if (source.mode == SINGLE) {
        if (source.capacity || source.transforms.len || source.colors.len) return c3d::INVALID_ARGUMENT~;
    } else if (!source.capacity || source.transforms.len > source.capacity) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!scene::instance_effects_valid(source.effects.sway, source.effects.fade)) return c3d::INVALID_ARGUMENT~;
    LodGroup group = scene::create_lod_group(
        allocator: context.scene.allocator,
        assets: context.assets,
        desc: source.desc,
        capacity: source.capacity,
    )!;
    context.scene.add(context.node, group);
    defer catch context.scene.remove_component(context.node, LodGroup);
    if (source.mode == INSTANCED) {
        context.scene.set_lod_instances(context.node, source.transforms, source.colors)!;
    }
    context.scene.set_lod_effects(context.node, source.effects);
    if (source.has_impostor) {
        context.scene.set_lod_impostor(
            assets: context.assets,
            node: context.node,
            impostor: source.impostor,
            min_screen_size: source.impostor_min_screen_size,
        )!;
    }
}

fn AnimatedLodDesc? project_animated_lod(LodGroupState* state, WriteContext* context) @local {
    AnimatedLodBinding* binding = state.animated;
    if (!c3d::same_id(binding.source_owner, context.node.id) || state.has_impostor) {
        return c3d::INVALID_ARGUMENT~;
    }
    context.assets.models.try_get(binding.source_model)!;

    AnimatedLodPart[] parts = alloc::new_array_try(tmem, AnimatedLodPart, state.desc.parts.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    foreach (index, &part : parts) {
        AnimatedLodPartBinding* admitted = &binding.parts[index];
        context.assets.geometries.try_get(state.desc.parts[index].geometry)!;
        context.assets.materials.try_get(state.desc.parts[index].material)!;
        if (admitted.skinned) context.assets.skeletons.try_get(admitted.skeleton)!;

        float[] defaults = alloc::new_array_try(tmem, float, admitted.weight_count)
          ?? c3d::CAPACITY_EXCEEDED~!;
        foreach (weight, &value : defaults) {
            uint logical = binding.weight_indices[admitted.weight_offset + weight];
            *value = binding.defaults[binding.channel_offsets[admitted.mesh_index] + logical];
        }

        *part = {
            .draw = state.desc.parts[index],
            .mesh_index = admitted.mesh_index,
            .skin = admitted.skinned ? (ModelSkin){
                .mesh_node = admitted.template_node,
                .skeleton = admitted.skeleton,
                .joint_nodes = binding.joint_nodes,
            } : (ModelSkin){},
            .default_morph_weights = defaults,
        };
    }

    return {
        .levels = state.desc.levels,
        .parts = parts,
        .has_bounds_override = state.mode == SINGLE && state.desc.has_bounds_override,
        .local_bounds = state.mode == SINGLE ? state.desc.local_bounds : (Aabb){},
    };
}

fn void? read_lod_v1(Reader* reader, ReadContext* context) @local {
    LodAuthoringV1 legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();

    read_described_value(
        type: described_type(LodAuthoringV1)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;

    LodAuthoring source = {
        .desc = legacy.desc,
        .mode = legacy.mode,
        .capacity = legacy.capacity,
        .transforms = legacy.transforms,
        .colors = legacy.colors,
        .effects = legacy.effects,
        .has_impostor = legacy.has_impostor,
        .impostor = legacy.impostor,
        .impostor_min_screen_size = legacy.impostor_min_screen_size,
    };

    attach_lod(&source, context)!;
}
