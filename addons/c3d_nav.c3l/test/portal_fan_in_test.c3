module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const uint   STRIP_QUADS @private = 32;
const ushort STRIP_STEP_VOXELS @private = 2;
const ushort TILE_VOXELS @private = (ushort)(STRIP_QUADS * STRIP_STEP_VOXELS);
const float  FAN_CELL @private = 0.5f;
const float  FAN_TILE_SIZE @private = TILE_VOXELS * FAN_CELL;
const ushort PORTAL_PLUS_X @private = nav::PORTAL_EDGE | 2;
const ushort PORTAL_MINUS_X @private = nav::PORTAL_EDGE | 0;
const ushort PORTAL_PLUS_Z @private = nav::PORTAL_EDGE | 1;
const ushort PORTAL_MINUS_Z @private = nav::PORTAL_EDGE | 3;
const char   SIDE_PLUS_X @private = 0;
const char   SIDE_MINUS_X @private = 4;
const char   LONG_NORTH_EDGE @private = 1;
const char   LONG_BORDER_EDGE @private = 2;
const char   STRIP_BORDER_EDGE @private = 0;
const uint   FAN_MAX_TILES @private = 4;
const usz    WALL_SEGMENT_CAPACITY @private = 128;

struct FanInFixture @private {
    NavMesh     mesh;
    NavQuery    query;
    QueryFilter filter;
}

fn FanInFixture* create_fan_in_fixture(uint max_links = 0) @private {
    FanInFixture* fixture = mem::new(FanInFixture);
    fixture.mesh = nav::create_nav_mesh(mem, {
        .tile_width  = FAN_TILE_SIZE,
        .tile_height = FAN_TILE_SIZE,
        .max_tiles   = FAN_MAX_TILES,
        .max_links   = max_links,
    })!!;
    fixture.query = nav::create_nav_query(mem, &fixture.mesh, QUERY_NODES)!!;
    fixture.filter = nav::default_query_filter();
    return fixture;
}

fn void destroy_fan_in_fixture(FanInFixture* fixture) @private {
    nav::destroy_nav_query(&fixture.query);
    nav::destroy_nav_mesh(&fixture.mesh);
    free(fixture);
}

fn Aabb fan_tile_bounds(int tile_x, int tile_z) @private {
    Vec3 min = { (float)tile_x * FAN_TILE_SIZE, 0, (float)tile_z * FAN_TILE_SIZE };
    return { .min = min, .max = min + { FAN_TILE_SIZE, 4, FAN_TILE_SIZE } };
}

fn char[] pack_quad_tile_mesh(
    ushort[] verts,
    ushort[] quads,
    int tile_x,
    int tile_z,
) @private {
    uint poly_count = (uint)(quads.len / (QUAD_VERTS * 2));
    ushort[STRIP_QUADS] regions;
    ushort[STRIP_QUADS] flags;
    char[STRIP_QUADS] areas;
    areas[..] = nav::WALKABLE_AREA;
    PolyMesh poly_mesh = {
        .verts          = verts,
        .polys          = quads,
        .regions        = regions[:poly_count],
        .flags          = flags[:poly_count],
        .areas          = areas[:poly_count],
        .vert_count     = (uint)(verts.len / 3),
        .poly_count     = poly_count,
        .verts_per_poly = QUAD_VERTS,
        .bounds         = fan_tile_bounds(tile_x, tile_z),
        .cell_size      = FAN_CELL,
        .cell_height    = FAN_CELL,
    };
    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&poly_mesh));
    nav::pack_tile_mesh(&poly_mesh, tile_x, tile_z, blob);
    return blob;
}

// One quad covering tile (0, 0) with +X and +Z portal edges.
fn char[] long_tile_mesh() @private {
    ushort[12] verts = {
        0, 0, 0,
        0, 0, TILE_VOXELS,
        TILE_VOXELS, 0, TILE_VOXELS,
        TILE_VOXELS, 0, 0,
    };
    ushort none = nav::MESH_NULL_INDEX;
    ushort[8] quads = {
        0, 1, 2, 3,
        none, PORTAL_PLUS_Z, PORTAL_PLUS_X, none,
    };
    return pack_quad_tile_mesh(
        verts:  verts[..],
        quads:  quads[..],
        tile_x: 0,
        tile_z: 0,
    );
}

