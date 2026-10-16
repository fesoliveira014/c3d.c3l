module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;
import c3d::scene;

fn GridFixture* clearance_grid_fixture(NavBuildConfig config, Vec3 origin = {}) @local {
    GridFixture* fixture = mem::new(GridFixture);
    GridSourceDesc source = grid_map_source(&fixture.map);
    source.origin = origin;
    fixture.builder = nav::create_grid_tile_builder(
        allocator: mem,
        config: config,
        source: source,
        scratch_bytes: 8 * 1024 * 1024,
    )!!;
    fixture.mesh = nav::create_nav_mesh(mem, fixture.builder.mesh_desc(4))!!;
    fixture.query = nav::create_nav_query(mem, &fixture.mesh, 1024)!!;
    fixture.filter = nav::default_query_filter();
    return fixture;
}

fn NavBuildConfig clearance_grid_config() @local {
    NavBuildConfig config = nav::default_grid_build_config(1);
    config.tile_size = 4;
    config.agent_radius = 0.2f;
    config.agent_height = 1;
    config.agent_max_climb = 0.75f;
    config.agent_max_slope_degrees = 60;
    config.detail_mode = DetailMode.BOUNDED;
    config.detail_max_error = 0;
    config.clearance_mode = ClearanceMode.SUB_CELL;
    config.clearance_max_error = 0.5f;
    return config;
}

fn void test_clearance_authored_diagonal_and_layer_validation() @test {
    NavBuildConfig config = clearance_grid_config();
    config.cell_size = 0.1f;
    config.cell_height = 0.025f;
    config.agent_radius = 0;
    config.agent_height = 0.15f;
    config.clearance_max_error = 0.1f;
    GridFixture* fixture = clearance_grid_fixture(config, { 0, 0, 100000 });
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 4, 4 }, open_floor(0));
    GridFloor* floor = &fixture.map.floors[1 + GRID_MAP_SIDE][0];
    floor.floor_kind = GridSurfaceKind.CORNERS;
    floor.floor_corners = { 0, 0, 0.1f, 0 };
    floor.diagonal = GridDiagonal.MIN_MIN_TO_MAX_MAX;
    install_grid_tile(fixture, 0, 0);
    float low_z = (float)(100000.0 + config.cell_size);
    float high_z = (float)(100000.0 + 2.0 * config.cell_size);
    Vec3 point = { 0.175f, 0, low_z + (high_z - low_z) * 0.25f };
    NearestPoly nearest = fixture.query.find_nearest_poly(point, { 0.001f, 1, 0.001f }, &fixture.filter)!!;
    double expected = 0.1 * ((double)point.z - low_z) / ((double)high_z - low_z);
    assert(math::abs(fixture.query.poly_height(nearest.ref, point)!! - expected) < 0.00001);
    SurfacePoint surface = fixture.query.poly_surface(nearest.ref, point)!!;
    double gradient = (double)floor.floor_corners[2] / ((double)high_z - low_z);
    assert(math::abs(surface.normal.z + gradient / math::sqrt(1.0 + gradient * gradient)) < 0.00001);

    floor.diagonal = GridDiagonal.MAX_MIN_TO_MIN_MAX;
    install_grid_tile(fixture, 0, 0);
    nearest = fixture.query.find_nearest_poly(point, { 0.001f, 1, 0.001f }, &fixture.filter)!!;
    assert(math::abs(fixture.query.poly_height(nearest.ref, point)!!) < 0.00001);

    floor.floor_corners = { 0, 2, 0, 2 };
    fixture.map.floors[1 + GRID_MAP_SIDE][1] = {
        .ceiling = float::max,
        .area = nav::WALKABLE_AREA,
        .floor_kind = GridSurfaceKind.CORNERS,
        .floor_corners = { 1, 3, 1, 3 },
        .diagonal = GridDiagonal.MIN_MIN_TO_MAX_MAX,
    };
    fixture.map.counts[1 + GRID_MAP_SIDE] = 2;
    assert(@catch(fixture.builder.build(0, 0)) == c3d::INVALID_ARGUMENT);
    assert(fixture.mesh.is_valid_ref(nearest.ref));

    floor.floor_kind = GridSurfaceKind.FLAT;
    floor.ceiling_kind = GridSurfaceKind.CORNERS;
    floor.ceiling_corners = { 0.05f, 0.45f, 0.45f, 0.05f };
    fixture.map.floors[1 + GRID_MAP_SIDE][1].floor_corners = { 0.45f, 0.05f, 0.05f, 0.45f };
    assert(@catch(fixture.builder.build(0, 0)) == c3d::INVALID_ARGUMENT);
    assert(fixture.mesh.is_valid_ref(nearest.ref));
}

