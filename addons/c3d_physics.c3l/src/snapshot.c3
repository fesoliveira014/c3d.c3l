module c3d::physics;

import std::math;
import std::math::quaternion;
import std::hash::fnv64a;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import b3;

const usz  RGBA_CHANNELS @local = 4;
const b3::Transform IDENTITY_FRAME @private = { .q = quaternion::IDENTITY };

<*
 Kind of cooked data a snapshot holds.
*>
enum SnapshotKind {
    HULL,
    MESH,
    HEIGHT_FIELD,
    COMPOUND,
}

<*
 Reference to one snapshot slot; generation 0 names none.
*>
struct SnapshotHandle {
    uint index;
    uint generation;
}

<*
 Asset revision a snapshot was cooked from: a texture for height fields, geometry otherwise.
*>
struct SnapshotSource {
    GeometryId geometry;
    TextureId  texture;
    uint       revision;
}

<*
 Cooked collision data shared by every collider with the same key.
*>
struct CollisionSnapshot {
    SnapshotKind         kind;
    ulong                content;    // hash of component data baked into the box3d object; 0 when none
    Vec3                 scale;      // exact scale baked into a hull variant; zero for unscaled data
    SnapshotSource[]     sources;    // empty for component-sourced data
    b3::HullData*        hull;
    b3::MeshData*        mesh;
    b3::HeightFieldData* height_field;
    b3::CompoundData*    compound;
    Vec3[]               wire;
    uint                 holders;
    uint                 generation; // odd while occupied
}

<*
 Snapshot slots and the allocator the removal hook frees with.
*>
struct SnapshotTable {
    Allocator           allocator;
    CollisionSnapshot[] slots;
    AssetStore*         assets;
    uint                borrowers;
    bool                cache_wireframes;
}

struct SnapshotKey @local {
    SnapshotKind     kind;
    ulong            content;
    Vec3             scale;
    SnapshotSource[] sources;
}

fn SnapshotTable*? create_snapshot_table(Allocator allocator, AssetStore* assets, CollisionCacheDesc desc) @private {
    SnapshotTable* table = alloc::new_try(allocator, SnapshotTable) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, table);
    CollisionSnapshot[] slots;
    if (desc.snapshot_capacity) {
        slots = alloc::new_array_try(allocator, CollisionSnapshot, desc.snapshot_capacity) ?? c3d::CAPACITY_EXCEEDED~!;
    }
    *table = {
        .allocator = allocator,
        .slots = slots,
        .assets = assets,
        .cache_wireframes = desc.cache_wireframes,
    };
    return table;
}

fn void destroy_snapshot_table(SnapshotTable* table) @private {
    foreach (&slot : table.slots) {
        if (is_occupied(slot)) free_snapshot(table, slot);
    }
    Allocator allocator = table.allocator;
    alloc::free(allocator, table.slots.ptr);
    alloc::free(allocator, table);
}

fn CollisionSnapshot* snapshot_of(SnapshotTable* table, SnapshotHandle handle) @private => &table.slots[handle.index];

fn SnapshotHandle? acquire_hull(SnapshotTable* table, GeometryId geometry, bool query = false) @private {
    SnapshotSource[1] sources = { current_source(table, geometry) };
    foreach (usz index, &slot : table.slots) {
        if (matches(slot, { .kind = HULL, .sources = sources[..] })) return hold(table, index);
    }

    Vec3[] positions = table.assets.geometry(geometry).data.positions;
    if (!positions.len) return SOURCE_UNAVAILABLE~;
    if (query) check_collision_hull_source(positions)!;
    usz index = reserve_slot(table)!;
    SnapshotSource[] captured_sources = alloc::new_array_try(table.allocator, SnapshotSource, 1)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(table.allocator, captured_sources.ptr);
    captured_sources[0] = sources[0];
    b3::HullData* hull = b3::create_hull(positions, b3::MAX_HULL_VERTICES)!;
    defer catch b3::destroy_hull(hull);
    Allocator allocator = table.allocator;
    Vec3[] wire;
    if (table.cache_wireframes) {
        wire = alloc::new_array_try(allocator, Vec3, hull.edge_count) ?? c3d::CAPACITY_EXCEEDED~!;
        WireWriter writer = { .points = wire };
        write_hull(&writer, hull, matrix::IDENTITY4);
    }
    return occupy(table, index, {
        .kind    = HULL,
        .sources = captured_sources,
        .hull    = hull,
        .wire    = wire,
    });
}

