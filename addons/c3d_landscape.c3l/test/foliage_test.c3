module c3d_foliage_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::geometry;
import c3d::landscape::foliage;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::material;
import c3d::scene;

const uint TEXELS @local = 129; // 64 m of ground at TERRAIN_CELL
const float TERRAIN_CELL @local = 0.5f;
const float EXTENT @local = (TEXELS - 1) * TERRAIN_CELL;
const float LAYER_CELL @local = 8; // 8 x 8 cells over the ground
const float SPACING @local = 1; // 64 candidates per cell
const float RANDOM_HEIGHT_SCALE @local = 4; // random texels: faces up to about 83 degrees from up
const float RAMP_HEIGHT_SCALE @local = 80;
const float RAMP_CURVE @local = 1.0f / 64; // metres of height per square metre along x: 45 degrees mid extent
const float STEP_HEIGHT_SCALE @local = 8;
const float STEP_METRES @local = 2; // terraces at 0, 2 and 4 m above the node
const uint STEP_TEXELS @local = 43; // three terraces across 129 texels
const Vec3 STEP_GROUND_POSITION @local = { 0, -2, 0 }; // terraces at -2, 0 and 2 m in world
const float BAND_LOW @local = -1;
const float BAND_HIGH @local = 1;
const float SLOPE_LIMIT @local = (float)math::PI * 0.25f;
const float ORDER_SLOPE_LIMIT @local = (float)math::PI / 3; // keeps about half of a random ground's candidates
const Vec3 ROTATED_GROUND_POSITION @local = { 3, -2, 5 };
const float ROTATED_GROUND_YAW_DEGREES @local = 30;
const Vec3 MOVED_GROUND_POSITION @local = { 3.3f, 1, -2.1f };
const float MOVED_GROUND_YAW_DEGREES @local = 10;
const uint SEED @local = 0x51ed;
const ulong TEXEL_SEED @local = 0x7e11a1;
const float HEIGHT_TOLERANCE @local = 0.0001f; // metres; the layer's height is subtracted, then added back
const float TINT_LOW @local = 0.8f;
const float SCALE_LOW @local = 0.8f;
const float SCALE_HIGH @local = 1.2f;
const uint EDIT_SIDE @local = 9;
const uint CELL_EDGE_TEXEL @local = 64; // 32 m, a cell edge: the edit reaches into the cell before it
const uint QUADRANT_TEXELS @local = 65; // the first quadrant's side; the second takes the other 64
const uint SMALL_SCENE_NODES @local = 48; // a camera, a ground, a layer and up to 36 cells; not 64
const uint BUDGET_SCENE_NODES @local = 80; // a camera, a ground, a layer, up to 36 cells and the fillers; not 64 cells
const uint FILLER_NODES @local = 20; // removing them makes room for all 64 cells
const uint INVALID_DESCS @local = 10;
const uint RGBA8_BYTES @local = 4;
const float OUTPUT_HEIGHT @local = 1080;
const float CAMERA_FOV_DEGREES @local = 60;
const float CAMERA_NEAR @local = 0.1f;
const float FULL_DENSITY_BELOW @local = 0.37f; // of the extent: two red texels of four, then the blend
const float NO_DENSITY_ABOVE @local = 0.63f;
const Vec3 HALF_BEND_WIND @local = { 3, 0, 4 }; // 5 m/s against a full bend at 10
const Vec3 GALE_WIND @local = { 30, 0, 40 };
const float EDITED_SPACING @local = SPACING * 0.5f; // four times the candidates a cell has room for
const uint EDITED_SEED @local = SEED + 1;
const float EDITED_LEAN @local = 1.5f; // outside [0, 1]: validate_effects rejects it

const SwayTemplate TEST_SWAY @local = {
    .amplitude       = 0.2f,
    .full_bend_speed = 10,
    .frequency       = 0.5f,
    .lean            = 0.25f,
    .wavelength      = 5,
    .variation       = 0.3f,
    .weight          = SwayWeight.VERTEX_ALPHA,
};

enum Ground @local {
    RANDOM,
    FLAT,
    RAMP,
    STEPS,
}

enum Filter @local {
    SLOPE,
    ALTITUDE,
}

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId geometry;
    MaterialId material;
    TextureId  full_density; // 255 in every channel
    Node*      camera;
}

struct InstanceBits @local {
    uint[<3>] position;
    uint[<4>] rotation;
    uint[<3>] scale;
    uint[<4>] color;
}

struct CellCopy @local {
    usz            index;
    Entity         cell;
    usz            capacity;
    InstanceBits[] instances;
}

// Fails one allocation above a byte, counted from 1; node names take one byte and must not fail.
struct FailingAllocator (Allocator) @local {
    Allocator backing;
    uint      fail_at;
    uint      sized;
}

fn void*? FailingAllocator.acquire(
    &self,
    sz bytes,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (bytes > 1) {
        self.sized++;
        if (self.sized == self.fail_at) return mem::OUT_OF_MEMORY~;
    }
    return self.backing.acquire(bytes, init_type, alignment);
}

fn void*? FailingAllocator.resize(
    &self,
    void* old_pointer,
    sz bytes,
    sz alignment,
) @dynamic {
    return self.backing.resize(old_pointer, bytes, alignment);
}

fn void FailingAllocator.release(&self, void* old_pointer, bool aligned) @dynamic {
    self.backing.release(old_pointer, aligned);
}

