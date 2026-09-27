module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const int   CACHE_GRID_TILES @private = 3;
const uint  CACHE_TILE_CELLS @private = 32;
const float CACHE_CELL_SIZE @private = 0.3f;
const float CACHE_CELL_HEIGHT @private = 0.2f;
const float CACHE_TILE_WORLD @private = CACHE_TILE_CELLS * CACHE_CELL_SIZE;
const uint  CACHE_OBSTACLES @private = 80; // past MAX_OBSTACLE_REQUESTS, so a full queue faults before the slots run out
const usz   CACHE_BUILD_BYTES @private = 256 * 1024;
const uint  DRAIN_BUDGET @private = 64;
const uint  UPDATE_BUDGET @private = 4;
const float OBSTACLE_RADIUS @private = 1;
const float OBSTACLE_HEIGHT @private = 2;
const float OBSTACLE_BASE_Y @private = -0.5f; // below the floor, so the cylinder spans its height

struct CacheFixture @private {
    TileCache cache;
    NavMesh   mesh;
}

// Header, vertices and polygons of a resident tile, links cleared; they carry the tile's salt.
struct TileSnapshot @private {
    TileHeader header;
    Vec3[]     verts;
    Poly[]     polys;
}

// A 3 by 3 grid of flat walkable layers at height 0 with portals on every tile side, none built.
fn void setup_cache(CacheFixture* fixture) @private {
    TileCacheDesc desc = {
        .cell_size                = CACHE_CELL_SIZE,
        .cell_height              = CACHE_CELL_HEIGHT,
        .width                    = CACHE_TILE_CELLS,
        .height                   = CACHE_TILE_CELLS,
        .walkable_height          = 2,
        .walkable_radius          = 0.6f,
        .walkable_climb           = 0.9f,
        .max_simplification_error = 1.3f,
        .max_tiles                = CACHE_GRID_TILES * CACHE_GRID_TILES,
        .max_obstacles            = CACHE_OBSTACLES,
    };
    fixture.cache = nav::create_tile_cache(mem, desc, CACHE_BUILD_BYTES)!!;
    fixture.mesh = nav::create_nav_mesh(mem, {
        .tile_width  = CACHE_TILE_WORLD,
        .tile_height = CACHE_TILE_WORLD,
        .max_tiles   = CACHE_GRID_TILES * CACHE_GRID_TILES,
    })!!;
    for (int tile_z = 0; tile_z < CACHE_GRID_TILES; tile_z++) {
        for (int tile_x = 0; tile_x < CACHE_GRID_TILES; tile_x++) {
            fixture.cache.add_tile(flat_layer_blob(tile_x, tile_z), { .free_data = true })!!;
        }
    }
}

fn void teardown_cache(CacheFixture* fixture) @private {
    nav::destroy_nav_mesh(&fixture.mesh);
    nav::destroy_tile_cache(&fixture.cache);
}

fn char[] flat_layer_blob(int tile_x, int tile_z) @private {
    char[] blob;
    @pool() {
        sz cells = (sz)CACHE_TILE_CELLS * CACHE_TILE_CELLS;
        HeightfieldLayer layer = {
            .bounds      = {
                .min = { (float)tile_x * CACHE_TILE_WORLD, 0, (float)tile_z * CACHE_TILE_WORLD },
                .max = { (float)(tile_x + 1) * CACHE_TILE_WORLD, 0, (float)(tile_z + 1) * CACHE_TILE_WORLD },
            },
            .cell_size   = CACHE_CELL_SIZE,
            .cell_height = CACHE_CELL_HEIGHT,
            .width       = CACHE_TILE_CELLS,
            .height      = CACHE_TILE_CELLS,
            .max_x       = CACHE_TILE_CELLS - 1,
            .max_z       = CACHE_TILE_CELLS - 1,
            .heights     = mem::temp_array(char, cells),
            .areas       = mem::temp_array(char, cells),
            .connections = mem::temp_array(char, cells),
        };
        layer.areas[..] = nav::WALKABLE_AREA;
        for (int z = 0; z < (int)CACHE_TILE_CELLS; z++) {
            for (int x = 0; x < (int)CACHE_TILE_CELLS; x++) {
                char portals;
                char links;
                for (uint direction = 0; direction < 4; direction++) {
                    int neighbour_x = x + nav::dir_offset_x(direction);
                    int neighbour_z = z + nav::dir_offset_z(direction);
                    bool inside = neighbour_x >= 0 && neighbour_z >= 0
                        && neighbour_x < (int)CACHE_TILE_CELLS && neighbour_z < (int)CACHE_TILE_CELLS;
                    if (inside) {
                        links |= (char)(1 << direction);
                    } else {
                        portals |= (char)(1 << direction);
                    }
                }
                layer.connections[(usz)(x + z * (int)CACHE_TILE_CELLS)] = portals << 4 | links;
            }
        }
        blob = mem::new_array(char, (sz)nav::layer_blob_size(&layer));
        nav::build_tile_cache_layer(
            layer:      &layer,
            tile_x:     tile_x,
            tile_z:     tile_z,
            tile_layer: 0,
            blob:       blob,
        );
    };
    return blob;
}

