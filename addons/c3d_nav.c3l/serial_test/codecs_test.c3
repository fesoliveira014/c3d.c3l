module c3d_nav_serial_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::nav @public;
import c3d::scene;
import c3d::serial;
import std::core::mem::allocators;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    Node* root;
}

fn void create_fixture(Fixture* fixture, uint capacity = 16) @private {
    nav::register_serial_codecs()!!;
    serial::register_core_codecs()!!;
    fixture.assets = asset::create_asset_store(mem, { .max_geometries = 2, .max_textures = 8, .max_materials = 2, .max_samplers = 8 });
    fixture.source = scene::create_scene(mem, { .max_nodes = 16 });
    fixture.destination = scene::create_scene(mem, { .max_nodes = capacity });
    nav::register_nav(&fixture.source)!!;
    nav::register_nav(&fixture.destination)!!;
    GeometryId geometry;
    @pool() {
        Geometry plane = geometry::plane(
            allocator: tmem,
            width: 20,
            depth: 20,
            segments_x: 1,
            segments_z: 1,
        );
        geometry = fixture.assets.add_geometry(&plane, "floor")!!;
    };
    fixture.root = fixture.source.add_node(name: "navigation")!!;
    fixture.source.add_nav_source(
        node: fixture.root,
        geometry: geometry,
        walkable: true,
        area: nav::WALKABLE_AREA,
    )!!;
    Node* implicit = fixture.source.add_mesh(geometry: geometry, material: {}, parent: fixture.root)!!;
    fixture.source.add_nav_source(implicit)!!;
    for (uint index = 0; index < 3; index++) {
        Node* node = fixture.source.add_node(fixture.root, "settings")!!;
        NavVolume volume = {
            .kind = (VolumeKind)index,
            .area = 2,
            .box = { .min = { -2, -1, -2 }, .max = { 2, 2, 2 } },
            .verts = { [0] = { -2, 0, -2 }, [1] = { 2, 0, -2 }, [2] = { 2, 0, 2 }, [3] = { -2, 0, 2 } },
            .vert_count = 4,
            .min_y = -1,
            .max_y = 2,
            .base = { 1, 0, 1 },
            .radius = 0.5f,
            .height = 1,
        };
        fixture.source.add_nav_volume(node, volume)!!;
        fixture.source.add_nav_obstacle(node, {
            .kind = (ObstacleKind)index,
            .position = { -3, 0, -3 },
            .radius = 0.3f,
            .height = 1,
            .box = { .min = { -4, -1, -4 }, .max = { -3, 1, -3 } },
            .half_extents = { 0.3f, 0.7f, 0.4f },
        })!!;
        fixture.source.add_nav_link(node, {
            .start = { -5, 0, -5 },
            .end = { 5, 0, 5 },
            .radius = 0.5f,
            .bidirectional = true,
            .area = 3,
            .flags = 32769,
            .user_id = 12345 + index,
        })!!;
        NavAgentParams params = nav::default_nav_agent_params();
        params.radius = 0.35f;
        params.height = 1.7f;
        params.max_acceleration = 11;
        params.max_speed = 3;
        params.collision_query_range = 4;
        params.path_optimization_range = 9;
        params.separation_weight = 2.5f;
        params.update_flags = { .anticipate_turns = true, .separation = true, .optimize_visibility = true };
        params.obstacle_avoidance_type = 2;
        params.query_filter_type = 3;
        fixture.source.add_nav_agent(node, params)!!;
        NavAgent* agent = fixture.source.get(node, NavAgent);
        agent.target_kind = (AgentTargetKind)index;
        agent.target = { 6, 0, 3 };
        agent.driven = true;
        agent.changed = true;
        fixture.source.get(node, NavVolume).changed = true;
        fixture.source.get(node, NavObstacle).changed = true;
        fixture.source.get(node, NavLink).changed = true;
    }
    fixture.source.update_world();
}

fn void destroy_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    asset::destroy_asset_store(&fixture.assets);
}

fn char[]? encode(
    Scene* scene,
    AssetStore* assets,
    Node* root,
    bool text_mode,
) @private {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    );
}

fn Node*? decode(
    Fixture* fixture,
    char[] bytes,
    bool text_mode,
    serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT,
) @private {
    if (text_mode) return serial::read_subtree_text(
        scene: &fixture.destination,
        assets: &fixture.assets,
        text: (String)bytes,
        options: options,
    );
    return serial::read_subtree(
        scene: &fixture.destination,
        assets: &fixture.assets,
        bytes: bytes,
        options: options,
    );
}

