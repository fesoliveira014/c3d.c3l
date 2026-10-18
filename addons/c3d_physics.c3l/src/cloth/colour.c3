module c3d::physics::cloth;

import std::math;

const uint MAX_EDGE_COLOURS @private = 64; // one bit per colour in a particle's used mask; a vertex of larger degree stays uncoloured

fn void colour_edges(ClothState* state) @private {
    state.edge_colour_count = 0;
    usz edge_count = state.edges.len;
    if (!edge_count || state.coloured_edge_storage.len < edge_count) return;

    uint colour_count;
    @pool() {
        ulong[] used = alloc::new_array(tmem, ulong, (sz)state.positions.len);
        uint[] colours = alloc::new_array(tmem, uint, (sz)edge_count);
        uint[MAX_EDGE_COLOURS + 1] starts;

        foreach (index, edge : state.edges) {
            ulong blocked = used[edge.first] | used[edge.second];
            if (blocked == ulong::max) return;

            uint colour;
            while ((blocked >> colour) & 1) colour++;

            colours[index] = colour;
            used[edge.first] |= 1UL << colour;
            used[edge.second] |= 1UL << colour;
            starts[colour + 1]++;
            colour_count = math::max(colour_count, colour + 1);
        }

        for (uint colour = 0; colour < colour_count; colour++) starts[colour + 1] += starts[colour];
        state.edge_colour_start_storage[:colour_count + 1] = starts[:colour_count + 1];

        uint[MAX_EDGE_COLOURS] cursors;
        cursors[:colour_count] = starts[:colour_count];
        foreach (index, edge : state.edges) {
            state.coloured_edge_storage[cursors[colours[index]]++] = edge;
        }
    };

    state.coloured_edges = state.coloured_edge_storage[:edge_count];
    state.edge_colour_starts = state.edge_colour_start_storage[:colour_count + 1];
    state.edge_colour_count = colour_count;
}
