module c3d_character_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::character;
import c3d::ecs;
import c3d::physics;
import c3d::scene;
import std::io;

const float TOLERANCE @private = 0.0001f;
const float STOP_TOLERANCE @private = 0.01f;
const uint  NODE_CAPACITY @private = 64;
const uint  SETTLE_UPDATES @private = 120;
const uint  WALK_UPDATES @private = 60;
const uint  HOLD_UPDATES @private = 30;
const uint  LAND_UPDATES @private = 120;
const float DROP_HEIGHT @private = 0.5f;
const float WALK_SPEED @private = 2;
const Vec3  DIAGONAL_WALK @private = { 2, 0, 1 }; // slides along the steep face without leaving its width
const float WALL_SPEED @private = 3;
const float DOWNHILL_SPEED @private = 4;
const uint  DOWNHILL_UPDATES @private = 20; // stays on the ramp's top face at DOWNHILL_SPEED
const float DOWNHILL_START_X @private = 3.5f;
const float JUMP_SPEED @private = 4;
const float PLATFORM_SPEED @private = 1;
const Vec3  GROUND_HALF_EXTENTS @private = { 10, 0.5f, 10 };
const Vec3  WALL_HALF_EXTENTS @private = { 0.5f, 2, 2 };
const float WALL_X @private = 2;
const float RAMP_START_X @private = 1;
const Vec3  RAMP_HALF_EXTENTS @private = { 2, 0.25f, 2 };
const float WALKABLE_DEGREES @private = 30;
const float STEEP_DEGREES @private = 70;
const float MIN_CLIMB @private = 0.3f;
const float LEDGE_FACE_X @private = 1;
const Vec2  LEDGE_HALF_EXTENTS_XZ @private = { 1.5f, 2 };
const float LOW_LEDGE_HEIGHT @private = 0.3f;
const float HIGH_LEDGE_HEIGHT @private = 0.5f;
const Vec3  PLATFORM_HALF_EXTENTS @private = { 2, 0.25f, 2 };
const Vec3  CRATE_HALF_EXTENTS @private = { 0.5f, 0.5f, 0.5f };
const float CRATE_X @private = 1.5f;
const ulong CRATE_CATEGORY @private = 2;
const float MIN_PUSH @private = 0.1f;
const float GROWTH_GAP @private = 0.05f;
const float SHIFT_DISTANCE @private = 195 * 256; // about 50 km, a multiple of the 256 m cell
const float GROWTH @private = 0.2f; // four times the gap, so the grown capsule overlaps the wall

struct Fixture @private {
    AssetStore      assets;
    Scene           scene;
    PhysicsWorld    physics;
    CharacterSystem system;
}

fn void test_root_motion_sets_world_intent_and_turn_without_teleport() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    character::register_character(&scene)!!;
    Node* parent = scene.add_node()!!;
    parent.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    Node* node = scene.add_node(parent)!!;
    scene.update_world();
    CharacterDesc desc = character::default_character_desc();
    desc.push_bodies = false;
    scene.add_character(node, desc)!!;
    RootMotionDelta delta = {
        .translation = { 1, 0, 0 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 18),
    };

    scene.move_character_root_motion(node, delta, 0.5f);
    assert(close_vec(scene.get(node, Character).desired, { 0, 0, -2 }));
    assert(node.local.position == (Vec3){});
    scene.update_world();
    Vec3 facing = c3d::maths::transform_dir(node.world, { 1, 0, 0 });
    assert(close_vec(facing, { -0.1736482f, 0, -0.9848077f }));

    node.transform_space = TransformSpace.WORLD;
    node.local.rotation = parent.local.rotation;
    scene.update_world();
    scene.move_character_root_motion(node, delta, 0.5f);
    assert(close_vec(scene.get(node, Character).desired, { 0, 0, -2 }));
    assert(node.local.position == (Vec3){});
}

