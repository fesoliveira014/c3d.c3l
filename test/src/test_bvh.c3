module c3d::test::bvh;

import c3d;
import c3d::geometry;
import c3d::maths;
import c3d::spatial::bvh;
import std::math;

const uint SEED @local = 0x9e3779b9;
const float DISTANCE_TOLERANCE @local = 1e-5f;

struct Random @local {
    uint state;
}

struct Traced @local {
    Bvh    tree;
    Vec3[] positions;
    uint[] indices;
}

fn uint next_bits(Random* random) @local {
    random.state ^= random.state << 13;
    random.state ^= random.state >> 17;
    random.state ^= random.state << 5;
    return random.state;
}

fn float next_float(Random* random, float low, float high) @local {
    return low + (high - low) * (float)(next_bits(random) >> 8) / (float)(1u << 24);
}

fn Vec3 next_point(Random* random, float low, float high) @local {
    return { next_float(random, low, high), next_float(random, low, high), next_float(random, low, high) };
}

fn Vec3[] random_triangles(Random* random, usz count) @local {
    Vec3[] positions = alloc::alloc_array(tmem, Vec3, (sz)(3 * count));
    for (usz triangle = 0; triangle < count; triangle++) {
        Vec3 center = next_point(random, -10, 10);
        for (usz corner = 0; corner < 3; corner++) {
            positions[3 * triangle + corner] = center + next_point(random, -0.5f, 0.5f);
        }
    }
    return positions;
}

fn Aabb node_box(BvhNode* node) @local {
    return { .min = (Vec3)node.min, .max = (Vec3)node.max };
}

fn bool contains(Aabb outer, Aabb inner) @local {
    return outer.min.x <= inner.min.x && outer.min.y <= inner.min.y && outer.min.z <= inner.min.z
        && outer.max.x >= inner.max.x && outer.max.y >= inner.max.y && outer.max.z >= inner.max.z;
}

fn bool contains_point(Aabb outer, Vec3 point) @local {
    return contains(outer, { .min = point, .max = point });
}

fn Vec3[3] corners_of(Vec3[] positions, uint[] indices, uint primitive) @local {
    usz first = 3 * (usz)primitive;
    if (!indices.len) return { positions[first], positions[first + 1], positions[first + 2] };
    return { positions[indices[first]], positions[indices[first + 1]], positions[indices[first + 2]] };
}

fn void check_permutation(Bvh* tree, usz count) @local {
    bool[] seen = alloc::new_array(tmem, bool, (sz)count);
    usz covered;
    foreach (&node : tree.nodes) {
        if (!node.count) continue;
        foreach (primitive : tree.primitives[node.left_or_first:node.count]) {
            assert(primitive < count && !seen[primitive]);
            seen[primitive] = true;
            covered++;
        }
    }
    assert(covered == count);
}

fn uint max_depth(Bvh* tree, uint node_index, uint depth) @local {
    BvhNode* node = &tree.nodes[node_index];
    if (node.count) return depth;
    return math::max(
        max_depth(tree, node.left_or_first, depth + 1),
        max_depth(tree, node.left_or_first + 1, depth + 1),
    );
}

fn Traced build_traced(Vec3[] positions, uint[] indices, BvhBuildDesc desc = bvh::BVH_BUILD_DEFAULT) @local {
    Bvh tree = bvh::build_triangle_bvh(
        allocator: tmem,
        positions: positions,
        indices:   indices,
        desc:      desc,
    )!!;
    return { .tree = tree, .positions = positions, .indices = indices };
}

fn bool nearest(Traced* traced, Ray ray, BvhHit* hit) @local {
    return traced.tree.trace(
        positions:      traced.positions,
        indices:        traced.indices,
        ray:            ray,
        distance_limit: math::FLOAT_MAX,
        hit:            hit,
    );
}

fn bool any_closer(Traced* traced, Ray ray, float limit) @local {
    return traced.tree.trace_any(
        positions:      traced.positions,
        indices:        traced.indices,
        ray:            ray,
        distance_limit: limit,
    );
}

