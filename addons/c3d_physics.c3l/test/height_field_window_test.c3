module c3d_physics_height_window_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::material;
import c3d::physics;
import c3d::scene;
import b3;

const uint  MAP_SAMPLES @private = 65; // 64 cells, two 32-cell windows along each axis
const uint  WINDOW_CELLS @private = 32;
const uint  FLAT_SAMPLES @private = 17; // 16 cells, two 8-cell windows along each axis
const uint  FLAT_WINDOW_CELLS @private = 8;
const float HEIGHT_SCALE @private = 20;
const float SAME_HIT_TOLERANCE @private = 0.00001f; // rounding only: both cook the same quantized samples
const float RAY_START_HEIGHT @private = 100;
const float RAY_LENGTH @private = 200;
const uint  SETTLE_UPDATES @private = 240;
const uint  ROLL_SETTLE_UPDATES @private = 6;
const uint  ROLL_UPDATES @private = 120;
const float SPHERE_RADIUS @private = 0.5f;
const float ROLL_SPEED @private = 4;
const float ROLL_START_X @private = 4;
const float ROLL_START_Z @private = 4;
const float CAPSULE_RADIUS @private = 0.4f;
const float CAPSULE_HALF_HEIGHT @private = 0.6f;
const float SEAM_X @private = 8;
const float SEAM_CLEARANCE @private = 1; // metres past the seam, more than either body's diameter
const float SPEED_EPSILON @private = 0.001f; // m/s; solver rounding between two cooks of one surface
const float RISE_EPSILON @private = 0.0005f; // metres; the same rounding, seen in height
const float HEADING_EPSILON @private = 0.001f; // radians; the same rounding, seen in direction
const ushort FLAT_LEVEL @private = 6554; // a tenth of the range
const uint  FLOAT_TEXEL_BYTES @private = 16;

enum Tiling @private {
    WHOLE,
    WINDOWS,
}

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
}

struct Crossing @private {
    float speed_loss;
    float rise;
    float heading_drift;
}

fn void setup(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
}

fn void teardown(Fixture* fixture) @private {
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void run_updates(Fixture* fixture, uint count) @private {
    for (uint update = 0; update < count; update++) fixture.physics.update(physics::DEFAULT_FIXED_DT);
    fixture.scene.update_world();
}

fn TextureId add_map(Fixture* fixture, uint side, ushort[] samples) @private {
    TextureDesc desc = material::texture_2d_desc(side, side, R16_UINT);
    desc.generate_mips = false;
    return fixture.assets.add_texture(desc, ((char*)samples.ptr)[:samples.len * ushort::size])!!;
}

// Hills whose lowest and highest samples are 0 and 65535, so the whole field's own range equals the window range.
fn TextureId add_hill_map(Fixture* fixture) @private {
    ushort[] samples = alloc::new_array(tmem, ushort, (sz)(MAP_SAMPLES * MAP_SAMPLES));
    for (uint z = 0; z < MAP_SAMPLES; z++) {
        for (uint x = 0; x < MAP_SAMPLES; x++) {
            float column = (float)x;
            float row = (float)z;
            float wave = 0.5f + 0.35f * math::sin(column * 0.31f) * math::cos(row * 0.23f) + 0.1f * math::sin((column + row) * 0.11f);
            samples[z * MAP_SAMPLES + x] = (ushort)math::round(wave * 65535);
        }
    }
    samples[0] = 0;
    samples[samples.len - 1] = 65535;
    return add_map(fixture, MAP_SAMPLES, samples);
}

fn TextureId add_flat_map(Fixture* fixture) @private {
    ushort[] samples = alloc::new_array(tmem, ushort, (sz)(FLAT_SAMPLES * FLAT_SAMPLES));
    samples[..] = FLAT_LEVEL;
    return add_map(fixture, FLAT_SAMPLES, samples);
}

fn ColliderDesc map_collider(TextureId texture) @private {
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = texture };
    collider.local.scale = { 1, HEIGHT_SCALE, 1 };
    return collider;
}

fn Node* add_terrain_node(Fixture* fixture) @private {
    Node* node = fixture.scene.add_node(name: "terrain")!!;
    fixture.scene.update_world();
    return node;
}

fn Node* add_window_terrain(Fixture* fixture, ColliderDesc* collider, uint window_cells) @private {
    Node* terrain = add_terrain_node(fixture);
    physics::add_height_field_windows(
        scene:        &fixture.scene,
        assets:       &fixture.assets,
        node:         terrain.id,
        collider:     collider,
        window_cells: window_cells,
    )!!;
    fixture.physics.update(0);
    return terrain;
}