fn void setup(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    physics::register_physics(&fixture.scene)!!;
    character::register_character(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
    fixture.system = character::create_character_system(mem, &fixture.physics, &fixture.scene)!!;
}

fn void teardown(Fixture* fixture) @private {
    if (fixture.system.state) character::destroy_character_system(&fixture.system);
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn bool close(float first, float second, float tolerance = TOLERANCE) @private {
    return math::abs(first - second) <= tolerance;
}

fn bool close_vec(Vec3 first, Vec3 second, float tolerance = 1e-5f) @private {
    return close(first.x, second.x, tolerance) && close(first.y, second.y, tolerance)
        && close(first.z, second.z, tolerance);
}

fn Node* add_box(
    Fixture* fixture,
    Vec3 position,
    Vec3 half_extents,
    BodyKind kind = STATIC,
    Quaternionf rotation = quaternion::IDENTITY,
) @private {
    Node* node = fixture.scene.add_node(name: "box")!!;
    node.local.position = position;
    node.local.rotation = rotation;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    fixture.physics.add_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

fn Node* add_ground(Fixture* fixture) @private {
    return add_box(fixture, { 0, -GROUND_HALF_EXTENTS.y, 0 }, GROUND_HALF_EXTENTS);
}

fn Node* add_ramp_rising_along_x(Fixture* fixture, float degrees) @private {
    float angle = (float)math::deg_to_rad(degrees);
    Vec3 along = { math::cos(angle), math::sin(angle), 0 };
    Vec3 down = { math::sin(angle), -math::cos(angle), 0 };
    Vec3 center = (Vec3){ RAMP_START_X, 0, 0 } + along * RAMP_HALF_EXTENTS.x + down * RAMP_HALF_EXTENTS.y;
    return add_box(
        fixture:      fixture,
        position:     center,
        half_extents: RAMP_HALF_EXTENTS,
        rotation:     quaternion::from_axis_angle{float}({ 0, 0, 1 }, angle),
    );
}

fn Node* add_ledge(Fixture* fixture, float height) @private {
    Vec3 half_extents = { LEDGE_HALF_EXTENTS_XZ.x, height * 0.5f, LEDGE_HALF_EXTENTS_XZ.y };
    return add_box(fixture, { LEDGE_FACE_X + half_extents.x, half_extents.y, 0 }, half_extents);
}

fn Node* add_character(Fixture* fixture, Vec3 position, CharacterDesc desc) @private {
    Node* node = fixture.scene.add_node(name: "character")!!;
    node.local.position = position;
    fixture.scene.update_world();
    fixture.scene.add_character(node, desc)!!;
    return node;
}

fn float resting_height(CharacterDesc desc) @private => desc.half_height + desc.radius;

fn Node* add_standing_character(Fixture* fixture, CharacterDesc desc) @private {
    Node* node = add_character(fixture, { 0, DROP_HEIGHT, 0 }, desc);
    settle(fixture, SETTLE_UPDATES);
    return node;
}

fn void settle(Fixture* fixture, uint updates) @private {
    for (uint update = 0; update < updates; update++) {
        fixture.scene.update_world();
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
    }
    fixture.scene.update_world();
}

fn Character* character_of(Fixture* fixture, Node* node) @private => fixture.scene.get(node, Character);

fn void test_character_on_flat_ground_stays_grounded_with_zero_vertical_velocity() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_character(&fixture, { 0, 2, 0 }, desc);

    settle(&fixture, SETTLE_UPDATES);
    for (uint update = 0; update < HOLD_UPDATES; update++) {
        settle(&fixture, 1);
        Character* standing = character_of(&fixture, node);
        assert(standing.grounded);
        assert(close(standing.velocity.y, 0));
        assert(close(standing.current.y, resting_height(desc), desc.skin + 1e-3));
    }
    assert(close(node.world_position().y, 0, desc.skin + 1e-3), "the write pass places the node");
}

fn void test_wall_clips_velocity_along_its_normal() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    add_box(&fixture, { WALL_X, WALL_HALF_EXTENTS.y, 0 }, WALL_HALF_EXTENTS);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_standing_character(&fixture, desc);

    fixture.scene.move_character(node, { WALL_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);

    Character* blocked = character_of(&fixture, node);
    assert(close(blocked.velocity.x, 0, 1e-3));
    assert(close(blocked.current.x, WALL_X - WALL_HALF_EXTENTS.x - desc.radius - desc.skin, STOP_TOLERANCE));
}

fn void test_walkable_slope_is_climbed() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    Node* ramp = add_ramp_rising_along_x(&fixture, WALKABLE_DEGREES);
    Node* node = add_standing_character(&fixture, character::default_character_desc());
    float start_y = character_of(&fixture, node).current.y;

    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);

    Character* climber = character_of(&fixture, node);
    assert(climber.current.y > start_y + MIN_CLIMB);
    assert(climber.grounded);
    assert(c3d::same_id(climber.ground, ramp.id));
}

