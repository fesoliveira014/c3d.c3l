module c3d_terrain_setup_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::material;
import c3d::nav;
import c3d::physics;
import c3d::scene;

const uint TEXELS @local = 129; // one chunk, 128 cells
const float CELL_SIZE @local = 0.5f;
const float HEIGHT_SCALE @local = 20;
const float TEXEL_MAX @local = 65535; // height = height_scale * texel / 65535, the physics height-field rule
const float BASE_HEIGHT @local = 8; // metres above the node; leaves the hills clear of both ends of the scale
const float HILL_AMPLITUDE @local = 1; // metres
const float HILL_WAVE_X @local = 0.4488f; // radians per metre: a 14 m wavelength
const float HILL_WAVE_Z @local = 0.3142f; // a 20 m wavelength; different on each axis so a swapped axis disagrees
const Vec3 TERRAIN_POSITION @local = { 3, -2, 5 };
const float TERRAIN_YAW_DEGREES @local = 30;
const Vec3 REBASE_OFFSET @local = { 40, 0, -30 };
const float SCALED_NODE @local = 1.01f;
const float RAY_START_HEIGHT @local = 100; // above HEIGHT_SCALE plus the node's height
const float RAY_LENGTH @local = 200;
const float OUTSIDE_DISTANCE @local = 1000; // metres past the map
const uint EDIT_TEXEL @local = 10;
const uint TILE_COUNT @local = 2; // tiles of the seam set, side by side along x
const float SEAM_REGION_Z @local = 20; // metres from the set's origin to the grid's first row; a texel row
const float HALF_CELL @local = 0.5f;
const float SEAM_CLEARANCE @local = 0.125f; // metres, a quarter of a cell: off both diagonals of the cells either side
const uint NAV_TILES @local = 2; // along each axis
const uint NAV_TILE_CELLS @local = 16;
const float NAV_PADDING @local = 1; // metres around the terrain's height range, for edits that stay inside it
const float NAV_AGENT_HEIGHT @local = 1;
const float NAV_AGENT_MAX_CLIMB @local = 1; // above the step between neighbouring cells at the largest cell size
const float NAV_AGENT_MAX_SLOPE_DEGREES @local = 60; // above the steepest hill face
const uint NAV_QUERY_NODES @local = 256;
const uint NAV_UPDATES @local = 128; // far more than the tiles of the grid need
const Vec3 NAV_NEAR @local = { 0.1f, 0.5f, 0.1f }; // half extents of the polygon search; Y holds the sampled height
const float PHYSICS_TOLERANCE @local = 0.001f; // metres; float rounding of the rotated node and box3d's ray
const float NAV_TOLERANCE @local = 0.0001f; // metres; detail_max_error 0 plus the builder's float allowance
const float RANGE_TOLERANCE @local = 0.0001f; // metres; float rounding of the texel scale and the node's translation
const float SEAM_AGREEMENT @local = 0.0001f; // metres; float rounding of two node transforms at the shared edge
const float INTERPOLATION_BOUND @local = 0.0254f; // metres; half a second difference 0.02507 plus a texel unit 0.00031

struct Fixture @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    MaterialId   layer;
}

struct Navigation @local {
    GridHeightSampler sampler;
    GridCache         grid;
    NavMesh           mesh;
    NavQuery          query;
    QueryFilter       filter;
}

struct TileHeights @local {
    HeightView[] views;
    Vec3         origin;
    float        tile_extent;
    uint         columns;
    uint         rows;
}

fn void setup(Fixture* fixture, Allocator allocator = mem) @local {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(allocator, scene::default_scene_desc());
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    fixture.layer = fixture.assets.add_material(material::standard({ .base_color = { 1, 1, 1, 1 }, .roughness = 1 }))!!;
}

