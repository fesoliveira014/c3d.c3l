module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d;
import c3d::nav @public;

const char[] PERSISTENCE_LITTLE @local = $embed("fixtures/nav_snapshot_v1_le.bin");
const char[] PERSISTENCE_BIG @local = $embed("fixtures/nav_snapshot_v1_be.bin");
const char[] PERSISTENCE_COARSE_LITTLE @local = $embed("fixtures/nav_snapshot_v1_coarse_le.bin");
const char[] PERSISTENCE_COARSE_BIG @local = $embed("fixtures/nav_snapshot_v1_coarse_be.bin");
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

struct PersistenceAllocation @local {
    void* pointer;
    sz bytes;
}

struct PersistenceAllocator (Allocator) @local {
    Allocator backing;
    PersistenceAllocation[32] allocations;
    usz attempts;
    usz fail_at;
    sz live_bytes;
    sz peak_bytes;
}

fn void*? PersistenceAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.attempts++;
    if (self.fail_at == self.attempts) return mem::OUT_OF_MEMORY~;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    foreach (&entry : self.allocations) {
        if (entry.pointer) continue;
        *entry = { .pointer = pointer, .bytes = size };
        self.live_bytes += size;
        self.peak_bytes = math::max(self.peak_bytes, self.live_bytes);
        return pointer;
    }
    unreachable("fixture allocation table exhausted");
}

fn void*? PersistenceAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return mem::OUT_OF_MEMORY~;
}

fn void PersistenceAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    foreach (&entry : self.allocations) {
        if (entry.pointer != pointer) continue;
        self.live_bytes -= entry.bytes;
        *entry = {};
        self.backing.release(pointer, aligned);
        return;
    }
    unreachable("untracked fixture allocation");
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
    if (try upper = query.find_nearest_poly(shift + { 1, 3, 1 }, { 0.1f, 0.5f, 0.1f }, &filter)) {
        assert(mesh.poly_key(upper.ref)!!.layer == 0);
    }
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
    assert(first.ray.edge == second.ray.edge && first.ray.truncated == second.ray.truncated);
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
        bool correction;
        foreach (&tile : mesh.tiles) {
            if (!tile.header) continue;
            old_tiles[count] = mesh.tile_ref(tile);
            old_polygons[count] = mesh.poly_ref_base(tile);
            keys[count] = mesh.poly_key(old_polygons[count])!!;
            correction |= tile.header.detail_origin_correction[0] != 0 || tile.header.detail_origin_correction[1] != 0;
            count++;
        }
        if (bounded) assert(correction);
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
        assert(linked.off_mesh[0].start.y == 0.4f && linked.verts[linked.polys[1].verts[0]].y != 0.4f);
        char[] restored = saved_persistence_mesh(&mesh);
        defer free(restored);
        assert(same_bytes(bytes, restored));
    }
}

