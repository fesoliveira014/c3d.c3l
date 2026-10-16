module c3d_nav_test;

import std::core::mem::allocator;
import c3d;
import c3d::nav @public;

struct CacheAllocationProbe (Allocator) @private {
    Allocator backing;
    uint attempts;
    uint failure;
    uint acquired;
    uint released;
}

fn void*? CacheAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    void* result = self.backing.acquire(size, init_type, alignment)!;
    self.acquired++;
    return result;
}

fn void*? CacheAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void CacheAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.released++;
}

fn void test_bounded_cache_replacement_preserves_all_layers_on_allocation_failure() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1, config), config);
    desc.cache_layers = true;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    add_plane(fixture, { 8, 8 }, { 2, 0, 2 });
    add_plane(fixture, { 8, 8 }, { 2, 3, 2 });
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0, "failure %s stage %s", fixture.builder.last_failure.reason, fixture.builder.last_failure.stage);
    TileRecord* record = &fixture.builder.tiles[0];
    assert(record.layer_count == 2);
    CachedLayerRef[2] refs = { record.layers[0], record.layers[1] };
    char[][2] saved;
    defer {
        foreach (bytes : saved) free(bytes);
    }
    for (uint index = 0; index < refs.len; index++) {
        CachedLayer* layer = fixture.builder.cache.tile_by_ref(refs[index])!!;
        saved[index] = mem::new_array(char, layer.data.len);
        saved[index][..] = layer.data[..];
    }
    uint revision = record.revision;
    uint free_links = fixture.mesh.free_links();
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 128)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly lower = query.find_nearest_poly({ 2, 0, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    NearestPoly upper = query.find_nearest_poly({ 2, 3, 2 }, { 0.1f, 0.5f, 0.1f }, &filter)!!;
    Allocator original = fixture.builder.cache.allocator;
    CacheAllocationProbe probe = { .backing = original };
    fixture.builder.cache.allocator = &probe;
    defer fixture.builder.cache.allocator = original;

    for (uint failure = 1; failure <= refs.len + 1; failure++) {
        fixture.builder.mark_dirty(fixture.builder.tile_bounds(0, 0));
        TileJob* job = rasterize(fixture);
        nav::build_tile(job)!!;
        probe.attempts = 0;
        probe.acquired = 0;
        probe.released = 0;
        probe.failure = failure;
        if (catch excuse = fixture.builder.commit(job)) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false);
        }
        assert(probe.acquired == failure - 1 && probe.released == probe.acquired);
        assert(record.layer_count == refs.len && record.revision == revision && record.dirty);
        for (uint index = 0; index < refs.len; index++) {
            assert(record.layers[index] == refs[index]);
            CachedLayer* layer = fixture.builder.cache.tile_by_ref(refs[index])!!;
            assert(same_bytes(saved[index], layer.data));
        }
        assert(fixture.mesh.free_links() == free_links);
        assert(fixture.mesh.is_valid_ref(lower.ref) && fixture.mesh.is_valid_ref(upper.ref));
        assert(query.poly_height(lower.ref, lower.point)!! == lower.point.y);
        assert(query.poly_height(upper.ref, upper.point)!! == upper.point.y);
    }
    probe.failure = 0;
    TileJob* retry = rasterize(fixture);
    nav::build_tile(retry)!!;
    fixture.builder.commit(retry)!!;
    assert(record.revision == revision && record.layer_count == 2);
    assert(record.layers[0] == refs[0] && record.layers[1] == refs[1]);
    NavSyncResult rebuilt = build_everything(fixture);
    assert(rebuilt.failed == 0 && rebuilt.pending == 0);
    assert(record.revision == revision + 1 && record.layer_count == 2);
    assert(record.layers[0] != refs[0] && record.layers[1] != refs[1]);
}
