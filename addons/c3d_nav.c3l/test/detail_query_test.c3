module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const float DETAIL_QUERY_TOLERANCE @private = 0.00001f;

fn char[] detail_runtime_mesh(Vec3 origin = {}, bool boundary_ridge = false, bool border = false) @private {
    ushort[12] vertices = { 0, 0, 0, 0, 0, 2, 2, 0, 2, 2, 0, 0 };
    ushort[12] polygons;
    polygons[..] = nav::MESH_NULL_INDEX;
    polygons[:4] = (ushort[4]){ 0, 1, 2, 3 }[..];
    ushort[1] regions;
    ushort[1] flags = { nav::POLY_FLAG_WALK };
    char[1] areas = { nav::WALKABLE_AREA };
    DetailPortal[4] portals;
    if (border) {
        polygons[9] = nav::PORTAL_EDGE | 3;
        for (usz vertex = 0; vertex < 4; vertex++) {
            vertices[vertex * 3] *= 2;
            vertices[vertex * 3 + 2] *= 2;
            float height = vertex == 0 || vertex == 3 ? 0.25f : 0.75f;
            portals[vertex] = {
                .edge = 3,
                .min = (float)vertex * 0.25f,
                .max = (float)(vertex + 1) * 0.25f,
                .source_height = height,
                .target_height = height,
            };
        }
    }
    Vec3[6] detail_vertices = {
        { 0, 0, 0 }, { 2, 0, 0 }, { 2, 0, 2 }, { 0, 0, 2 }, { 1, 1, 1 }, { 1, 1, 1 },
    };
    DetailTriangle[5] triangles = {
        { .vertices = { 0, 1, 4 }, .boundary_edges = 1 },
        { .vertices = { 1, 2, 4 }, .boundary_edges = 1 },
        { .vertices = { 2, 3, 4 }, .boundary_edges = 1 },
        { .vertices = { 3, 0, 4 }, .boundary_edges = 1 },
        {},
    };
    uint vertex_count = 5;
    uint triangle_count = 4;
    if (boundary_ridge) {
        detail_vertices[4] = { 1, 1, 0 };
        triangles = {
            { .vertices = { 0, 4, 5 }, .boundary_edges = 1 },
            { .vertices = { 4, 1, 5 }, .boundary_edges = 1 },
            { .vertices = { 1, 2, 5 }, .boundary_edges = 1 },
            { .vertices = { 2, 3, 5 }, .boundary_edges = 1 },
            { .vertices = { 3, 0, 5 }, .boundary_edges = 1 },
        };
        vertex_count = 6;
        triangle_count = 5;
    }
    PolyDetail[1] details = { { .vertex_count = vertex_count, .triangle_count = triangle_count } };
    PolyMesh source = {
        .verts = vertices[..],
        .polys = polygons[..],
        .regions = regions[..],
        .flags = flags[..],
        .areas = areas[..],
        .vert_count = 4,
        .poly_count = 1,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds = { .min = origin, .max = origin + (Vec3){ 2, 0.25f, 2 } },
        .cell_size = border ? 0.5f : 1.0f,
        .cell_height = 1,
        .detail = {
            .mode = DetailMode.BOUNDED,
            .origin = origin,
            .polygons = details[..],
            .vertices = detail_vertices[:vertex_count],
            .triangles = triangles[:triangle_count],
            .portals = portals[:border ? 4 : 0],
        },
    };
    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&source));
    nav::pack_tile_mesh(
        mesh: &source,
        tile_x: 0,
        tile_z: 0,
        blob: blob,
    );
    return blob;
}

fn TileDataParams detail_runtime_params(bool bv_tree = true, int layer = 0) @private {
    return {
        .tile_layer = layer,
        .walkable_height = 1,
        .walkable_climb = 0.1f,
        .build_bv_tree = bv_tree,
    };
}

