module c3d_character_nav_test @feat(C3D_CHARACTER_NAV);

import std::math;
import c3d;
import c3d::asset;
import c3d::character;
import c3d::ecs;
import c3d::geometry;
import c3d::nav;
import c3d::physics;
import c3d::scene;

const uint  NODE_CAPACITY @private = 64;
const uint  CROWD_AGENTS @private = 8;
const uint  NAV_TILES @private = 2;
const uint  BUILD_BUDGET @private = 64; // tiles per nav_sync; the whole level builds in one call
const float FLOOR_THICKNESS @private = 0.5f;
const Vec3  START @private = { 4, 0, 4 };
const Vec3  TARGET @private = { 14, 0, 4 };
const uint  ARRIVAL_UPDATES @private = 600;
const Vec3  BLOCK_SIZE @private = { 1, 2, 4 };
const float BLOCK_X @private = 9;
const uint  BLOCKED_UPDATES @private = 300;
const float STOP_TOLERANCE @private = 0.01f;
const float STOPPED_SPEED @private = 0.05f; // metres per second
const float THROUGH_ALIGNMENT @private = 0.9f; // cosine; the velocity points within 26 degrees of the target
const uint  STEER_UPDATES @private = 30;
const float RELEASED_OFFSET_Z @private = 3; // metres between the two characters of the release test
const float WALK_SPEED @private = 2;
const uint  WALK_UPDATES @private = 60;
const float MIN_WALK @private = 1;
const Vec3  PLATFORM_SIZE @private = { 4.2f, 1.5f, 4.2f }; // taller than the 0.9 m climb, so only the link reaches it
const Vec3  PLATFORM_CENTRE @private = { 12, 0.75f, 4 };
const float LINK_RUN @private = 1; // metres each endpoint lies from the platform's edge, past the eroded border
const float LINK_RADIUS @private = 0.6f;
const uint  LANDING_UPDATES @private = 120;
const float SHIFT_OFFSET @private = 256;
const float PATH_TOLERANCE @private = 0.1f; // one step at the agent's top speed, the capsule's lead over the node

struct Fixture @private {
    AssetStore      assets;
    Scene           scene;
    PhysicsWorld    physics;
    CharacterSystem system;
    NavBuilder      builder;
    NavMesh         mesh;
    Crowd           crowd;
}

fn float level_side() @private {
    NavBuildConfig config = nav::default_nav_build_config();
    return (float)(NAV_TILES * config.tile_size) * config.cell_size;
}

// The floor's top is at y = 0; the test adds its own geometry, then calls build_navigation.
fn Fixture* setup() @private {
    Fixture* fixture = mem::new(Fixture);
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    Scene* scene = &fixture.scene;
    physics::register_physics(scene)!!;
    character::register_character(scene)!!;
    nav::register_nav(scene)!!;
    character::register_nav_driven(scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     scene,
        desc:      physics::default_physics_desc(),
    )!!;
    fixture.system = character::create_character_system(mem, &fixture.physics, scene)!!;
    float side = level_side();
    add_block(
        fixture:   fixture,
        size:      { side, FLOOR_THICKNESS, side },
        centre:    { side * 0.5f, -FLOOR_THICKNESS * 0.5f, side * 0.5f },
        navigable: true,
    );
    return fixture;
}

fn void build_navigation(Fixture* fixture) @private {
    float side = level_side();
    NavBuilderDesc desc = nav::default_nav_builder_desc({ .min = { 0, -1, 0 }, .max = { side, 5, side } });
    fixture.builder = nav::create_nav_builder(mem, &fixture.scene, desc)!!;
    fixture.mesh = nav::create_nav_mesh_for(mem, &fixture.builder)!!;
    NavSyncResult result = nav::nav_sync(
        builder: &fixture.builder,
        mesh:    &fixture.mesh,
        scene:   &fixture.scene,
        assets:  &fixture.assets,
        budget:  BUILD_BUDGET,
    );
    assert(result.pending == 0 && result.failed == 0);
    fixture.crowd = nav::create_crowd(
        allocator: mem,
        desc:      { .max_agents = CROWD_AGENTS, .max_agent_radius = nav::default_nav_agent_params().radius },
        mesh:      &fixture.mesh,
        scene:     &fixture.scene,
    )!!;
}

fn void teardown(Fixture* fixture) @private {
    nav::destroy_crowd(&fixture.crowd);
    nav::destroy_nav_mesh(&fixture.mesh);
    nav::destroy_nav_builder(&fixture.builder);
    character::destroy_character_system(&fixture.system);
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
    free(fixture);
}

