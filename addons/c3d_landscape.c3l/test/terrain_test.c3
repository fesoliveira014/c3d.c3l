module c3d_landscape_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::material;
import c3d::physics;
import c3d::scene;

const uint SMALL_TEXELS @local = 129; // one chunk, one level
const uint TWO_LEVEL_TEXELS @local = 257; // 2 x 2 finest chunks under one root
const uint FOUR_LEVEL_TEXELS @local = 1025; // 8 x 8 finest chunks, four levels
const float CELL_SIZE @local = 0.5f;
const float HEIGHT_SCALE @local = 20;
const float HEIGHT_TOLERANCE @local = 0.001f; // metres; float rounding of the rotated node and box3d's ray
const Vec3 TERRAIN_POSITION @local = { 3, -2, 5 };
const float TERRAIN_YAW_DEGREES @local = 30;
const float RAY_START_HEIGHT @local = 100; // above HEIGHT_SCALE plus the node's height
const float RAY_LENGTH @local = 200;
const uint RANDOM_POINTS @local = 256;
const ulong SEED @local = 0x7e11a1;
const float OUTPUT_HEIGHT @local = 1080;
const float CAMERA_FOV_DEGREES @local = 60;
const float CAMERA_NEAR @local = 0.1f;
const uint EDIT_SIDE @local = 9;
const ushort MAP_LOW @local = 1000; // generated maps stay inside [MAP_LOW, MAP_HIGH]; edits write 0 and 65535
const ushort MAP_HIGH @local = 64000;

struct Fixture @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    MaterialId   layer;
    Node*        camera;
}

fn void setup(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
    fixture.layer = fixture.assets.add_material(material::standard({ .base_color = { 1, 1, 1, 1 }, .roughness = 1 }))!!;
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR))!!;
}

fn void teardown(Fixture* fixture) @local {
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ulong next_random(ulong* state) @local {
    *state += 0x9e3779b97f4a7c15;
    ulong mixed = *state;
    mixed = (mixed ^ (mixed >> 30)) * 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) * 0x94d049bb133111eb;
    return mixed ^ (mixed >> 31);
}

fn float random_unit(ulong* state) @local => (float)(next_random(state) >> 40) / (float)(1ul << 24);

fn ushort middle_texel(ulong* state) @local => (ushort)(MAP_LOW + next_random(state) % (MAP_HIGH - MAP_LOW));

fn TextureId add_height_map(
    Fixture* fixture,
    uint texels,
    ulong seed,
    PixelFormat format = R16_UINT,
    bool flat = false,
) @local {
    usz texel_bytes = format == R16_UINT ? ushort::size : 4;
    TextureId texture;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)((usz)texels * texels * texel_bytes));
        ulong state = seed;
        if (format == R16_UINT && !flat) {
            foreach (&value : ((ushort*)pixels.ptr)[:(usz)texels * texels]) *value = middle_texel(&state);
        }
        TextureDesc desc = material::texture_2d_desc(texels, texels, format);
        desc.generate_mips = false;
        texture = fixture.assets.add_texture(desc, pixels)!!;
    };
    return texture;
}

fn TerrainDesc terrain_desc(Fixture* fixture, TextureId height_map) @local {
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = height_map;
    desc.cell_size = CELL_SIZE;
    desc.height_scale = HEIGHT_SCALE;
    desc.layers[0] = fixture.layer;
    return desc;
}

fn void? try_add_terrain(Fixture* fixture, Node* node, TerrainDesc desc) @local {
    return terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

fn Node* add_terrain_node(
    Fixture* fixture,
    TerrainDesc desc,
    Vec3 position = {},
    float yaw_degrees = 0,
) @local {
    Node* node = fixture.scene.add_node()!!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(yaw_degrees));
    fixture.scene.update_world();
    try_add_terrain(fixture, node, desc)!!;
    return node;
}

// The collider as docs/terrain.md builds it; kept identical by hand.
fn void add_terrain_collider(Fixture* fixture, Node* node, TerrainDesc desc) @local {
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = desc.height_map };
    collider.local.scale = { desc.cell_size, desc.height_scale, desc.cell_size };
    fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
}

