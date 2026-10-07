module c3d::character @feat(C3D_CHARACTER_SERIAL);

import c3d;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import c3d::serial;
import std::math;

<*
 Register character authoring and generated push-body ownership.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? register_serial_codecs() {
    physics::register_serial_value_types()!;
    describe::register_reflected(CharacterDesc)!;
    serial::register_described_type(
        $Type: CharacterDesc,
        version: 1,
        layout: 0x97ed00b8e41ba418,
        defaults: &defaults_character,
    )!;
    serial::register_described_owner(Character, CharacterDesc, {
        .name = "character",
        .phase = REFERENCES,
        .collect = &collect_character,
        .project = &project_character,
        .validate = &validate_character,
        .attach = &attach_character,
    })!;
    $if $feat(C3D_CHARACTER_NAV):
        register_nav_driven_codec()!;
    $endif
}

fn void defaults_character(void* value) @private => *(CharacterDesc*)value = default_character_desc();

fn void? project_character(void* component, void* value, serial::WriteContext* context) @private {
    *(CharacterDesc*)value = ((Character*)component).desc;
    check_character_desc((CharacterDesc*)value)!;
}

fn void? validate_character(void* value, serial::ReadContext* context) @private {
    CharacterDesc* desc = value;
    check_character_desc(desc)!;
    if (desc.push_bodies && context.has_component(PhysicsBody)) return physics::BODY_EXISTS~;
}

fn void? check_character_desc(CharacterDesc* desc) @private {
    if (!(desc.radius > 0) || !(desc.half_height > 0)) return c3d::INVALID_ARGUMENT~;
}

fn void? attach_character(void* value, serial::ReadContext* context) @private {
    CharacterDesc desc = *(CharacterDesc*)value;
    if (!desc.push_bodies) return context.scene.add_character(context.node, desc);
    ColliderDesc collider = push_collider(desc);
    PhysicsBody body = physics::try_copy_physics_body(context.scene.allocator, physics::default_body_desc(KINEMATIC), (&collider)[:1])!;
    defer catch alloc::free(context.scene.allocator, body.colliders.ptr);
    CharacterDesc capsule = desc;
    capsule.push_bodies = false;
    context.scene.add_character(context.node, capsule)!;
    context.scene.get(context.node, Character).desc = desc;
    context.scene.add(context.node, body);
}

fn void? collect_character(void* component, serial::WriteContext* context) @private {
    Character* character = component;
    if (!character.desc.push_bodies) return;
    PhysicsBody* body = context.scene.get(context.node, PhysicsBody);
    if (!body || !serial_push_body_matches(body, character.desc)) return c3d::INVALID_ARGUMENT~;
    context.omit_component(context.node, ecs::slot_of(PhysicsBody)!)!;
    if (context.scene.has(context.node, RigidBody)) context.omit_component(context.node, ecs::slot_of(RigidBody)!)!;
}

fn bool serial_push_body_matches(PhysicsBody* body, CharacterDesc character) @private {
    if (body.colliders.len != 1) return false;
    BodyDesc desc = body.body;
    MotionLocks locks = desc.locks;
    if (desc.kind != KINEMATIC || desc.name.len || desc.linear_velocity != (Vec3){} || desc.angular_velocity != (Vec3){}
        || desc.linear_damping != 0 || desc.angular_damping != 0 || desc.gravity_scale != 1
        || !desc.allow_sleep || desc.bullet || desc.disabled
        || locks.linear_x || locks.linear_y || locks.linear_z || locks.angular_x || locks.angular_y || locks.angular_z) return false;
    ColliderDesc* collider = &body.colliders[0];
    ColliderDesc expected = push_collider(character);
    return collider.kind == CAPSULE && collider.local.position == expected.local.position
        && collider.local.rotation.v == expected.local.rotation.v && collider.local.scale == expected.local.scale
        && collider.radius == expected.radius && collider.half_height == expected.half_height
        && collider.half_extents == (Vec3){} && !collider.geometry.generation
        && collider.height_field.source == HEIGHTS && !collider.height_field.heights.len
        && !collider.height_field.count_x && !collider.height_field.count_z && !collider.height_field.texture.generation
        && !collider.children.len && collider.density == expected.density && collider.explosion_scale == expected.explosion_scale
        && collider.material.friction == expected.material.friction && collider.material.restitution == 0
        && collider.material.rolling_resistance == 0 && collider.material.tangent_velocity == (Vec3){} && (ulong)collider.material.id == 0
        && !collider.face_materials.len && !collider.material_indices.len
        && !collider.sensor && !collider.contact_events && !collider.hit_events
        && collider.filter.category == expected.filter.category && collider.filter.mask == expected.filter.mask
        && collider.filter.group == expected.filter.group;
}