fn void test_persistence_portable_endian_fixtures_and_unaligned_bytes() @test {
    foreach (char[] fixture : { PERSISTENCE_LITTLE, PERSISTENCE_BIG }) {
        NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 1, .tile_height = 1, .max_tiles = 2 })!!;
        defer nav::destroy_nav_mesh(&mesh);
        char[] input = mem::new_array(char, fixture.len + 1);
        defer free(input);
        input[1..] = fixture[..];
        char[256] scratch;
        mesh.read_snapshot(input[1..], scratch[1..], persistence_limits())!!;
        MeshTile* tile = mesh.tile_at(-2, 3, 4);
        assert(tile && tile.header.user_id == 0x12345678 && tile.polys[0].flags == 0x1234);
        assert(tile.polys[0].area_type.area == 7);
        assert(bitcast(tile.header.detail_origin_correction[0], ulong) == bitcast(1e-12, ulong));
        assert(bitcast(tile.header.detail_origin_correction[1], ulong) == bitcast(-2e-12, ulong));
        PolyRef ref = mesh.resolve_poly_key({ .x = -2, .z = 3, .layer = 4 })!!;
        NavQuery query = nav::create_nav_query(mem, &mesh, 16)!!;
        defer nav::destroy_nav_query(&query);
        assert(query.poly_height(ref, { 1, 0, 1 })!! == 0);
        input[..] = 0xcc;
        scratch[..] = 0xcc;
        assert(query.poly_height(ref, { 1, 0, 1 })!! == 0);
        char[] written = saved_persistence_mesh(&mesh);
        defer free(written);
        assert(same_bytes(written, PERSISTENCE_LITTLE));
    }

    foreach (char[] fixture : { PERSISTENCE_COARSE_LITTLE, PERSISTENCE_COARSE_BIG }) {
        NavMesh mesh = nav::create_nav_mesh(mem, {
            .tile_width = 2,
            .tile_height = 2,
            .max_tiles = 1,
            .max_links = 8,
        })!!;
        defer nav::destroy_nav_mesh(&mesh);
        char[] input = mem::new_array(char, fixture.len + 1);
        defer free(input);
        input[1..] = fixture[..];
        char[1024] scratch;
        mesh.read_snapshot(input[1..], scratch[1..], persistence_limits())!!;
        input[..] = 0xcc;
        scratch[..] = 0xcc;
        MeshTile* tile = mesh.tile_at(0, 0, 0);
        assert(tile.header.detail_mode == COARSE && tile.bv_tree.len == 3);
        assert(tile.header.user_id == 0x87654321 && tile.polys[1].flags == 0x0201);
        foreach (node : tile.bv_tree) {
            if (node.index < 0) continue;
            assert(node.min[0] == node.index * 512 && node.max[0] == (node.index + 1) * 512);
            assert(node.min[1] == 0 && node.max[1] == 0 && node.min[2] == 0 && node.max[2] == 1024);
        }
        NavQuery query = nav::create_nav_query(mem, &mesh, 16)!!;
        defer nav::destroy_nav_query(&query);
        QueryFilter filter = nav::default_query_filter();
        NearestPoly nearest = query.find_nearest_poly({ 3.5f, 0, 1 }, { 0.1f, 0.1f, 0.1f }, &filter)!!;
        assert(mesh.poly_key(nearest.ref)!!.polygon == 1);
        char[] canonical = saved_persistence_mesh(&mesh);
        defer free(canonical);
        assert(same_bytes(canonical, PERSISTENCE_COARSE_LITTLE));

        BvNode first_leaf = tile.bv_tree[1];
        tile.bv_tree[1] = tile.bv_tree[2];
        tile.bv_tree[2] = first_leaf;
        char[] reordered = saved_persistence_mesh(&mesh);
        defer free(reordered);
        assert(same_bytes(canonical, reordered));
    }
}

fn void test_persistence_canonical_output_ignores_slots_salts_and_capacity() @test {
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
    char[] guarded = mem::new_array(char, expected.len + 2);
    defer free(guarded);
    guarded[..] = 0x7b;
    char[256] scratch;
    assert(first.write_snapshot(guarded[1:expected.len], scratch[..])!! == expected.len);
    assert(guarded[0] == 0x7b && guarded[^1] == 0x7b);
    assert(same_bytes(expected, guarded[1:expected.len]));
    assert(@catch(first.write_snapshot(guarded[1:expected.len - 1], scratch[..])) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(first.write_snapshot(guarded[1:expected.len], {})) == c3d::CAPACITY_EXCEEDED);
    assert(guarded[0] == 0x7b && guarded[^1] == 0x7b);
    char[] unchanged = saved_persistence_mesh(&first);
    defer free(unchanged);
    assert(same_bytes(expected, unchanged));
}