fn void test_walking_down_a_walkable_slope_stays_grounded() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    Node* ramp = add_ramp_rising_along_x(&fixture, WALKABLE_DEGREES);
    CharacterDesc desc = character::default_character_desc();
    float surface_y = (DOWNHILL_START_X - RAMP_START_X) * (float)math::tan(math::deg_to_rad(WALKABLE_DEGREES));
    Node* node = add_character(&fixture, { DOWNHILL_START_X, surface_y + DROP_HEIGHT, 0 }, desc);
    settle(&fixture, SETTLE_UPDATES);
    float start_y = character_of(&fixture, node).current.y;

    fixture.scene.move_character(node, { -DOWNHILL_SPEED, 0, 0 });
    for (uint update = 0; update < DOWNHILL_UPDATES; update++) {
        settle(&fixture, 1);
        Character* walker = character_of(&fixture, node);
        assert(walker.grounded);
        assert(c3d::same_id(walker.ground, ramp.id));
    }
    assert(character_of(&fixture, node).current.y < start_y);
}

fn void test_steep_slope_blocks_the_character() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture);
    add_ramp_rising_along_x(&fixture, STEEP_DEGREES);
    Node* node = add_standing_character(&fixture, character::default_character_desc());
    float start_y = character_of(&fixture, node).current.y;

    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);

    Character* blocked = character_of(&fixture, node);
    assert(close(blocked.current.y, start_y, STOP_TOLERANCE));
    assert(blocked.grounded);
    assert(c3d::same_id(blocked.ground, ground.id));
}

fn void test_ledge_below_step_height_is_climbed() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    Node* ledge = add_ledge(&fixture, LOW_LEDGE_HEIGHT);
    CharacterDesc desc = character::default_character_desc();
    assert(LOW_LEDGE_HEIGHT < desc.step_height);
    Node* node = add_standing_character(&fixture, desc);

    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);

    Character* climber = character_of(&fixture, node);
    assert(climber.grounded);
    assert(c3d::same_id(climber.ground, ledge.id));
    assert(close(climber.current.y, LOW_LEDGE_HEIGHT + resting_height(desc), desc.skin + 1e-3));
}

fn void test_ledge_above_step_height_blocks() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture);
    add_ledge(&fixture, HIGH_LEDGE_HEIGHT);
    CharacterDesc desc = character::default_character_desc();
    assert(HIGH_LEDGE_HEIGHT > desc.step_height);
    Node* node = add_standing_character(&fixture, desc);
    float start_y = character_of(&fixture, node).current.y;

    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);

    Character* blocked = character_of(&fixture, node);
    assert(close(blocked.current.x, LEDGE_FACE_X - desc.radius - desc.skin, STOP_TOLERANCE));
    assert(close(blocked.current.y, start_y, STOP_TOLERANCE));
    assert(c3d::same_id(blocked.ground, ground.id));
}