fn void teardown(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void add_physics(Fixture* fixture) @local {
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
}

fn void remove_physics(Fixture* fixture) @local {
    physics::destroy_physics_world(&fixture.physics);
}

// Heights over the metres of a whole map or tile set, so tiles that cut one map share their edge texels.
fn ushort hill_texel(float metres_x, float metres_z) @local {
    float height = BASE_HEIGHT + HILL_AMPLITUDE * math::sin(HILL_WAVE_X * metres_x) * math::sin(HILL_WAVE_Z * metres_z);
    return (ushort)math::round(height / HEIGHT_SCALE * TEXEL_MAX);
}

fn TextureId add_hill_map(Fixture* fixture, uint first_column = 0, uint first_row = 0) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (usz)TEXELS * TEXELS);
        for (uint row = 0; row < TEXELS; row++) {
            for (uint column = 0; column < TEXELS; column++) {
                texels[row * TEXELS + column] = hill_texel(
                    (float)(first_column + column) * CELL_SIZE,
                    (float)(first_row + row) * CELL_SIZE,
                );
            }
        }
        TextureDesc desc = material::texture_2d_desc(TEXELS, TEXELS, R16_UINT);
        desc.generate_mips = false;
        texture = fixture.assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * ushort::size])!!;
    };
    return texture;
}

fn TerrainDesc hill_desc(Fixture* fixture, TextureId height_map) @local {
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = height_map;
    desc.cell_size = CELL_SIZE;
    desc.height_scale = HEIGHT_SCALE;
    desc.layers[0] = fixture.layer;
    return desc;
}

fn Node* add_hill_node(
    Fixture* fixture,
    Vec3 position = TERRAIN_POSITION,
    float yaw_degrees = 0,
) @local {
    Node* node = fixture.scene.add_node()!!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(yaw_degrees));
    fixture.scene.update_world();
    terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   hill_desc(fixture, add_hill_map(fixture)),
    )!!;
    return node;
}

fn void add_collider(Fixture* fixture, Node* node) @local {
    TerrainCollisionInput input = terrain::collision_input(&fixture.scene, node.id)!!;
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = input.height_map };
    collider.local.scale = input.scale;
    fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
}

fn float ray_height(Fixture* fixture, float world_x, float world_z) @local {
    return fixture.physics.raycast({ world_x, RAY_START_HEIGHT, world_z }, { 0, -1, 0 }, RAY_LENGTH)!!.point.y;
}

fn GridHeightSample? terrain_height(void* context, float world_x, float world_z) @local {
    HeightView* view = context;
    float? height = terrain::sample_height(view, world_x, world_z);
    if (catch height) return {};

    return { .height = height, .present = true };
}

fn GridHeightSample? tile_height(void* context, float world_x, float world_z) @local {
    TileHeights* tiles = context;
    int column = (int)math::floor((world_x - tiles.origin.x) / tiles.tile_extent);
    int row = (int)math::floor((world_z - tiles.origin.z) / tiles.tile_extent);
    column = math::clamp(column, 0, (int)tiles.columns - 1);
    row = math::clamp(row, 0, (int)tiles.rows - 1);

    HeightView* view = &tiles.views[(uint)row * tiles.columns + (uint)column];
    float? height = terrain::sample_height(view, world_x, world_z);
    if (catch height) return {};

    return { .height = height, .present = true };
}

fn void create_navigation(
    Navigation* navigation,
    GridHeightSampleFn callback,
    void* context,
    Vec3 origin,
    float cell_size,
    TerrainHeightRange range,
) @local {
    navigation.sampler = {
        .origin    = origin,
        .cell_size = cell_size,
        .sample    = callback,
        .context   = context,
        .diagonal  = MAX_MIN_TO_MIN_MAX,
        .area      = nav::WALKABLE_AREA,
    };
    GridSourceDesc source = nav::grid_sampled_source(
        sampler:    &navigation.sampler,
        min_height: range.minimum - NAV_PADDING,
        max_height: range.maximum + NAV_PADDING,
    )!!;

    NavBuildConfig config = nav::default_grid_build_config(cell_size);
    config.tile_size = NAV_TILE_CELLS;
    config.agent_height = NAV_AGENT_HEIGHT;
    config.agent_radius = 0;
    config.agent_max_climb = NAV_AGENT_MAX_CLIMB;
    config.agent_max_slope_degrees = NAV_AGENT_MAX_SLOPE_DEGREES;
    config.region_merge_size = 0;
    config.detail_mode = BOUNDED;
    config.detail_max_error = 0;

    GridCacheDesc desc = nav::default_grid_cache_desc({ .max_x = (int)NAV_TILES, .max_z = (int)NAV_TILES }, config);
    navigation.grid = nav::create_grid_cache(
        allocator: mem,
        desc:      desc,
        source:    source,
        identity:  (GridSourceId)1,
        revision:  1,
    )!!;
    navigation.mesh = nav::create_nav_mesh(mem, navigation.grid.mesh_desc())!!;
    navigation.query = nav::create_nav_query(mem, &navigation.mesh, NAV_QUERY_NODES)!!;
    navigation.filter = nav::default_query_filter();

    uint pending = 1;
    for (uint step = 0; step < NAV_UPDATES && pending; step++) {
        GridUpdateResult result = navigation.grid.update(&navigation.mesh, 1);
        assert(result.failed == 0);
        pending = result.pending;
    }
    assert(pending == 0);
}

