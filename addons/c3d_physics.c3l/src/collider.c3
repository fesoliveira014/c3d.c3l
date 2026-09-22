module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import b3;

fn void? check_collider(PhysicsWorld* world, ColliderDesc* desc, BodyKind kind) @private {
    switch (desc.kind) {
        case SPHERE:
        case CAPSULE:
        case BOX:
            return;
        case HULL:
            return check_source(world, desc.geometry);
        case MESH:
            if (kind != STATIC) return STATIC_ONLY~;
            check_placement(desc)!;
            return check_source(world, desc.geometry);
        case HEIGHT_FIELD:
            if (kind != STATIC) return STATIC_ONLY~;
            check_placement(desc)!;
            HeightField field = desc.height_field;
            if (field.count_x < 2 || field.count_z < 2) return c3d::INVALID_ARGUMENT~;
            if (field.heights.len != (usz)field.count_x * field.count_z) return c3d::INVALID_ARGUMENT~;
            return;
    }
}

fn void? check_placement(ColliderDesc* desc) @local {
    Vec3 position = desc.local.position;
    Quat rotation = desc.local.rotation;
    if (position.x != 0 || position.y != 0 || position.z != 0) return c3d::UNSUPPORTED~;
    if (rotation.i != 0 || rotation.j != 0 || rotation.k != 0 || rotation.l != 1) return c3d::UNSUPPORTED~;
}

fn void? check_source(PhysicsWorld* world, GeometryId geometry) @local {
    if (!world.assets.geometries.is_live(geometry)) return c3d::INVALID_ID~;
    if (world.assets.geometry(geometry).data.positions.len == 0) return SOURCE_UNAVAILABLE~;
}

fn b3::ShapeDef shape_def(ColliderDesc* desc) @local {
    b3::ShapeDef def = b3::default_shape_def();
    def.density = desc.density;
    def.base_material.friction = desc.friction;
    def.base_material.restitution = desc.restitution;
    def.filter = {
        .category_bits = desc.filter.category,
        .mask_bits     = desc.filter.mask,
        .group_index   = desc.filter.group,
    };
    def.is_sensor = desc.sensor;
    def.enable_sensor_events = desc.sensor || desc.contact_events;
    def.enable_contact_events = desc.contact_events;
    def.enable_hit_events = desc.hit_events;
    return def;
}

fn b3::Transform shape_frame(ColliderDesc* desc) @local {
    return { .p = desc.local.position, .q = desc.local.rotation };
}

fn Collider? create_shape(PhysicsWorld* world, b3::BodyId body, ColliderDesc* desc) @private {
    b3::ShapeDef def = shape_def(desc);
    Collider record = {
        .kind         = desc.kind,
        .local        = desc.local,
        .radius       = desc.radius,
        .half_height  = desc.half_height,
        .half_extents = desc.half_extents,
    };
    switch (desc.kind) {
        case SPHERE:
            b3::Sphere sphere = { .center = desc.local.position, .radius = desc.radius };
            record.shape = b3::create_sphere_shape(body, &def, &sphere)!;
        case CAPSULE:
            Vec3 half = desc.local.rotation.rotate_vec3({ 0, desc.half_height, 0 });
            b3::Capsule capsule = {
                .center1 = desc.local.position - half,
                .center2 = desc.local.position + half,
                .radius  = desc.radius,
            };
            record.shape = b3::create_capsule_shape(body, &def, &capsule)!;
        case BOX:
            b3::BoxHull box = b3::make_box_hull(desc.half_extents.x, desc.half_extents.y, desc.half_extents.z);
            record.shape = b3::create_transformed_hull_shape(
                body:      body,
                def:       &def,
                hull:      &box.base,
                transform: shape_frame(desc),
                scale:     { 1, 1, 1 },
            )!;
        case HULL:
            PhysicsHull* snapshot = resolve_hull(world, desc.geometry)!;
            record.shape = b3::create_transformed_hull_shape(
                body:      body,
                def:       &def,
                hull:      snapshot.hull,
                transform: shape_frame(desc),
                scale:     desc.local.scale,
            )!;
            record.wire = snapshot.wire;
        case MESH:
            PhysicsMesh* snapshot = resolve_mesh(world, desc.geometry)!;
            record.shape = b3::create_mesh_shape(
                body:  body,
                def:   &def,
                mesh:  snapshot.mesh,
                scale: desc.local.scale,
            )!;
            record.wire = snapshot.wire;
        case HEIGHT_FIELD:
            PhysicsHeightField* snapshot = create_height_field(world, desc)!;
            record.shape = b3::create_height_field_shape(body, &def, snapshot.field)!;
            record.wire = snapshot.wire;
    }
    return record;
}

