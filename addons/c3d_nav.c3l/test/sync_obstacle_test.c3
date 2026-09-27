module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;
import c3d::scene;

const char  RELAYER_MUD_AREA @private = 2;
const float CRATE_RADIUS @private = 1;
const float CRATE_HEIGHT @private = 2;
const Vec3  CRATE_BASE @private = { 0, -0.5f, 0 }; // node space; below the floor, so the cylinder spans its height
const Aabb  DOOR_BOX @private = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };

// One tile of flat floor built through cached layers.
fn BuilderFixture* setup_cached_floor() @private {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1));
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    build_everything(fixture);
    return fixture;
}

fn void teardown_cached_floor(BuilderFixture* fixture) @private {
    teardown(fixture);
    free(fixture);
}

fn void test_volume_change_relayers_instead_of_rebuilding() @test {
    BuilderFixture* fixture = setup_cached_floor();
    defer teardown_cached_floor(fixture);
    float tile = fixture.builder.tile_world_size;
    float middle = tile * 0.5f;
    Node* mud = fixture.scene.add_node()!!;
    fixture.scene.add_nav_volume(mud, {
        .kind = BOX,
        .area = RELAYER_MUD_AREA,
        .box  = { .min = { 0, -1, -1 }, .max = { middle, 1, tile + 1 } },
    })!!;
    build_everything(fixture);
    uint revision = fixture.builder.tiles[0].revision;

    mud.local.position.x = middle;
    fixture.scene.update_world();
    fixture.scene.get(mud, NavVolume).mark_changed();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    assert(fixture.builder.tiles[0].relayer && fixture.builder.dirty_count == 0);
    NavSyncResult result = build_everything(fixture);

    assert(result.built == 0 && result.relayered == 1);
    assert(fixture.builder.tiles[0].revision == revision, "the layers were not rebuilt");
    MeshTile* mesh_tile = fixture.mesh.tile_at(0, 0, 0);
    float cell = fixture.builder.config.cell_size;
    bool[2] seen;
    foreach (&poly : mesh_tile.polys) {
        char area = poly.area_type.area;
        seen[area == RELAYER_MUD_AREA ? 0 : 1] = true;
        foreach (vertex : poly.verts[:poly.vert_count]) {
            float x = mesh_tile.verts[vertex].x;
            if (area == RELAYER_MUD_AREA) assert(x >= middle - cell);
            if (area != RELAYER_MUD_AREA) assert(x <= middle + cell);
        }
    }
    assert(seen[0] && seen[1]);
}

fn void test_nav_obstacle_component_follows_its_node() @test {
    BuilderFixture* fixture = setup_cached_floor();
    defer teardown_cached_floor(fixture);
    float tile = fixture.builder.tile_world_size;
    Vec3 first_spot = { tile * 0.3f, 0, tile * 0.5f };
    Vec3 second_spot = { tile * 0.7f, 0, tile * 0.5f };
    Node* crate = fixture.scene.add_node()!!;
    crate.local.position = first_spot;
    fixture.scene.update_world();
    fixture.scene.add_nav_obstacle(crate, {
        .kind     = CYLINDER,
        .position = CRATE_BASE,
        .radius   = CRATE_RADIUS,
        .height   = CRATE_HEIGHT,
    })!!;
    build_everything(fixture);
    assert(!polygon_covers(&fixture.mesh, 0, 0, first_spot) && polygon_covers(&fixture.mesh, 0, 0, second_spot));

    crate.local.position = second_spot;
    fixture.scene.update_world();
    fixture.scene.get(crate, NavObstacle).mark_changed();
    build_everything(fixture);

    assert(polygon_covers(&fixture.mesh, 0, 0, first_spot) && !polygon_covers(&fixture.mesh, 0, 0, second_spot));
    assert(obstacles_in_state(&fixture.builder.cache, PROCESSED) == 1);
    assert(obstacles_in_state(&fixture.builder.cache, EMPTY) == fixture.builder.cache.obstacles.len - 1);
}

fn void test_removing_an_obstacle_node_restores_the_tile() @test {
    BuilderFixture* fixture = setup_cached_floor();
    defer teardown_cached_floor(fixture);
    float tile = fixture.builder.tile_world_size;
    TileSnapshot before = snapshot_tile(&fixture.mesh, 0, 0);
    defer free_snapshot(&before);
    Node* door = fixture.scene.add_node()!!;
    door.local.position = { tile * 0.5f, 0, tile * 0.5f };
    fixture.scene.update_world();
    fixture.scene.add_nav_obstacle(door, { .kind = BOX, .box = DOOR_BOX })!!;
    build_everything(fixture);
    TileSnapshot blocked = snapshot_tile(&fixture.mesh, 0, 0);
    defer free_snapshot(&blocked);

    fixture.scene.remove_later(door);
    fixture.scene.flush_removals();
    build_everything(fixture);
    TileSnapshot after = snapshot_tile(&fixture.mesh, 0, 0);
    defer free_snapshot(&after);

    assert(!same_snapshot(&before, &blocked));
    assert(same_snapshot(&before, &after));
    assert(obstacles_in_state(&fixture.builder.cache, EMPTY) == fixture.builder.cache.obstacles.len);
}

fn void test_nav_obstacle_without_cache_layers_is_skipped() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    Node* door = fixture.scene.add_node()!!;
    fixture.scene.add_nav_obstacle(door, { .kind = BOX, .box = DOOR_BOX })!!;

    NavSyncResult result = build_everything(fixture);

    assert(result.skipped == 1 && !fixture.scene.has(door, NavObstacleRuntime));
    assert(@catch(fixture.scene.add_nav_obstacle(door, { .kind = BOX, .box = DOOR_BOX })) == nav::OBSTACLE_EXISTS);
    Node* flat = fixture.scene.add_node()!!;
    assert(@catch(fixture.scene.add_nav_obstacle(flat, { .kind = CYLINDER, .height = 1 })) == c3d::INVALID_ARGUMENT);
}
