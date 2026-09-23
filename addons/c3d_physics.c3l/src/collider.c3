module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
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
            check_placement(desc.local)!;
            check_source(world, desc.geometry)!;
            return check_mesh_indices(world, desc.geometry, desc.material_indices, desc.face_materials.len);
        case HEIGHT_FIELD:
            if (kind != STATIC) return STATIC_ONLY~;
            check_placement(desc.local)!;
            HeightField field = desc.height_field;
            if (field.count_x < 2 || field.count_z < 2) return c3d::INVALID_ARGUMENT~;
            if (field.heights.len != (usz)field.count_x * field.count_z) return c3d::INVALID_ARGUMENT~;
            if (!desc.material_indices.len) return;
            if (desc.material_indices.len != (usz)(field.count_x - 1) * (usz)(field.count_z - 1)) return c3d::INVALID_ARGUMENT~;
            foreach (index : desc.material_indices) {
                if (index != HEIGHT_FIELD_HOLE && index >= desc.face_materials.len) return c3d::INVALID_ARGUMENT~;
            }
            return;
        case COMPOUND:
            if (kind != STATIC) return STATIC_ONLY~;
            if (desc.sensor || !desc.children.len) return c3d::INVALID_ARGUMENT~;
            check_placement(desc.local)!;
            foreach (&child : desc.children) check_compound_child(world, child)!;
            return;
    }
}

fn void? check_compound_child(PhysicsWorld* world, CompoundChild* child) @local {
    switch (child.kind) {
        case SPHERE:
        case CAPSULE:
        case BOX:
            return;
        case HULL:
            if (child.local.scale != (Vec3){ 1, 1, 1 }) return c3d::UNSUPPORTED~;
            return check_source(world, child.geometry);
        case MESH:
            check_source(world, child.geometry)!;
            check_mesh_indices(world, child.geometry, child.material_indices, child.face_materials.len)!;
            usz material_count = 1;
            foreach (index : child.material_indices) material_count = math::max(material_count, (usz)index + 1);
            if (material_count > b3::MAX_COMPOUND_MESH_MATERIALS) return c3d::INVALID_ARGUMENT~;
            if (child.face_materials.len && child.face_materials.len != material_count) return c3d::INVALID_ARGUMENT~;
            return;
    }
}

fn void? check_mesh_indices(
    PhysicsWorld* world,
    GeometryId geometry,
    char[] material_indices,
    usz face_material_count,
) @local {
    if (!material_indices.len) return;
    GeometryAsset* asset = world.assets.geometry(geometry);
    uint triangle_count = asset.index_count ? asset.index_count / 3 : asset.vertex_count / 3;
    if (material_indices.len != triangle_count) return c3d::INVALID_ARGUMENT~;
    foreach (index : material_indices) {
        if (index >= face_material_count) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_placement(maths::Transform local) @local {
    Vec3 position = local.position;
    Quat rotation = local.rotation;
    if (position.x != 0 || position.y != 0 || position.z != 0) return c3d::UNSUPPORTED~;
    if (rotation.i != 0 || rotation.j != 0 || rotation.k != 0 || rotation.l != 1) return c3d::UNSUPPORTED~;
}

fn void? check_source(PhysicsWorld* world, GeometryId geometry) @local {
    if (!world.assets.geometries.is_live(geometry)) return c3d::INVALID_ID~;
}

// Called inside the caller's @pool: the face material array lives in tmem until box3d copies it.
fn b3::ShapeDef shape_def(ColliderDesc* desc) @local {
    b3::ShapeDef def = b3::default_shape_def();
    def.density = desc.density;
    def.explosion_scale = desc.explosion_scale;
    def.base_material = surface_material(desc.material);
    if (desc.face_materials.len == 1) def.base_material = surface_material(desc.face_materials[0]);
    if (desc.face_materials.len > 1) {
        b3::SurfaceMaterial[] materials = alloc::new_array(tmem, b3::SurfaceMaterial, (sz)desc.face_materials.len);
        foreach (index, &face : desc.face_materials) materials[index] = surface_material(*face);
        def.materials = materials.ptr;
        def.material_count = (int)materials.len;
    }
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
            return record;
        case CAPSULE:
            b3::Capsule capsule = capsule_of(desc.local, desc.half_height, desc.radius);
            record.shape = b3::create_capsule_shape(body, &def, &capsule)!;
            return record;
        case BOX:
            b3::BoxHull box = b3::make_box_hull(desc.half_extents.x, desc.half_extents.y, desc.half_extents.z);
            record.shape = b3::create_transformed_hull_shape(
                body:      body,
                def:       &def,
                hull:      &box.base,
                transform: shape_frame(desc),
                scale:     { 1, 1, 1 },
            )!;
            return record;
        case HULL:
            record.snapshot = acquire_hull(world, desc.geometry)!;
            defer catch release_snapshot(world.snapshots, record.snapshot);
            CollisionSnapshot* snapshot = snapshot_of(world.snapshots, record.snapshot);
            record.wire = snapshot.wire;
            record.shape = b3::create_transformed_hull_shape(
                body:      body,
                def:       &def,
                hull:      snapshot.hull,
                transform: shape_frame(desc),
                scale:     desc.local.scale,
            )!;
            return record;
        case MESH:
            record.snapshot = acquire_mesh(world, desc.geometry, desc.material_indices)!;
            defer catch release_snapshot(world.snapshots, record.snapshot);
            CollisionSnapshot* snapshot = snapshot_of(world.snapshots, record.snapshot);
            record.wire = snapshot.wire;
            record.shape = b3::create_mesh_shape(
                body:  body,
                def:   &def,
                mesh:  snapshot.mesh,
                scale: desc.local.scale,
            )!;
            return record;
        case HEIGHT_FIELD:
            record.snapshot = acquire_height_field(world, desc)!;
            defer catch release_snapshot(world.snapshots, record.snapshot);
            CollisionSnapshot* snapshot = snapshot_of(world.snapshots, record.snapshot);
            record.wire = snapshot.wire;
            record.shape = b3::create_height_field_shape(body, &def, snapshot.height_field)!;
            return record;
        case COMPOUND:
            record.snapshot = acquire_compound(world, desc)!;
            defer catch release_snapshot(world.snapshots, record.snapshot);
            CollisionSnapshot* snapshot = snapshot_of(world.snapshots, record.snapshot);
            record.wire = snapshot.wire;
            record.shape = b3::create_baked_compound_shape(body, &def, snapshot.compound)!;
            return record;
    }
}
