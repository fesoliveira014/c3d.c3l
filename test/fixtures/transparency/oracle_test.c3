module c3d::test::transparency_fixtures;

import std::math;

fn void test_exact_ties_and_sorted_remainder_have_literal_expected_colors() @test {
    DepthFragment[4] fragments = {
        { .depth = 0.5, .node_index = 2, .node_generation = 1, .radiance = { 0, 0, 1 }, .coverage = 0.5 },
        { .depth = 0.25, .node_index = 3, .node_generation = 1, .radiance = { 1, 1, 1 }, .coverage = 0.5 },
        { .depth = 0.75, .node_index = 0, .node_generation = 1, .radiance = { 1, 0, 0 }, .coverage = 0.5 },
        { .depth = 0.5, .node_index = 1, .node_generation = 1, .radiance = { 0, 1, 0 }, .coverage = 0.5 },
    };
    DepthFragment[4] sorted = fragments;
    order_depth_fragments(fragments[..]);
    DepthGroup[4] groups;
    uint count = classify_depth_groups(fragments[..], groups[..]);
    assert(count == 3);
    assert(groups[0].depth == 0.75 && groups[0].count == 1);
    assert(groups[1].depth == 0.5 && groups[1].begin == 1 && groups[1].count == 2);
    assert(fragments[1].node_index == 1 && fragments[2].node_index == 2);
    Color two_groups = compose_hybrid(
        ordered: fragments[..],
        groups: groups[:count],
        capacity: 2,
        sorted: sorted[..],
        background: {},
    );
    assert(two_groups == (Color){ 0.5625, 0.1875, 0.3125 });
    Color one_group = compose_hybrid(
        ordered: fragments[..],
        groups: groups[:count],
        capacity: 1,
        sorted: sorted[..],
        background: {},
    );
    assert(one_group == (Color){ 0.625, 0.375, 0.1875 });
}

fn void test_adjacent_r32_values_are_two_distinct_groups() @test {
    DepthFragment[2] fragments = {
        { .depth = 0.5, .node_index = 0 },
        { .depth = bitcast(0x3f000001u, float), .node_index = 1 },
    };
    order_depth_fragments(fragments[..]);
    DepthGroup[2] groups;
    assert(classify_depth_groups(fragments[..], groups[..]) == 2);
    assert(bitcast(groups[0].depth, uint) == 0x3f000001u);
    assert(bitcast(groups[1].depth, uint) == 0x3f000000u);
}

fn void test_planar_fixture_has_literal_depths_and_global_quad_indices() @test {
    DepthFragment[6] fragments;
    make_planar_fragments(fragments[..]);
    foreach (uint index, fragment : fragments) {
        assert(fragment.depth == PLANAR_DEPTHS[index]);
        assert(fragment.node_index == index && fragment.node_generation == 1);
        assert((9.0 - (double)PLANAR_DISTANCES[index]) / 8 == (double)fragment.depth);
    }
    QuadVertex[24] vertices;
    uint[36] indices;
    make_planar_quads(vertices: vertices[..], indices: indices[..], distances: PLANAR_DISTANCES[..]);
    assert(vertices[0].position == (float[3]){ -0.75, -0.75, -3 });
    assert(vertices[23].position == (float[3]){ -0.75, 0.75, -8 });
    assert(indices[30] == 20 && indices[35] == 23);
}

fn void test_odd_extent_box_weights_split_the_central_impulse() @test {
    Color[15] source;
    source[7] = { 30, 15, 7.5 };
    Color[2] output;
    reduce_area_box(
        source: { .width = 5, .height = 3, .pixels = source[..] },
        output: { .width = 2, .height = 1, .pixels = output[..] },
    );
    assert(output[0] == (Color){ 2, 1, 0.5 });
    assert(output[1] == (Color){ 2, 1, 0.5 });
    assert((output[0] + output[1]) * 7.5 == source[7]);
}

fn void test_area_box_linear_ramp_has_independent_odd_extent_means() @test {
    Color[5] source = { { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 }, { 3, 3, 3 }, { 4, 4, 4 } };
    Color[2] output;
    reduce_area_box(
        source: { .width = 5, .height = 1, .pixels = source[..] },
        output: { .width = 2, .height = 1, .pixels = output[..] },
    );
    assert(math::abs(output[0].x - 0.8) < 1e-12);
    assert(math::abs(output[1].x - 3.2) < 1e-12);
}

fn void test_rough_footprint_matches_fixed_reference_values_and_zero() @test {
    assert(rough_transmission_lod(
        width: 256,
        height: 128,
        roughness: 0.5,
        ior: 1.5,
    ) == 4);
    assert(rough_transmission_lod(
        width: 256,
        height: 128,
        roughness: 1,
        ior: 2,
    ) == 8);
    assert(rough_transmission_lod(
        width: 256,
        height: 128,
        roughness: 1,
        ior: 1,
    ) == 0);
    foreach (ior : IOR_VALUES) {
        assert(rough_transmission_lod(
            width: 257,
            height: 129,
            roughness: 0,
            ior: ior,
        ) == 0);
    }
    double fractional = rough_transmission_lod(
        width: 256,
        height: 128,
        roughness: 0.5,
        ior: 1.33,
    );
    assert(math::abs(fractional - 2.64) < 1e-12);
    assert(mip_level_count(257, 129) == 9);
}

fn void test_homogeneous_fog_segments_multiply_without_extra_in_scatter() @test {
    Color source = { 1, 2, 4 };
    Color second = fog_segment(
        radiance: source,
        color: FOG_COLOR,
        extinction: FOG_EXTINCTION,
        distance: 4,
    );
    Color composed = fog_segment(
        radiance: second,
        color: FOG_COLOR,
        extinction: FOG_EXTINCTION,
        distance: 2,
    );
    Color whole = fog_segment(
        radiance: source,
        color: FOG_COLOR,
        extinction: FOG_EXTINCTION,
        distance: 6,
    );
    assert((composed - whole).length() < 1e-12);
    Color additive = fog_attenuation(
        radiance: source,
        coverage: 0.5,
        extinction: FOG_EXTINCTION,
        distance: 4,
    );
    Color expected = { 0.3032653298563167, 0.6065306597126334, 1.2130613194252668 };
    assert((additive - expected).length() < 1e-12);
    assert(fog_segment(
        radiance: source,
        color: FOG_COLOR,
        extinction: 0,
        distance: 4,
    ) == source);
}

fn void test_equal_depth_readers_share_the_group_background_snapshot() @test {
    DepthFragment[2] fragments = {
        { .depth = 0.5, .node_index = 0, .radiance = { 1, 0, 0 }, .coverage = 0.5, .reader = COLOR },
        { .depth = 0.5, .node_index = 1, .radiance = { 0, 1, 0 }, .coverage = 0.5, .reader = COLOR },
    };
    DepthGroup[2] groups;
    uint count = classify_depth_groups(fragments[..], groups[..]);
    Color actual = compose_hybrid(
        ordered: fragments[..],
        groups: groups[:count],
        capacity: 1,
        sorted: fragments[..],
        background: { 0, 0, 1 },
    );
    assert(actual == (Color){ 0.125, 0.25, 0.625 });
}
