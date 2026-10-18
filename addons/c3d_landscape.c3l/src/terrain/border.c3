module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::scene;

const uint BORDER_BAND @private = 2; // texels from an edge that a neighbour's ring reads: the edge, then the row inside
const uint ALL_BORDER_EDGES @private = 0b1111;

// Row of the border ring and bit of TerrainParams.border_edges.
// Mirrored as TERRAIN_BORDER_* in landscape/terrain_height.glsl.
enum BorderEdge : uint (TerrainNeighbour neighbour) @private {
    NORTH { TerrainNeighbour.NORTH },
    SOUTH { TerrainNeighbour.SOUTH },
    WEST { TerrainNeighbour.WEST },
    EAST { TerrainNeighbour.EAST },
}

fn uint BorderEdge.bit(self) => (uint)1 << self.ordinal;

// Past a tile's border lies the neighbour's texel one step inside its own border: the shared edge is duplicated.
fn sz border_source_index(BorderEdge edge, uint texels, sz along) @private {
    switch (edge) {
        case NORTH: return (sz)(texels - 2) * texels + along;
        case SOUTH: return (sz)texels + along;
        case WEST: return along * texels + texels - 2;
        case EAST: return along * texels + 1;
    }
}

// A tile gets its ring as it gets its owned material, so the material's slot is bound before the first draw.
fn TextureId? attach_border_ring(AssetStore* assets, MaterialId material, uint texels) @private {
    TextureDesc desc = material::texture_2d_desc(texels, (uint)BorderEdge::len, R16_UINT, "terrain_border_ring");
    desc.generate_mips = false;
    TextureId ring;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (usz)texels * BorderEdge::len * ushort::size);
        ring = assets.add_texture(desc, pixels)!;
    };
    assets.material(material).data.custom.slots[BORDER_SLOT] = material::texture_slot(ring);
    assets.mark_material_dirty(material);
    return ring;
}

// A neighbour whose map was replaced since the last update may not conform yet; its edge reads as missing.
fn ushort[]? neighbour_texels(
    Scene* scene,
    AssetStore* assets,
    TerrainSet* set,
    Entity tile,
    BorderEdge edge,
    uint texels,
) @private {
    Entity neighbour = set.neighbour(tile, edge.neighbour)!;
    TerrainDesc* desc = &scene.get(scene.node(neighbour), Terrain).desc;
    if (!assets.textures.is_live(desc.height_map)) return c3d::INVALID_ID~;

    TextureAsset* texture = assets.textures.get(desc.height_map);
    check_height_map(texture)!;
    if (texture.desc.width != texels) return c3d::INVALID_ARGUMENT~;
    return height_texels(texture);
}

// Rebuilds the tile's ring from its linked edge neighbours; an unlinked tile gets an empty ring and no edges.
fn void refresh_border_ring(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    TerrainSet* set,
) @private {
    TerrainRuntime* runtime = scene.get(node, TerrainRuntime);
    uint texels = runtime.texels;
    ushort[] ring = ((ushort*)assets.texture(runtime.border_ring).pixels.ptr)[:(usz)texels * BorderEdge::len];
    uint edges;
    bool changed;
    foreach (edge : BorderEdge::values) {
        ushort[] row = ring[edge.ordinal * texels : texels];
        if (try source = neighbour_texels(scene, assets, set, node.id, edge, texels)) {
            edges |= edge.bit();
            foreach (along, &value : row) {
                ushort sample = source[border_source_index(edge, texels, along)];
                changed |= *value != sample;
                *value = sample;
            }
        } else {
            foreach (&value : row) {
                changed |= *value != 0;
                *value = 0;
            }
        }
    }
    if (changed) assets.mark_texture_dirty(runtime.border_ring);

    TerrainParams* params = assets.@custom_params(runtime.material, TerrainParams);
    if (params.border_edges == edges) return;

    params.border_edges = edges;
    assets.mark_material_dirty(runtime.material);
}

// Refreshes the rings of the linked tiles beside grid cell (x, z) across the chosen edges.
fn void refresh_edge_neighbours(
    Scene* scene,
    AssetStore* assets,
    TerrainSet* set,
    int x,
    int z,
    uint edges,
) @private {
    foreach (edge : BorderEdge::values) {
        if (!(edges & edge.bit())) continue;

        TerrainNeighbour direction = edge.neighbour;
        if (try position = find_link_at(set.state, x + direction.x_offset, z + direction.z_offset)) {
            refresh_border_ring(scene, assets, scene.node(set.state.links[position].tile), set);
        }
    }
}

fn uint touched_edges(uint texels, TexelRect rect) @private {
    uint edges;
    if (rect.z < BORDER_BAND) edges |= BorderEdge.NORTH.bit();
    if (rect.z + rect.rows > texels - BORDER_BAND) edges |= BorderEdge.SOUTH.bit();
    if (rect.x < BORDER_BAND) edges |= BorderEdge.WEST.bit();
    if (rect.x + rect.columns > texels - BORDER_BAND) edges |= BorderEdge.EAST.bit();
    return edges;
}

<*
 Refresh the border rings that read a tile's texels after they changed.
 Reaches only the neighbours across edges whose outer two texel bands the rectangle intersects.
 @param [&inout] scene
 @param [&inout] assets : "The store given to register_terrain."
 @param [&in] tile : "A tile linked to its set."
 @param rect : "Texels written in the tile's height map."
 @require scene.has(tile, TerrainTile), scene.has(tile, TerrainRuntime)
 @require parent_set(scene, tile) != null && parent_set(scene, tile).is_linked(tile.id)
 @require rect.columns > 0 && rect.rows > 0
 @require rect.x + rect.columns <= scene.get(tile, TerrainRuntime).texels
 @require rect.z + rect.rows <= scene.get(tile, TerrainRuntime).texels
*>
fn void refresh_neighbour_rings(
    Scene* scene,
    AssetStore* assets,
    Node* tile,
    TexelRect rect,
) {
    TerrainTile* position = scene.get(tile, TerrainTile);
    refresh_edge_neighbours(
        scene:  scene,
        assets: assets,
        set:    parent_set(scene, tile),
        x:      position.x,
        z:      position.z,
        edges:  touched_edges(scene.get(tile, TerrainRuntime).texels, rect),
    );
}