// One quad covering tile (tile_x, tile_z) with -X and -Z portal edges.
fn char[] single_quad_tile_mesh(int tile_x, int tile_z) @private {
    ushort[12] verts = {
        0, 0, 0,
        0, 0, TILE_VOXELS,
        TILE_VOXELS, 0, TILE_VOXELS,
        TILE_VOXELS, 0, 0,
    };
    ushort none = nav::MESH_NULL_INDEX;
    ushort[8] quads = {
        0, 1, 2, 3,
        PORTAL_MINUS_X, none, none, PORTAL_MINUS_Z,
    };
    return pack_quad_tile_mesh(
        verts:  verts[..],
        quads:  quads[..],
        tile_x: tile_x,
        tile_z: tile_z,
    );
}

// STRIP_QUADS quads along the -X border of tile (1, 0); raised_index gets raised_y voxels in height.
fn char[] strip_tile_mesh(uint raised_index = STRIP_QUADS, ushort raised_y = 0) @private {
    ushort[STRIP_QUADS * 4 * 3] verts;
    ushort[STRIP_QUADS * 8] quads;
    ushort none = nav::MESH_NULL_INDEX;
    for (uint index = 0; index < STRIP_QUADS; index++) {
        ushort z0 = (ushort)(index * STRIP_STEP_VOXELS);
        ushort z1 = (ushort)((index + 1) * STRIP_STEP_VOXELS);
        ushort y = index == raised_index ? raised_y : 0;
        uint v_base = index * 4;
        uint c_base = v_base * 3;
        verts[c_base + 0] = 0;           verts[c_base + 1] = y; verts[c_base + 2] = z0;
        verts[c_base + 3] = 0;           verts[c_base + 4] = y; verts[c_base + 5] = z1;
        verts[c_base + 6] = TILE_VOXELS; verts[c_base + 7] = y; verts[c_base + 8] = z1;
        verts[c_base + 9] = TILE_VOXELS; verts[c_base + 10] = y; verts[c_base + 11] = z0;

        bool link_prev = index > 0 && index != raised_index && index - 1 != raised_index;
        bool link_next = index + 1 < STRIP_QUADS && index != raised_index && index + 1 != raised_index;
        uint q_base = index * 8;
        quads[q_base + 0] = (ushort)(v_base + 0);
        quads[q_base + 1] = (ushort)(v_base + 1);
        quads[q_base + 2] = (ushort)(v_base + 2);
        quads[q_base + 3] = (ushort)(v_base + 3);
        quads[q_base + 4] = PORTAL_MINUS_X;
        quads[q_base + 5] = link_next ? (ushort)(index + 1) : none;
        quads[q_base + 6] = none;
        quads[q_base + 7] = link_prev ? (ushort)(index - 1) : none;
    }
    return pack_quad_tile_mesh(
        verts:  verts[..],
        quads:  quads[..],
        tile_x: 1,
        tile_z: 0,
    );
}

// Two disjoint quads along the -X border of tile (1, 0): z in [0, 16] and [32, 48] voxels.
fn char[] gapped_strip_tile_mesh() @private {
    ushort[2 * 4 * 3] verts = {
        0, 0, 0,   0, 0, 16,  TILE_VOXELS, 0, 16,  TILE_VOXELS, 0, 0,
        0, 0, 32,  0, 0, 48,  TILE_VOXELS, 0, 48,  TILE_VOXELS, 0, 32,
    };
    ushort none = nav::MESH_NULL_INDEX;
    ushort[2 * 8] quads = {
        0, 1, 2, 3,  PORTAL_MINUS_X, none, none, none,
        4, 5, 6, 7,  PORTAL_MINUS_X, none, none, none,
    };
    return pack_quad_tile_mesh(
        verts:  verts[..],
        quads:  quads[..],
        tile_x: 1,
        tile_z: 0,
    );
}

fn TileRef? install_mesh_at(NavMesh* mesh, char[] tile_mesh, int tile_x, int tile_z = 0) @private {
    return mesh.install_tile_mesh(tile_mesh, {}, default_tile_params(tile_x, tile_z));
}

fn usz collect_edge_links(
    NavMesh* mesh,
    Poly* poly,
    char edge,
    Link[] out_links,
) @private {
    usz count;
    for (uint link = poly.first_link; link != nav::NULL_LINK; link = mesh.links[link].next) {
        Link entry = mesh.links[link];
        if (entry.edge == edge) out_links[count++] = entry;
    }
    return count;
}

