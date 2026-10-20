module c3d_physics_cloth_color_test;

import c3d::physics::cloth @public;

const uint GRID_SIDE @local = 4;

fn ClothConstraint[] grid_edges(Allocator allocator) @local {
    uint count = 3 * (GRID_SIDE - 1) * (GRID_SIDE - 1) + 2 * (GRID_SIDE - 1);
    ClothConstraint[] edges = alloc::new_array(allocator, ClothConstraint, count);
    usz next;
    for (uint row = 0; row < GRID_SIDE; row++) {
        for (uint column = 0; column < GRID_SIDE; column++) {
            uint particle = row * GRID_SIDE + column;
            if (column + 1 < GRID_SIDE) edges[next++] = { .first = particle, .second = particle + 1, .rest_length = 1 };
            if (row + 1 < GRID_SIDE) {
                edges[next++] = { .first = particle, .second = particle + GRID_SIDE, .rest_length = 1 };
            }
            if (column + 1 < GRID_SIDE && row + 1 < GRID_SIDE) {
                edges[next++] = { .first = particle, .second = particle + GRID_SIDE + 1, .rest_length = 1.5f };
            }
        }
    }
    return edges;
}

fn void test_color_starts_split_edges_that_share_no_particle() @test {
    @pool() {
        ClothConstraint[] edges = grid_edges(tmem);
        ClothConstraint[] unreported = alloc::new_array(tmem, ClothConstraint, edges.len);
        unreported[..] = edges[..];
        uint[] used_colors = alloc::new_array(tmem, uint, GRID_SIDE * GRID_SIDE);
        uint[] destinations = alloc::new_array(tmem, uint, edges.len);

        ColorStarts starts;
        uint colors = cloth::order_constraints_by_color(edges, used_colors, destinations, &starts);
        assert(colors > 1 && starts[0] == 0 && starts[colors] == edges.len);
        for (uint color = 0; color < colors; color++) {
            bool[GRID_SIDE * GRID_SIDE] seen;
            foreach (edge : edges[starts[color]:starts[color + 1] - starts[color]]) {
                assert(!seen[edge.first] && !seen[edge.second]);
                seen[edge.first] = true;
                seen[edge.second] = true;
            }
        }

        cloth::order_constraints_by_color(unreported, used_colors, destinations);
        ColorStarts again;
        ClothConstraint[] reordered = alloc::new_array(tmem, ClothConstraint, edges.len);
        reordered[..] = edges[..];
        assert(cloth::order_constraints_by_color(reordered, used_colors, destinations, &again) == colors);
        foreach (index, edge : edges) {
            assert(edge.first == unreported[index].first && edge.second == unreported[index].second);
            assert(edge.first == reordered[index].first && edge.second == reordered[index].second);
        }
        assert(again[..colors] == starts[..colors]);
    };
}
