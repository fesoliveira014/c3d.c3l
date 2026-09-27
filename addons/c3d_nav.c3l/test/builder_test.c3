module c3d_nav_test;

import std::math;
import std::math::quaternion;
import std::thread;
import c3d;
import c3d::asset;
import c3d::maths;
import c3d::nav @public;
import c3d::scene;

const float LEVEL_HALF_SIZE @private = 10;
const uint  BUDGET_TRIANGLE_BUDGET @private = 100;
const uint  BUDGET_SEGMENTS_X @private = 20;
const uint  BUDGET_SEGMENTS_Z @private = 25; // with BUDGET_SEGMENTS_X, 1000 triangles
const uint  BUDGET_CALLS @private = 10;
const char  MUD_AREA @private = 2;
const usz   TINY_SLOT_BYTES @private = 256;
const float STEP_HEIGHT @private = 0.2f;  // metres; within the default 0.9 m climb
const float STEP_DEPTH @private = 0.6f;
const float RAMP_ANGLE @private = 0.35f;  // radians; about 20 degrees, within the 45 degree slope

fn Aabb centred_level_bounds() @private {
    return { .min = { -LEVEL_HALF_SIZE, -1, -LEVEL_HALF_SIZE }, .max = { LEVEL_HALF_SIZE, 5, LEVEL_HALF_SIZE } };
}

fn int build_on_thread(void* job) @private {
    nav::build_tile((TileJob*)job)!!;
    return 0;
}

fn TileJob* rasterize(BuilderFixture* fixture) @private {
    return fixture.builder.rasterize_next(&fixture.scene, &fixture.assets)!!;
}

fn char[] copy_output(TileJob* job) @private {
    char[] copy = mem::new_array(char, job.output.len);
    copy[..] = job.output[..];
    return copy;
}

fn bool same_bytes(char[] first, char[] second) @private {
    if (first.len != second.len) return false;
    foreach (index, value : first) {
        if (value != second[index]) return false;
    }
    return true;
}

fn Vec3[] portal_vertices(TileMeshView view, ushort side) @private {
    Vec3[] found = mem::new_array(Vec3, (usz)view.header.poly_count * view.header.verts_per_poly * 2);
    usz count;
    for (uint poly = 0; poly < view.header.poly_count; poly++) {
        ushort[] indices = view_polygon(view, poly);
        ushort[] neighbours = view_neighbours(view, poly);
        int vertex_count = nav::count_poly_verts(indices);
        for (int slot = 0; slot < vertex_count; slot++) {
            if (neighbours[slot] != (nav::PORTAL_EDGE | side)) continue;
            found[count++] = world_vertex(view, indices[slot]);
            found[count++] = world_vertex(view, indices[(slot + 1) % vertex_count]);
        }
    }
    return found[:count];
}

fn bool has_close_vertex(Vec3[] vertices, Vec3 target, float tolerance) @private {
    foreach (vertex : vertices) {
        Vec3 delta = math::abs(vertex - target);
        if (delta.x <= tolerance && delta.y <= tolerance && delta.z <= tolerance) return true;
    }
    return false;
}

fn void test_tile_config_derives_voxels() @test {
    TileConfig config = nav::tile_config(nav::default_nav_build_config())!!;

    assert(config.walkable_height == 10 && config.walkable_climb == 4 && config.walkable_radius == 2);
    assert(config.border_size == 5 && config.width == 42 && config.height == 42);
    assert(config.max_edge_length == 40 && config.min_region_area == 64 && config.merge_region_area == 400);
}

fn void test_tile_config_rejects_invalid_values() @test {
    NavBuildConfig[8] rejected;
    foreach (&config : rejected) *config = nav::default_nav_build_config();
    rejected[0].cell_size = 0;
    rejected[1].cell_height = -0.2f;
    rejected[2].tile_size = 0;
    rejected[3].agent_max_slope_degrees = 90;
    rejected[4].agent_height = 0.4f;
    rejected[5].agent_radius = 40;
    rejected[6].verts_per_poly = 2;
    rejected[7].verts_per_poly = nav::MAX_VERTS_PER_POLY + 1;
    foreach (config : rejected) assert(@catch(nav::tile_config(config)) == c3d::INVALID_ARGUMENT);

    NavBuildConfig no_radius = nav::default_nav_build_config();
    no_radius.agent_radius = 0;
    TileConfig derived = nav::tile_config(no_radius)!!;
    assert(derived.walkable_radius == 0 && derived.border_size == 3);
}

