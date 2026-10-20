module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::describe;
import c3d::maths;
import c3d::serial;
import std::math;

const ulong HEIGHT_FIELD_V2_LAYOUT @private = 0x81b6bf6cbb20c0f4;
const ulong COLLIDER_DESC_V2_LAYOUT @private = 0xf3ffcc18d6404c63;
const ulong BODY_V2_LAYOUT @private = 0xc7083025384ef72b;

struct HeightFieldV2 @private {
    HeightSource      source;
    float[]           heights;
    uint              count_x;
    uint              count_z;
    TextureId         texture;
    HeightFieldWindow window;
}

struct ColliderDescV2 @private {
    ColliderKind          kind;
    maths::Transform      local;
    float                 radius;
    float                 half_height;
    Vec3                  half_extents;
    GeometryId            geometry;
    HeightFieldV2         height_field;
    CompoundChild[]       children;
    float                 density;
    float                 explosion_scale;
    SurfaceMaterialDesc   material;
    SurfaceMaterialDesc[] face_materials;
    char[]                material_indices;
    bool                  sensor;
    bool                  contact_events;
    bool                  hit_events;
    CollisionFilter       filter;
}

struct BodyAuthoringV2 @private {
    BodyDesc          body;
    ColliderDescV2[]  colliders;
}

fn void? register_body_v2_values() @private {
    describe::register_reflected(HeightFieldV2)!;
    describe::register_reflected(ColliderDescV2)!;
    describe::register_reflected(BodyAuthoringV2)!;
    register_physics_value(HeightFieldV2, HEIGHT_FIELD_V2_LAYOUT, &defaults_height_field_v2, 2)!;
    register_physics_value(ColliderDescV2, COLLIDER_DESC_V2_LAYOUT, &defaults_collider_desc_v2, 2)!;
    register_physics_value(BodyAuthoringV2, BODY_V2_LAYOUT, &defaults_body_authoring_v2, 2)!;
}

fn void defaults_height_field_v2(void* value) @private => *(HeightFieldV2*)value = {};
fn void defaults_collider_desc_v2(void* value) @private => *(ColliderDescV2*)value = {};
fn void defaults_body_authoring_v2(void* value) @private => *(BodyAuthoringV2*)value = {};

fn ColliderDesc collider_of_v2(ColliderDescV2* legacy) @private {
    return {
        .kind             = legacy.kind,
        .local            = legacy.local,
        .radius           = legacy.radius,
        .half_height      = legacy.half_height,
        .half_extents     = legacy.half_extents,
        .geometry         = legacy.geometry,
        .height_field     = {
            .source  = legacy.height_field.source,
            .heights = legacy.height_field.heights,
            .count_x = legacy.height_field.count_x,
            .count_z = legacy.height_field.count_z,
            .texture = legacy.height_field.texture,
            .window  = legacy.height_field.window,
        },
        .children         = legacy.children,
        .density          = legacy.density,
        .explosion_scale  = legacy.explosion_scale,
        .material         = legacy.material,
        .face_materials   = legacy.face_materials,
        .material_indices = legacy.material_indices,
        .sensor           = legacy.sensor,
        .contact_events   = legacy.contact_events,
        .hit_events       = legacy.hit_events,
        .filter           = legacy.filter,
    };
}

// Bodies saved before neighbours existed have no neighbour maps.
fn void? upgrade_body_v2(serial::Reader* reader, serial::ReadContext* context, void* value) @private {
    BodyAuthoringV2* legacy = context.read_value(BodyAuthoringV2, reader)!;
    ColliderDesc* colliders = context.read_owned.acquire(
        legacy.colliders.len,
        ColliderDesc::size,
        ColliderDesc::alignment,
    )!;
    foreach (index, &collider : legacy.colliders) colliders[index] = collider_of_v2(collider);

    *(BodyAuthoring*)value = { .body = legacy.body, .colliders = colliders[:legacy.colliders.len] };
}

fn void? read_body_v2(serial::Reader* reader, serial::ReadContext* context) @private {
    BodyAuthoring source;
    upgrade_body_v2(reader, context, &source)!;
    validate_body(&source, context)!;
    attach_body(&source, context)!;
}
