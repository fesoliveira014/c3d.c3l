module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

struct GridCacheFixture @private {
    GridMap map;
    GridCache grid;
    NavMesh mesh;
    NavQuery query;
    QueryFilter filter;
    uint captures;
    PolyRef[128] path;
}

fn void test_grid_cache_retains_authored_obstacle_layers() @test {
    GridCacheFixture* fixture = grid_cache_fixture(1, DetailMode.BOUNDED);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 4, true);
    drain_grid_cache(fixture);

    assert(fixture.grid.tiles[0].layer_count == 2);
    uint captured = fixture.captures;
    Vec3 start = { 0.75f, 0.015f, 2 };
    Vec3 end = { 3.25f, 0.065f, 2 };
    assert(grid_cache_ray(fixture, start, end).t > 1);
    NearestPoly upper = cached_grid_nearest(fixture, { 2, 3, 2 });
    assert(math::abs(fixture.query.poly_height(upper.ref, upper.point)!! - 3) < 0.00001f);

    ObstacleRef obstacle = fixture.grid.cache.add_box_obstacle({ .min = { 1.5f, 0, 1.5f }, .max = { 2.5f, 1, 2.5f } })!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t < 1);
    upper = cached_grid_nearest(fixture, { 2, 3, 2 });
    assert(math::abs(fixture.query.poly_height(upper.ref, upper.point)!! - 3) < 0.00001f);
    PathResult detour = cached_grid_path(fixture, start, end);
    assert(!detour.partial && detour.count > 1);

    fixture.grid.cache.remove_obstacle(obstacle)!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t > 1);
    assert(fixture.captures == captured);
}

fn void test_grid_cache_flat_whole_cell_obstacles() @test {
    GridCacheFixture* fixture = grid_cache_fixture(
        side: 2,
        mode: DetailMode.COARSE,
        slots: 2,
        whole_radius: 1,
    );
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, false);
    drain_grid_cache(fixture);

    Vec3 start = { 4.5f, 0, 1.5f };
    Vec3 end = { 4.5f, 0, 3.5f };
    assert(grid_cache_ray(fixture, start, end).t > 1);

    ObstacleRef obstacle = fixture.grid.cache.add_box_obstacle({ .min = { 3.25f, 0.25f, 2.25f }, .max = { 3.75f, 0.75f, 2.75f } })!!;
    GridUpdateResult added = fixture.grid.update(&fixture.mesh, 1);
    assert(added.rebuilt == 1 && added.pending > 0 && added.failed == 0);
    drain_grid_cache(fixture);
    assert(fixture.grid.cache.obstacle_by_ref(obstacle)!!.touched_count == 4);
    float blocked = grid_cache_ray(fixture, start, end).t;
    assert(blocked < 1);

    fixture.grid.mark_dirty({ .min_x = 4, .min_z = 2, .max_x = 5, .max_z = 3 }, 2)!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t == blocked);

    fixture.grid.cache.remove_obstacle(obstacle)!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t > 1);
}

fn void test_grid_cache_detached_jobs_and_budgets() @test {
    GridCacheFixture* fixture = grid_cache_fixture(2, DetailMode.BOUNDED, 1);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, false);

    GridCacheJob* old = fixture.grid.capture_next()!!;
    assert(old.state == JobState.READY);
    assert(@catch(fixture.grid.capture_next()) == nav::NO_FREE_SLOT);
    assert(fixture.grid.update(&fixture.mesh, 0).attempted == 0);

    fixture.map.floors[1 + GRID_MAP_SIDE][0].height = 0.25f;
    fixture.grid.mark_dirty({ .min_x = 1, .min_z = 1, .max_x = 2, .max_z = 2 }, 2)!!;
    nav::build_grid_cache_job(old)!!;
    assert(fixture.grid.commit(old)!! == GridCommitResult.STALE);

    GridCacheJob* current = fixture.grid.capture_next()!!;
    nav::build_grid_cache_job(current)!!;
    assert(fixture.grid.commit(current)!! == GridCommitResult.STAGED);
    GridUpdateResult one = fixture.grid.update(&fixture.mesh, 1);
    assert(one.attempted == 1 && one.installed == 1 && one.pending == 3);
    assert(fixture.grid.tiles[0].installed_revision == 2);

    old = fixture.grid.capture_next()!!;
    fixture.grid.set_source(source: grid_cache_fixture_source(fixture), identity: (GridSourceId)2, revision: 1)!!;
    nav::build_grid_cache_job(old)!!;
    assert(fixture.grid.commit(old)!! == GridCommitResult.STALE);

    drain_grid_cache(fixture);
    assert(fixture.grid.tiles[0].installed_source == (GridSourceId)2);
}