fn void test_persistence_empty_replacement_and_key_invalidation() @test {
    NavMesh empty = nav::create_nav_mesh(mem, {
        .origin = { 4, 2, 8 },
        .tile_width = 3,
        .tile_height = 5,
        .max_tiles = 1,
    })!!;
    defer nav::destroy_nav_mesh(&empty);
    char[] bytes = saved_persistence_mesh(&empty);
    defer free(bytes);
    assert(bytes.len == 64);
    NavMesh mesh = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&mesh);
    MeshTile* tile = mesh.tile_at(0, 0, 0);
    tile.salt = 65535;
    PolyRef old = mesh.poly_ref_base(tile);
    NavPolyKey key = mesh.poly_key(old)!!;
    char[] populated = saved_persistence_mesh(&mesh);
    defer free(populated);
    char[PERSISTENCE_SCRATCH_BYTES] scratch;
    mesh.read_snapshot(populated, scratch[..], persistence_limits())!!;
    assert(@catch(mesh.tile_and_poly(old)) == nav::INVALID_REF);
    PolyRef fresh = mesh.resolve_poly_key(key)!!;
    assert(nav::decode_salt(fresh) == 1);
    assert(@catch(mesh.poly_key(old)) == nav::INVALID_REF);
    assert(@catch(mesh.resolve_poly_key({ .x = 99 })) == nav::INVALID_REF);
    assert(@catch(mesh.resolve_poly_key({ .layer = 99 })) == nav::INVALID_REF);
    assert(@catch(mesh.resolve_poly_key({ .polygon = 99 })) == nav::INVALID_REF);
    (void)mesh.remove_tile(mesh.tile_ref(mesh.tile_at(key.x, key.z, key.layer)))!!;
    assert(@catch(mesh.tile_and_poly(fresh)) == nav::INVALID_REF);
    PolyRef remaining = mesh.poly_ref_base(mesh.tile_at(1, 0, 0));
    uint max_tiles = mesh.desc.max_tiles;
    uint max_links = mesh.desc.max_links;
    mesh.read_snapshot(bytes, {}, persistence_limits())!!;
    assert(mesh.desc.origin == empty.desc.origin && mesh.desc.tile_width == 3 && mesh.desc.tile_height == 5);
    assert(mesh.desc.max_tiles == max_tiles && mesh.desc.max_links == max_links);
    assert(@catch(mesh.tile_and_poly(remaining)) == nav::INVALID_REF);
    foreach (resident : mesh.tiles) assert(!resident.header);
    char[] resaved = saved_persistence_mesh(&mesh);
    defer free(resaved);
    assert(same_bytes(bytes, resaved));
}

fn void persistence_patch_integer(
    char[] bytes,
    usz offset,
    ulong value,
    usz width,
) @local {
    for (usz index = 0; index < width; index++) bytes[offset + index] = (char)(value >> (index * 8));
}

fn ulong persistence_integer(char[] bytes, usz offset, usz width) @local {
    ulong value;
    for (usz index = 0; index < width; index++) value |= (ulong)bytes[offset + index] << (index * 8);
    return value;
}

fn void check_persistence_rollback(
    NavMesh* mesh,
    char[] input,
    fault expected,
    char[] scratch,
    NavSnapshotLimits limits,
) @local {
    NavMesh original = *mesh;
    char[] before = saved_persistence_mesh(mesh);
    defer free(before);
    TileRef[8] refs;
    char*[8] data;
    uint count;
    foreach (&tile : mesh.tiles) {
        if (!tile.header) continue;
        refs[count] = mesh.tile_ref(tile);
        data[count++] = tile.data.ptr;
    }
    PersistenceQueries queries = observe_persistence_mesh(mesh);
    fault actual = @catch(mesh.read_snapshot(input, scratch, limits));
    assert(actual == expected, "load fault %s, expected %s", actual, expected);
    assert(mesh.tiles.ptr == original.tiles.ptr && mesh.lookup.ptr == original.lookup.ptr && mesh.links.ptr == original.links.ptr);
    assert(mesh.desc.origin == original.desc.origin && mesh.desc.tile_width == original.desc.tile_width);
    assert(mesh.desc.tile_height == original.desc.tile_height && mesh.desc.max_tiles == original.desc.max_tiles);
    assert(mesh.desc.max_links == original.desc.max_links && mesh.free_link_count == original.free_link_count);
    for (uint index = 0; index < count; index++) {
        assert(mesh.tile_by_ref(refs[index])!!.data.ptr == data[index]);
        assert(mesh.is_valid_ref((PolyRef)refs[index]));
    }
    char[] after = saved_persistence_mesh(mesh);
    defer free(after);
    assert(same_bytes(before, after));
    compare_persistence_queries(queries, observe_persistence_mesh(mesh));
}

