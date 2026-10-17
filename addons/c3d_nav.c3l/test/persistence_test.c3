module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const char[] PERSISTENCE_LITTLE @local = $embed("fixtures/nav_snapshot_v1_le.bin");
const char[] PERSISTENCE_BIG @local = $embed("fixtures/nav_snapshot_v1_be.bin");
const usz PERSISTENCE_SCRATCH_BYTES @local = 32768;
const usz PERSISTENCE_BLOB_LIMIT @local = 1024 * 1024;
const usz PERSISTENCE_STAGED_LIMIT @local = 8 * 1024 * 1024;
const uint PERSISTENCE_TILES @local = 4;
const usz PERSISTENCE_PATH_CAPACITY @local = 8;

struct PersistenceMutation @local {
    usz offset;
    ulong value;
    usz width;
    fault expected;
}

struct PersistenceQueries @local {
    NavPolyKey[PERSISTENCE_PATH_CAPACITY] path;
    usz path_count;
    Vec3[PERSISTENCE_PATH_CAPACITY] corners;
    char[PERSISTENCE_PATH_CAPACITY] corner_flags;
    usz corner_count;
    SurfacePoint[3] surfaces;
    Vec3 nearest;
    RaycastHit ray;
}

fn NavSnapshotLimits persistence_limits() @local {
    return { .max_blob_bytes = PERSISTENCE_BLOB_LIMIT, .max_staged_bytes = PERSISTENCE_STAGED_LIMIT };
}

fn char[] persistence_tile_mesh(int tile_x, int layer, bool bounded) @local {
    ushort[12] vertices = { 0, 0, 0, 0, 0, 2, 2, 0, 2, 2, 0, 0 };
    ushort[12] polygons;
    polygons[..] = nav::MESH_NULL_INDEX;
    polygons[:4] = (ushort[4]){ 0, 1, 2, 3 }[..];
    bool border = layer == 0 && tile_x < 2;
    uint border_edge = tile_x == 0 ? 2 : 0;
    if (border) polygons[nav::MAX_VERTS_PER_POLY + border_edge] = nav::PORTAL_EDGE | (ushort)(tile_x == 0 ? 2 : 0);

    ushort[1] regions;
    ushort[1] flags = { nav::POLY_FLAG_WALK };
    char[1] areas = { nav::WALKABLE_AREA };
    Vec3 origin = { tile_x * 2.0f, layer * 3.0f, 0 };
    Vec3[4] corners = { { 0, 0, 0 }, { 0, 0, 2 }, { 2, 0, 2 }, { 2, 0, 0 } };
    Vec3[5] detail_vertices = { { 0, 0, 0 }, { 2, 0, 0 }, { 2, 0, 2 }, { 0, 0, 2 }, { 1, 0.25f, 1 } };
    DetailTriangle[4] triangles = {
        { .vertices = { 0, 1, 4 }, .boundary_edges = 1 },
        { .vertices = { 1, 2, 4 }, .boundary_edges = 1 },
        { .vertices = { 2, 3, 4 }, .boundary_edges = 1 },
        { .vertices = { 3, 0, 4 }, .boundary_edges = 1 },
    };
    PolyDetail[1] details = { { .vertex_count = 5, .triangle_count = 4 } };
    DetailPortal[1] portals = { {
        .polygon = 0,
        .edge = border_edge,
        .min = 0.1f,
        .max = 0.9f,
        .kind = HEIGHT_BORDER,
    } };

    PolyMesh source = {
        .verts = vertices[..],
        .polys = polygons[..],
        .regions = regions[..],
        .flags = flags[..],
        .areas = areas[..],
        .vert_count = 4,
        .poly_count = 1,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds = { .min = origin, .max = origin + { 2, 1, 2 } },
        .cell_size = 1,
        .cell_height = 1,
    };
    if (bounded) {
        source.detail = {
            .mode = BOUNDED,
            .origin = origin,
            .source_cell_size = 1,
            .subdivision = 1,
            .corners = corners[..],
            .polygons = details[..],
            .vertices = detail_vertices[..],
            .triangles = triangles[..],
            .portals = border ? portals[..] : (DetailPortal[]){},
        };
    }

    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&source));
    nav::pack_tile_mesh(mesh: &source, tile_x: tile_x, tile_z: 0, blob: blob);
    return blob;
}