fn char[] detail_border_strips(bool bounded = true) @private {
    ushort[4 * 12] vertices;
    ushort[4 * 12] polygons;
    polygons[..] = nav::MESH_NULL_INDEX;
    ushort[4] regions;
    ushort[4] flags;
    char[4] areas;
    areas[..] = nav::WALKABLE_AREA;
    PolyDetail[4] details;
    DetailPortal[4] portals;
    for (uint index = 0; index < 4; index++) {
        ushort low = (ushort)index;
        ushort high = low + 1;
        ushort low_height = math::min(low, (ushort)(4 - low));
        ushort high_height = math::min(high, (ushort)(4 - high));
        ushort[12] corners = {
            low, low_height, 0, low, low_height, 4,
            high, high_height, 4, high, high_height, 0,
        };
        vertices[index * 12:12] = corners[..];
        for (uint vertex = 0; vertex < 4; vertex++) polygons[index * 12 + vertex] = (ushort)(index * 4 + vertex);
        polygons[index * 12 + 6] = index ? (ushort)(index - 1) : nav::MESH_NULL_INDEX;
        polygons[index * 12 + 7] = nav::PORTAL_EDGE | 1;
        polygons[index * 12 + 8] = index < 3 ? (ushort)(index + 1) : nav::MESH_NULL_INDEX;
        float height = ((float)low_height + high_height) * 0.25f;
        portals[index] = {
            .polygon = index,
            .edge = 1,
            .max = 1,
            .source_height = height,
            .target_height = height,
        };
    }
    PolyMesh source = {
        .verts = vertices[..],
        .polys = polygons[..],
        .regions = regions[..],
        .flags = flags[..],
        .areas = areas[..],
        .vert_count = 16,
        .poly_count = 4,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds = { .min = { 0, 0, -2 }, .max = { 2, 1, 0 } },
        .cell_size = 0.5f,
        .cell_height = 0.5f,
        .detail = {
            .mode = bounded ? DetailMode.BOUNDED : DetailMode.COARSE,
            .origin = { 0, 0, -2 },
            .polygons = details[:bounded ? 4 : 0],
            .portals = portals[:bounded ? 4 : 0],
        },
    };
    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&source));
    nav::pack_tile_mesh(
        mesh: &source,
        tile_x: 0,
        tile_z: -1,
        blob: blob,
    );
    return blob;
}

fn void test_detail_matching_border_profiles_connect_different_polygon_subdivisions() @test {
    foreach (bool reverse : { false, true }) {
        char[] ridge = detail_runtime_mesh(boundary_ridge: true, border: true);
        defer free(ridge);
        char[] strips = detail_border_strips();
        defer free(strips);
        NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2 })!!;
        defer nav::destroy_nav_mesh(&mesh);
        TileDataParams ridge_params = detail_runtime_params();
        TileDataParams strip_params = detail_runtime_params();
        strip_params.tile_z = -1;
        if (reverse) {
            mesh.add_tile_mesh(strips, {}, strip_params)!!;
            mesh.add_tile_mesh(ridge, {}, ridge_params)!!;
        } else {
            mesh.add_tile_mesh(ridge, {}, ridge_params)!!;
            mesh.add_tile_mesh(strips, {}, strip_params)!!;
        }
        MeshTile* ridge_tile = mesh.tile_at(0, 0, 0);
        MeshTile* strip_tile = mesh.tile_at(0, -1, 0);
        uint linked;
        for (uint link = ridge_tile.polys[0].first_link; link != nav::NULL_LINK; link = mesh.links[link].next) {
            if (mesh.links[link].side == 6) linked++;
        }
        assert(linked == 4);
        foreach (&poly : strip_tile.polys) {
            bool reciprocal;
            for (uint link = poly.first_link; link != nav::NULL_LINK; link = mesh.links[link].next) {
                if (mesh.links[link].side == 2) reciprocal = true;
            }
            assert(reciprocal);
        }
    }
}