fn void test_long_border_edge_links_every_segment() @test {
    assert(@catch(nav::create_nav_mesh(mem, {
        .tile_width  = FAN_TILE_SIZE,
        .tile_height = FAN_TILE_SIZE,
        .max_tiles   = 1u << nav::TILE_BITS,
    })) == c3d::INVALID_ARGUMENT);
    assert(@catch(nav::create_nav_mesh(mem, {
        .tile_width  = FAN_TILE_SIZE,
        .tile_height = FAN_TILE_SIZE,
        .max_tiles   = 1,
        .max_links   = nav::NULL_LINK,
    })) == c3d::INVALID_ARGUMENT);

    FanInFixture* fixture = create_fan_in_fixture();
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] strip_mesh = strip_tile_mesh();
    defer free(strip_mesh);

    install_mesh_at(&fixture.mesh, long_mesh, 0)!!;
    install_mesh_at(&fixture.mesh, strip_mesh, 1)!!;

    MeshTile* long_tile = fixture.mesh.tile_at(0, 0, 0);
    MeshTile* strip_tile = fixture.mesh.tile_at(1, 0, 0);
    PolyRef long_ref = fixture.mesh.poly_ref_base(long_tile);
    PolyRef strip_base = fixture.mesh.poly_ref_base(strip_tile);

    Link[STRIP_QUADS] forward_links;
    usz forward_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: forward_links[..],
    );
    assert(forward_count == STRIP_QUADS);
    for (uint index = 0; index < STRIP_QUADS; index++) {
        assert(forward_links[index].ref == (strip_base | (PolyRef)index));
        assert(forward_links[index].side == SIDE_PLUS_X);
        Link[4] back_links;
        usz back_count = collect_edge_links(
            mesh:      &fixture.mesh,
            poly:      &strip_tile.polys[index],
            edge:      STRIP_BORDER_EDGE,
            out_links: back_links[..],
        );
        assert(back_count == 1 && back_links[0].ref == long_ref && back_links[0].side == SIDE_MINUS_X);
    }

    uint[3] entrances = { 0, 4, STRIP_QUADS - 1 };
    PolyRef[8] corridor;
    StraightPoint[8] straight;
    foreach (entrance : entrances) {
        PolyRef strip_ref = strip_base | (PolyRef)entrance;
        float z = ((float)entrance + 0.5f) * (STRIP_STEP_VOXELS * FAN_CELL);
        Vec3 in_long = { FAN_TILE_SIZE * 0.5f, 0, z };
        Vec3 in_strip = { FAN_TILE_SIZE * 1.5f, 0, z };

        PathResult to_strip = fixture.query.find_path(
            start_ref: long_ref,
            end_ref:   strip_ref,
            start:     in_long,
            end:       in_strip,
            filter:    &fixture.filter,
            out_path:  corridor[..],
        )!!;
        assert(!to_strip.partial && to_strip.count == 2);
        assert(corridor[0] == long_ref && corridor[1] == strip_ref);

        PathResult straight_result = fixture.query.straight_path(
            start:      in_long,
            end:        in_strip,
            path:       corridor[:to_strip.count],
            out_points: straight[..],
        )!!;
        assert(straight_result.count == 2);
        assert(near_point(straight[0].position, in_long));
        assert(near_point(straight[1].position, in_strip));

        PathResult to_long = fixture.query.find_path(
            start_ref: strip_ref,
            end_ref:   long_ref,
            start:     in_strip,
            end:       in_long,
            filter:    &fixture.filter,
            out_path:  corridor[..],
        )!!;
        assert(!to_long.partial && to_long.count == 2);
        assert(corridor[0] == strip_ref && corridor[1] == long_ref);
    }
}

