module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::material;
import c3d::physics @public;
import c3d::scene;
import c3d::serial @public;
import std::math::vector;

const char[*] HEIGHT_FIELD_V1_BINARY @private = $embed("fixtures/height_field_v1.bin");
const char[*] HEIGHT_FIELD_V1_TEXT @private = $embed("fixtures/height_field_v1.json");
const char[*] HEIGHT_FIELD_V2_BINARY @private = $embed("fixtures/height_field_v2.bin");
const char[*] HEIGHT_FIELD_V2_TEXT @private = $embed("fixtures/height_field_v2.json");
const char[*] HEIGHT_FIELD_WINDOWS_V1_BINARY @private = $embed("fixtures/height_field_windows_v1.bin");
const char[*] HEIGHT_FIELD_WINDOWS_V1_TEXT @private = $embed("fixtures/height_field_windows_v1.json");
const char[*] ANCHORED_BREAKABLE_V1_BINARY @private = $embed("fixtures/anchored_breakable_v1.bin");
const char[*] ANCHORED_BREAKABLE_V1_TEXT @private = $embed("fixtures/anchored_breakable_v1.json");
const char[*] ANCHORED_BREAKABLE_V2_BINARY @private = $embed("fixtures/anchored_breakable_v2.bin");
const char[*] ANCHORED_BREAKABLE_V2_TEXT @private = $embed("fixtures/anchored_breakable_v2.json");

const uint MAP_SAMPLES @private = 5; // four cells, two 2-cell windows along each axis
const uint WINDOW_CELLS @private = 2;
const uint WINDOW_COUNT @private = 4;
const uint SMALL_SCENE_NODES @private = 4; // the root and the document node leave room for two windows of four

fn TextureId add_map(Fixture* fixture) @private {
    ushort[MAP_SAMPLES * MAP_SAMPLES] samples;
    foreach (index, &sample : samples) *sample = (ushort)(index * 1000);
    TextureDesc desc = material::texture_2d_desc(MAP_SAMPLES, MAP_SAMPLES, R16_UINT);
    desc.generate_mips = false;
    return fixture.assets.add_texture(desc, ((char*)&samples)[:samples.len * ushort::size], "terrain_heights")!!;
}

fn void test_height_field_windows_round_trip_regenerates_the_windows_once() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
            collider.height_field = { .source = TEXTURE, .texture = add_map(&fixture) };
            collider.local.scale = { 2, 10, 2 };
            physics::add_height_field_windows(
                scene:        &fixture.source,
                assets:       &fixture.assets,
                node:         fixture.root.id,
                collider:     &collider,
                window_cells: WINDOW_CELLS,
            )!!;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            assert(!((String)bytes).contains("terrain_window"));
            assert(!((String)bytes).contains("physics_body"));

            Node* restored = decode(&fixture, bytes, text_mode)!!;
            HeightFieldWindows* windows = fixture.destination.get(restored, HeightFieldWindows);
            assert(windows.window_cells == WINDOW_CELLS && windows.nodes.len == WINDOW_COUNT);
            assert(fixture.destination.count(HeightFieldWindows) == 1);
            assert(fixture.destination.count(HeightFieldWindowOwner) == WINDOW_COUNT);
            assert(fixture.destination.count(PhysicsBody) == WINDOW_COUNT);
            uint children;
            for (Node* child = restored.first_child; child; child = child.next_sibling) children++;
            assert(children == WINDOW_COUNT);

            foreach (index, entity : windows.nodes) {
                Node* window = fixture.destination.node(entity);
                assert(window.parent == restored);
                PhysicsBody* body = fixture.destination.get(window, PhysicsBody);
                HeightFieldWindow cells = body.colliders[0].height_field.window;
                assert(cells.count_x == WINDOW_CELLS && cells.count_z == WINDOW_CELLS);
                assert(cells.x == (index % 2) * WINDOW_CELLS && cells.z == (index / 2) * WINDOW_CELLS);
                assert(window.local.position == (Vec3){ (float)cells.x * 2, 0, (float)cells.z * 2 });
            }
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
        };
    }
}