fn void test_persistence_rejects_malformed_and_incompatible_bytes_without_mutation() @test {
    NavMesh mesh = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&mesh);
    char[PERSISTENCE_SCRATCH_BYTES] scratch;
    foreach (usz length : { 0, 7, 63, 95, 100, 223, 367 }) {
        check_persistence_rollback(
            mesh: &mesh,
            input: PERSISTENCE_LITTLE[:length],
            expected: nav::INVALID_NAV_SNAPSHOT,
            scratch: scratch[..],
            limits: persistence_limits(),
        );
    }
    PersistenceMutation[] mutations = {
        { .offset = 0, .value = 'X', .width = 1 },
        { .offset = 8, .value = 0x02030405, .width = 4 },
        { .offset = 12, .value = 2, .width = 4, .expected = nav::INCOMPATIBLE_NAV_SNAPSHOT },
        { .offset = 16, .value = 72, .width = 4, .expected = nav::INCOMPATIBLE_NAV_SNAPSHOT },
        { .offset = 20, .value = uint::max, .width = 4 },
        { .offset = 24, .value = ulong::max, .width = 8 },
        { .offset = 52, .value = 1, .width = 1 },
        { .offset = 76, .value = 1, .width = 4 },
        { .offset = 80, .value = 64, .width = 8 },
        { .offset = 80, .value = ulong::max, .width = 8 },
        { .offset = 88, .value = ulong::max, .width = 8 },
        { .offset = 88, .value = 271, .width = 8 },
        { .offset = 100, .value = 0, .width = 4 },
        { .offset = 100, .value = uint::max, .width = 4 },
        { .offset = 104, .value = uint::max, .width = 4 },
        { .offset = 108, .value = uint::max, .width = 4 },
        { .offset = 112, .value = uint::max, .width = 4 },
        { .offset = 116, .value = uint::max, .width = 4 },
        { .offset = 120, .value = uint::max, .width = 4 },
        { .offset = 124, .value = 8, .width = 4 },
        { .offset = 128, .value = 8, .width = 4 },
        { .offset = 132, .value = 0, .width = 4 },
        { .offset = 136, .value = 2, .width = 4 },
        { .offset = 140, .value = 2, .width = 4 },
        { .offset = 144, .value = 0x7f800000, .width = 4 },
        { .offset = 208, .value = 0x7ff0000000000000, .width = 8 },
        { .offset = 224, .value = 0x7fc00000, .width = 4 },
        { .offset = 272, .value = 4, .width = 2 },
        { .offset = 280, .value = 1, .width = 2 },
        { .offset = 284, .value = 2, .width = 2 },
        { .offset = 298, .value = 2, .width = 1 },
        { .offset = 299, .value = 64, .width = 1 },
        { .offset = 300, .value = 1, .width = 4 },
        { .offset = 352, .value = uint::max, .width = 4 },
    };
    char[] mutated = mem::new_array(char, PERSISTENCE_LITTLE.len + 8);
    defer free(mutated);
    foreach (mutation : mutations) {
        mutated[:PERSISTENCE_LITTLE.len] = PERSISTENCE_LITTLE[..];
        persistence_patch_integer(
            bytes: mutated,
            offset: mutation.offset,
            value: mutation.value,
            width: mutation.width,
        );
        check_persistence_rollback(
            mesh: &mesh,
            input: mutated[:PERSISTENCE_LITTLE.len],
            expected: mutation.expected ? mutation.expected : nav::INVALID_NAV_SNAPSHOT,
            scratch: scratch[..],
            limits: persistence_limits(),
        );
    }
    mutated[:PERSISTENCE_LITTLE.len] = PERSISTENCE_LITTLE[..];
    mutated[PERSISTENCE_LITTLE.len..] = 0;
    persistence_patch_integer(bytes: mutated, offset: 24, value: mutated.len, width: 8);
    check_persistence_rollback(
        mesh: &mesh,
        input: mutated,
        expected: nav::INVALID_NAV_SNAPSHOT,
        scratch: scratch[..],
        limits: persistence_limits(),
    );
    char[] native = mesh.tile_at(0, 0, 0).data;
    char[] native_copy = mem::new_array(char, native.len);
    defer free(native_copy);
    native_copy[..] = native[..];
    check_persistence_rollback(
        mesh: &mesh,
        input: native_copy,
        expected: nav::INVALID_NAV_SNAPSHOT,
        scratch: scratch[..],
        limits: persistence_limits(),
    );

    char[] reversed = mem::new_array(char, PERSISTENCE_COARSE_LITTLE.len);
    defer free(reversed);
    reversed[..] = PERSISTENCE_COARSE_LITTLE[..];
    persistence_patch_integer(bytes: reversed, offset: 360, value: 513, width: 2);
    check_persistence_rollback(
        mesh: &mesh,
        input: reversed,
        expected: nav::INVALID_NAV_SNAPSHOT,
        scratch: scratch[..],
        limits: persistence_limits(),
    );
}