fn float ray_height(Fixture* fixture, float world_x, float world_z) @local {
    return fixture.physics.raycast({ world_x, RAY_START_HEIGHT, world_z }, { 0, -1, 0 }, RAY_LENGTH)!!.point.y;
}

fn Vec3 world_point(Node* node, float local_x, float local_z) @local {
    return maths::transform_point(node.world, { local_x, 0, local_z });
}

fn void assert_heights_match(Fixture* fixture, Node* node, Vec2[] local_points) @local {
    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, node.id)!!;
    foreach (local : local_points) {
        Vec3 point = world_point(node, local.x, local.y);
        float height = terrain::sample_height(&view, point.x, point.z)!!;
        assert(math::abs(height - ray_height(fixture, point.x, point.z)) <= HEIGHT_TOLERANCE);
    }
}

// A cell inside the border: a point exactly on it can round outside the extent.
fn Vec2[] probe_points(Allocator allocator, uint texels, ulong seed) @local {
    Vec2[] points = alloc::new_array(allocator, Vec2, RANDOM_POINTS * 4);
    float inner = (float)(texels - 3) * CELL_SIZE;
    ulong state = seed;
    for (uint index = 0; index < RANDOM_POINTS; index++) {
        uint cell_x = 1 + (uint)(random_unit(&state) * (float)(texels - 3));
        uint cell_z = 1 + (uint)(random_unit(&state) * (float)(texels - 3));
        float along = random_unit(&state);
        Vec2 corner = { (float)cell_x * CELL_SIZE, (float)cell_z * CELL_SIZE };
        points[4 * index] = { CELL_SIZE + random_unit(&state) * inner, CELL_SIZE + random_unit(&state) * inner };
        points[4 * index + 1] = corner;
        points[4 * index + 2] = corner + (Vec2){ along * CELL_SIZE, 0 };
        points[4 * index + 3] = corner + (Vec2){ along * CELL_SIZE, (1 - along) * CELL_SIZE };
    }
    return points;
}

fn void camera_at(Fixture* fixture, Vec3 position, Quat rotation = quaternion::IDENTITY) @local {
    fixture.camera.local.position = position;
    fixture.camera.local.rotation = rotation;
    fixture.scene.update_world();
}

fn void? try_update(Fixture* fixture) @local {
    return terrain::update(
        scene:                &fixture.scene,
        assets:               &fixture.assets,
        camera_node:          fixture.camera,
        output_height_pixels: OUTPUT_HEIGHT,
    );
}

fn void update_terrain(Fixture* fixture) @local {
    try_update(fixture)!!;
}

fn void assert_covers_once(InstancedMesh* batch, uint texels) @local {
    uint side = (texels - 1) / terrain::CHUNK_CELLS;
    @pool() {
        uint[] hits = alloc::new_array(tmem, uint, (sz)side * side);
        foreach (chunk : batch.colors[:batch.count]) {
            uint span = (uint)chunk.z / terrain::CHUNK_CELLS;
            uint first_x = (uint)chunk.x / terrain::CHUNK_CELLS;
            uint first_z = (uint)chunk.y / terrain::CHUNK_CELLS;
            for (uint z = first_z; z < first_z + span; z++) {
                for (uint x = first_x; x < first_x + span; x++) hits[z * side + x]++;
            }
        }
        foreach (count : hits) assert(count == 1);
    };
}

fn void assert_same_bounds(TerrainRuntime* edited, TerrainRuntime* fresh) @local {
    assert(mem::equals(edited.minimum, fresh.minimum));
    assert(mem::equals(edited.maximum, fresh.maximum));
}

fn void write_random_texels(
    Fixture* fixture,
    TextureId texture,
    TexelRect rect,
    ulong seed,
) @local {
    TextureAsset* record = fixture.assets.texture(texture);
    ushort* texels = (ushort*)record.pixels.ptr;
    ulong state = seed;
    for (uint z = rect.z; z < rect.z + rect.rows; z++) {
        for (uint x = rect.x; x < rect.x + rect.columns; x++) texels[z * record.desc.width + x] = middle_texel(&state);
    }
    fixture.assets.mark_texture_dirty(texture);
}