fn Node* add_sphere(
    Fixture* fixture,
    Vec3 position,
    Vec3 velocity = {},
    Vec3 spin = {},
) @private {
    Node* node = fixture.scene.add_node(name: "sphere")!!;
    node.local.position = position;
    fixture.scene.update_world();
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = velocity;
    body.angular_velocity = spin;
    ColliderDesc collider = physics::default_collider_desc(SPHERE);
    collider.radius = SPHERE_RADIUS;
    fixture.physics.add_body(node, body, (&collider)[:1])!!;
    return node;
}

// Friction and rotation are off, so a seam is the only thing that can slow it or lift it.
fn Node* add_capsule(Fixture* fixture, Vec3 position, Vec3 velocity) @private {
    Node* node = fixture.scene.add_node(name: "capsule")!!;
    node.local.position = position;
    fixture.scene.update_world();
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = velocity;
    body.locks = { .angular_x = true, .angular_y = true, .angular_z = true };
    ColliderDesc collider = physics::default_collider_desc(CAPSULE);
    collider.radius = CAPSULE_RADIUS;
    collider.half_height = CAPSULE_HALF_HEIGHT;
    collider.material.friction = 0;
    fixture.physics.add_body(node, body, (&collider)[:1])!!;
    return node;
}

fn void add_flat_terrain(Fixture* fixture, Tiling tiling) @private {
    ColliderDesc collider = map_collider(add_flat_map(fixture));
    switch (tiling) {
        case WHOLE:
            Node* terrain = add_terrain_node(fixture);
            fixture.physics.add_body(terrain, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        case WINDOWS:
            add_window_terrain(fixture, &collider, FLAT_WINDOW_CELLS);
    }
}

fn Crossing measure_crossing(Fixture* fixture, Node* body) @private {
    run_updates(fixture, ROLL_SETTLE_UPDATES);

    float resting_height = body.world_position().y;
    float slowest = ROLL_SPEED;
    float highest = resting_height;
    float heading_drift;
    for (uint update = 0; update < ROLL_UPDATES; update++) {
        run_updates(fixture, 1);
        Vec3 velocity = fixture.physics.body_state(body).linear_velocity;
        slowest = math::min(slowest, velocity.x);
        highest = math::max(highest, body.world_position().y);
        heading_drift = math::max(heading_drift, math::abs(math::atan2(velocity.z, velocity.x)));
    }

    assert(body.world_position().x > SEAM_X + SEAM_CLEARANCE);
    return {
        .speed_loss    = ROLL_SPEED - slowest,
        .rise          = highest - resting_height,
        .heading_drift = heading_drift,
    };
}

fn Crossing roll_sphere_across_the_seam(Tiling tiling) @private {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_flat_terrain(&fixture, tiling);
    float ground = FLAT_LEVEL * HEIGHT_SCALE / 65535;
    Node* sphere = add_sphere(
        fixture:  &fixture,
        position: { ROLL_START_X, ground + SPHERE_RADIUS, ROLL_START_Z },
        velocity: { ROLL_SPEED, 0, 0 },
        spin:     { 0, 0, -ROLL_SPEED / SPHERE_RADIUS },
    );
    return measure_crossing(&fixture, sphere);
}

fn Crossing slide_capsule_across_the_seam(Tiling tiling) @private {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_flat_terrain(&fixture, tiling);
    float ground = FLAT_LEVEL * HEIGHT_SCALE / 65535;
    Node* capsule = add_capsule(
        &fixture,
        { ROLL_START_X, ground + CAPSULE_HALF_HEIGHT + CAPSULE_RADIUS, ROLL_START_Z },
        { ROLL_SPEED, 0, 0 },
    );
    return measure_crossing(&fixture, capsule);
}

fn void assert_crosses_like_the_whole_field(Crossing windows, Crossing whole) @private {
    assert(windows.speed_loss <= whole.speed_loss + SPEED_EPSILON);
    assert(windows.rise <= whole.rise + RISE_EPSILON);
    assert(windows.heading_drift <= whole.heading_drift + HEADING_EPSILON);
}

fn fault add_body_fault(Fixture* fixture, ColliderDesc collider) @private {
    Node* node = fixture.scene.add_node(name: "probe")!!;
    fixture.scene.update_world();
    if (catch excuse = fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])) {
        assert(!fixture.scene.has(node, PhysicsBody));
        return excuse;
    }
    return {};
}