fn void setup(Fixture* fixture, Allocator allocator = mem, uint max_nodes = 0) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    SceneDesc scene_desc = scene::default_scene_desc();
    if (max_nodes) scene_desc.max_nodes = max_nodes;
    fixture.scene = scene::create_scene(allocator, scene_desc);
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    foliage::register_foliage(&fixture.scene)!!;
    @pool() {
        Geometry stalk = geometry::box(
            allocator: tmem,
            width:     0.2f,
            height:    0.6f,
            depth:     0.2f,
        );
        fixture.geometry = fixture.assets.add_geometry(&stalk)!!;
    };
    fixture.material = fixture.assets.add_material(material::standard())!!;
    char[4] full = { 255, 255, 255, 255 };
    fixture.full_density = add_density_map(fixture, 1, full[..]);
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(CAMERA_FOV_DEGREES, CAMERA_NEAR))!!;
}

fn void teardown(Fixture* fixture) @local {
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

fn float height_scale_of(Ground shape) @local {
    switch (shape) {
        case RANDOM: return RANDOM_HEIGHT_SCALE;
        case FLAT: return RANDOM_HEIGHT_SCALE; // receives the random ground's texels in the order test
        case RAMP: return RAMP_HEIGHT_SCALE;
        case STEPS: return STEP_HEIGHT_SCALE;
    }
}

fn ushort metres_to_texel(float metres, float height_scale) @local {
    return (ushort)(metres / height_scale * (float)ushort::max + 0.5f);
}

fn ushort ground_texel(Ground shape, uint x, ulong* state) @local {
    switch (shape) {
        case RANDOM: return (ushort)(next_random(state) >> 48);
        case FLAT: return 0;
        case RAMP:
            float along = (float)x * TERRAIN_CELL;
            return metres_to_texel(along * along * RAMP_CURVE, RAMP_HEIGHT_SCALE);
        case STEPS: return metres_to_texel((float)(x / STEP_TEXELS) * STEP_METRES, STEP_HEIGHT_SCALE);
    }
}

fn Node* add_ground(
    Fixture* fixture,
    Ground shape,
    Vec3 position = {},
    float yaw_degrees = 0,
) @local {
    TextureId height_map;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)(TEXELS * TEXELS * ushort::size));
        ushort[] texels = ((ushort*)pixels.ptr)[:TEXELS * TEXELS];
        ulong state = TEXEL_SEED;
        for (uint z = 0; z < TEXELS; z++) {
            for (uint x = 0; x < TEXELS; x++) texels[z * TEXELS + x] = ground_texel(shape, x, &state);
        }
        TextureDesc desc = material::texture_2d_desc(TEXELS, TEXELS, R16_UINT);
        desc.generate_mips = false;
        height_map = fixture.assets.add_texture(desc, pixels)!!;
    };
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = height_map;
    desc.cell_size = TERRAIN_CELL;
    desc.height_scale = height_scale_of(shape);
    desc.layers[0] = fixture.material;
    Node* node = fixture.scene.add_node()!!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(yaw_degrees));
    fixture.scene.update_world();
    terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    )!!;
    return node;
}

fn TextureId add_density_map(Fixture* fixture, uint width, char[] texels) @local {
    uint height = (uint)texels.len / (RGBA8_BYTES * width);
    return fixture.assets.add_texture(material::texture_2d_desc(width, height, RGBA8_UNORM), texels)!!;
}

fn TextureId height_map_of(Fixture* fixture, Node* ground) @local {
    return fixture.scene.get(ground, Terrain).desc.height_map;
}

fn FoliageDesc layer_desc(Fixture* fixture, Node* ground, TextureId density = {}) @local {
    FoliageDesc desc = foliage::default_foliage_desc();
    desc.geometry = fixture.geometry;
    desc.material = fixture.material;
    desc.ground = ground.id;
    desc.cell_size = LAYER_CELL;
    desc.rules.density_map = density.generation ? density : fixture.full_density;
    desc.rules.spacing = SPACING;
    desc.rules.seed = SEED;
    desc.rules.min_scale = SCALE_LOW;
    desc.rules.max_scale = SCALE_HIGH;
    desc.rules.min_tint = { TINT_LOW, TINT_LOW, TINT_LOW };
    return desc;
}