fn void test_clearance_partial_climb_portal() @test {
    NavBuildConfig config = clearance_grid_config();
    config.clearance_mode = ClearanceMode.WHOLE_CELL;
    config.agent_radius = 0;
    GridFixture* fixture = clearance_grid_fixture(config);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 4, 4 }, open_floor(0));
    GridFloor* ramp = &fixture.map.floors[2 + GRID_MAP_SIDE][0];
    ramp.floor_kind = GridSurfaceKind.CORNERS;
    ramp.floor_corners = { 0, 0, 1, 1 };
    install_grid_tile(fixture, 0, 0);
    Vec3 start = { 1.5f, 0, 1.5f };
    PolyRef ref = grid_nearest(fixture, start).ref;
    RaycastHit pass = fixture.query.raycast(
        start_ref: ref,
        start: start,
        end: { 2.5f, 0.5f, 1.5f },
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
    assert(pass.t > 1);
    start.z = 1.9f;
    ref = grid_nearest(fixture, start).ref;
    RaycastHit wall = fixture.query.raycast(
        start_ref: ref,
        start: start,
        end: { 2.5f, 0.9f, 1.9f },
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
    assert(wall.t < 1 && wall.path_count > 0);
}

fn void test_clearance_portal_keeps_shared_stored_endpoint() @test {
    NavBuildConfig config = clearance_grid_config();
    config.tile_size = 1;
    config.agent_radius = 0;
    GridFixture* fixture = clearance_grid_fixture(config, { 0, 0, 0.1f });
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 3, 3 }, open_floor(0));
    install_grid_tile(fixture, 0, 0);
    install_grid_tile(fixture, 1, 0);
    Vec3 first = { 0.5f, 0, 0.35f };
    Vec3 last = { 1.5f, 0, 0.35f };
    NearestPoly first_nearest = grid_nearest(fixture, first);
    NearestPoly last_nearest = grid_nearest(fixture, last);
    assert(first_nearest.point.z == first.z && last_nearest.point.z == last.z);
    RaycastHit forward = fixture.query.raycast(
        start_ref: first_nearest.ref,
        start: first,
        end: last,
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
    RaycastHit reverse = fixture.query.raycast(
        start_ref: last_nearest.ref,
        start: last,
        end: first,
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
    assert(forward.t > 1 && reverse.t > 1);
    assert(forward.path_count == 2 && reverse.path_count == 2);
}

fn void test_clearance_analytic_grid_core() @test {
    NavBuildConfig config = clearance_grid_config();
    GridFixture* fixture = clearance_grid_fixture(config);
    defer destroy_grid_fixture(fixture);
    lay_floor(&fixture.map, { 0, 0, 4, 4 }, open_floor(0));
    fixture.map.floors[2 + 2 * GRID_MAP_SIDE][0].area = nav::NULL_AREA;
    TileRef installed = install_grid_tile(fixture, 0, 0);
    MeshTile* tile = fixture.mesh.tile_by_ref(installed)!!;
    assert(tile.header.subdivision == 4 && tile.header.clearance_mode == ClearanceMode.SUB_CELL);
    foreach (polygon : tile.polys) {
        Aabb bounds = { .min = { float::max, 0, float::max }, .max = { -float::max, 0, -float::max } };
        foreach (index : polygon.verts[:polygon.vert_count]) {
            bounds.min = math::min(bounds.min, tile.verts[index]);
            bounds.max = math::max(bounds.max, tile.verts[index]);
        }
        assert(bounds.min.x >= config.agent_radius && bounds.min.z >= config.agent_radius);
        assert(bounds.max.x <= 4 - config.agent_radius && bounds.max.z <= 4 - config.agent_radius);
        double dx = math::max(0.0, math::max(2.0 - bounds.max.x, (double)bounds.min.x - 3));
        double dz = math::max(0.0, math::max(2.0 - bounds.max.z, (double)bounds.min.z - 3));
        assert(dx * dx + dz * dz >= (double)config.agent_radius * config.agent_radius);
    }
    Vec3 from = { 0.75f, 0, 0.75f };
    Vec3 to = { 3.25f, 0, 0.75f };
    NearestPoly first = grid_nearest(fixture, from);
    NearestPoly last = grid_nearest(fixture, to);
    assert(first.point.x == from.x && first.point.z == from.z && last.point.x == to.x && last.point.z == to.z);
    RaycastHit clear = fixture.query.raycast(
        start_ref: first.ref,
        start: from,
        end: to,
        filter: &fixture.filter,
        out_path: fixture.path[..],
    )!!;
    assert(clear.t > 1);

}

fn void test_clearance_scene_cache_cylinder() @test {
    for (uint mode = 0; mode < 2; mode++) {
        BuilderFixture* fixture = mem::new(BuilderFixture);
        defer free(fixture);
        NavBuildConfig config = bounded_scene_config();
        config.clearance_mode = ClearanceMode.SUB_CELL;
        config.clearance_max_error = 0.25f;
        config.agent_radius = 0.2f;
        NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
        desc.cache_layers = mode == 1;
        desc.slot_scratch_bytes = 8 * 1024 * 1024;
        desc.cache_scratch_bytes = 8 * 1024 * 1024;
        setup_with_desc(fixture, desc);
        defer teardown(fixture);
        add_plane(fixture, { 12, 12 }, { 2, 0, 2 });
        Node* blocker = fixture.scene.add_node()!!;
        if (mode == 1) {
            fixture.scene.add_nav_obstacle(blocker, {
                .kind = CYLINDER, .position = { 2, -0.1f, 2 }, .radius = 0.35f, .height = 2,
            })!!;
        } else {
            fixture.scene.add_nav_volume(blocker, {
                .kind = CYLINDER, .area = nav::NULL_AREA,
                .base = { 2, -0.1f, 2 }, .radius = 0.35f, .height = 2,
            })!!;
        }
        NavSyncResult built = build_everything(fixture);
        assert(built.failed == 0 && built.pending == 0, "mode %d: %s at %s", mode, fixture.builder.last_failure.reason, fixture.builder.last_failure.stage);
        NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 1024)!!;
        defer nav::destroy_nav_query(&query);
        QueryFilter filter = nav::default_query_filter();
        Vec3 core = { 2.8f, 0, 2 };
        NearestPoly nearest = query.find_nearest_poly(core, { 0.001f, 0.5f, 0.001f }, &filter)!!;
        assert(nearest.point.x == core.x && nearest.point.z == core.z);
        foreach (tile : fixture.mesh.tiles) {
            if (!tile.header) continue;
            foreach (polygon : tile.polys) {
                double min_x = double::max;
                double min_z = double::max;
                double max_x = -double::max;
                double max_z = -double::max;
                foreach (index : polygon.verts[:polygon.vert_count]) {
                    min_x = math::min(min_x, (double)tile.verts[index].x);
                    min_z = math::min(min_z, (double)tile.verts[index].z);
                    max_x = math::max(max_x, (double)tile.verts[index].x);
                    max_z = math::max(max_z, (double)tile.verts[index].z);
                }
                double dx = math::max(0.0, math::max(min_x - 2, 2 - max_x));
                double dz = math::max(0.0, math::max(min_z - 2, 2 - max_z));
                double radius = (double)config.agent_radius + 0.35f;
                assert(dx * dx + dz * dz >= radius * radius);
            }
        }
    }
}
