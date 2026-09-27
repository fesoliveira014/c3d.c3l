module c3d_nav_test;

import std::core::mem::allocator;
import c3d;
import c3d::maths;
import c3d::nav @public;

const uint  POLY_BORDER @private = 2;
const uint  SPLIT_COLUMN @private = 6; // splits the interior of SQUARE_FLOOR into two regions of one area
const uint  TRIANGLE_VERTS @private = 3;
const int   BLOB_TILE_X @private = 3;
const int   BLOB_TILE_Z @private = -2;
const usz   TINY_MESH_BYTES @private = 64;

fn PolyMesh poly_mesh_of(
    CompactFixture* fixture,
    ContourSet* contours,
    uint verts_per_poly = nav::MAX_VERTS_PER_POLY,
) @private {
    return nav::build_poly_mesh(
        allocator:      &fixture.arena,
        scratch:        &fixture.arena,
        contours:       contours,
        verts_per_poly: verts_per_poly,
    )!!;
}

fn ushort[] mesh_indices(PolyMesh* mesh, uint poly) @private {
    return mesh.polys[(usz)poly * mesh.verts_per_poly * 2:mesh.verts_per_poly];
}

fn ushort[] mesh_neighbours(PolyMesh* mesh, uint poly) @private {
    return mesh.polys[(usz)poly * mesh.verts_per_poly * 2 + mesh.verts_per_poly:mesh.verts_per_poly];
}

fn bool lists_neighbour(ushort[] neighbours, uint poly) @private {
    foreach (neighbour : neighbours) {
        if (neighbour == poly) return true;
    }
    return false;
}

fn ushort split_bordered_region(uint x, uint z, uint size) @private {
    ushort region = bordered_region(x, z, size);
    return region == 1 && x >= SPLIT_COLUMN ? 2 : region;
}

// The side a tile-edge vertex pair lies on, or -1; sides are numbered as rcBuildPolyMesh numbers portals.
fn int shared_side(ushort* start, ushort* end, int size) @private {
    if (start[0] == 0 && end[0] == 0) return 0;
    if ((int)start[2] == size && (int)end[2] == size) return 1;
    if ((int)start[0] == size && (int)end[0] == size) return 2;
    if (start[2] == 0 && end[2] == 0) return 3;
    return -1;
}

fn bool same_ushorts(ushort[] first, ushort[] second) @private {
    if (first.len != second.len) return false;
    foreach (index, value : first) {
        if (value != second[index]) return false;
    }
    return true;
}

fn bool four_byte_aligned(void* pointer, char[] blob) @private => ((usz)pointer - (usz)blob.ptr) % 4 == 0;

fn void test_rectangle_yields_one_polygon() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    ContourSet contours = contours_of(fixture);

    PolyMesh mesh = poly_mesh_of(fixture, &contours);

    assert(mesh.poly_count == 1 && mesh.vert_count == 4);
    assert(mesh.areas[0] == nav::WALKABLE_AREA && mesh.regions[0] == 1 && mesh.flags[0] == 0);
    ushort[] indices = mesh_indices(&mesh, 0);
    assert(nav::count_poly_verts(indices) == 4);
    foreach (unused : indices[4..]) assert(unused == nav::MESH_NULL_INDEX);
    foreach (neighbour : mesh_neighbours(&mesh, 0)) assert(neighbour == nav::MESH_NULL_INDEX);
}

fn void test_polygons_respect_the_vertex_limit_and_link_back() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, L_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    ContourSet contours = contours_of(fixture);

    PolyMesh mesh = poly_mesh_of(fixture, &contours);

    assert(mesh.poly_count >= 2, "an L is not convex");
    usz links;
    for (uint poly = 0; poly < mesh.poly_count; poly++) {
        int count = nav::count_poly_verts(mesh_indices(&mesh, poly));
        assert(count >= 3 && count <= (int)nav::MAX_VERTS_PER_POLY);
        foreach (neighbour : mesh_neighbours(&mesh, poly)[:count]) {
            if (neighbour == nav::MESH_NULL_INDEX) continue;
            assert(neighbour < mesh.poly_count);
            assert(lists_neighbour(mesh_neighbours(&mesh, neighbour), poly));
            links++;
        }
    }
    assert(links > 0);
}

