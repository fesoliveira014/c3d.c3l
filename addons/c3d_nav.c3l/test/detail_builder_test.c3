module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d;
import c3d::maths;
import c3d::nav @public;

fn NavBuildConfig bounded_scene_config() @private {
    NavBuildConfig config = nav::default_nav_build_config();
    config.cell_size = 0.5f;
    config.cell_height = 0.05f;
    config.tile_size = 8;
    config.agent_height = 1;
    config.agent_radius = 0;
    config.agent_max_climb = 0.3f;
    config.agent_max_slope_degrees = 60;
    config.region_min_size = 0;
    config.region_merge_size = 0;
    config.detail_mode = DetailMode.BOUNDED;
    config.detail_max_error = 0.01f;
    return config;
}

fn void setup_bounded_scene(BuilderFixture* fixture, bool cached, NavBuildConfig config = bounded_scene_config()) @private {
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(2, config), config);
    desc.cache_layers = cached;
    setup_with_desc(fixture, desc);
    add_plane(fixture, { 12, 12 }, { 4, 0, 4 });
    Node* ramp = add_box(fixture, { 3, 0.2f, 6 }, { 4, 0.5f, 4 });
    ramp.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.15f);
    fixture.scene.update_world();
}

fn float[4] bounded_scene_heights(BuilderFixture* fixture) @private {
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 256)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    Vec3[4] points = { { 3.25f, 1, 2.25f }, { 3.25f, 1, 3.25f }, { 4.75f, 1, 4.75f }, { 4.75f, 1, 5.75f } };
    float[4] heights;
    foreach (index, point : points) {
        NearestPoly nearest = query.find_nearest_poly(point, { 0.02f, 2, 0.02f }, &filter)!!;
        SurfacePoint surface = query.poly_surface(nearest.ref, nearest.point)!!;
        assert(math::abs(surface.height - query.poly_height(nearest.ref, nearest.point)!!) < 1e-5);
        assert(math::abs(surface.normal.length() - 1) < 1e-5 && surface.normal.y > 0);
        heights[index] = surface.height;
    }
    return heights;
}

fn void test_bounded_scene_build_installs_refined_tiles() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_scene(fixture, false);
    defer teardown(fixture);
    NavSyncResult result = build_everything(fixture);
    assert(result.failed == 0 && result.pending == 0, "failure %s stage %s", fixture.builder.last_failure.reason, fixture.builder.last_failure.stage);
    uint detail_triangles;
    uint detail_portals;
    foreach (tile : fixture.mesh.tiles) {
        if (!tile.header) continue;
        assert(tile.header.detail_mode == DetailMode.BOUNDED);
        detail_triangles += tile.header.detail_triangle_count;
        detail_portals += tile.header.detail_portal_count;
    }
    assert(detail_triangles > 0 && detail_portals > 0);
    float[4] heights = bounded_scene_heights(fixture);
    assert(math::abs(heights[0] - heights[3]) > 0.2f);
}

fn void test_bounded_cached_scene_preserves_direct_heights() @test {
    BuilderFixture* direct = mem::new(BuilderFixture);
    defer free(direct);
    setup_bounded_scene(direct, false);
    defer teardown(direct);
    BuilderFixture* cached = mem::new(BuilderFixture);
    defer free(cached);
    setup_bounded_scene(cached, true);
    defer teardown(cached);
    NavSyncResult direct_result = build_everything(direct);
    NavSyncResult cached_result = build_everything(cached);
    assert(direct_result.failed == 0 && cached_result.failed == 0,
        "direct %s cached %s stage %s tile %d,%d arena %d/%d",
        direct.builder.last_failure.reason,
        cached.builder.last_failure.reason,
        cached.builder.last_failure.stage,
        cached.builder.last_failure.tile_x,
        cached.builder.last_failure.tile_z,
        cached.builder.cache.arena.used,
        cached.builder.cache.build_scratch.len
    );
    assert(direct_result.pending == 0 && cached_result.pending == 0);
    float[4] direct_heights = bounded_scene_heights(direct);
    float[4] cached_heights = bounded_scene_heights(cached);
    for (uint index = 0; index < direct_heights.len; index++) assert(math::abs(direct_heights[index] - cached_heights[index]) < 1e-5);
    foreach (tile : cached.builder.cache.tiles) {
        if (!tile.header) continue;
        assert(tile.header.detail_mode == DetailMode.BOUNDED && tile.header.reference_bytes > 0);
        DetailReference reference = nav::cached_detail_reference(tile.data)!!;
        uint[] sources = nav::cached_detail_sources(tile.data);
        assert(reference.border_size > 0 && sources.len == (usz)tile.header.width * tile.header.height);
    }
}

