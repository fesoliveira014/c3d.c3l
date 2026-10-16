module c3d_nav_test;

import std::math::vector;
import c3d;
import c3d::nav @public;

struct RuntimeSetSnapshot @private {
    char[] mesh;
    char[] tiles;
    char[] links;
    char[] lookup;
    char[][] data;
    PolyRef[] refs;
}

fn char[] copy_runtime_set_bytes(void* source, usz count) @private {
    char[] result = mem::new_array(char, (sz)count);
    result[..] = ((char*)source)[:count];
    return result;
}

fn RuntimeSetSnapshot snapshot_runtime_set(NavMesh* mesh) @private {
    RuntimeSetSnapshot result = {
        .mesh = copy_runtime_set_bytes(mesh, NavMesh::size),
        .tiles = copy_runtime_set_bytes(mesh.tiles.ptr, MeshTile::size * mesh.tiles.len),
        .links = copy_runtime_set_bytes(mesh.links.ptr, Link::size * mesh.links.len),
        .lookup = copy_runtime_set_bytes(mesh.lookup.ptr, uptr::size * mesh.lookup.len),
        .data = mem::new_array(char[], (sz)mesh.tiles.len),
        .refs = mem::new_array(PolyRef, (sz)mesh.tiles.len),
    };
    foreach (index, &tile : mesh.tiles) {
        if (!tile.header) continue;
        result.data[index] = copy_runtime_set_bytes(tile.data.ptr, tile.data.len);
        result.refs[index] = mesh.poly_ref_base(tile);
    }
    return result;
}

fn void destroy_runtime_set_snapshot(RuntimeSetSnapshot* snapshot) @private {
    free(snapshot.mesh);
    free(snapshot.tiles);
    free(snapshot.links);
    free(snapshot.lookup);
    foreach (bytes : snapshot.data) free(bytes);
    free(snapshot.data);
    free(snapshot.refs);
}

fn void assert_runtime_set_unchanged(NavMesh* mesh, RuntimeSetSnapshot* snapshot) @private {
    assert(same_bytes(snapshot.mesh, ((char*)mesh)[:NavMesh::size]));
    assert(same_bytes(snapshot.tiles, ((char*)mesh.tiles.ptr)[:MeshTile::size * mesh.tiles.len]));
    assert(same_bytes(snapshot.links, ((char*)mesh.links.ptr)[:Link::size * mesh.links.len]));
    assert(same_bytes(snapshot.lookup, ((char*)mesh.lookup.ptr)[:uptr::size * mesh.lookup.len]));
    foreach (index, bytes : snapshot.data) {
        if (!bytes.len) continue;
        assert(mesh.is_valid_ref(snapshot.refs[index]));
        assert(same_bytes(bytes, mesh.tiles[index].data));
    }
}

fn char[] runtime_layer_data(
    NavMesh* mesh,
    int layer,
    float floor,
    OffMeshConnectionDesc[] connections = {},
    int tile_x = 0,
) @local {
    char[] source = detail_runtime_mesh({ (float)tile_x * 2, floor, 0 });
    defer free(source);
    TileDataParams params = detail_runtime_params(layer: layer);
    params.tile_x = tile_x;
    return nav::create_tile_blob(
        mesh: mesh,
        tile_mesh: source,
        connections: connections,
        params: params,
    )!!;
}

fn OffMeshConnectionDesc runtime_layer_jump(float start, float end, bool bidirectional = true) @local {
    return {
        .start = { 1, start, 1 },
        .end = { 1, end, 1 },
        .radius = 0.1f,
        .flags = nav::POLY_FLAG_WALK,
        .bidirectional = bidirectional,
    };
}