fn void test_persistence_rejects_record_overlap_and_late_geometry_or_adjacency() @test {
    NavMesh source = persistence_mesh(mem, true);
    defer nav::destroy_nav_mesh(&source);
    char[] bytes = saved_persistence_mesh(&source);
    defer free(bytes);
    char[] mutated = mem::new_array(char, bytes.len);
    defer free(mutated);
    NavMesh mesh = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&mesh);
    char[PERSISTENCE_SCRATCH_BYTES] scratch;
    usz first = (usz)persistence_integer(bytes, 80, 8);
    usz third = (usz)persistence_integer(bytes, 144, 8);
    usz last = (usz)persistence_integer(bytes, 176, 8);
    usz first_triangles = first + 128 + 48 + 32 + 48 + 16 + 64;
    usz first_portals = first_triangles + 32;
    usz third_connection = third + 128 + 48 + 32 + 48 + 16 + 64 + 32 + 32;
    PersistenceMutation[] mutations = {
        { .offset = 112, .value = first, .width = 8 },
        { .offset = 112, .value = first + 8, .width = 8 },
        { .offset = 80, .value = first + 8, .width = 8 },
        { .offset = 128, .value = 0, .width = 4 },
        { .offset = 128, .value = uint::max, .width = 4 },
        { .offset = last + 128, .value = 0x7fc00000, .width = 4 },
        { .offset = first_triangles, .value = 9, .width = 2 },
        { .offset = first_triangles + 6, .value = 8, .width = 2 },
        { .offset = first_triangles - 1, .value = 1, .width = 1 },
        { .offset = first_portals, .value = 1, .width = 4 },
        { .offset = first_portals + 24, .value = 9, .width = 2 },
        { .offset = first_portals + 8, .value = bitcast(2.0f, uint), .width = 4 },
        { .offset = third_connection + 32, .value = 0, .width = 4 },
        { .offset = third_connection + 39, .value = 2, .width = 1 },
        { .offset = third + 48, .value = bitcast(2.0f, uint), .width = 4 },
    };
    foreach (mutation : mutations) {
        mutated[..] = bytes[..];
        persistence_patch_integer(
            bytes: mutated,
            offset: mutation.offset,
            value: mutation.value,
            width: mutation.width,
        );
        check_persistence_rollback(
            mesh: &mesh,
            input: mutated,
            expected: nav::INVALID_NAV_SNAPSHOT,
            scratch: scratch[..],
            limits: persistence_limits(),
        );
    }
    mutated[..] = bytes[..];
    mutated[96:12] = mutated[64:12];
    check_persistence_rollback(
        mesh: &mesh,
        input: mutated,
        expected: nav::INVALID_NAV_SNAPSHOT,
        scratch: scratch[..],
        limits: persistence_limits(),
    );
}

