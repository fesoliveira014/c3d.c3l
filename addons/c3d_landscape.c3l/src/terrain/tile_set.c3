module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

const uint INITIAL_TILE_CAPACITY @private = 16; // 256 B of links; a 4 x 4 grid fits before the first growth

<*
 Direction from a tile to one of its eight neighbours; north is toward lower z.
*>
enum TerrainNeighbour : int (int x_offset, int z_offset) {
    WEST { -1, 0 },
    EAST { 1, 0 },
    NORTH { 0, -1 },
    SOUTH { 0, 1 },
    NORTH_WEST { -1, -1 },
    NORTH_EAST { 1, -1 },
    SOUTH_WEST { -1, 1 },
    SOUTH_EAST { 1, 1 },
}

<*
 Shared settings and neighbour links of a grid of terrain tiles under one parent node.
*>
struct TerrainSet {
    uint  texels;           // texels per side of every tile (CHUNK_CELLS·2^n + 1)
    float cell_size;
    float height_scale;
    TerrainSetState* state; // neighbour table, owned
}

<*
 Grid coordinates of a terrain tile within its parent TerrainSet.
 Remove it before reparenting a linked tile; reparenting does not unlink.
*>
struct TerrainTile {
    int x;
    int z;
}

<*
 A linked tile of a set and the grid cell it occupies.
*>
struct TerrainSetLink {
    Entity tile;
    int    x;
    int    z;
}

<*
 Linked tiles of a set, written by the library and freed with the set.
*>
struct TerrainSetState {
    Allocator        allocator;
    AssetStore*      assets; // borrowed; a tile that leaves refreshes its neighbours' rings through it
    TerrainSetLink[] links; // capacity; the first count entries are linked
    uint             count;
}

<*
 Side length of one tile, (texels - 1) · cell_size.
 @require self.texels > 1
 @pure
*>
fn float TerrainSet.tile_extent(&self) => (float)(self.texels - 1) * self.cell_size;

<*
 Whether a tile node is linked into the set.
 @param tile : "A child node of the set's node."
*>
fn bool TerrainSet.is_linked(&self, Entity tile) {
    return self.state != null && @ok(find_link(self.state, tile));
}

<*
 The linked tile next to a linked tile, in the direction.
 @param tile : "A child node of the set's node."
 @return? NOT_FOUND
*>
fn Entity? TerrainSet.neighbour(&self, Entity tile, TerrainNeighbour direction) {
    if (!self.state) return NOT_FOUND~;
    TerrainSetState* state = self.state;
    TerrainSetLink origin = state.links[find_link(state, tile)!];

    return state.links[find_link_at(state, origin.x + direction.x_offset, origin.z + direction.z_offset)!].tile;
}

fn sz? find_link(TerrainSetState* state, Entity tile) @private {
    foreach (position, link : state.links[:state.count]) {
        if (c3d::same_id(link.tile, tile)) return position;
    }
    return NOT_FOUND~;
}

fn sz? find_link_at(TerrainSetState* state, int x, int z) @private {
    foreach (position, link : state.links[:state.count]) {
        if (link.x == x && link.z == z) return position;
    }
    return NOT_FOUND~;
}

fn TerrainSet* parent_set(Scene* scene, Node* node) @private {
    return node.parent ? scene.get(node.parent, TerrainSet) : null;
}

fn bool is_placed_in_set(Node* node, TerrainTile* tile, TerrainSet* set) @private {
    if (node.transform_space != TransformSpace.PARENT) return false;

    float extent = set.tile_extent();
    Vec3 expected = { (float)tile.x * extent, 0, (float)tile.z * extent };
    Quat rotation = node.local.rotation;
    Vec3 tilt = { rotation.i, rotation.j, rotation.k };
    return (node.local.position - expected).length() <= RIGID_TOLERANCE
      && tilt.length() <= RIGID_TOLERANCE
      && (node.local.scale - (Vec3){ 1, 1, 1 }).length() <= RIGID_TOLERANCE;
}

fn bool same_layers(TerrainDesc* first, TerrainDesc* second) @private {
    foreach (index, layer : first.layers) {
        if (!c3d::same_id(layer, second.layers[index])) return false;
    }
    return true;
}