fn void test_triangles_only_when_verts_per_poly_is_three() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, L_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    ContourSet contours = contours_of(fixture);

    PolyMesh mesh = poly_mesh_of(fixture, &contours, TRIANGLE_VERTS);

    assert(contours.contours.len == 1);
    assert(mesh.poly_count == contours.contours[0].verts.len / 4 - 2);
    for (uint poly = 0; poly < mesh.poly_count; poly++) assert(nav::count_poly_verts(mesh_indices(&mesh, poly)) == 3);
}

fn void test_border_vertices_are_removed_and_portals_marked() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, SQUARE_FLOOR);
    defer destroy_compact_fixture(fixture);
    CompactHeightfield* compact = &fixture.compact;
    uint size = SQUARE_FLOOR.len;
    for (uint z = 0; z < size; z++) {
        for (uint x = 0; x < size; x++) first_span(compact, x, z).region = split_bordered_region(x, z, size);
    }
    compact.max_regions = 2;
    compact.border_size = POLY_BORDER;
    ContourSet contours = contours_of(fixture);

    PolyMesh mesh = poly_mesh_of(fixture, &contours);

    int interior = (int)(size - 2 * POLY_BORDER);
    for (uint vertex = 0; vertex < mesh.vert_count; vertex++) {
        int x = mesh.verts[vertex * 3];
        int z = mesh.verts[vertex * 3 + 2];
        if (x == 0 || x == interior) assert(z == 0 || z == interior, "a vertex inside an X side");
        if (z == 0 || z == interior) assert(x == 0 || x == interior, "a vertex inside a Z side");
    }
    bool[4] portal_sides;
    for (uint poly = 0; poly < mesh.poly_count; poly++) {
        ushort[] indices = mesh_indices(&mesh, poly);
        ushort[] neighbours = mesh_neighbours(&mesh, poly);
        int count = nav::count_poly_verts(indices);
        for (int slot = 0; slot < count; slot++) {
            ushort* start = &mesh.verts[indices[slot] * 3];
            ushort* end = &mesh.verts[indices[(slot + 1) % count] * 3];
            int side = shared_side(start, end, interior);
            if (side < 0) continue;
            assert(neighbours[slot] == (nav::PORTAL_EDGE | (ushort)side));
            portal_sides[side] = true;
        }
    }
    foreach (marked : portal_sides) assert(marked);
}

fn void test_tile_mesh_blob_round_trips() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, L_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    ContourSet contours = contours_of(fixture);
    PolyMesh mesh = poly_mesh_of(fixture, &contours);
    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&mesh));
    defer free(blob);

    nav::pack_tile_mesh(
        mesh:   &mesh,
        tile_x: BLOB_TILE_X,
        tile_z: BLOB_TILE_Z,
        blob:   blob,
    );
    TileMeshView view = nav::tile_mesh_view(blob);

    TileMeshHeader* header = view.header;
    assert(header.tile_x == BLOB_TILE_X && header.tile_z == BLOB_TILE_Z);
    assert(header.vert_count == mesh.vert_count && header.poly_count == mesh.poly_count);
    assert(header.verts_per_poly == mesh.verts_per_poly && header.border_size == mesh.border_size);
    assert(header.bounds.min == mesh.bounds.min && header.bounds.max == mesh.bounds.max);
    assert(header.cell_size == mesh.cell_size && header.cell_height == mesh.cell_height);
    assert(header.max_edge_error == mesh.max_edge_error);
    assert(same_ushorts(view.verts, mesh.verts) && same_ushorts(view.polys, mesh.polys));
    assert(same_ushorts(view.regions, mesh.regions) && same_ushorts(view.flags, mesh.flags));
    assert(view.areas.len == mesh.areas.len);
    foreach (index, area : view.areas) assert(area == mesh.areas[index]);
    assert(four_byte_aligned(view.verts.ptr, blob) && four_byte_aligned(view.polys.ptr, blob));
    assert(four_byte_aligned(view.regions.ptr, blob) && four_byte_aligned(view.flags.ptr, blob));
    assert(four_byte_aligned(view.areas.ptr, blob));
    assert((usz)(view.areas.ptr + view.areas.len) <= (usz)(blob.ptr + blob.len));
}

fn void test_poly_mesh_faults_when_the_allocator_is_too_small() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    ContourSet contours = contours_of(fixture);
    char[TINY_MESH_BYTES] small;
    ArenaAllocator output;
    output.init(small[..]);

    fault excuse = @catch(nav::build_poly_mesh(
        allocator:      &output,
        scratch:        &fixture.arena,
        contours:       &contours,
        verts_per_poly: nav::MAX_VERTS_PER_POLY,
    ));
    assert(excuse == c3d::CAPACITY_EXCEEDED);
}
