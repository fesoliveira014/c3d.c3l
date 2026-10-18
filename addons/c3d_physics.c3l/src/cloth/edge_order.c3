module c3d::physics::cloth;

const uint MAX_EDGE_COLORS @private = 32; // one bit per color in a particle's used mask

<*
 Order edges color-major so edges of one color share no particle.
 Leaves the order unchanged when MAX_EDGE_COLORS colors do not suffice.
 @param [inout] edges : "Sorted by first, then second; the order within a color stays sorted."
 @param [inout] used_colors : "Scratch with one entry per particle."
 @param [inout] destinations : "Scratch with one entry per edge."
 @require destinations.len == edges.len
*>
fn void order_edges_by_color(
    ClothConstraint[] edges,
    uint[] used_colors,
    uint[] destinations,
) @private {
    used_colors[..] = 0;
    uint[MAX_EDGE_COLORS + 1] starts;

    foreach (index, edge : edges) {
        uint blocked = used_colors[edge.first] | used_colors[edge.second];
        if (blocked == uint::max) return;

        uint color;
        while ((blocked >> color) & 1) color++;

        destinations[index] = color;
        used_colors[edge.first] |= 1U << color;
        used_colors[edge.second] |= 1U << color;
        starts[color + 1]++;
    }

    for (uint color = 1; color <= MAX_EDGE_COLORS; color++) starts[color] += starts[color - 1];
    foreach (&destination : destinations) *destination = starts[*destination]++;

    for (usz index = 0; index < edges.len; index++) {
        while (destinations[index] != index) {
            uint target = destinations[index];
            @swap(edges[index], edges[target]);
            @swap(destinations[index], destinations[target]);
        }
    }
}
