module c3d::test::animation_blend_layout;

import c3d;
import c3d::anim @public;
import std::math;

const uint LAYOUT_MAX_SAMPLES @local = 16;
const uint LAYOUT_MAX_TRIANGLES @local = 27;
const double LAYOUT_WEIGHT_EPSILON @local = 5e-6;

struct LayoutFixture @local {
    Vec2[LAYOUT_MAX_SAMPLES] points;
    BlendTriangle[LAYOUT_MAX_TRIANGLES] triangles;
    BlendTriangleIndices[LAYOUT_MAX_TRIANGLES] prepared_triangles;
    BlendHullIndices[LAYOUT_MAX_SAMPLES] prepared_hull;
    uint count;
    uint triangle_count;
    BlendLayoutInfo info;
}

struct LayoutExpectation @local {
    uint count;
    double[] weights;
}

fn void layout_prepare(LayoutFixture* layout, uint capacity = LAYOUT_MAX_SAMPLES) @local {
    layout.info = anim::prepare_blend_layout(
        points: layout.points[:layout.count],
        triangles: layout.triangles[:layout.triangle_count],
        capacity: capacity,
        prepared_triangles: layout.prepared_triangles[..],
        prepared_hull: layout.prepared_hull[..],
    )!!;
}

fn BlendLayoutView layout_view(LayoutFixture* layout) @local {
    return {
        .points = layout.points[:layout.count],
        .triangles = layout.prepared_triangles[:layout.info.triangle_count],
        .hull = layout.prepared_hull[:layout.info.hull_count],
        .extent = layout.info.extent,
    };
}

fn void layout_expect(LayoutFixture* layout, Vec2 parameter, LayoutExpectation expected) @local {
    BlendLayoutSelection selected = anim::select_blend_layout(layout_view(layout), parameter);
    assert(selected.count == expected.count);
    double[LAYOUT_MAX_SAMPLES] weights;
    for (uint index = 0; index < selected.count; index++) {
        weights[selected.indices[index]] += selected.weights[index];
    }
    double[LAYOUT_MAX_SAMPLES] expected_weights;
    expected_weights[:expected.weights.len] = expected.weights[..];
    for (uint sample = 0; sample < layout.count; sample++) {
        assert(math::abs(weights[sample] - expected_weights[sample]) <= LAYOUT_WEIGHT_EPSILON);
    }
}

fn void layout_expect_samples(LayoutFixture* layout) @local {
    for (uint sample = 0; sample < layout.count; sample++) {
        BlendLayoutSelection selected = anim::select_blend_layout(layout_view(layout), layout.points[sample]);
        assert(selected.count == 1 && selected.indices[0] == sample && selected.weights[0] == 1);
    }
}

fn void layout_expect_fault(LayoutFixture* layout, uint capacity = LAYOUT_MAX_SAMPLES) @local {
    foreach (&triangle : layout.prepared_triangles) triangle.indices = { 0xa5, 0xa5, 0xa5 };
    foreach (&edge : layout.prepared_hull) edge.indices = { 0x5a, 0x5a };
    BlendTriangleIndices[LAYOUT_MAX_TRIANGLES] old_triangles = layout.prepared_triangles;
    BlendHullIndices[LAYOUT_MAX_SAMPLES] old_hull = layout.prepared_hull;
    bool rejected;
    if (catch failure = anim::prepare_blend_layout(
        points: layout.points[:layout.count],
        triangles: layout.triangles[:layout.triangle_count],
        capacity: capacity,
        prepared_triangles: layout.prepared_triangles[..],
        prepared_hull: layout.prepared_hull[..],
    )) {
        assert(failure == c3d::INVALID_ARGUMENT);
        rejected = true;
    }
    assert(rejected);
    foreach (uint index, triangle : layout.prepared_triangles) {
        assert(triangle.indices == old_triangles[index].indices);
    }
    foreach (uint index, edge : layout.prepared_hull) assert(edge.indices == old_hull[index].indices);
}

