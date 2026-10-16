module c3d_nav_test;

import std::io;
import c3d;
import c3d::nav @public;
import c3d::scene;

fn bool retained_layer_matches(TileCache* cache, CachedLayerRef ref, char[] bytes) @local {
    if (try layer = cache.tile_by_ref(ref)) return same_bytes(layer.data, bytes);
    return false;
}

fn void test_cached_layer_shrink_keeps_the_failed_runtime_layers_reference() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 8, 8 }, { 2, 0, 2 });
    Node* upper_source = add_plane(fixture, { 8, 8 }, { 2, 3, 2 });
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0);
    TileRecord* record = &fixture.builder.tiles[0];
    assert(record.layer_count == 2);
    CachedLayerRef[2] cache_refs = { record.layers[0], record.layers[1] };
    char[][2] cache_bytes;
    defer {
        foreach (bytes : cache_bytes) free(bytes);
    }
    for (uint layer = 0; layer < 2; layer++) {
        char[] bytes = fixture.builder.cache.tile_by_ref(cache_refs[layer])!!.data;
        cache_bytes[layer] = mem::new_array(char, bytes.len);
        cache_bytes[layer][..] = bytes[..];
    }
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly lower = query.find_nearest_poly({ 2, 0, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    NearestPoly upper = query.find_nearest_poly({ 2, 3, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    uint before_revision = record.revision;
    uint before_links = fixture.mesh.free_links();
    RuntimeSetSnapshot runtime_before = snapshot_runtime_set(&fixture.mesh);
    defer destroy_runtime_set_snapshot(&runtime_before);
    fixture.scene.remove_later(upper_source);
    fixture.scene.flush_removals();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* job = rasterize(fixture);
    nav::build_tile(job)!!;
    fixture.builder.commit(job)!!;
    bool lower_cache_before_install = retained_layer_matches(&fixture.builder.cache, cache_refs[0], cache_bytes[0]);
    bool upper_cache_before_install = retained_layer_matches(&fixture.builder.cache, cache_refs[1], cache_bytes[1]);
    bool lower_runtime_before_install = fixture.mesh.is_valid_ref(lower.ref);
    bool upper_runtime_before_install = fixture.mesh.is_valid_ref(upper.ref);
    io::printfn("before_request layers=2 revision=%d links=%d", before_revision, before_links);
    io::printfn("before_install layers=%d revision=%d", record.layer_count, record.revision);
    io::printfn("before_install old_cache_lower=%s old_cache_upper=%s", lower_cache_before_install, upper_cache_before_install);
    io::printfn("before_install old_runtime_lower=%s old_runtime_upper=%s", lower_runtime_before_install, upper_runtime_before_install);

    Allocator original = fixture.mesh.allocator;
    CacheAllocationProbe probe = { .backing = original, .failure = 1 };
    fixture.mesh.allocator = &probe;
    NavSyncResult failed = build_everything(fixture);
    fixture.mesh.allocator = original;
    assert(failed.failed > 0 && fixture.builder.last_failure.stage == BuildStage.INSTALL);
    assert(fixture.builder.last_failure.reason == c3d::CAPACITY_EXCEEDED);
    assert_runtime_set_unchanged(&fixture.mesh, &runtime_before);
    assert(record.revision == before_revision && record.layer_count == 2);
    bool lower_cache_after_failure = retained_layer_matches(&fixture.builder.cache, cache_refs[0], cache_bytes[0]);
    bool upper_cache_after_failure = retained_layer_matches(&fixture.builder.cache, cache_refs[1], cache_bytes[1]);
    bool lower_runtime_after_failure = fixture.mesh.is_valid_ref(lower.ref);
    bool upper_runtime_after_failure = fixture.mesh.is_valid_ref(upper.ref);
    io::printfn("after_install_failure old_cache_lower=%s old_cache_upper=%s", lower_cache_after_failure, upper_cache_after_failure);
    io::printfn("after_install_failure old_runtime_lower=%s old_runtime_upper=%s", lower_runtime_after_failure, upper_runtime_after_failure);
    io::printfn("after_install_failure queued=%d links=%d", fixture.builder.cache.update_count, fixture.mesh.free_links());
    assert(lower_runtime_after_failure && query.poly_height(lower.ref, lower.point)!! == lower.point.y);
    assert(upper_runtime_after_failure && query.poly_height(upper.ref, upper.point)!! == upper.point.y);
    assert(lower_cache_before_install && upper_cache_before_install && lower_cache_after_failure && upper_cache_after_failure);
    NavSyncResult retried = build_everything(fixture);
    assert(retried.failed == 0 && retried.pending == 0 && record.layer_count == 1);
    assert(fixture.mesh.tile_at(0, 0, 0) && !fixture.mesh.tile_at(0, 0, 1));
    io::printfn("retry layers=%d queued=%d failed=%d", record.layer_count, fixture.builder.cache.update_count, retried.failed);
    assert(lower_cache_before_install && lower_cache_after_failure,
        "the old retained lower reference must survive until its runtime replacement commits");
}

fn void test_cached_two_layer_replacement_keeps_complete_sets_on_each_runtime_allocation_failure() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 8, 8 }, { 2, 0, 2 });
    add_plane(fixture, { 8, 8 }, { 2, 3, 2 });
    assert(build_everything(fixture).failed == 0);
    TileRecord* record = &fixture.builder.tiles[0];
    CachedLayerRef[2] refs = { record.layers[0], record.layers[1] };
    char[][2] cached;
    defer { foreach (bytes : cached) free(bytes); }
    foreach (index, ref : refs) {
        char[] data = fixture.builder.cache.tile_by_ref(ref)!!.data;
        cached[index] = copy_runtime_set_bytes(data.ptr, data.len);
    }
    uint revision = record.revision;
    fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
    TileJob* job = rasterize(fixture);
    nav::build_tile(job)!!;
    fixture.builder.commit(job)!!;
    RuntimeSetSnapshot before = snapshot_runtime_set(&fixture.mesh);
    defer destroy_runtime_set_snapshot(&before);
    Allocator original = fixture.mesh.allocator;
    for (uint failure = 1; failure <= 2; failure++) {
        CacheAllocationProbe probe = { .backing = original, .failure = failure };
        fixture.mesh.allocator = &probe;
        NavSyncResult result = build_everything(fixture);
        fixture.mesh.allocator = original;
        assert(result.failed == 1 && result.pending == 1);
        assert(probe.acquired == failure - 1 && probe.released == probe.acquired);
        assert_runtime_set_unchanged(&fixture.mesh, &before);
        assert(record.revision == revision && record.layer_count == 2);
        foreach (index, ref : refs) assert(retained_layer_matches(&fixture.builder.cache, ref, cached[index]));
    }
    NavSyncResult retried = build_everything(fixture);
    assert(retried.failed == 0 && retried.pending == 0 && record.revision == revision + 1);
    foreach (ref : refs) assert(@catch(fixture.builder.cache.tile_by_ref(ref)) == nav::INVALID_REF);
}

