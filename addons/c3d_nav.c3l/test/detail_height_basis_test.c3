module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

fn NavBuildConfig bounded_scene_config() @private {
    NavBuildConfig config = nav::default_nav_build_config();
    config.cell_size = 0.5f;
    config.cell_height = 0.05f;
    config.tile_size = 8;
    config.agent_height = 1;
    config.agent_radius = 0;
    config.agent_max_climb = 0.3f;
    config.agent_max_slope_degrees = 60;
    config.region_min_size = 0;
    config.region_merge_size = 0;
    config.detail_mode = DetailMode.BOUNDED;
    config.detail_max_error = 0.01f;
    return config;
}

fn void check_bounded_flat_height_basis(bool cached) @local {
    NavBuildConfig config = bounded_scene_config();
    config.cell_height = 0.1f;
    config.detail_max_error = 0;
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc({ .min = { 0, -700, 0 }, .max = { 4, 2, 4 } }, config);
    desc.cache_layers = cached;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 12, 12 }, { 2, 0.05f, 2 });
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0);

    float captured_relative_height = 7001 * config.cell_height;
    double expected = -700.0 + captured_relative_height;
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly nearest = query.find_nearest_poly({ 2, (float)expected, 2 }, { 0.01f, 0.25f, 0.01f }, &filter)!!;
    SurfacePoint sampled = query.poly_surface(nearest.ref, nearest.point)!!;
    assert(math::abs((double)sampled.height - expected) <= nav::detail_numerical_allowance(0));
    assert(sampled.height == query.poly_height(nearest.ref, nearest.point)!!);
    assert(sampled.normal.x == 0 && sampled.normal.y == 1 && sampled.normal.z == 0);
    foreach (tile : fixture.mesh.tiles) {
        if (tile.header) assert(tile.header.detail_triangle_count == 0);
    }
}

fn void test_bounded_direct_flat_fan_preserves_captured_height_rounding() @test {
    check_bounded_flat_height_basis(false);
}

fn void test_bounded_cached_flat_fan_preserves_captured_height_rounding() @test {
    check_bounded_flat_height_basis(true);
}

fn void test_bounded_cached_step_certifies_final_stored_fan_heights() @test {
    NavBuildConfig config = bounded_scene_config();
    config.cell_height = 0.1f;
    config.detail_max_error = 0;
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc({ .min = { 0, -700, 0 }, .max = { 4, 2, 4 } }, config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 12, 12 }, { 2, 0.05f, 2 });
    add_plane(fixture, { 6, 12 }, { 5, 0.15f, 2 });
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0, "failure %s stage %s", fixture.builder.last_failure.reason, fixture.builder.last_failure.stage);
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    for (uint side = 0; side < 2; side++) {
        float captured_relative_height = (float)(7001 + side) * config.cell_height;
        double expected = -700.0 + captured_relative_height;
        Vec3 point = { 0.5f + side * 3.0f, (float)expected, 2 };
        NearestPoly nearest = query.find_nearest_poly(point, { 0.01f, 0.25f, 0.01f }, &filter)!!;
        SurfacePoint surface = query.poly_surface(nearest.ref, point)!!;
        assert(math::abs((double)surface.height - expected) <= nav::detail_numerical_allowance(0),
            "side %d expected %.12f actual %.12f", side, expected, surface.height);
        if (side == 1) {
            TileAndPoly found = fixture.mesh.tile_and_poly(nearest.ref)!!;
            uint index = (uint)(found.poly - found.tile.polys.ptr);
            assert(found.tile.details[index].triangle_count > 0, "the cached coarse fan cannot represent the retained height within its allowance");
        }
    }
}
