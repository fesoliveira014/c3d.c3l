module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d;
import c3d::nav @public;

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