fn LayoutFixture layout_triangle() @local {
    LayoutFixture layout = { .count = 3, .triangle_count = 1 };
    layout.points[0] = { 0, 0 };
    layout.points[1] = { 2, 0 };
    layout.points[2] = { 0, 2 };
    layout.triangles[0] = { .indices = { 0, 1, 2 } };
    return layout;
}

fn LayoutFixture layout_grid(uint width, uint height) @local {
    LayoutFixture layout = { .count = width * height };
    for (uint y = 0; y < height; y++) for (uint x = 0; x < width; x++) {
        layout.points[y * width + x] = { (float)x, (float)y };
    }
    for (uint y = 0; y + 1 < height; y++) for (uint x = 0; x + 1 < width; x++) {
        uint a = y * width + x;
        uint b = a + 1;
        uint c = a + width;
        uint d = c + 1;
        layout.triangles[layout.triangle_count++] = { .indices = { a, b, d } };
        layout.triangles[layout.triangle_count++] = { .indices = { a, d, c } };
    }
    return layout;
}

fn LayoutFixture layout_maximal(uint count) @local {
    LayoutFixture layout = layout_triangle();
    layout.points[1] = { 4, 0 };
    layout.points[2] = { 0, 4 };
    while (layout.count < count) {
        BlendTriangle cell = layout.triangles[0];
        uint sample = layout.count++;
        layout.points[sample] = (layout.points[cell.indices[0]] + layout.points[cell.indices[1]]
          + layout.points[cell.indices[2]]) / 3.0f;
        layout.triangles[0] = { .indices = { cell.indices[0], cell.indices[1], sample } };
        layout.triangles[layout.triangle_count++] = { .indices = { cell.indices[1], cell.indices[2], sample } };
        layout.triangles[layout.triangle_count++] = { .indices = { cell.indices[2], cell.indices[0], sample } };
    }
    return layout;
}

fn void test_animation_authoring_blend_layout_exact_samples_interior_and_duration() @test {
    LayoutFixture layout = layout_triangle();
    layout_prepare(&layout);
    layout_expect_samples(&layout);
    layout_expect(&layout, { 1, 0 }, { .count = 3, .weights = { 0.5, 0.5, 0 } });
    layout_expect(&layout, { 0, 1 }, { .count = 3, .weights = { 0.5, 0, 0.5 } });
    layout_expect(&layout, { 1, 1 }, { .count = 3, .weights = { 0, 0.5, 0.5 } });
    BlendLayoutSelection selected = anim::select_blend_layout(layout_view(&layout), { 0.5f, 0.5f });
    assert(selected.weights[0] == 0.5f && selected.weights[1] == 0.25f && selected.weights[2] == 0.25f);
    double duration = selected.weights[0] + 2.0 * selected.weights[1] + 4.0 * selected.weights[2];
    assert(duration == 2);
    assert(0.25 / duration == 0.125);
    double translation = 10.0 * selected.weights[1] + 20.0 * selected.weights[2];
    assert(translation == 7.5);
    foreach (float group_weight : { 0.0f, 0.25f, 1.0f }) {
        double sum;
        foreach (weight : selected.weights) sum += (double)weight * group_weight;
        assert(math::abs(sum - group_weight) <= LAYOUT_WEIGHT_EPSILON);
    }
}