// Every chunk whose footprint meets the rectangle gets a new minimum and maximum.
fn void write_extreme_texels(Fixture* fixture, TextureId texture, TexelRect rect) @local {
    TextureAsset* record = fixture.assets.texture(texture);
    ushort* texels = (ushort*)record.pixels.ptr;
    for (uint z = rect.z; z < rect.z + rect.rows; z++) {
        for (uint x = rect.x; x < rect.x + rect.columns; x++) {
            texels[z * record.desc.width + x] = (x + z) % 2 ? ushort::max : 0;
        }
    }
    fixture.assets.mark_texture_dirty(texture);
}

fn TextureId copy_height_map(Fixture* fixture, TextureId source) @local {
    TextureAsset* record = fixture.assets.texture(source);
    return fixture.assets.add_texture(record.desc, record.pixels)!!;
}

fn void test_heights_match_physics_ray_casts() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    Node* node = add_terrain_node(
        fixture:     &fixture,
        desc:        desc,
        position:    TERRAIN_POSITION,
        yaw_degrees: TERRAIN_YAW_DEGREES,
    );
    add_terrain_collider(&fixture, node, desc);

    @pool() {
        assert_heights_match(&fixture, node, probe_points(tmem, SMALL_TEXELS, SEED));

        TexelRect edit = { .x = 60, .z = 60, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
        write_random_texels(
            fixture: &fixture,
            texture: desc.height_map,
            rect:    edit,
            seed:    SEED + 1,
        );
        terrain::mark_dirty(&fixture.scene, node, edit);
        update_terrain(&fixture);
        fixture.scene.get(node, PhysicsBody).mark_changed();
        fixture.physics.update(0);
        assert_heights_match(&fixture, node, probe_points(tmem, SMALL_TEXELS, SEED + 2));
    };
}

fn void test_height_past_the_edge_is_not_found() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    Node* node = add_terrain_node(
        fixture:     &fixture,
        desc:        desc,
        position:    TERRAIN_POSITION,
        yaw_degrees: TERRAIN_YAW_DEGREES,
    );

    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, node.id)!!;
    float edge = (float)(SMALL_TEXELS - 1) * CELL_SIZE;
    Vec3 inside = world_point(node, edge - 0.5f * CELL_SIZE, edge - 0.5f * CELL_SIZE);
    Vec3 outside = world_point(node, edge + CELL_SIZE, edge * 0.5f);
    assert(@ok(terrain::sample_height(&view, inside.x, inside.z)));
    if (catch excuse = terrain::sample_height(&view, outside.x, outside.z)) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "A point past the edge has a height.");
    }
}

fn void test_height_maps_other_than_r16_are_unsupported() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    Node* node = add_terrain_node(&fixture, desc);

    TerrainDesc eight_bit = terrain_desc(&fixture, add_height_map(
        fixture: &fixture,
        texels:  SMALL_TEXELS,
        seed:    SEED,
        format:  RGBA8_UNORM,
    ));
    Node* other = fixture.scene.add_node()!!;
    if (catch excuse = try_add_terrain(&fixture, other, eight_bit)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "An RGBA8 height map was accepted.");
    }

    TextureAsset* record = fixture.assets.texture(desc.height_map);
    TextureAsset* replacement = fixture.assets.texture(eight_bit.height_map);
    char[] original = record.pixels;
    TextureDesc original_desc = record.desc;
    record.desc = replacement.desc;
    record.pixels = replacement.pixels;
    fixture.assets.mark_texture_dirty(desc.height_map);
    if (catch excuse = terrain::height_view(&fixture.scene, &fixture.assets, node.id)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "A view read RGBA8 texels.");
    }
    if (catch excuse = try_update(&fixture)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "An update accepted an RGBA8 replacement.");
    }
    record.desc = original_desc;
    record.pixels = original;
}