fn void? try_add_layer(Fixture* fixture, Node* node, FoliageDesc desc) @local {
    return foliage::add_foliage(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

// At the ground's pose, so layer-local and terrain-local coordinates coincide.
fn Node* add_layer(Fixture* fixture, FoliageDesc desc) @local {
    Node* node = fixture.scene.add_node()!!;
    node.local = fixture.scene.node(desc.ground).local;
    fixture.scene.update_world();
    try_add_layer(fixture, node, desc)!!;
    return node;
}

fn void? try_update(Fixture* fixture, Vec3 wind = {}) @local {
    terrain::update(
        scene:                &fixture.scene,
        assets:               &fixture.assets,
        camera_node:          fixture.camera,
        output_height_pixels: OUTPUT_HEIGHT,
    )!;
    return foliage::update(&fixture.scene, &fixture.assets, wind);
}

fn void update_landscape(Fixture* fixture, Vec3 wind = {}) @local {
    try_update(fixture, wind)!!;
}

fn void update_terrain(Fixture* fixture) @local {
    terrain::update(
        scene:                &fixture.scene,
        assets:               &fixture.assets,
        camera_node:          fixture.camera,
        output_height_pixels: OUTPUT_HEIGHT,
    )!!;
}

fn FoliageRuntime* runtime_of(Fixture* fixture, Node* layer) @local => fixture.scene.get(layer, FoliageRuntime);

fn InstancedMesh* cell_batch(Fixture* fixture, Node* layer, usz index) @local {
    Entity cell = runtime_of(fixture, layer).cells[index];
    if (!cell.generation) return null;
    return fixture.scene.world.get(cell, InstancedMesh);
}

fn usz cell_count(Fixture* fixture, Node* layer) @local => runtime_of(fixture, layer).cells.len;

fn InstanceBits instance_bits(InstancedMesh* batch, uint index) @local {
    Transform transform = batch.transforms[index];
    return {
        .position = bitcast(transform.position, uint[<3>]),
        .rotation = bitcast(transform.rotation.v, uint[<4>]),
        .scale    = bitcast(transform.scale, uint[<3>]),
        .color    = bitcast(batch.colors[index], uint[<4>]),
    };
}

fn bool same_bits(InstanceBits first, InstanceBits second) @local {
    return first.position == second.position && first.rotation == second.rotation && first.scale == second.scale
      && first.color == second.color;
}

fn void assert_same_layers(Fixture* fixture, Node* first, Node* second) @local {
    assert(cell_count(fixture, first) == cell_count(fixture, second));
    for (usz index = 0; index < cell_count(fixture, first); index++) {
        InstancedMesh* a = cell_batch(fixture, first, index);
        InstancedMesh* b = cell_batch(fixture, second, index);
        assert((a == null) == (b == null));
        if (!a) continue;
        assert(a.count == b.count);
        for (uint instance = 0; instance < a.count; instance++) {
            assert(same_bits(instance_bits(a, instance), instance_bits(b, instance)));
        }
    }
}

fn CellCopy[] copy_cells(Allocator allocator, Fixture* fixture, Node* layer) @local {
    CellCopy[] copies = alloc::new_array(allocator, CellCopy, (sz)cell_count(fixture, layer));
    foreach (usz index, &copy : copies) {
        copy.index = index;
        copy.cell = runtime_of(fixture, layer).cells[index];
        InstancedMesh* batch = cell_batch(fixture, layer, index);
        if (!batch) continue;
        copy.capacity = batch.transforms.len;
        copy.instances = alloc::new_array(allocator, InstanceBits, (sz)batch.count);
        foreach (uint instance, &bits : copy.instances) *bits = instance_bits(batch, instance);
    }
    return copies;
}

fn bool cell_unchanged(Fixture* fixture, Node* layer, CellCopy copy) @local {
    if (!c3d::same_id(runtime_of(fixture, layer).cells[copy.index], copy.cell)) return false;
    InstancedMesh* batch = cell_batch(fixture, layer, copy.index);
    if (!batch) return true;
    if (batch.count != copy.instances.len) return false;
    foreach (uint instance, bits : copy.instances) {
        if (!same_bits(instance_bits(batch, instance), bits)) return false;
    }
    return true;
}

fn Vec3 instance_world(Node* layer, InstancedMesh* batch, uint index) @local {
    return maths::transform_point(layer.world, batch.transforms[index].position);
}

fn void assert_cell_on_ground(HeightView* view, Node* layer, InstancedMesh* batch) @local {
    for (uint index = 0; index < batch.count; index++) {
        Vec3 world = instance_world(layer, batch, index);
        assert(math::abs(world.y - terrain::sample_height(view, world.x, world.z)!!) <= HEIGHT_TOLERANCE);
    }
}

fn void assert_layer_on_ground(Fixture* fixture, Node* layer, Node* ground) @local {
    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, ground.id)!!;
    for (usz index = 0; index < cell_count(fixture, layer); index++) {
        InstancedMesh* batch = cell_batch(fixture, layer, index);
        if (batch) assert_cell_on_ground(&view, layer, batch);
    }
}

fn bool keeps(HeightView* view, Vec3 world, Filter filter) @local {
    switch (filter) {
        case SLOPE:
            return terrain::sample_normal(view, world.x, world.z)!!.y >= math::cos(SLOPE_LIMIT);
        case ALTITUDE:
            float height = terrain::sample_height(view, world.x, world.z)!!;
            return height >= BAND_LOW && height <= BAND_HIGH;
    }
}

// The filtered layer holds exactly the unfiltered layer's instances the filter keeps, in order.
fn void assert_filtered(
    Fixture* fixture,
    Node* filtered,
    Node* every,
    Filter filter,
) @local {
    Entity ground = fixture.scene.get(every, Foliage).desc.ground;
    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, ground)!!;
    uint kept;
    uint removed;
    for (usz index = 0; index < cell_count(fixture, every); index++) {
        InstancedMesh* all = cell_batch(fixture, every, index);
        InstancedMesh* some = cell_batch(fixture, filtered, index);
        assert((all == null) == (some == null));
        if (!all) continue;
        uint next;
        for (uint instance = 0; instance < all.count; instance++) {
            if (!keeps(&view, instance_world(every, all, instance), filter)) {
                removed++;
                continue;
            }
            assert(next < some.count && same_bits(instance_bits(some, next), instance_bits(all, instance)));
            next++;
            kept++;
        }
        assert(next == some.count);
    }
    assert(kept > 0 && removed > 0);
}

