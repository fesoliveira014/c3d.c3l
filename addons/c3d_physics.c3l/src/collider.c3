module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::maths;
import b3;

struct HeightGrid @private {
    uint x;
    uint z;
    uint samples_x;
    uint samples_z;
    char apron_sides;     // b3::HEIGHT_FIELD_APRON_* bits of the sides whose padding is read
    char neighbour_sides; // the apron sides past the map's edge, read from the neighbour maps
}

fn uint HeightGrid.padding(&self) => apron_padding(self.apron_sides);

fn usz HeightGrid.padded_sample_count(&self) {
    uint padding = self.padding();
    return (usz)(self.samples_x + 2 * padding) * (usz)(self.samples_z + 2 * padding);
}

fn usz HeightGrid.padded_cell_count(&self) {
    uint padding = self.padding();
    return (usz)(self.samples_x - 1 + 2 * padding) * (usz)(self.samples_z - 1 + 2 * padding);
}

// A window's material indices carry its ring; a whole map's stay one per cell.
fn usz HeightGrid.authored_cell_count(&self, HeightFieldWindow window) {
    if (window_covers_map(window)) return (usz)(self.samples_x - 1) * (usz)(self.samples_z - 1);
    return self.padded_cell_count();
}

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
            return check_mesh_indices(
                world:               world,
                geometry:            desc.geometry,
                material_indices:    desc.material_indices,
                face_material_count: desc.face_materials.len,
            );
        case HEIGHT_FIELD:
            if (kind != STATIC) return STATIC_ONLY~;
            check_placement(desc.local)!;
            HeightField field = desc.height_field;
            switch (field.source) {
                case HEIGHTS:
                    if (!window_covers_map(field.window) || has_neighbour_data(&field)) return c3d::INVALID_ARGUMENT~;
                    if (field.count_x < 2 || field.count_z < 2) return c3d::INVALID_ARGUMENT~;
                    if (field.heights.len != (usz)field.count_x * field.count_z) return c3d::INVALID_ARGUMENT~;
                    return check_cell_materials(desc, (usz)(field.count_x - 1) * (usz)(field.count_z - 1));
                case TEXTURE:
                    check_height_map(world.assets, field.texture)!;
                    char neighbour_sides = check_height_neighbours(world.assets, &field)!;
                    check_neighbour_cells(&field, desc.face_materials.len)!;
                    TextureDesc map = world.assets.texture(field.texture).desc;
                    HeightGrid grid = height_grid(map, field.window, neighbour_sides)!;
                    return check_cell_materials(desc, grid.authored_cell_count(field.window));
            }
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
            check_mesh_indices(
                world:               world,
                geometry:            child.geometry,
                material_indices:    child.material_indices,
                face_material_count: child.face_materials.len,
            )!;
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

// Pixels are checked only when present: released ones may still match a cooked snapshot.
fn void? check_height_map(AssetStore* assets, TextureId texture) @private {
    if (!assets.textures.is_live(texture)) return c3d::INVALID_ID~;
    TextureAsset* record = assets.texture(texture);
    TextureDesc source = record.desc;
    if (record.source_kind != MIP_ZERO) return c3d::UNSUPPORTED~;
    usz texel_bytes = height_texel_bytes(source.format)!;
    if (source.layers != 1 || source.depth > 1 || source.is_cube) return c3d::UNSUPPORTED~;
    if (source.width < 2 || source.height < 2) return c3d::INVALID_ARGUMENT~;
    usz texels = (usz)source.width * source.height;
    if (record.pixels.len && record.pixels.len != texels * texel_bytes) return c3d::INVALID_ARGUMENT~;
}

fn bool window_covers_map(HeightFieldWindow window) @private {
    return !window.x && !window.z && !window.count_x && !window.count_z;
}

// The window's own samples include its far row and column, which the next window shares.
fn HeightGrid? height_grid(TextureDesc source, HeightFieldWindow window, char neighbour_sides = 0) @private {
    if (window_covers_map(window)) {
        if (neighbour_sides && source.format == RGBA32_FLOAT) return c3d::UNSUPPORTED~;
        return {
            .samples_x       = source.width,
            .samples_z       = source.height,
            .apron_sides     = neighbour_sides,
            .neighbour_sides = neighbour_sides,
        };
    }
    if (!window.count_x || !window.count_z) return c3d::INVALID_ARGUMENT~;
    if ((usz)window.x + window.count_x >= source.width || (usz)window.z + window.count_z >= source.height) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (source.format == RGBA32_FLOAT) return c3d::UNSUPPORTED~;
    char interior_sides = window_apron_sides(window, { .x = source.width - 1, .z = source.height - 1 });
    char beyond_sides = neighbour_sides & ~interior_sides;
    return {
        .x               = window.x,
        .z               = window.z,
        .samples_x       = window.count_x + 1,
        .samples_z       = window.count_z + 1,
        .apron_sides     = interior_sides | beyond_sides,
        .neighbour_sides = beyond_sides,
    };
}

fn uint apron_padding(char apron_sides) @private => apron_sides ? 1 : 0;

// A side reads a neighbour wherever the map continues past it.
fn char window_apron_sides(HeightFieldWindow window, MapCells map) @private {
    char sides;
    if (window.x > 0) sides |= b3::HEIGHT_FIELD_APRON_NEGATIVE_X;
    if (window.x + window.count_x < map.x) sides |= b3::HEIGHT_FIELD_APRON_POSITIVE_X;
    if (window.z > 0) sides |= b3::HEIGHT_FIELD_APRON_NEGATIVE_Z;
    if (window.z + window.count_z < map.z) sides |= b3::HEIGHT_FIELD_APRON_POSITIVE_Z;
    return sides;
}

// Position in a grid padded on every side, mapped into the map; the border repeats where the map ends.
fn usz padded_map_index(uint origin, uint position, uint padding, uint count) @private {
    sz index = (sz)origin + position - padding;
    return (usz)math::clamp(index, 0, (sz)count - 1);
}

fn void? check_cell_materials(ColliderDesc* desc, usz cell_count) @local {
    if (!desc.material_indices.len) return;
    if (desc.material_indices.len != cell_count) return c3d::INVALID_ARGUMENT~;
    check_cell_values(desc.material_indices, desc.face_materials.len)!;
}

fn void? check_cell_values(char[] indices, usz face_material_count) @private {
    foreach (index : indices) {
        if (index != HEIGHT_FIELD_HOLE && index >= face_material_count) return c3d::INVALID_ARGUMENT~;
    }
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
            record.snapshot = acquire_hull(world.snapshots, desc.geometry)!;
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
            record.snapshot = acquire_mesh(world.snapshots, desc.geometry, desc.material_indices)!;
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
            record.snapshot = acquire_height_field(
                table: world.snapshots,
                field: desc.height_field,
                scale: desc.local.scale,
                material_indices: desc.material_indices,
            )!;
            defer catch release_snapshot(world.snapshots, record.snapshot);
            CollisionSnapshot* snapshot = snapshot_of(world.snapshots, record.snapshot);
            record.wire = snapshot.wire;
            record.shape = b3::create_height_field_shape(body, &def, snapshot.height_field)!;
            return record;
        case COMPOUND:
            record.snapshot = acquire_compound(world.snapshots, desc)!;
            defer catch release_snapshot(world.snapshots, record.snapshot);
            CollisionSnapshot* snapshot = snapshot_of(world.snapshots, record.snapshot);
            record.wire = snapshot.wire;
            record.shape = b3::create_baked_compound_shape(body, &def, snapshot.compound)!;
            return record;
    }
}
