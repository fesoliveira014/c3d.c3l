module c3d_landscape_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::geometry;
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
const uint EDIT_SIDE @local = 9;
const float RECORD_TOLERANCE @local = 1e-4f; // float rounding of node boxes built from the same texels
const float TEXEL_MAX @local = 65535; // height = height_scale * texel / 65535, the physics height-field rule
const ushort MAP_LOW @local = 1000; // generated maps stay inside [MAP_LOW, MAP_HIGH]; edits write 0 and 65535
const ushort MAP_HIGH @local = 64000;
const uint RING_NORTH @local = 0; // the border ring's rows and the bits of the tile's edge mask, in this order
const uint RING_SOUTH @local = 1;
const uint RING_WEST @local = 2;
const uint RING_EAST @local = 3;
const usz BORDER_EDGES_OFFSET @local = 16; // in the material block, after texels, cell_size, height_scale and layer_count
const uint BORDER_SLOT @local = 2; // the material slot of the border ring
const uint BAND_ROW @local = 1; // the row inside a tile's edge that its neighbour's ring holds
const uint INTERIOR_ROW @local = 60; // clear of both outer bands of a 129-texel tile
const float SEAM_AGREEMENT @local = 1e-6f; // both sides difference the same four heights
const float ONE_SIDED_DISAGREEMENT @local = 0.01f; // random texels: far above the agreement, so a missing ring fails
const uint MID_EDGE_ROW @local = 40; // an edit from here stays clear of both corners of a 129-texel tile

struct Fixture @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    MaterialId   layer;
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

fn void? try_update(Fixture* fixture) @local {
    return terrain::update(&fixture.scene, &fixture.assets);
}

fn void update_terrain(Fixture* fixture) @local {
    try_update(fixture)!!;
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
    InstancedMesh* restored = fixture.scene.get(node, InstancedMesh);
    assert(restored.count > 0 && restored.quadtree.parents.len == restored.count);
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

fn bool near(float first, float second) @local => math::abs(first - second) <= RECORD_TOLERANCE;

fn void test_node_records_and_parents_match_the_bounds_tree() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_terrain_node(&fixture, terrain_desc(&fixture, add_height_map(&fixture, FOUR_LEVEL_TEXELS, SEED)));
    TerrainRuntime* runtime = fixture.scene.get(node, TerrainRuntime);
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    uint finest_side = (FOUR_LEVEL_TEXELS - 1) / terrain::CHUNK_CELLS;
    uint nodes;
    for (uint level = 0; level < runtime.level_count; level++) nodes += (finest_side >> level) * (finest_side >> level);

    assert(batch.count == nodes && batch.transforms.len == nodes && batch.quadtree.parents.len == nodes);
    assert(batch.quadtree.leaf_count == finest_side * finest_side && !batch.trace);

    float height_unit = HEIGHT_SCALE / TEXEL_MAX;
    for (uint level = 0; level < runtime.level_count; level++) {
        uint side = finest_side >> level;
        uint span = terrain::CHUNK_CELLS << level;
        float edge = (float)span * CELL_SIZE;
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                uint index = runtime.level_offset[level] + z * side + x;
                uint parent = scene::QUADTREE_ROOT;
                if (level + 1 < runtime.level_count) {
                    parent = runtime.level_offset[level + 1] + (z >> 1) * (side >> 1) + (x >> 1);
                }
                assert(batch.quadtree.parents[index] == parent);
                assert(batch.is_leaf(index) == (level == 0));

                float lowest = (float)runtime.minimum[index] * height_unit;
                float highest = (float)runtime.maximum[index] * height_unit;
                Transform record = batch.transforms[index];
                assert(near(record.position.x, (float)x * edge) && near(record.position.z, (float)z * edge));
                assert(near(record.position.y, lowest) && near(record.scale.y, highest - lowest));
                assert(near(record.scale.x, edge) && near(record.scale.z, edge));
                Vec4 chunk = batch.colors[index];
                assert(near(chunk.x, (float)(x * span)) && near(chunk.y, (float)(z * span)));
                assert(near(chunk.z, (float)span) && near(chunk.w, lowest));
            }
        }
    }
}

fn void test_height_edit_republishes_records_and_keeps_the_topology() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, TWO_LEVEL_TEXELS, SEED));
    Node* edited = add_terrain_node(&fixture, desc);
    InstancedMesh* batch = fixture.scene.get(edited, InstancedMesh);
    uint records = batch.revision;
    uint topology = batch.quadtree.revision;

    update_terrain(&fixture);
    assert(batch.revision == records && batch.quadtree.revision == topology);

    TexelRect edit = { .x = 10, .z = 20, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
    write_extreme_texels(&fixture, desc.height_map, edit);
    terrain::mark_dirty(&fixture.scene, edited, edit);
    update_terrain(&fixture);
    assert(batch.revision != records && batch.quadtree.revision == topology);

    Node* fresh = add_terrain_node(&fixture, terrain_desc(&fixture, copy_height_map(&fixture, desc.height_map)));
    batch = fixture.scene.get(edited, InstancedMesh);
    InstancedMesh* expected = fixture.scene.get(fresh, InstancedMesh);
    assert(batch.count == expected.count);
    assert(mem::equals(batch.transforms[:batch.count], expected.transforms[:expected.count]));
    assert(mem::equals(batch.colors[:batch.count], expected.colors[:expected.count]));
}