fn Node* add_block(
    Fixture* fixture,
    Vec3 size,
    Vec3 centre,
    bool navigable,
) @private {
    GeometryId box;
    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width:     size.x,
            height:    size.y,
            depth:     size.z,
        );
        box = fixture.assets.add_geometry(&geometry)!!;
    };
    Node* node = fixture.scene.add_mesh(box, {})!!;
    node.local.position = centre;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = size * 0.5f;
    fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    if (navigable) fixture.scene.add_nav_source(node)!!;
    return node;
}

fn Node* add_driven_character(Fixture* fixture, Vec3 feet) @private {
    Scene* scene = &fixture.scene;
    Node* node = scene.add_node(name: "character")!!;
    node.local.position = feet;
    scene.update_world();
    scene.add_character(node, character::default_character_desc())!!;
    scene.add_nav_agent(node, nav::default_nav_agent_params())!!;
    scene.add_nav_driven(node)!!;
    return node;
}

fn void steer(Fixture* fixture) @private {
    fixture.scene.update_world();
    nav::crowd_update(&fixture.scene, &fixture.crowd, fixture.physics.desc.tuning.fixed_dt);
    character::drive_characters(&fixture.scene, &fixture.crowd);
}

fn void step(Fixture* fixture) @private {
    fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
    fixture.scene.update_world();
}

fn void run_frames(Fixture* fixture, uint frames) @private {
    for (uint frame = 0; frame < frames; frame++) {
        steer(fixture);
        step(fixture);
    }
}

fn Character* character_of(Fixture* fixture, Node* node) @private => fixture.scene.get(node, Character);

fn CrowdAgent* agent_of(Fixture* fixture, Node* node) @private {
    return fixture.crowd.agent(fixture.scene.get(node, CrowdAgentRuntime).index);
}

fn float xz_distance(Vec3 first, Vec3 second) @private {
    Vec3 offset = second - first;
    offset.y = 0;
    return offset.length();
}

fn float segment_distance(Vec3 point, Vec3 from, Vec3 to) @private {
    Vec3 along = to - from;
    float t = math::clamp((point - from).dot(along) / along.length_sq(), 0.0f, 1.0f);
    return (point - (from + along * t)).length();
}

fn float traversal_distance(AgentAnimation traversal, Vec3 point) @private {
    float approach = segment_distance(point, traversal.initial_position, traversal.start);
    return math::min(approach, segment_distance(point, traversal.start, traversal.end));
}

fn void test_nav_driven_character_follows_the_agent_velocity() @test {
    Fixture* fixture = setup();
    defer teardown(fixture);
    build_navigation(fixture);
    Node* node = add_driven_character(fixture, START);
    fixture.scene.set_nav_target(node, TARGET);

    for (uint frame = 0; frame < ARRIVAL_UPDATES; frame++) {
        Vec3 written = node.local.position;
        steer(fixture);
        assert(node.local.position == written, "frame %d: the crowd wrote the node", frame);
        step(fixture);
        assert(character_of(fixture, node).grounded, "frame %d: left the ground", frame);
    }

    float reach = character_of(fixture, node).desc.radius + agent_of(fixture, node).params.radius;
    float distance = xz_distance(node.world_position(), TARGET);
    assert(distance < reach, "%f m from the target", distance);
}

fn void test_nav_driven_character_collides_with_physics_the_crowd_cannot_see() @test {
    Fixture* fixture = setup();
    defer teardown(fixture);
    add_block(
        fixture:   fixture,
        size:      BLOCK_SIZE,
        centre:    { BLOCK_X, BLOCK_SIZE.y * 0.5f, START.z },
        navigable: false,
    );
    build_navigation(fixture);
    Node* node = add_driven_character(fixture, START);
    fixture.scene.set_nav_target(node, TARGET);

    run_frames(fixture, BLOCKED_UPDATES);

    Character* blocked = character_of(fixture, node);
    CrowdAgent* agent = agent_of(fixture, node);
    float stop_x = BLOCK_X - BLOCK_SIZE.x * 0.5f - blocked.desc.radius - blocked.desc.skin;
    assert(math::abs(blocked.current.x - stop_x) < STOP_TOLERANCE, "stopped at the block, at %f", blocked.current.x);
    assert(agent.velocity.length() > STOPPED_SPEED, "the agent still moves");
    assert(agent.velocity.normalize().x > THROUGH_ALIGNMENT, "the agent heads through the block");
}