fn void test_runtime_set_replacement_uses_exact_slots_and_counts_candidate_pairs_once() @test {
    foreach (bool reverse : { false, true }) {
        NavMesh mesh = nav::create_nav_mesh(mem, {
            .tile_width = 2,
            .tile_height = 2,
            .max_tiles = 2,
            .max_links = 8,
        })!!;
        defer nav::destroy_nav_mesh(&mesh);
        OffMeshConnectionDesc[1] lower_jump = { runtime_layer_jump(1, 4) };
        OffMeshConnectionDesc[1] upper_jump = { runtime_layer_jump(4, 1) };
        char[] lower = runtime_layer_data(
            mesh: &mesh,
            layer: 0,
            floor: 0,
            connections: lower_jump[..],
        );
        char[] upper = runtime_layer_data(
            mesh: &mesh,
            layer: 1,
            floor: 3,
            connections: upper_jump[..],
        );
        TileRef lower_ref = mesh.add_tile(lower, { .free_data = true })!!;
        TileRef upper_ref = mesh.add_tile(upper, { .free_data = true })!!;
        assert(mesh.free_links() == 0 && mesh.next_free == null);
        char[][2] candidates = {
            runtime_layer_data(
                mesh: &mesh,
                layer: 0,
                floor: 0,
                connections: lower_jump[..],
            ),
            runtime_layer_data(
                mesh: &mesh,
                layer: 1,
                floor: 3,
                connections: upper_jump[..],
            ),
        };
        defer {
            foreach (bytes : candidates) free(bytes);
        }
        if (reverse) @swap(candidates[0], candidates[1]);

        nav::replace_tile_data_at(
            mesh: &mesh,
            tile_x: 0,
            tile_z: 0,
            owned_data: candidates[..],
        )!!;
        candidates[0] = {};
        candidates[1] = {};

        assert(@catch(mesh.tile_by_ref(lower_ref)) == nav::INVALID_REF);
        assert(@catch(mesh.tile_by_ref(upper_ref)) == nav::INVALID_REF);
        assert(mesh.free_links() == 0 && mesh.next_free == null);
        MeshTile* first = mesh.tile_at(0, 0, 0);
        MeshTile* second = mesh.tile_at(0, 0, 1);
        assert(first && second && first.flags.free_data && second.flags.free_data);
        foreach (MeshTile* tile : { first, second }) {
            uint links;
            for (uint link = tile.polys[1].first_link; link != nav::NULL_LINK; link = mesh.links[link].next) links++;
            assert(links == 2);
        }
        NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
        defer nav::destroy_nav_query(&query);
        assert(query.poly_height(mesh.poly_ref_base(first), { 1, 0, 1 })!! == 1);
        assert(query.poly_height(mesh.poly_ref_base(second), { 1, 0, 1 })!! == 4);
    }
}

fn void test_runtime_set_link_failure_does_not_double_credit_old_cross_layer_links() @test {
    NavMesh mesh = nav::create_nav_mesh(mem, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 2,
        .max_links = 8,
    })!!;
    defer nav::destroy_nav_mesh(&mesh);
    OffMeshConnectionDesc[1] lower_jump = { runtime_layer_jump(1, 4) };
    OffMeshConnectionDesc[1] upper_jump = { runtime_layer_jump(4, 1) };
    mesh.add_tile(runtime_layer_data(
        mesh: &mesh,
        layer: 0,
        floor: 0,
        connections: lower_jump[..],
    ), { .free_data = true })!!;
    mesh.add_tile(runtime_layer_data(
        mesh: &mesh,
        layer: 1,
        floor: 3,
        connections: upper_jump[..],
    ), { .free_data = true })!!;
    RuntimeSetSnapshot before = snapshot_runtime_set(&mesh);
    defer destroy_runtime_set_snapshot(&before);
    OffMeshConnectionDesc[2] extra = { runtime_layer_jump(1, 4), runtime_layer_jump(1, 4, false) };
    char[][2] candidates = {
        runtime_layer_data(
            mesh: &mesh,
            layer: 0,
            floor: 0,
            connections: extra[..],
        ),
        runtime_layer_data(
            mesh: &mesh,
            layer: 1,
            floor: 3,
            connections: upper_jump[..],
        ),
    };
    defer {
        foreach (bytes : candidates) free(bytes);
    }

    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[..],
    )) == nav::NO_FREE_LINKS);

    assert_runtime_set_unchanged(&mesh, &before);
    NavQuery query = nav::create_nav_query(mem, &mesh, 64)!!;
    defer nav::destroy_nav_query(&query);
    assert(query.poly_height(mesh.poly_ref_base(mesh.tile_at(0, 0, 0)), { 1, 0, 1 })!! == 1);
    assert(query.poly_height(mesh.poly_ref_base(mesh.tile_at(0, 0, 1)), { 1, 0, 1 })!! == 4);
}