fn void test_precision_portal_provenance_keeps_a_rejected_fragment_blocked() @test {
    char[] ridge = detail_runtime_mesh(boundary_ridge: true, border: true);
    defer free(ridge);
    char[] strips = detail_border_strips();
    defer free(strips);
    TileMeshView strip_view = nav::tile_mesh_view(strips);
    strip_view.detail_portals[1].source_height += 0.0001f;
    strip_view.detail_portals[1].target_height += 0.0001f;
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileDataParams strip_params = detail_runtime_params();
    strip_params.tile_z = -1;
    TileRef ridge_ref = mesh.add_tile_mesh(ridge, {}, detail_runtime_params())!!;
    mesh.add_tile_mesh(strips, {}, strip_params)!!;
    PolyRef ref = mesh.poly_ref_base(mesh.tile_by_ref(ridge_ref)!!);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    Vec3 start = { 0.75f, 0.75f, 0.05f };
    Vec3 end = { 0.75f, 0.75f, -0.05f };
    PolyRef[8] path;

    RaycastHit ray = query.raycast(
        start_ref: ref,
        start: start,
        end: end,
        filter: &filter,
        out_path: path[..],
    )!!;
    assert(math::abs(ray.t - 0.5f) < DETAIL_QUERY_TOLERANCE);
    MoveResult moved = query.move_along_surface_projected(
        start_ref: ref,
        start: start,
        end: end,
        filter: &filter,
        out_visited: path[..],
    )!!;
    assert(moved.end_ref == ref && moved.position.z == 0 && moved.position.y == 0.75f);
    WallHit wall = query.find_distance_to_wall(
        start_ref: ref,
        center: start,
        max_radius: 0.2f,
        filter: &filter,
    )!!;
    assert(math::abs(wall.distance - 0.05f) < DETAIL_QUERY_TOLERANCE && wall.point.y == 0.75f);
    WallSegment[16] segments;
    QueryResult result = query.poly_wall_segments(ref, &filter, segments[..])!!;
    bool found_wall;
    foreach (segment : segments[:result.count]) {
        if (segment.neighbour || segment.start.z != 0 || segment.end.z != 0) continue;
        if (math::min(segment.start.x, segment.end.x) <= 0.75f
            && math::max(segment.start.x, segment.end.x) >= 0.75f) found_wall = true;
    }
    assert(found_wall && !result.truncated);
}

fn void test_precision_portals_retain_intervals_smaller_than_a_byte_step() @test {
    char[] ridge = detail_runtime_mesh(boundary_ridge: true, border: true);
    defer free(ridge);
    TileMeshView ridge_view = nav::tile_mesh_view(ridge);
    ridge_view.detail_portals[2].min = 0.6249f;
    ridge_view.detail_portals[2].max = 0.6251f;
    char[] strips = detail_border_strips();
    defer free(strips);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileDataParams strip_params = detail_runtime_params();
    strip_params.tile_z = -1;
    TileRef ridge_ref = mesh.add_tile_mesh(ridge, {}, detail_runtime_params())!!;
    TileRef strip_ref = mesh.add_tile_mesh(strips, {}, strip_params)!!;
    PolyRef from = mesh.poly_ref_base(mesh.tile_by_ref(ridge_ref)!!);
    PolyRef to = mesh.poly_ref_base(mesh.tile_by_ref(strip_ref)!!) | (PolyRef)1;
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    PolyRef[8] path;
    RaycastHit inside = query.raycast(
        start_ref: from,
        start: { 0.75f, 0.75f, 0.01f },
        end: { 0.75f, 0.75f, -0.01f },
        filter: &filter,
        out_path: path[..],
    )!!;
    assert(inside.t > 1 && inside.path_count == 2 && path[1] == to);
    RaycastHit outside = query.raycast(
        start_ref: from,
        start: { 0.751f, 0.751f, 0.01f },
        end: { 0.751f, 0.751f, -0.01f },
        filter: &filter,
        out_path: path[..],
    )!!;
    assert(outside.t < 1);
    RaycastHit reverse = query.raycast(
        start_ref: to,
        start: { 0.75f, 0.75f, -0.01f },
        end: { 0.75f, 0.75f, 0.01f },
        filter: &filter,
        out_path: path[..],
    )!!;
    assert(reverse.t > 1 && reverse.path_count == 2 && path[1] == from);
}