fn void test_moving_platform_carries_the_character() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* platform = add_box(
        fixture:      &fixture,
        position:     { 0, -PLATFORM_HALF_EXTENTS.y, 0 },
        half_extents: PLATFORM_HALF_EXTENTS,
        kind:         KINEMATIC,
    );
    Node* node = add_standing_character(&fixture, character::default_character_desc());
    float start_x = character_of(&fixture, node).current.x;
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;

    for (uint update = 0; update < WALK_UPDATES; update++) {
        platform.local.position.x += PLATFORM_SPEED * fixed_dt;
        settle(&fixture, 1);
    }

    Character* rider = character_of(&fixture, node);
    assert(close(rider.current.x - start_x, platform.local.position.x, STOP_TOLERANCE));
    assert(c3d::same_id(rider.ground, platform.id));
}

fn void test_jump_leaves_the_ground_and_lands() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_standing_character(&fixture, desc);
    float start_y = character_of(&fixture, node).current.y;

    fixture.scene.jump_character(node, JUMP_SPEED);
    settle(&fixture, 1);
    Character* jumper = character_of(&fixture, node);
    assert(!jumper.grounded);
    assert(jumper.velocity.y > 0);

    uint update;
    while (update < LAND_UPDATES && !jumper.grounded) {
        settle(&fixture, 1);
        update++;
    }
    assert(jumper.grounded, "lands within the update budget");
    assert(close(jumper.current.y, start_y, desc.skin + 1e-3));
}

fn void test_push_body_moves_a_dynamic_box() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    Node* crate = fixture.scene.add_node(name: "crate")!!;
    crate.local.position = { CRATE_X, CRATE_HALF_EXTENTS.y, 0 };
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = CRATE_HALF_EXTENTS;
    collider.filter.category = CRATE_CATEGORY;
    fixture.physics.add_body(crate, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    CharacterDesc desc = character::default_character_desc();
    desc.push_bodies = true;
    desc.filter.mask = ~CRATE_CATEGORY;
    Node* node = add_standing_character(&fixture, desc);
    float crate_start_x = crate.world_position().x;

    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);

    assert(crate.world_position().x > crate_start_x + MIN_PUSH);
}

fn void test_remove_character_removes_the_push_body_components() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    CharacterDesc desc = character::default_character_desc();
    desc.push_bodies = true;
    Node* node = add_character(&fixture, { 0, 0, 0 }, desc);
    settle(&fixture, 1);
    assert(fixture.scene.has(node, PhysicsBody) && fixture.scene.has(node, RigidBody));

    fixture.scene.remove_character(node);
    settle(&fixture, 1);

    assert(!fixture.scene.has(node, Character));
    assert(!fixture.scene.has(node, PhysicsBody));
    assert(!fixture.scene.has(node, RigidBody));
}

fn void test_add_character_twice_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_character(&fixture, { 0, 0, 0 }, desc);
    CharacterDesc other = desc;
    other.radius = desc.radius * 0.5f;

    if (catch excuse = fixture.scene.add_character(node, other)) {
        assert(excuse == character::CHARACTER_EXISTS);
    } else {
        assert(false, "a second character on the node faults");
    }
    assert(character_of(&fixture, node).desc.radius == desc.radius);
}

fn void test_create_character_system_registers_the_mover_pass() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_character(&fixture, { 0, 5, 0 }, character::default_character_desc());
    float start_y = character_of(&fixture, node).current.y;

    settle(&fixture, 1);
    float after_one_update = character_of(&fixture, node).current.y;
    assert(after_one_update < start_y);
    assert(fixture.system.state.stepped == 1);

    character::destroy_character_system(&fixture.system);
    assert(fixture.physics.mover_pass.step == null && fixture.physics.mover_pass.write == null);
    float written_y = node.world_position().y;
    settle(&fixture, 1);
    assert(character_of(&fixture, node).current.y == after_one_update);
    assert(node.world_position().y == written_y);
}