fn void test_persistence_bounds_and_allocator_failure_preserve_live_mesh() @test {
    NavMesh source = persistence_mesh(mem, true);
    defer nav::destroy_nav_mesh(&source);
    char[] bytes = saved_persistence_mesh(&source);
    defer free(bytes);
    PersistenceAllocator allocator = { .backing = mem };
    NavMesh mesh = persistence_mesh(&allocator, false);
    defer nav::destroy_nav_mesh(&mesh);
    sz baseline = allocator.live_bytes;
    char[PERSISTENCE_SCRATCH_BYTES] scratch;
    for (usz failed = 1; failed <= 3 + PERSISTENCE_TILES; failed++) {
        allocator.fail_at = allocator.attempts + failed;
        check_persistence_rollback(
            mesh: &mesh,
            input: bytes,
            expected: c3d::CAPACITY_EXCEEDED,
            scratch: scratch[..],
            limits: persistence_limits(),
        );
        assert(allocator.live_bytes == baseline);
    }
    allocator.fail_at = 0;
    check_persistence_rollback(
        mesh: &mesh,
        input: bytes,
        expected: c3d::CAPACITY_EXCEEDED,
        scratch: {},
        limits: persistence_limits(),
    );
    NavSnapshotLimits limits = persistence_limits();
    limits.max_blob_bytes = bytes.len - 1;
    check_persistence_rollback(
        mesh: &mesh,
        input: bytes,
        expected: c3d::CAPACITY_EXCEEDED,
        scratch: scratch[..],
        limits: limits,
    );
    usz staged_bytes = source.tiles.len * MeshTile::size + source.lookup.len * MeshTile*::size + source.links.len * Link::size;
    foreach (tile : source.tiles) if (tile.header) staged_bytes += tile.data.len;
    limits.max_blob_bytes = bytes.len;
    limits.max_staged_bytes = staged_bytes - 1;
    check_persistence_rollback(
        mesh: &mesh,
        input: bytes,
        expected: c3d::CAPACITY_EXCEEDED,
        scratch: scratch[..],
        limits: limits,
    );
    limits.max_staged_bytes = staged_bytes;
    allocator.peak_bytes = baseline;
    mesh.read_snapshot(bytes, scratch[..], limits)!!;
    assert(allocator.live_bytes == (sz)staged_bytes && allocator.peak_bytes == baseline + (sz)staged_bytes);
    char[] saved = saved_persistence_mesh(&mesh);
    defer free(saved);
    assert(same_bytes(bytes, saved));
    bytes[..] = 0xcd;
    scratch[..] = 0xcd;
    (void)observe_persistence_mesh(&mesh);
    nav::destroy_nav_mesh(&mesh);
    assert(allocator.live_bytes == 0);
}

fn void test_persistence_tile_and_link_limits_and_borrowed_ownership() @test {
    NavMesh source = persistence_mesh(mem, false);
    defer nav::destroy_nav_mesh(&source);
    char[] bytes = saved_persistence_mesh(&source);
    defer free(bytes);
    char[PERSISTENCE_SCRATCH_BYTES] scratch;
    foreach (uint capacity : { 1, 4 }) {
        NavMesh mesh = nav::create_nav_mesh(mem, {
            .tile_width = 2,
            .tile_height = 2,
            .max_tiles = capacity,
            .max_links = 1,
        })!!;
        defer nav::destroy_nav_mesh(&mesh);
        char[] geometry = square_tile_mesh();
        defer free(geometry);
        char[] borrowed = tile_data_of(geometry);
        defer free(borrowed);
        TileRef old = mesh.add_tile(borrowed, {})!!;
        char[] copy = mem::new_array(char, borrowed.len);
        defer free(copy);
        copy[..] = borrowed[..];
        fault expected = capacity == 1 ? c3d::CAPACITY_EXCEEDED : nav::NO_FREE_LINKS;
        assert(@catch(mesh.read_snapshot(bytes, scratch[..], persistence_limits())) == expected);
        assert(mesh.tile_by_ref(old)!!.data.ptr == borrowed.ptr && same_bytes(copy, borrowed));
        mesh.read_snapshot(PERSISTENCE_LITTLE, scratch[..], persistence_limits())!!;
        assert(@catch(mesh.tile_by_ref(old)) == nav::INVALID_REF);
        assert(same_bytes(copy, borrowed));
        assert(mesh.tile_at(-2, 3, 4).flags.free_data);
    }
}

