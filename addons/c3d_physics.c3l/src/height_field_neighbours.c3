module c3d::physics;

import c3d;
import c3d::asset;
import b3;

fn char apron_bit(HeightFieldSide side) @private {
    switch (side) {
        case NEGATIVE_X: return b3::HEIGHT_FIELD_APRON_NEGATIVE_X;
        case POSITIVE_X: return b3::HEIGHT_FIELD_APRON_POSITIVE_X;
        case NEGATIVE_Z: return b3::HEIGHT_FIELD_APRON_NEGATIVE_Z;
        case POSITIVE_Z: return b3::HEIGHT_FIELD_APRON_POSITIVE_Z;
    }
}

fn bool has_neighbour_data(HeightField* field) @private {
    foreach (&neighbour : field.neighbours) {
        if (neighbour.texture.generation || neighbour.material_indices.len) return true;
    }
    return false;
}

fn char neighbour_sides(HeightFieldNeighbour[] neighbours) @private {
    char sides;
    foreach (side : HeightFieldSide::values) {
        if (neighbours[side.ordinal].texture.generation) sides |= apron_bit(side);
    }
    return sides;
}

fn char? check_height_neighbours(AssetStore* assets, HeightField* field) @private {
    TextureDesc map = assets.texture(field.texture).desc;
    char sides;
    foreach (side : HeightFieldSide::values) {
        HeightFieldNeighbour* neighbour = &field.neighbours[side.ordinal];
        if (!neighbour.texture.generation) {
            if (neighbour.material_indices.len) return c3d::INVALID_ARGUMENT~;
            continue;
        }

        check_height_map(assets, neighbour.texture)!;
        TextureDesc beyond = assets.texture(neighbour.texture).desc;
        uint shared_length = side.x_offset ? map.height : map.width;
        uint beyond_length = side.x_offset ? beyond.height : beyond.width;
        if (beyond.format != map.format || beyond_length != shared_length) return c3d::INVALID_ARGUMENT~;

        usz cell_count = (usz)(beyond.width - 1) * (usz)(beyond.height - 1);
        if (neighbour.material_indices.len && neighbour.material_indices.len != cell_count) {
            return c3d::INVALID_ARGUMENT~;
        }
        sides |= apron_bit(side);
    }
    return sides;
}

fn void? check_neighbour_cells(HeightField* field, usz face_material_count) @private {
    foreach (&neighbour : field.neighbours) check_cell_values(neighbour.material_indices, face_material_count)!;
}

// Where the map ends and a neighbour continues it, the ring holds the neighbour's cells beside the shared edge.
fn char[] ringed_materials(
    AssetStore* assets,
    char[] indices,
    MapCells map,
    HeightFieldWindow window,
    HeightFieldNeighbour[] neighbours,
) @private {
    bool neighbour_indices;
    foreach (&neighbour : neighbours) neighbour_indices = neighbour_indices || neighbour.material_indices.len > 0;
    if (!indices.len && !neighbour_indices) return {};

    char interior_sides = window_apron_sides(window, map);
    uint padding = apron_padding(interior_sides | neighbour_sides(neighbours));
    uint columns = window.count_x + 2 * padding;
    uint rows = window.count_z + 2 * padding;
    char[] ring = alloc::new_array(tmem, char, (sz)((usz)columns * rows));
    if (indices.len) {
        for (uint row = 0; row < rows; row++) {
            usz source_row = padded_map_index(window.z, row, padding, map.z);
            for (uint column = 0; column < columns; column++) {
                usz source_column = padded_map_index(window.x, column, padding, map.x);
                ring[(usz)row * columns + column] = indices[source_row * map.x + source_column];
            }
        }
    }

    foreach (side : HeightFieldSide::values) {
        HeightFieldNeighbour* neighbour = &neighbours[side.ordinal];
        if ((interior_sides & apron_bit(side)) || !neighbour.texture.generation) continue;

        write_neighbour_cells(
            ring:      ring,
            columns:   columns,
            padding:   padding,
            window:    window,
            side:      side,
            neighbour: neighbour,
            beyond:    assets.texture(neighbour.texture).desc,
        );
    }
    return ring;
}

fn char neighbour_cell(HeightFieldNeighbour* neighbour, usz index) @local {
    return neighbour.material_indices.len ? neighbour.material_indices[index] : 0; // no indices leave the cells solid
}

fn void write_neighbour_cells(
    char[] ring,
    uint columns,
    uint padding,
    HeightFieldWindow window,
    HeightFieldSide side,
    HeightFieldNeighbour* neighbour,
    TextureDesc beyond,
) @local {
    usz beyond_columns = (usz)beyond.width - 1;
    switch (side) {
        case NEGATIVE_X:
        case POSITIVE_X:
            usz beyond_column = side == NEGATIVE_X ? beyond_columns - 1 : 0;
            usz ring_column = side == NEGATIVE_X ? 0 : (usz)(padding + window.count_x);
            for (uint row = 0; row < window.count_z; row++) {
                usz index = (usz)(window.z + row) * beyond_columns + beyond_column;
                ring[(usz)(row + padding) * columns + ring_column] = neighbour_cell(neighbour, index);
            }
        case NEGATIVE_Z:
        case POSITIVE_Z:
            usz beyond_row = side == NEGATIVE_Z ? (usz)beyond.height - 2 : 0;
            usz ring_row = side == NEGATIVE_Z ? 0 : (usz)(padding + window.count_z);
            for (uint column = 0; column < window.count_x; column++) {
                usz index = beyond_row * beyond_columns + (usz)(window.x + column);
                ring[ring_row * columns + (usz)(padding + column)] = neighbour_cell(neighbour, index);
            }
    }
}