fn bool nearest_by_scan(Traced* traced, Ray ray, BvhHit* nearest) @local {
    Vec3[] positions = traced.positions;
    uint[] indices = traced.indices;
    usz triangle_count = indices.len ? indices.len / 3 : positions.len / 3;
    bool found;
    for (uint triangle = 0; triangle < triangle_count; triangle++) {
        Vec3[3] corners = corners_of(positions, indices, triangle);
        float distance;
        Vec3 barycentric;
        bool met = maths::ray_intersects_triangle(
            ray:         ray,
            a:           corners[0],
            b:           corners[1],
            c:           corners[2],
            distance:    &distance,
            barycentric: &barycentric,
        );
        if (!met || (found && distance >= nearest.distance)) continue;
        found = true;
        *nearest = { .primitive = triangle, .distance = distance, .barycentric = barycentric };
    }
    return found;
}

fn Ray random_ray(Random* random) @local {
    Vec3 origin = next_point(random, -15, 15);
    return { .origin = origin, .direction = next_point(random, -5, 5) - origin };
}

fn void check_traces_match_scan(Random* random, Vec3[] positions, uint[] indices) @local {
    Traced traced = build_traced(positions, indices);
    for (usz ray_index = 0; ray_index < 1000; ray_index++) {
        Ray ray = random_ray(random);
        BvhHit expected;
        BvhHit actual;
        bool scanned = nearest_by_scan(&traced, ray, &expected);
        bool met_by_tree = nearest(&traced, ray, &actual);
        assert(scanned == met_by_tree);
        if (!met_by_tree) continue;
        float tolerance = DISTANCE_TOLERANCE * math::max(1.0f, expected.distance);
        assert(math::abs(actual.distance - expected.distance) <= tolerance);
        if (actual.primitive == expected.primitive) continue;
        Vec3[3] corners = corners_of(positions, indices, actual.primitive);
        float tied;
        Vec3 weights;
        bool met = maths::ray_intersects_triangle(
            ray:         ray,
            a:           corners[0],
            b:           corners[1],
            c:           corners[2],
            distance:    &tied,
            barycentric: &weights,
        );
        assert(met && math::abs(tied - expected.distance) <= tolerance);
    }
}

fn void test_every_primitive_lands_in_exactly_one_leaf() @test {
    @pool() {
        Random random = { SEED };
        Vec3[] positions = random_triangles(&random, 500);
        Bvh tree = bvh::build_triangle_bvh(tmem, positions, {})!!;
        check_permutation(&tree, 500);
    };
}

fn void test_node_bounds_contain_children_and_primitives() @test {
    @pool() {
        Random random = { SEED };
        Vec3[] positions = random_triangles(&random, 500);
        Bvh tree = bvh::build_triangle_bvh(tmem, positions, {})!!;
        foreach (&node : tree.nodes) {
            Aabb box = node_box(node);
            if (!node.count) {
                assert(contains(box, node_box(&tree.nodes[node.left_or_first])));
                assert(contains(box, node_box(&tree.nodes[node.left_or_first + 1])));
                continue;
            }
            foreach (primitive : tree.primitives[node.left_or_first:node.count]) {
                foreach (corner : corners_of(positions, {}, primitive)) assert(contains_point(box, corner));
            }
        }
    };
}

fn void test_bvh_trace_matches_the_linear_scan() @test {
    @pool() {
        Random random = { SEED };
        check_traces_match_scan(&random, random_triangles(&random, 2000), {});
        Geometry box = geometry::box(tmem, 2, 2, 2);
        check_traces_match_scan(&random, box.positions, box.indices);
    };
}

fn void test_trace_any_agrees_with_trace() @test {
    @pool() {
        Random random = { SEED };
        Traced traced = build_traced(random_triangles(&random, 2000), {});
        for (usz ray_index = 0; ray_index < 1000; ray_index++) {
            Ray ray = random_ray(&random);
            BvhHit hit;
            if (!nearest(&traced, ray, &hit)) {
                assert(!any_closer(&traced, ray, 1e6f));
                continue;
            }
            assert(any_closer(&traced, ray, hit.distance * 1.001f));
            assert(!any_closer(&traced, ray, hit.distance * 0.999f));
        }
    };
}