fn void build_every_tile(CacheFixture* fixture) @private {
    for (int tile_z = 0; tile_z < CACHE_GRID_TILES; tile_z++) {
        for (int tile_x = 0; tile_x < CACHE_GRID_TILES; tile_x++) {
            fixture.cache.build_tiles_at(tile_x, tile_z, &fixture.mesh)!!;
        }
    }
}

fn void update_until_done(CacheFixture* fixture) @private {
    while (!fixture.cache.update(&fixture.mesh, DRAIN_BUDGET)!!) {}
}

fn Vec3 tile_centre(int tile_x, int tile_z) @private {
    return { (tile_x + 0.5f) * CACHE_TILE_WORLD, OBSTACLE_BASE_Y, (tile_z + 0.5f) * CACHE_TILE_WORLD };
}

fn TileSnapshot snapshot_tile(NavMesh* mesh, int tile_x, int tile_z) @private {
    MeshTile* tile = mesh.tile_at(tile_x, tile_z, 0);
    TileSnapshot snapshot = {
        .header = *tile.header,
        .verts  = mem::new_array(Vec3, tile.verts.len),
        .polys  = mem::new_array(Poly, tile.polys.len),
    };
    snapshot.verts[..] = tile.verts[..];
    snapshot.polys[..] = tile.polys[..];
    foreach (&poly : snapshot.polys) poly.first_link = 0;
    return snapshot;
}

fn void free_snapshot(TileSnapshot* snapshot) @private {
    free(snapshot.verts);
    free(snapshot.polys);
}

fn bool same_snapshot(TileSnapshot* first, TileSnapshot* second) @private {
    if (first.verts.len != second.verts.len || first.polys.len != second.polys.len) return false;
    if (!same_bytes(((char*)&first.header)[:TileHeader::size], ((char*)&second.header)[:TileHeader::size])) return false;
    if (!same_bytes(((char*)first.verts.ptr)[:first.verts.len * Vec3::size], ((char*)second.verts.ptr)[:second.verts.len * Vec3::size])) {
        return false;
    }
    return same_bytes(((char*)first.polys.ptr)[:first.polys.len * Poly::size], ((char*)second.polys.ptr)[:second.polys.len * Poly::size]);
}

fn bool polygon_covers(NavMesh* mesh, int tile_x, int tile_z, Vec3 point) @private {
    MeshTile* tile = mesh.tile_at(tile_x, tile_z, 0);
    foreach (&poly : tile.polys) {
        Vec3[nav::MAX_VERTS_PER_POLY] verts = nav::polygon_vertices(tile, poly);
        if (nav::point_in_polygon(point, verts[:poly.vert_count])) return true;
    }
    return false;
}

fn usz obstacles_in_state(TileCache* cache, ObstacleState state) @private {
    usz count;
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state == state) count++;
    }
    return count;
}

