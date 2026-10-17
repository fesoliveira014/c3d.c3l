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
    obstacle = fixture.grid.cache.add_box_obstacle({ .min = { 1.5f, 0, 0.5f }, .max = { 2.5f, 1, 1.25f } })!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t > 1);
    assert(grid_cache_ray(fixture, { 0.75f, 0.015f, 0.875f }, { 3.25f, 0.065f, 0.875f }).t < 1);

    fixture.grid.cache.remove_obstacle(obstacle)!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, start, end).t > 1);
    assert(fixture.captures == captured);
}

fn void test_grid_cache_flat_whole_cell_obstacles() @test {
    GridCacheFixture* fixture = grid_cache_fixture(1, DetailMode.COARSE);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 4, false);
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, { 0.5f, 0, 2 }, { 3.5f, 0, 2 }).t > 1);

    ObstacleRef obstacle = fixture.grid.cache.add_box_obstacle({ .min = { 1.25f, 0.25f, 1.25f }, .max = { 2.75f, 0.75f, 2.75f } })!!;
    GridUpdateResult added = fixture.grid.update(&fixture.mesh, 1);
    assert(added.rebuilt == 1 && added.pending == 0 && added.failed == 0);
    assert(fixture.grid.cache.obstacle_by_ref(obstacle)!!.touched_count == 1);
    float blocked = grid_cache_ray(fixture, { 0.5f, 0, 2 }, { 3.5f, 0, 2 }).t;
    assert(blocked < 1);

    fixture.grid.mark_dirty({ .max_x = 4, .max_z = 4 }, 2)!!;
    drain_grid_cache(fixture);
    assert(grid_cache_ray(fixture, { 0.5f, 0, 2 }, { 3.5f, 0, 2 }).t == blocked);

    fixture.grid.cache.remove_obstacle(obstacle)!!;
    GridUpdateResult removed = fixture.grid.update(&fixture.mesh, 1);
    assert(removed.rebuilt == 1 && removed.pending == 0 && removed.failed == 0);
    assert(grid_cache_ray(fixture, { 0.5f, 0, 2 }, { 3.5f, 0, 2 }).t > 1);

    GridCacheFixture* border = grid_cache_fixture(
        side: 2,
        mode: DetailMode.COARSE,
        slots: 2,
        whole_radius: 1,
    );
    defer destroy_grid_cache_fixture(border);
    fill_cached_grid(border, 8, false);
    drain_grid_cache(border);
    Vec3 start = { 4.5f, 0, 1.5f };
    Vec3 end = { 4.5f, 0, 3.5f };
    assert(grid_cache_ray(border, start, end).t > 1);

    obstacle = border.grid.cache.add_box_obstacle({ .min = { 3.25f, 0.25f, 2.25f }, .max = { 3.75f, 0.75f, 2.75f } })!!;
    added = border.grid.update(&border.mesh, 1);
    assert(added.rebuilt == 1 && added.pending > 0 && added.failed == 0);
    drain_grid_cache(border);
    assert(border.grid.cache.obstacle_by_ref(obstacle)!!.touched_count == 4);
    blocked = grid_cache_ray(border, start, end).t;
    assert(blocked < 1);

    border.grid.mark_dirty({ .min_x = 4, .min_z = 2, .max_x = 5, .max_z = 3 }, 2)!!;
    drain_grid_cache(border);
    assert(grid_cache_ray(border, start, end).t == blocked);

    border.grid.cache.remove_obstacle(obstacle)!!;
    drain_grid_cache(border);
    assert(grid_cache_ray(border, start, end).t > 1);
}

