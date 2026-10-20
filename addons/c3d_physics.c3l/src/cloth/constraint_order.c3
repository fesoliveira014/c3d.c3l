module c3d::physics::cloth;

import std::math;

const uint MAX_CONSTRAINT_COLORS @private = 32; // one bit per color in a particle's used mask

alias ColorStarts @private = uint[MAX_CONSTRAINT_COLORS + 1]; // color c spans starts[c] up to starts[c + 1]

// Stable within a color; more than MAX_CONSTRAINT_COLORS colors keeps the incoming order and returns zero colors.
fn uint order_constraints_by_color(
    ClothConstraint[] constraints,
    uint[] used_colors,
    uint[] destinations,
    ColorStarts* starts = null,
) @private {
    used_colors[..] = 0;
    ColorStarts offsets;

    uint colors;
    foreach (index, constraint : constraints) {
        uint blocked = used_colors[constraint.first] | used_colors[constraint.second];
        if (blocked == uint::max) return 0;

        uint color;
        while ((blocked >> color) & 1) color++;

        destinations[index] = color;
        used_colors[constraint.first] |= 1U << color;
        used_colors[constraint.second] |= 1U << color;
        offsets[color + 1]++;
        colors = math::max(colors, color + 1);
    }

    for (uint color = 1; color <= MAX_CONSTRAINT_COLORS; color++) offsets[color] += offsets[color - 1];
    if (starts) *starts = offsets;
    foreach (&destination : destinations) *destination = offsets[*destination]++;

    for (usz index = 0; index < constraints.len; index++) {
        while (destinations[index] != index) {
            uint target = destinations[index];
            @swap(constraints[index], constraints[target]);
            @swap(destinations[index], destinations[target]);
        }
    }
    return colors;
}