fn void destroy_navigation(Navigation* navigation) @local {
    nav::destroy_nav_query(&navigation.query);
    nav::destroy_nav_mesh(&navigation.mesh);
    nav::destroy_grid_cache(&navigation.grid);
}

fn float navigation_height(Navigation* navigation, Vec3 near) @local {
    NearestPoly nearest = navigation.query.find_nearest_poly(near, NAV_NEAR, &navigation.filter)!!;
    return navigation.query.poly_height(nearest.ref, near)!!;
}

fn Vec3 node_point(Node* node, float local_x, float local_z) @local {
    return maths::transform_point(node.world, { local_x, 0, local_z });
}

fn Vec3 navigation_origin(Node* node, float cell_size) @local {
    float half = (float)(NAV_TILES * NAV_TILE_CELLS) * cell_size * 0.5f;
    float middle = (float)(TEXELS - 1) * CELL_SIZE * 0.5f;
    Vec3 center = node_point(node, middle, middle);
    return { center.x - half, 0, center.z - half };
}

fn void assert_point_agrees(
    Fixture* fixture,
    Navigation* navigation,
    HeightView* owner,
    float world_x,
    float world_z,
) @local {
    float height = terrain::sample_height(owner, world_x, world_z)!!;
    assert(math::abs(ray_height(fixture, world_x, world_z) - height) <= PHYSICS_TOLERANCE);
    assert(math::abs(navigation_height(navigation, { world_x, height, world_z }) - height) <= NAV_TOLERANCE);
}

fn void assert_lattice_agrees(
    Fixture* fixture,
    Navigation* navigation,
    HeightView* view,
    Vec3 origin,
) @local {
    uint[<2>][5] lattice_vertices = { { 5, 6 }, { 16, 16 }, { 27, 9 }, { 12, 25 }, { 20, 20 } };
    foreach (vertex : lattice_vertices) {
        assert_point_agrees(
            fixture:    fixture,
            navigation: navigation,
            owner:      view,
            world_x:    origin.x + (float)vertex[0] * CELL_SIZE,
            world_z:    origin.z + (float)vertex[1] * CELL_SIZE,
        );
    }
}

fn TerrainHeightRange texel_range(Fixture* fixture, TextureId height_map) @local {
    TextureAsset* record = fixture.assets.texture(height_map);
    ushort lowest = ushort::max;
    ushort highest = 0;
    foreach (texel : ((ushort*)record.pixels.ptr)[:(usz)TEXELS * TEXELS]) {
        lowest = min(lowest, texel);
        highest = max(highest, texel);
    }
    return {
        .minimum = TERRAIN_POSITION.y + (float)lowest * HEIGHT_SCALE / TEXEL_MAX,
        .maximum = TERRAIN_POSITION.y + (float)highest * HEIGHT_SCALE / TEXEL_MAX,
    };
}