fn void test_animation_authoring_blend_layout_authored_ties_and_history_independence() @test {
    LayoutFixture square = layout_grid(2, 2);
    layout_prepare(&square);
    Vec2[9] probes = {
        { 0.5f, 0.5f }, { 0.5f, 0.50000006f }, { 0.5f, 0.5000002f },
        { -1, 0.5f }, { 2, 0.5f }, { 0.5f, -1 }, { 0.5f, 2 }, { -1, -1 }, { 2, 2 },
    };
    LayoutExpectation[9] expected = {
        { .count = 3, .weights = { 0.5, 0, 0, 0.5 } },
        { .count = 3, .weights = { 0.5, 0, 0, 0.5 } },
        { .count = 3, .weights = { 0.5, 0, 0, 0.5 } },
        { .count = 2, .weights = { 0.5, 0, 0.5, 0 } },
        { .count = 2, .weights = { 0, 0.5, 0, 0.5 } },
        { .count = 2, .weights = { 0.5, 0.5, 0, 0 } },
        { .count = 2, .weights = { 0, 0, 0.5, 0.5 } },
        { .count = 2, .weights = { 1, 0, 0, 0 } },
        { .count = 2, .weights = { 0, 0, 0, 1 } },
    };
    foreach (index, parameter : probes) layout_expect(&square, parameter, expected[index]);
    BlendLayoutSelection first = anim::select_blend_layout(layout_view(&square), probes[0]);
    (void)anim::select_blend_layout(layout_view(&square), probes[7]);
    BlendLayoutSelection after = anim::select_blend_layout(layout_view(&square), probes[0]);
    assert(first.indices == after.indices && first.weights == after.weights);
    assert(first.count == after.count);
    @swap(square.triangles[0], square.triangles[1]);
    @swap(square.triangles[0].indices[1], square.triangles[0].indices[2]);
    layout_prepare(&square);
    layout_expect(&square, probes[0], expected[0]);
}

fn void test_animation_authoring_blend_layout_relative_tolerances_and_extents() @test {
    LayoutFixture triangle = layout_triangle();
    triangle.points[1] = { 1, 0 };
    triangle.points[2] = { 0, 0.5e-10f };
    layout_expect_fault(&triangle);
    triangle.points[2].y = 2e-10f;
    layout_prepare(&triangle);
    layout_expect(&triangle, { 0.25f, 0.5e-10f }, { .count = 3, .weights = { 0.5, 0.25, 0.25 } });
    triangle = layout_triangle();
    layout_prepare(&triangle);
    assert(anim::select_blend_layout(layout_view(&triangle), { -1e-7f, 0.5f }).count == 3);
    assert(anim::select_blend_layout(layout_view(&triangle), { -4e-7f, 0.5f }).count == 2);
    foreach (float scale : { 0.0009765625f, 1048576.0f }) {
        LayoutFixture scaled = layout_grid(2, 2);
        for (uint sample = 0; sample < scaled.count; sample++) {
            scaled.points[sample] = scaled.points[sample] * scale - (Vec2){ 2 * scale, 3 * scale };
        }
        layout_prepare(&scaled);
        layout_expect(&scaled, { -1.5f * scale, -2.5f * scale }, { .count = 3, .weights = { 0.5, 0, 0, 0.5 } });
        layout_expect(&scaled, { -3 * scale, -4 * scale }, { .count = 2, .weights = { 1, 0, 0, 0 } });
    }
}

fn void test_animation_authoring_blend_layout_sliver_contains_its_points_before_a_tolerant_neighbor() @test {
    LayoutFixture layout = { .count = 4, .triangle_count = 2 };
    layout.points[0] = { 0, 0 };
    layout.points[1] = { 1, 0 };
    layout.points[2] = { 0.5f, 1 };
    layout.points[3] = { 0.5f, -1e-9f };
    layout.triangles[0] = { .indices = { 0, 1, 2 } };
    layout.triangles[1] = { .indices = { 0, 3, 1 } };
    layout_prepare(&layout);
    layout_expect(&layout, { 0.5f, -0.5e-9f }, { .count = 3, .weights = { 0.25, 0.25, 0, 0.5 } });
    layout_expect(&layout, { 0.5f, -1.01e-9f }, { .count = 2, .weights = { 0, 0, 0, 1 } });
}