fn void test_lod_group_on_the_node_faults_and_rolls_back() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    Node* node = fixture.scene.add_node()!!;

    GeometryId stand_in;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width:     1,
            height:    1,
            depth:     1,
        );
        stand_in = fixture.assets.add_geometry(&box)!!;
    };
    LodLevel[1] levels = {{ .first_part = 0, .part_count = 1, .min_screen_size = 0 }};
    LodPart[1] parts = {{ .geometry = stand_in, .material = fixture.layer, .local = matrix::IDENTITY4 }};
    LodGroup group = scene::create_lod_group(
        allocator: mem,
        assets:    &fixture.assets,
        desc:      { .levels = levels[..], .parts = parts[..] },
    )!!;
    fixture.scene.add(node, group);

    uint free_materials = fixture.assets.materials.free_count;
    uint free_geometry = fixture.assets.geometries.free_count;
    uint free_shaders = fixture.assets.shaders.free_count;

    assert(@catch(try_add_terrain(&fixture, node, desc)) == c3d::UNSUPPORTED);
    assert(!fixture.scene.has(node, Terrain) && !fixture.scene.has(node, TerrainRuntime));
    assert(!fixture.scene.has(node, InstancedMesh));
    assert(fixture.assets.materials.free_count == free_materials);
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.shaders.free_count == free_shaders);
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

fn void test_pending_terrains_retry_without_partial_assets_or_shared_owner_changes() @test {
    Fixture fixture;
    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_materials = 3;
    fixture.assets = asset::create_asset_store(mem, store_desc);
    defer asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&fixture.scene);
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    fixture.layer = fixture.assets.add_material(material::standard())!!;
    MaterialId first_blocker = fixture.assets.add_material(material::standard())!!;
    MaterialId second_blocker = fixture.assets.add_material(material::standard())!!;
    TextureId height_map = add_height_map(&fixture, SMALL_TEXELS, SEED, flat: true);
    TerrainDesc desc = terrain_desc(&fixture, height_map);
    Node* group = fixture.scene.add_node()!!;
    Node* first = fixture.scene.add_node(group)!!;
    Node* second = fixture.scene.add_node(group)!!;
    uint free_nodes = fixture.scene.world.entities.free_count;
    uint free_geometry = fixture.assets.geometries.free_count;
    uint free_shaders = fixture.assets.shaders.free_count;
    terrain::attach_terrain(
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: first,
        desc: desc,
    )!!;
    terrain::attach_terrain(
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: second,
        desc: desc,
    )!!;
    assert(!terrain::is_prepared(&fixture.scene, first) && !terrain::is_prepared(&fixture.scene, second));
    assert(fixture.scene.world.entities.free_count == free_nodes);
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.shaders.free_count == free_shaders);
    assert(fixture.scene.count(InstancedMesh) == 0);
    fixture.scene.update_world();
    terrain::update(&fixture.scene, &fixture.assets)!!;
    assert(fixture.scene.count(InstancedMesh) == 0);

    assert(@catch(terrain::prepare(&fixture.scene, &fixture.assets, first)) == c3d::CAPACITY_EXCEEDED);
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.shaders.free_count == free_shaders);
    assert(!terrain::is_prepared(&fixture.scene, first));
    assert(c3d::same_id(fixture.scene.get(first, Terrain).desc.height_map, height_map));
    fixture.assets.remove_material(first_blocker);
    assert(@catch(terrain::prepare_subtree(&fixture.scene, &fixture.assets, group)) == c3d::CAPACITY_EXCEEDED);
    assert(terrain::is_prepared(&fixture.scene, first) && !terrain::is_prepared(&fixture.scene, second));
    MaterialId material = fixture.scene.get(first, TerrainRuntime).material;
    terrain::update(&fixture.scene, &fixture.assets)!!;
    assert(fixture.scene.get(first, InstancedMesh).count == 1 && !fixture.scene.has(second, InstancedMesh));

    fixture.assets.remove_material(second_blocker);
    terrain::prepare(&fixture.scene, &fixture.assets, second)!!;
    assert(terrain::is_prepared(&fixture.scene, second));
    free_geometry = fixture.assets.geometries.free_count;
    uint free_materials = fixture.assets.materials.free_count;
    terrain::prepare_subtree(&fixture.scene, &fixture.assets)!!;
    assert(c3d::same_id(fixture.scene.get(first, TerrainRuntime).material, material));
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.materials.free_count == free_materials);
    terrain::update(&fixture.scene, &fixture.assets)!!;
    assert(fixture.scene.get(first, InstancedMesh).count == 1 && fixture.scene.get(second, InstancedMesh).count == 1);
}