fn RayHit? cast_down(Fixture* fixture, float x, float z) @private {
    return fixture.physics.raycast({ x, RAY_START_HEIGHT, z }, { 0, -1, 0 }, RAY_LENGTH);
}

fn void test_height_field_windows_match_the_whole_field() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Vec2[13] points = {
        { 0.5f, 0.5f }, { 31.5f, 31.5f }, { 32, 32 }, { 32, 10.25f }, { 10.25f, 32 }, { 32.25f, 32.25f },
        { 63.5f, 63.5f }, { 40.125f, 8.5f }, { 8.5f, 40.125f }, { 63.875f, 1.5f }, { 1.5f, 63.875f },
        { 31.5f, 30.5f }, { 33.5f, 34.5f },
    };
    char[64 * 64] indices;
    indices[30 * 64 + 31] = physics::HEIGHT_FIELD_HOLE;
    indices[34 * 64 + 33] = physics::HEIGHT_FIELD_HOLE;
    SurfaceMaterialDesc material = physics::default_surface_material();
    TextureId texture = add_hill_map(&fixture);
    ColliderDesc collider = map_collider(texture);
    collider.material_indices = indices[..];
    collider.face_materials = (&material)[:1];

    Node* whole_node = add_terrain_node(&fixture);
    fixture.physics.add_body(whole_node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    RayHit[points.len] whole;
    bool[points.len] whole_hit;
    foreach (index, point : points) {
        RayHit? hit = cast_down(&fixture, point.x, point.y);
        if (try hit) {
            whole[index] = hit;
            whole_hit[index] = true;
        }
    }
    fixture.physics.remove_body(whole_node);

    Node* terrain = add_window_terrain(&fixture, &collider, WINDOW_CELLS);
    assert(fixture.scene.get(terrain, HeightFieldWindows).nodes.len == 4);
    assert(fixture.physics.counters().occupied_snapshots == 5);
    uint holes;
    foreach (index, point : points) {
        RayHit? tiled = cast_down(&fixture, point.x, point.y);
        if (!whole_hit[index]) {
            assert(@catch(tiled) == b3::NO_HIT);
            holes++;
            continue;
        }
        RayHit expected = whole[index];
        RayHit actual = tiled!!;
        assert(math::abs(actual.point.y - expected.point.y) < SAME_HIT_TOLERANCE);
        assert(math::abs(actual.normal.x - expected.normal.x) < SAME_HIT_TOLERANCE);
        assert(math::abs(actual.normal.y - expected.normal.y) < SAME_HIT_TOLERANCE);
        assert(math::abs(actual.normal.z - expected.normal.z) < SAME_HIT_TOLERANCE);
        assert(actual.node.parent == terrain);
    }
    assert(holes == 2);
}

fn void test_window_edit_marks_every_sharing_window() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    ColliderDesc collider = map_collider(add_flat_map(&fixture));
    Node* terrain = add_window_terrain(&fixture, &collider, FLAT_WINDOW_CELLS);
    assert(fixture.physics.counters().pending_bodies == 0);

    SampleRect[9] rects = {
        { .x = 3, .z = 3, .columns = 2, .rows = 2 },
        { .x = 8, .z = 3, .columns = 1, .rows = 2 },
        { .x = 3, .z = 8, .columns = 2, .rows = 1 },
        { .x = 8, .z = 8, .columns = 1, .rows = 1 },
        { .x = 0, .z = 0, .columns = FLAT_SAMPLES, .rows = FLAT_SAMPLES },
        { .x = 7, .z = 3, .columns = 1, .rows = 1 },
        { .x = 9, .z = 3, .columns = 1, .rows = 1 },
        { .x = 6, .z = 3, .columns = 1, .rows = 1 },
        { .x = 9, .z = 9, .columns = 1, .rows = 1 },
    };
    uint[9] expected = { 1, 2, 2, 4, 4, 2, 2, 1, 4 };
    foreach (index, rect : rects) {
        uint marked = physics::mark_height_field_windows_changed(&fixture.scene, terrain.id, rect)!!;
        assert(marked == expected[index]);
        assert(fixture.physics.counters().pending_bodies == expected[index]);
        fixture.physics.update(0);
        assert(fixture.physics.counters().pending_bodies == 0);
    }
}

