module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const float  POINT_TOLERANCE @private = 0.0001f;
const ushort SQUARE_VOXELS @private = 10;
const float  SQUARE_CELL_SIZE @private = 0.3f;
const float  SQUARE_CELL_HEIGHT @private = 0.2f;
const usz    ARRAY_ALIGNMENT @private = 8;

fn bool near_point(Vec3 actual, Vec3 expected) @private {
    Vec3 delta = math::abs(actual - expected);
    return delta.x <= POINT_TOLERANCE && delta.y <= POINT_TOLERANCE && delta.z <= POINT_TOLERANCE;
}

// One square polygon of SQUARE_VOXELS per side at the origin, packed as a TileMesh blob.
fn char[] square_tile_mesh() @private {
    ushort[12] verts = {
        0, 0, 0,
        0, 0, SQUARE_VOXELS,
        SQUARE_VOXELS, 0, SQUARE_VOXELS,
        SQUARE_VOXELS, 0, 0,
    };
    ushort[nav::MAX_VERTS_PER_POLY * 2] polys;
    polys[..] = nav::MESH_NULL_INDEX;
    polys[:4] = (ushort[4]){ 0, 1, 2, 3 }[..];
    ushort[1] regions;
    ushort[1] flags;
    char[1] areas = { nav::WALKABLE_AREA };
    float side = SQUARE_VOXELS * SQUARE_CELL_SIZE;
    PolyMesh mesh = {
        .verts          = verts[..],
        .polys          = polys[..],
        .regions        = regions[..],
        .flags          = flags[..],
        .areas          = areas[..],
        .vert_count     = 4,
        .poly_count     = 1,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds         = { .min = { 0, 0, 0 }, .max = { side, 1, side } },
        .cell_size      = SQUARE_CELL_SIZE,
        .cell_height    = SQUARE_CELL_HEIGHT,
    };
    char[] blob = mem::new_array(char, (sz)nav::tile_mesh_size(&mesh));
    nav::pack_tile_mesh(&mesh, 0, 0, blob);
    return blob;
}

fn TileDataParams default_tile_params(int tile_x = 0, int tile_z = 0) @private {
    NavBuildConfig config = nav::default_nav_build_config();
    return {
        .tile_x          = tile_x,
        .tile_z          = tile_z,
        .walkable_height = config.agent_height,
        .walkable_radius = config.agent_radius,
        .walkable_climb  = config.agent_max_climb,
        .build_bv_tree   = true,
    };
}

fn char[] tile_data_of(char[] tile_mesh, OffMeshConnectionDesc[] connections = {}) @private {
    TileMeshView view = nav::tile_mesh_view(tile_mesh);
    TileDataParams params = default_tile_params(view.header.tile_x, view.header.tile_z);
    char[] blob = mem::new_array(char, (sz)nav::tile_data_size(view, connections, params));
    nav::create_tile_data(view, connections, params, blob)!!;
    return blob;
}

fn usz offset_in(void* pointer, char[] blob) @private => (usz)pointer - (usz)blob.ptr;

// Links of the tile on the side, each on a portal edge of that side and into the target tile.
fn uint links_on_side(MeshTile* tile, char side, uint target_index) @private {
    uint count;
    foreach (&poly : tile.polys) {
        for (uint link = poly.first_link; link != nav::NULL_LINK; link = tile.links[link].next) {
            Link* entry = &tile.links[link];
            if (entry.side != side) continue;
            assert(poly.neighbours[entry.edge] == (nav::EXTERNAL_LINK | (ushort)side));
            assert(nav::decode_tile(entry.ref) == target_index);
            count++;
        }
    }
    return count;
}

fn void test_random_point_in_convex_poly_with_s_one() @test {
    Vec3[3] points = { { 0, 0, 0 }, { 0, 0, 1 }, { 1, 0, 0 } };

    assert(near_point(nav::random_point_in_convex_poly(points[..], 0, 1), { 0, 0, 1 }));
    assert(near_point(nav::random_point_in_convex_poly(points[..], 0.5f, 1), { 0.5f, 0, 0.5f }));
    assert(near_point(nav::random_point_in_convex_poly(points[..], 1, 1), { 1, 0, 0 }));
}

fn void test_poly_ref_encodes_and_decodes() @test {
    uint salt = (1u << nav::SALT_BITS) - 1;
    uint tile = (1u << nav::TILE_BITS) - 1;
    uint poly = (1u << nav::POLY_BITS) - 1;
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = 1, .tile_height = 1, .max_tiles = 4 })!!;
    defer nav::destroy_nav_mesh(&mesh);

    PolyRef full = nav::encode_poly_ref(salt, tile, poly);
    PolyRef small = nav::encode_poly_ref(1, 2, 3);

    assert(nav::decode_salt(full) == salt && nav::decode_tile(full) == tile && nav::decode_poly(full) == poly);
    assert(nav::decode_salt(small) == 1 && nav::decode_tile(small) == 2 && nav::decode_poly(small) == 3);
    assert(!mesh.is_valid_ref((PolyRef)0));
    assert(@catch(mesh.tile_and_poly((PolyRef)0)) == nav::INVALID_REF);
}

