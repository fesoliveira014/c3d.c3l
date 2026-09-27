module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;
import c3d::scene;

const float LINK_RADIUS @private = 0.6f;
const uint  LINK_GRID_TILES @private = 2;

struct LinkFixture @private {
    BuilderFixture* builder;
    Node*           node;
}

// A 2 by 2 tile floor with a link from the centre of tile (0, 0) to the centre of tile (1, 0).
fn LinkFixture setup_link(bool bidirectional = true) @private {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    setup(fixture, tile_grid_bounds(LINK_GRID_TILES));
    float tile = fixture.builder.tile_world_size;
    float side = tile * LINK_GRID_TILES;
    add_plane(fixture, { side, side }, { side * 0.5f, 0, side * 0.5f });
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    fixture.scene.add_nav_link(node, {
        .start         = { tile * 0.5f, 0, tile * 0.5f },
        .end           = { tile * 1.5f, 0, tile * 0.5f },
        .radius        = LINK_RADIUS,
        .area          = nav::WALKABLE_AREA,
        .bidirectional = bidirectional,
    })!!;
    build_everything(fixture);
    return { .builder = fixture, .node = node };
}

fn void teardown_link(LinkFixture* fixture) @private {
    teardown(fixture.builder);
    free(fixture.builder);
}

fn PolyRef link_on_edge(MeshTile* tile, Poly* poly, char edge) @private {
    for (uint link = poly.first_link; link != nav::NULL_LINK; link = tile.links[link].next) {
        if (tile.links[link].edge == edge) return tile.links[link].ref;
    }
    return (PolyRef)0;
}

fn bool links_to(MeshTile* tile, uint poly, PolyRef target) @private {
    for (uint link = tile.polys[poly].first_link; link != nav::NULL_LINK; link = tile.links[link].next) {
        if (tile.links[link].ref == target) return true;
    }
    return false;
}

fn uint tile_slot(NavMesh* mesh, MeshTile* tile) @private => nav::decode_tile((PolyRef)mesh.tile_ref(tile));

fn void test_off_mesh_connection_links_both_ends() @test {
    LinkFixture fixture = setup_link();
    defer teardown_link(&fixture);
    NavMesh* mesh = &fixture.builder.mesh;
    MeshTile* start_tile = mesh.tile_at(0, 0, 0);
    MeshTile* end_tile = mesh.tile_at(1, 0, 0);
    assert(start_tile.header.off_mesh_count == 1 && end_tile.header.off_mesh_count == 0);
    OffMeshConnection* connection = &start_tile.off_mesh[0];
    Poly* poly = &start_tile.polys[connection.poly];
    PolyRef connection_ref = mesh.poly_ref_base(start_tile) | (PolyRef)connection.poly;

    PolyRef start_landing = link_on_edge(start_tile, poly, 0);
    PolyRef end_landing = link_on_edge(start_tile, poly, 1);

    assert(nav::decode_tile(start_landing) == tile_slot(mesh, start_tile));
    assert(nav::decode_tile(end_landing) == tile_slot(mesh, end_tile));
    assert(links_to(start_tile, nav::decode_poly(start_landing), connection_ref));
    assert(links_to(end_tile, nav::decode_poly(end_landing), connection_ref), "bidirectional");

    mesh.remove_tile(mesh.tile_ref(end_tile))!!;

    assert(!link_on_edge(start_tile, poly, 1));
    assert(link_on_edge(start_tile, poly, 0) == start_landing);
}

fn void test_link_change_relinks_without_rebuilding() @test {
    LinkFixture fixture = setup_link();
    defer teardown_link(&fixture);
    BuilderFixture* builder = fixture.builder;
    TileRecord[] tiles = builder.builder.tiles;
    TileRef[LINK_GRID_TILES * LINK_GRID_TILES] refs;
    uint[LINK_GRID_TILES * LINK_GRID_TILES] revisions;
    foreach (index, record : tiles) {
        refs[index] = record.ref;
        revisions[index] = record.revision;
    }
    NavLink* link = builder.scene.get(fixture.node, NavLink);

    link.bidirectional = false;
    link.mark_changed();
    builder.builder.sync_sources(&builder.scene, &builder.assets);

    assert(builder.builder.dirty_count == 0);
    assert(tiles[0].relink && tiles[1].relink && !tiles[2].relink && !tiles[3].relink);
    NavSyncResult result = nav::nav_sync(
        builder: &builder.builder,
        mesh:    &builder.mesh,
        scene:   &builder.scene,
        assets:  &builder.assets,
        budget:  0,
    );
    assert(result.installed == 2 && result.built == 0 && result.failed == 0);
    foreach (index, record : tiles) {
        assert(record.revision == revisions[index] && !record.relink);
        bool relinked = index < 2;
        assert((nav::decode_salt((PolyRef)record.ref) != nav::decode_salt((PolyRef)refs[index])) == relinked);
    }
    assert(builder.mesh.tile_at(0, 0, 0).off_mesh[0].flags == 0, "one-way now");
}

fn void test_removing_a_link_node_relinks_its_tiles() @test {
    LinkFixture fixture = setup_link();
    defer teardown_link(&fixture);
    BuilderFixture* builder = fixture.builder;
    TileRef before = builder.builder.tiles[0].ref;

    builder.scene.remove_later(fixture.node);
    builder.scene.flush_removals();
    NavSyncResult result = build_everything(builder);

    MeshTile* start_tile = builder.mesh.tile_at(0, 0, 0);
    assert(result.installed == 2 && result.built == 0);
    assert(start_tile.header.off_mesh_count == 0);
    assert(nav::decode_salt((PolyRef)builder.builder.tiles[0].ref) != nav::decode_salt((PolyRef)before));
}

fn void test_add_nav_link_rejects_bad_input() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup(fixture, tile_grid_bounds(1));
    defer teardown(fixture);
    Node* node = fixture.scene.add_node()!!;
    NavLink valid = { .start = { 0, 0, 0 }, .end = { 1, 0, 0 }, .radius = LINK_RADIUS };
    NavLink flat = valid;
    flat.radius = 0;
    NavLink looped = valid;
    looped.end = looped.start;

    assert(@catch(fixture.scene.add_nav_link(node, flat)) == c3d::INVALID_ARGUMENT);
    assert(@catch(fixture.scene.add_nav_link(node, looped)) == c3d::INVALID_ARGUMENT);
    fixture.scene.add_nav_link(node, valid)!!;
    assert(fixture.scene.get(node, NavLink).flags == nav::POLY_FLAG_WALK);
    assert(@catch(fixture.scene.add_nav_link(node, valid)) == nav::LINK_EXISTS);
}