fn void test_terrain_eager_failure_and_pending_removal_leave_no_owned_resources() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Fixture fixture;
    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_materials = 1;
    fixture.assets = asset::create_asset_store(&tracking, store_desc);
    fixture.scene = scene::create_scene(&tracking, { .max_nodes = 4 });
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    fixture.layer = fixture.assets.add_material(material::standard())!!;
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, SMALL_TEXELS, SEED));
    Node* node = fixture.scene.add_node()!!;
    uint free_geometry = fixture.assets.geometries.free_count;
    uint free_shaders = fixture.assets.shaders.free_count;
    uint free_nodes = fixture.scene.world.entities.free_count;
    assert(@catch(try_add_terrain(&fixture, node, desc)) == c3d::CAPACITY_EXCEEDED);
    assert(!fixture.scene.has(node, Terrain) && !fixture.scene.has(node, TerrainRuntime));
    assert(!fixture.scene.has(node, InstancedMesh) && fixture.scene.world.entities.free_count == free_nodes);
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.shaders.free_count == free_shaders);
    assert(fixture.assets.materials.free_count == 0);
    sz bytes = tracking.allocated();
    terrain::attach_terrain(
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: node,
        desc: desc,
    )!!;
    assert(!terrain::is_prepared(&fixture.scene, node) && tracking.allocated() == bytes);
    fixture.scene.remove_component(node, Terrain);
    assert(!fixture.scene.has(node, Terrain) && !fixture.scene.has(node, TerrainRuntime));
    assert(!fixture.scene.has(node, InstancedMesh) && tracking.allocated() == bytes);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
    assert(!tracking.has_leaks());
}

fn void test_replaced_height_map_refreshes_whole_map() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    TerrainDesc desc = terrain_desc(&fixture, add_height_map(&fixture, TWO_LEVEL_TEXELS, SEED));
    Node* node = add_terrain_node(&fixture, desc);
    update_terrain(&fixture);

    TexelRect edit = { .x = 10, .z = 20, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
    terrain::mark_dirty(&fixture.scene, node, edit);
    TextureAsset* record = fixture.assets.texture(desc.height_map);
    @pool() {
        char[] next = alloc::new_array(tmem, char, record.pixels.len);
        next[..] = record.pixels[..];
        fixture.assets.replace_texture(desc.height_map, record.desc, next)!!;
    };
    // A replacement may reuse the address of the pixels the runtime last read.
    fixture.scene.get(node, TerrainRuntime).pixels = record.pixels.ptr;
    update_terrain(&fixture);

    TexelRect refreshed = fixture.scene.get(node, TerrainRuntime).last_refresh.rect;
    assert(refreshed.x == 0 && refreshed.z == 0);
    assert(refreshed.columns == TWO_LEVEL_TEXELS && refreshed.rows == TWO_LEVEL_TEXELS);
}

struct SetFixture @local {
    Fixture     base;
    Node*       node;
    TerrainSet* set;
    TerrainDesc desc;
}

fn void setup_set(SetFixture* sets, Allocator allocator) @local {
    Fixture* fixture = &sets.base;
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(allocator, scene::default_scene_desc());
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    fixture.layer = fixture.assets.add_material(material::standard({ .base_color = { 1, 1, 1, 1 }, .roughness = 1 }))!!;

    sets.node = fixture.scene.add_node(name: "set")!!;
    fixture.scene.add(sets.node, (TerrainSet){
        .texels       = SMALL_TEXELS,
        .cell_size    = CELL_SIZE,
        .height_scale = HEIGHT_SCALE,
    });
    sets.set = fixture.scene.get(sets.node, TerrainSet);
    sets.desc = terrain_desc(fixture, add_height_map(fixture, SMALL_TEXELS, SEED));
}

fn void teardown_set(SetFixture* sets) @local {
    scene::destroy_scene(&sets.base.scene);
    asset::destroy_asset_store(&sets.base.assets);
}

fn Node* add_tile_node(SetFixture* sets, int x, int z) @local {
    float extent = sets.set.tile_extent();
    Node* node = sets.base.scene.add_node(sets.node)!!;
    node.local.position = { (float)x * extent, 0, (float)z * extent };
    sets.base.scene.add(node, (TerrainTile){ .x = x, .z = z });
    return node;
}

fn Node* add_prepared_tile(SetFixture* sets, int x, int z) @local {
    Node* node = add_tile_node(sets, x, z);
    try_add_terrain(&sets.base, node, sets.desc)!!;
    return node;
}

fn void assert_tile_rejected(SetFixture* sets, Node* tile, TerrainDesc desc) @local {
    assert(@catch(try_add_terrain(&sets.base, tile, desc)) == c3d::INVALID_ARGUMENT);
    assert(!sets.set.is_linked(tile.id) && !sets.base.scene.has(tile, TerrainRuntime));
}