fn void test_add_nav_driven_needs_an_agent() @test {
    Fixture* fixture = setup();
    defer teardown(fixture);
    build_navigation(fixture);
    Scene* scene = &fixture.scene;
    Node* node = scene.add_node()!!;
    node.local.position = START;
    scene.update_world();
    scene.add_character(node, character::default_character_desc())!!;

    assert(@catch(scene.add_nav_driven(node)) == character::NO_NAV_AGENT);
    scene.add_nav_agent(node, nav::default_nav_agent_params())!!;
    scene.add_nav_driven(node)!!;
    assert(scene.get(node, NavAgent).driven);
    assert(@catch(scene.add_nav_driven(node)) == character::NAV_DRIVEN_EXISTS);
}

fn void test_remove_nav_driven_returns_control() @test {
    Fixture* fixture = setup();
    defer teardown(fixture);
    build_navigation(fixture);
    Scene* scene = &fixture.scene;
    Node* released = add_driven_character(fixture, START);
    Vec3 orphan_start = START + (Vec3){ 0, 0, RELEASED_OFFSET_Z };
    Node* orphaned = add_driven_character(fixture, orphan_start);
    scene.set_nav_target(orphaned, { TARGET.x, 0, orphan_start.z });
    run_frames(fixture, STEER_UPDATES);
    assert(character_of(fixture, orphaned).desired.length() > STOPPED_SPEED, "the agent steers the character");

    scene.remove_nav_driven(released);
    scene.remove_component(orphaned, NavAgent);
    assert(!scene.get(released, NavAgent).driven);
    float start_x = released.world_position().x;
    scene.move_character(released, { -WALK_SPEED, 0, 0 });
    run_frames(fixture, WALK_UPDATES);

    assert(released.world_position().x < start_x - MIN_WALK, "the application's intent moves the node");
    assert(character_of(fixture, orphaned).desired == (Vec3){}, "a driven character without an agent stops");
}

fn void test_off_mesh_link_moves_the_capsule_along_the_connection() @test {
    Fixture* fixture = setup();
    defer teardown(fixture);
    Scene* scene = &fixture.scene;
    Node* platform = add_block(
        fixture:   fixture,
        size:      PLATFORM_SIZE,
        centre:    PLATFORM_CENTRE,
        navigable: true,
    );
    float edge = PLATFORM_CENTRE.x - PLATFORM_SIZE.x * 0.5f;
    Node* link = scene.add_node()!!;
    scene.update_world();
    scene.add_nav_link(link, {
        .start  = { edge - LINK_RUN, 0, PLATFORM_CENTRE.z },
        .end    = { edge + LINK_RUN, PLATFORM_SIZE.y, PLATFORM_CENTRE.z },
        .radius = LINK_RADIUS,
        .area   = nav::WALKABLE_AREA,
    })!!;
    build_navigation(fixture);
    Node* node = add_driven_character(fixture, START);
    scene.set_nav_target(node, { PLATFORM_CENTRE.x, PLATFORM_SIZE.y, PLATFORM_CENTRE.z });

    uint traversing;
    uint landed;
    for (uint frame = 0; frame < ARRIVAL_UPDATES && landed < LANDING_UPDATES; frame++) {
        steer(fixture);
        step(fixture);
        AgentAnimation traversal = scene.get(node, NavDriven).traversal;
        if (traversal.active) {
            traversing++;
            float off_path = traversal_distance(traversal, node.world_position());
            assert(off_path < PATH_TOLERANCE, "%f m off the traversal", off_path);
        } else if (traversing) {
            landed++;
        }
    }

    Character* character = character_of(fixture, node);
    assert(traversing > 0, "the agent crossed the link");
    assert(character.grounded && c3d::same_id(character.ground, platform.id), "stands on the platform");
    assert(math::abs(node.world_position().y - PLATFORM_SIZE.y) < character.desc.skin + STOP_TOLERANCE);
}

fn void test_shift_characters_moves_the_traversal() @test {
    Fixture* fixture = setup();
    defer teardown(fixture);
    build_navigation(fixture);
    Scene* scene = &fixture.scene;
    Node* node = add_driven_character(fixture, START);
    Vec3 offset = { SHIFT_OFFSET, 0, 0 };
    NavDriven* driven = scene.get(node, NavDriven);
    driven.traversal = {
        .active           = true,
        .initial_position = { 300, 0, 4 },
        .start            = { 310, 1, 4 },
        .end              = { 320, 2, 5 },
    };

    scene.shift_characters(offset);
    assert(driven.traversal.initial_position == (Vec3){ 44, 0, 4 });
    assert(driven.traversal.start == (Vec3){ 54, 1, 4 });
    assert(driven.traversal.end == (Vec3){ 64, 2, 5 });
    assert(driven.traversal.active);
}
