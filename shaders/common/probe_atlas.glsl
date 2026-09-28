#ifndef C3D_PROBE_ATLAS_GLSL
#define C3D_PROBE_ATLAS_GLSL

#include "gbuffer.glsl"

// Mirrored as probe_cell in probe_atlas.c3.
uvec2 probe_cell(uvec3 counts, uint slices_per_row, uvec3 cell) {
    return uvec2(
        cell.x + counts.x * (cell.z % slices_per_row),
        cell.y + counts.y * (cell.z / slices_per_row)
    );
}

// Mirrored as probe_atlas_extent in probe_atlas.c3; slices_per_row comes from the CPU.
uvec2 probe_atlas_extent(uvec3 counts, uint slices_per_row, uint cell_edge) {
    uint slice_rows = (counts.z + slices_per_row - 1u) / slices_per_row;
    return uvec2(cell_edge * counts.x * slices_per_row, cell_edge * counts.y * slice_rows);
}

// Mirrored as probe_atlas_texel in probe_atlas.c3.
vec2 probe_atlas_texel(uvec2 atlas_cell, uint cell_edge, vec3 direction) {
    vec2 interior = (encode_octahedral(direction) * 0.5 + 0.5) * float(cell_edge - 2u);
    return vec2(atlas_cell * cell_edge) + 1.0 + interior;
}

// Mirrored as probe_border_source in probe_atlas.c3.
uvec2 probe_border_source(uint cell_edge, uvec2 texel) {
    uint last = cell_edge - 1u;
    bool x_edge = texel.x == 0u || texel.x == last;
    bool y_edge = texel.y == 0u || texel.y == last;
    if (x_edge && y_edge) return uvec2(texel.x == 0u ? last - 1u : 1u, texel.y == 0u ? last - 1u : 1u);
    if (x_edge) return uvec2(texel.x == 0u ? 1u : last - 1u, last - texel.y);
    if (y_edge) return uvec2(last - texel.x, texel.y == 0u ? 1u : last - 1u);
    return texel;
}

#endif