fn void test_terrain_physics_and_navigation_agree() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_physics(&fixture);
    defer remove_physics(&fixture);
    Node* node = add_hill_node(&fixture, TERRAIN_POSITION, TERRAIN_YAW_DEGREES);
    add_collider(&fixture, node);

    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, node.id)!!;
    TerrainHeightRange range = terrain::height_range(&fixture.scene, node.id)!!;
    TerrainHeightRange scanned = texel_range(&fixture, fixture.scene.get(node, Terrain).desc.height_map);
    assert(math::abs(range.minimum - scanned.minimum) <= RANGE_TOLERANCE);
    assert(math::abs(range.maximum - scanned.maximum) <= RANGE_TOLERANCE);

    Vec3 origin = navigation_origin(node, CELL_SIZE);
    Navigation navigation;
    create_navigation(
        navigation: &navigation,
        callback:   &terrain_height,
        context:    &view,
        origin:     origin,
        cell_size:  CELL_SIZE,
        range:      range,
    );
    defer destroy_navigation(&navigation);
    assert_lattice_agrees(&fixture, &navigation, &view, origin);

    GridHeightSample outside = terrain_height(&view, origin.x - OUTSIDE_DISTANCE, origin.z)!!;
    assert(!outside.present);

    TextureId height_map = fixture.scene.get(node, Terrain).desc.height_map;
    ushort* texels = (ushort*)fixture.assets.texture(height_map).pixels.ptr;
    texels[EDIT_TEXEL * TEXELS + EDIT_TEXEL] = ushort::max;
    fixture.assets.mark_texture_dirty(height_map);
    terrain::mark_dirty(&fixture.scene, node, { .x = EDIT_TEXEL, .z = EDIT_TEXEL, .columns = 1, .rows = 1 });
    terrain::update(&fixture.scene, &fixture.assets)!!;
    TerrainHeightRange edited = terrain::height_range(&fixture.scene, node.id)!!;
    assert(math::abs(edited.maximum - (TERRAIN_POSITION.y + HEIGHT_SCALE)) <= RANGE_TOLERANCE);
}

fn void test_setup_survives_an_origin_rebase() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_physics(&fixture);
    defer remove_physics(&fixture);
    Node* node = add_hill_node(&fixture, TERRAIN_POSITION, TERRAIN_YAW_DEGREES);
    add_collider(&fixture, node);

    fixture.scene.shift_origin(REBASE_OFFSET);
    fixture.scene.update_world();
    fixture.physics.shift_origin(&fixture.scene, REBASE_OFFSET);
    assert(@ok(terrain::collision_input(&fixture.scene, node.id)));

    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, node.id)!!;
    TerrainHeightRange range = terrain::height_range(&fixture.scene, node.id)!!;
    Vec3 origin = navigation_origin(node, CELL_SIZE);
    Navigation navigation;
    create_navigation(
        navigation: &navigation,
        callback:   &terrain_height,
        context:    &view,
        origin:     origin,
        cell_size:  CELL_SIZE,
        range:      range,
    );
    defer destroy_navigation(&navigation);
    assert_lattice_agrees(&fixture, &navigation, &view, origin);
}

fn void test_navigation_is_continuous_across_a_tile_seam() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_physics(&fixture);
    defer remove_physics(&fixture);
    Node* set_node = fixture.scene.add_node(name: "set")!!;
    set_node.local.position = TERRAIN_POSITION;
    fixture.scene.add(set_node, (TerrainSet){ .texels = TEXELS, .cell_size = CELL_SIZE, .height_scale = HEIGHT_SCALE });
    float extent = fixture.scene.get(set_node, TerrainSet).tile_extent();

    Node*[TILE_COUNT] tile_nodes;
    for (uint index = 0; index < TILE_COUNT; index++) {
        Node* tile_node = fixture.scene.add_node(set_node)!!;
        tile_node.local.position = { (float)index * extent, 0, 0 };
        fixture.scene.add(tile_node, (TerrainTile){ .x = (int)index, .z = 0 });
        terrain::add_terrain(
            scene:  &fixture.scene,
            assets: &fixture.assets,
            node:   tile_node,
            desc:   hill_desc(&fixture, add_hill_map(&fixture, index * (TEXELS - 1))),
        )!!;
        tile_nodes[index] = tile_node;
    }
    fixture.scene.update_world();

    HeightView[TILE_COUNT] views;
    TerrainHeightRange range = { .minimum = float::max, .maximum = -float::max };
    foreach (index, tile_node : tile_nodes) {
        add_collider(&fixture, tile_node);
        views[index] = terrain::height_view(&fixture.scene, &fixture.assets, tile_node.id)!!;
        TerrainHeightRange tile_range = terrain::height_range(&fixture.scene, tile_node.id)!!;
        range.minimum = min(range.minimum, tile_range.minimum);
        range.maximum = max(range.maximum, tile_range.maximum);
    }

    TileHeights tiles = {
        .views       = views[..],
        .origin      = TERRAIN_POSITION,
        .tile_extent = extent,
        .columns     = TILE_COUNT,
        .rows        = 1,
    };
    float seam = TERRAIN_POSITION.x + extent;
    float region = (float)(NAV_TILES * NAV_TILE_CELLS) * CELL_SIZE;
    Vec3 origin = { seam - region * 0.5f, 0, TERRAIN_POSITION.z + SEAM_REGION_Z };
    Navigation navigation;
    create_navigation(
        navigation: &navigation,
        callback:   &tile_height,
        context:    &tiles,
        origin:     origin,
        cell_size:  CELL_SIZE,
        range:      range,
    );
    defer destroy_navigation(&navigation);

    uint[2] rows = { 4, 13 };
    foreach (row : rows) {
        float world_z = origin.z + ((float)row + HALF_CELL) * CELL_SIZE;
        assert_point_agrees(
            fixture:    &fixture,
            navigation: &navigation,
            owner:      &views[0],
            world_x:    seam - SEAM_CLEARANCE,
            world_z:    world_z,
        );
        assert_point_agrees(
            fixture:    &fixture,
            navigation: &navigation,
            owner:      &views[1],
            world_x:    seam + SEAM_CLEARANCE,
            world_z:    world_z,
        );

        float left = terrain::sample_height(&views[0], seam, world_z)!!;
        float right = terrain::sample_height(&views[1], seam, world_z)!!;
        assert(math::abs(left - right) <= SEAM_AGREEMENT);
    }
}