fn void test_persistence_preserves_the_no_bv_query_path() @test {
    char[] source = square_tile_mesh();
    defer free(source);
    TileDataParams params = default_tile_params();
    params.build_bv_tree = false;
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 3, .tile_height = 3, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileRef ref = mesh.add_tile_mesh(source, {}, params)!!;
    assert(mesh.tile_by_ref(ref)!!.bv_tree.len == 0);
    NavQuery query = nav::create_nav_query(mem, &mesh, 16)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    NearestPoly before = query.find_nearest_poly({ 1, 0, 1 }, { 0.1f, 0.1f, 0.1f }, &filter)!!;
    fault outside = @catch(query.find_nearest_poly({ 1, 3, 1 }, { 0.1f, 0.1f, 0.1f }, &filter));
    char[] bytes = saved_persistence_mesh(&mesh);
    defer free(bytes);
    mesh.read_snapshot(bytes, {}, persistence_limits())!!;
    assert(mesh.tile_at(0, 0, 0).bv_tree.len == 0);
    assert(near_point(before.point, query.find_nearest_poly({ 1, 0, 1 }, { 0.1f, 0.1f, 0.1f }, &filter)!!.point));
    assert(@catch(query.find_nearest_poly({ 1, 3, 1 }, { 0.1f, 0.1f, 0.1f }, &filter)) == outside);
    char[] restored = saved_persistence_mesh(&mesh);
    defer free(restored);
    assert(same_bytes(bytes, restored));
}

fn void test_persistence_preserves_grid_clearance_and_portal_identities() @test {
    GridFixture* fixture = mem::new(GridFixture);
    defer destroy_grid_fixture(fixture);
    NavBuildConfig config = nav::default_grid_build_config(1);
    config.tile_size = 4;
    config.agent_radius = 0;
    config.agent_height = 1;
    config.agent_max_climb = 0.75f;
    config.agent_max_slope_degrees = 60;
    config.detail_mode = BOUNDED;
    config.detail_max_error = 0;
    config.clearance_mode = SUB_CELL;
    config.clearance_max_error = 0.5f;
    fixture.builder = nav::create_grid_tile_builder(
        allocator: mem,
        config: config,
        source: grid_map_source(&fixture.map),
        scratch_bytes: 8 * 1024 * 1024,
    )!!;
    fixture.mesh = nav::create_nav_mesh(mem, fixture.builder.mesh_desc(4))!!;
    fixture.query = nav::create_nav_query(mem, &fixture.mesh, 256)!!;
    fixture.filter = nav::default_query_filter();
    lay_floor(&fixture.map, { 0, 0, 8, 4 }, open_floor(0));
    GridFloor* ramp = &fixture.map.floors[2 + GRID_MAP_SIDE][0];
    ramp.floor_kind = GridSurfaceKind.CORNERS;
    ramp.floor_corners = { 0, 0, 1, 1 };
    install_grid_tile(fixture, 0, 0);
    install_grid_tile(fixture, 1, 0);
    uint internal_portals;
    uint floor_portals;
    foreach (tile : fixture.mesh.tiles) {
        if (!tile.header) continue;
        assert(tile.header.clearance_mode == SUB_CELL && tile.header.subdivision == 4);
        foreach (portal : tile.detail_portals) {
            if (portal.kind == INTERNAL) internal_portals++;
            if (portal.kind == FLOOR_BORDER) floor_portals++;
        }
    }
    assert(internal_portals > 0 && floor_portals > 0);
    Vec3 from = { 0.5f, 0, 1.5f };
    Vec3 to = { 7.5f, 0, 1.5f };
    PathResult before = grid_path(fixture, from, to);
    assert(!before.partial && !before.truncated);
    NavPolyKey[128] keys;
    foreach (index, ref : fixture.path[:before.count]) keys[index] = fixture.mesh.poly_key(ref)!!;
    char[] bytes = saved_persistence_mesh(&fixture.mesh);
    defer free(bytes);
    char[] scratch = mem::new_array(char, 1024 * 1024);
    defer free(scratch);
    fixture.mesh.read_snapshot(bytes, scratch, persistence_limits())!!;
    PathResult after = grid_path(fixture, from, to);
    assert(after.count == before.count && !after.partial && !after.truncated);
    foreach (index, ref : fixture.path[:after.count]) {
        assert(same_persistence_key(keys[index], fixture.mesh.poly_key(ref)!!));
    }
    char[] restored = saved_persistence_mesh(&fixture.mesh);
    defer free(restored);
    assert(same_bytes(bytes, restored));
}