fn void test_terrain_set_rejects_incompatible_tiles() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* first = add_prepared_tile(&sets, 0, 0);

    TerrainDesc finer_map = terrain_desc(&sets.base, add_height_map(&sets.base, TWO_LEVEL_TEXELS, SEED));
    assert_tile_rejected(&sets, add_tile_node(&sets, 1, 0), finer_map);

    TerrainDesc wide_cells = sets.desc;
    wide_cells.cell_size = CELL_SIZE * 2;
    assert_tile_rejected(&sets, add_tile_node(&sets, 1, 0), wide_cells);

    TerrainDesc tall = sets.desc;
    tall.height_scale = HEIGHT_SCALE * 2;
    assert_tile_rejected(&sets, add_tile_node(&sets, 1, 0), tall);

    TerrainDesc eager_lod = sets.desc;
    eager_lod.lod_threshold = sets.desc.lod_threshold + 1;
    assert_tile_rejected(&sets, add_tile_node(&sets, 1, 0), eager_lod);

    TerrainDesc extra_layer = sets.desc;
    extra_layer.layers[1] = sets.base.assets.add_material(material::standard())!!;
    assert_tile_rejected(&sets, add_tile_node(&sets, 1, 0), extra_layer);

    Node* shifted = add_tile_node(&sets, 1, 0);
    shifted.local.position.x += CELL_SIZE;
    assert_tile_rejected(&sets, shifted, sets.desc);

    Node* turned = add_tile_node(&sets, 1, 0);
    turned.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(TERRAIN_YAW_DEGREES));
    assert_tile_rejected(&sets, turned, sets.desc);

    assert_tile_rejected(&sets, add_tile_node(&sets, 0, 0), sets.desc);

    Node* second = add_prepared_tile(&sets, 1, 0);
    assert(c3d::same_id(sets.set.neighbour(first.id, EAST)!!, second.id));
}

fn void test_terrain_set_links_neighbours_and_unlinks_on_removal() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    SetFixture sets;
    setup_set(&sets, &tracking);
    TerrainSet* set = sets.set;
    Node* north_west = add_prepared_tile(&sets, 0, 0);
    Node* north_east = add_prepared_tile(&sets, 1, 0);
    Node* south_west = add_prepared_tile(&sets, 0, 1);
    Node* south_east = add_prepared_tile(&sets, 1, 1);

    assert(c3d::same_id(set.neighbour(north_west.id, EAST)!!, north_east.id));
    assert(c3d::same_id(set.neighbour(north_west.id, SOUTH)!!, south_west.id));
    assert(c3d::same_id(set.neighbour(north_west.id, SOUTH_EAST)!!, south_east.id));
    assert(@catch(set.neighbour(north_west.id, WEST)) == NOT_FOUND);
    assert(c3d::same_id(set.neighbour(north_east.id, SOUTH_WEST)!!, south_west.id));
    assert(c3d::same_id(set.neighbour(south_east.id, WEST)!!, south_west.id));
    assert(c3d::same_id(set.neighbour(south_east.id, NORTH)!!, north_east.id));
    assert(c3d::same_id(set.neighbour(south_east.id, NORTH_WEST)!!, north_west.id));
    assert(@catch(set.neighbour(south_east.id, SOUTH_EAST)) == NOT_FOUND);

    Entity removed = north_east.id;
    sets.base.scene.remove(north_east);
    assert(!set.is_linked(removed));
    assert(@catch(set.neighbour(north_west.id, EAST)) == NOT_FOUND);
    assert(@catch(set.neighbour(south_west.id, NORTH_EAST)) == NOT_FOUND);
    assert(@catch(set.neighbour(south_east.id, NORTH)) == NOT_FOUND);
    assert(c3d::same_id(set.neighbour(north_west.id, SOUTH)!!, south_west.id));

    sets.base.scene.remove_component(south_west, TerrainTile);
    assert(!set.is_linked(south_west.id) && sets.base.scene.has(south_west, TerrainRuntime));
    assert(@catch(set.neighbour(north_west.id, SOUTH)) == NOT_FOUND);

    sets.base.scene.remove_component(south_east, Terrain);
    assert(!set.is_linked(south_east.id));
    assert(@catch(set.neighbour(north_west.id, SOUTH_EAST)) == NOT_FOUND);

    teardown_set(&sets);
    assert(!tracking.has_leaks());
}

fn void test_prepare_revalidates_a_moved_tile() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* west = add_prepared_tile(&sets, 0, 0);
    Node* east = add_prepared_tile(&sets, 1, 0);

    east.local.position.x += CELL_SIZE;
    assert(@catch(terrain::prepare(&sets.base.scene, &sets.base.assets, east)) == c3d::INVALID_ARGUMENT);
    assert(!sets.set.is_linked(east.id) && terrain::is_prepared(&sets.base.scene, east));
    assert(@catch(sets.set.neighbour(west.id, EAST)) == NOT_FOUND);

    east.local.position.x -= CELL_SIZE;
    terrain::prepare(&sets.base.scene, &sets.base.assets, east)!!;
    assert(c3d::same_id(sets.set.neighbour(west.id, EAST)!!, east.id));
}

fn Node* add_tile_with_own_map(SetFixture* sets, int x, int z) @local {
    Node* node = add_tile_node(sets, x, z);
    TerrainDesc desc = terrain_desc(&sets.base, add_height_map(&sets.base, SMALL_TEXELS, SEED + (ulong)(x + 2 * z)));
    try_add_terrain(&sets.base, node, desc)!!;
    return node;
}

