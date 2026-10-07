module c3d::serial;

import c3d;
import c3d::describe;
import c3d::maths;
import c3d::scene;
import std::math;

const ulong INSTANCES_LAYOUT @local = 0x59d3aec48200fec8;
const ulong BILLBOARDS_LAYOUT @local = 0x0e6e17ed81a957bb;
const ulong LOD_LAYOUT @local = 0xdb17924ea7b43e3f;

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
}

fn void? register_core_batch_codecs() @private {
    describe::register_reflected(InstanceAuthoring)!;
    describe::register_reflected(BillboardAuthoring)!;
    describe::register_reflected(LodAuthoring)!;
    register_core_value(InstanceAuthoring, INSTANCES_LAYOUT, &defaults_instances)!;
    register_core_value(BillboardAuthoring, BILLBOARDS_LAYOUT, &defaults_billboards)!;
    register_core_value(LodAuthoring, LOD_LAYOUT, &defaults_lod)!;
    register_described_owner(InstancedMesh, InstanceAuthoring, {
        .name = "c3d.InstancedMesh", .project = &project_instances, .attach = &attach_instances,
    })!;
    register_described_owner(BillboardBatch, BillboardAuthoring, {
        .name = "c3d.BillboardBatch", .project = &project_billboards, .attach = &attach_billboards,
    })!;
    register_described_owner(LodGroup, LodAuthoring, {
        .name = "c3d.LodGroup", .project = &project_lod, .attach = &attach_lod,
    })!;
}

fn void defaults_instances(void* value) @local {
    *(InstanceAuthoring*)value = { .capacity = 1, .cast_shadow = true, .receive_shadow = true, .trace = true };
}

fn void defaults_billboards(void* value) @local {
    *(BillboardAuthoring*)value = { .capacity = 1 };
}

fn void defaults_lod(void* value) @local {
    *(LodAuthoring*)value = { .effects = { .cast_shadow = true, .receive_shadow = true, .trace = true } };
}

fn void? project_instances(void* component, void* value, WriteContext* context) @local {
    InstancedMesh* batch = component;
    validate_serial_effects(batch.sway, batch.fade)!;
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
    check_serial_billboards(batch.billboards[:batch.count])!;
    *(BillboardAuthoring*)value = {
        .material = batch.material,
        .capacity = (uint)batch.billboards.len,
        .facing = batch.facing,
        .billboards = batch.billboards[:batch.count],
    };
}

fn void? project_lod(void* component, void* value, WriteContext* context) @local {
    LodGroupState* state = ((LodGroup*)component).state;
    scene::validate_lod_desc(context.assets, state.desc, state.mode)!;
    validate_serial_effects(state.effects.sway, state.effects.fade)!;
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
    validate_serial_effects(source.sway, source.fade)!;
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
    check_serial_billboards(source.billboards)!;
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
    if (source.mode == SINGLE) {
        if (source.capacity || source.transforms.len || source.colors.len) return c3d::INVALID_ARGUMENT~;
    } else if (!source.capacity || source.transforms.len > source.capacity) {
        return c3d::INVALID_ARGUMENT~;
    }
    validate_serial_effects(source.effects.sway, source.effects.fade)!;
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

fn void? validate_serial_effects(InstanceSway sway, InstanceFade fade) @local {
    float[4] nonnegative = { sway.amplitude, sway.frequency, sway.wavelength, sway.variation };
    foreach (value : nonnegative) {
        if (!math::is_finite(value) || value < 0) return c3d::INVALID_ARGUMENT~;
    }
    if (sway.amplitude != 0 && !(sway.direction.length() > 0)) return c3d::INVALID_ARGUMENT~;
    if (!(sway.lean >= 0 && sway.lean <= 1)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(fade.end)) return c3d::INVALID_ARGUMENT~;
    if (fade.end != 0 && !(fade.start >= 0 && fade.start < fade.end)) return c3d::INVALID_ARGUMENT~;
}

fn void? check_serial_billboards(Billboard[] billboards) @local {
    foreach (billboard : billboards) {
        for (uint axis = 0; axis < 3; axis++) {
            if (!math::is_finite(billboard.position[axis]) || !math::is_finite(billboard.direction[axis])) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
        foreach (channel : billboard.color) if (!math::is_finite(channel)) return c3d::INVALID_ARGUMENT~;
        if (!math::is_finite(billboard.rotation) || !math::is_finite(billboard.size.x)
            || !math::is_finite(billboard.size.y) || billboard.size.x < 0 || billboard.size.y < 0) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}