fn void test_cached_obstacle_update_keeps_all_runtime_layers_on_late_allocation_failure() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 8, 8 }, { 2, 0, 2 });
    add_plane(fixture, { 8, 8 }, { 2, 3, 2 });
    assert(build_everything(fixture).failed == 0);
    ObstacleRef obstacle = fixture.builder.cache.add_box_obstacle({ .min = { 1, -1, 1 }, .max = { 2, 5, 2 } })!!;
    RuntimeSetSnapshot before = snapshot_runtime_set(&fixture.mesh);
    defer destroy_runtime_set_snapshot(&before);
    Allocator original = fixture.mesh.allocator;
    CacheAllocationProbe probe = { .backing = original, .failure = 2 };
    fixture.mesh.allocator = &probe;
    fault failure = @catch(fixture.builder.cache.update(&fixture.mesh, 1));
    fixture.mesh.allocator = original;
    assert(failure == c3d::CAPACITY_EXCEEDED && probe.acquired == 1 && probe.released == 1);
    assert_runtime_set_unchanged(&fixture.mesh, &before);
    assert(fixture.builder.cache.update_count == 2);
    assert(fixture.builder.cache.obstacle_by_ref(obstacle)!!.state == ObstacleState.PROCESSING);
    assert(fixture.builder.cache.update(&fixture.mesh, 1)!!);
    assert(fixture.builder.cache.update_count == 0);
    assert(fixture.builder.cache.obstacle_by_ref(obstacle)!!.state == ObstacleState.PROCESSED);
}