fn void fill_persistence_mesh(NavMesh* mesh, bool bounded, bool reverse = false) @local {
    int[4] tile_x = { 0, 0, 1, 2 };
    int[4] layers = { 0, 1, 0, 0 };
    for (uint step = 0; step < PERSISTENCE_TILES; step++) {
        uint index = reverse ? PERSISTENCE_TILES - step - 1 : step;
        int x = tile_x[index];
        int layer = layers[index];
        char[] source = persistence_tile_mesh(x, layer, bounded);
        defer free(source);

        OffMeshConnectionDesc[1] connections = { {
            .start = { 3, 0.4f, 1 },
            .end = { 5, 0.4f, 1 },
            .radius = 0.3f,
            .flags = 8,
            .area = 6,
            .bidirectional = true,
            .user_id = 42,
        } };
        TileRef ref = mesh.add_tile_mesh(
            tile_mesh: source,
            connections: x == 1 && layer == 0 ? connections[..] : (OffMeshConnectionDesc[]){},
            params: {
                .tile_x = x,
                .tile_layer = layer,
                .user_id = 42,
                .walkable_height = 1,
                .walkable_radius = 0.2f,
                .walkable_climb = 0.5f,
                .build_bv_tree = true,
            },
        )!!;
        MeshTile* tile = mesh.tile_by_ref(ref)!!;
        PolyRef polygon = mesh.poly_ref_base(tile);
        mesh.set_poly_flags(polygon, layer == 1 ? 0 : 3)!!;
        mesh.set_poly_area(polygon, (char)(layer == 1 ? 0 : x + 3))!!;
    }
}

fn NavMesh persistence_mesh(Allocator allocator, bool bounded, bool reverse = false) @local {
    NavMesh mesh = nav::create_nav_mesh(allocator, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 8,
        .max_links = 128,
    })!!;
    fill_persistence_mesh(&mesh, bounded, reverse);
    return mesh;
}

fn char[] saved_persistence_mesh(NavMesh* mesh) @local {
    usz size = mesh.snapshot_size()!!;
    char[] bytes = mem::new_array(char, (sz)size);
    char[1024] scratch;
    assert(mesh.write_snapshot(bytes, scratch[..])!! == size);
    return bytes;
}

fn bool same_persistence_key(NavPolyKey first, NavPolyKey second) @local {
    return first.x == second.x && first.z == second.z && first.layer == second.layer && first.polygon == second.polygon;
}

fn PersistenceQueries observe_persistence_mesh(NavMesh* mesh) @local {
    NavQuery query = nav::create_nav_query(mem, mesh, 64)!!;
    defer nav::destroy_nav_query(&query);

    QueryFilter filter = nav::default_query_filter();
    filter.area_cost[4] = 3;
    Vec3 shift = mesh.desc.origin;
    NearestPoly start = query.find_nearest_poly(shift + { 0.5f, 0, 1 }, { 0.1f, 1, 0.1f }, &filter)!!;
    NearestPoly end = query.find_nearest_poly(shift + { 5.5f, 0, 1 }, { 0.1f, 1, 0.1f }, &filter)!!;

    MeshTile* disabled = mesh.tile_at(0, 0, 1);
    assert(!filter.passes(mesh.poly_ref_base(disabled), &disabled.polys[0]));

    PolyRef[PERSISTENCE_PATH_CAPACITY] path;
    PathResult result = query.find_path(
        start_ref: start.ref,
        end_ref: end.ref,
        start: start.point,
        end: end.point,
        filter: &filter,
        out_path: path[..],
    )!!;
    assert(!result.partial && !result.truncated && result.count == 4);

    PersistenceQueries observed = { .path_count = result.count, .nearest = start.point };
    foreach (index, ref : path[:result.count]) observed.path[index] = mesh.poly_key(ref)!!;
    assert(observed.path[2].x == 1 && observed.path[2].polygon == 1);

    StraightPoint[PERSISTENCE_PATH_CAPACITY] corners;
    PathResult straight = query.straight_path(
        start: start.point,
        end: end.point,
        path: path[:result.count],
        out_points: corners[..],
        options: { .all_crossings = true },
    )!!;
    assert(!straight.partial && !straight.truncated);
    observed.corner_count = straight.count;
    foreach (index, corner : corners[:straight.count]) {
        observed.corners[index] = corner.position;
        observed.corner_flags[index] = (char)corner.flags;
    }

    Vec3[3] samples = { { 0.5f, 0, 0.5f }, { 1, 0, 1 }, { 0, 0, 0 } };
    foreach (index, sample : samples) {
        observed.surfaces[index] = query.poly_surface(start.ref, sample + shift)!!;
        assert(observed.surfaces[index].height == query.poly_height(start.ref, sample + shift)!!);
    }

    observed.ray = query.raycast(
        start_ref: start.ref,
        start: start.point,
        end: shift + { 3.5f, 0, 1 },
        filter: &filter,
        out_path: path[..],
        options: { .use_costs = true },
    )!!;
    assert(observed.ray.t == float::max && observed.ray.path_count == 2);
    return observed;
}