// The subset is an ordered subsequence of the full-density layer; bands are shares of the extent along x.
fn void assert_density_band(
    Fixture* fixture,
    Node* subset,
    Node* every,
    Vec2 full,
    Vec2 empty,
) @local {
    uint kept;
    for (usz index = 0; index < cell_count(fixture, every); index++) {
        InstancedMesh* all = cell_batch(fixture, every, index);
        InstancedMesh* some = cell_batch(fixture, subset, index);
        if (!all) continue;
        uint next;
        for (uint instance = 0; instance < all.count; instance++) {
            float share = all.transforms[instance].position.x / EXTENT;
            bool matched = some && next < some.count;
            if (matched && same_bits(instance_bits(some, next), instance_bits(all, instance))) {
                assert(share < empty.x || share > empty.y);
                next++;
                kept++;
            } else {
                assert(share < full.x || share > full.y);
            }
        }
        assert(!some || next == some.count);
    }
    assert(kept > 0);
}

fn TexelRect quadrant(uint column, uint row) @local {
    return {
        .x       = column * QUADRANT_TEXELS,
        .z       = row * QUADRANT_TEXELS,
        .columns = column ? TEXELS - QUADRANT_TEXELS : QUADRANT_TEXELS,
        .rows    = row ? TEXELS - QUADRANT_TEXELS : QUADRANT_TEXELS,
    };
}

fn void copy_texels(
    Fixture* fixture,
    TextureId source,
    TextureId target,
    TexelRect rect,
) @local {
    ushort* from = (ushort*)fixture.assets.texture(source).pixels.ptr;
    ushort* to = (ushort*)fixture.assets.texture(target).pixels.ptr;
    for (uint z = rect.z; z < rect.z + rect.rows; z++) {
        for (uint x = rect.x; x < rect.x + rect.columns; x++) to[z * TEXELS + x] = from[z * TEXELS + x];
    }
    fixture.assets.mark_texture_dirty(target);
}

fn void write_extreme_texels(Fixture* fixture, TextureId texture, TexelRect rect) @local {
    ushort* texels = (ushort*)fixture.assets.texture(texture).pixels.ptr;
    for (uint z = rect.z; z < rect.z + rect.rows; z++) {
        for (uint x = rect.x; x < rect.x + rect.columns; x++) texels[z * TEXELS + x] = (x + z) % 2 ? ushort::max : 0;
    }
    fixture.assets.mark_texture_dirty(texture);
}

fn void stamp(Fixture* fixture, Node* ground, TexelRect rect) @local {
    write_extreme_texels(fixture, height_map_of(fixture, ground), rect);
    terrain::mark_dirty(&fixture.scene, ground, rect);
}

// A texel shapes the surface between its neighbours, so an edit reaches one texel past its rectangle.
fn bool cell_meets_edit(usz index, TexelRect rect) @local {
    uint cells_per_side = (uint)math::ceil(EXTENT / LAYER_CELL);
    float column = (float)(index % cells_per_side) * LAYER_CELL;
    float row = (float)(index / cells_per_side) * LAYER_CELL;
    float first_x = ((float)rect.x - 1) * TERRAIN_CELL;
    float first_z = ((float)rect.z - 1) * TERRAIN_CELL;
    float end_x = (float)(rect.x + rect.columns) * TERRAIN_CELL;
    float end_z = (float)(rect.z + rect.rows) * TERRAIN_CELL;
    return column < end_x && column + LAYER_CELL > first_x && row < end_z && row + LAYER_CELL > first_z;
}

fn void write_density(Fixture* fixture, TextureId texture, char[] texels) @local {
    fixture.assets.texture(texture).pixels[..] = texels[..];
    fixture.assets.mark_texture_dirty(texture);
}

fn void test_scatter_is_identical_in_any_cell_order() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RANDOM);
    FoliageDesc desc = layer_desc(&fixture, ground);
    desc.rules.max_slope = ORDER_SLOPE_LIMIT;
    Node* in_rows = add_layer(&fixture, desc);

    Node* flat = add_ground(&fixture, FLAT);
    desc.ground = flat.id;
    Node* by_quadrants = add_layer(&fixture, desc);
    uint[2][4] order = { { 1, 1 }, { 0, 0 }, { 1, 0 }, { 0, 1 } };
    foreach (quadrant_cell : order) {
        TexelRect rect = quadrant(quadrant_cell[0], quadrant_cell[1]);
        copy_texels(
            fixture: &fixture,
            source:  height_map_of(&fixture, ground),
            target:  height_map_of(&fixture, flat),
            rect:    rect,
        );
        terrain::mark_dirty(&fixture.scene, flat, rect);
        update_landscape(&fixture);
    }
    assert_same_layers(&fixture, in_rows, by_quadrants);
}

fn void test_terrain_edit_replaces_only_the_touched_cells() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(
        fixture:     &fixture,
        shape:       RANDOM,
        position:    ROTATED_GROUND_POSITION,
        yaw_degrees: ROTATED_GROUND_YAW_DEGREES,
    );
    Node* layer = add_layer(&fixture, layer_desc(&fixture, ground));

    @pool() {
        CellCopy[] before = copy_cells(tmem, &fixture, layer);
        TexelRect edit = { .x = CELL_EDGE_TEXEL, .z = CELL_EDGE_TEXEL / 4, .columns = EDIT_SIDE, .rows = EDIT_SIDE };
        stamp(&fixture, ground, edit);
        update_landscape(&fixture);

        HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, ground.id)!!;
        uint changed;
        foreach (usz index, copy : before) {
            if (!cell_meets_edit(index, edit)) {
                assert(cell_unchanged(&fixture, layer, copy));
                continue;
            }
            InstancedMesh* batch = cell_batch(&fixture, layer, index);
            if (batch) assert_cell_on_ground(&view, layer, batch);
            if (!cell_unchanged(&fixture, layer, copy)) changed++;
        }
        assert(changed > 0);
    };
}