fn void test_runtime_set_validation_failure_preserves_every_published_byte() @test {
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 3 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    mesh.add_tile(runtime_layer_data(&mesh, 0, 0), { .free_data = true })!!;
    mesh.add_tile(runtime_layer_data(&mesh, 1, 3), { .free_data = true })!!;
    mesh.add_tile(runtime_layer_data(
        mesh: &mesh,
        layer: 0,
        floor: 0,
        tile_x: 1,
    ), { .free_data = true })!!;
    RuntimeSetSnapshot before = snapshot_runtime_set(&mesh);
    defer destroy_runtime_set_snapshot(&before);
    char[][3] candidates = {
        runtime_layer_data(&mesh, 0, 0),
        runtime_layer_data(&mesh, 1, 3),
        runtime_layer_data(&mesh, 2, 6),
    };
    defer {
        foreach (bytes : candidates) free(bytes);
    }
    TileHeader* second = (TileHeader*)candidates[1].ptr;
    second.version--;
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[:2],
    )) == c3d::INVALID_ARGUMENT);
    assert_runtime_set_unchanged(&mesh, &before);
    second.version++;
    second.layer = 0;
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[:2],
    )) == c3d::INVALID_ARGUMENT);
    assert_runtime_set_unchanged(&mesh, &before);
    second.layer = 1;
    second.x = 1;
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[:2],
    )) == c3d::INVALID_ARGUMENT);
    assert_runtime_set_unchanged(&mesh, &before);
    second.x = 0;
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[..],
    )) == c3d::CAPACITY_EXCEEDED);
    assert_runtime_set_unchanged(&mesh, &before);
    char[][1] published = { mesh.tile_at(0, 0, 0).data };
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: published[..],
    )) == c3d::INVALID_ARGUMENT);
    assert_runtime_set_unchanged(&mesh, &before);
    char[][2] repeated = { candidates[0], candidates[0] };
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: repeated[..],
    )) == c3d::INVALID_ARGUMENT);
    assert_runtime_set_unchanged(&mesh, &before);
}

fn void test_runtime_set_unlanded_candidate_is_not_counted_as_an_endpoint_source() @test {
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2, .max_links = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    OffMeshConnectionDesc[1] jump = { runtime_layer_jump(4, 1) };
    char[][2] candidates = {
        runtime_layer_data(&mesh, 0, 0),
        runtime_layer_data(
            mesh: &mesh,
            layer: 1,
            floor: 3,
            connections: jump[..],
        ),
    };
    defer {
        foreach (bytes : candidates) free(bytes);
    }
    MeshTile staged;
    nav::carve_tile_data(&staged, candidates[1]);
    staged.off_mesh[0].start.x = 10;

    nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[..],
    )!!;
    candidates[0] = {};
    candidates[1] = {};

    assert(mesh.free_links() == 1);
    assert(mesh.tile_at(0, 0, 1).polys[1].first_link == nav::NULL_LINK);
}

fn void test_runtime_set_empty_replacement_removes_incoming_neighbor_links() @test {
    char[] ridge = detail_runtime_mesh(boundary_ridge: true, border: true);
    defer free(ridge);
    char[] strips = detail_border_strips();
    defer free(strips);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 3, .max_links = 32 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileDataParams params = detail_runtime_params();
    TileRef retained = mesh.add_tile_mesh(ridge, {}, params)!!;
    params.tile_z = -1;
    TileRef removed = mesh.add_tile_mesh(strips, {}, params)!!;
    MeshTile* neighbour = mesh.tile_by_ref(retained)!!;
    assert(neighbour.polys[0].first_link != nav::NULL_LINK);

    nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: -1,
        owned_data: {},
    )!!;

    assert(@catch(mesh.tile_by_ref(removed)) == nav::INVALID_REF);
    assert(mesh.tile_by_ref(retained)!! == neighbour && neighbour.polys[0].first_link == nav::NULL_LINK);
    assert(mesh.free_links() == mesh.desc.max_links);
    assert(!mesh.tile_at(0, -1, 0));
}

