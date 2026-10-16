module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d;
import c3d::nav @public;
import c3d::scene;

fn void setup_bounded_bridge(BuilderFixture* fixture, uint tiles = 1) @private {
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(tiles, config), config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    float side = (float)tiles * (config.tile_size * config.cell_size);
    add_plane(fixture, { side + 4, side + 4 }, { side * 0.5f, 0, side * 0.5f });
    add_plane(fixture, { side + 4, side + 4 }, { side * 0.5f, 3, side * 0.5f });
    NavSyncResult result = build_everything(fixture);
    assert(result.failed == 0 && result.pending == 0);
}

fn void test_bounded_cache_obstacles_preserve_reference_and_other_floor() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_bridge(fixture);
    defer teardown(fixture);
    TileCache* cache = &fixture.builder.cache;
    CachedLayerRef[2] refs = { fixture.builder.tiles[0].layers[0], fixture.builder.tiles[0].layers[1] };
    char[][2] saved;
    defer {
        foreach (bytes : saved) free(bytes);
    }
    for (uint index = 0; index < refs.len; index++) {
        CachedLayer* layer = cache.tile_by_ref(refs[index])!!;
        saved[index] = mem::new_array(char, layer.data.len);
        saved[index][..] = layer.data[..];
    }
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly lower = query.find_nearest_poly({ 2, 0, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)!!;
    float upper_height = query.find_nearest_poly({ 2, 3, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)!!.point.y;
    for (uint shape = 0; shape < 3; shape++) {
        ObstacleRef obstacle;
        switch (shape) {
            case 0:
                obstacle = cache.add_obstacle({ 2, 3.25f, 2 }, 0.4f, 0.5f)!!;
            case 1:
                obstacle = cache.add_box_obstacle({ .min = { 1.6f, 3.25f, 1.6f }, .max = { 2.4f, 3.75f, 2.4f } })!!;
            case 2:
                obstacle = cache.add_oriented_box_obstacle({ 2, 3.5f, 2 }, { 0.4f, 0.25f, 0.4f }, 0.4f)!!;
        }
        assert(cache.update(&fixture.mesh, 64)!!);
        assert(cache.obstacle_by_ref(obstacle)!!.state == PROCESSED);
        if (catch excuse = query.find_nearest_poly({ 2, 3, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)) {
            assert(excuse == nav::NO_POLY);
        } else {
            assert(false);
        }
        NearestPoly current_lower = query.find_nearest_poly({ 2, 0, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)!!;
        assert(current_lower.point.y == lower.point.y);
        assert(query.poly_height(current_lower.ref, current_lower.point)!! == lower.point.y);
        cache.remove_obstacle(obstacle)!!;
        assert(cache.update(&fixture.mesh, 64)!!);
        NearestPoly restored = query.find_nearest_poly({ 2, 3, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)!!;
        assert(restored.point.y == upper_height);
        for (uint index = 0; index < refs.len; index++) assert(same_bytes(saved[index], cache.tile_by_ref(refs[index])!!.data));
    }
}

fn void test_bounded_cache_failed_rebuild_stays_pending_and_retryable() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_bridge(fixture);
    defer teardown(fixture);
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly resident = query.find_nearest_poly({ 2, 3, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)!!;
    TileCache* cache = &fixture.builder.cache;
    ObstacleRef obstacle = cache.add_box_obstacle({ .min = { 1.5f, 3.2f, 1.5f }, .max = { 2.5f, 3.8f, 2.5f } })!!;
    cache.arena.init(cache.build_scratch[:64]);
    if (catch excuse = cache.update(&fixture.mesh, 64)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(cache.update_count > 0 && cache.obstacle_by_ref(obstacle)!!.state == PROCESSING);
    assert(fixture.mesh.is_valid_ref(resident.ref));
    assert(query.poly_height(resident.ref, resident.point)!! == resident.point.y);
    cache.arena.init(cache.build_scratch);
    assert(cache.update(&fixture.mesh, 64)!!);
    assert(cache.update_count == 0 && cache.obstacle_by_ref(obstacle)!!.state == PROCESSED);
}

fn void test_bounded_cache_rejects_untracked_obstacle_influence() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_bridge(fixture, 3);
    defer teardown(fixture);
    TileCache* cache = &fixture.builder.cache;
    uint pending = cache.request_count;
    Obstacle* free_obstacle = cache.next_free_obstacle;
    if (catch excuse = cache.add_box_obstacle({ .min = { -1, -1, -1 }, .max = { 13, 5, 13 } })) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(cache.request_count == pending && cache.next_free_obstacle == free_obstacle);
}

fn void test_bounded_cache_and_prepared_layers_survive_origin_shift() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_bridge(fixture);
    defer teardown(fixture);
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly before = query.find_nearest_poly({ 2, 3, 2 }, { 0.01f, 0.5f, 0.01f }, &filter)!!;
    fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
    TileJob* prepared = rasterize(fixture);
    nav::build_tile(prepared)!!;
    Vec3 offset = { 100000, 0, -100000 };
    fixture.scene.shift_origin(offset);
    fixture.scene.update_world();
    fixture.mesh.shift_origin(offset);
    fixture.builder.shift_origin(offset);
    fixture.scene.shift_navigation(offset);
    query.shift_origin(offset);
    assert(fixture.mesh.is_valid_ref(before.ref));
    assert(query.poly_height(before.ref, before.point - offset)!! == before.point.y);
    fixture.builder.commit(prepared)!!;
    NavSyncResult rebuilt = build_everything(fixture);
    assert(rebuilt.failed == 0 && rebuilt.pending == 0);
    NearestPoly after = query.find_nearest_poly(before.point - offset, { 0.01f, 0.5f, 0.01f }, &filter)!!;
    assert(after.point.y == before.point.y);
    ObstacleRef obstacle = fixture.builder.cache.add_box_obstacle({ .min = { 1.5f, 3.2f, 1.5f } - offset, .max = { 2.5f, 3.8f, 2.5f } - offset })!!;
    assert(fixture.builder.cache.update(&fixture.mesh, 64)!!);
    fixture.builder.cache.remove_obstacle(obstacle)!!;
    assert(fixture.builder.cache.update(&fixture.mesh, 64)!!);
    NearestPoly restored = query.find_nearest_poly(before.point - offset, { 0.01f, 0.5f, 0.01f }, &filter)!!;
    assert(restored.point.y == before.point.y);
}

fn void test_bounded_cache_rejects_malformed_reference_before_publication() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_bridge(fixture);
    defer teardown(fixture);
    TileCache* cache = &fixture.builder.cache;
    CachedLayerRef resident_ref = fixture.builder.tiles[0].layers[0];
    CachedLayer* resident = cache.tile_by_ref(resident_ref)!!;
    char[] copy = mem::new_array(char, resident.data.len);
    defer free(copy);
    copy[..] = resident.data[..];
    DetailReference reference = nav::cached_detail_reference(copy)!!;
    reference.samples[reference.samples.len - 1].column = uint::max;
    reference.samples[0].connections[0] = (uint)reference.samples.len - 1;
    if (catch excuse = cache.add_tile(copy, {})) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(cache.tile_by_ref(resident_ref)!! == resident);
    assert(nav::cached_detail_reference(resident.data)!!.samples[0].column < uint::max);
}