fn void? check_tile(
    Scene* scene,
    Node* node,
    TerrainDesc* desc,
    uint texels,
) @private {
    TerrainTile* tile = scene.get(node, TerrainTile);
    if (!tile) return;

    TerrainSet* set = parent_set(scene, node);
    if (!set) return c3d::INVALID_ARGUMENT~;
    if (set.texels != texels || set.cell_size != desc.cell_size || set.height_scale != desc.height_scale) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!is_placed_in_set(node, tile, set)) return c3d::INVALID_ARGUMENT~;
    if (!set.state) return;

    foreach (link : set.state.links[:set.state.count]) {
        if (link.x == tile.x && link.z == tile.z) return c3d::INVALID_ARGUMENT~;
        TerrainDesc* peer = &scene.get(scene.node(link.tile), Terrain).desc;
        if (peer.lod_threshold != desc.lod_threshold || peer.lod_hysteresis != desc.lod_hysteresis
            || !same_layers(peer, desc)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn TerrainSetState*? acquire_set_state(Scene* scene, AssetStore* assets, TerrainSet* set) @private {
    if (set.state) return set.state;

    TerrainSetState*? created = alloc::new_try(scene.allocator, TerrainSetState);
    if (catch created) return c3d::CAPACITY_EXCEEDED~;
    created.allocator = scene.allocator;
    created.assets = assets;
    set.state = created;
    return created;
}

fn void? reserve_link(TerrainSetState* state) @private {
    if (state.count < state.links.len) return;

    sz capacity = state.links.len ? (sz)state.links.len * 2 : INITIAL_TILE_CAPACITY;
    TerrainSetLink[]? grown = alloc::new_array_try(state.allocator, TerrainSetLink, capacity);
    if (catch grown) return c3d::CAPACITY_EXCEEDED~;
    grown[:state.count] = state.links[:state.count];
    alloc::free(state.allocator, state.links.ptr);
    state.links = grown;
}

fn void? link_tile(Scene* scene, AssetStore* assets, Node* node) @private {
    TerrainTile* tile = scene.get(node, TerrainTile);
    if (!tile) return;

    TerrainSetState* state = acquire_set_state(scene, assets, parent_set(scene, node))!;
    reserve_link(state)!;
    state.links[state.count] = { .tile = node.id, .x = tile.x, .z = tile.z };
    state.count++;
}

// The tile's own ring empties and its former neighbours drop their rows toward it.
fn void unlink_tile(Scene* scene, Entity tile) @private {
    Node* node = scene.node(tile);
    TerrainSet* set = parent_set(scene, node);
    if (!set || !set.state) return;

    TerrainSetState* state = set.state;
    if (try position = find_link(state, tile)) {
        TerrainSetLink departed = state.links[position];
        state.count--;
        state.links[position] = state.links[state.count];
        // A prepare that fails after linking has not added the runtime yet.
        if (scene.has(node, TerrainRuntime)) refresh_border_ring(scene, state.assets, node, set);
        refresh_edge_neighbours(
            scene:  scene,
            assets: state.assets,
            set:    set,
            x:      departed.x,
            z:      departed.z,
            edges:  ALL_BORDER_EDGES,
        );
    }
}

// The tile's ring reads its neighbours' texels and their rings read the tile's.
fn void refresh_tile_rings(Scene* scene, AssetStore* assets, Node* node) @private {
    TerrainTile* tile = scene.get(node, TerrainTile);
    TerrainSet* set = parent_set(scene, node);
    refresh_border_ring(scene, assets, node, set);
    refresh_edge_neighbours(
        scene:  scene,
        assets: assets,
        set:    set,
        x:      tile.x,
        z:      tile.z,
        edges:  ALL_BORDER_EDGES,
    );
}

// Re-validates a prepared tile; a failure leaves it unlinked.
fn void? relink_tile(Scene* scene, AssetStore* assets, Node* node) @private {
    if (!scene.has(node, TerrainTile)) return;

    unlink_tile(scene, node.id);
    TerrainRuntime* runtime = scene.get(node, TerrainRuntime);
    check_tile(
        scene:  scene,
        node:   node,
        desc:   &scene.get(node, Terrain).desc,
        texels: runtime.texels,
    )!;
    if (!runtime.border_ring.generation) {
        runtime.border_ring = attach_border_ring(assets, runtime.material, runtime.texels)!;
    }
    link_tile(scene, assets, node)!;
    refresh_tile_rings(scene, assets, node);
}

// A hook runs inside the removal, so the tile's parent and its set are still alive.
fn void remove_tile_link(Entity entity, void* component, void* user) @private {
    unlink_tile((Scene*)user, entity);
}

fn void remove_set(Entity entity, void* component, void* user) @private {
    TerrainSet* set = component;
    TerrainSetState* state = set.state;
    if (!state) return;

    Scene* scene = user;
    uint tiles = state.count;
    state.count = 0;
    foreach (link : state.links[:tiles]) {
        refresh_border_ring(scene, state.assets, scene.node(link.tile), set);
    }
    alloc::free(state.allocator, state.links.ptr);
    alloc::free(state.allocator, state);
}