fn void test_rectangle_refresh_matches_a_fresh_build() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, TWO_LEVEL_TEXELS, SEED));
    Node* edited = add_terrain_node(&fixture, desc);
    update_terrain(&fixture);

    TexelRect inside = { .x = 10, .z = 20, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
    write_extreme_texels(&fixture, desc.height_map, inside);
    terrain::mark_dirty(&fixture.scene, edited, inside);
    update_terrain(&fixture);
    // Texel (128, 128) is a corner of all four finest chunks.
    TexelRect shared_corner = { .x = 128, .z = 128, .columns = 1, .rows = 1 };
    write_extreme_texels(&fixture, desc.height_map, shared_corner);
    terrain::mark_dirty(&fixture.scene, edited, shared_corner);
    update_terrain(&fixture);

    Node* fresh = add_terrain_node(&fixture, terrain_desc(&fixture, copy_height_map(&fixture, desc.height_map)));
    assert_same_bounds(fixture.scene.get(edited, TerrainRuntime), fixture.scene.get(fresh, TerrainRuntime));
}

fn void test_revision_bump_without_mark_dirty_rebuilds_bounds() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, TWO_LEVEL_TEXELS, SEED));
    Node* edited = add_terrain_node(&fixture, desc);
    update_terrain(&fixture);

    write_extreme_texels(&fixture, desc.height_map, { .x = 100, .z = 100, .columns = 60, .rows = 60 });
    update_terrain(&fixture);

    Node* fresh = add_terrain_node(&fixture, terrain_desc(&fixture, copy_height_map(&fixture, desc.height_map)));
    assert_same_bounds(fixture.scene.get(edited, TerrainRuntime), fixture.scene.get(fresh, TerrainRuntime));
}

fn void test_size_changing_replacement_faults_invalid_argument() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, TWO_LEVEL_TEXELS, SEED));
    Node* node = add_terrain_node(&fixture, desc);
    update_terrain(&fixture);

    TexelRect before = { .x = 10, .z = 10, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
    terrain::mark_dirty(&fixture.scene, node, before);
    TextureId smaller = add_height_map(&fixture, SMALL_TEXELS, SEED);
    TextureAsset* record = fixture.assets.texture(desc.height_map);
    char[] original = record.pixels;
    TextureDesc original_desc = record.desc;
    record.desc = fixture.assets.texture(smaller).desc;
    record.pixels = fixture.assets.texture(smaller).pixels;
    fixture.assets.mark_texture_dirty(desc.height_map);
    if (catch excuse = try_update(&fixture)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "A smaller replacement was accepted.");
    }
    assert(fixture.scene.get(node, TerrainRuntime).texels == TWO_LEVEL_TEXELS);
    assert(fixture.scene.get(node, InstancedMesh).count == 0);

    // A conforming replacement after the rejection rebuilds everything, not the rectangle marked before it.
    TextureId conforming = add_height_map(&fixture, TWO_LEVEL_TEXELS, SEED + 4);
    record.desc = fixture.assets.texture(conforming).desc;
    record.pixels = fixture.assets.texture(conforming).pixels;
    fixture.assets.mark_texture_dirty(desc.height_map);
    update_terrain(&fixture);
    assert(fixture.scene.get(node, InstancedMesh).count > 0);
    Node* fresh = add_terrain_node(&fixture, terrain_desc(&fixture, copy_height_map(&fixture, desc.height_map)));
    assert_same_bounds(fixture.scene.get(node, TerrainRuntime), fixture.scene.get(fresh, TerrainRuntime));
    record.desc = original_desc;
    record.pixels = original;

    Node* other = fixture.scene.add_node()!!;
    TerrainDesc odd = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS + 1, SEED));
    if (catch excuse = try_add_terrain(&fixture, other, odd)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "A 130-texel height map was accepted.");
    }
}

fn void test_invalid_desc_values_are_invalid_argument() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;

    TerrainDesc gap = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    gap.layers[2] = fixture.layer;
    if (catch excuse = try_add_terrain(&fixture, node, gap)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "A layer after an unset one was accepted.");
    }
    TerrainDesc flat_cells = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    flat_cells.cell_size = 0;
    if (catch excuse = try_add_terrain(&fixture, node, flat_cells)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "A zero cell size was accepted.");
    }
    assert(!fixture.scene.has(node, Terrain) && !fixture.scene.has(node, InstancedMesh));
}