fn void compare_persistence_queries(PersistenceQueries first, PersistenceQueries second) @local {
    assert(first.path_count == second.path_count && first.corner_count == second.corner_count);
    for (usz index = 0; index < first.path_count; index++) assert(same_persistence_key(first.path[index], second.path[index]));
    for (usz index = 0; index < first.corner_count; index++) {
        assert(near_point(first.corners[index], second.corners[index]));
        assert(first.corner_flags[index] == second.corner_flags[index]);
    }
    for (usz index = 0; index < first.surfaces.len; index++) {
        assert(math::abs(first.surfaces[index].height - second.surfaces[index].height) < 0.00001f);
        assert(near_point(first.surfaces[index].normal, second.surfaces[index].normal));
    }
    assert(near_point(first.nearest, second.nearest));
    assert(first.ray.t == second.ray.t && first.ray.path_count == second.ray.path_count);
    assert(math::abs(first.ray.cost - second.ray.cost) < 0.0001f);
}

fn void test_persistence_round_trip_queries_state_and_precision() @test {
    foreach (bool bounded : { false, true }) {
        NavMesh mesh = persistence_mesh(mem, bounded);
        defer nav::destroy_nav_mesh(&mesh);
        mesh.shift_origin({ 0.1f, 0, 0.3f });

        PersistenceQueries before = observe_persistence_mesh(&mesh);
        char[] bytes = saved_persistence_mesh(&mesh);
        defer free(bytes);

        TileRef[PERSISTENCE_TILES] old_tiles;
        PolyRef[PERSISTENCE_TILES] old_polygons;
        NavPolyKey[PERSISTENCE_TILES] keys;
        uint count;
        foreach (&tile : mesh.tiles) {
            if (!tile.header) continue;
            old_tiles[count] = mesh.tile_ref(tile);
            old_polygons[count] = mesh.poly_ref_base(tile);
            keys[count] = mesh.poly_key(old_polygons[count])!!;
            count++;
        }

        char[PERSISTENCE_SCRATCH_BYTES] scratch;
        mesh.read_snapshot(bytes, scratch[..], persistence_limits())!!;
        foreach (index, ref : old_polygons) {
            assert(@catch(mesh.tile_by_ref(old_tiles[index])) == nav::INVALID_REF);
            assert(@catch(mesh.tile_and_poly(ref)) == nav::INVALID_REF);
            assert(mesh.is_valid_ref(mesh.resolve_poly_key(keys[index])!!));
        }

        compare_persistence_queries(before, observe_persistence_mesh(&mesh));
        MeshTile* disabled = mesh.tile_at(0, 0, 1);
        assert(disabled.polys[0].flags == 0 && disabled.polys[0].area_type.area == 0);
        MeshTile* linked = mesh.tile_at(1, 0, 0);
        assert(linked.off_mesh[0].user_id == 42 && linked.polys[1].flags == 8 && linked.polys[1].area_type.area == 6);

        char[] restored = saved_persistence_mesh(&mesh);
        defer free(restored);
        assert(same_bytes(bytes, restored));
    }
}

