module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const Vec3 GRID_SHIFT_ORIGIN @local = { 51200, 0, 25600 };
const Vec3 GRID_SHIFT_OFFSET @local = { 25600, 0, 12800 }; // multiples of 256 m keep the origins exact
const float GRID_SHIFT_TOLERANCE @local = 1.0f / 256; // float spacing at 51200 m: the rounding bound of the old origin

struct GridCacheFixture @private {
    GridMap map;
    Vec3 origin;
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

fn void test_shifted_grid_cache_matches_a_fresh_one() @test {
    GridCacheFixture* fixture = grid_cache_fixture(side: 2, mode: DetailMode.BOUNDED, origin: GRID_SHIFT_ORIGIN);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, true);
    drain_grid_cache(fixture);
    uint captured = fixture.captures;

    shift_grid_cache_fixture(fixture, GRID_SHIFT_OFFSET);
    assert(fixture.grid.source_origin() == GRID_SHIFT_ORIGIN - GRID_SHIFT_OFFSET);

    GridUpdateResult idle = fixture.grid.update(&fixture.mesh, 4);
    assert(idle.attempted == 0 && idle.pending == 0);
    assert(fixture.captures == captured);
    compare_fresh_cached_grid(fixture, GRID_SHIFT_TOLERANCE);
}

fn void test_dirty_mark_after_shift_rebuilds_its_tile() @test {
    GridCacheFixture* fixture = grid_cache_fixture(side: 3, mode: DetailMode.BOUNDED, origin: GRID_SHIFT_ORIGIN);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 12, true);
    drain_grid_cache(fixture);
    shift_grid_cache_fixture(fixture, GRID_SHIFT_OFFSET);

    fixture.map.floors[1 + GRID_MAP_SIDE][0].floor_corners = { 0.02f, 0.12f, 0.12f, 0.02f };
    fixture.grid.mark_dirty({ .min_x = 1, .min_z = 1, .max_x = 2, .max_z = 2 }, 2)!!;
    drain_grid_cache(fixture);

    // The edit's border reaches tiles 0, 1, 3 and 4; the other five keep their shifted layers.
    foreach (coordinate, record : fixture.grid.tiles) {
        bool reached = coordinate == 0 || coordinate == 1 || coordinate == 3 || coordinate == 4;
        assert(record.installed_revision == (reached ? 2UL : 1UL));
    }
    compare_fresh_cached_grid(
        edited: fixture,
        tolerance: GRID_SHIFT_TOLERANCE,
        from: { 6.5f, 0.13f, 5.5f },
        to: { 9.5f, 0.19f, 5.5f },
    );
}

fn void test_held_jobs_survive_a_shift() @test {
    GridCacheFixture* fixture = grid_cache_fixture(side: 2, mode: DetailMode.BOUNDED, origin: GRID_SHIFT_ORIGIN);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, true);

    // One tile each: a staged blob, a finished job and a captured job.
    GridCacheJob* staged = fixture.grid.capture_next()!!;
    nav::build_grid_cache_job(staged)!!;
    assert(fixture.grid.commit(staged)!! == GridCommitResult.STAGED);

    GridCacheJob* built = fixture.grid.capture_next()!!;
    nav::build_grid_cache_job(built)!!;
    GridCacheJob* ready = fixture.grid.capture_next()!!;
    assert(ready.state == JobState.READY);

    shift_grid_cache_fixture(fixture, GRID_SHIFT_OFFSET);

    nav::build_grid_cache_job(ready)!!;
    assert(fixture.grid.commit(built)!! == GridCommitResult.STAGED);
    assert(fixture.grid.commit(ready)!! == GridCommitResult.STAGED);
    drain_grid_cache(fixture);
    compare_fresh_cached_grid(fixture, GRID_SHIFT_TOLERANCE);
}