fn void test_height_field_windows_load_that_runs_out_of_nodes_leaves_nothing_behind() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, mem, SMALL_SCENE_NODES);
            defer destroy_fixture(&fixture);

            ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
            collider.height_field = { .source = TEXTURE, .texture = add_map(&fixture) };
            physics::add_height_field_windows(
                scene:        &fixture.source,
                assets:       &fixture.assets,
                node:         fixture.root.id,
                collider:     &collider,
                window_cells: WINDOW_CELLS,
            )!!;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;

            uint free_nodes = fixture.destination.world.entities.free_count;
            assert(@catch(decode(&fixture, bytes, text_mode)) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.world.entities.free_count == free_nodes);
            assert(fixture.destination.count(HeightFieldWindows) == 0 && fixture.destination.count(PhysicsBody) == 0);
            assert(fixture.destination.count(HeightFieldWindowOwner) == 0);
        };
    }
}

fn void test_height_field_windows_export_rejects_an_edited_window_node() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
            collider.height_field = { .source = TEXTURE, .texture = add_map(&fixture) };
            physics::add_height_field_windows(
                scene:        &fixture.source,
                assets:       &fixture.assets,
                node:         fixture.root.id,
                collider:     &collider,
                window_cells: WINDOW_CELLS,
            )!!;
            Node* window = fixture.source.node(fixture.source.get(fixture.root, HeightFieldWindows).nodes[1]);
            fixture.source.reparent(window, fixture.source.root);

            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
    }
}

fn void test_height_field_v1_body_loads_with_a_zero_window() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? HEIGHT_FIELD_V1_TEXT[..] : HEIGHT_FIELD_V1_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            PhysicsBody* body = fixture.destination.get(root, PhysicsBody);
            ColliderDesc collider = body.colliders[0];
            assert(body.colliders.len == 1 && collider.kind == HEIGHT_FIELD);
            assert(collider.height_field.source == TEXTURE && c3d::same_id(collider.height_field.texture, fixture.texture));
            HeightFieldWindow window = collider.height_field.window;
            assert(!window.x && !window.z && !window.count_x && !window.count_z);
            assert(collider.local.scale == (Vec3){ 2, 3, 4 } && collider.density == 7 && collider.filter.group == 5);
        };
    }
}

fn void test_anchored_breakable_v1_loads_through_its_v1_bodies() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;

            char[] bytes = text_mode ? ANCHORED_BREAKABLE_V1_TEXT[..] : ANCHORED_BREAKABLE_V1_BINARY[..];
            (void)decode(&fixture, bytes, text_mode)!!;
            Node* owner = fixture.destination.find("physics")!!;
            assert(fixture.destination.get(owner, Breakable).state.anchor_count() == 2);
            assert(fixture.destination.count(PhysicsBody) == 2);
        };
    }
}

fn void test_height_field_v2_body_keeps_its_window() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? HEIGHT_FIELD_V2_TEXT[..] : HEIGHT_FIELD_V2_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            ColliderDesc collider = fixture.destination.get(root, PhysicsBody).colliders[0];
            assert(collider.kind == HEIGHT_FIELD && collider.height_field.source == TEXTURE);
            assert(c3d::same_id(collider.height_field.texture, fixture.texture));
            HeightFieldWindow window = collider.height_field.window;
            assert(!window.x && !window.z && window.count_x == 1 && window.count_z == 1);
            assert(collider.local.scale == (Vec3){ 2, 3, 4 } && collider.density == 7 && collider.filter.group == 5);
        };
    }
}

fn void test_height_field_windows_v1_owner_regenerates_its_windows() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            TextureId map = add_map(&fixture);

            char[] bytes = text_mode ? HEIGHT_FIELD_WINDOWS_V1_TEXT[..] : HEIGHT_FIELD_WINDOWS_V1_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            HeightFieldWindows* windows = fixture.destination.get(root, HeightFieldWindows);
            assert(windows.window_cells == WINDOW_CELLS && windows.nodes.len == WINDOW_COUNT);
            assert(c3d::same_id(windows.collider.height_field.texture, map));
            assert(windows.collider.local.scale == (Vec3){ 2, 10, 2 });
            assert(fixture.destination.count(PhysicsBody) == WINDOW_COUNT);
        };
    }
}

fn void test_anchored_breakable_v2_loads_through_its_v2_bodies() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;

            char[] bytes = text_mode ? ANCHORED_BREAKABLE_V2_TEXT[..] : ANCHORED_BREAKABLE_V2_BINARY[..];
            (void)decode(&fixture, bytes, text_mode)!!;
            Node* owner = fixture.destination.find("physics")!!;
            assert(fixture.destination.get(owner, Breakable).state.anchor_count() == 2);
            assert(fixture.destination.count(PhysicsBody) == 2);
        };
    }
}
