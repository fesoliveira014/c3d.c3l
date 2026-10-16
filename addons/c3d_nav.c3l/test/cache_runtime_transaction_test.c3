module c3d_nav_test;

import std::core::mem::allocator;
import c3d;
import c3d::nav @public;
import c3d::scene;

struct CacheAllocationProbe (Allocator) @local {
    Allocator backing;
}

fn void*? CacheAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    return mem::OUT_OF_MEMORY~;
}

fn void*? CacheAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return mem::OUT_OF_MEMORY~;
}

fn void CacheAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
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
    TileRef[2] runtime_refs;
    char[][2] cache_bytes;
    char[][2] runtime_bytes;
    defer {
        foreach (bytes : cache_bytes) free(bytes);
        foreach (bytes : runtime_bytes) free(bytes);
    }
    for (uint layer = 0; layer < 2; layer++) {
        char[] cached = fixture.builder.cache.tile_by_ref(cache_refs[layer])!!.data;
        cache_bytes[layer] = mem::new_array(char, cached.len);
        cache_bytes[layer][..] = cached[..];
        MeshTile* tile = fixture.mesh.tile_at(0, 0, (int)layer);
        runtime_refs[layer] = fixture.mesh.tile_ref(tile);
        runtime_bytes[layer] = mem::new_array(char, tile.data.len);
        runtime_bytes[layer][..] = tile.data[..];
    }
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly lower = query.find_nearest_poly({ 2, 0, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    NearestPoly upper = query.find_nearest_poly({ 2, 3, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    uint before_revision = record.revision;
    uint before_links = fixture.mesh.free_links();
    fixture.scene.remove_later(upper_source);
    fixture.scene.flush_removals();
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* job = rasterize(fixture);
    nav::build_tile(job)!!;
    fixture.builder.commit(job)!!;

    Allocator original = fixture.mesh.allocator;
    CacheAllocationProbe probe = { .backing = original };
    fixture.mesh.allocator = &probe;
    NavSyncResult failed = build_everything(fixture);
    fixture.mesh.allocator = original;
    assert(failed.failed > 0 && fixture.builder.last_failure.stage == BuildStage.INSTALL);
    assert(fixture.builder.last_failure.reason == c3d::CAPACITY_EXCEEDED);
    assert(record.revision == before_revision && record.layer_count == 2);
    assert(fixture.mesh.free_links() == before_links);
    for (uint layer = 0; layer < 2; layer++) {
        assert(same_bytes(cache_bytes[layer], fixture.builder.cache.tile_by_ref(cache_refs[layer])!!.data));
        assert(same_bytes(runtime_bytes[layer], fixture.mesh.tile_by_ref(runtime_refs[layer])!!.data));
    }
    assert(query.poly_height(lower.ref, lower.point)!! == lower.point.y);
    assert(query.poly_height(upper.ref, upper.point)!! == upper.point.y);
    NavSyncResult retried = build_everything(fixture);
    assert(retried.failed == 0 && retried.pending == 0 && record.layer_count == 1);
    assert(fixture.mesh.tile_at(0, 0, 0) && !fixture.mesh.tile_at(0, 0, 1));
}