fn void test_flat_plane_yields_one_polygon_per_tile() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, centred_level_bounds());
    defer teardown(fixture);
    add_plane(fixture, { 2 * LEVEL_HALF_SIZE, 2 * LEVEL_HALF_SIZE }, { 0, 0, 0 });

    NavSyncResult result = build_everything(fixture);

    NavBuilder* builder = &fixture.builder;
    assert(result.pending == 0 && result.failed == 0 && result.built == builder.tiles_x * builder.tiles_z);
    uint meshes;
    for (uint tile_z = 0; tile_z < builder.tiles_z; tile_z++) {
        for (uint tile_x = 0; tile_x < builder.tiles_x; tile_x++) {
            char[] mesh = builder.tile_mesh(tile_x, tile_z);
            if (!mesh.len) continue;
            TileMeshView view = nav::tile_mesh_view(mesh);
            assert(view.header.poly_count == 1, "tile %d %d has %d polygons", tile_x, tile_z, view.header.poly_count);
            assert(view.areas[0] == nav::WALKABLE_AREA);
            meshes++;
        }
    }
    // The outer row and column hold 0.8 m of floor, which the ledge filter and erosion remove.
    assert(meshes == (builder.tiles_x - 1) * (builder.tiles_z - 1));
}

fn void test_neighbouring_tiles_share_edge_vertices() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(2));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { 2 * tile, 2 * tile }, { tile, 0, tile });
    add_box(fixture, { 2, 1, 2 }, { tile, 0.5f, tile * 0.5f });

    build_everything(fixture);

    TileMeshView left = nav::tile_mesh_view(fixture.builder.tile_mesh(0, 0));
    TileMeshView right = nav::tile_mesh_view(fixture.builder.tile_mesh(1, 0));
    Vec3[] left_side = portal_vertices(left, 2);
    defer free(left_side);
    Vec3[] right_side = portal_vertices(right, 0);
    defer free(right_side);
    float half_cell = fixture.builder.config.cell_size * 0.5f;
    assert(left_side.len >= 4, "the box splits the shared side into two portal edges");
    assert(left_side.len == right_side.len);
    foreach (vertex : left_side) assert(has_close_vertex(right_side, vertex, half_cell));
    foreach (vertex : right_side) assert(has_close_vertex(left_side, vertex, half_cell));
}

fn void test_build_tile_on_a_spawned_thread_matches_the_main_thread() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    add_box(fixture, { 2, 1, 2 }, { tile * 0.5f, 0.5f, tile * 0.5f });
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* main_job = rasterize(fixture);
    fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
    TileJob* worker_job = rasterize(fixture);
    assert(main_job != worker_job && worker_job.state == READY);

    nav::build_tile(main_job)!!;
    Thread thread;
    thread.create(&build_on_thread, worker_job)!!;
    thread.join()!!;

    assert(main_job.state == BUILT && worker_job.state == BUILT);
    assert(main_job.output.len > 0);
    assert(same_bytes(main_job.output, worker_job.output));
}

fn void test_commit_answers_only_the_latest_request() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    Node* floor = add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* older = rasterize(fixture);

    floor.local.position.x += tile * 0.5f;
    fixture.scene.update_world();
    fixture.scene.get(floor, NavSource).mark_changed();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* newer = rasterize(fixture);
    nav::build_tile(newer)!!;
    fixture.builder.commit(newer)!!;
    nav::build_tile(older)!!;
    assert(!same_bytes(older.output, newer.output), "the moved floor builds a different mesh");
    fixture.builder.commit(older)!!;

    TileRecord* record = &fixture.builder.tiles[0];
    assert(record.revision == 1 && !record.dirty);
    assert(same_bytes(record.mesh, newer.output));
    assert(older.state == FREE && newer.state == FREE);
}