fn void test_local_queries_follow_every_portal_on_an_edge() @test {
    FanInFixture* fixture = create_fan_in_fixture();
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] strip_mesh = strip_tile_mesh();
    defer free(strip_mesh);
    install_mesh_at(&fixture.mesh, long_mesh, 0)!!;
    install_mesh_at(&fixture.mesh, strip_mesh, 1)!!;

    PolyRef long_ref = fixture.mesh.poly_ref_base(fixture.mesh.tile_at(0, 0, 0));
    PolyRef strip_base = fixture.mesh.poly_ref_base(fixture.mesh.tile_at(1, 0, 0));
    uint target_index = 20;
    float target_z = ((float)target_index + 0.5f) * (STRIP_STEP_VOXELS * FAN_CELL);
    Vec3 start = { FAN_TILE_SIZE - 0.5f, 0, target_z };
    Vec3 goal = { FAN_TILE_SIZE + 0.5f, 0, target_z };
    PolyRef[16] visited;

    MoveResult moved = fixture.query.move_along_surface(
        start_ref:   long_ref,
        start:       start,
        end:         goal,
        filter:      &fixture.filter,
        out_visited: visited[..],
    )!!;
    assert(near_point(moved.position, goal));
    assert(moved.visited_count >= 2 && visited[moved.visited_count - 1] == (strip_base | (PolyRef)target_index));

    WallSegment[WALL_SEGMENT_CAPACITY] segments;
    QueryResult wall_result = fixture.query.poly_wall_segments(
        ref:          long_ref,
        filter:       &fixture.filter,
        out_segments: segments[..],
    )!!;
    assert(!wall_result.truncated && wall_result.count == STRIP_QUADS + 3);
    usz portal_segments;
    foreach (segment : segments[:wall_result.count]) {
        if (segment.neighbour) portal_segments++;
    }
    assert(portal_segments == STRIP_QUADS);

    fixture.mesh.set_poly_flags(strip_base, 0)!!;
    WallHit wall_hit = fixture.query.find_distance_to_wall(
        start_ref:  long_ref,
        center:     { FAN_TILE_SIZE - 0.2f, 0, target_z },
        max_radius: 0.4f,
        filter:     &fixture.filter,
    )!!;
    assert(math::abs(wall_hit.distance - 0.4f) <= POINT_TOLERANCE);

    NavQuery small_query = nav::create_nav_query(
        allocator:      mem,
        mesh:           &fixture.mesh,
        max_nodes:      QUERY_NODES,
        max_edge_links: 8,
    )!!;
    defer nav::destroy_nav_query(&small_query);
    assert(@catch(small_query.move_along_surface(
        start_ref:   long_ref,
        start:       start,
        end:         goal,
        filter:      &fixture.filter,
        out_visited: visited[..],
    )) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(small_query.poly_wall_segments(
        ref:          long_ref,
        filter:       &fixture.filter,
        out_segments: segments[..],
    )) == c3d::CAPACITY_EXCEEDED);
}

fn void test_climb_difference_rejects_one_segment() @test {
    FanInFixture* fixture = create_fan_in_fixture();
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    uint raised_index = 10;
    char[] strip_mesh = strip_tile_mesh(raised_index: raised_index, raised_y: 6);
    defer free(strip_mesh);

    install_mesh_at(&fixture.mesh, long_mesh, 0)!!;
    install_mesh_at(&fixture.mesh, strip_mesh, 1)!!;

    MeshTile* long_tile = fixture.mesh.tile_at(0, 0, 0);
    MeshTile* strip_tile = fixture.mesh.tile_at(1, 0, 0);
    PolyRef strip_base = fixture.mesh.poly_ref_base(strip_tile);
    PolyRef raised_ref = strip_base | (PolyRef)raised_index;

    Link[STRIP_QUADS] forward_links;
    usz forward_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: forward_links[..],
    );
    assert(forward_count == STRIP_QUADS - 1);
    foreach (entry : forward_links[:forward_count]) assert(entry.ref != raised_ref);

    Link[4] raised_back;
    usz raised_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &strip_tile.polys[raised_index],
        edge:      STRIP_BORDER_EDGE,
        out_links: raised_back[..],
    );
    assert(raised_count == 0);
}

fn void test_disjoint_segments_clip_their_intervals() @test {
    FanInFixture* fixture = create_fan_in_fixture();
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] gapped_mesh = gapped_strip_tile_mesh();
    defer free(gapped_mesh);

    install_mesh_at(&fixture.mesh, long_mesh, 0)!!;
    install_mesh_at(&fixture.mesh, gapped_mesh, 1)!!;

    MeshTile* long_tile = fixture.mesh.tile_at(0, 0, 0);
    PolyRef long_ref = fixture.mesh.poly_ref_base(long_tile);
    Link[4] links;
    usz link_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: links[..],
    );
    assert(link_count == 2);
    // Edge 2 of the long quad runs from z = 32 down to z = 0: quad 0 covers [0, 8] (t in [0.75, 1]) and quad 1 covers [16, 24] (t in [0.25, 0.5]).
    assert(links[0].min == 191.0f / 255.0f && links[0].max == 1);
    assert(links[1].min == 64.0f / 255.0f && links[1].max == 128.0f / 255.0f);

    WallSegment[WALL_SEGMENT_CAPACITY] segments;
    QueryResult wall_result = fixture.query.poly_wall_segments(
        ref:          long_ref,
        filter:       &fixture.filter,
        out_segments: segments[..],
    )!!;
    usz portals;
    usz border_walls;
    foreach (segment : segments[:wall_result.count]) {
        if (segment.neighbour) {
            portals++;
        } else if (math::abs(segment.start.x - FAN_TILE_SIZE) <= POINT_TOLERANCE
            && math::abs(segment.end.x - FAN_TILE_SIZE) <= POINT_TOLERANCE) {
            border_walls++;
        }
    }
    assert(portals == 2 && border_walls == 2);
}