fn void test_precision_neighbor_mismatch_preserves_resident_tiles() @test {
    char[] ridge = detail_runtime_mesh(boundary_ridge: true, border: true);
    defer free(ridge);
    char[] strips = detail_border_strips();
    defer free(strips);
    char[] legacy = detail_border_strips(false);
    defer free(legacy);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef ridge_ref = mesh.add_tile_mesh(ridge, {}, detail_runtime_params())!!;
    MeshTile* resident = mesh.tile_by_ref(ridge_ref)!!;
    char* bytes = resident.data.ptr;
    uint free_links = mesh.free_links();
    TileDataParams params = detail_runtime_params();
    params.tile_z = -1;
    params.walkable_height = 2;
    assert(@catch(mesh.add_tile_mesh(strips, {}, params)) == c3d::INVALID_ARGUMENT);
    params.walkable_height = 1;
    assert(@catch(mesh.add_tile_mesh(legacy, {}, params)) == c3d::INVALID_ARGUMENT);
    assert(resident.data.ptr == bytes && mesh.free_links() == free_links && !mesh.tile_at(0, -1, 0));
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
        PolyRef[1] refs;
        QueryResult result = query.query_polygons(
            center: { 1, 1, 1 },
            half_extents: { 0.01f, 0.01f, 0.01f },
            filter: &filter,
            out_refs: refs[..],
        )!!;
        assert(result.count == 1 && refs[0] == ref);
        assert(@catch(query.find_nearest_poly({ 1, 2, 1 }, { 0.01f, 0.01f, 0.01f }, &filter)) == nav::NO_POLY);
        QueryResult outside = query.query_polygons(
            center: { 1, 2, 1 },
            half_extents: { 0.01f, 0.01f, 0.01f },
            filter: &filter,
            out_refs: refs[..],
        )!!;
        assert(outside.count == 0);
    }
}

fn void test_detail_closest_boundary_follows_the_retained_chain() @test {
    char[] source = detail_runtime_mesh(boundary_ridge: true);
    defer free(source);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef tile_ref = mesh.add_tile_mesh(source, {}, detail_runtime_params())!!;
    PolyRef ref = mesh.poly_ref_base(mesh.tile_by_ref(tile_ref)!!);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);

    ClosestPoint closest = query.closest_point_on_poly(ref, { 1, 9, -1 })!!;
    assert(!closest.over_poly && closest.point == (Vec3){ 1, 1, 0 });
    assert(query.closest_point_on_poly_boundary(ref, { 1, 9, -1 })!! == closest.point);
    assert(query.poly_height(ref, { 1, 0, 0 })!! == 1);
}

fn void test_detail_off_mesh_landings_include_height_extrema() @test {
    char[] source = detail_runtime_mesh();
    defer free(source);
    OffMeshConnectionDesc[1] connections = { {
        .start = { 1, 1, 1 },
        .end = { 1, 0.5f, 0.5f },
        .radius = 0.1f,
        .flags = nav::POLY_FLAG_WALK,
        .bidirectional = true,
    } };
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef tile_ref = mesh.add_tile_mesh(source, connections[..], detail_runtime_params())!!;
    MeshTile* tile = mesh.tile_by_ref(tile_ref)!!;
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    PolyRef base = mesh.poly_ref_base(tile);

    assert(tile.header.off_mesh_count == 1);
    assert(tile.verts[tile.polys[1].verts[0]] == connections[0].start);
    assert(tile.verts[tile.polys[1].verts[1]] == connections[0].end);
    assert(tile.polys[1].first_link != nav::NULL_LINK);
    assert(query.poly_height(base | (PolyRef)1, { 1, 0, 0.75f })!! == 0.75f);
    assert(@catch(query.poly_surface(base | (PolyRef)1, { 1, 0, 0.75f })) == c3d::INVALID_ARGUMENT);
}

