module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

struct HeightSampleContext @local {
    GridHeightView* view;
    bool missing;
    bool invalid;
    bool failed;
}

fn void test_grid_height_adapters_match_authored_triangles() @test {
    float[24] samples;
    for (uint z = 0; z < 4; z++) {
        for (uint x = 0; x < 5; x++) samples[x + z * 6] = x * 0.25f + z * 0.5f;
    }
    samples[2 + 2 * 6] += 0.5f;

    GridHeightView heights = {
        .samples = samples[..],
        .width = 5,
        .height = 4,
        .row_stride = 6,
        .origin = { -8, 0, -6 },
        .cell_size = 2,
        .height_scale = 0.5f,
        .height_offset = 1.5f,
        .area = nav::WALKABLE_AREA,
    };
    HeightSampleContext context = { .view = &heights };
    GridHeightSampler sampler = {
        .origin = heights.origin,
        .cell_size = heights.cell_size,
        .sample = &height_test_sample,
        .context = &context,
        .area = nav::WALKABLE_AREA,
    };

    foreach (diagonal : GridDiagonal::values) {
        heights.diagonal = diagonal;
        sampler.diagonal = diagonal;

        GridMap* authored = mem::new(GridMap);
        defer free(authored);
        for (int z = 0; z < 3; z++) {
            for (int x = 0; x < 4; x++) {
                float base = 1.5f + x * 0.125f + z * 0.25f;
                GridFloor floor = {
                    .ceiling = float::max,
                    .area = nav::WALKABLE_AREA,
                    .floor_kind = GridSurfaceKind.CORNERS,
                    .floor_corners = { base, base + 0.125f, base + 0.375f, base + 0.25f },
                    .diagonal = diagonal,
                };
                if (x == 2 && z == 2) floor.floor_corners[0] += 0.25f;
                if (x == 1 && z == 2) floor.floor_corners[1] += 0.25f;
                if (x == 1 && z == 1) floor.floor_corners[2] += 0.25f;
                if (x == 2 && z == 1) floor.floor_corners[3] += 0.25f;
                lay_floor(authored, { x, z, x + 1, z + 1 }, floor);
            }
        }

        GridSourceDesc explicit_source = grid_map_source(authored);
        explicit_source.origin = heights.origin;
        GridSourceDesc[3] sources = {
            nav::grid_height_source(&heights, 0, 8)!!,
            nav::grid_sampled_source(&sampler, 0, 8)!!,
            explicit_source,
        };

        foreach (source : sources) {
            GridFixture* fixture = height_source_fixture(source);
            defer destroy_grid_fixture(fixture);
            install_grid_tile(fixture, 0, 0);

            for (uint triangle = 0; triangle < 2; triangle++) {
                bool main_diagonal = diagonal == GridDiagonal.MIN_MIN_TO_MAX_MAX;
                Vec2 local = main_diagonal
                    ? (triangle == 0 ? (Vec2){ 0.75f, 0.25f } : (Vec2){ 0.25f, 0.75f })
                    : (triangle == 0 ? (Vec2){ 0.25f, 0.25f } : (Vec2){ 0.75f, 0.75f });
                float expected = main_diagonal
                    ? (triangle == 0 ? 2.09375f : 2.15625f)
                    : (triangle == 0 ? 1.96875f : 2.28125f);
                float gradient_x = triangle == 0 ? 0.0625f : 0.1875f;
                float gradient_z = main_diagonal
                    ? (triangle == 0 ? 0.25f : 0.125f)
                    : (triangle == 0 ? 0.125f : 0.25f);
                Vec3 point = { -6 + local.x * 2, expected, -4 + local.y * 2 };

                NearestPoly nearest = fixture.query.find_nearest_poly(point, { 0.001f, 1, 0.001f }, &fixture.filter)!!;
                SurfacePoint surface = fixture.query.poly_surface(nearest.ref, point)!!;
                Vec3 normal = ((Vec3){ -gradient_x, 1, -gradient_z }).normalize();
                assert(math::abs(surface.height - expected) < 0.00001f);
                assert((surface.normal - normal).length() < 0.00001f);
            }
        }
    }
}

