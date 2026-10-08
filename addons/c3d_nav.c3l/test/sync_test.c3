module c3d_nav_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::maths;
import c3d::nav @public;
import c3d::scene;

const uint  SYNC_BUDGET @private = 4;
const uint  SYNC_GRID_TILES @private = 3;
const uint  SHIFT_GRID_TILES @private = 4; // interior tiles on both sides of the moved crate
const char  ABOVE_WALKABLE_AREA @private = nav::WALKABLE_AREA + 1;
const uint  ONE_PLANE_BUDGET @private = 2; // triangles; one unsegmented plane per rasterize_next call
const uint  CRATE_ROW @private = 8;
const float CRATE_SPACING @private = 0.5f;

fn bool overlaps_tile(NavBuilder* builder, Aabb box, uint tile_x, uint tile_z) @private {
    Aabb tile = builder.tile_bounds(tile_x, tile_z);
    return box.min.x <= tile.max.x && box.max.x >= tile.min.x && box.min.z <= tile.max.z && box.max.z >= tile.min.z;
}

fn uint tiles_under(NavBuilder* builder, Aabb first, Aabb second) @private {
    uint count;
    for (uint tile_z = 0; tile_z < builder.tiles_z; tile_z++) {
        for (uint tile_x = 0; tile_x < builder.tiles_x; tile_x++) {
            bool under_first = overlaps_tile(builder, first, tile_x, tile_z);
            if (under_first || overlaps_tile(builder, second, tile_x, tile_z)) count++;
        }
    }
    return count;
}

fn usz mirror_count(Scene* scene) @private {
    usz count;
    scene.@each(NavSourceRuntime; entity, runtime) {
        count++;
    };
    return count;
}

fn NavSyncResult sync(BuilderFixture* fixture, uint budget) @private {
    return nav::nav_sync(
        builder: &fixture.builder,
        mesh:    &fixture.mesh,
        scene:   &fixture.scene,
        assets:  &fixture.assets,
        budget:  budget,
    );
}

fn void test_mark_changed_dirties_exactly_the_overlapped_tiles() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(SYNC_GRID_TILES));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    float side = tile * SYNC_GRID_TILES;
    add_plane(fixture, { side, side }, { side * 0.5f, 0, side * 0.5f });
    Node* crate = add_box(fixture, { 1, 1, 1 }, { tile * 1.5f, 0.5f, tile * 1.5f });
    build_everything(fixture);
    assert(fixture.builder.dirty_count == 0);
    Aabb old_bounds = fixture.scene.get(crate, NavSourceRuntime).bounds;

    crate.local.position.x += tile;
    fixture.scene.update_world();
    fixture.scene.get(crate, NavSource).mark_changed();
    NavSyncResult synced = sync(fixture, 0);

    Aabb new_bounds = fixture.scene.get(crate, NavSourceRuntime).bounds;
    uint expected = tiles_under(&fixture.builder, old_bounds, new_bounds);
    assert(new_bounds.min.x > old_bounds.max.x);
    assert(expected == 2, "one tile under the old bounds and one under the new");
    assert(synced.pending == expected && fixture.builder.dirty_count == expected);
    NavSyncResult rebuilt = sync(fixture, expected);
    assert(rebuilt.built == expected && rebuilt.pending == 0);
}

fn void test_removing_a_source_dirties_its_tiles() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    Node* floor = add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    build_everything(fixture);
    assert(fixture.builder.tile_mesh(0, 0).len > 0);

    fixture.scene.remove_component(floor, NavSource);
    NavSyncResult result = build_everything(fixture);

    assert(result.built == 1 && result.pending == 0);
    assert(fixture.builder.tile_mesh(0, 0).len == 0);
    assert(!fixture.scene.has(floor, NavSourceRuntime));
}

fn void test_removing_a_source_node_dirties_its_tiles() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    Node* floor = add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    build_everything(fixture);
    assert(fixture.builder.tile_mesh(0, 0).len > 0);

    fixture.scene.remove_later(floor);
    fixture.scene.flush_removals();
    NavSyncResult result = build_everything(fixture);

    assert(result.built == 1 && result.pending == 0);
    assert(fixture.builder.tile_mesh(0, 0).len == 0);
    assert(mirror_count(&fixture.scene) == 0);
}

fn void test_node_removal_restarts_a_rasterizing_slot() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1));
    desc.rasterize_budget = ONE_PLANE_BUDGET;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    float half = tile * 0.5f;
    Node* left = add_plane(fixture, { half, tile }, { half * 0.5f, 0, half });
    add_plane(fixture, { half, tile }, { half * 1.5f, 0, half });
    add_box(fixture, { 1, 1, 1 }, { half * 1.5f, 0.5f, half });
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* job = rasterize(fixture);
    assert(job.state == RASTERIZING, "the left plane is in, the rest waits for the next call");

    fixture.scene.remove_later(left);
    fixture.scene.flush_removals();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    while (job.state == RASTERIZING) job = rasterize(fixture);
    nav::build_tile(job)!!;
    char[] resumed = copy_output(job);
    defer free(resumed);
    fixture.builder.commit(job)!!;

    fixture.builder.rasterize_budget = 0;
    fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
    TileJob* fresh = rasterize(fixture);
    nav::build_tile(fresh)!!;
    assert(resumed.len > 0);
    assert(same_bytes(resumed, fresh.output), "the slot rebuilt from the remaining sources only");
}

