module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d;
import c3d::nav @public;

struct DetailBuildCounts @private {
    uint vertices;
    uint triangles;
}

fn DetailBuildCounts? build_bounded_ridge_at_capacity(uint vertex_limit, uint triangle_limit) @local {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    for (uint z = 0; z < fixture.compact.height; z++) first_span(&fixture.compact, 6, z).y = 2;
    DetailReference reference = nav::build_detail_reference(&fixture.arena, &fixture.compact, 0)!;
    ContourSet contours = nav::build_contours(
        allocator: &fixture.arena,
        scratch: &fixture.arena,
        compact: &fixture.compact,
        max_error: 0,
        max_edge_length: 0,
    )!;
    PolyMesh mesh = poly_mesh_of(fixture, &contours);
    ushort[] regions = alloc::new_array(&fixture.arena, ushort, fixture.compact.span_count);
    regions[..] = 1;
    TileConfig config = {
        .detail_mode = DetailMode.BOUNDED,
        .max_detail_vertices = vertex_limit,
        .max_detail_triangles = triangle_limit,
    };
    nav::build_poly_details(
        allocator: &fixture.arena,
        mesh: &mesh,
        reference: &reference,
        regions: regions,
        config: &config,
    )!;
    return { .vertices = (uint)mesh.detail.vertices.len, .triangles = (uint)mesh.detail.triangles.len };
}

fn void test_bounded_detail_capacity_limits_are_exact() @test {
    DetailBuildCounts required = build_bounded_ridge_at_capacity(nav::DEFAULT_DETAIL_VERTICES, nav::DEFAULT_DETAIL_TRIANGLES)!!;
    assert(required.vertices > 1 && required.triangles > 1);
    DetailBuildCounts exact = build_bounded_ridge_at_capacity(required.vertices, required.triangles)!!;
    assert(exact.vertices == required.vertices && exact.triangles == required.triangles);
    assert(@catch(build_bounded_ridge_at_capacity(required.vertices - 1, required.triangles)) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(build_bounded_ridge_at_capacity(required.vertices, required.triangles - 1)) == c3d::CAPACITY_EXCEEDED);
}

fn void test_bounded_reference_rechecks_reconstructed_headroom_and_slope() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    CompactHeightfield* compact = &fixture.compact;
    first_span(compact, 4, 3).y = 2;
    first_span(compact, 4, 4).y = 3;
    first_span(compact, 3, 4).y = 4;
    for (int z = 0; z < (int)compact.height; z++) {
        for (int x = 0; x < (int)compact.width; x++) {
            uint index = compact.cells[x + z * (int)compact.width].index;
            for (uint direction = 0; direction < 4; direction++) {
                uint neighbour = nav::neighbour_index(compact: compact, x: x, z: z, index: index, direction: direction);
                if (neighbour == nav::NULL_SPAN) continue;
                if (math::abs((int)compact.spans[index].y - compact.spans[neighbour].y) > 1) {
                    compact.spans[index].set_connection(direction, nav::NOT_CONNECTED);
                }
            }
        }
    }
    uint lowest = compact.cells[3 + 3 * compact.width].index;
    compact.spans[lowest].links.height = 3;
    DetailReference low_ceiling = nav::build_detail_reference(&fixture.arena, compact, 0)!!;
    assert(low_ceiling.samples[lowest].height == 1 && low_ceiling.samples[lowest].corners[2] == 4);
    assert(low_ceiling.samples[lowest].ceiling == 4);
    TileConfig config = { .slope_degrees = 85, .agent_height = 1 };
    nav::classify_detail_reference(&low_ceiling, compact, &config)!!;
    assert(compact.areas[lowest] == nav::NULL_AREA);
    assert(compact.areas[compact.cells[0].index] == nav::WALKABLE_AREA);

    compact.areas[..] = nav::WALKABLE_AREA;
    compact.spans[lowest].links.height = 255;
    DetailReference open_ceiling = nav::build_detail_reference(&fixture.arena, compact, 0)!!;
    nav::classify_detail_reference(&open_ceiling, compact, &config)!!;
    assert(compact.areas[lowest] == nav::WALKABLE_AREA);
    compact.areas[..] = nav::WALKABLE_AREA;
    config.slope_degrees = 45;
    nav::classify_detail_reference(&open_ceiling, compact, &config)!!;
    assert(compact.areas[lowest] == nav::NULL_AREA);
    assert(compact.areas[compact.cells[0].index] == nav::WALKABLE_AREA);
}

fn void test_bounded_flat_reference_retains_a_coarse_fan() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    DetailReference reference = nav::build_detail_reference(&fixture.arena, &fixture.compact, 0)!!;
    ContourSet contours = contours_of(fixture);
    PolyMesh mesh = poly_mesh_of(fixture, &contours);
    ushort[] regions = alloc::new_array(&fixture.arena, ushort, fixture.compact.span_count);
    regions[..] = 1;
    TileConfig config = {
        .detail_mode = DetailMode.BOUNDED,
        .detail_max_error = 0,
        .max_detail_vertices = nav::DEFAULT_DETAIL_VERTICES,
        .max_detail_triangles = nav::DEFAULT_DETAIL_TRIANGLES,
    };
    nav::build_poly_details(
        allocator: &fixture.arena,
        mesh: &mesh,
        reference: &reference,
        regions: regions,
        config: &config,
    )!!;
    assert(mesh.detail.mode == DetailMode.BOUNDED);
    assert(mesh.detail.polygons.len == mesh.poly_count);
    assert(mesh.detail.vertices.len == 0 && mesh.detail.triangles.len == 0);
    char[] blob = alloc::alloc_array(&fixture.arena, char, (sz)nav::tile_mesh_size(&mesh));
    nav::pack_tile_mesh(mesh: &mesh, tile_x: 0, tile_z: 0, blob: blob);
    TileMeshView view = nav::validate_tile_mesh(blob)!!;
    assert(view.header.detail_mode == DetailMode.BOUNDED && view.details.len == 1);
}