fn void test_shifted_grid_cache_keeps_obstacles_and_cached_layers() @test {
    GridCacheFixture* fixture = grid_cache_fixture(side: 2, mode: DetailMode.BOUNDED, origin: GRID_SHIFT_ORIGIN);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, true);
    drain_grid_cache(fixture);

    Aabb box = {
        .min = fixture.origin + (Vec3){ 1.5f, 0, 1.5f },
        .max = fixture.origin + (Vec3){ 2.5f, 1, 2.5f },
    };
    ObstacleRef obstacle = fixture.grid.cache.add_box_obstacle(box)!!;
    drain_grid_cache(fixture);
    shift_grid_cache_fixture(fixture, GRID_SHIFT_OFFSET);

    // The source rebuild applies the obstacle again at its shifted position.
    fixture.grid.mark_dirty({ .min_x = 1, .min_z = 1, .max_x = 2, .max_z = 2 }, 2)!!;
    drain_grid_cache(fixture);
    Vec3 start = fixture.origin + (Vec3){ 0.75f, 0.015f, 2 };
    Vec3 end = fixture.origin + (Vec3){ 3.25f, 0.065f, 2 };
    assert(grid_cache_ray(fixture, start, end).t < 1);

    // Removal rebuilds the tile from the shifted cached layers.
    fixture.grid.cache.remove_obstacle(obstacle)!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t > 1);
    compare_fresh_cached_grid(fixture, GRID_SHIFT_TOLERANCE);
}

fn GridCacheFixture* grid_cache_fixture(
    uint side,
    DetailMode mode,
    uint slots = 2,
    float whole_radius = 0,
    Vec3 origin = {},
) @private {
    GridCacheFixture* fixture = mem::new(GridCacheFixture);
    fixture.origin = origin;
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
    return {
        .origin = fixture.origin,
        .min_height = 0,
        .max_height = 8,
        .floors = &count_grid_capture,
        .context = fixture,
    };
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

fn void shift_grid_cache_fixture(GridCacheFixture* fixture, Vec3 offset) @local {
    fixture.mesh.shift_origin(offset);
    fixture.query.shift_origin(offset);
    fixture.grid.shift_origin(offset);
    fixture.origin = fixture.grid.source_origin();
}

fn bool near_vertex(Vec3 first, Vec3 second, float tolerance) @local {
    return math::abs(first - second).max() <= tolerance;
}

fn void compare_fresh_cached_grid(
    GridCacheFixture* edited,
    float tolerance = 0,
    Vec3 from = { 2.5f, 0.05f, 1.5f },
    Vec3 to = { 5.5f, 0.11f, 1.5f },
) @local {
    Vec3 origin = edited.grid.source_origin();
    uint side = (uint)edited.grid.desc.tiles.max_x;
    GridCacheFixture* fresh = grid_cache_fixture(side: side, mode: DetailMode.BOUNDED, origin: origin);
    defer destroy_grid_cache_fixture(fresh);
    fresh.map = edited.map;
    drain_grid_cache(fresh);

    for (uint coordinate = 0; coordinate < side * side; coordinate++) {
        assert(edited.grid.tiles[coordinate].layer_count == fresh.grid.tiles[coordinate].layer_count);
        int x = (int)(coordinate % side);
        int z = (int)(coordinate / side);
        for (uint layer = 0; layer < edited.grid.tiles[coordinate].layer_count; layer++) {
            MeshTile* old_tile = edited.mesh.tile_at(x, z, (int)layer);
            MeshTile* new_tile = fresh.mesh.tile_at(x, z, (int)layer);
            assert((old_tile == null) == (new_tile == null));
            if (!old_tile) continue;
            assert(old_tile.header.poly_count == new_tile.header.poly_count && old_tile.verts.len == new_tile.verts.len);
            foreach (index, vertex : old_tile.verts) assert(near_vertex(vertex, new_tile.verts[index], tolerance));
        }
    }

    Vec3 start = origin + from;
    Vec3 end = origin + to;
    assert(math::abs(grid_cache_ray(edited, start, end).t - grid_cache_ray(fresh, start, end).t) <= tolerance);
    PathResult edited_path = cached_grid_path(edited, start, end);
    PathResult fresh_path = cached_grid_path(fresh, start, end);
    assert(edited_path.partial == fresh_path.partial && edited_path.count == fresh_path.count);
}