fn void test_grid_height_capture_preserves_absence_and_source_faults() @test {
    float[4] samples = { 0, 0.25f, 0.5f, 0.75f };
    GridHeightView heights = {
        .samples = samples[..],
        .width = 2,
        .height = 2,
        .row_stride = 2,
        .cell_size = 2,
        .height_scale = 1,
        .area = nav::WALKABLE_AREA,
    };
    HeightSampleContext context = { .view = &heights, .missing = true };
    GridHeightSampler sampler = {
        .cell_size = heights.cell_size,
        .sample = &height_test_sample,
        .context = &context,
        .area = nav::WALKABLE_AREA,
    };

    GridSourceDesc source = nav::grid_sampled_source(&sampler, 0, 8)!!;
    GridFixture* fixture = height_source_fixture(source);
    defer destroy_grid_fixture(fixture);
    assert(fixture.builder.build(0, 0)!!.len == 0);

    context.missing = false;
    context.invalid = true;
    assert(@catch(fixture.builder.build(0, 0)) == c3d::INVALID_ARGUMENT);
    context.invalid = false;
    context.failed = true;
    assert(@catch(fixture.builder.build(0, 0)) == c3d::CAPACITY_EXCEEDED);

    source = nav::grid_height_source(&heights, 0, 8)!!;
    fixture.builder.source = source;
    samples[3] = bitcast(0x7fc00000u, float);
    assert(@catch(fixture.builder.build(0, 0)) == c3d::INVALID_ARGUMENT);
}

fn void test_grid_dirty_and_world_ranges() @test {
    GridRange extent = { .min_x = -2, .min_z = -2, .max_x = 3, .max_z = 3 };
    assert_grid_range(
        nav::grid_dirty_tiles({ .min_x = 7, .min_z = 7, .max_x = 9, .max_z = 9 }, 8, 1, extent)!!,
        { .max_x = 2, .max_z = 2 },
    );
    assert_grid_range(
        nav::grid_dirty_tiles({ .min_x = -9, .min_z = -1, .max_x = -8, .max_z = 0 }, 8, 1, extent)!!,
        { .min_x = -2, .min_z = -1, .max_x = 0, .max_z = 1 },
    );
    assert_grid_range(
        nav::grid_dirty_tiles({ .min_x = 40, .min_z = 40, .max_x = 41, .max_z = 41 }, 8, 1, extent)!!,
        {},
    );

    assert_grid_range(
        nav::grid_vertex_cells({ .min_x = 8, .min_z = 8, .max_x = 9, .max_z = 9 })!!,
        { .min_x = 7, .min_z = 7, .max_x = 9, .max_z = 9 },
    );
    assert(@catch(nav::grid_vertex_cells({ .min_x = 1 })) == c3d::INVALID_ARGUMENT);

    Vec3 origin = { -10, 0, -6 };
    assert_grid_range(
        nav::grid_world_cells({ .min = { -10, 0, -6 }, .max = { -6, 0, -2 } }, origin, 2)!!,
        { .min_x = -1, .min_z = -1, .max_x = 3, .max_z = 3 },
    );
    assert(@catch(nav::grid_world_cells({ .min = { 1, 0, 0 } }, {}, 1)) == c3d::INVALID_ARGUMENT);
}

fn GridFixture* height_source_fixture(GridSourceDesc source) @local {
    GridFixture* fixture = mem::new(GridFixture);
    NavBuildConfig config = nav::default_grid_build_config(2);
    config.tile_size = 4;
    config.agent_height = 0.5f;
    config.agent_radius = 0;
    config.agent_max_climb = 1;
    config.agent_max_slope_degrees = 60;
    config.region_merge_size = 0;
    config.detail_mode = DetailMode.BOUNDED;
    config.detail_max_error = 0;

    fixture.builder = nav::create_grid_tile_builder(
        allocator: mem,
        config: config,
        source: source,
        scratch_bytes: 8 * 1024 * 1024,
    )!!;
    fixture.mesh = nav::create_nav_mesh(mem, fixture.builder.mesh_desc(4))!!;
    fixture.query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    fixture.filter = nav::default_query_filter();
    return fixture;
}

fn GridHeightSample? height_test_sample(void* context, float world_x, float world_z) @local {
    HeightSampleContext* state = context;
    GridHeightView* view = state.view;
    if (state.failed) return c3d::CAPACITY_EXCEEDED~;

    int x = (int)((world_x - view.origin.x) / view.cell_size);
    int z = (int)((world_z - view.origin.z) / view.cell_size);
    if (x < 0 || z < 0 || (uint)x >= view.width || (uint)z >= view.height) return {};
    if (state.missing && x == 1 && z == 1) return {};
    if (state.invalid) return { .height = bitcast(0x7fc00000u, float), .present = true };

    return {
        .height = view.samples[(usz)x + (usz)z * view.row_stride] * view.height_scale + view.height_offset,
        .present = true,
    };
}

fn void assert_grid_range(GridRange actual, GridRange expected) @local {
    assert(actual.min_x == expected.min_x && actual.min_z == expected.min_z
        && actual.max_x == expected.max_x && actual.max_z == expected.max_z,
        "range (%d, %d)..(%d, %d), expected (%d, %d)..(%d, %d)",
        actual.min_x, actual.min_z, actual.max_x, actual.max_z,
        expected.min_x, expected.min_z, expected.max_x, expected.max_z);
}