fn void test_selection_ignores_camera_facing() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_terrain_node(&fixture, terrain_desc(&fixture, add_height_map(&fixture, FOUR_LEVEL_TEXELS, SEED)));
    TerrainRuntime* runtime = fixture.scene.get(node, TerrainRuntime);
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    Vec3 position = { 60, 30, 90 };

    camera_at(&fixture, position);
    update_terrain(&fixture);
    assert_covers_once(batch, FOUR_LEVEL_TEXELS);
    assert(runtime.chunks_per_level[0] > 0 && runtime.chunks_per_level[runtime.level_count - 1] == 0);
    uint count = batch.count;
    uint revision = batch.revision;
    @pool() {
        Vec4[] first = alloc::new_array(tmem, Vec4, (sz)count);
        first[..] = batch.colors[:count];
        Quat[3] turns = {
            quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::deg_to_rad(90)),
            quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::deg_to_rad(200)),
            quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::deg_to_rad(-60)),
        };
        foreach (turn : turns) {
            camera_at(&fixture, position, turn);
            update_terrain(&fixture);
            assert(runtime.lod_switches == 0 && batch.revision == revision);
            assert(batch.count == count);
            assert(mem::equals(batch.colors[:count], first));
        }
    };
}

fn void test_split_and_merge_follow_the_hysteresis_band() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(
        fixture: &fixture,
        texels:  TWO_LEVEL_TEXELS,
        seed:    SEED,
        flat:    true,
    ));
    Node* node = add_terrain_node(&fixture, desc);
    TerrainRuntime* runtime = fixture.scene.get(node, TerrainRuntime);
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    float extent = (float)(TWO_LEVEL_TEXELS - 1) * CELL_SIZE;
    Vec3 center = { extent * 0.5f, 0, extent * 0.5f };
    float diameter = extent * math::SQRT2;
    Camera* lens = fixture.scene.get(fixture.camera, Camera);
    float pixels_per_unit = OUTPUT_HEIGHT / (2 * math::tan(lens.fov_y * 0.5f));
    float threshold = desc.lod_threshold;
    float merge_below = threshold / (1 + desc.lod_hysteresis);

    float[4] sizes = { threshold * 0.99f, threshold * 1.01f, (threshold + merge_below) * 0.5f, merge_below * 0.99f };
    uint[4] counts = { 1, 4, 4, 1 };
    uint[4] switches = { 0, 1, 0, 1 };
    foreach (index, size : sizes) {
        camera_at(&fixture, center + (Vec3){ 0, diameter * pixels_per_unit / size, 0 });
        update_terrain(&fixture);
        assert(batch.count == counts[index]);
        assert(runtime.lod_switches == switches[index]);
    }
}

fn void test_finest_selection_fills_the_instance_capacity() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, FOUR_LEVEL_TEXELS, SEED));
    desc.lod_threshold = 0;
    Node* node = add_terrain_node(&fixture, desc);
    camera_at(&fixture, { 0, 5000, 0 });
    update_terrain(&fixture);

    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    uint side = (FOUR_LEVEL_TEXELS - 1) / terrain::CHUNK_CELLS;
    assert(batch.count == side * side && batch.transforms.len == (usz)side * side);
    assert_covers_once(batch, FOUR_LEVEL_TEXELS);
}

fn void test_removed_terrain_releases_its_batch_and_material() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    Node* kept = add_terrain_node(&fixture, desc);
    Node* destroyed = add_terrain_node(&fixture, desc);
    update_terrain(&fixture);
    MaterialId kept_material = fixture.scene.get(kept, TerrainRuntime).material;
    MaterialId destroyed_material = fixture.scene.get(destroyed, TerrainRuntime).material;
    GeometryId grid = fixture.scene.get(kept, InstancedMesh).geometry;

    fixture.scene.remove_component(kept, Terrain);
    update_terrain(&fixture);
    assert(!fixture.scene.has(kept, InstancedMesh) && !fixture.scene.has(kept, TerrainRuntime));
    assert(!fixture.assets.materials.is_live(kept_material));

    fixture.scene.remove(destroyed);
    assert(!fixture.assets.materials.is_live(destroyed_material));
    assert(fixture.assets.geometries.is_live(grid));
}
