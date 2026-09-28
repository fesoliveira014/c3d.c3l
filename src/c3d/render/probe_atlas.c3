module c3d::render;

import c3d;
import c3d::light;
import c3d::shader;
import std::math;

$assert shader::PROBE_ATLAS_COLUMNS * shader::PROBE_VISIBILITY_CELL == 4096;

fn uint probe_slices_per_row(uint[<3>] counts) @private {
    return math::min(counts.z, shader::PROBE_ATLAS_COLUMNS / counts.x);
}

// Mirrored as probe_cell in probe_atlas.glsl.
fn uint[<2>] probe_cell(uint[<3>] counts, uint slices_per_row, uint[<3>] cell) @private {
    return {
        cell.x + counts.x * (cell.z % slices_per_row),
        cell.y + counts.y * (cell.z / slices_per_row),
    };
}

fn uint[<3>] probe_from_cell(uint[<3>] counts, uint slices_per_row, uint[<2>] atlas_cell) @private {
    uint slice_column = atlas_cell.x / counts.x;
    uint slice_row = atlas_cell.y / counts.y;
    return { atlas_cell.x % counts.x, atlas_cell.y % counts.y, slice_row * slices_per_row + slice_column };
}

// Mirrored as probe_atlas_extent in probe_atlas.glsl.
fn uint[<2>] probe_atlas_extent(uint[<3>] counts, uint cell_edge) @private {
    uint slices_per_row = probe_slices_per_row(counts);
    uint slice_rows = (counts.z + slices_per_row - 1) / slices_per_row;
    return { cell_edge * counts.x * slices_per_row, cell_edge * counts.y * slice_rows };
}

// Mirrored as probe_atlas_texel in probe_atlas.glsl.
fn Vec2 probe_atlas_texel(uint[<2>] atlas_cell, uint cell_edge, Vec3 direction) @private {
    Vec2 interior = (encode_octahedral(direction) * 0.5f + 0.5f) * (float)(cell_edge - 2);
    return (Vec2)(atlas_cell * cell_edge) + 1 + interior;
}

// Mirrored as probe_border_source in probe_atlas.glsl.
fn uint[<2>] probe_border_source(uint cell_edge, uint[<2>] texel) @private {
    uint last = cell_edge - 1;
    bool x_edge = texel.x == 0 || texel.x == last;
    bool y_edge = texel.y == 0 || texel.y == last;
    if (x_edge && y_edge) return { texel.x == 0 ? last - 1 : 1, texel.y == 0 ? last - 1 : 1 };
    if (x_edge) return { texel.x == 0 ? 1 : last - 1, last - texel.y };
    if (y_edge) return { last - texel.x, texel.y == 0 ? 1 : last - 1 };
    return texel;
}