fn char[] coarse_query_tile(float origin_x, float cell_size, uint bounds_cells) @local {
    ushort[12] vertices = { 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0 };
    ushort[12] polygons;
    polygons[..] = nav::MESH_NULL_INDEX;
    polygons[:4] = (ushort[4]){ 0, 1, 2, 3 }[..];
    ushort[1] regions;
    ushort[1] flags = { nav::POLY_FLAG_WALK };
    char[1] areas = { nav::WALKABLE_AREA };
    PolyMesh source = {
        .verts = vertices[..],
        .polys = polygons[..],
        .regions = regions[..],
        .flags = flags[..],
        .areas = areas[..],
        .vert_count = 4,
        .poly_count = 1,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds = { .min = { origin_x, 0, 0 }, .max = { origin_x + cell_size * (float)bounds_cells, 1, cell_size } },
        .cell_size = cell_size,
        .cell_height = 1,
    };
    char[] bytes = mem::new_array(char, (sz)nav::tile_mesh_size(&source));
    nav::pack_tile_mesh(mesh: &source, tile_x: 0, tile_z: 0, blob: bytes);
    return bytes;
}

fn void test_persistence_retains_quantized_coarse_query_bounds() @test {
    NavMesh mesh = nav::create_nav_mesh(mem, {
        .origin = { 0.1f, 0, 0 },
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 1,
        .max_links = 128,
    })!!;
    defer nav::destroy_nav_mesh(&mesh);
    char[] tile = coarse_query_tile(0.1f, 0.2f, 4);
    defer free(tile);
    (void)mesh.add_tile_mesh(tile, {}, { .walkable_height = 1, .build_bv_tree = true })!!;
    NavQuery query = nav::create_nav_query(mem, &mesh, 16)!!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    assert(mesh.tile_at(0, 0, 0).bv_tree[0].max[0] == 1);
    assert(@catch(query.find_nearest_poly({ 0.5f, 0, 0.1f }, { 0, 0.1f, 0.01f }, &filter)) == nav::NO_POLY);
    char[] snapshot = saved_persistence_mesh(&mesh);
    defer free(snapshot);
    char[8192] scratch;
    mesh.read_snapshot(snapshot, scratch[..], {
        .max_blob_bytes = snapshot.len,
        .max_staged_bytes = 1024 * 1024,
    })!!;
    fault nearest = @catch(query.find_nearest_poly({ 0.5f, 0, 0.1f }, { 0, 0.1f, 0.01f }, &filter));
    assert(mesh.tile_at(0, 0, 0).bv_tree[0].max[0] == 1 && nearest == nav::NO_POLY,
        "restored max X %d, nearest fault %s", mesh.tile_at(0, 0, 0).bv_tree[0].max[0], nearest);
    char[] restored = saved_persistence_mesh(&mesh);
    defer free(restored);
    assert(same_bytes(snapshot, restored));
}

fn void test_persistence_rejects_excess_layers_before_sizing_or_writing() @test {
    NavMesh mesh = nav::create_nav_mesh(mem, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 33,
        .max_links = 128,
    })!!;
    defer nav::destroy_nav_mesh(&mesh);
    char[] tile = coarse_query_tile(0, 1, 1);
    defer free(tile);
    TileRef[33] refs;
    char[][33] original;
    defer foreach (bytes : original) free(bytes);
    for (int layer = 0; layer < 33; layer++) {
        refs[layer] = mesh.add_tile_mesh(tile, {}, { .tile_layer = layer, .walkable_height = 1 })!!;
        char[] data = mesh.tile_by_ref(refs[layer])!!.data;
        original[layer] = mem::new_array(char, data.len);
        original[layer][..] = data[..];
    }
    MeshTile* first_slot = mesh.tiles.ptr;
    uint free_links = mesh.free_link_count;
    char[8192] output;
    char[8192] scratch;
    fault sizing = @catch(mesh.snapshot_size());
    fault writing = @catch(mesh.write_snapshot(output[..], scratch[..]));
    assert(sizing == nav::INCOMPATIBLE_NAV_SNAPSHOT && writing == nav::INCOMPATIBLE_NAV_SNAPSHOT,
        "sizing fault %s, writing fault %s", sizing, writing);
    assert(mesh.tiles.ptr == first_slot && mesh.free_link_count == free_links);
    foreach (layer, ref : refs) {
        MeshTile* resident = mesh.tile_by_ref(ref)!!;
        assert(resident.header.layer == layer && same_bytes(resident.data, original[layer]));
    }
}