fn void test_grid_cache_rejects_superseded_detached_capture() @test {
    GridCacheFixture* fixture = grid_cache_fixture(1, DetailMode.BOUNDED);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 4, false);

    GridCacheJob* old = fixture.grid.capture_next()!!;
    assert(old.state == JobState.READY);

    fixture.map.floors[1 + GRID_MAP_SIDE][0].height = 0.25f;
    fixture.grid.mark_dirty({ .min_x = 1, .min_z = 1, .max_x = 2, .max_z = 2 }, 2)!!;
    GridCacheJob* current = fixture.grid.capture_next()!!;
    nav::build_grid_cache_job(current)!!;
    assert(fixture.grid.commit(current)!! == GridCommitResult.STAGED);
    assert(fixture.grid.update(&fixture.mesh, 1).installed == 1);

    TileRef installed = fixture.mesh.tile_ref(fixture.mesh.tile_at(0, 0, 0));
    uint captured = fixture.captures;
    nav::build_grid_cache_job(old)!!;
    assert(fixture.captures == captured);
    assert(fixture.grid.commit(old)!! == GridCommitResult.STALE);
    assert(fixture.mesh.tile_by_ref(installed)!!.header.layer == 0);
    assert(fixture.grid.tiles[0].installed_revision == 2);

    fixture.grid.mark_dirty({ .max_x = 1, .max_z = 1 }, 3)!!;
    old = fixture.grid.capture_next()!!;
    fixture.grid.set_source(source: grid_cache_fixture_source(fixture), identity: (GridSourceId)2, revision: 1)!!;
    nav::build_grid_cache_job(old)!!;
    assert(fixture.grid.commit(old)!! == GridCommitResult.STALE);
    assert(fixture.mesh.tile_by_ref(installed)!!.header.layer == 0);

    drain_grid_cache(fixture);
    assert(fixture.grid.tiles[0].installed_source == (GridSourceId)2);
}

fn void test_grid_cache_budget_preserves_queued_requests() @test {
    GridCacheFixture* fixture = grid_cache_fixture(2, DetailMode.BOUNDED, 1);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 8, false);

    GridCacheJob* held = fixture.grid.capture_next()!!;
    assert(@catch(fixture.grid.capture_next()) == nav::NO_FREE_SLOT);
    GridUpdateResult zero = fixture.grid.update(&fixture.mesh, 0);
    assert(zero.attempted == 0 && !fixture.mesh.tile_at(0, 0, 0));

    nav::build_grid_cache_job(held)!!;
    fixture.grid.commit(held)!!;
    GridUpdateResult one = fixture.grid.update(&fixture.mesh, 1);
    assert(one.attempted == 1 && one.installed == 1 && one.pending == 3);
    drain_grid_cache(fixture);

    for (uint index = 0; index < nav::MAX_OBSTACLE_REQUESTS; index++) {
        fixture.grid.cache.add_obstacle(base: { 1, 0, 1 }, radius: 0.1f, height: 1)!!;
    }
    assert(@catch(fixture.grid.cache.add_obstacle(base: { 1, 0, 1 }, radius: 0.1f, height: 1)) == c3d::CAPACITY_EXCEEDED);
    drain_grid_cache(fixture);
    assert(fixture.grid.cache.request_count == 0 && fixture.grid.cache.update_count == 0);
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

    GridUpdateResult first = fixture.grid.update(&fixture.mesh, 1);
    assert(first.installed == 1 && first.pending == 3);
    assert(fixture.grid.tiles[0].installed_revision == 2 && fixture.grid.tiles[1].installed_revision == 1);
    drain_grid_cache(fixture);
    compare_fresh_cached_grid(fixture);

    lay_floor(&fixture.map, { 4, 4, 5, 5 }, open_floor(0.08f));
    lay_floor(&fixture.map, { 4, 4, 5, 5 }, open_floor(3));
    GridRange cells = nav::grid_vertex_cells({ .min_x = 4, .min_z = 4, .max_x = 5, .max_z = 5 })!!;
    for (int z = 3; z <= 4; z++) {
        for (int x = 3; x <= 4; x++) {
            GridFloor* floor = &fixture.map.floors[x + z * GRID_MAP_SIDE][0];
            if (floor.floor_kind == GridSurfaceKind.FLAT) {
                floor.floor_kind = GridSurfaceKind.CORNERS;
                floor.floor_corners = { floor.height, floor.height, floor.height, floor.height };
            }
            uint corner = z == 3 ? (x == 3 ? 2 : 3) : (x == 3 ? 1 : 0);
            floor.floor_corners[corner] = 0.18f;
        }
    }

    fixture.grid.mark_dirty(cells, 3)!!;
    drain_grid_cache(fixture);
    assert(fixture.grid.tiles[3].layer_count == 2);
    compare_fresh_cached_grid(fixture);
}