fn void test_animation_authoring_blend_layout_capacity_and_compact_storage() @test {
    uint[6] counts = { 3, 4, 8, 9, 15, 16 };
    LayoutExpectation[6] centers = {
        { .count = 3, .weights = { 0.75, 0.125, 0.125 } },
        { .count = 3, .weights = { 0.625, 0, 0, 0.375 } },
        { .count = 3, .weights = { 0.625, 0, 0, 0.375 } },
        { .count = 3, .weights = { 0.5, 0, 0, 0, 0.5 } },
        { .count = 3, .weights = { 0.5, 0, 0, 0, 0, 0, 0.5 } },
        { .count = 3, .weights = { 0.625, 0, 0, 0.375 } },
    };
    foreach (index, count : counts) {
        LayoutFixture layout = count == 9 ? layout_grid(3, 3)
          : count == 15 ? layout_grid(5, 3) : layout_maximal(count);
        layout_prepare(&layout, count);
        assert(layout.info.triangle_count <= 2 * count - 5 && layout.info.hull_count <= count);
        layout_expect_samples(&layout);
        layout_expect(&layout, { 0.5f, 0.5f }, centers[index]);
    }
    foreach (uint capacity : { 1u, 2u }) {
        LayoutFixture layout = layout_triangle();
        layout_expect_fault(&layout, capacity);
    }
    LayoutFixture five = layout_maximal(5);
    layout_expect_fault(&five, 4);
    LayoutFixture fifteen = layout_grid(5, 3);
    layout_prepare(&fifteen, 16);
    Vec2[17] too_many;
    BlendTriangle[1] triangle = { { .indices = { 0, 1, 2 } } };
    BlendTriangleIndices[27] prepared_triangles;
    BlendHullIndices[16] prepared_hull;
    bool rejected;
    if (catch failure = anim::prepare_blend_layout(
        points: too_many[..],
        triangles: triangle[..],
        capacity: 16,
        prepared_triangles: prepared_triangles[..],
        prepared_hull: prepared_hull[..],
    )) {
        assert(failure == c3d::INVALID_ARGUMENT);
        rejected = true;
    }
    assert(rejected);
}

fn void test_animation_authoring_blend_layout_malformed_topology_is_atomic() @test {
    LayoutFixture valid = layout_grid(2, 2);
    LayoutFixture invalid = valid;
    invalid.count = 2;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.points[0].x = float::nan;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.points[3] = invalid.points[1];
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangles[0].indices[2] = 4;
    layout_expect_fault(&invalid);
    invalid = { .count = 6, .triangle_count = 2 };
    invalid.points[0] = { 0, 0 };
    invalid.points[1] = { 1, 0 };
    invalid.points[2] = { 0, 1 };
    invalid.points[3] = { 3, 0 };
    invalid.points[4] = { 4, 0 };
    invalid.points[5] = { 3, 1 };
    invalid.triangles[0] = { .indices = { 0, 1, 2 } };
    invalid.triangles[1] = { .indices = { 3, 4, 5 } };
    layout_expect_fault(&invalid);
    LayoutFixture bow_tie = { .count = 5, .triangle_count = 2 };
    bow_tie.points[1] = { 1, -1 };
    bow_tie.points[2] = { 1, 1 };
    bow_tie.points[3] = { -1, 1 };
    bow_tie.points[4] = { -1, -1 };
    bow_tie.triangles[0] = { .indices = { 0, 1, 2 } };
    bow_tie.triangles[1] = { .indices = { 0, 3, 4 } };
    layout_expect_fault(&bow_tie);
    LayoutFixture crossing = { .count = 6, .triangle_count = 2 };
    crossing.points[0] = { -1, 0 };
    crossing.points[1] = { 1, 0 };
    crossing.points[2] = { 0, 2 };
    crossing.points[3] = { -1, 1 };
    crossing.points[4] = { 0, -1 };
    crossing.points[5] = { 1, 1 };
    crossing.triangles[0] = { .indices = { 0, 1, 2 } };
    crossing.triangles[1] = { .indices = { 3, 4, 5 } };
    layout_expect_fault(&crossing);
}
