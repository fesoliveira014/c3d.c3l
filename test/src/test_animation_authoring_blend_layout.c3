module c3d::test::animation_blend_layout;

import c3d;
import c3d::anim @public;
import std::math;

const uint LAYOUT_MAX_SAMPLES @local = 16;
const uint LAYOUT_MAX_TRIANGLES @local = 27;
const double LAYOUT_WEIGHT_EPSILON @local = 5e-6;
const double LAYOUT_ORACLE_BOUNDARY_TOLERANCE @local = 1e-7;
const double LAYOUT_ORACLE_DISTANCE_TOLERANCE @local = 1e-12;
const uint LAYOUT_CORPUS_SEED @local = 3532026;
const uint LAYOUT_CORPUS_COUNT @local = 2000;

struct LayoutFixture @local {
    Vec2[LAYOUT_MAX_SAMPLES] points;
    BlendTriangle[LAYOUT_MAX_TRIANGLES] triangles;
    BlendTriangleIndices[LAYOUT_MAX_TRIANGLES] prepared_triangles;
    BlendHullIndices[LAYOUT_MAX_SAMPLES] prepared_hull;
    uint count;
    uint triangle_count;
    BlendLayoutInfo info;
}

struct LayoutOracle @local {
    double[LAYOUT_MAX_SAMPLES] weights;
    BlendLayoutLocation kind;
    uint authored_index;
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
        .reversed = layout.info.reversed,
        .extent = layout.info.extent,
    };
}