fn void test_steep_plane_is_a_wall() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    add_ramp_rising_along_x(&fixture, STEEP_DEGREES);
    Node* node = add_standing_character(&fixture, character::default_character_desc());
    float start_y = character_of(&fixture, node).current.y;

    fixture.scene.move_character(node, DIAGONAL_WALK);
    for (uint update = 0; update < WALK_UPDATES; update++) {
        settle(&fixture, 1);
        Character* walker = character_of(&fixture, node);
        assert(close(walker.current.y, start_y, STOP_TOLERANCE));
        assert(walker.velocity.y <= TOLERANCE);
    }
}

fn void test_node_origin_is_the_capsule_bottom() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_standing_character(&fixture, desc);

    Character* standing = character_of(&fixture, node);
    assert(standing.grounded);
    assert(close(node.world_position().y, 0, desc.skin + 1e-3), "the node stands on the floor");
    assert(close(standing.current.y - node.world_position().y, desc.half_height + desc.radius));
}

fn Vec3 feet_of(Vec3 center, CharacterDesc desc) @private => center - (Vec3){ 0, desc.half_height + desc.radius, 0 };

fn void test_set_character_desc_keeps_the_feet() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_character(&fixture, { 1, 0, 2 }, character::default_character_desc());
    Vec3 position = node.world_position();

    CharacterDesc desc = character::default_character_desc();
    desc.radius = 0.6f;
    fixture.scene.set_character_desc(node, desc)!!;
    desc.half_height = 1.0f;
    fixture.scene.set_character_desc(node, desc)!!;

    Character* character = character_of(&fixture, node);
    assert(close_vec(feet_of(character.previous, desc), { 1, 0, 2 }));
    assert(close_vec(feet_of(character.current, desc), { 1, 0, 2 }));
    assert(close_vec(node.world_position(), position));
}

fn void test_set_character_desc_keeps_the_motion() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_standing_character(&fixture, desc);
    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, HOLD_UPDATES);
    Character before = *character_of(&fixture, node);
    assert(before.grounded && c3d::same_id(before.ground, ground.id));

    desc.radius = 0.5f;
    fixture.scene.set_character_desc(node, desc)!!;
    Character* after = character_of(&fixture, node);
    assert(close_vec(after.velocity, before.velocity) && close_vec(after.desired, before.desired));
    assert(after.grounded && c3d::same_id(after.ground, before.ground));
    assert(close_vec(after.ground_normal, before.ground_normal));
}

fn void test_push_body_follows_the_flag() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_character(&fixture, { 0, 1, 0 }, desc);
    assert(!fixture.scene.has(node, PhysicsBody));

    desc.push_bodies = true;
    fixture.scene.set_character_desc(node, desc)!!;
    PhysicsBody* body = fixture.scene.get(node, PhysicsBody);
    assert(body.colliders.len == 1 && body.colliders[0].kind == CAPSULE);
    desc.push_bodies = false;
    fixture.scene.set_character_desc(node, desc)!!;
    assert(!fixture.scene.has(node, PhysicsBody));
}

fn void test_push_body_collider_follows_the_desc() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CharacterDesc desc = character::default_character_desc();
    desc.push_bodies = true;
    Node* node = add_character(&fixture, { 0, 1, 0 }, desc);
    settle(&fixture, 1);
    assert(fixture.scene.get(node, PhysicsBody).status == LIVE);

    desc.radius = 0.5f;
    desc.half_height = 0.8f;
    fixture.scene.set_character_desc(node, desc)!!;
    desc.filter.category = 4;
    desc.filter.group = 2;
    fixture.scene.set_character_desc(node, desc)!!;

    PhysicsBody* body = fixture.scene.get(node, PhysicsBody);
    ColliderDesc collider = body.colliders[0];
    assert(close(collider.radius, 0.5f) && close(collider.half_height, 0.8f));
    assert(close_vec(collider.local.position, { 0, 0.8f + 0.5f, 0 }));
    assert(collider.filter.category == 4 && collider.filter.group == 2 && collider.filter.mask == ulong::max);
    assert(body.status == PENDING);
}