fn void test_navigation_at_twice_the_cell_size() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_hill_node(&fixture);
    HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, node.id)!!;
    TerrainHeightRange range = terrain::height_range(&fixture.scene, node.id)!!;

    float cell_size = CELL_SIZE * 2;
    Vec3 origin = navigation_origin(node, cell_size);
    Navigation navigation;
    create_navigation(
        navigation: &navigation,
        callback:   &terrain_height,
        context:    &view,
        origin:     origin,
        cell_size:  cell_size,
        range:      range,
    );
    defer destroy_navigation(&navigation);

    uint[<2>][4] edge_midpoints = { { 3, 4 }, { 10, 11 }, { 20, 7 }, { 14, 21 } };
    foreach (midpoint : edge_midpoints) {
        float world_x = origin.x + ((float)midpoint[0] + HALF_CELL) * cell_size;
        float world_z = origin.z + (float)midpoint[1] * cell_size;
        float height = terrain::sample_height(&view, world_x, world_z)!!;
        float error = math::abs(navigation_height(&navigation, { world_x, height, world_z }) - height);
        assert(error <= INTERPOLATION_BOUND + NAV_TOLERANCE);
    }
}

fn void test_released_height_pixels_fault_the_view() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Fixture fixture;
    setup(&fixture, &tracking);
    Node* node = add_hill_node(&fixture);
    TextureId height_map = fixture.scene.get(node, Terrain).desc.height_map;
    assert(@ok(terrain::height_view(&fixture.scene, &fixture.assets, node.id)));

    fixture.assets.release_texture_cpu(height_map);
    assert(@catch(terrain::height_view(&fixture.scene, &fixture.assets, node.id)) == c3d::INVALID_ARGUMENT);

    teardown(&fixture);
    assert(!tracking.has_leaks());
}

fn void test_setup_values_refuse_unusable_nodes() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    assert(@catch(terrain::collision_input(&fixture.scene, node.id)) == c3d::INVALID_ID);

    terrain::attach_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   hill_desc(&fixture, add_hill_map(&fixture)),
    )!!;
    assert(@ok(terrain::collision_input(&fixture.scene, node.id)));
    assert(@ok(terrain::height_view(&fixture.scene, &fixture.assets, node.id)));
    assert(@catch(terrain::height_range(&fixture.scene, node.id)) == c3d::INVALID_ID);

    node.local.scale = { SCALED_NODE, SCALED_NODE, SCALED_NODE };
    fixture.scene.update_world();
    assert(@catch(terrain::collision_input(&fixture.scene, node.id)) == c3d::UNSUPPORTED);
}