fn ushort[] texels_of(SetFixture* sets, TextureId texture) @local {
    TextureAsset* record = sets.base.assets.texture(texture);
    return ((ushort*)record.pixels.ptr)[:record.pixels.len / ushort::size];
}

fn TerrainRuntime* runtime_of(SetFixture* sets, Node* tile) @local => sets.base.scene.get(tile, TerrainRuntime);

fn ushort[] ring_row(SetFixture* sets, Node* tile, uint edge) @local {
    ushort[] ring = texels_of(sets, runtime_of(sets, tile).border_ring);
    return ring[edge * SMALL_TEXELS : SMALL_TEXELS];
}

fn uint ring_revision(SetFixture* sets, Node* tile) @local {
    return sets.base.assets.texture(runtime_of(sets, tile).border_ring).header.revision;
}

fn uint material_revision(SetFixture* sets, Node* tile) @local {
    return sets.base.assets.material(runtime_of(sets, tile).material).header.revision;
}

fn uint border_edges(SetFixture* sets, Node* tile) @local {
    char[] block = sets.base.assets.material(runtime_of(sets, tile).material).data.custom.param_block;
    return *(uint*)(block.ptr + BORDER_EDGES_OFFSET);
}

// The neighbour's texel one step inside its own border, at a position along the shared edge.
fn ushort SetFixture.inner_texel(
    &self,
    Node* neighbour,
    uint edge,
    uint along,
) {
    ushort[] heights = texels_of(self, self.base.scene.get(neighbour, Terrain).desc.height_map);
    uint inside = SMALL_TEXELS - 2;
    switch (edge) {
        case RING_NORTH: return heights[inside * SMALL_TEXELS + along];
        case RING_SOUTH: return heights[SMALL_TEXELS + along];
        case RING_WEST: return heights[along * SMALL_TEXELS + inside];
        default: return heights[along * SMALL_TEXELS + 1];
    }
}

fn void SetFixture.assert_ring_holds(
    &self,
    Node* tile,
    uint edge,
    Node* neighbour,
) {
    assert((border_edges(self, tile) & (1u << edge)) != 0);
    foreach (along, value : ring_row(self, tile, edge)) {
        assert(value == self.inner_texel(neighbour, edge, (uint)along));
    }
}

fn void assert_ring_empty(SetFixture* sets, Node* tile, uint edge) @local {
    assert((border_edges(sets, tile) & (1u << edge)) == 0);
    foreach (value : ring_row(sets, tile, edge)) assert(value == 0);
}

fn void test_border_ring_holds_neighbour_texels() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* north_west = add_tile_with_own_map(&sets, 0, 0);
    Node* north_east = add_tile_with_own_map(&sets, 1, 0);
    Node* south_west = add_tile_with_own_map(&sets, 0, 1);
    Node* south_east = add_tile_with_own_map(&sets, 1, 1);

    TerrainRuntime* runtime = runtime_of(&sets, north_west);
    TextureSlot bound = sets.base.assets.material(runtime.material).data.custom.slots[BORDER_SLOT];
    assert(c3d::same_id(bound.texture.asset, runtime.border_ring));
    assert_ring_empty(&sets, north_west, RING_NORTH);
    assert_ring_empty(&sets, north_west, RING_WEST);
    sets.assert_ring_holds(north_west, RING_EAST, north_east);
    sets.assert_ring_holds(north_west, RING_SOUTH, south_west);

    assert_ring_empty(&sets, north_east, RING_NORTH);
    assert_ring_empty(&sets, north_east, RING_EAST);
    sets.assert_ring_holds(north_east, RING_WEST, north_west);
    sets.assert_ring_holds(north_east, RING_SOUTH, south_east);

    assert_ring_empty(&sets, south_west, RING_SOUTH);
    assert_ring_empty(&sets, south_west, RING_WEST);
    sets.assert_ring_holds(south_west, RING_NORTH, north_west);
    sets.assert_ring_holds(south_west, RING_EAST, south_east);

    assert_ring_empty(&sets, south_east, RING_SOUTH);
    assert_ring_empty(&sets, south_east, RING_EAST);
    sets.assert_ring_holds(south_east, RING_NORTH, north_east);
    sets.assert_ring_holds(south_east, RING_WEST, south_west);

    Node*[4] tiles = { north_west, north_east, south_west, south_east };
    uint[4] ring_revisions;
    uint[4] block_revisions;
    foreach (index, tile : tiles) {
        ring_revisions[index] = ring_revision(&sets, tile);
        block_revisions[index] = material_revision(&sets, tile);
    }
    terrain::prepare_subtree(&sets.base.scene, &sets.base.assets, sets.node)!!;
    foreach (index, tile : tiles) {
        assert(ring_revision(&sets, tile) == ring_revisions[index]);
        assert(material_revision(&sets, tile) == block_revisions[index]);
    }
}