fn void test_two_refreshes_between_updates_replace_the_whole_layer() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RANDOM);
    Node* layer = add_layer(&fixture, layer_desc(&fixture, ground));

    stamp(&fixture, ground, { .x = 8, .z = 8, .columns = EDIT_SIDE, .rows = EDIT_SIDE });
    update_terrain(&fixture);
    stamp(&fixture, ground, { .x = 100, .z = 100, .columns = EDIT_SIDE, .rows = EDIT_SIDE });
    update_terrain(&fixture);
    foliage::update(&fixture.scene, &fixture.assets, {})!!;
    assert_layer_on_ground(&fixture, layer, ground);
}

fn void test_slope_limit_removes_exactly_the_steep_candidates() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RAMP);
    FoliageDesc desc = layer_desc(&fixture, ground);
    Node* every = add_layer(&fixture, desc);
    desc.rules.max_slope = SLOPE_LIMIT;
    Node* limited = add_layer(&fixture, desc);
    assert_filtered(
        fixture:  &fixture,
        filtered: limited,
        every:    every,
        filter:   SLOPE,
    );
}

fn void test_altitude_band_removes_exactly_the_candidates_outside_it() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, STEPS, position: STEP_GROUND_POSITION);
    FoliageDesc desc = layer_desc(&fixture, ground);
    Node* every = add_layer(&fixture, desc);
    desc.rules.min_altitude = BAND_LOW;
    desc.rules.max_altitude = BAND_HIGH;
    Node* banded = add_layer(&fixture, desc);
    assert_filtered(
        fixture:  &fixture,
        filtered: banded,
        every:    every,
        filter:   ALTITUDE,
    );
}

fn void test_density_channel_selects_its_channel_of_the_map() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    char[16] red_then_green = { 255, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0 };
    TextureId split = add_density_map(&fixture, 4, red_then_green[..]);
    Node* every = add_layer(&fixture, layer_desc(&fixture, ground));
    FoliageDesc green_desc = layer_desc(&fixture, ground, split);
    green_desc.rules.density_channel = 1;
    Node* red = add_layer(&fixture, layer_desc(&fixture, ground, split));
    Node* green = add_layer(&fixture, green_desc);
    Vec2 left = { 0, FULL_DENSITY_BELOW };
    Vec2 right = { NO_DENSITY_ABOVE, 1 };
    assert_density_band(
        fixture: &fixture,
        subset:  red,
        every:   every,
        full:    left,
        empty:   right,
    );
    assert_density_band(
        fixture: &fixture,
        subset:  green,
        every:   every,
        full:    right,
        empty:   left,
    );
}

fn void test_density_edit_rescatters_like_a_fresh_layer() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RANDOM);
    char[16] before_edit = { 255, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0 };
    TextureId density = add_density_map(&fixture, 2, before_edit[..]);
    Node* layer = add_layer(&fixture, layer_desc(&fixture, ground, density));

    @pool() {
        CellCopy[] before = copy_cells(tmem, &fixture, layer);
        char[16] after_edit = { 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0 };
        write_density(&fixture, density, after_edit[..]);
        update_landscape(&fixture);
        Node* fresh = add_layer(&fixture, layer_desc(&fixture, ground, density));
        assert_same_layers(&fixture, layer, fresh);

        uint emptied;
        uint filled;
        foreach (usz index, copy : before) {
            Entity cell = runtime_of(&fixture, layer).cells[index];
            if (copy.cell.generation && cell.generation) {
                assert(c3d::same_id(copy.cell, cell));
                assert(cell_batch(&fixture, layer, index).transforms.len >= copy.capacity);
            }
            if (copy.cell.generation && !cell.generation) emptied++;
            if (!copy.cell.generation && cell.generation) filled++;
        }
        assert(emptied > 0 && filled > 0);
    };
}

fn void test_rescatter_past_the_node_budget_keeps_the_cells() @test {
    Fixture fixture;
    setup(&fixture, max_nodes: BUDGET_SCENE_NODES);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RANDOM);
    char[16] corner = { 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    TextureId density = add_density_map(&fixture, 2, corner[..]);
    Node* layer = add_layer(&fixture, layer_desc(&fixture, ground, density));
    Node*[FILLER_NODES] fillers;
    foreach (&filler : fillers) *filler = fixture.scene.add_node()!!;

    @pool() {
        CellCopy[] before = copy_cells(tmem, &fixture, layer);
        uint free_nodes = fixture.scene.world.entities.free_count;
        char[16] everywhere = { 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 };
        write_density(&fixture, density, everywhere[..]);
        assert(@catch(try_update(&fixture)) == c3d::CAPACITY_EXCEEDED);
        assert(fixture.scene.world.entities.free_count == free_nodes);
        foreach (copy : before) assert(cell_unchanged(&fixture, layer, copy));

        uint count_passes = runtime_of(&fixture, layer).count_passes;
        assert(@catch(try_update(&fixture)) == c3d::CAPACITY_EXCEEDED);
        assert(runtime_of(&fixture, layer).count_passes == count_passes);
        foreach (copy : before) assert(cell_unchanged(&fixture, layer, copy));

        foreach (filler : fillers) fixture.scene.remove(filler);
        update_landscape(&fixture);
        assert(runtime_of(&fixture, layer).count_passes == count_passes + 1);
        assert(runtime_of(&fixture, layer).cell_nodes == cell_count(&fixture, layer));
    };
}