fn void test_serial_registration_and_schema() @test {
    nav::register_serial_codecs()!!;
    assert(serial::described_type(nav::NavSourceAuthoring)!!.layout == 0x92e51405ee3d3b38);
    assert(serial::described_type(nav::NavVolumeAuthoring)!!.layout == 0x751ce47375bc297a);
    assert(serial::described_type(nav::NavLinkAuthoring)!!.layout == 0xf6e1d7fd06715801);
    assert(serial::described_type(nav::NavObstacleAuthoring)!!.layout == 0x86fb0afd9d99f20b);
    assert(serial::described_type(nav::NavAgentParamsAuthoring)!!.layout == 0x1c765a3b425abafa);
    assert(serial::described_type(nav::NavAgentAuthoring)!!.layout == 0xe9692a3bee8bc525);
    @pool() {
        String schema = serial::write_schema(tmem)!!;
        assert(schema.contains("nav_agent") && schema.contains("nav_link"));
        assert(schema.contains("target_kind") && schema.contains("obstacle_avoidance_type"));
    };
}

fn void test_navigation_both_encodings_restore_authoring_before_normal_sync() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            assert(bytes == encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!);
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            assert(fixture.destination.count(NavSource) == 2 && fixture.destination.count(NavAgent) == 3);
            assert(fixture.destination.count(NavSourceRuntime) == 0 && fixture.destination.count(CrowdAgentRuntime) == 0);
            assert(fixture.destination.count(NavVolumeRuntime) == 0 && fixture.destination.count(NavLinkRuntime) == 0);
            assert(fixture.destination.count(NavObstacleRuntime) == 0);
            fixture.destination.@each(NavAgent; entity, agent) {
                assert(!agent.changed && agent.driven && agent.params.query_filter_type == 3);
                assert(agent.params.max_acceleration == 11 && agent.params.obstacle_avoidance_type == 2);
                assert((char)agent.params.update_flags == 13 && agent.target == (Vec3){ 6, 0, 3 });
            };
            fixture.destination.@each(NavVolume; entity, volume) {
                assert(!volume.changed && volume.vert_count == 4 && volume.verts[3] == (Vec3){ -2, 0, 2 });
            };
            fixture.destination.@each(NavLink; entity, link) {
                assert(!link.changed && link.flags == 32769 && link.user_id >= 12345);
            };
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
            NavBuilderDesc desc = nav::default_nav_builder_desc({ .min = { -10, -1, -10 }, .max = { 10, 4, 10 } });
            desc.cache_layers = true;
            NavBuilder builder = nav::create_nav_builder(mem, &fixture.destination, desc)!!;
            defer nav::destroy_nav_builder(&builder);
            NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!!;
            defer nav::destroy_nav_mesh(&mesh);
            NavSyncResult result = nav::nav_sync(
                builder: &builder,
                mesh: &mesh,
                scene: &fixture.destination,
                assets: &fixture.assets,
                budget: 32,
            );
            assert(result.failed == 0 && result.pending == 0);
            assert(fixture.destination.count(NavSourceRuntime) == 2 && fixture.destination.count(NavVolumeRuntime) == 3);
            assert(fixture.destination.count(NavLinkRuntime) == 3 && fixture.destination.count(NavObstacleRuntime) == 3);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
            Crowd crowd = nav::create_crowd(
                allocator: mem,
                desc: { .max_agents = 4, .max_agent_radius = 1 },
                mesh: &mesh,
                scene: &fixture.destination,
            )!!;
            defer nav::destroy_crowd(&crowd);
            nav::crowd_update(&fixture.destination, &crowd, 0.01f);
            assert(fixture.destination.count(CrowdAgentRuntime) == 3);
        };
    }
}

fn void test_navigation_invalid_authoring_and_reader_failure_roll_back() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            uint before = fixture.destination.world.entities.free_count;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            fixture.source.@each(NavAgent; entity, agent) { agent.params.radius = -1; };
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.@each(NavAgent; entity, agent) { agent.params.radius = 0.35f; };
            char[] invalid = invalid_agent_radius(bytes, text_mode);
            assert(@catch(decode(&fixture, invalid, text_mode)) == c3d::INVALID_ARGUMENT);
            assert(fixture.destination.world.entities.free_count == before && fixture.destination.count(NavAgent) == 0);
            NullAllocator failed;
            serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
            options.allocator = &failed;
            assert(@catch(decode(
                fixture: &fixture,
                bytes: bytes,
                text_mode: text_mode,
                options: options,
            )) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.world.entities.free_count == before);
        };
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, 3);
            defer destroy_fixture(&fixture);
            uint before = fixture.destination.world.entities.free_count;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            assert(@catch(decode(&fixture, bytes, text_mode)) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.world.entities.free_count == before);
        };
    }
}