fn bool same_key(PhysicsSourceKey a, PhysicsSourceKey b) @local {
    return a.geometry.index == b.geometry.index
        && a.geometry.generation == b.geometry.generation
        && a.revision == b.revision;
}

fn PhysicsHull*? resolve_hull(PhysicsWorld* world, GeometryId geometry) @local {
    GeometryAsset* asset = world.assets.geometry(geometry);
    PhysicsSourceKey key = { .geometry = geometry, .revision = asset.header.revision };
    foreach (&snapshot : world.hulls[:world.hull_count]) {
        if (same_key(snapshot.key, key)) return snapshot;
    }
    if (world.hull_count == world.desc.snapshot_capacity) return c3d::CAPACITY_EXCEEDED~;

    b3::HullData* hull = b3::create_hull(asset.data.positions, b3::MAX_HULL_VERTICES)!;
    Vec3[] wire;
    if (world.desc.cache_wireframes) wire = hull_wire(world.allocator, hull);
    world.hulls[world.hull_count] = { .key = key, .hull = hull, .wire = wire };
    return &world.hulls[world.hull_count++];
}

fn PhysicsMesh*? resolve_mesh(PhysicsWorld* world, GeometryId geometry) @local {
    GeometryAsset* asset = world.assets.geometry(geometry);
    PhysicsSourceKey key = { .geometry = geometry, .revision = asset.header.revision };
    foreach (&snapshot : world.meshes[:world.mesh_count]) {
        if (same_key(snapshot.key, key)) return snapshot;
    }
    if (world.mesh_count == world.desc.snapshot_capacity) return c3d::CAPACITY_EXCEEDED~;

    Geometry* source = &asset.data;
    uint[] indices = source.indices;
    if (indices.len == 0) indices = sequential_indices(world.allocator, source.positions.len);
    defer {
        if (indices.ptr != source.indices.ptr) alloc::free(world.allocator, indices.ptr);
    }
    b3::MeshDef def = {
        .vertices       = source.positions.ptr,
        .indices        = (int*)indices.ptr,
        .vertex_count   = (int)source.positions.len,
        .triangle_count = (int)(indices.len / 3),
    };
    b3::MeshData* mesh = b3::create_mesh(&def)!;
    Vec3[] wire;
    if (world.desc.cache_wireframes) wire = mesh_wire(world.allocator, source.positions, indices);
    world.meshes[world.mesh_count] = { .key = key, .mesh = mesh, .wire = wire };
    return &world.meshes[world.mesh_count++];
}

fn PhysicsHeightField*? create_height_field(PhysicsWorld* world, ColliderDesc* desc) @local {
    if (world.height_field_count == world.desc.snapshot_capacity) return c3d::CAPACITY_EXCEEDED~;

    HeightField field = desc.height_field;
    float minimum = field.heights[0];
    float maximum = field.heights[0];
    foreach (height : field.heights) {
        minimum = math::min(minimum, height);
        maximum = math::max(maximum, height);
    }
    b3::HeightFieldDef def = {
        .heights               = field.heights.ptr,
        .scale                 = desc.local.scale,
        .count_x               = (int)field.count_x,
        .count_z               = (int)field.count_z,
        .global_minimum_height = minimum,
        .global_maximum_height = maximum,
    };
    b3::HeightFieldData* data = b3::create_height_field(&def)!;
    Vec3[] wire;
    if (world.desc.cache_wireframes) wire = height_field_wire(world.allocator, field, desc.local.scale);
    world.height_fields[world.height_field_count] = { .field = data, .wire = wire };
    return &world.height_fields[world.height_field_count++];
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