fn void test_invalid_desc_values_are_invalid_argument() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    FoliageDesc valid = layer_desc(&fixture, ground);
    valid.trace = true;
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    for (uint variant = 0; variant < INVALID_DESCS; variant++) {
        FoliageDesc desc = valid;
        switch (variant) {
            case 0: desc.sway.lean = 1.5f;
            case 1: desc.sway.full_bend_speed = 0;
            case 2: desc.sway.amplitude = -1;
            case 3: desc.sway.frequency = -1;
            case 4: desc.rules.spacing = 0;
            case 5: desc.rules.density_channel = 4;
            case 6: desc.rules.min_scale = SCALE_HIGH * 2;
            case 7: desc.rules.max_slope = float::nan;
            case 8: desc.fade = { .start = 90, .end = 60 };
            default: desc.cell_size = 0;
        }
        assert(@catch(try_add_layer(&fixture, node, desc)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.scene.has(node, Foliage) && !fixture.scene.has(node, FoliageRuntime) && !node.first_child);
    }
}

fn void test_density_maps_other_than_rgba8_are_unsupported() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();

    char[8] half_float = {};
    TextureId wide = fixture.assets.add_texture(material::texture_2d_desc(1, 1, RGBA16_FLOAT), half_float[..])!!;
    assert(@catch(try_add_layer(&fixture, node, layer_desc(&fixture, ground, wide))) == c3d::UNSUPPORTED);

    char[4] full = { 255, 255, 255, 255 };
    TextureId released = add_density_map(&fixture, 1, full[..]);
    fixture.assets.release_texture_cpu(released);
    assert(@catch(try_add_layer(&fixture, node, layer_desc(&fixture, ground, released))) == c3d::INVALID_ARGUMENT);

    TextureId removed = add_density_map(&fixture, 1, full[..]);
    fixture.assets.remove_texture(removed);
    assert(@catch(try_add_layer(&fixture, node, layer_desc(&fixture, ground, removed))) == c3d::INVALID_ID);

    FoliageDesc bare_ground = layer_desc(&fixture, ground);
    bare_ground.ground = node.id;
    assert(@catch(try_add_layer(&fixture, node, bare_ground)) == c3d::INVALID_ID);
    assert(!node.first_child);

    TextureId density = add_density_map(&fixture, 1, full[..]);
    Node* layer = add_layer(&fixture, layer_desc(&fixture, ground, density));
    @pool() {
        CellCopy[] before = copy_cells(tmem, &fixture, layer);
        TextureAsset* record = fixture.assets.texture(density);
        TextureAsset* replacement = fixture.assets.texture(wide);
        char[] original = record.pixels;
        TextureDesc original_desc = record.desc;
        record.desc = replacement.desc;
        record.pixels = replacement.pixels;
        fixture.assets.mark_texture_dirty(density);
        assert(@catch(try_update(&fixture)) == c3d::UNSUPPORTED);
        foreach (copy : before) assert(cell_unchanged(&fixture, layer, copy));
        record.desc = original_desc;
        record.pixels = original;
    };
}

fn void test_node_budget_faults_before_any_node_is_created() @test {
    Fixture fixture;
    setup(&fixture, max_nodes: SMALL_SCENE_NODES);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    uint free_nodes = fixture.scene.world.entities.free_count;
    assert(@catch(try_add_layer(&fixture, node, layer_desc(&fixture, ground))) == c3d::CAPACITY_EXCEEDED);
    assert(fixture.scene.world.entities.free_count == free_nodes);
    assert(!fixture.scene.has(node, Foliage) && !node.first_child);
    // A node created and removed would leave its slot a generation ahead.
    assert(fixture.scene.add_node()!!.id.generation == 1);
}

fn void test_failed_allocations_roll_back_the_layer() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    FailingAllocator failing = { .backing = &tracking };
    Fixture fixture;
    setup(&fixture, allocator: &failing);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    FoliageDesc desc = layer_desc(&fixture, ground);
    desc.cell_size = EXTENT * 0.5f;
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();

    uint failures;
    for (uint fail_at = 1; ; fail_at++) {
        sz allocations = tracking.allocation_count();
        uint free_nodes = fixture.scene.world.entities.free_count;
        failing.sized = 0;
        failing.fail_at = fail_at;
        fault excuse = @catch(try_add_layer(&fixture, node, desc));
        failing.fail_at = 0;
        if (!excuse) break;
        assert(excuse == c3d::CAPACITY_EXCEEDED);
        assert(tracking.allocation_count() == allocations);
        assert(fixture.scene.world.entities.free_count == free_nodes);
        assert(!fixture.scene.has(node, Foliage) && !node.first_child);
        failures++;
    }
    assert(failures > 2 && runtime_of(&fixture, node).cell_nodes == 4);
}