fn void test_rasterize_budget_resumes_across_calls() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1));
    desc.rasterize_budget = BUDGET_TRIANGLE_BUDGET;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(
        fixture:    fixture,
        size:       { tile - 2, tile - 2 },
        position:   { tile * 0.5f, 0, tile * 0.5f },
        segments_x: BUDGET_SEGMENTS_X,
        segments_z: BUDGET_SEGMENTS_Z,
    );
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);

    TileJob* job;
    for (uint call = 1; call <= BUDGET_CALLS; call++) {
        job = rasterize(fixture);
        assert(job.state == (call < BUDGET_CALLS ? JobState.RASTERIZING : JobState.READY), "call %d", call);
    }
    nav::build_tile(job)!!;
    char[] budgeted = copy_output(job);
    defer free(budgeted);
    fixture.builder.commit(job)!!;

    fixture.builder.rasterize_budget = 0;
    fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
    TileJob* unlimited = rasterize(fixture);
    assert(unlimited.state == READY);
    nav::build_tile(unlimited)!!;
    assert(budgeted.len > 0);
    assert(same_bytes(budgeted, unlimited.output));
}

fn void test_volume_marks_polygons_with_its_area() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    float middle = tile * 0.5f;
    add_plane(fixture, { tile, tile }, { middle, 0, middle });
    Node* mud = fixture.scene.add_node()!!;
    fixture.scene.add_nav_volume(mud, {
        .kind = BOX,
        .area = MUD_AREA,
        .box  = { .min = { -1, -1, -1 }, .max = { middle, 1, tile + 1 } },
    })!!;

    build_everything(fixture);

    TileMeshView view = nav::tile_mesh_view(fixture.builder.tile_mesh(0, 0));
    float cell = fixture.builder.config.cell_size;
    bool[2] seen;
    for (uint poly = 0; poly < view.header.poly_count; poly++) {
        char area = view.areas[poly];
        assert(area == MUD_AREA || area == nav::WALKABLE_AREA);
        seen[area == MUD_AREA ? 0 : 1] = true;
        ushort[] indices = view_polygon(view, poly);
        foreach (vertex : indices[:nav::count_poly_verts(indices)]) {
            float x = world_vertex(view, vertex).x;
            if (area == MUD_AREA) assert(x <= middle + cell);
            if (area != MUD_AREA) assert(x >= middle - cell);
        }
    }
    assert(seen[0] && seen[1]);
}

fn void test_build_failure_names_the_stage() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1));
    desc.slot_scratch_bytes = TINY_SLOT_BYTES;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });

    NavSyncResult result = nav::nav_sync(
        builder: &fixture.builder,
        mesh:    &fixture.mesh,
        scene:   &fixture.scene,
        assets:  &fixture.assets,
        budget:  1,
    );

    TileFailure failure = fixture.builder.last_failure;
    assert(result.failed == 1 && result.built == 0 && result.pending == 1);
    assert(failure.tile_x == 0 && failure.tile_z == 0);
    assert(failure.reason == c3d::CAPACITY_EXCEEDED && failure.stage == COMPACT);
    assert(fixture.builder.tiles[0].dirty && fixture.builder.tiles[0].revision == 0);
}

fn void test_default_tile_fits_the_default_arena() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    float middle = tile * 0.5f;
    add_plane(fixture, { tile, tile }, { middle, 0, middle });
    for (uint step = 1; step <= 3; step++) {
        float rise = step * STEP_HEIGHT;
        add_box(fixture, { 2, rise, STEP_DEPTH }, { 2, rise * 0.5f, 2 + step * STEP_DEPTH });
    }
    Node* ramp = add_box(fixture, { 2, 0.2f, 4 }, { 6.5f, 0.6f, 5 });
    ramp.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, RAMP_ANGLE);
    fixture.scene.update_world();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);

    TileJob* job = rasterize(fixture);
    nav::build_tile(job)!!;

    assert(job.output.len > 0);
    assert((usz)job.arena.used < job.scratch.len / 4);
}