fn void test_persistence_portable_endian_fixtures_and_canonical_ordering() @test {
    foreach (char[] fixture : { PERSISTENCE_LITTLE, PERSISTENCE_BIG }) {
        NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 1, .tile_height = 1, .max_tiles = 2 })!!;
        defer nav::destroy_nav_mesh(&mesh);

        char[256] scratch;
        mesh.read_snapshot(fixture, scratch[..], persistence_limits())!!;

        MeshTile* tile = mesh.tile_at(-2, 3, 4);
        assert(tile && tile.header.user_id == 0x12345678 && tile.polys[0].flags == 0x1234);
        assert(tile.polys[0].area_type.area == 7);

        char[] written = saved_persistence_mesh(&mesh);
        defer free(written);
        assert(same_bytes(written, PERSISTENCE_LITTLE));
    }

    NavMesh first = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&first);
    NavMesh second = nav::create_nav_mesh(mem, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 12,
        .max_links = 512,
    })!!;
    defer nav::destroy_nav_mesh(&second);
    foreach (&tile : second.tiles) tile.salt = 37;
    fill_persistence_mesh(&second, false, true);

    char[] expected = saved_persistence_mesh(&first);
    defer free(expected);
    char[] actual = saved_persistence_mesh(&second);
    defer free(actual);
    assert(same_bytes(expected, actual));

    NavMesh empty = nav::create_nav_mesh(mem, {
        .origin = { 4, 2, 8 },
        .tile_width = 3,
        .tile_height = 5,
        .max_tiles = 1,
    })!!;
    defer nav::destroy_nav_mesh(&empty);
    char[] empty_bytes = saved_persistence_mesh(&empty);
    defer free(empty_bytes);

    PolyRef old_ref = first.poly_ref_base(first.tile_at(0, 0, 0));
    first.read_snapshot(empty_bytes, {}, persistence_limits())!!;
    assert(@catch(first.tile_and_poly(old_ref)) == nav::INVALID_REF);
    foreach (resident : first.tiles) assert(!resident.header);
}

fn void persistence_patch_integer(
    char[] bytes,
    usz offset,
    ulong value,
    usz width,
) @local {
    for (usz index = 0; index < width; index++) bytes[offset + index] = (char)(value >> (index * 8));
}

fn void test_persistence_rejects_malformed_and_incompatible_snapshots() @test {
    NavMesh mesh = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&mesh);
    TileRef live_ref = mesh.tile_ref(mesh.tile_at(0, 0, 0));
    char[PERSISTENCE_SCRATCH_BYTES] scratch;

    assert(@catch(mesh.read_snapshot(PERSISTENCE_LITTLE[:63], scratch[..], persistence_limits())) == nav::INVALID_NAV_SNAPSHOT);
    assert(mesh.tile_by_ref(live_ref)!! != null);

    PersistenceMutation[] mutations = {
        { .offset = 0, .value = 'X', .width = 1, .expected = nav::INVALID_NAV_SNAPSHOT },
        { .offset = 12, .value = 2, .width = 4, .expected = nav::INCOMPATIBLE_NAV_SNAPSHOT },
        { .offset = 80, .value = 64, .width = 8, .expected = nav::INVALID_NAV_SNAPSHOT },
        { .offset = 144, .value = 0x7f800000, .width = 4, .expected = nav::INVALID_NAV_SNAPSHOT },
    };
    char[] mutated = mem::new_array(char, PERSISTENCE_LITTLE.len);
    defer free(mutated);
    foreach (mutation : mutations) {
        mutated[..] = PERSISTENCE_LITTLE[..];
        persistence_patch_integer(
            bytes: mutated,
            offset: mutation.offset,
            value: mutation.value,
            width: mutation.width,
        );
        assert(@catch(mesh.read_snapshot(mutated, scratch[..], persistence_limits())) == mutation.expected);
        assert(mesh.tile_by_ref(live_ref)!! != null);
    }
}

fn void test_persistence_enforces_resource_and_capacity_limits() @test {
    NavMesh source = persistence_mesh(mem, true);
    defer nav::destroy_nav_mesh(&source);
    char[] bytes = saved_persistence_mesh(&source);
    defer free(bytes);
    char[PERSISTENCE_SCRATCH_BYTES] scratch;

    assert(@catch(source.write_snapshot(bytes[:bytes.len - 1], scratch[..])) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(source.write_snapshot(bytes, {})) == c3d::CAPACITY_EXCEEDED);

    NavMesh mesh = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&mesh);
    assert(@catch(mesh.read_snapshot(bytes, {}, persistence_limits())) == c3d::CAPACITY_EXCEEDED);

    NavSnapshotLimits limits = persistence_limits();
    limits.max_blob_bytes = bytes.len - 1;
    assert(@catch(mesh.read_snapshot(bytes, scratch[..], limits)) == c3d::CAPACITY_EXCEEDED);

    limits.max_blob_bytes = bytes.len;
    limits.max_staged_bytes = 64;
    assert(@catch(mesh.read_snapshot(bytes, scratch[..], limits)) == c3d::CAPACITY_EXCEEDED);

    NavMesh small = nav::create_nav_mesh(mem, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 1,
        .max_links = 1,
    })!!;
    defer nav::destroy_nav_mesh(&small);
    assert(@catch(small.read_snapshot(bytes, scratch[..], persistence_limits())) == c3d::CAPACITY_EXCEEDED);
}