fn void assert_layer_sway(Fixture* fixture, Node* layer, InstanceSway expected) @local {
    for (usz index = 0; index < cell_count(fixture, layer); index++) {
        InstancedMesh* batch = cell_batch(fixture, layer, index);
        if (!batch) continue;
        batch.validate_effects();
        InstanceSway sway = batch.sway;
        assert((sway.direction - expected.direction).length() <= 1e-6f);
        assert(math::abs(sway.amplitude - expected.amplitude) <= 1e-6f);
        assert(sway.frequency == expected.frequency && sway.lean == expected.lean);
        assert(sway.wavelength == expected.wavelength && sway.variation == expected.variation);
        assert(sway.weight == expected.weight);
    }
}

fn void test_wind_scales_the_sway_template() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    char[16] half = { 255, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0 };
    TextureId density = add_density_map(&fixture, 2, half[..]);
    FoliageDesc desc = layer_desc(&fixture, ground, density);
    desc.sway = TEST_SWAY;
    Node* layer = add_layer(&fixture, desc);
    InstanceSway full = {
        .direction  = GALE_WIND.normalize(),
        .amplitude  = TEST_SWAY.amplitude,
        .frequency  = TEST_SWAY.frequency,
        .lean       = TEST_SWAY.lean,
        .wavelength = TEST_SWAY.wavelength,
        .variation  = TEST_SWAY.variation,
        .weight     = TEST_SWAY.weight,
    };

    assert_layer_sway(&fixture, layer, { .weight = TEST_SWAY.weight });
    update_landscape(&fixture, GALE_WIND);
    assert_layer_sway(&fixture, layer, full);
    update_landscape(&fixture, HALF_BEND_WIND);
    InstanceSway half_bend = full;
    half_bend.amplitude = TEST_SWAY.amplitude * 0.5f;
    assert_layer_sway(&fixture, layer, half_bend);

    char[16] everywhere = { 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 };
    uint cells_before = runtime_of(&fixture, layer).cell_nodes;
    write_density(&fixture, density, everywhere[..]);
    update_landscape(&fixture, HALF_BEND_WIND);
    assert(runtime_of(&fixture, layer).cell_nodes > cells_before);
    assert_layer_sway(&fixture, layer, half_bend);

    update_landscape(&fixture, {});
    assert_layer_sway(&fixture, layer, { .weight = TEST_SWAY.weight });
}

fn void test_desc_edits_after_add_do_not_reach_the_cells() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RANDOM);
    FoliageDesc desc = layer_desc(&fixture, ground);
    desc.sway = TEST_SWAY;
    Node* edited = add_layer(&fixture, desc);
    Node* twin = add_layer(&fixture, desc);
    FoliageDesc* authored = &fixture.scene.get(edited, Foliage).desc;
    authored.rules.spacing = EDITED_SPACING;
    authored.rules.seed = EDITED_SEED;
    authored.sway.lean = EDITED_LEAN;

    stamp(&fixture, ground, { .x = CELL_EDGE_TEXEL, .z = CELL_EDGE_TEXEL, .columns = EDIT_SIDE, .rows = EDIT_SIDE });
    update_landscape(&fixture, GALE_WIND);
    assert_same_layers(&fixture, edited, twin);
    InstanceSway full = {
        .direction  = GALE_WIND.normalize(),
        .amplitude  = TEST_SWAY.amplitude,
        .frequency  = TEST_SWAY.frequency,
        .lean       = TEST_SWAY.lean,
        .wavelength = TEST_SWAY.wavelength,
        .variation  = TEST_SWAY.variation,
        .weight     = TEST_SWAY.weight,
    };
    assert_layer_sway(&fixture, edited, full);
}

fn void test_moved_ground_rescatters_like_a_fresh_layer() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, RANDOM);
    FoliageDesc desc = layer_desc(&fixture, ground);
    desc.rules.max_slope = ORDER_SLOPE_LIMIT;
    Node* layer = add_layer(&fixture, desc);

    ground.local.position = MOVED_GROUND_POSITION;
    ground.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(MOVED_GROUND_YAW_DEGREES));
    fixture.scene.update_world();
    update_landscape(&fixture);
    Node* fresh = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    try_add_layer(&fixture, fresh, desc)!!;
    assert_same_layers(&fixture, layer, fresh);
    assert_layer_on_ground(&fixture, layer, ground);
}

fn void assert_cells_trace(Fixture* fixture, Node* layer, bool trace) @local {
    for (usz index = 0; index < cell_count(fixture, layer); index++) {
        InstancedMesh* batch = cell_batch(fixture, layer, index);
        if (batch) assert(batch.trace == trace);
    }
}

fn void test_removed_foliage_releases_its_cells() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture, FLAT);
    FoliageDesc traced = layer_desc(&fixture, ground);
    traced.trace = true;
    Node* first = add_layer(&fixture, traced);
    Node* second = add_layer(&fixture, layer_desc(&fixture, ground));
    assert_cells_trace(&fixture, first, true);
    assert_cells_trace(&fixture, second, false);
    Entity first_cell = runtime_of(&fixture, first).cells[0];
    Entity second_cell = runtime_of(&fixture, second).cells[0];

    fixture.scene.remove_component(first, Foliage);
    update_landscape(&fixture);
    assert(!fixture.scene.world.is_alive(first_cell) && !fixture.scene.has(first, FoliageRuntime));
    assert(fixture.scene.world.is_alive(second_cell));

    fixture.scene.remove(second);
    update_landscape(&fixture);
    assert(!fixture.scene.world.is_alive(second_cell));
}