fn void test_grid_cache_boundary_edits_match_fresh_layers() @test {
    GridCacheFixture* fixture = grid_cache_fixture(2, DetailMode.BOUNDED);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, true);
    clear_cells(&fixture.map, { 4, 4, 8, 8 });
    drain_grid_cache(fixture);
    assert(fixture.grid.tiles[3].layer_count == 0);

    GridFloor* border = &fixture.map.floors[3 + GRID_MAP_SIDE][0];
    border.floor_corners = { 0.06f, 0.16f, 0.16f, 0.06f };
    fixture.grid.mark_dirty({ .min_x = 3, .min_z = 1, .max_x = 4, .max_z = 2 }, 2)!!;
    foreach (record : fixture.grid.tiles) assert(record.dirty);

    drain_grid_cache(fixture);
    compare_fresh_cached_grid(fixture);
}

fn GridCacheFixture* grid_cache_fixture(
    uint side,
    DetailMode mode,
    uint slots = 2,
    float whole_radius = 0,
) @private {
    GridCacheFixture* fixture = mem::new(GridCacheFixture);
    NavBuildConfig config = nav::default_grid_build_config(1);
    config.tile_size = 4;
    config.agent_radius = mode == DetailMode.BOUNDED ? 0.2f : whole_radius;
    config.agent_height = 1;
    config.agent_max_climb = 0.75f;
    config.agent_max_slope_degrees = 60;
    config.detail_mode = mode;
    config.detail_max_error = 0;
    config.clearance_mode = mode == DetailMode.BOUNDED ? ClearanceMode.SUB_CELL : ClearanceMode.WHOLE_CELL;
    config.clearance_max_error = 0.5f;

    GridCacheDesc desc = nav::default_grid_cache_desc({ .max_x = (int)side, .max_z = (int)side }, config);
    desc.build_slots = slots;
    desc.slot_scratch_bytes = 8 * 1024 * 1024;
    desc.cache_scratch_bytes = 8 * 1024 * 1024;
    fixture.grid = nav::create_grid_cache(
        allocator: mem,
        desc: desc,
        source: grid_cache_fixture_source(fixture),
        identity: (GridSourceId)1,
        revision: 1,
    )!!;
    fixture.mesh = nav::create_nav_mesh(mem, fixture.grid.mesh_desc())!!;
    fixture.query = nav::create_nav_query(mem, &fixture.mesh, 1024)!!;
    fixture.filter = nav::default_query_filter();
    return fixture;
}

fn void destroy_grid_cache_fixture(GridCacheFixture* fixture) @private {
    nav::destroy_nav_query(&fixture.query);
    nav::destroy_nav_mesh(&fixture.mesh);
    nav::destroy_grid_cache(&fixture.grid);
    free(fixture);
}

fn GridSourceDesc grid_cache_fixture_source(GridCacheFixture* fixture) @local {
    return { .min_height = 0, .max_height = 8, .floors = &count_grid_capture, .context = fixture };
}