fn void test_tile_data_layout_is_aligned_and_counts_links() @test {
    char[] square = square_tile_mesh();
    defer free(square);
    float side = SQUARE_VOXELS * SQUARE_CELL_SIZE;
    OffMeshConnectionDesc[2] connections = {
        { .start = { 1, 0, 1 }, .end = { 2, 0, 2 }, .radius = 0.5f, .flags = nav::POLY_FLAG_WALK },
        { .start = { side + 1, 0, 1 }, .end = { 1, 0, 2 }, .radius = 0.5f, .flags = nav::POLY_FLAG_WALK },
    };
    char[] plain = tile_data_of(square);
    defer free(plain);
    char[] linked = tile_data_of(square, connections[..]);
    defer free(linked);
    NavMesh mesh = nav::create_nav_mesh(mem, { .tile_width = side, .tile_height = side, .max_tiles = 1 })!!;
    defer nav::destroy_nav_mesh(&mesh);

    TileRef ref = mesh.add_tile(plain, {})!!;

    TileHeader* header = (TileHeader*)plain.ptr;
    assert(header.poly_count == 1 && header.vert_count == 4 && header.bv_node_count == 1);
    assert(header.max_link_count == 4, "four border edges, no portals");
    MeshTile* tile = mesh.tile_by_ref(ref)!!;
    void*[5] arrays = { tile.verts.ptr, tile.polys.ptr, tile.links.ptr, tile.bv_tree.ptr, tile.off_mesh.ptr };
    foreach (array : arrays) assert(offset_in(array, plain) % ARRAY_ALIGNMENT == 0);
    usz end = offset_in(tile.off_mesh.ptr + tile.off_mesh.len, plain);
    assert(end <= plain.len && plain.len - end < ARRAY_ALIGNMENT);
    assert(mesh.remove_tile(ref)!!.ptr == plain.ptr, "a borrowed blob returns to the caller");

    TileHeader* linked_header = (TileHeader*)linked.ptr;
    assert(linked_header.off_mesh_count == 1, "the connection starting outside the tile is dropped");
    assert(linked_header.poly_count == 2 && linked_header.vert_count == 6);
    assert(linked_header.max_link_count == 4 + 3 * 2, "both ends of the first connection and the end of the second");
}

fn void test_add_tile_links_neighbours_across_the_border() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(2));
    defer teardown(fixture);
    float side = fixture.builder.tile_world_size * 2;
    add_plane(fixture, { side, side }, { side * 0.5f, 0, side * 0.5f });

    build_everything(fixture);

    NavMesh* mesh = &fixture.mesh;
    MeshTile* left = mesh.tile_at(0, 0, 0);
    MeshTile* right = mesh.tile_at(1, 0, 0);
    uint right_index = nav::decode_tile((PolyRef)mesh.tile_ref(right));
    uint left_index = nav::decode_tile((PolyRef)mesh.tile_ref(left));
    assert(links_on_side(left, 0, right_index) > 0, "side 0 is +X");
    assert(links_on_side(right, 4, left_index) > 0, "side 4 is -X");

    mesh.remove_tile(mesh.tile_ref(right))!!;

    assert(links_on_side(left, 0, right_index) == 0);
}

fn void test_add_tile_faults_when_occupied() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    build_everything(fixture);
    char[] duplicate = tile_data_of(fixture.builder.tile_mesh(0, 0));
    defer free(duplicate);

    assert(@catch(fixture.mesh.add_tile(duplicate, {})) == nav::TILE_OCCUPIED);
}

fn void test_removing_a_tile_invalidates_its_refs_through_the_salt() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    add_plane(fixture, { tile, tile }, { tile * 0.5f, 0, tile * 0.5f });
    build_everything(fixture);
    NavMesh* mesh = &fixture.mesh;
    TileRef ref = mesh.tile_ref_at(0, 0, 0);
    PolyRef base = mesh.poly_ref_base(mesh.tile_at(0, 0, 0));
    assert(mesh.is_valid_ref(base));

    assert(mesh.remove_tile(ref)!!.len == 0, "the mesh freed its own blob");

    assert(!mesh.is_valid_ref(base));
    assert(@catch(mesh.tile_and_poly(base)) == nav::INVALID_REF);
    assert(@catch(mesh.remove_tile(ref)) == nav::INVALID_REF);
    mesh.add_tile(tile_data_of(fixture.builder.tile_mesh(0, 0)), { .free_data = true })!!;
    PolyRef rebased = mesh.poly_ref_base(mesh.tile_at(0, 0, 0));
    assert(nav::decode_tile(rebased) == nav::decode_tile(base));
    assert(nav::decode_salt(rebased) != nav::decode_salt(base));
}