fn void test_ring_refreshes_on_edge_link_and_band_edits() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* north_west = add_tile_with_own_map(&sets, 0, 0);
    Node* north_east = add_tile_with_own_map(&sets, 1, 0);
    Node* south_west = add_tile_with_own_map(&sets, 0, 1);
    Node* south_east = add_tile_with_own_map(&sets, 1, 1);

    uint settled_revision = ring_revision(&sets, north_west);
    sets.base.scene.remove_component(south_east, TerrainTile);
    assert(ring_revision(&sets, north_west) == settled_revision);
    sets.assert_ring_holds(north_west, RING_EAST, north_east);
    sets.assert_ring_holds(north_west, RING_SOUTH, south_west);

    TextureId departed_ring = runtime_of(&sets, north_east).border_ring;
    sets.base.scene.remove(north_east);
    assert(!sets.base.assets.textures.is_live(departed_ring));
    assert_ring_empty(&sets, north_west, RING_EAST);
    sets.assert_ring_holds(north_west, RING_SOUTH, south_west);

    assert_ring_empty(&sets, south_east, RING_NORTH);
    assert_ring_empty(&sets, south_east, RING_WEST);
    assert_ring_empty(&sets, south_west, RING_EAST);

    TextureId south_map = sets.base.scene.get(south_west, Terrain).desc.height_map;
    ushort[] south_texels = texels_of(&sets, south_map);
    ushort edited = south_texels[BAND_ROW * SMALL_TEXELS + INTERIOR_ROW] ^ 0x5a5a;
    south_texels[BAND_ROW * SMALL_TEXELS + INTERIOR_ROW] = edited;
    uint stale_revision = ring_revision(&sets, north_west);
    terrain::refresh_neighbour_rings(
        scene:  &sets.base.scene,
        assets: &sets.base.assets,
        tile:   south_west,
        rect:   { .x = INTERIOR_ROW, .z = INTERIOR_ROW, .columns = 1, .rows = 1 },
    );
    assert(ring_revision(&sets, north_west) == stale_revision);
    assert(ring_row(&sets, north_west, RING_SOUTH)[INTERIOR_ROW] != edited);

    terrain::refresh_neighbour_rings(
        scene:  &sets.base.scene,
        assets: &sets.base.assets,
        tile:   south_west,
        rect:   { .x = INTERIOR_ROW, .z = BAND_ROW, .columns = 1, .rows = 1 },
    );
    assert(ring_revision(&sets, north_west) != stale_revision);
    assert(ring_row(&sets, north_west, RING_SOUTH)[INTERIOR_ROW] == edited);

    sets.base.scene.remove_component(sets.node, TerrainSet);
    assert_ring_empty(&sets, north_west, RING_SOUTH);
    assert_ring_empty(&sets, south_west, RING_NORTH);
}

fn void test_tile_added_to_a_prepared_terrain_binds_a_ring() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* west = add_tile_with_own_map(&sets, 0, 0);

    float extent = sets.set.tile_extent();
    Node* plain = sets.base.scene.add_node(sets.node)!!;
    plain.local.position = { extent, 0, 0 };
    TerrainDesc desc = terrain_desc(&sets.base, add_height_map(&sets.base, SMALL_TEXELS, SEED + 1));
    try_add_terrain(&sets.base, plain, desc)!!;
    assert(!runtime_of(&sets, plain).border_ring.generation);
    assert(border_edges(&sets, plain) == 0);

    sets.base.scene.add(plain, (TerrainTile){ .x = 1, .z = 0 });
    terrain::prepare(&sets.base.scene, &sets.base.assets, plain)!!;
    assert(runtime_of(&sets, plain).border_ring.generation != 0);
    sets.assert_ring_holds(plain, RING_WEST, west);
    sets.assert_ring_holds(west, RING_EAST, plain);
}

fn void test_retiled_terrain_empties_the_rows_of_the_cell_it_left() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* west = add_tile_with_own_map(&sets, 0, 0);
    Node* east = add_tile_with_own_map(&sets, 1, 0);
    sets.assert_ring_holds(west, RING_EAST, east);

    sets.base.scene.get(east, TerrainTile).x = 2;
    east.local.position.x = 2 * sets.set.tile_extent();
    terrain::prepare(&sets.base.scene, &sets.base.assets, east)!!;
    assert(sets.set.is_linked(east.id));
    assert_ring_empty(&sets, west, RING_EAST);
    assert_ring_empty(&sets, east, RING_WEST);
}