fn void test_adding_and_removing_an_obstacle_restores_the_tile() @test {
    CacheFixture fixture;
    setup_cache(&fixture);
    defer teardown_cache(&fixture);
    build_every_tile(&fixture);
    TileSnapshot before = snapshot_tile(&fixture.mesh, 1, 1);
    defer free_snapshot(&before);
    Vec3 centre = tile_centre(1, 1);

    ObstacleRef obstacle = fixture.cache.add_obstacle(centre, OBSTACLE_RADIUS, OBSTACLE_HEIGHT)!!;
    update_until_done(&fixture);
    TileSnapshot blocked = snapshot_tile(&fixture.mesh, 1, 1);
    defer free_snapshot(&blocked);
    bool covered_while_blocked = polygon_covers(&fixture.mesh, 1, 1, centre);
    fixture.cache.remove_obstacle(obstacle)!!;
    update_until_done(&fixture);
    TileSnapshot after = snapshot_tile(&fixture.mesh, 1, 1);
    defer free_snapshot(&after);

    assert(!same_snapshot(&before, &blocked));
    assert(!covered_while_blocked, "the polygons avoid the obstacle's cells");
    assert(same_snapshot(&before, &after));
    assert(polygon_covers(&fixture.mesh, 1, 1, centre));
    assert(@catch(fixture.cache.obstacle_by_ref(obstacle)) == nav::INVALID_REF);
}

fn void test_obstacle_change_dirties_only_overlapped_tiles() @test {
    CacheFixture fixture;
    setup_cache(&fixture);
    defer teardown_cache(&fixture);

    ObstacleRef inside = fixture.cache.add_obstacle(tile_centre(1, 1), OBSTACLE_RADIUS, OBSTACLE_HEIGHT)!!;
    fixture.cache.update(&fixture.mesh, 0)!!;
    assert(fixture.cache.update_count == 1);
    assert(fixture.cache.obstacle_by_ref(inside)!!.touched_count == 1);
    update_until_done(&fixture);

    Vec3 corner = { CACHE_TILE_WORLD, OBSTACLE_BASE_Y, CACHE_TILE_WORLD };
    fixture.cache.add_obstacle(corner, OBSTACLE_RADIUS, OBSTACLE_HEIGHT)!!;
    fixture.cache.update(&fixture.mesh, 0)!!;
    assert(fixture.cache.update_count == 4);
    update_until_done(&fixture);

    float side = CACHE_GRID_TILES * CACHE_TILE_WORLD;
    ObstacleRef wide = fixture.cache.add_box_obstacle({ .min = { 0, -1, 0 }, .max = { side, 1, side } })!!;
    fixture.cache.update(&fixture.mesh, 0)!!;
    assert(fixture.cache.obstacle_by_ref(wide)!!.touched_count == nav::MAX_TOUCHED_TILES);
    assert(fixture.cache.update_count == nav::MAX_TOUCHED_TILES);
}

fn void test_update_budget_drains_the_queue() @test {
    CacheFixture fixture;
    setup_cache(&fixture);
    defer teardown_cache(&fixture);
    for (int tile_z = 0; tile_z < CACHE_GRID_TILES; tile_z++) {
        for (int tile_x = 0; tile_x < CACHE_GRID_TILES; tile_x++) {
            CachedLayerRef[1] layer;
            assert(fixture.cache.tiles_at(tile_x, tile_z, layer[..]) == 1);
            nav::queue_rebuild(&fixture.cache, layer[0])!!;
        }
    }

    bool first = fixture.cache.update(&fixture.mesh, UPDATE_BUDGET)!!;
    bool second = fixture.cache.update(&fixture.mesh, UPDATE_BUDGET)!!;
    bool third = fixture.cache.update(&fixture.mesh, UPDATE_BUDGET)!!;

    assert(!first && !second && third);
    assert(fixture.mesh.tile_at(2, 2, 0) != null);
}

fn void test_request_queue_full_faults() @test {
    CacheFixture fixture;
    setup_cache(&fixture);
    defer teardown_cache(&fixture);
    build_every_tile(&fixture);

    for (uint index = 0; index < nav::MAX_OBSTACLE_REQUESTS; index++) {
        Vec3 base = tile_centre((int)index % CACHE_GRID_TILES, (int)index / CACHE_GRID_TILES % CACHE_GRID_TILES);
        fixture.cache.add_obstacle(base, OBSTACLE_RADIUS, OBSTACLE_HEIGHT)!!;
    }
    ObstacleRef? overflow = fixture.cache.add_obstacle(tile_centre(0, 0), OBSTACLE_RADIUS, OBSTACLE_HEIGHT);
    assert(@catch(overflow) == c3d::CAPACITY_EXCEEDED);
    update_until_done(&fixture);

    assert(fixture.cache.request_count == 0);
    assert(obstacles_in_state(&fixture.cache, PROCESSED) == nav::MAX_OBSTACLE_REQUESTS);
}
