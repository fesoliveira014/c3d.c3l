module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::maths;
import c3d::serial;
import std::math;

const ulong HEIGHT_FIELD_V1_LAYOUT @private = 0x103663e5d599fb64;
const ulong COLLIDER_DESC_V1_LAYOUT @private = 0xdd2a19f055eaf423;
const ulong BODY_V1_LAYOUT @private = 0xed9972ba2248fa8b;

struct HeightFieldV1 @private {
    HeightSource source;
    float[]      heights;
    uint         count_x;
    uint         count_z;
    TextureId    texture;
}

struct ColliderDescV1 @private {
    ColliderKind          kind;
    maths::Transform      local;
    float                 radius;
    float                 half_height;
    Vec3                  half_extents;
    GeometryId            geometry;
    HeightFieldV1         height_field;
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

struct BodyAuthoringV1 @private {
    BodyDesc          body;
    ColliderDescV1[]  colliders;
}

fn void? register_body_v1_values() @private {
    describe::register_reflected(HeightFieldV1)!;
    describe::register_reflected(ColliderDescV1)!;
    describe::register_reflected(BodyAuthoringV1)!;
    register_physics_value(HeightFieldV1, HEIGHT_FIELD_V1_LAYOUT, &defaults_height_field_v1)!;
    register_physics_value(ColliderDescV1, COLLIDER_DESC_V1_LAYOUT, &defaults_collider_desc_v1)!;
    register_physics_value(BodyAuthoringV1, BODY_V1_LAYOUT, &defaults_body_authoring_v1)!;
}

fn void defaults_height_field_v1(void* value) @private => *(HeightFieldV1*)value = {};
fn void defaults_collider_desc_v1(void* value) @private => *(ColliderDescV1*)value = {};
fn void defaults_body_authoring_v1(void* value) @private => *(BodyAuthoringV1*)value = {};

fn ColliderDesc collider_of_v1(ColliderDescV1* legacy) @local {
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

// Bodies saved before windows existed cover their whole map.
fn void? upgrade_body_v1(serial::Reader* reader, serial::ReadContext* context, void* value) @private {
    BodyAuthoringV1* legacy = context.read_value(BodyAuthoringV1, reader)!;
    ColliderDesc* colliders = context.read_owned.acquire(
        legacy.colliders.len,
        ColliderDesc::size,
        ColliderDesc::alignment,
    )!;
    foreach (index, &collider : legacy.colliders) colliders[index] = collider_of_v1(collider);

    *(BodyAuthoring*)value = { .body = legacy.body, .colliders = colliders[:legacy.colliders.len] };
}

fn void? read_body_v1(serial::Reader* reader, serial::ReadContext* context) @private {
    BodyAuthoring source;
    upgrade_body_v1(reader, context, &source)!;
    validate_body(&source, context)!;
    attach_body(&source, context)!;
}