fn void test_removal_queue_overflow_dirties_every_tile() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(SYNC_GRID_TILES));
    defer teardown(fixture);
    Node*[nav::REMOVAL_QUEUE_CAPACITY + 1] crates;
    foreach (index, &crate : crates) {
        Vec3 position = {
            1 + (float)(index % CRATE_ROW) * CRATE_SPACING,
            0.1f,
            1 + (float)(index / CRATE_ROW) * CRATE_SPACING,
        };
        *crate = add_box(fixture, { 0.2f, 0.2f, 0.2f }, position);
    }
    build_everything(fixture);
    assert(fixture.builder.dirty_count == 0);
    uint epoch = fixture.builder.source_epoch;

    foreach (crate : crates) fixture.scene.remove_later(crate);
    fixture.scene.flush_removals();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);

    assert(fixture.builder.dirty_count == SYNC_GRID_TILES * SYNC_GRID_TILES);
    assert(fixture.builder.source_epoch == epoch + 1);
}

fn void test_unavailable_geometry_is_skipped_and_counted() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    float half = tile * 0.5f;
    Node* released = add_plane(fixture, { half, tile }, { half * 0.5f, 0, half });
    add_plane(fixture, { half, tile }, { half * 1.5f, 0, half });
    fixture.assets.release_geometry_cpu(fixture.scene.get(released, scene::Mesh).geometry);

    NavSyncResult result = build_everything(fixture);

    assert(result.skipped == 1 && result.built == 1 && result.failed == 0);
    TileMeshView view = nav::tile_mesh_view(fixture.builder.tile_mesh(0, 0));
    assert(view.header.poly_count > 0);
    for (uint poly = 0; poly < view.header.poly_count; poly++) {
        ushort[] indices = view_polygon(view, poly);
        foreach (vertex : indices[:nav::count_poly_verts(indices)]) assert(world_vertex(view, vertex).x >= half);
    }
}

fn void test_nav_sync_builds_up_to_budget() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(SYNC_GRID_TILES));
    defer teardown(fixture);
    float side = fixture.builder.tile_world_size * SYNC_GRID_TILES;
    add_plane(fixture, { side, side }, { side * 0.5f, 0, side * 0.5f });

    NavSyncResult first = sync(fixture, SYNC_BUDGET);
    NavSyncResult second = sync(fixture, SYNC_BUDGET);
    NavSyncResult third = sync(fixture, SYNC_BUDGET);

    assert(first.built == 4 && first.pending == 5);
    assert(second.built == 4 && second.pending == 1);
    assert(third.built == 1 && third.pending == 0);
}

fn void test_add_nav_source_rejects_bad_input() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    Node* bare = fixture.scene.add_node()!!;
    Node* floor = add_plane(fixture, { 1, 1 }, { 0, 0, 0 });
    Node* other = fixture.scene.add_mesh(fixture.scene.get(floor, scene::Mesh).geometry, {})!!;

    assert(@catch(fixture.scene.add_nav_source(bare)) == c3d::INVALID_ARGUMENT);
    assert(@catch(fixture.scene.add_nav_source(other, area: ABOVE_WALKABLE_AREA)) == c3d::INVALID_ARGUMENT);
    assert(@catch(fixture.scene.add_nav_source(floor)) == nav::SOURCE_EXISTS);
    assert(!fixture.scene.has(bare, NavSource) && !fixture.scene.has(other, NavSource));
}

fn void test_add_nav_volume_rejects_bad_input() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    Node* node = fixture.scene.add_node()!!;
    NavVolume two_vertices = { .kind = CONVEX, .area = 1, .vert_count = 2, .min_y = 0, .max_y = 1 };
    NavVolume inverted = { .kind = CONVEX, .area = 1, .vert_count = 3, .min_y = 1, .max_y = 0 };
    NavVolume box = { .kind = BOX, .area = 1, .box = { .min = { 0, 0, 0 }, .max = { 1, 1, 1 } } };

    assert(@catch(fixture.scene.add_nav_volume(node, two_vertices)) == c3d::INVALID_ARGUMENT);
    assert(@catch(fixture.scene.add_nav_volume(node, inverted)) == c3d::INVALID_ARGUMENT);
    fixture.scene.add_nav_volume(node, box)!!;
    assert(@catch(fixture.scene.add_nav_volume(node, box)) == nav::VOLUME_EXISTS);
}

fn void test_builder_rebuilds_the_shifted_tile() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(SHIFT_GRID_TILES));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    float side = tile * SHIFT_GRID_TILES;
    add_plane(fixture, { side, side }, { side * 0.5f, 0, side * 0.5f });
    Node* crate = add_box(fixture, { 1, 1, 1 }, { tile * 1.5f, 0.5f, tile * 1.5f });
    build_everything(fixture);
    Vec3 offset = { 2 * tile, 0, -tile };

    fixture.scene.shift_origin(offset);
    fixture.scene.update_world();
    fixture.mesh.shift_origin(offset);
    fixture.builder.shift_origin(offset);
    fixture.scene.shift_navigation(offset);
    crate.local.position.x += tile;
    fixture.scene.update_world();
    fixture.scene.get(crate, NavSource).mark_changed();
    NavSyncResult rebuilt = build_everything(fixture);

    assert(rebuilt.built == 2 && rebuilt.pending == 0 && rebuilt.failed == 0);
    TileRef moved = fixture.mesh.tile_ref_at(2, 1, 0);
    assert(moved != (TileRef)0);
    TileHeader* header = fixture.mesh.tile_by_ref(moved)!!.header;
    Aabb bounds = fixture.builder.bounds;
    assert(header.x == 2 && header.z == 1);
    assert(header.bounds.min.x >= bounds.min.x + 2 * tile - QUERY_TOLERANCE);
    assert(header.bounds.max.x <= bounds.min.x + 3 * tile + QUERY_TOLERANCE);
    assert(header.bounds.min.z >= bounds.min.z + tile - QUERY_TOLERANCE);
    assert(header.bounds.max.z <= bounds.min.z + 2 * tile + QUERY_TOLERANCE);
}