fn void test_detail_nearest_ties_do_not_depend_on_installation_order() @test {
    foreach (bool reverse : { false, true }) {
        char[] source = detail_runtime_mesh();
        defer free(source);
        NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2 })!!;
        defer nav::destroy_nav_mesh(&mesh);
        mesh.add_tile_mesh(source, {}, detail_runtime_params(layer: reverse ? 1 : 0))!!;
        mesh.add_tile_mesh(source, {}, detail_runtime_params(layer: reverse ? 0 : 1))!!;
        NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
        defer nav::destroy_nav_query(&query);
        QueryFilter filter = nav::default_query_filter();

        NearestPoly nearest = query.find_nearest_poly({ 1, 1, 1 }, { 0.1f, 0.1f, 0.1f }, &filter)!!;
        assert(mesh.tile_and_poly(nearest.ref)!!.tile.header.layer == 0);
    }
}

fn void test_projected_movement_reports_the_end_polygon_when_visited_is_empty() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    NearestPoly first = level.query.find_nearest_poly({ 1, 0, 1 }, { 1, 1, 1 }, &level.filter)!!;
    NearestPoly last = level.query.find_nearest_poly({ 1, 0, 18 }, { 1, 1, 1 }, &level.filter)!!;
    MoveResult result = level.query.move_along_surface_projected(
        start_ref: first.ref,
        start: first.point,
        end: { 1, 99, 18 },
        filter: &level.filter,
        out_visited: {},
    )!!;
    assert(result.end_ref == last.ref && result.position == (Vec3){ 1, 0, 18 });
    assert(result.truncated && result.visited_count == 0);
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

fn void test_corridor_projection_failure_preserves_its_resident_state() @test {
    HandLevel* level = hall_level();
    defer destroy_hand_level(level);
    NearestPoly first = level.query.find_nearest_poly({ 1, 0, 1 }, { 1, 1, 1 }, &level.filter)!!;
    PathCorridor corridor = nav::create_path_corridor(mem, 1)!!;
    defer nav::destroy_path_corridor(&corridor);
    corridor.reset(first.ref, first.point);
    Vec3 target = corridor.target;

    assert(@catch(corridor.move_position({ 1, 0, 18 }, &level.query, &level.filter)) == c3d::CAPACITY_EXCEEDED);
    assert(corridor.position == first.point && corridor.target == target);
    assert(corridor.count == 1 && corridor.path[0] == first.ref);
    assert(@catch(corridor.move_target_position({ 1, 0, 18 }, &level.query, &level.filter)) == c3d::CAPACITY_EXCEEDED);
    assert(corridor.position == first.point && corridor.target == target && corridor.path[0] == first.ref);
}