fn void test_grid_cache_failed_layer_shrink_is_retryable() @test {
    GridCacheFixture* fixture = grid_cache_fixture(1, DetailMode.BOUNDED);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 4, true);
    drain_grid_cache(fixture);

    CachedLayerRef[2] old_cache = { fixture.grid.tiles[0].layers[0], fixture.grid.tiles[0].layers[1] };
    TileRef[2] old_runtime = {
        fixture.mesh.tile_ref(fixture.mesh.tile_at(0, 0, 0)),
        fixture.mesh.tile_ref(fixture.mesh.tile_at(0, 0, 1)),
    };
    uint links = fixture.mesh.free_links();

    for (uint z = 0; z < 4; z++) {
        for (uint x = 0; x < 4; x++) fixture.map.counts[x + z * GRID_MAP_SIDE] = 1;
    }
    fixture.map.floors[1 + GRID_MAP_SIDE][0].floor_corners = { 0.02f, 0.14f, 0.14f, 0.02f };
    fixture.grid.mark_dirty({ .max_x = 4, .max_z = 4 }, 2)!!;
    GridCacheJob* job = fixture.grid.capture_next()!!;
    nav::build_grid_cache_job(job)!!;
    fixture.grid.commit(job)!!;
    uint captures = fixture.captures;

    Allocator original = fixture.mesh.allocator;
    CacheAllocationProbe probe = { .backing = original };
    fixture.mesh.allocator = &probe;
    GridUpdateResult failed = fixture.grid.update(&fixture.mesh, 1);
    fixture.mesh.allocator = original;

    assert(failed.failed == 1 && fixture.grid.last_failure.reason == c3d::CAPACITY_EXCEEDED);
    assert(fixture.grid.tiles[0].installed_revision == 1 && fixture.grid.tiles[0].layer_count == 2);
    assert(fixture.mesh.free_links() == links);
    for (uint layer = 0; layer < 2; layer++) {
        assert(fixture.grid.cache.tile_by_ref(old_cache[layer])!!.header.tile_layer == (int)layer);
        assert(fixture.mesh.tile_by_ref(old_runtime[layer])!!.header.layer == (int)layer);
    }
    assert(cached_grid_nearest(fixture, { 2, 3, 2 }).ref != (PolyRef)0);

    GridUpdateResult retried = fixture.grid.update(&fixture.mesh, 1);
    assert(retried.installed == 1 && retried.pending == 0);
    assert(fixture.grid.tiles[0].layer_count == 1 && fixture.grid.tiles[0].installed_revision == 2);
    assert(!fixture.mesh.tile_at(0, 0, 1) && fixture.captures == captures);
}

fn void test_grid_cache_obstacle_footprint_keeps_existing_capacity() @test {
    GridCacheFixture* fixture = grid_cache_fixture(3, DetailMode.BOUNDED);
    defer destroy_grid_cache_fixture(fixture);
    fill_cached_grid(fixture, 12, false);
    drain_grid_cache(fixture);

    assert(@catch(fixture.grid.cache.add_box_obstacle({ .min = { 0, -1, 0 }, .max = { 12, 1, 12 } })) == c3d::CAPACITY_EXCEEDED);
    assert(fixture.grid.cache.request_count == 0);
    assert(grid_cache_ray(fixture, { 0.75f, 0, 2 }, { 11.25f, 0, 2 }).t > 1);
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

    Vec3[4] points = { { 1.5f, 0.03f, 1.5f }, { 4.5f, 0.09f, 1.5f }, { 1.5f, 3, 4.5f }, { 6.5f, 3, 2.5f } };
    foreach (point : points) {
        NearestPoly first = cached_grid_nearest(edited, point);
        NearestPoly second = cached_grid_nearest(fresh, point);
        SurfacePoint left = edited.query.poly_surface(first.ref, point)!!;
        SurfacePoint right = fresh.query.poly_surface(second.ref, point)!!;
        assert(math::abs(left.height - right.height) < 0.00001f);
        assert(left.normal == right.normal);
    }

    Vec3 start = { 2.5f, 0.05f, 1.5f };
    Vec3 end = { 5.5f, 0.11f, 1.5f };
    assert(grid_cache_ray(edited, start, end).t == grid_cache_ray(fresh, start, end).t);
    assert(grid_cache_ray(edited, end, start).t == grid_cache_ray(fresh, end, start).t);
    assert(cached_grid_path(edited, start, end).partial == cached_grid_path(fresh, start, end).partial);
}
