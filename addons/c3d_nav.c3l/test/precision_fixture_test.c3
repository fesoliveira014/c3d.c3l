module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

fn usz precision_fixture_bytes(BuilderFixture* fixture, char[] output = {}) @local {
    usz offset;
    foreach (record : fixture.builder.tiles) {
        if (fixture.builder.cache_layers) {
            foreach (ref : record.layers[:record.layer_count]) {
                char[] bytes = fixture.builder.cache.tile_by_ref(ref)!!.data;
                if (output.len) output[offset:bytes.len] = bytes[..];
                offset += bytes.len;
            }
        } else {
            if (output.len) output[offset:record.mesh.len] = record.mesh[..];
            offset += record.mesh.len;
        }
    }
    return offset;
}

fn void check_precision_repeatability(BuilderFixture* fixture) @local {
    usz size = precision_fixture_bytes(fixture);
    char[] original = mem::new_array(char, (sz)size);
    defer free(original);
    precision_fixture_bytes(fixture, original);
    char[] repeated = mem::new_array(char, (sz)size);
    defer free(repeated);
    for (uint repetition = 0; repetition < 2; repetition++) {
        fixture.builder.mark_dirty(fixture.builder.bounds);
        NavSyncResult rebuilt = build_everything(fixture);
        assert(rebuilt.failed == 0 && rebuilt.pending == 0);
        assert(precision_fixture_bytes(fixture) == size);
        precision_fixture_bytes(fixture, repeated);
        assert(same_bytes(original, repeated));
    }
}

fn void test_precision_scene_fixtures_match_the_retained_reference() @test {
    foreach (kind : PrecisionFixtureKind::values) {
        BuilderFixture* direct = mem::new(BuilderFixture);
        defer free(direct);
        setup_precision_fixture(fixture: direct, kind: kind, cached: false, mode: DetailMode.BOUNDED);
        defer teardown(direct);
        BuilderFixture* cached = mem::new(BuilderFixture);
        defer free(cached);
        setup_precision_fixture(fixture: cached, kind: kind, cached: true, mode: DetailMode.BOUNDED);
        defer teardown(cached);
        NavSyncResult direct_result = build_everything(direct);
        NavSyncResult cached_result = build_everything(cached);
        assert(!direct_result.failed && !cached_result.failed, "fixture %d direct %s cached %s",
            kind.ordinal, direct.builder.last_failure.reason, cached.builder.last_failure.reason);
        NavQuery direct_query = nav::create_nav_query(mem, &direct.mesh, 256)!!;
        defer nav::destroy_nav_query(&direct_query);
        NavQuery cached_query = nav::create_nav_query(mem, &cached.mesh, 256)!!;
        defer nav::destroy_nav_query(&cached_query);
        QueryFilter filter = nav::default_query_filter();
        uint compared;
        foreach (tile : cached.builder.cache.tiles) {
            if (!tile.header || tile.header.tile_layer != 0) continue;
            DetailReference reference = nav::cached_detail_reference(tile.data)!!;
            foreach (sample : reference.samples) {
                if (sample.area == nav::NULL_AREA) continue;
                uint x = sample.column % reference.width;
                uint z = sample.column / reference.width;
                if (x < reference.border_size || z < reference.border_size
                    || x >= reference.width - reference.border_size || z >= reference.height - reference.border_size) continue;
                Vec3 point = reference.origin + (Vec3){
                    ((float)(x - reference.border_size) + 0.5f) * reference.cell_size,
                    sample.height,
                    ((float)(z - reference.border_size) + 0.5f) * reference.cell_size,
                };
                NearestPoly first = direct_query.find_nearest_poly(point, { 0.0001f, 0.1f, 0.0001f }, &filter)!!;
                NearestPoly second = cached_query.find_nearest_poly(point, { 0.0001f, 0.1f, 0.0001f }, &filter)!!;
                double allowance = cached.builder.config.detail_max_error + 1e-5;
                assert(math::abs((double)first.point.y - point.y) <= allowance);
                assert(math::abs((double)second.point.y - point.y) <= allowance);
                compared++;
            }
        }
        assert(compared >= 256);
        check_precision_repeatability(direct);
        check_precision_repeatability(cached);
    }
}