fn void test_replacing_and_removing_the_strip_tile_relinks() @test {
    FanInFixture* fixture = create_fan_in_fixture();
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] strip_mesh = strip_tile_mesh();
    defer free(strip_mesh);
    char[] single_mesh = single_quad_tile_mesh(1, 0);
    defer free(single_mesh);

    uint initial_free = fixture.mesh.free_links();
    install_mesh_at(&fixture.mesh, long_mesh, 0)!!;
    uint free_with_long = fixture.mesh.free_links();
    assert(free_with_long == initial_free);

    install_mesh_at(&fixture.mesh, strip_mesh, 1)!!;
    MeshTile* long_tile = fixture.mesh.tile_at(0, 0, 0);
    Link[STRIP_QUADS] links;
    assert(collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: links[..],
    ) == STRIP_QUADS);

    install_mesh_at(&fixture.mesh, single_mesh, 1)!!;
    assert(collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: links[..],
    ) == 1);
    assert(fixture.mesh.free_links() == free_with_long - 2);

    install_mesh_at(&fixture.mesh, {}, 1)!!;
    assert(collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: links[..],
    ) == 0);
    assert(fixture.mesh.free_links() == free_with_long);
}

fn void test_reversed_install_order_links_the_same_portals() @test {
    FanInFixture* forward = create_fan_in_fixture();
    defer destroy_fan_in_fixture(forward);
    FanInFixture* reversed = create_fan_in_fixture();
    defer destroy_fan_in_fixture(reversed);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] strip_mesh = strip_tile_mesh();
    defer free(strip_mesh);

    install_mesh_at(&forward.mesh, long_mesh, 0)!!;
    install_mesh_at(&forward.mesh, strip_mesh, 1)!!;
    install_mesh_at(&reversed.mesh, strip_mesh, 1)!!;
    install_mesh_at(&reversed.mesh, long_mesh, 0)!!;

    MeshTile* forward_long = forward.mesh.tile_at(0, 0, 0);
    MeshTile* reversed_long = reversed.mesh.tile_at(0, 0, 0);
    Link[STRIP_QUADS] forward_links;
    Link[STRIP_QUADS] reversed_links;
    usz forward_count = collect_edge_links(
        mesh:      &forward.mesh,
        poly:      &forward_long.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: forward_links[..],
    );
    usz reversed_count = collect_edge_links(
        mesh:      &reversed.mesh,
        poly:      &reversed_long.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: reversed_links[..],
    );
    assert(forward_count == STRIP_QUADS && reversed_count == STRIP_QUADS);
    for (usz index = 0; index < STRIP_QUADS; index++) {
        assert(nav::decode_poly(forward_links[index].ref) == index);
        assert(nav::decode_poly(reversed_links[index].ref) == index);
        assert(forward_links[index].min == reversed_links[index].min);
        assert(forward_links[index].max == reversed_links[index].max);
        assert(forward_links[index].side == reversed_links[index].side);
    }

    PolyRef forward_long_ref = forward.mesh.poly_ref_base(forward_long);
    PolyRef reversed_long_ref = reversed.mesh.poly_ref_base(reversed_long);
    PolyRef forward_strip_base = forward.mesh.poly_ref_base(forward.mesh.tile_at(1, 0, 0));
    PolyRef reversed_strip_base = reversed.mesh.poly_ref_base(reversed.mesh.tile_at(1, 0, 0));
    PolyRef[8] forward_path;
    PolyRef[8] reversed_path;
    uint[3] entrances = { 0, 4, STRIP_QUADS - 1 };
    foreach (entrance : entrances) {
        float z = ((float)entrance + 0.5f) * (STRIP_STEP_VOXELS * FAN_CELL);
        Vec3 start = { FAN_TILE_SIZE * 0.5f, 0, z };
        Vec3 end = { FAN_TILE_SIZE * 1.5f, 0, z };
        PathResult f_res = forward.query.find_path(
            start_ref: forward_long_ref,
            end_ref:   forward_strip_base | (PolyRef)entrance,
            start:     start,
            end:       end,
            filter:    &forward.filter,
            out_path:  forward_path[..],
        )!!;
        PathResult r_res = reversed.query.find_path(
            start_ref: reversed_long_ref,
            end_ref:   reversed_strip_base | (PolyRef)entrance,
            start:     start,
            end:       end,
            filter:    &reversed.filter,
            out_path:  reversed_path[..],
        )!!;
        assert(f_res.count == r_res.count && !f_res.partial && !r_res.partial);
        assert(nav::decode_poly(forward_path[1]) == nav::decode_poly(reversed_path[1]));
    }
}