fn void test_bounded_crowd_follows_refined_floor_across_tiles() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_bounded_scene(fixture, true);
    defer teardown(fixture);
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0);
    Crowd crowd = nav::create_crowd(
        allocator: mem,
        desc: { .max_agents = 2, .max_agent_radius = 0.15f },
        mesh: &fixture.mesh,
        scene: &fixture.scene,
    )!!;
    defer nav::destroy_crowd(&crowd);
    NavAgentParams params = nav::default_nav_agent_params();
    params.radius = 0.15f;
    params.height = 1;
    params.max_speed = 1;
    uint index = crowd.add_agent({ 3.25f, 1, 2.25f }, params)!!;
    CrowdAgent* agent = crowd.agent(index);
    NearestPoly target = crowd.query.find_nearest_poly({ 4.75f, 1, 5.75f }, { 0.02f, 2, 0.02f }, crowd.filter(0))!!;
    crowd.request_move_target(index, target.ref, target.point);
    float start_height = agent.position.y;
    for (uint update = 0; update < 600; update++) {
        crowd.update(1.0f / 60.0f);
        PolyRef ref = agent.corridor.first_poly();
        float height = crowd.query.poly_height(ref, agent.position)!!;
        assert(math::abs(height - agent.position.y) < 1e-5, "update %d", update);
    }
    assert(xz_distance(agent.position, target.point) < params.radius * 2);
    assert(math::abs(agent.position.y - start_height) > 0.2f);
}

fn void test_bounded_direct_cache_surface_consistency_across_resolutions() @test {
    float[4] sizes = { 0.25f, 0.3f, 0.5f, 1.0f };
    float[4] radii = { 0, 0.1f, 0.25f, 0.49f };
    float[3] errors = { 0, 0.01f, 0.05f };
    foreach (size_index, size : sizes) {
        foreach (radius_index, radius : radii) {
            NavBuildConfig config = bounded_scene_config();
            config.cell_size = size;
            config.tile_size = (uint)math::round(4.0f / size);
            config.agent_radius = radius;
            config.detail_max_error = errors[(size_index + radius_index) % errors.len];
            BuilderFixture* direct = mem::new(BuilderFixture);
            defer free(direct);
            setup_bounded_scene(direct, false, config);
            defer teardown(direct);
            BuilderFixture* cached = mem::new(BuilderFixture);
            defer free(cached);
            setup_bounded_scene(cached, true, config);
            defer teardown(cached);
            NavSyncResult direct_result = build_everything(direct);
            NavSyncResult cached_result = build_everything(cached);
            assert(direct_result.failed == 0 && cached_result.failed == 0,
                "cell %g radius %g error %g direct %s cached %s",
                size, radius, config.detail_max_error, direct.builder.last_failure.reason, cached.builder.last_failure.reason
            );
            NavQuery direct_query = nav::create_nav_query(mem, &direct.mesh, 256)!!;
            defer nav::destroy_nav_query(&direct_query);
            NavQuery cached_query = nav::create_nav_query(mem, &cached.mesh, 256)!!;
            defer nav::destroy_nav_query(&cached_query);
            QueryFilter filter = nav::default_query_filter();
            uint compared;
            foreach (&tile : direct.mesh.tiles) {
                if (!tile.header) continue;
                for (uint polygon = 0; polygon < tile.header.off_mesh_base; polygon++) {
                    Poly* poly = &tile.polys[polygon];
                    Vec3 center;
                    foreach (vertex : poly.verts[:poly.vert_count]) center += tile.verts[vertex];
                    center /= (float)poly.vert_count;
                    PolyRef ref = direct.mesh.poly_ref_base(tile) | (PolyRef)polygon;
                    float direct_height = direct_query.poly_height(ref, center)!!;
                    center.y = direct_height;
                    NearestPoly found = cached_query.find_nearest_poly(center, { 0.0001f, 0.2f, 0.0001f }, &filter)!!;
                    assert(math::abs(found.point.y - direct_height) <= 2 * config.detail_max_error + 1e-5f);
                    compared++;
                }
            }
            assert(compared > 0);
        }
    }
}