fn void test_set_character_desc_faults_over_an_application_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_character(&fixture, { 0, 1, 0 }, desc);
    ColliderDesc collider = physics::default_collider_desc(SPHERE);
    collider.radius = 0.3f;
    fixture.scene.add_physics_body(node, physics::default_body_desc(KINEMATIC), (&collider)[:1])!!;
    Character before = *character_of(&fixture, node);
    Vec3 position = node.world_position();

    CharacterDesc pushing = desc;
    pushing.push_bodies = true;
    pushing.radius = 0.7f;
    assert(@catch(fixture.scene.set_character_desc(node, pushing)) == physics::BODY_EXISTS);
    Character* after = character_of(&fixture, node);
    assert(!after.desc.push_bodies && close(after.desc.radius, desc.radius));
    assert(close_vec(after.current, before.current) && close_vec(node.world_position(), position));
    assert(fixture.scene.get(node, PhysicsBody).colliders[0].kind == SPHERE);
}

fn void test_step_height_applies_on_the_next_step() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    Node* ledge = add_ledge(&fixture, HIGH_LEDGE_HEIGHT);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_standing_character(&fixture, desc);
    fixture.scene.move_character(node, { WALK_SPEED, 0, 0 });
    settle(&fixture, WALK_UPDATES);
    assert(!c3d::same_id(character_of(&fixture, node).ground, ledge.id));

    desc.step_height = HIGH_LEDGE_HEIGHT + 0.1f;
    fixture.scene.set_character_desc(node, desc)!!;
    settle(&fixture, WALK_UPDATES);
    assert(c3d::same_id(character_of(&fixture, node).ground, ledge.id));
}

fn void test_grown_capsule_is_pushed_out_of_a_wall() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    add_box(&fixture, { WALL_X, WALL_HALF_EXTENTS.y, 0 }, WALL_HALF_EXTENTS);
    CharacterDesc desc = character::default_character_desc();
    float wall_face = WALL_X - WALL_HALF_EXTENTS.x;
    Node* node = add_character(&fixture, { wall_face - desc.radius - GROWTH_GAP, DROP_HEIGHT, 0 }, desc);
    settle(&fixture, SETTLE_UPDATES);

    desc.radius += GROWTH;
    fixture.scene.set_character_desc(node, desc)!!;
    settle(&fixture, 1);
    float surface = character_of(&fixture, node).current.x + desc.radius;
    io::eprintfn("grown capsule surface %f against the wall face %f", surface, wall_face);
    assert(surface <= wall_face + desc.skin * 2);
}

fn void test_shift_characters_keeps_grounding() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Vec3 offset = { SHIFT_DISTANCE, 0, 0 };
    add_box(&fixture, offset + (Vec3){ 0, -GROUND_HALF_EXTENTS.y, 0 }, GROUND_HALF_EXTENTS);
    CharacterDesc desc = character::default_character_desc();
    Node* node = add_character(&fixture, offset + (Vec3){ 0, DROP_HEIGHT, 0 }, desc);
    settle(&fixture, SETTLE_UPDATES);
    Vec3 center = character_of(&fixture, node).current;
    assert(character_of(&fixture, node).plane_count > 0);

    fixture.scene.shift_origin(offset);
    fixture.scene.update_world();
    fixture.physics.shift_origin(&fixture.scene, offset);
    fixture.scene.shift_characters(offset);
    Character* shifted = character_of(&fixture, node);
    assert(close_vec(shifted.current, center - offset, STOP_TOLERANCE));
    assert(close_vec(shifted.previous, center - offset, STOP_TOLERANCE));
    foreach (plane : shifted.planes[:shifted.plane_count]) assert(math::abs(plane.point.x) < GROUND_HALF_EXTENTS.x + STOP_TOLERANCE);

    settle(&fixture, 1);
    Character* standing = character_of(&fixture, node);
    assert(standing.grounded);
    assert(close(standing.velocity.y, 0));
    assert(close_vec(standing.current, center - offset, STOP_TOLERANCE));
    assert(close(node.world_position().x, 0, STOP_TOLERANCE));
}