fn void test_install_without_free_links_faults_and_changes_nothing() @test {
    // Strip tile needs 62 internal links + 64 portal links = 126 links.
    uint strip_links = (STRIP_QUADS - 1) * 2 + STRIP_QUADS * 2;
    FanInFixture* fixture = create_fan_in_fixture(strip_links);
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] north_mesh = single_quad_tile_mesh(0, 1);
    defer free(north_mesh);
    char[] strip_mesh = strip_tile_mesh();
    defer free(strip_mesh);

    install_mesh_at(&fixture.mesh, long_mesh, 0, 0)!!;
    TileRef north_ref = install_mesh_at(&fixture.mesh, north_mesh, 0, 1)!!;
    uint free_before = fixture.mesh.free_links();
    assert(free_before == strip_links - 2);

    MeshTile* long_tile = fixture.mesh.tile_at(0, 0, 0);
    Link[4] before_links;
    usz before_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_NORTH_EDGE,
        out_links: before_links[..],
    );
    assert(before_count == 1);

    assert(@catch(install_mesh_at(&fixture.mesh, strip_mesh, 1, 0)) == nav::NO_FREE_LINKS);
    assert(fixture.mesh.free_links() == free_before);
    assert(!fixture.mesh.tile_at(1, 0, 0));
    Link[4] after_links;
    usz after_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_NORTH_EDGE,
        out_links: after_links[..],
    );
    assert(after_count == 1 && after_links[0].ref == before_links[0].ref);

    fixture.mesh.remove_tile(north_ref)!!;
    assert(fixture.mesh.free_links() == strip_links);
    install_mesh_at(&fixture.mesh, strip_mesh, 1, 0)!!;
    assert(fixture.mesh.free_links() == 0);
    assert(fixture.mesh.tile_at(1, 0, 0) != null);
}

fn void test_failed_replace_keeps_the_resident_tile() @test {
    FanInFixture* fixture = create_fan_in_fixture(64);
    defer destroy_fan_in_fixture(fixture);
    char[] long_mesh = long_tile_mesh();
    defer free(long_mesh);
    char[] single_mesh = single_quad_tile_mesh(1, 0);
    defer free(single_mesh);
    char[] strip_mesh = strip_tile_mesh();
    defer free(strip_mesh);

    install_mesh_at(&fixture.mesh, long_mesh, 0, 0)!!;
    TileRef resident_ref = install_mesh_at(&fixture.mesh, single_mesh, 1, 0)!!;
    uint free_before = fixture.mesh.free_links();
    PolyRef resident_poly = fixture.mesh.poly_ref_base(fixture.mesh.tile_at(1, 0, 0));

    assert(@catch(install_mesh_at(&fixture.mesh, strip_mesh, 1, 0)) == nav::NO_FREE_LINKS);
    assert(fixture.mesh.tile_ref_at(1, 0, 0) == resident_ref);
    assert(fixture.mesh.free_links() == free_before);
    MeshTile* resident = fixture.mesh.tile_at(1, 0, 0);
    assert(resident != null && resident.header.poly_count == 1);

    MeshTile* long_tile = fixture.mesh.tile_at(0, 0, 0);
    Link[4] forward_links;
    usz forward_count = collect_edge_links(
        mesh:      &fixture.mesh,
        poly:      &long_tile.polys[0],
        edge:      LONG_BORDER_EDGE,
        out_links: forward_links[..],
    );
    assert(forward_count == 1 && forward_links[0].ref == resident_poly);
}