fn void test_smooth_normal_agrees_across_a_linked_seam() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* west = add_tile_with_own_map(&sets, 0, 0);
    Node* east = add_tile_with_own_map(&sets, 1, 0);
    ushort[] west_texels = texels_of(&sets, sets.base.scene.get(west, Terrain).desc.height_map);
    ushort[] east_texels = texels_of(&sets, sets.base.scene.get(east, Terrain).desc.height_map);
    for (uint row = 0; row < SMALL_TEXELS; row++) {
        east_texels[row * SMALL_TEXELS] = west_texels[row * SMALL_TEXELS + SMALL_TEXELS - 1];
    }
    terrain::refresh_neighbour_rings(
        scene:  &sets.base.scene,
        assets: &sets.base.assets,
        tile:   east,
        rect:   { .x = 0, .z = 0, .columns = 1, .rows = SMALL_TEXELS },
    );
    sets.base.scene.update_world();

    HeightView west_view = terrain::height_view(&sets.base.scene, &sets.base.assets, west.id)!!;
    HeightView east_view = terrain::height_view(&sets.base.scene, &sets.base.assets, east.id)!!;
    float seam_x = sets.set.tile_extent();
    float along_z = ((float)INTERIOR_ROW + 0.25f) * CELL_SIZE;
    Vec3 west_normal = terrain::sample_smooth_normal(&west_view, seam_x, along_z)!!;
    Vec3 east_normal = terrain::sample_smooth_normal(&east_view, seam_x, along_z)!!;
    assert((west_normal - east_normal).length() <= SEAM_AGREEMENT);

    west_view.border_edges = 0;
    east_view.border_edges = 0;
    Vec3 west_one_sided = terrain::sample_smooth_normal(&west_view, seam_x, along_z)!!;
    Vec3 east_one_sided = terrain::sample_smooth_normal(&east_view, seam_x, along_z)!!;
    assert((west_one_sided - east_one_sided).length() >= ONE_SIDED_DISAGREEMENT);
}

fn uint height_revision(SetFixture* sets, Node* tile) @local {
    return sets.base.assets.texture(sets.base.scene.get(tile, Terrain).desc.height_map).header.revision;
}

fn ushort[] tile_texels(SetFixture* sets, Node* tile) @local {
    return texels_of(sets, sets.base.scene.get(tile, Terrain).desc.height_map);
}

fn bool is_inside(TexelRect rect, uint column, uint row) @local {
    return column >= rect.x && column < rect.x + rect.columns && row >= rect.z && row < rect.z + rect.rows;
}

fn bool same_rect(TexelRect first, TexelRect second) @local {
    return first.x == second.x && first.z == second.z && first.columns == second.columns && first.rows == second.rows;
}

fn void assert_changed_only_inside(ushort[] before, ushort[] after, TexelRect rect) @local {
    foreach (index, texel : after) {
        uint column = (uint)(index % SMALL_TEXELS);
        uint row = (uint)(index / SMALL_TEXELS);
        if (!is_inside(rect, column, row)) assert(texel == before[index]);
    }
}

fn uint SetFixture.propagate(&self, Node* tile, TexelRect rect) {
    return self.set.propagate_edit(
        scene:  &self.base.scene,
        assets: &self.base.assets,
        tile:   tile.id,
        rect:   rect,
    )!!;
}

fn uint SetFixture.edit_and_propagate(
    &self,
    Node* tile,
    TexelRect rect,
    ulong seed,
) {
    write_random_texels(&self.base, self.base.scene.get(tile, Terrain).desc.height_map, rect, seed);
    terrain::mark_dirty(&self.base.scene, tile, rect);
    return self.propagate(tile, rect);
}

fn uint neighbour_bit(TerrainNeighbour direction) @local => (uint)1 << direction.ordinal;

// Tiles in grid order, x fastest.
fn void SetFixture.assert_rings_hold_neighbours(&self, Node*[4] tiles) {
    self.assert_ring_holds(tiles[0], RING_EAST, tiles[1]);
    self.assert_ring_holds(tiles[0], RING_SOUTH, tiles[2]);
    self.assert_ring_holds(tiles[1], RING_WEST, tiles[0]);
    self.assert_ring_holds(tiles[1], RING_SOUTH, tiles[3]);
    self.assert_ring_holds(tiles[2], RING_NORTH, tiles[0]);
    self.assert_ring_holds(tiles[2], RING_EAST, tiles[3]);
    self.assert_ring_holds(tiles[3], RING_NORTH, tiles[1]);
    self.assert_ring_holds(tiles[3], RING_WEST, tiles[2]);
}

fn void test_propagated_edge_edit_leaves_other_neighbours_alone() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* north_west = add_tile_with_own_map(&sets, 0, 0);
    Node* north_east = add_tile_with_own_map(&sets, 1, 0);
    Node* south_west = add_tile_with_own_map(&sets, 0, 1);
    Node* south_east = add_tile_with_own_map(&sets, 1, 1);
    Node*[4] tiles = { north_west, north_east, south_west, south_east };

    uint last = SMALL_TEXELS - 1;
    uint first_column = SMALL_TEXELS - EDIT_SIDE;
    TexelRect mid_edge = { .x = first_column, .z = MID_EDGE_ROW, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
    TexelRect east_of_mid = { .x = 0, .z = MID_EDGE_ROW, .columns = 1, .rows = EDIT_SIDE };

    @pool() {
        uint[3] revisions = {
            height_revision(&sets, north_east),
            height_revision(&sets, south_west),
            height_revision(&sets, south_east),
        };
        ushort[] untouched = alloc::new_array(tmem, ushort, (usz)SMALL_TEXELS * SMALL_TEXELS);
        untouched[..] = tile_texels(&sets, north_east)[..];

        uint changed = sets.edit_and_propagate(north_west, mid_edge, SEED);
        assert(changed == neighbour_bit(TerrainNeighbour.EAST));

        ushort[] edited = tile_texels(&sets, north_west);
        ushort[] east = tile_texels(&sets, north_east);
        for (uint row = MID_EDGE_ROW; row < MID_EDGE_ROW + EDIT_SIDE; row++) {
            assert(edited[row * SMALL_TEXELS + last] == east[row * SMALL_TEXELS]);
        }
        assert_changed_only_inside(untouched, east, east_of_mid);
        assert(height_revision(&sets, north_east) != revisions[0]);
        assert(same_rect(runtime_of(&sets, north_east).pending, east_of_mid));
        assert(height_revision(&sets, south_west) == revisions[1]);
        assert(height_revision(&sets, south_east) == revisions[2]);
        assert(!runtime_of(&sets, south_west).has_pending && !runtime_of(&sets, south_east).has_pending);
        sets.assert_rings_hold_neighbours(tiles);

        uint settled_revision = height_revision(&sets, north_east);
        assert(sets.propagate(north_west, mid_edge) == 0);
        assert(height_revision(&sets, north_east) == settled_revision);
    };
}