fn void test_coincident_triangles_build_one_leaf() @test {
    @pool() {
        Vec3[] positions = alloc::alloc_array(tmem, Vec3, 3000);
        for (usz corner = 0; corner < 3000; corner += 3) {
            positions[corner] = { -1, -1, 0 };
            positions[corner + 1] = { 1, -1, 0 };
            positions[corner + 2] = { 0, 1, 0 };
        }
        Traced traced = build_traced(positions, {}, { .bins = 12, .leaf_size = 1 });
        assert(traced.tree.nodes.len == 1 && traced.tree.nodes[0].count == 1000);
        BvhHit hit;
        Ray ray = { .origin = { 0, -1.0f / 3, 5 }, .direction = { 0, 0, -1 } };
        assert(nearest(&traced, ray, &hit) && hit.primitive < 1000);
    };
}

fn void test_depth_stays_within_the_limit() @test {
    @pool() {
        Vec3[] positions = alloc::alloc_array(tmem, Vec3, 300);
        for (usz triangle = 0; triangle < 100; triangle++) {
            float center = math::pow(2.0f, (float)triangle);
            positions[3 * triangle] = { center - 0.25f, 0, 0 };
            positions[3 * triangle + 1] = { center + 0.25f, 0, 0 };
            positions[3 * triangle + 2] = { center, 0.5f, 0 };
        }
        Bvh peeled = build_traced(positions, {}, { .bins = 2, .leaf_size = 1 }).tree;
        assert(max_depth(&peeled, 0, 0) <= bvh::BVH_MAX_DEPTH - 1);
        check_permutation(&peeled, 100);
        bool forced;
        foreach (&node : peeled.nodes) forced = forced || node.count > 1;
        assert(forced);

        Random random = { SEED };
        Vec3[] soup = random_triangles(&random, 4000);
        Bvh balanced = bvh::build_triangle_bvh(tmem, soup, {})!!;
        assert(max_depth(&balanced, 0, 0) <= bvh::BVH_MAX_DEPTH - 1);
        check_permutation(&balanced, 4000);
    };
}

fn void test_build_rejects_invalid_input() @test {
    Vec3[4] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 } };
    uint[2] short_indices = { 0, 1 };
    uint[3] out_of_range = { 0, 1, 3 };
    assert(@catch(bvh::build_triangle_bvh(mem, positions[:2], {})) == c3d::INVALID_ARGUMENT);
    assert(@catch(bvh::build_triangle_bvh(mem, positions[..], {})) == c3d::INVALID_ARGUMENT);
    assert(@catch(bvh::build_triangle_bvh(mem, positions[:3], short_indices[..])) == c3d::INVALID_ARGUMENT);
    assert(@catch(bvh::build_triangle_bvh(mem, positions[:3], out_of_range[..])) == c3d::INVALID_ARGUMENT);
    assert(@catch(bvh::build_box_bvh(mem, {})) == c3d::INVALID_ARGUMENT);
}

fn void test_box_bvh_covers_every_box() @test {
    @pool() {
        Random random = { SEED };
        Aabb[] boxes = alloc::alloc_array(tmem, Aabb, 100);
        foreach (&box : boxes) {
            Vec3 center = next_point(&random, -50, 50);
            Vec3 half = next_point(&random, 0.1f, 2);
            *box = { .min = center - half, .max = center + half };
        }
        Bvh tree = bvh::build_box_bvh(tmem, boxes)!!;
        check_permutation(&tree, 100);
        foreach (&node : tree.nodes) {
            Aabb box = node_box(node);
            if (!node.count) {
                assert(contains(box, node_box(&tree.nodes[node.left_or_first])));
                assert(contains(box, node_box(&tree.nodes[node.left_or_first + 1])));
                continue;
            }
            foreach (primitive : tree.primitives[node.left_or_first:node.count]) {
                assert(contains(box, boxes[primitive]));
            }
        }
    };
}