fn void test_body_on_an_unedited_window_keeps_its_contact() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    TextureId texture = add_flat_map(&fixture);
    ColliderDesc collider = map_collider(texture);
    Node* terrain = add_window_terrain(&fixture, &collider, FLAT_WINDOW_CELLS);
    float ground = FLAT_LEVEL * HEIGHT_SCALE / 65535;
    Node* sphere = add_sphere(&fixture, { 3, ground + SPHERE_RADIUS, 3 });
    run_updates(&fixture, SETTLE_UPDATES);
    assert(!fixture.physics.body_state(sphere).awake);
    uint contacts = fixture.physics.counters().contacts;
    Vec3 resting = sphere.world_position();
    assert(contacts >= 1);

    ushort* texels = (ushort*)fixture.assets.texture(texture).pixels.ptr;
    for (uint z = 12; z < 15; z++) {
        for (uint x = 12; x < 15; x++) texels[z * FLAT_SAMPLES + x] = 3 * FLAT_LEVEL;
    }
    fixture.assets.mark_texture_dirty(texture);
    uint marked = physics::mark_height_field_windows_changed(
        &fixture.scene,
        terrain.id,
        { .x = 12, .z = 12, .columns = 3, .rows = 3 },
    )!!;
    assert(marked == 1);
    run_updates(&fixture, 4);

    assert(fixture.physics.counters().pending_bodies == 0);
    assert(!fixture.physics.body_state(sphere).awake);
    assert(fixture.physics.counters().contacts == contacts);
    assert(sphere.world_position() == resting);
    assert(cast_down(&fixture, 13, 13)!!.point.y > ground + 1);
}

fn void test_sphere_rolls_across_a_window_seam() @test {
    Crossing whole = roll_sphere_across_the_seam(WHOLE);
    Crossing windows = roll_sphere_across_the_seam(WINDOWS);

    assert_crosses_like_the_whole_field(windows, whole);
}

fn void test_capsule_slides_across_a_window_seam() @test {
    Crossing whole = slide_capsule_across_the_seam(WHOLE);
    Crossing windows = slide_capsule_across_the_seam(WINDOWS);

    assert_crosses_like_the_whole_field(windows, whole);
}

fn void test_windowed_field_validation() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    TextureId texture = add_flat_map(&fixture);
    float[4] heights;
    ColliderDesc on_heights = physics::default_collider_desc(HEIGHT_FIELD);
    on_heights.height_field = { .heights = heights[..], .count_x = 2, .count_z = 2 };
    on_heights.height_field.window = { .count_x = 1, .count_z = 1 };
    assert(add_body_fault(&fixture, on_heights) == c3d::INVALID_ARGUMENT);

    HeightFieldWindow[5] invalid = {
        { .x = 9, .z = 0, .count_x = 8, .count_z = 4 },
        { .x = 0, .z = 9, .count_x = 4, .count_z = 8 },
        { .x = 16, .z = 0, .count_x = 1, .count_z = 1 },
        { .x = 0, .z = 0, .count_x = 0, .count_z = 4 },
        { .x = 4, .z = 4, .count_x = 0, .count_z = 0 },
    };
    foreach (window : invalid) {
        ColliderDesc collider = map_collider(texture);
        collider.height_field.window = window;
        assert(add_body_fault(&fixture, collider) == c3d::INVALID_ARGUMENT);
    }

    ColliderDesc inside = map_collider(texture);
    inside.height_field.window = { .x = 8, .z = 8, .count_x = 8, .count_z = 8 };
    Node* edge_window = add_terrain_node(&fixture);
    fixture.physics.add_body(edge_window, physics::default_body_desc(STATIC), (&inside)[:1])!!;

    SurfaceMaterialDesc material = physics::default_surface_material();
    char[8 * 8] window_cells;
    char[10 * 10] ringed_cells;
    inside.face_materials = (&material)[:1];
    inside.material_indices = window_cells[..];
    assert(add_body_fault(&fixture, inside) == c3d::INVALID_ARGUMENT);
    inside.material_indices = ringed_cells[..];
    Node* ringed_window = add_terrain_node(&fixture);
    fixture.physics.add_body(ringed_window, physics::default_body_desc(STATIC), (&inside)[:1])!!;

    TextureDesc float_desc = material::texture_2d_desc(FLAT_SAMPLES, FLAT_SAMPLES, RGBA32_FLOAT);
    float_desc.generate_mips = false;
    char[] float_pixels = alloc::new_array(tmem, char, (sz)(FLAT_SAMPLES * FLAT_SAMPLES * FLOAT_TEXEL_BYTES));
    TextureId float_texture = fixture.assets.add_texture(float_desc, float_pixels)!!;
    ColliderDesc float_window = map_collider(float_texture);
    float_window.height_field.window = { .count_x = 4, .count_z = 4 };
    assert(add_body_fault(&fixture, float_window) == c3d::UNSUPPORTED);
}