fn void test_bounded_prepared_direct_tile_installs_after_large_origin_shift() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuildConfig config = bounded_scene_config();
    config.cell_size = 0.3f;
    config.tile_size = 13;
    setup_bounded_scene(fixture, false, config);
    defer teardown(fixture);
    NavSyncResult built = build_everything(fixture);
    assert(built.failed == 0 && built.pending == 0);
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 256)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly before = query.find_nearest_poly({ 3.25f, 1, 3.25f }, { 0.02f, 2, 0.02f }, &filter)!!;
    SurfacePoint before_surface = query.poly_surface(before.ref, before.point)!!;
    uint free_links = fixture.mesh.free_links();
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
    SurfacePoint shifted_surface = query.poly_surface(before.ref, before.point - offset)!!;
    assert(math::abs(shifted_surface.height - before_surface.height) <= 0.0078125f);
    fixture.builder.commit(prepared)!!;
    NavSyncResult installed = build_everything(fixture);
    assert(installed.failed == 0 && installed.pending == 0, "shifted install %s stage %s tile %d,%d (%d failures)",
        fixture.builder.last_failure.reason, fixture.builder.last_failure.stage,
        fixture.builder.last_failure.tile_x, fixture.builder.last_failure.tile_z, installed.failed);
    assert(fixture.mesh.free_links() == free_links, "shifted border links changed: %d -> %d", free_links, fixture.mesh.free_links());
    NearestPoly after = query.find_nearest_poly(before.point - offset, { 0.02f, 0.1f, 0.02f }, &filter)!!;
    assert(math::abs(after.point.y - before.point.y) <= 0.0078125f);
    char[] candidate = fixture.builder.tile_mesh(0, 0);
    TileMeshHeader* candidate_header = (TileMeshHeader*)candidate.ptr;
    double saved_phase = candidate_header.detail_origin_correction[0];
    candidate_header.detail_origin_correction[0] += 0.001;
    TileDataParams params = {
        .walkable_height = config.agent_height,
        .walkable_radius = config.agent_radius,
        .walkable_climb = config.agent_max_climb,
        .build_bv_tree = true,
    };
    assert(@catch(fixture.mesh.install_tile_mesh(candidate, {}, params)) == c3d::INVALID_ARGUMENT);
    candidate_header.detail_origin_correction[0] = saved_phase;
    assert(fixture.mesh.is_valid_ref(after.ref) && fixture.mesh.free_links() == free_links);
    fixture.scene.shift_origin(-offset);
    fixture.scene.update_world();
    fixture.mesh.shift_origin(-offset);
    fixture.builder.shift_origin(-offset);
    fixture.scene.shift_navigation(-offset);
    query.shift_origin(-offset);
    assert(fixture.mesh.is_valid_ref(after.ref));
    assert(math::abs(query.poly_height(after.ref, before.point)!! - before.point.y) <= 0.0078125f);
    fixture.builder.mark_dirty(fixture.builder.bounds);
    NavSyncResult restored = build_everything(fixture);
    assert(restored.failed == 0 && restored.pending == 0);
    assert(fixture.mesh.free_links() == free_links);
}