fn SnapshotHandle? acquire_scaled_hull(SnapshotTable* table, GeometryId geometry, Vec3 scale) @private {
    SnapshotSource[1] sources = { current_source(table, geometry) };
    foreach (usz index, &slot : table.slots) {
        if (matches(slot, { .kind = HULL, .scale = scale, .sources = sources[..] })) return hold(table, index);
    }

    SnapshotHandle unit = acquire_hull(table, geometry, query: true)!;
    defer release_snapshot(table, unit);
    b3::HullData* unit_hull = snapshot_of(table, unit).hull;
    check_collision_hull_scale(unit_hull, scale)!;

    usz index = reserve_slot(table)!;
    SnapshotSource[] captured_sources = alloc::new_array_try(table.allocator, SnapshotSource, 1)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(table.allocator, captured_sources.ptr);
    captured_sources[0] = sources[0];

    b3::HullData* hull = b3::clone_and_transform_hull(unit_hull, IDENTITY_FRAME, scale)!;
    defer catch b3::destroy_hull(hull);

    // Query owners never draw a variant, so it carries no wireframe.
    return occupy(table, index, {
        .kind    = HULL,
        .scale   = scale,
        .sources = captured_sources,
        .hull    = hull,
    });
}

fn SnapshotHandle? acquire_mesh(
    SnapshotTable* table,
    GeometryId geometry,
    char[] material_indices,
    bool query = false,
) @private {
    SnapshotSource[1] sources = { current_source(table, geometry) };
    ulong content = material_indices.len ? fnv64a::hash(material_indices) : 0;
    foreach (usz index, &slot : table.slots) {
        if (matches(slot, { .kind = MESH, .content = content, .sources = sources[..] })) return hold(table, index);
    }

    Geometry* source = &table.assets.geometry(geometry).data;
    if (!source.positions.len) return SOURCE_UNAVAILABLE~;
    if (query) check_collision_mesh_source(source, material_indices)!;
    usz index = reserve_slot(table)!;
    Allocator allocator = table.allocator;
    uint[] indices = source.indices;
    if (!indices.len) indices = sequential_indices(allocator, source.positions.len);
    defer {
        if (indices.ptr != source.indices.ptr) alloc::free(allocator, indices.ptr);
    }
    b3::MeshDef def = {
        .vertices         = source.positions.ptr,
        .indices          = (int*)indices.ptr,
        .material_indices = material_indices.len ? material_indices.ptr : null,
        .vertex_count     = (int)source.positions.len,
        .triangle_count   = (int)(indices.len / 3),
    };
    b3::MeshData* mesh = b3::create_mesh(&def)!;
    Vec3[] wire;
    if (table.cache_wireframes) wire = mesh_wire(allocator, source.positions, indices);
    return occupy(table, index, {
        .kind    = MESH,
        .content = content,
        .sources = copy_sources(allocator, sources[..]),
        .mesh    = mesh,
        .wire    = wire,
    });
}

fn SnapshotHandle? acquire_height_field(SnapshotTable* table, ColliderDesc* desc) @private {
    switch (desc.height_field.source) {
        case HEIGHTS:
            usz index = reserve_slot(table)!;
            CollisionSnapshot snapshot = cook_height_field(table, desc, desc.height_field)!;
            return occupy(table, index, snapshot);
        case TEXTURE:
            return acquire_height_map(table, desc);
    }
}

