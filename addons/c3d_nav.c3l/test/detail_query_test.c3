module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const float DETAIL_QUERY_TOLERANCE @local = 0.00001f;

fn char[] detail_runtime_mesh() @local {
    ushort[12] vertices = { 0, 0, 0, 0, 0, 2, 2, 0, 2, 2, 0, 0 };
    ushort[12] polygons;
    polygons[..] = nav::MESH_NULL_INDEX;
    polygons[:4] = (ushort[4]){ 0, 1, 2, 3 }[..];
    ushort[1] regions;
    ushort[1] flags = { nav::POLY_FLAG_WALK };
    char[1] areas = { nav::WALKABLE_AREA };
    Vec3[5] detail_vertices = { { 0, 0, 0 }, { 2, 0, 0 }, { 2, 0, 2 }, { 0, 0, 2 }, { 1, 1, 1 } };
    DetailTriangle[4] triangles = {
        { .vertices = { 0, 1, 4 }, .boundary_edges = 1 },
        { .vertices = { 1, 2, 4 }, .boundary_edges = 1 },
        { .vertices = { 2, 3, 4 }, .boundary_edges = 1 },
        { .vertices = { 3, 0, 4 }, .boundary_edges = 1 },
    };
    PolyDetail[1] details = { { .vertex_count = 5, .triangle_count = 4 } };
    PolyMesh source = {
        .verts = vertices[..],
        .polys = polygons[..],
        .regions = regions[..],
        .flags = flags[..],
        .areas = areas[..],
        .vert_count = 4,
        .poly_count = 1,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds = { .max = { 2, 0.25f, 2 } },
        .cell_size = 1,
        .cell_height = 1,
        .detail = {
            .mode = DetailMode.BOUNDED,
            .polygons = details[..],
            .vertices = detail_vertices[..],
            .triangles = triangles[..],
        },
    };
    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&source));
    nav::pack_tile_mesh(mesh: &source, tile_x: 0, tile_z: 0, blob: blob);
    return blob;
}

fn TileDataParams detail_runtime_params(bool bv_tree = true) @local {
    return {
        .walkable_height = 1,
        .walkable_climb = 0.1f,
        .build_bv_tree = bv_tree,
    };
}

fn void test_detail_queries_include_interior_extrema_with_and_without_bv() @test {
    foreach (bool bv_tree : { false, true }) {
        char[] source = detail_runtime_mesh();
        defer free(source);
        NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
        defer nav::destroy_nav_mesh(&mesh);
        TileRef tile_ref = mesh.add_tile_mesh(source, {}, detail_runtime_params(bv_tree))!!;
        MeshTile* tile = mesh.tile_by_ref(tile_ref)!!;
        PolyRef ref = mesh.poly_ref_base(tile);
        NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
        defer nav::destroy_nav_query(&query);
        QueryFilter filter = nav::default_query_filter();

        assert(tile.header.bounds.max.y == 1);
        assert(tile.details.len == 1 && tile.detail_vertices.len == 5 && tile.detail_triangles.len == 4);
        SurfacePoint surface = query.poly_surface(ref, { 1, 0, 0.5f })!!;
        assert(math::abs(surface.height - 0.5f) < DETAIL_QUERY_TOLERANCE);
        assert(math::abs(surface.normal.y - math::sqrt(0.5f)) < DETAIL_QUERY_TOLERANCE);
        assert(math::abs(surface.normal.z + math::sqrt(0.5f)) < DETAIL_QUERY_TOLERANCE);
        assert(math::abs(surface.normal.length() - 1) < DETAIL_QUERY_TOLERANCE);
        assert(query.poly_height(ref, { 1, 0, 1 })!! == 1);
        SurfacePoint seam = query.poly_surface(ref, { 1, 0, 1 })!!;
        assert(seam.normal == surface.normal);

        NearestPoly nearest = query.find_nearest_poly({ 1, 1, 1 }, { 0.01f, 0.01f, 0.01f }, &filter)!!;
        assert(nearest.ref == ref && nearest.point.y == 1);
    }
}

fn void test_projected_detail_movement_preserves_the_old_entry_point() @test {
    char[] source = detail_runtime_mesh();
    defer free(source);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef tile_ref = mesh.add_tile_mesh(source, {}, detail_runtime_params())!!;
    PolyRef ref = mesh.poly_ref_base(mesh.tile_by_ref(tile_ref)!!);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    MoveResult legacy = query.move_along_surface(
        start_ref: ref,
        start: { 1, 0.5f, 0.5f },
        end: { 1, 99, 1 },
        filter: &filter,
        out_visited: {},
    )!!;
    MoveResult projected = query.move_along_surface_projected(
        start_ref: ref,
        start: { 1, 0.5f, 0.5f },
        end: { 1, 99, 1 },
        filter: &filter,
        out_visited: {},
    )!!;
    assert(legacy.position.y == 99 && projected.position.y == 1 && projected.end_ref == ref);

    PathCorridor corridor = nav::create_path_corridor(mem, 4)!!;
    defer nav::destroy_path_corridor(&corridor);
    corridor.reset(ref, { 1, 0.5f, 0.5f });
    corridor.move_position({ 1, 99, 1 }, &query, &filter)!!;
    corridor.move_target_position({ 1, 99, 1.5f }, &query, &filter)!!;
    assert(corridor.position.y == 1 && corridor.target.y == 0.5f);
}