fn void check_bounded_link_landings(
    BuilderFixture* fixture,
    NavQuery* query,
    Vec3 start,
    Vec3 end,
    bool bidirectional,
) @local {
    uint connections;
    foreach (&tile : fixture.mesh.tiles) {
        if (!tile.header) continue;
        foreach (connection : tile.off_mesh) {
            Poly* poly = &tile.polys[connection.poly];
            PolyRef ref = fixture.mesh.poly_ref_base(tile) | (PolyRef)connection.poly;
            PolyRef start_landing = link_on_edge(&fixture.mesh, poly, 0);
            PolyRef end_landing = link_on_edge(&fixture.mesh, poly, 1);
            assert(start_landing && end_landing);
            assert(links_to(&fixture.mesh, start_landing, ref));
            assert(links_to(&fixture.mesh, end_landing, ref) == bidirectional);
            Vec3 first = tile.verts[poly.verts[0]];
            Vec3 last = tile.verts[poly.verts[1]];
            assert((first - start).length() < 1e-5 && (last - end).length() < 1e-5);
            assert(math::abs(query.poly_height(start_landing, first)!! - first.y) < 1e-5);
            assert(math::abs(query.poly_height(end_landing, last)!! - last.y) < 1e-5);
            connections++;
        }
    }
    assert(connections == 1);
}

fn void test_bounded_source_links_relink_without_rasterization_and_survive_shift() @test {
    foreach (bool cached : { false, true }) {
        BuilderFixture* fixture = mem::new(BuilderFixture);
        defer free(fixture);
        setup_bounded_scene(fixture, cached);
        defer teardown(fixture);
        NavSyncResult built = build_everything(fixture);
        assert(!built.failed && !built.pending);
        NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 256)!!;
        defer nav::destroy_nav_query(&query);
        QueryFilter filter = nav::default_query_filter();
        Vec3 start = query.find_nearest_poly({ 3.25f, 1, 2.25f }, { 0.02f, 2, 0.02f }, &filter)!!.point;
        Vec3 end = query.find_nearest_poly({ 4.75f, 1, 5.75f }, { 0.02f, 2, 0.02f }, &filter)!!.point;
        Node* node = fixture.scene.add_node()!!;
        fixture.scene.update_world();
        fixture.scene.add_nav_link(node, { .start = start, .end = end, .radius = 0.15f, .area = nav::WALKABLE_AREA, .bidirectional = true })!!;
        NavSyncResult linked = build_everything(fixture);
        assert(linked.failed == 0 && linked.built == 0);
        check_bounded_link_landings(fixture: fixture, query: &query, start: start, end: end, bidirectional: true);

        end = query.find_nearest_poly({ 5, end.y, 5.75f }, { 0.02f, 0.1f, 0.02f }, &filter)!!.point;
        NavLink* link = fixture.scene.get(node, NavLink);
        link.end = end;
        link.bidirectional = false;
        link.mark_changed();
        NavSyncResult relinked = build_everything(fixture);
        assert(relinked.failed == 0 && relinked.built == 0);
        check_bounded_link_landings(fixture: fixture, query: &query, start: start, end: end, bidirectional: false);

        Vec3 offset = { 100000, 0, 100000 };
        fixture.scene.shift_origin(offset);
        fixture.scene.update_world();
        fixture.mesh.shift_origin(offset);
        fixture.builder.shift_origin(offset);
        fixture.scene.shift_navigation(offset);
        query.shift_origin(offset);
        NavSyncResult shifted = build_everything(fixture);
        assert(shifted.failed == 0 && shifted.built == 0);
        check_bounded_link_landings(fixture: fixture, query: &query, start: start - offset, end: end - offset, bidirectional: false);
    }
}