fn void test_propagated_edit_keeps_edges_and_corners_equal() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* north_west = add_tile_with_own_map(&sets, 0, 0);
    Node* north_east = add_tile_with_own_map(&sets, 1, 0);
    Node* south_west = add_tile_with_own_map(&sets, 0, 1);
    Node* south_east = add_tile_with_own_map(&sets, 1, 1);
    Node*[4] tiles = { north_west, north_east, south_west, south_east };

    uint last = SMALL_TEXELS - 1;
    uint first_edit = SMALL_TEXELS - EDIT_SIDE;
    TexelRect edit = { .x = first_edit, .z = first_edit, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
    Node*[3] neighbours = { north_east, south_west, south_east };
    TexelRect[3] strips = {
        { .x = 0, .z = first_edit, .columns = 1, .rows = EDIT_SIDE },
        { .x = first_edit, .z = 0, .columns = EDIT_SIDE, .rows = 1 },
        { .x = 0, .z = 0, .columns = 1, .rows = 1 },
    };

    @pool() {
        ushort[][3] before;
        uint[3] revisions;
        foreach (index, neighbour : neighbours) {
            ushort[] texels = tile_texels(&sets, neighbour);
            before[index] = alloc::new_array(tmem, ushort, texels.len);
            before[index][..] = texels[..];
            revisions[index] = height_revision(&sets, neighbour);
        }
        ushort stale_ring_texel = ring_row(&sets, south_east, RING_NORTH)[0];

        uint changed = sets.edit_and_propagate(north_west, edit, SEED + 1);
        uint expected = neighbour_bit(TerrainNeighbour.EAST)
          | neighbour_bit(TerrainNeighbour.SOUTH)
          | neighbour_bit(TerrainNeighbour.SOUTH_EAST);
        assert(changed == expected);

        ushort[] edited = tile_texels(&sets, north_west);
        ushort[] east = tile_texels(&sets, north_east);
        ushort[] south = tile_texels(&sets, south_west);
        ushort[] diagonal = tile_texels(&sets, south_east);
        for (uint row = first_edit; row <= last; row++) {
            assert(edited[row * SMALL_TEXELS + last] == east[row * SMALL_TEXELS]);
        }
        for (uint column = first_edit; column <= last; column++) {
            assert(edited[last * SMALL_TEXELS + column] == south[column]);
        }
        ushort shared = edited[last * SMALL_TEXELS + last];
        assert(east[last * SMALL_TEXELS] == shared && south[last] == shared && diagonal[0] == shared);

        foreach (index, neighbour : neighbours) {
            assert(height_revision(&sets, neighbour) != revisions[index]);
            TerrainRuntime* runtime = runtime_of(&sets, neighbour);
            assert(runtime.has_pending && same_rect(runtime.pending, strips[index]));
            assert_changed_only_inside(before[index], tile_texels(&sets, neighbour), strips[index]);
        }
        sets.assert_rings_hold_neighbours(tiles);
        assert(ring_row(&sets, south_east, RING_NORTH)[0] != stale_ring_texel);
    };
}

fn void test_propagate_edit_rejects_an_entity_that_is_not_a_linked_tile() @test {
    SetFixture sets;
    setup_set(&sets, mem);
    defer teardown_set(&sets);
    Node* tile = add_tile_with_own_map(&sets, 0, 0);
    Node* plain = sets.base.scene.add_node(sets.node)!!;
    Node* departed = add_tile_with_own_map(&sets, 1, 0);
    Entity removed = departed.id;
    sets.base.scene.remove(departed);

    TexelRect edit = { .columns = 1, .rows = 1 };
    foreach (entity : (Entity[]){ plain.id, removed }) {
        assert(@catch(sets.set.propagate_edit(
            scene:  &sets.base.scene,
            assets: &sets.base.assets,
            tile:   entity,
            rect:   edit,
        )) == c3d::INVALID_ARGUMENT);
    }
    assert(sets.set.is_linked(tile.id));
}