fn void test_runtime_set_compatibility_failure_preserves_old_and_neighbor_links() @test {
    char[] ridge = detail_runtime_mesh(boundary_ridge: true, border: true);
    defer free(ridge);
    char[] strips = detail_border_strips();
    defer free(strips);
    char[] legacy = detail_border_strips(false);
    defer free(legacy);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 2, .tile_height = 2, .max_tiles = 2, .max_links = 32 })!!;
    defer nav::destroy_nav_mesh(&mesh);
    TileDataParams params = detail_runtime_params();
    mesh.add_tile_mesh(ridge, {}, params)!!;
    params.tile_z = -1;
    mesh.add_tile_mesh(strips, {}, params)!!;
    RuntimeSetSnapshot before = snapshot_runtime_set(&mesh);
    defer destroy_runtime_set_snapshot(&before);
    char[][1] candidates = { nav::create_tile_blob(
        mesh: &mesh,
        tile_mesh: legacy,
        connections: {},
        params: params,
    )!! };
    defer free(candidates[0]);

    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: -1,
        owned_data: candidates[..],
    )) == c3d::INVALID_ARGUMENT);

    assert_runtime_set_unchanged(&mesh, &before);
}

fn void test_runtime_set_layer_capacity_and_shrink_preserve_local_detail_storage() @test {
    NavMesh mesh = nav::create_nav_mesh(mem, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = nav::MAX_TILES_AT,
        .max_links = 1,
    })!!;
    defer nav::destroy_nav_mesh(&mesh);
    char[][nav::MAX_TILES_AT + 1] candidates;
    defer {
        foreach (bytes : candidates) free(bytes);
    }
    for (uint index = 0; index < nav::MAX_TILES_AT; index++) {
        int layer = (int)(nav::MAX_TILES_AT - 1 - index);
        candidates[index] = runtime_layer_data(&mesh, layer, (float)layer * 3);
    }
    assert(@catch(nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[..],
    )) == c3d::CAPACITY_EXCEEDED);
    assert(mesh.free_links() == 1 && !mesh.tile_at(0, 0, 0));
    nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[:nav::MAX_TILES_AT],
    )!!;
    foreach (&data : candidates) *data = {};
    PolyRef[nav::MAX_TILES_AT] previous;
    for (uint index = 0; index < nav::MAX_TILES_AT; index++) {
        MeshTile* tile = mesh.tile_at(0, 0, (int)index);
        assert(tile);
        previous[index] = mesh.poly_ref_base(tile);
    }
    candidates[0] = runtime_layer_data(&mesh, 7, 21);
    MeshTile probe;
    nav::carve_tile_data(&probe, candidates[0]);
    Vec3[5] vertices;
    vertices[..] = probe.detail_vertices[..];
    Vec3[4] corners;
    corners[..] = probe.detail_corners[..];
    double[2] correction = probe.header.detail_origin_correction;

    nav::replace_tile_data_at(
        mesh: &mesh,
        tile_x: 0,
        tile_z: 0,
        owned_data: candidates[:1],
    )!!;
    candidates[0] = {};

    foreach (ref : previous) assert(!mesh.is_valid_ref(ref));
    MeshTile* retained = mesh.tile_at(0, 0, 7);
    assert(retained && !mesh.tile_at(0, 0, 0) && !mesh.tile_at(0, 0, (int)nav::MAX_TILES_AT - 1));
    foreach (index, vertex : vertices) assert(vertex == retained.detail_vertices[index]);
    foreach (index, vertex : corners) assert(vertex == retained.detail_corners[index]);
    assert(correction[0] == retained.header.detail_origin_correction[0]
        && correction[1] == retained.header.detail_origin_correction[1]);
}
