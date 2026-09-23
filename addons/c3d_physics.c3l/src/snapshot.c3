module c3d::physics;

import std::math;
import std::math::quaternion;
import std::hash::fnv64a;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import b3;

const uint COMPOUND_RING_SEGMENTS @local = 16; // 48 lines per sphere; the wire density lever
const usz  BOX_EDGE_POINTS @local = 24;
const float AXIS_PARALLEL_THRESHOLD @local = 0.99f; // an axis this close to Y takes X as its basis reference

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
 Geometry revision a snapshot was cooked from.
*>
struct SnapshotSource {
    GeometryId geometry;
    uint       revision;
}

<*
 Cooked collision data shared by every collider with the same key.
*>
struct CollisionSnapshot {
    SnapshotKind         kind;
    ulong                content;    // hash of component data baked into the box3d object; 0 when none
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
}

struct SnapshotKey @local {
    SnapshotKind     kind;
    ulong            content;
    SnapshotSource[] sources;
}

struct WireWriter @local {
    Vec3[] points;
    usz    count;
}

fn SnapshotTable* create_snapshot_table(Allocator allocator, uint capacity) @private {
    SnapshotTable* table = alloc::new(allocator, SnapshotTable);
    *table = {
        .allocator = allocator,
        .slots     = alloc::new_array(allocator, CollisionSnapshot, capacity),
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

fn SnapshotHandle? acquire_hull(PhysicsWorld* world, GeometryId geometry) @private {
    SnapshotSource[1] sources = { current_source(world, geometry) };
    foreach (usz index, &slot : world.snapshots.slots) {
        if (matches(slot, { .kind = HULL, .sources = sources[..] })) return hold(world.snapshots, index);
    }

    Vec3[] positions = world.assets.geometry(geometry).data.positions;
    if (!positions.len) return SOURCE_UNAVAILABLE~;
    usz index = reserve_slot(world)!;
    b3::HullData* hull = b3::create_hull(positions, b3::MAX_HULL_VERTICES)!;
    Allocator allocator = world.snapshots.allocator;
    Vec3[] wire;
    if (world.desc.cache_wireframes) wire = hull_wire(allocator, hull);
    return occupy(world.snapshots, index, {
        .kind    = HULL,
        .sources = copy_sources(allocator, sources[..]),
        .hull    = hull,
        .wire    = wire,
    });
}

fn SnapshotHandle? acquire_mesh(PhysicsWorld* world, GeometryId geometry, char[] material_indices) @private {
    SnapshotSource[1] sources = { current_source(world, geometry) };
    ulong content = material_indices.len ? fnv64a::hash(material_indices) : 0;
    foreach (usz index, &slot : world.snapshots.slots) {
        if (matches(slot, { .kind = MESH, .content = content, .sources = sources[..] })) return hold(world.snapshots, index);
    }

    Geometry* source = &world.assets.geometry(geometry).data;
    if (!source.positions.len) return SOURCE_UNAVAILABLE~;
    usz index = reserve_slot(world)!;
    Allocator allocator = world.snapshots.allocator;
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
    if (world.desc.cache_wireframes) wire = mesh_wire(allocator, source.positions, indices);
    return occupy(world.snapshots, index, {
        .kind    = MESH,
        .content = content,
        .sources = copy_sources(allocator, sources[..]),
        .mesh    = mesh,
        .wire    = wire,
    });
}

fn SnapshotHandle? acquire_height_field(PhysicsWorld* world, ColliderDesc* desc) @private {
    usz index = reserve_slot(world)!;
    HeightField field = desc.height_field;
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
    if (world.desc.cache_wireframes) wire = height_field_wire(world.snapshots.allocator, field, desc.local.scale);
    return occupy(world.snapshots, index, { .kind = HEIGHT_FIELD, .height_field = data, .wire = wire });
}

fn SnapshotHandle? acquire_compound(PhysicsWorld* world, ColliderDesc* desc) @private {
    Allocator allocator = world.snapshots.allocator;
    SnapshotSource[] sources = compound_sources(world, allocator, desc.children);
    defer catch alloc::free(allocator, sources.ptr);
    ulong content = compound_content(desc.children);
    foreach (usz index, &slot : world.snapshots.slots) {
        if (matches(slot, { .kind = COMPOUND, .content = content, .sources = sources })) {
            alloc::free(allocator, sources.ptr);
            return hold(world.snapshots, index);
        }
    }

    Vec3[] wire;
    b3::CompoundData* compound = bake_compound(world, desc.children, &wire)!;
    defer catch {
        b3::destroy_compound(compound);
        alloc::free(allocator, wire.ptr);
    }
    // Reserved only after the bake: the bake acquires child snapshots and would take a reserved slot.
    usz index = reserve_slot(world)!;
    return occupy(world.snapshots, index, {
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

fn void reclaim_unheld_stale(PhysicsWorld* world) @private {
    foreach (&slot : world.snapshots.slots) {
        if (is_occupied(slot) && !slot.holders && slot.sources.len && !sources_current(world, slot.sources)) {
            free_snapshot(world.snapshots, slot);
        }
    }
}

fn bool sources_current(PhysicsWorld* world, SnapshotSource[] sources) @private {
    foreach (source : sources) {
        if (!world.assets.geometries.is_live(source.geometry)) return false;
        if (world.assets.geometry(source.geometry).header.revision != source.revision) return false;
    }
    return true;
}

fn ulong body_revision_sum(PhysicsWorld* world, PhysicsBody* physics_body) @private {
    ulong sum;
    foreach (&collider : physics_body.colliders) {
        switch (collider.kind) {
            case HULL:
            case MESH:
                sum += revision_or_zero(world, collider.geometry);
            case COMPOUND:
                foreach (&child : collider.children) {
                    if (child.kind == HULL || child.kind == MESH) sum += revision_or_zero(world, child.geometry);
                }
            case SPHERE:
            case CAPSULE:
            case BOX:
            case HEIGHT_FIELD:
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

fn usz? reserve_slot(PhysicsWorld* world) @local {
    usz? index = first_free_slot(world.snapshots);
    if (try index) return index;
    reclaim_unheld_stale(world);
    return first_free_slot(world.snapshots);
}

fn usz? first_free_slot(SnapshotTable* table) @local {
    foreach (usz index, &slot : table.slots) {
        if (!is_occupied(slot)) return index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

fn bool matches(CollisionSnapshot* slot, SnapshotKey key) @local {
    if (!is_occupied(slot) || slot.kind != key.kind || slot.content != key.content) return false;
    if (slot.sources.len != key.sources.len) return false;
    foreach (index, source : key.sources) {
        SnapshotSource held = slot.sources[index];
        if (held.geometry.index != source.geometry.index || held.geometry.generation != source.geometry.generation) return false;
        if (held.revision != source.revision) return false;
    }
    return true;
}

fn SnapshotSource current_source(PhysicsWorld* world, GeometryId geometry) @local {
    return { .geometry = geometry, .revision = world.assets.geometry(geometry).header.revision };
}

fn ulong revision_or_zero(PhysicsWorld* world, GeometryId geometry) @local {
    if (!world.assets.geometries.is_live(geometry)) return 0;
    return world.assets.geometry(geometry).header.revision;
}

fn SnapshotSource[] copy_sources(Allocator allocator, SnapshotSource[] sources) @local {
    SnapshotSource[] copy = alloc::new_array(allocator, SnapshotSource, (sz)sources.len);
    copy[..] = sources[..];
    return copy;
}

fn SnapshotSource[] compound_sources(PhysicsWorld* world, Allocator allocator, CompoundChild[] children) @local {
    usz count;
    foreach (&child : children) {
        if (child.kind == HULL || child.kind == MESH) count++;
    }
    SnapshotSource[] sources = alloc::new_array(allocator, SnapshotSource, (sz)count);
    usz cursor;
    foreach (&child : children) {
        if (child.kind == HULL || child.kind == MESH) sources[cursor++] = current_source(world, child.geometry);
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

fn b3::CompoundData*? bake_compound(PhysicsWorld* world, CompoundChild[] children, Vec3[]* wire) @local {
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
        defer foreach (handle : held) release_snapshot(world.snapshots, handle);

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
                    held[index] = acquire_hull(world, child.geometry)!;
                    hulls[hull_cursor++] = {
                        .hull      = snapshot_of(world.snapshots, held[index]).hull,
                        .transform = frame,
                        .material  = material,
                    };
                case MESH:
                    held[index] = acquire_mesh(world, child.geometry, child.material_indices)!;
                    meshes[mesh_cursor++] = mesh_child_def(
                        world: world,
                        child: child,
                        mesh:  snapshot_of(world.snapshots, held[index]).mesh,
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
        if (world.desc.cache_wireframes) *wire = compound_wire(world, children, held);
    };
    return compound;
}

fn b3::CompoundMeshDef mesh_child_def(
    PhysicsWorld* world,
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

fn Vec3[] compound_wire(PhysicsWorld* world, CompoundChild[] children, SnapshotHandle[] held) @local {
    usz length;
    foreach (index, &child : children) {
        switch (child.kind) {
            case SPHERE:  length += 3 * COMPOUND_RING_SEGMENTS * 2;
            case CAPSULE: length += 2 * COMPOUND_RING_SEGMENTS * 2 + 8;
            case BOX:     length += BOX_EDGE_POINTS;
            case HULL:
            case MESH:
                length += snapshot_of(world.snapshots, held[index]).wire.len;
        }
    }

    WireWriter writer = { .points = alloc::new_array(world.snapshots.allocator, Vec3, (sz)length) };
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
                foreach (point : snapshot_of(world.snapshots, held[index]).wire) {
                    writer.points[writer.count++] = maths::transform_point(placement, point);
                }
        }
    }
    return writer.points;
}

fn void write_ring(WireWriter* writer, Vec3 center, Vec3 axis, float radius) @local {
    Vec3 reference = math::abs(axis.y) < AXIS_PARALLEL_THRESHOLD ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    Vec3 side = axis.cross(reference).normalize() * radius;
    Vec3 forward = axis.cross(side).normalize() * radius;
    float step = (float)math::PI * 2 / COMPOUND_RING_SEGMENTS;
    for (uint segment = 0; segment < COMPOUND_RING_SEGMENTS; segment++) {
        float start = segment * step;
        float end = start + step;
        writer.points[writer.count++] = center + side * math::cos(start) + forward * math::sin(start);
        writer.points[writer.count++] = center + side * math::cos(end) + forward * math::sin(end);
    }
}

fn void write_capsule(WireWriter* writer, b3::Capsule capsule) @local {
    Vec3 axis = (capsule.center2 - capsule.center1).normalize();
    foreach (center : (Vec3[2]){ capsule.center1, capsule.center2 }) {
        write_ring(
            writer: writer,
            center: center,
            axis:   axis,
            radius: capsule.radius,
        );
    }
    Vec3 reference = math::abs(axis.y) < AXIS_PARALLEL_THRESHOLD ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    Vec3 side = axis.cross(reference).normalize() * capsule.radius;
    Vec3 forward = axis.cross(side).normalize() * capsule.radius;
    foreach (offset : (Vec3[4]){ side, -side, forward, -forward }) {
        writer.points[writer.count++] = capsule.center1 + offset;
        writer.points[writer.count++] = capsule.center2 + offset;
    }
}

fn void write_box(WireWriter* writer, maths::Transform local, Vec3 half_extents) @local {
    Mat4 placement = local.to_mat4();
    Vec3[8] corners;
    for (uint corner = 0; corner < 8; corner++) {
        Vec3 sign = { corner & 1 ? 1 : -1, corner & 2 ? 1 : -1, corner & 4 ? 1 : -1 };
        corners[corner] = maths::transform_point(placement, half_extents * sign);
    }
    for (uint corner = 0; corner < 8; corner++) {
        foreach (bit : (uint[3]){ 1, 2, 4 }) {
            if (corner & bit) continue;
            writer.points[writer.count++] = corners[corner];
            writer.points[writer.count++] = corners[corner | bit];
        }
    }
}

fn uint[] sequential_indices(Allocator allocator, usz count) @local {
    uint[] indices = alloc::new_array(allocator, uint, (sz)count);
    foreach (index, &value : indices) *value = (uint)index;
    return indices;
}

fn Vec3[] hull_wire(Allocator allocator, b3::HullData* hull) @local {
    b3::HullHalfEdge* edges = (b3::HullHalfEdge*)((char*)hull + hull.edge_offset);
    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    Vec3[] wire = alloc::new_array(allocator, Vec3, (sz)hull.edge_count);
    usz cursor;
    for (int edge = 0; edge < hull.edge_count; edge++) {
        if (edges[edge].twin < edge) continue;
        wire[cursor++] = points[edges[edge].origin];
        wire[cursor++] = points[edges[edges[edge].twin].origin];
    }
    return wire;
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
