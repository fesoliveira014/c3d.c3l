module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::scene;

// Where the texels of an edit along one axis lie in a neighbour at that axis offset.
struct AxisSpan @private {
    uint first;  // in the edited tile
    uint mirror; // in the neighbour
    uint length;
}

struct SharedStrip @private {
    TexelRect source; // in the edited tile
    TexelRect target; // in the neighbour
}

struct EdgeWrite @private {
    Entity    neighbour;
    TexelRect target;    // texels the copy changed
}

<*
 Copy a tile edit's edge texels into its neighbours and refresh the rings that read them.
 Call after writing the tile's texels and calling mark_dirty on the tile.
 Call mark_changed on the bodies of the edited tile and of the neighbours in the result.
 @param [&inout] scene : "Registered with register_terrain."
 @param [&inout] assets : "The store given to register_terrain."
 @param tile : "A tile linked to this set."
 @param rect : "Texels written in place in the tile's height map."
 @require rect.columns > 0 && rect.rows > 0
 @require rect.x + rect.columns <= self.texels
 @require rect.z + rect.rows <= self.texels
 @return "Bit n is set when the TerrainNeighbour of ordinal n changed; set.neighbour names its tile."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED
*>
fn uint? TerrainSet.propagate_edit(
    &self,
    Scene* scene,
    AssetStore* assets,
    Entity tile,
    TexelRect rect,
) {
    if (!self.is_linked(tile)) return c3d::INVALID_ARGUMENT~;

    ushort[] edited = conforming_texels(
        scene:  scene,
        assets: assets,
        tile:   tile,
        texels: self.texels,
    )!;
    EdgeWrite[TerrainNeighbour::len] writes;
    uint count;
    uint changed_neighbours;
    foreach (direction : TerrainNeighbour::values) {
        if (try strip = shared_strip(direction, self.texels, rect) && try neighbour = self.neighbour(tile, direction)) {
            ushort[]? texels = conforming_texels(
                scene:  scene,
                assets: assets,
                tile:   neighbour,
                texels: self.texels,
            );
            if (catch texels) continue;

            bool changed = copy_strip(
                edited:    edited,
                neighbour: texels,
                texels:    self.texels,
                strip:     strip,
            );
            if (!changed) continue;

            Node* node = scene.node(neighbour);
            mark_dirty(
                scene:  scene,
                assets: assets,
                node:   node,
                rect:   strip.target,
            )!;
            writes[count] = { .neighbour = neighbour, .target = strip.target };
            count++;
            changed_neighbours |= (uint)1 << direction.ordinal;
        }
    }
    // Every copy lands first: a ring row reads texels of the tiles around it.
    refresh_neighbour_rings(
        scene:  scene,
        assets: assets,
        tile:   scene.node(tile),
        rect:   rect,
    );
    foreach (write : writes[:count]) {
        refresh_neighbour_rings(
            scene:  scene,
            assets: assets,
            tile:   scene.node(write.neighbour),
            rect:   write.target,
        );
    }
    return changed_neighbours;
}

// A neighbour across a side duplicates the tile's edge row or column there; none across no side.
fn AxisSpan? shared_span(
    int offset,
    uint texels,
    uint first,
    uint length,
) @private {
    if (offset < 0) {
        if (first != 0) return NOT_FOUND~;
        return { .first = 0, .mirror = texels - 1, .length = 1 };
    }
    if (offset > 0) {
        if (first + length != texels) return NOT_FOUND~;
        return { .first = texels - 1, .mirror = 0, .length = 1 };
    }
    return { .first = first, .mirror = first, .length = length };
}

fn SharedStrip? shared_strip(TerrainNeighbour direction, uint texels, TexelRect rect) @private {
    AxisSpan columns = shared_span(
        offset: direction.x_offset,
        texels: texels,
        first:  rect.x,
        length: rect.columns,
    )!;
    AxisSpan rows = shared_span(
        offset: direction.z_offset,
        texels: texels,
        first:  rect.z,
        length: rect.rows,
    )!;
    return {
        .source = { .x = columns.first, .z = rows.first, .columns = columns.length, .rows = rows.length },
        .target = { .x = columns.mirror, .z = rows.mirror, .columns = columns.length, .rows = rows.length },
    };
}

// Whether any texel of the neighbour changed.
fn bool copy_strip(
    ushort[] edited,
    ushort[] neighbour,
    uint texels,
    SharedStrip strip,
) @private {
    bool changed;
    for (uint row = 0; row < strip.source.rows; row++) {
        usz source = (usz)(strip.source.z + row) * texels + strip.source.x;
        usz target = (usz)(strip.target.z + row) * texels + strip.target.x;
        for (uint column = 0; column < strip.source.columns; column++) {
            changed |= neighbour[target + column] != edited[source + column];
            neighbour[target + column] = edited[source + column];
        }
    }
    return changed;
}