fn void test_cached_runtime_slot_failure_preserves_old_set_then_empty_source_removes_it() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
    desc.bounds.max.y = 9;
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    nav::destroy_nav_mesh(&fixture.mesh);
    fixture.mesh = nav::create_nav_mesh(mem, {
        .origin = desc.bounds.min,
        .tile_width = fixture.builder.tile_world_size,
        .tile_height = fixture.builder.tile_world_size,
        .max_tiles = 2,
    })!!;
    Node*[3] floors;
    floors[0] = add_plane(fixture, { 8, 8 }, { 2, 0, 2 });
    floors[1] = add_plane(fixture, { 8, 8 }, { 2, 3, 2 });
    assert(build_everything(fixture).failed == 0);
    TileRecord* record = &fixture.builder.tiles[0];
    CachedLayerRef[2] refs = { record.layers[0], record.layers[1] };
    char[][2] cached;
    defer { foreach (bytes : cached) free(bytes); }
    foreach (index, ref : refs) {
        char[] data = fixture.builder.cache.tile_by_ref(ref)!!.data;
        cached[index] = copy_runtime_set_bytes(data.ptr, data.len);
    }
    RuntimeSetSnapshot before = snapshot_runtime_set(&fixture.mesh);
    defer destroy_runtime_set_snapshot(&before);
    uint revision = record.revision;
    floors[2] = add_plane(fixture, { 8, 8 }, { 2, 6, 2 });
    NavSyncResult failed = build_everything(fixture);
    assert(failed.failed == 1 && failed.pending == 1);
    assert(fixture.builder.last_failure.reason == c3d::CAPACITY_EXCEEDED && fixture.builder.last_failure.stage == INSTALL);
    assert(record.revision == revision && record.layer_count == 2);
    assert_runtime_set_unchanged(&fixture.mesh, &before);
    foreach (index, ref : refs) assert(retained_layer_matches(&fixture.builder.cache, ref, cached[index]));

    foreach (floor : floors) fixture.scene.remove_later(floor);
    fixture.scene.flush_removals();
    NavSyncResult empty = build_everything(fixture);
    assert(empty.failed == 0 && empty.pending == 0 && record.layer_count == 0);
    assert(record.revision == revision + 1);
    assert(!fixture.mesh.tile_at(0, 0, 0) && !fixture.mesh.tile_at(0, 0, 1));
    foreach (ref : refs) assert(@catch(fixture.builder.cache.tile_by_ref(ref)) == nav::INVALID_REF);
}

fn void test_cached_runtime_set_limit_rejects_all_layers_instead_of_truncating() @test {
    CacheFixture fixture;
    setup_cache(&fixture);
    defer teardown_cache(&fixture);
    TileCacheDesc desc = fixture.cache.desc;
    nav::destroy_tile_cache(&fixture.cache);
    desc.max_tiles = nav::MAX_TILES_AT + 1;
    fixture.cache = nav::create_tile_cache(mem, desc, CACHE_BUILD_BYTES)!!;
    fixture.cache.add_tile(flat_layer_blob(0, 0), { .free_data = true })!!;
    fixture.cache.build_tiles_at(x: 0, z: 0, mesh: &fixture.mesh)!!;
    RuntimeSetSnapshot before = snapshot_runtime_set(&fixture.mesh);
    defer destroy_runtime_set_snapshot(&before);
    for (uint layer = 1; layer <= nav::MAX_TILES_AT; layer++) {
        char[] blob = flat_layer_blob(0, 0);
        ((LayerHeader*)blob.ptr).tile_layer = (int)layer;
        fixture.cache.add_tile(blob, { .free_data = true })!!;
    }
    assert(@catch(fixture.cache.build_tiles_at(x: 0, z: 0, mesh: &fixture.mesh)) == c3d::CAPACITY_EXCEEDED);
    assert_runtime_set_unchanged(&fixture.mesh, &before);
}

fn void test_cached_built_job_cannot_publish_after_its_source_becomes_dirty() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    Node* floor = add_plane(fixture, { 8, 8 }, { 2, 0, 2 });
    assert(build_everything(fixture).failed == 0);
    TileRecord* record = &fixture.builder.tiles[0];
    uint revision = record.revision;
    CachedLayerRef ref = record.layers[0];
    char[] data = fixture.builder.cache.tile_by_ref(ref)!!.data;
    char[] cached = copy_runtime_set_bytes(data.ptr, data.len);
    defer free(cached);
    RuntimeSetSnapshot before = snapshot_runtime_set(&fixture.mesh);
    defer destroy_runtime_set_snapshot(&before);
    fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
    TileJob* job = rasterize(fixture);
    nav::build_tile(job)!!;
    floor.local.position.y = 1;
    fixture.scene.update_world();
    fixture.scene.get(floor, NavSource).mark_changed();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    fixture.builder.commit(job)!!;
    assert(record.dirty && !record.pending_layers && record.revision == revision);
    assert(retained_layer_matches(&fixture.builder.cache, ref, cached));
    assert_runtime_set_unchanged(&fixture.mesh, &before);
    NavSyncResult latest = build_everything(fixture);
    assert(latest.failed == 0 && latest.pending == 0 && record.revision == revision + 1);
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly moved = query.find_nearest_poly({ 2, 1, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    assert(moved.point.y > 0.9f);
}