fn void layout_check_location(LayoutFixture* layout, Vec2 parameter) @local {
    BlendLayoutSelection actual = anim::select_blend_layout(layout_view(layout), parameter);
    LayoutOracle expected = layout_reference_location(layout, parameter);
    double[LAYOUT_MAX_SAMPLES] weights;
    double sum;
    for (uint index = 0; index < actual.count; index++) {
        assert(actual.indices[index] < layout.count && actual.weights[index] >= 0);
        weights[actual.indices[index]] += actual.weights[index];
        sum += actual.weights[index];
    }
    assert(math::abs(sum - 1) <= LAYOUT_WEIGHT_EPSILON);
    assert(actual.kind == expected.kind && actual.authored_index == expected.authored_index);
    for (uint sample = 0; sample < layout.count; sample++) {
        assert(math::abs(weights[sample] - expected.weights[sample]) <= LAYOUT_WEIGHT_EPSILON);
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

fn LayoutFixture layout_fan(uint count, bool center) @local {
    if (count == 3) return layout_triangle();
    LayoutFixture layout = { .count = count };
    uint vertices = center ? count - 1 : count;
    uint first = center ? 1 : 0;
    for (uint index = 0; index < vertices; index++) {
        double angle = 2 * math::PI * index / vertices;
        layout.points[first + index] = { (float)math::cos(angle), (float)math::sin(angle) };
    }
    if (center) {
        for (uint index = 0; index < vertices; index++) {
            layout.triangles[layout.triangle_count++] = { .indices = { 0, 1 + index, 1 + (index + 1) % vertices } };
        }
    } else {
        for (uint index = 1; index + 1 < vertices; index++) {
            layout.triangles[layout.triangle_count++] = { .indices = { 0, index, index + 1 } };
        }
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

fn LayoutOracle layout_reference_location(LayoutFixture* layout, Vec2 parameter) @local {
    for (uint sample = 0; sample < layout.count; sample++) {
        Vec2 point = layout.points[sample];
        if (point.x == parameter.x && point.y == parameter.y) {
            LayoutOracle result = { .kind = BlendLayoutLocation.SAMPLE, .authored_index = sample };
            result.weights[sample] = 1;
            return result;
        }
    }
    for (uint index = 0; index < layout.triangle_count; index++) {
        BlendTriangle triangle = layout.triangles[index];
        Vec2 a = layout.points[triangle.indices[0]];
        Vec2 b = layout.points[triangle.indices[1]];
        Vec2 c = layout.points[triangle.indices[2]];
        double pivot = (double)b.x - a.x;
        double other = (double)c.x - a.x;
        double value = (double)parameter.x - a.x;
        double below = (double)b.y - a.y;
        double diagonal = (double)c.y - a.y;
        double target = (double)parameter.y - a.y;
        if (math::abs(below) > math::abs(pivot)) {
            @swap(pivot, below);
            @swap(other, diagonal);
            @swap(value, target);
        }
        double elimination = below / pivot;
        double c_weight = (target - elimination * value) / (diagonal - elimination * other);
        double b_weight = (value - other * c_weight) / pivot;
        double a_weight = 1 - b_weight - c_weight;
        if (a_weight < -LAYOUT_ORACLE_BOUNDARY_TOLERANCE || b_weight < -LAYOUT_ORACLE_BOUNDARY_TOLERANCE
          || c_weight < -LAYOUT_ORACLE_BOUNDARY_TOLERANCE) continue;
        a_weight = math::max(0.0, a_weight);
        b_weight = math::max(0.0, b_weight);
        c_weight = math::max(0.0, c_weight);
        double sum = a_weight + b_weight + c_weight;
        LayoutOracle result = { .kind = BlendLayoutLocation.TRIANGLE, .authored_index = index };
        result.weights[triangle.indices[0]] = a_weight / sum;
        result.weights[triangle.indices[1]] = b_weight / sum;
        result.weights[triangle.indices[2]] = c_weight / sum;
        return result;
    }
    uint[LAYOUT_MAX_TRIANGLES * 3] first;
    uint[LAYOUT_MAX_TRIANGLES * 3] second;
    uint[LAYOUT_MAX_TRIANGLES * 3] identity;
    double[LAYOUT_MAX_TRIANGLES * 3] distances;
    double[LAYOUT_MAX_TRIANGLES * 3] fractions;
    uint hull_count;
    double min_x = double::max;
    double min_y = double::max;
    double max_x = -double::max;
    double max_y = -double::max;
    for (uint sample = 0; sample < layout.count; sample++) {
        min_x = math::min(min_x, (double)layout.points[sample].x);
        max_x = math::max(max_x, (double)layout.points[sample].x);
        min_y = math::min(min_y, (double)layout.points[sample].y);
        max_y = math::max(max_y, (double)layout.points[sample].y);
    }
    double closest = double::max;
    for (uint triangle = 0; triangle < layout.triangle_count; triangle++) {
        BlendTriangle input = layout.triangles[triangle];
        uint[3] corners = { input.indices[0], input.indices[1], input.indices[2] };
        for (uint edge = 0; edge < 3; edge++) {
            uint a_index = corners[edge];
            uint b_index = corners[(edge + 1) % 3];
            uint incidence;
            for (uint other_triangle = 0; other_triangle < layout.triangle_count; other_triangle++) {
                BlendTriangle other = layout.triangles[other_triangle];
                uint[3] other_corners = { other.indices[0], other.indices[1], other.indices[2] };
                for (uint other_edge = 0; other_edge < 3; other_edge++) {
                    uint from = other_corners[other_edge];
                    uint to = other_corners[(other_edge + 1) % 3];
                    incidence += (from == a_index && to == b_index) || (from == b_index && to == a_index) ? 1 : 0;
                }
            }
            if (incidence != 1) continue;
            Vec2 a = layout.points[a_index];
            Vec2 b = layout.points[b_index];
            double length = math::sqrt(((double)b.x - a.x) * ((double)b.x - a.x)
              + ((double)b.y - a.y) * ((double)b.y - a.y));
            double ux = ((double)b.x - a.x) / length;
            double uy = ((double)b.y - a.y) / length;
            double along = math::clamp(((double)parameter.x - a.x) * ux
              + ((double)parameter.y - a.y) * uy, 0.0, length);
            double projected_x = a.x + along * ux;
            double projected_y = a.y + along * uy;
            double distance = ((double)parameter.x - projected_x) * ((double)parameter.x - projected_x)
              + ((double)parameter.y - projected_y) * ((double)parameter.y - projected_y);
            first[hull_count] = a_index;
            second[hull_count] = b_index;
            identity[hull_count] = 3 * triangle + edge;
            fractions[hull_count] = along / length;
            distances[hull_count++] = distance;
            closest = math::min(closest, distance);
        }
    }
    double extent = math::max(max_x - min_x, max_y - min_y);
    for (uint edge = 0; edge < hull_count; edge++) {
        if (distances[edge] > closest + LAYOUT_ORACLE_DISTANCE_TOLERANCE * extent * extent) continue;
        LayoutOracle result = { .kind = BlendLayoutLocation.HULL, .authored_index = identity[edge] };
        result.weights[first[edge]] = 1 - fractions[edge];
        result.weights[second[edge]] = fractions[edge];
        return result;
    }
    unreachable();
}

fn void test_animation_authoring_blend_layout_exact_samples_interior_and_duration() @test {
    LayoutFixture layout = layout_triangle();
    layout_prepare(&layout);
    for (uint sample = 0; sample < layout.count; sample++) {
        BlendLayoutSelection selected = anim::select_blend_layout(layout_view(&layout), layout.points[sample]);
        assert(selected.count == 1 && selected.indices[0] == sample && selected.weights[0] == 1);
        layout_check_location(&layout, layout.points[sample]);
    }
    Vec2[4] probes = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0.5f, 0.5f } };
    foreach (parameter : probes) layout_check_location(&layout, parameter);
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
    foreach (parameter : probes) layout_check_location(&square, parameter);
    assert(anim::select_blend_layout(layout_view(&square), probes[0]).authored_index == 0);
    assert(anim::select_blend_layout(layout_view(&square), probes[1]).authored_index == 0);
    assert(anim::select_blend_layout(layout_view(&square), probes[2]).authored_index == 1);
    Vec2 near_tie = { -1, 0.70710678e-6f };
    Vec2 separated = { -1, 1.41421356e-6f };
    layout_check_location(&square, near_tie);
    layout_check_location(&square, separated);
    assert(anim::select_blend_layout(layout_view(&square), near_tie).authored_index == 0);
    assert(anim::select_blend_layout(layout_view(&square), separated).authored_index == 5);
    BlendLayoutSelection first = anim::select_blend_layout(layout_view(&square), probes[0]);
    (void)anim::select_blend_layout(layout_view(&square), probes[7]);
    BlendLayoutSelection after = anim::select_blend_layout(layout_view(&square), probes[0]);
    assert(first.indices == after.indices && first.weights == after.weights);
    assert(first.kind == after.kind && first.authored_index == after.authored_index);
    @swap(square.triangles[0], square.triangles[1]);
    @swap(square.triangles[0].indices[1], square.triangles[0].indices[2]);
    layout_prepare(&square);
    foreach (parameter : probes) layout_check_location(&square, parameter);
    assert(anim::select_blend_layout(layout_view(&square), probes[0]).authored_index == 0);
}

fn void test_animation_authoring_blend_layout_relative_tolerances_and_extents() @test {
    LayoutFixture triangle = layout_triangle();
    triangle.points[1] = { 1, 0 };
    triangle.points[2] = { 0, 0.5e-10f };
    layout_expect_fault(&triangle);
    triangle.points[2].y = 2e-10f;
    layout_prepare(&triangle);
    layout_check_location(&triangle, { 0.25f, 0.5e-10f });
    triangle = layout_triangle();
    layout_prepare(&triangle);
    assert(anim::select_blend_layout(layout_view(&triangle), { -1e-7f, 0.5f }).kind == BlendLayoutLocation.TRIANGLE);
    assert(anim::select_blend_layout(layout_view(&triangle), { -4e-7f, 0.5f }).kind == BlendLayoutLocation.HULL);
    foreach (float scale : { 0.0009765625f, 1048576.0f }) {
        LayoutFixture scaled = layout_grid(2, 2);
        for (uint sample = 0; sample < scaled.count; sample++) {
            scaled.points[sample] = scaled.points[sample] * scale - (Vec2){ 2 * scale, 3 * scale };
        }
        layout_prepare(&scaled);
        layout_check_location(&scaled, { -1.5f * scale, -2.5f * scale });
        layout_check_location(&scaled, { -3 * scale, -4 * scale });
    }
}

fn void test_animation_authoring_blend_layout_capacity_and_compact_storage() @test {
    assert(BlendTriangleIndices::size == 3 && BlendHullIndices::size == 2);
    assert(BlendTriangle::size == 3 * uint::size);
    foreach (uint count : { 3u, 4u, 8u, 9u, 15u, 16u }) {
        LayoutFixture layout = count == 9 ? layout_grid(3, 3)
          : count == 15 ? layout_grid(5, 3) : layout_maximal(count);
        layout_prepare(&layout, count);
        assert(layout.info.triangle_count <= 2 * count - 5 && layout.info.hull_count <= count);
        for (uint sample = 0; sample < count; sample++) layout_check_location(&layout, layout.points[sample]);
        layout_check_location(&layout, { 0.5f, 0.5f });
    }
    foreach (uint capacity : { 1u, 2u }) {
        LayoutFixture layout = layout_triangle();
        layout_expect_fault(&layout, capacity);
    }
    LayoutFixture five = layout_fan(5, true);
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
    invalid.triangle_count = 0;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangle_count = LAYOUT_MAX_TRIANGLES;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.points[0].x = float::nan;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.points[0].y = float::inf;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.points[3] = invalid.points[1];
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangles[0].indices[1] = invalid.triangles[0].indices[0];
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangles[0].indices[2] = 4;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangles[1] = invalid.triangles[0];
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.count = 5;
    invalid.points[4] = { 0.5f, 0.5f };
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangle_count = 1;
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.triangles[1] = { .indices = { 1, 2, 3 } };
    layout_expect_fault(&invalid);
    invalid = valid;
    invalid.points[3] = { 0.2f, 0.3f };
    layout_expect_fault(&invalid);
    invalid = layout_maximal(4);
    invalid.points[3] = { 0, 1 };
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
    LayoutFixture collinear = layout_triangle();
    collinear.points[2] = { 1, 0 };
    layout_expect_fault(&collinear);
}

fn uint layout_next_random(uint* state) @local {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return *state;
}

fn void test_animation_authoring_blend_layout_seeded_independent_corpus() @test {
    uint random = LAYOUT_CORPUS_SEED;
    uint[17] member_counts;
    uint[3] location_counts;
    uint maximum_triangle_layouts;
    for (uint sample = 0; sample < LAYOUT_CORPUS_COUNT; sample++) {
        uint count = 3 + layout_next_random(&random) % 14;
        uint family = layout_next_random(&random) % 3;
        LayoutFixture layout;
        if (sample % 11 == 0) {
            switch (layout_next_random(&random) % 6) {
                case 0: layout = layout_triangle();
                case 1: layout = layout_grid(2, 2);
                case 2: layout = layout_grid(4, 2);
                case 3: layout = layout_grid(3, 3);
                case 4: layout = layout_grid(5, 3);
                case 5: layout = layout_grid(4, 4);
                default: unreachable();
            }
        } else if (family == 0) {
            layout = layout_maximal(count);
        } else {
            layout = layout_fan(count, family == 1);
        }
        int exponent = (int)(layout_next_random(&random) % 17) - 8;
        float scale = (float)math::pow(2.0, (double)exponent);
        Vec2 shift = {
            (float)((int)(layout_next_random(&random) % 17) - 8) * scale,
            (float)((int)(layout_next_random(&random) % 17) - 8) * scale,
        };
        for (uint point = 0; point < layout.count; point++) layout.points[point] = layout.points[point] * scale + shift;
        for (uint triangle = layout.triangle_count; triangle > 1; triangle--) {
            uint other = layout_next_random(&random) % triangle;
            @swap(layout.triangles[triangle - 1], layout.triangles[other]);
        }
        for (uint triangle = 0; triangle < layout.triangle_count; triangle++) {
            if (layout_next_random(&random) & 1) {
                @swap(layout.triangles[triangle].indices[1], layout.triangles[triangle].indices[2]);
            }
        }
        layout_prepare(&layout);
        member_counts[layout.count]++;
        maximum_triangle_layouts += layout.info.triangle_count == 2 * layout.count - 5 ? 1 : 0;
        Vec2 parameter;
        switch (sample % 4) {
            case 0: parameter = layout.points[layout_next_random(&random) % layout.count];
            case 1:
                BlendTriangle triangle = layout.triangles[layout_next_random(&random) % layout.triangle_count];
                parameter = layout.points[triangle.indices[0]] * 0.2f + layout.points[triangle.indices[1]] * 0.3f
                  + layout.points[triangle.indices[2]] * 0.5f;
            case 2:
                BlendTriangle triangle = layout.triangles[layout_next_random(&random) % layout.triangle_count];
                parameter = (layout.points[triangle.indices[0]] + layout.points[triangle.indices[1]]) * 0.5f;
            case 3:
                parameter = shift + (Vec2){
                    ((float)(layout_next_random(&random) % 2001) / 1000 - 1) * scale * 6,
                    ((float)(layout_next_random(&random) % 2001) / 1000 - 1) * scale * 6,
                };
            default: unreachable();
        }
        layout_check_location(&layout, parameter);
        BlendLayoutSelection selected = anim::select_blend_layout(layout_view(&layout), parameter);
        (void)anim::select_blend_layout(layout_view(&layout), shift + (Vec2){ 10 * scale, -10 * scale });
        BlendLayoutSelection after = anim::select_blend_layout(layout_view(&layout), parameter);
        assert(selected.indices == after.indices && selected.weights == after.weights);
        assert(selected.kind == after.kind && selected.authored_index == after.authored_index);
        location_counts[selected.kind.ordinal]++;
    }
    foreach (uint count : { 3u, 4u, 5u, 6u, 7u, 8u, 9u, 10u, 11u, 12u, 13u, 14u, 15u, 16u }) {
        assert(member_counts[count] > 0);
    }
    assert(maximum_triangle_layouts == 744);
    assert(location_counts[0] == 500 && location_counts[1] == 1000 && location_counts[2] == 500);
}