// Texture sources share one slot per texture revision, scale and material indices, like asset meshes.
// Called inside build_body's @pool: the samples live in tmem until box3d copies them.
fn SnapshotHandle? acquire_height_map(SnapshotTable* table, ColliderDesc* desc) @local {
    TextureId texture = desc.height_field.texture;
    SnapshotSource[1] sources = { current_texture_source(table, texture) };
    Fnv64a hash;
    hash.init();
    @hash_value(&hash, desc.local.scale);
    hash.update(desc.material_indices);
    ulong content = (ulong)hash;
    foreach (usz index, &slot : table.slots) {
        if (matches(slot, { .kind = HEIGHT_FIELD, .content = content, .sources = sources[..] })) {
            return hold(table, index);
        }
    }

    TextureAsset* record = table.assets.texture(texture);
    if (!record.pixels.len) return SOURCE_UNAVAILABLE~;
    usz index = reserve_slot(table)!;
    HeightField samples = {
        .heights = height_map_samples(record, tmem),
        .count_x = record.desc.width,
        .count_z = record.desc.height,
    };
    CollisionSnapshot snapshot = cook_height_field(table, desc, samples)!;
    snapshot.content = content;
    snapshot.sources = copy_sources(table.allocator, sources[..]);
    return occupy(table, index, snapshot);
}

fn CollisionSnapshot? cook_height_field(SnapshotTable* table, ColliderDesc* desc, HeightField field) @local {
    float minimum = field.heights[0];
    float maximum = field.heights[0];
    foreach (height : field.heights) {
        minimum = math::min(minimum, height);
        maximum = math::max(maximum, height);
    }
    b3::HeightFieldDef def = {
        .heights               = field.heights.ptr,
        .material_indices      = desc.material_indices.len ? desc.material_indices.ptr : null,
        .scale                 = desc.local.scale,
        .count_x               = (int)field.count_x,
        .count_z               = (int)field.count_z,
        .global_minimum_height = minimum,
        .global_maximum_height = maximum,
    };
    b3::HeightFieldData* data = b3::create_height_field(&def)!;
    Vec3[] wire;
    if (table.cache_wireframes) wire = height_field_wire(table.allocator, field, desc.local.scale);
    return { .kind = HEIGHT_FIELD, .height_field = data, .wire = wire };
}

fn SnapshotHandle? acquire_compound(SnapshotTable* table, ColliderDesc* desc) @private {
    Allocator allocator = table.allocator;
    SnapshotSource[] sources = compound_sources(table, allocator, desc.children);
    defer catch alloc::free(allocator, sources.ptr);
    ulong content = compound_content(desc.children);
    foreach (usz index, &slot : table.slots) {
        if (matches(slot, { .kind = COMPOUND, .content = content, .sources = sources })) {
            alloc::free(allocator, sources.ptr);
            return hold(table, index);
        }
    }

    Vec3[] wire;
    b3::CompoundData* compound = bake_compound(table, desc.children, &wire)!;
    defer catch {
        b3::destroy_compound(compound);
        alloc::free(allocator, wire.ptr);
    }
    // Reserved only after the bake: the bake acquires child snapshots and would take a reserved slot.
    usz index = reserve_slot(table)!;
    return occupy(table, index, {
        .kind     = COMPOUND,
        .content  = content,
        .sources  = sources,
        .compound = compound,
        .wire     = wire,
    });
}

<*
 @require handle.generation == 0 || table.slots[handle.index].generation == handle.generation
*>
fn void release_snapshot(SnapshotTable* table, SnapshotHandle handle) @private {
    if (!handle.generation) return;
    CollisionSnapshot* slot = &table.slots[handle.index];
    slot.holders--;
    // A compound re-bakes from its child snapshots, which stay cooked; keeping it would only pin edited content.
    if (!slot.holders && (!slot.sources.len || slot.kind == COMPOUND)) free_snapshot(table, slot);
}

fn void reclaim_unheld_stale(SnapshotTable* table) @private {
    foreach (&slot : table.slots) {
        if (is_occupied(slot) && !slot.holders && slot.sources.len && !sources_current(table, slot)) {
            free_snapshot(table, slot);
        }
    }
}