fn void test_bounded_detail_preserves_an_interior_ridge() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    for (uint z = 0; z < fixture.compact.height; z++) first_span(&fixture.compact, 6, z).y = 2;
    DetailReference reference = nav::build_detail_reference(&fixture.arena, &fixture.compact, 0)!!;
    ContourSet contours = nav::build_contours(
        allocator: &fixture.arena,
        scratch: &fixture.arena,
        compact: &fixture.compact,
        max_error: 0,
        max_edge_length: 0,
    )!!;
    PolyMesh mesh = poly_mesh_of(fixture, &contours);
    ushort[] regions = alloc::new_array(&fixture.arena, ushort, fixture.compact.span_count);
    regions[..] = 1;
    TileConfig config = {
        .detail_mode = DetailMode.BOUNDED,
        .detail_max_error = 0,
        .max_detail_vertices = nav::DEFAULT_DETAIL_VERTICES,
        .max_detail_triangles = nav::DEFAULT_DETAIL_TRIANGLES,
    };
    nav::build_poly_details(
        allocator: &fixture.arena,
        mesh: &mesh,
        reference: &reference,
        regions: regions,
        config: &config,
    )!!;
    assert(mesh.detail.vertices.len > 0 && mesh.detail.triangles.len > 0);
    char[] blob = alloc::alloc_array(&fixture.arena, char, (sz)nav::tile_mesh_size(&mesh));
    nav::pack_tile_mesh(mesh: &mesh, tile_x: 0, tile_z: 0, blob: blob);
    TileMeshView view = nav::validate_tile_mesh(blob)!!;
    assert(view.header.detail_triangle_count == mesh.detail.triangles.len);
    bool sampled;
    foreach (range : mesh.detail.polygons) {
        foreach (triangle : mesh.detail.triangles[range.triangle_base:range.triangle_count]) {
            Vec3 first = mesh.detail.vertices[range.vertex_base + triangle.vertices[0]];
            Vec3 second = mesh.detail.vertices[range.vertex_base + triangle.vertices[1]];
            Vec3 third = mesh.detail.vertices[range.vertex_base + triangle.vertices[2]];
            if (try point = nav::detail_triangle_surface(
                first: first,
                second: second,
                third: third,
                position: { 6.5f, 0, 3.5f },
            )) {
                assert(math::abs(point.height + mesh.detail.origin.y - 2) < 1e-5);
                sampled = true;
            }
        }
    }
    assert(sampled);
}

fn void test_bounded_fan_rejects_a_reference_hole() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    DetailReference reference = nav::build_detail_reference(&fixture.arena, &fixture.compact, 0)!!;
    ContourSet contours = contours_of(fixture);
    PolyMesh mesh = poly_mesh_of(fixture, &contours);
    ushort[] regions = alloc::new_array(&fixture.arena, ushort, fixture.compact.span_count);
    regions[..] = 1;
    regions[fixture.compact.cells[3 + 3 * fixture.compact.width].index] = 0;
    TileConfig config = {
        .detail_mode = DetailMode.BOUNDED,
        .max_detail_vertices = nav::DEFAULT_DETAIL_VERTICES,
        .max_detail_triangles = nav::DEFAULT_DETAIL_TRIANGLES,
    };
    if (catch excuse = nav::build_poly_details(
        allocator: &fixture.arena,
        mesh: &mesh,
        reference: &reference,
        regions: regions,
        config: &config,
    )) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(mesh.detail.mode == DetailMode.COARSE);
}

fn void test_bounded_config_rejects_nonfinite_active_fields() @test {
    NavBuildConfig config = nav::default_nav_build_config();
    config.detail_max_error = float::nan;
    (void)nav::tile_config(config)!!;
    config.detail_mode = DetailMode.BOUNDED;
    if (catch excuse = nav::tile_config(config)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    config = nav::default_nav_build_config();
    config.cell_size = float::nan;
    if (catch excuse = nav::tile_config(config)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
}

fn void test_bounded_source_rejects_bad_active_triangles_before_mutation() @test {
    Heightfield field = heightfield(width: 4, height: 4, layers: 8, cell_size: 1, cell_height: 0.1f);
    defer nav::destroy_heightfield(&field);
    Vec3[4] positions = { { 0, 0.2f, 0 }, { 3, 0.2f, 0 }, { 0, 0.2f, 3 }, { float::nan, 0, 0 } };
    uint[3] indices = { 0, 1, 2 };
    char[1] areas = { nav::WALKABLE_AREA };
    field.rasterize_triangles(positions: positions[..], indices: indices[..], areas: areas[..])!!;
    uint spans = field.pool.high_water;
    assert(spans > 0);
    indices[2] = 3;
    if (catch excuse = field.rasterize_triangles(positions: positions[..], indices: indices[..], areas: areas[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(field.pool.high_water == spans);
    indices[2] = 4;
    if (catch excuse = field.rasterize_triangles(positions: positions[..], indices: indices[..], areas: areas[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(field.pool.high_water == spans);
}
