module c3d::physics::cloth;

const uint MAX_CONSTRAINT_COLORS @private = 32; // one bit per color in a particle's used mask

// Stable within a color; more than MAX_CONSTRAINT_COLORS colors keeps the incoming order.
fn void order_constraints_by_color(
    ClothConstraint[] constraints,
    uint[] used_colors,
    uint[] destinations,
) @private {
    used_colors[..] = 0;
    uint[MAX_CONSTRAINT_COLORS + 1] starts;

    foreach (index, constraint : constraints) {
        uint blocked = used_colors[constraint.first] | used_colors[constraint.second];
        if (blocked == uint::max) return;

        uint color;
        while ((blocked >> color) & 1) color++;

        destinations[index] = color;
        used_colors[constraint.first] |= 1U << color;
        used_colors[constraint.second] |= 1U << color;
        starts[color + 1]++;
    }

    for (uint color = 1; color <= MAX_CONSTRAINT_COLORS; color++) starts[color] += starts[color - 1];
    foreach (&destination : destinations) *destination = starts[*destination]++;

    for (usz index = 0; index < constraints.len; index++) {
        while (destinations[index] != index) {
            uint target = destinations[index];
            @swap(constraints[index], constraints[target]);
            @swap(destinations[index], destinations[target]);
        }
    }
}