fn usz count_grid_capture(
    void* context,
    int x,
    int z,
    GridFloor[] output,
) @local {
    GridCacheFixture* fixture = context;
    fixture.captures++;
    return grid_map_floors(
        context: &fixture.map,
        cell_x: x,
        cell_z: z,
        out_floors: output,
    );
}

fn void fill_cached_grid(GridCacheFixture* fixture, int side, bool layers) @private {
    lay_floor(&fixture.map, { 0, 0, side, side }, open_floor(0));
    if (!layers) return;

    lay_floor(&fixture.map, { 0, 0, side, side }, open_floor(3));
    for (int z = 0; z < side; z++) {
        for (int x = 0; x < side; x++) {
            GridFloor* floor = &fixture.map.floors[x + z * GRID_MAP_SIDE][0];
            floor.floor_kind = GridSurfaceKind.CORNERS;
            floor.ceiling_kind = GridSurfaceKind.CORNERS;
            float first = x * 0.02f;
            float last = (float)(x + 1) * 0.02f;
            floor.floor_corners = { first, last, last, first };
            floor.ceiling_corners = { 2.5f + first, 2.5f + last, 2.5f + last, 2.5f + first };
        }
    }
}

fn void drain_grid_cache(GridCacheFixture* fixture) @private {
    uint pending;
    for (uint step = 0; step < 128; step++) {
        GridUpdateResult result = fixture.grid.update(&fixture.mesh, 1);
        assert(result.failed == 0, "%s", fixture.grid.last_failure.reason);
        assert(result.attempted <= 1);
        pending = result.pending;
        if (!result.pending) return;
    }
    assert(pending == 0, "Grid cache did not drain.");
}

fn NearestPoly cached_grid_nearest(GridCacheFixture* fixture, Vec3 point) @local {
    return fixture.query.find_nearest_poly(point, { 0.1f, 0.25f, 0.1f }, &fixture.filter)!!;
}

fn RaycastHit grid_cache_ray(GridCacheFixture* fixture, Vec3 start, Vec3 end) @local {
    return fixture.query.raycast(
        start_ref: cached_grid_nearest(fixture, start).ref,
        start: start,
        end: end,
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
}

fn PathResult cached_grid_path(GridCacheFixture* fixture, Vec3 start, Vec3 end) @local {
    return fixture.query.find_path(
        start_ref: cached_grid_nearest(fixture, start).ref,
        end_ref: cached_grid_nearest(fixture, end).ref,
        start: start,
        end: end,
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
}

fn void compare_fresh_cached_grid(GridCacheFixture* edited) @local {
    GridCacheFixture* fresh = grid_cache_fixture(2, DetailMode.BOUNDED);
    defer destroy_grid_cache_fixture(fresh);
    fresh.map = edited.map;
    drain_grid_cache(fresh);

    for (uint coordinate = 0; coordinate < 4; coordinate++) {
        assert(edited.grid.tiles[coordinate].layer_count == fresh.grid.tiles[coordinate].layer_count);
        int x = (int)(coordinate % 2);
        int z = (int)(coordinate / 2);
        for (uint layer = 0; layer < edited.grid.tiles[coordinate].layer_count; layer++) {
            MeshTile* old_tile = edited.mesh.tile_at(x, z, (int)layer);
            MeshTile* new_tile = fresh.mesh.tile_at(x, z, (int)layer);
            assert((old_tile == null) == (new_tile == null));
            if (!old_tile) continue;
            assert(old_tile.header.poly_count == new_tile.header.poly_count && old_tile.verts.len == new_tile.verts.len);
            foreach (index, vertex : old_tile.verts) assert(vertex == new_tile.verts[index]);
        }
    }

    Vec3 start = { 2.5f, 0.05f, 1.5f };
    Vec3 end = { 5.5f, 0.11f, 1.5f };
    assert(grid_cache_ray(edited, start, end).t == grid_cache_ray(fresh, start, end).t);
    assert(cached_grid_path(edited, start, end).partial == cached_grid_path(fresh, start, end).partial);
}