fn void test_foliage_lod_preserves_scatter_and_owns_descriptors() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Fixture fixture;
    setup(&fixture, allocator: &tracking);
    Node* ground = add_ground(&fixture, RANDOM);
    FoliageDesc desc = layer_desc(&fixture, ground);
    desc.sway = TEST_SWAY;
    desc.trace = true;
    Node* plain = add_layer(&fixture, desc);
    LodLevel[2] levels = {
        { .part_count = 2, .min_screen_size = 0.2f },
        { .first_part = 2, .part_count = 1 },
    };
    LodPart[3] parts;
    parts[..] = { .geometry = fixture.geometry, .material = fixture.material, .local = maths::TRANSFORM_IDENTITY.to_mat4() };
    LodDesc lod = { .levels = levels[..], .parts = parts[..] };
    desc.lod = &lod;
    Node* grouped = add_layer(&fixture, desc);
    levels[..] = {};
    parts[..] = {};
    lod = {};

    FoliageRuntime* runtime = runtime_of(&fixture, grouped);
    assert(runtime.desc.lod != &lod && runtime.desc.lod.levels[0].part_count == 2);
    LodGroupState* first = fixture.scene.world.get(runtime.cells[0], LodGroup).state;
    ulong identity = first.identity;
    ulong epoch = first.instance_epoch;
    assert(first.desc.parts.ptr != runtime.desc.lod.parts.ptr);
    update_landscape(&fixture, GALE_WIND);
    assert(first.identity == identity && first.instance_epoch == epoch);
    assert(first.effects.sway.amplitude == TEST_SWAY.amplitude && first.effects.trace);
    assert(first.effects.fade.end == desc.fade.end);
    assert_plain_and_lod_scatter(&fixture, plain, grouped);

    stamp(&fixture, ground, { .x = 0, .z = 0, .columns = EDIT_SIDE, .rows = EDIT_SIDE });
    update_landscape(&fixture, GALE_WIND);
    assert(first.instance_epoch != epoch);
    assert_plain_and_lod_scatter(&fixture, plain, grouped);
    Entity cell = runtime_of(&fixture, grouped).cells[0];
    fixture.scene.remove_component(grouped, Foliage);
    update_landscape(&fixture);
    assert(!fixture.scene.world.is_alive(cell) && !fixture.scene.has(grouped, FoliageRuntime));
    teardown(&fixture);
    assert(tracking.allocation_count() == 0);
}

fn void test_foliage_lod_allocation_failure_is_atomic() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    FailingAllocator failing = { .backing = &tracking };
    Fixture fixture;
    setup(&fixture, allocator: &failing);
    Node* ground = add_ground(&fixture, FLAT);
    LodLevel[1] levels = { { .part_count = 1 } };
    LodPart[1] parts = { {
        .geometry = fixture.geometry,
        .material = fixture.material,
        .local = maths::TRANSFORM_IDENTITY.to_mat4(),
    } };
    LodDesc lod = { .levels = levels[..], .parts = parts[..] };
    char[4] partial = { 64, 0, 0, 0 };
    TextureId density = add_density_map(&fixture, 1, partial[..]);
    FoliageDesc desc = layer_desc(&fixture, ground, density);
    desc.lod = &lod;
    desc.cell_size = EXTENT * 0.5f;
    Node* layer = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    for (uint fail_at = 1; ; fail_at++) {
        sz allocations = tracking.allocation_count();
        uint free_nodes = fixture.scene.world.entities.free_count;
        failing.sized = 0;
        failing.fail_at = fail_at;
        fault excuse = @catch(try_add_layer(&fixture, layer, desc));
        failing.fail_at = 0;
        if (!excuse) break;
        assert(excuse == c3d::CAPACITY_EXCEEDED);
        assert(tracking.allocation_count() == allocations);
        assert(fixture.scene.world.entities.free_count == free_nodes && !layer.first_child);
    }
    LodGroupState* first = fixture.scene.world.get(runtime_of(&fixture, layer).cells[0], LodGroup).state;
    ulong identity = first.identity;
    uint count = first.count;
    char[4] full = { 255, 0, 0, 0 };
    write_density(&fixture, density, full[..]);
    failing.sized = 0;
    failing.fail_at = 2;
    sz allocations = tracking.allocation_count();
    assert(@catch(try_update(&fixture)) == c3d::CAPACITY_EXCEEDED);
    failing.fail_at = 0;
    assert(tracking.allocation_count() == allocations);
    assert(first.identity == identity && first.count == count);
    fixture.assets.mark_texture_dirty(density);
    update_landscape(&fixture);
    first = fixture.scene.world.get(runtime_of(&fixture, layer).cells[0], LodGroup).state;
    assert(first.identity != identity && first.count > count);
    teardown(&fixture);
    assert(tracking.allocation_count() == 0);
}

fn void assert_plain_and_lod_scatter(Fixture* fixture, Node* plain, Node* grouped) @local {
    FoliageRuntime* runtime = runtime_of(fixture, grouped);
    assert(runtime.instances == runtime_of(fixture, plain).instances);
    foreach (usz index, cell : runtime.cells) {
        InstancedMesh* batch = cell_batch(fixture, plain, index);
        assert((batch != null) == (cell.generation != 0));
        if (!batch) continue;
        LodGroupState* state = fixture.scene.world.get(cell, LodGroup).state;
        assert(state.count == batch.count);
        for (uint slot = 0; slot < batch.count; slot++) {
            assert(state.transforms[slot].to_mat4() == batch.transforms[slot].to_mat4());
            assert(state.colors[slot] == batch.colors[slot]);
        }
    }
}