fn void test_detail_origin_shift_preserves_local_arrays_and_queries() @test {
    Vec3 origin = { 100000, 0, 100000 };
    char[] source = detail_runtime_mesh(origin);
    defer free(source);
    NavMesh mesh = nav::create_nav_mesh(mem, { .origin = origin, .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef tile_ref = mesh.add_tile_mesh(source, {}, detail_runtime_params())!!;
    MeshTile* tile = mesh.tile_by_ref(tile_ref)!!;
    PolyRef ref = mesh.poly_ref_base(tile);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    Vec3[5] before;
    before[..] = tile.detail_vertices[..];
    SurfacePoint surface = query.poly_surface(ref, origin + (Vec3){ 1, 0, 0.5f })!!;

    mesh.shift_origin(origin);

    assert(mesh.is_valid_ref(ref) && tile.header.detail_origin == (Vec3){});
    foreach (index, vertex : before) assert(vertex == tile.detail_vertices[index]);
    SurfacePoint shifted = query.poly_surface(ref, { 1, 0, 0.5f })!!;
    assert(shifted.height == surface.height && shifted.normal == surface.normal);
}

fn void test_detail_invalid_runtime_ranges_reject_before_installation() @test {
    char[] source = detail_runtime_mesh();
    defer free(source);
    TileMeshView view = nav::tile_mesh_view(source);
    TileDataParams params = detail_runtime_params();
    char[] data = mem::new_array(char, (sz)nav::tile_data_size(view, {}, params));
    defer free(data);
    nav::create_tile_data(
        mesh: view,
        connections: {},
        params: params,
        blob: data,
    )!!;
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileHeader* header = (TileHeader*)data.ptr;
    header.detail_vertex_count = uint::max;
    assert(@catch(mesh.add_tile(data, {})) == c3d::INVALID_ARGUMENT);
    header.detail_vertex_count = 5;
    header.version--;
    assert(@catch(mesh.add_tile(data, {})) == c3d::INVALID_ARGUMENT);
    header.version++;
    MeshTile decoded;
    nav::carve_tile_data(&decoded, data);
    decoded.details[0].triangle_count = uint::max;
    assert(@catch(mesh.add_tile(data, {})) == c3d::INVALID_ARGUMENT);
    decoded.details[0].triangle_count = 4;
    decoded.detail_triangles[0].vertices[0] = ushort::max;
    assert(@catch(mesh.add_tile(data, {})) == c3d::INVALID_ARGUMENT);
    assert(!mesh.tile_at(0, 0, 0));
}

fn void test_detail_failed_replacement_preserves_resident_geometry() @test {
    char[] source = detail_runtime_mesh();
    defer free(source);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileDataParams params = detail_runtime_params();
    TileRef tile_ref = mesh.add_tile_mesh(source, {}, params)!!;
    MeshTile* resident = mesh.tile_by_ref(tile_ref)!!;
    PolyRef ref = mesh.poly_ref_base(resident);
    char* data = resident.data.ptr;
    uint free_links = mesh.free_links();
    TileMeshView view = nav::tile_mesh_view(source);
    view.detail_triangles[0].vertices[0] = ushort::max;

    assert(@catch(mesh.install_tile_mesh(source, {}, params)) == c3d::INVALID_ARGUMENT);
    assert(mesh.is_valid_ref(ref) && resident.data.ptr == data && mesh.free_links() == free_links);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    assert(query.poly_height(ref, { 1, 0, 1 })!! == 1);
}

fn void test_detail_analytic_plane_normals_and_selected_query_fields() @test {
    Vec3 origin = { -20, 0, -30 };
    char[] source = detail_runtime_mesh(origin);
    defer free(source);
    TileMeshView view = nav::tile_mesh_view(source);
    foreach (&vertex : view.detail_vertices) vertex.y = 0.25f * vertex.x + 0.125f * vertex.z;
    NavMesh mesh = nav::create_nav_mesh(mem, { .origin = origin, .tile_width = 2, .tile_height = 2, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef tile_ref = mesh.add_tile_mesh(source, {}, detail_runtime_params())!!;
    PolyRef ref = mesh.poly_ref_base(mesh.tile_by_ref(tile_ref)!!);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    Vec3 expected_normal = (Vec3){ -0.25f, 1, -0.125f }.normalize();
    Vec3[4] positions = { { 0.75f, 0, 1.25f }, { 1, 0, 1 }, { 0.5f, 0, 0.5f }, { 1.5f, 0, 0.5f } };
    foreach (position : positions) {
        SurfacePoint surface = query.poly_surface(ref, origin + position)!!;
        assert(math::abs(surface.height - (0.25f * position.x + 0.125f * position.z)) < DETAIL_QUERY_TOLERANCE);
        assert((surface.normal - expected_normal).length() < DETAIL_QUERY_TOLERANCE);
        assert(query.poly_height(ref, origin + position)!! == surface.height);
    }
    foreach (float invalid : { float::nan, float::inf, -float::inf }) {
        assert(@catch(query.poly_surface(ref, { invalid, 0, -29 })) == c3d::INVALID_ARGUMENT);
        assert(@catch(query.poly_height(ref, { -19, 0, invalid })) == c3d::INVALID_ARGUMENT);
        assert(@catch(query.find_nearest_poly({ -19, invalid, -29 }, { 1, 1, 1 }, &filter)) == c3d::INVALID_ARGUMENT);
    }
    SurfacePoint inactive_y = query.poly_surface(ref, { -19, float::nan, -29 })!!;
    assert(inactive_y.height == 0.375f);
}