fn bool sources_current(SnapshotTable* table, CollisionSnapshot* slot) @private {
    foreach (source : slot.sources) {
        switch (slot.kind) {
            case HEIGHT_FIELD:
                if (texture_revision_or_zero(table, source.texture) != source.revision) return false;
            case HULL:
            case MESH:
            case COMPOUND:
                if (revision_or_zero(table, source.geometry) != source.revision) return false;
        }
    }
    return true;
}

fn ulong body_revision_sum(PhysicsWorld* world, PhysicsBody* physics_body) @private {
    SnapshotTable* table = world.snapshots;
    ulong sum;
    foreach (&collider : physics_body.colliders) {
        switch (collider.kind) {
            case HULL:
            case MESH:
                sum += revision_or_zero(table, collider.geometry);
            case COMPOUND:
                foreach (&child : collider.children) {
                    if (child.kind == HULL || child.kind == MESH) sum += revision_or_zero(table, child.geometry);
                }
            case HEIGHT_FIELD:
                HeightField field = collider.height_field;
                if (field.source == TEXTURE) sum += texture_revision_or_zero(table, field.texture);
            case SPHERE:
            case CAPSULE:
            case BOX:
                break;
        }
    }
    return sum;
}

fn bool is_occupied(CollisionSnapshot* slot) @private => slot.generation % 2 == 1;

fn void free_snapshot(SnapshotTable* table, CollisionSnapshot* slot) @local {
    switch (slot.kind) {
        case HULL:         b3::destroy_hull(slot.hull);
        case MESH:         b3::destroy_mesh(slot.mesh);
        case HEIGHT_FIELD: b3::destroy_height_field(slot.height_field);
        case COMPOUND:     b3::destroy_compound(slot.compound);
    }
    alloc::free(table.allocator, slot.wire.ptr);
    alloc::free(table.allocator, slot.sources.ptr);
    uint generation = slot.generation + 1;
    *slot = { .generation = generation };
}

fn SnapshotHandle hold(SnapshotTable* table, usz index) @local {
    CollisionSnapshot* slot = &table.slots[index];
    slot.holders++;
    return { .index = (uint)index, .generation = slot.generation };
}

fn SnapshotHandle occupy(SnapshotTable* table, usz index, CollisionSnapshot snapshot) @local {
    CollisionSnapshot* slot = &table.slots[index];
    snapshot.generation = slot.generation + 1;
    snapshot.holders = 1;
    *slot = snapshot;
    return { .index = (uint)index, .generation = snapshot.generation };
}

fn usz? reserve_slot(SnapshotTable* table) @local {
    usz? index = first_free_slot(table);
    if (try index) return index;
    reclaim_unheld_stale(table);
    return first_free_slot(table);
}

