module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

fn void check_bounded_flat_height_basis(bool cached, float minimum_height, bool stacked) @local {
    NavBuildConfig config = bounded_scene_config();
    config.cell_height = 0.1f;
    config.detail_max_error = 0;
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc({ .min = { 0, minimum_height, 0 }, .max = { 4, 5, 4 } }, config);
    desc.cache_layers = cached;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 12, 12 }, { 2, 0.05f, 2 });
    if (stacked) add_plane(fixture, { 12, 12 }, { 2, 3.05f, 2 });
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0, "cached %s origin %g: failure %s stage %s",
        cached, minimum_height, fixture.builder.last_failure.reason, fixture.builder.last_failure.stage);

    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    uint floor_count = stacked ? 2 : 1;
    for (uint floor = 0; floor < floor_count; floor++) {
        uint voxel_height = 7001 + floor * 30;
        float captured_relative_height = voxel_height * config.cell_height;
        double expected = (double)minimum_height + captured_relative_height;
        for (uint row = 0; row < 3; row++) {
            for (uint column = 0; column < 3; column++) {
                Vec3 point = { 0.5f + column * 1.5f, (float)expected, 0.5f + row * 1.5f };
                NearestPoly nearest = query.find_nearest_poly(point, { 0.01f, 0.25f, 0.01f }, &filter)!!;
                SurfacePoint sampled = query.poly_surface(nearest.ref, point)!!;
                double error = math::abs((double)sampled.height - expected);
                assert(error <= nav::detail_numerical_allowance(0),
                    "cached %s origin %g floor %d expected %.12f actual %.12f error %.12f",
                    cached, minimum_height, floor, expected, sampled.height, error);
                assert(sampled.height == query.poly_height(nearest.ref, point)!!);
                assert(sampled.height == nearest.point.y);
                assert(sampled.normal.x == 0 && sampled.normal.y == 1 && sampled.normal.z == 0);
            }
        }
    }
    foreach (tile : fixture.mesh.tiles) {
        if (!tile.header) continue;
        assert(tile.header.detail_triangle_count == 0, "flat references keep their implicit polygon fans");
    }

    if (!cached) return;
    ObstacleRef obstacle = fixture.builder.cache.add_box_obstacle({
        .min = { 0.25f, 0.15f, 0.25f },
        .max = { 1.25f, 0.5f, 1.25f },
    })!!;
    assert(fixture.builder.cache.update(&fixture.mesh, 64)!!);
    fixture.builder.cache.remove_obstacle(obstacle)!!;
    assert(fixture.builder.cache.update(&fixture.mesh, 64)!!);
    float captured_relative_height = 7001 * config.cell_height;
    double expected = (double)minimum_height + captured_relative_height;
    NearestPoly restored = query.find_nearest_poly({ 2, (float)expected, 2 }, { 0.01f, 0.25f, 0.01f }, &filter)!!;
    assert(math::abs((double)query.poly_height(restored.ref, restored.point)!! - expected) <= nav::detail_numerical_allowance(0));
}

fn void test_bounded_direct_flat_fan_preserves_captured_height_rounding() @test {
    check_bounded_flat_height_basis(false, -700, false);
    check_bounded_flat_height_basis(false, -700.03125f, true);
}

fn void test_bounded_cached_flat_fan_preserves_captured_height_rounding() @test {
    check_bounded_flat_height_basis(true, -700, false);
    check_bounded_flat_height_basis(true, -700.03125f, true);
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