fn usz? first_free_slot(SnapshotTable* table) @local {
    foreach (usz index, &slot : table.slots) {
        if (!is_occupied(slot)) return index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

fn bool matches(CollisionSnapshot* slot, SnapshotKey key) @local {
    if (!is_occupied(slot) || slot.kind != key.kind || slot.content != key.content) return false;
    if (slot.scale != key.scale) return false;
    if (slot.sources.len != key.sources.len) return false;
    foreach (index, source : key.sources) {
        SnapshotSource held = slot.sources[index];
        if (!c3d::same_id(held.geometry, source.geometry)) return false;
        if (!c3d::same_id(held.texture, source.texture)) return false;
        if (held.revision != source.revision) return false;
    }
    return true;
}

fn SnapshotSource current_source(SnapshotTable* table, GeometryId geometry) @local {
    return { .geometry = geometry, .revision = table.assets.geometry(geometry).header.revision };
}

fn ulong revision_or_zero(SnapshotTable* table, GeometryId geometry) @local {
    if (!table.assets.geometries.is_live(geometry)) return 0;
    return table.assets.geometry(geometry).header.revision;
}

fn SnapshotSource current_texture_source(SnapshotTable* table, TextureId texture) @local {
    return { .texture = texture, .revision = table.assets.texture(texture).header.revision };
}

fn ulong texture_revision_or_zero(SnapshotTable* table, TextureId texture) @local {
    if (!table.assets.textures.is_live(texture)) return 0;
    return table.assets.texture(texture).header.revision;
}

fn usz? height_texel_bytes(PixelFormat format) @private {
    switch (format) {
        case RGBA8_UNORM:
            return RGBA_CHANNELS;
        case RGBA32_FLOAT:
            return RGBA_CHANNELS * float::size;
        case R16_UINT:
            return ushort::size;
        case RGBA8_SRGB:
        case RGBA16_FLOAT:
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB:
            return c3d::UNSUPPORTED~;
    }
}

// Red channel only; the store allocator aligns pixels for the ushort and float views.
fn float[] height_map_samples(TextureAsset* texture, Allocator allocator) @local {
    usz count = (usz)texture.desc.width * texture.desc.height;
    float[] samples = alloc::new_array(allocator, float, (sz)count);
    switch (texture.desc.format) {
        case RGBA8_UNORM:
            foreach (usz index, &sample : samples) *sample = texture.pixels[index * RGBA_CHANNELS] / 255.0f;
        case R16_UINT:
            ushort* texels = (ushort*)texture.pixels.ptr;
            foreach (usz index, &sample : samples) *sample = texels[index] / 65535.0f;
        case RGBA32_FLOAT:
            float* texels = (float*)texture.pixels.ptr;
            foreach (usz index, &sample : samples) *sample = texels[index * RGBA_CHANNELS];
        case RGBA8_SRGB:
        case RGBA16_FLOAT:
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB:
            unreachable();
    }
    return samples;
}

fn SnapshotSource[] copy_sources(Allocator allocator, SnapshotSource[] sources) @local {
    SnapshotSource[] copy = alloc::new_array(allocator, SnapshotSource, (sz)sources.len);
    copy[..] = sources[..];
    return copy;
}

fn SnapshotSource[] compound_sources(SnapshotTable* table, Allocator allocator, CompoundChild[] children) @local {
    usz count;
    foreach (&child : children) {
        if (child.kind == HULL || child.kind == MESH) count++;
    }
    SnapshotSource[] sources = alloc::new_array(allocator, SnapshotSource, (sz)count);
    usz cursor;
    foreach (&child : children) {
        if (child.kind == HULL || child.kind == MESH) sources[cursor++] = current_source(table, child.geometry);
    }
    return sources;
}

// Fed field by field: whole structs would hash their padding and slice headers.
fn ulong compound_content(CompoundChild[] children) @local {
    Fnv64a hash;
    hash.init();
    foreach (&child : children) {
        @hash_value(&hash, child.kind);
        @hash_value(&hash, child.local.position);
        @hash_value(&hash, child.local.rotation);
        @hash_value(&hash, child.local.scale);
        @hash_value(&hash, child.radius);
        @hash_value(&hash, child.half_height);
        @hash_value(&hash, child.half_extents);
        @hash_value(&hash, child.geometry.index);
        @hash_value(&hash, child.geometry.generation);
        hash_material(&hash, &child.material);
        foreach (&material : child.face_materials) hash_material(&hash, material);
        hash.update(child.material_indices);
    }
    return (ulong)hash;
}

fn void hash_material(Fnv64a* hash, SurfaceMaterialDesc* material) @local {
    @hash_value(hash, material.friction);
    @hash_value(hash, material.restitution);
    @hash_value(hash, material.rolling_resistance);
    @hash_value(hash, material.tangent_velocity);
    @hash_value(hash, material.id);
}

macro void @hash_value(Fnv64a* hash, #value) @local => hash.update(@as_char_view(#value));

fn b3::CompoundData*? bake_compound(SnapshotTable* table, CompoundChild[] children, Vec3[]* wire) @local {
    b3::CompoundData* compound;
    @pool() {
        usz sphere_count;
        usz capsule_count;
        usz hull_count;
        usz box_count;
        usz mesh_count;
        foreach (&child : children) {
            switch (child.kind) {
                case SPHERE:  sphere_count++;
                case CAPSULE: capsule_count++;
                case BOX:
                    box_count++;
                    hull_count++;
                case HULL:    hull_count++;
                case MESH:    mesh_count++;
            }
        }
        b3::CompoundSphereDef[] spheres = alloc::new_array(tmem, b3::CompoundSphereDef, (sz)sphere_count);
        b3::CompoundCapsuleDef[] capsules = alloc::new_array(tmem, b3::CompoundCapsuleDef, (sz)capsule_count);
        b3::CompoundHullDef[] hulls = alloc::new_array(tmem, b3::CompoundHullDef, (sz)hull_count);
        b3::CompoundMeshDef[] meshes = alloc::new_array(tmem, b3::CompoundMeshDef, (sz)mesh_count);
        b3::BoxHull[] boxes = alloc::new_array(tmem, b3::BoxHull, (sz)box_count);
        SnapshotHandle[] held = alloc::new_array(tmem, SnapshotHandle, (sz)children.len);
        // box3d clones every child into the compound, so the child snapshots are held for the bake only.
        defer foreach (handle : held) release_snapshot(table, handle);

        usz sphere_cursor;
        usz capsule_cursor;
        usz hull_cursor;
        usz box_cursor;
        usz mesh_cursor;
        foreach (index, &child : children) {
            b3::SurfaceMaterial material = surface_material(child.material);
            b3::Transform frame = { .p = child.local.position, .q = child.local.rotation };
            switch (child.kind) {
                case SPHERE:
                    spheres[sphere_cursor++] = {
                        .sphere   = { .center = child.local.position, .radius = child.radius },
                        .material = material,
                    };
                case CAPSULE:
                    capsules[capsule_cursor++] = { .capsule = capsule_of(child.local, child.half_height, child.radius), .material = material };
                case BOX:
                    boxes[box_cursor] = b3::make_box_hull(child.half_extents.x, child.half_extents.y, child.half_extents.z);
                    hulls[hull_cursor++] = { .hull = &boxes[box_cursor++].base, .transform = frame, .material = material };
                case HULL:
                    held[index] = acquire_hull(table, child.geometry)!;
                    hulls[hull_cursor++] = {
                        .hull      = snapshot_of(table, held[index]).hull,
                        .transform = frame,
                        .material  = material,
                    };
                case MESH:
                    held[index] = acquire_mesh(table, child.geometry, child.material_indices)!;
                    meshes[mesh_cursor++] = mesh_child_def(
                        table: table,
                        child: child,
                        mesh:  snapshot_of(table, held[index]).mesh,
                        frame: frame,
                    );
            }
        }

        b3::CompoundDef def = {
            .capsules      = capsules.ptr,
            .capsule_count = (int)capsules.len,
            .hulls         = hulls.ptr,
            .hull_count    = (int)hulls.len,
            .meshes        = meshes.ptr,
            .mesh_count    = (int)meshes.len,
            .spheres       = spheres.ptr,
            .sphere_count  = (int)spheres.len,
        };
        compound = b3::create_compound(&def)!;
        if (table.cache_wireframes) *wire = compound_wire(table, children, held);
    };
    return compound;
}

fn b3::CompoundMeshDef mesh_child_def(
    SnapshotTable* table,
    CompoundChild* child,
    b3::MeshData* mesh,
    b3::Transform frame,
) @local {
    b3::SurfaceMaterial[] materials;
    if (child.face_materials.len) {
        materials = alloc::new_array(tmem, b3::SurfaceMaterial, (sz)child.face_materials.len);
        foreach (index, &face : child.face_materials) materials[index] = surface_material(*face);
    } else {
        materials = alloc::new_array(tmem, b3::SurfaceMaterial, 1);
        materials[0] = surface_material(child.material);
    }
    return {
        .mesh_data      = mesh,
        .transform      = frame,
        .scale          = child.local.scale,
        .materials      = materials.ptr,
        .material_count = (int)materials.len,
    };
}

fn b3::Capsule capsule_of(maths::Transform local, float half_height, float radius) @private {
    Vec3 half = local.rotation.rotate_vec3({ 0, half_height, 0 });
    return { .center1 = local.position - half, .center2 = local.position + half, .radius = radius };
}

fn Vec3[] compound_wire(SnapshotTable* table, CompoundChild[] children, SnapshotHandle[] held) @local {
    usz length;
    foreach (index, &child : children) {
        switch (child.kind) {
            case SPHERE:  length += 3 * COMPOUND_RING_SEGMENTS * 2;
            case CAPSULE: length += 2 * COMPOUND_RING_SEGMENTS * 2 + 8;
            case BOX:     length += BOX_EDGE_POINTS;
            case HULL:
            case MESH:
                length += snapshot_of(table, held[index]).wire.len;
        }
    }

    WireWriter writer = { .points = alloc::new_array(table.allocator, Vec3, (sz)length) };
    foreach (index, &child : children) {
        switch (child.kind) {
            case SPHERE:
                Vec3 center = child.local.position;
                foreach (axis : (Vec3[3]){ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) {
                    write_ring(
                        writer: &writer,
                        center: center,
                        axis:   axis,
                        radius: child.radius,
                    );
                }
            case CAPSULE:
                write_capsule(&writer, capsule_of(child.local, child.half_height, child.radius));
            case BOX:
                write_box(&writer, child.local, child.half_extents);
            case HULL:
            case MESH:
                Mat4 placement = child.local.to_mat4();
                foreach (point : snapshot_of(table, held[index]).wire) {
                    writer.points[writer.count++] = maths::transform_point(placement, point);
                }
        }
    }
    return writer.points;
}

fn uint[] sequential_indices(Allocator allocator, usz count) @local {
    uint[] indices = alloc::new_array(allocator, uint, (sz)count);
    foreach (index, &value : indices) *value = (uint)index;
    return indices;
}

fn Vec3[] mesh_wire(Allocator allocator, Vec3[] positions, uint[] indices) @local {
    Vec3[] wire = alloc::new_array(allocator, Vec3, (sz)(indices.len * 2));
    usz cursor;
    for (usz first = 0; first + 2 < indices.len; first += 3) {
        Vec3 a = positions[indices[first]];
        Vec3 b = positions[indices[first + 1]];
        Vec3 c = positions[indices[first + 2]];
        wire[cursor++] = a;
        wire[cursor++] = b;
        wire[cursor++] = b;
        wire[cursor++] = c;
        wire[cursor++] = c;
        wire[cursor++] = a;
    }
    return wire;
}

fn Vec3[] height_field_wire(Allocator allocator, HeightField field, Vec3 scale) @local {
    usz row_segments = (usz)(field.count_x - 1) * field.count_z;
    usz column_segments = (usz)(field.count_z - 1) * field.count_x;
    Vec3[] wire = alloc::new_array(allocator, Vec3, (sz)(2 * (row_segments + column_segments)));
    usz cursor;
    for (uint z = 0; z < field.count_z; z++) {
        for (uint x = 0; x + 1 < field.count_x; x++) {
            wire[cursor++] = height_point(field, scale, { x, z });
            wire[cursor++] = height_point(field, scale, { x + 1, z });
        }
    }
    for (uint x = 0; x < field.count_x; x++) {
        for (uint z = 0; z + 1 < field.count_z; z++) {
            wire[cursor++] = height_point(field, scale, { x, z });
            wire[cursor++] = height_point(field, scale, { x, z + 1 });
        }
    }
    return wire;
}

fn Vec3 height_point(HeightField field, Vec3 scale, uint[<2>] cell) @local {
    return { cell.x * scale.x, field.heights[(usz)cell.y * field.count_x + cell.x] * scale.y, cell.y * scale.z };
}
