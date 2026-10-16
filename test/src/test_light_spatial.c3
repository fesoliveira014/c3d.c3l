module c3d::test::light_spatial;

import c3d;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::shader;
import c3d::spatial::bvh;
import std::math;

fn LightGpu finite_light(Vec3 position, float radius, LightKind kind = LightKind.POINT) @local {
    return {
        .position_range = { position.x, position.y, position.z, radius },
        .kind = (uint)kind.ordinal,
        .layers = 1,
        .color_intensity = { 1, 1, 1, 1 },
    };
}

fn void check_spatial_indices(LightGpu[] lights, LightSpatialData* data) @local {
    bool[] seen = alloc::new_array(tmem, bool, (sz)lights.len);
    foreach (index : data.globals) {
        assert(index < lights.len && !seen[index]);
        assert(lights[index].kind == (uint)LightKind.DIRECTIONAL.ordinal || lights[index].position_range.w == 0);
        seen[index] = true;
    }
    foreach (index : data.tree.primitives) {
        assert(index < lights.len && !seen[index]);
        assert(lights[index].kind != (uint)LightKind.DIRECTIONAL.ordinal && lights[index].position_range.w > 0);
        seen[index] = true;
    }
    foreach (found : seen) assert(found);
    foreach (node : data.tree.nodes) {
        if (node.count) {
            foreach (index : data.tree.primitives[node.left_or_first:node.count]) {
                LightGpu light = lights[index];
                for (uint axis = 0; axis < 3; axis++) {
                    double position = light.position_range[axis];
                    double radius = light.position_range.w;
                    assert((double)node.min[axis] <= position - radius);
                    assert((double)node.max[axis] >= position + radius);
                }
            }
        } else {
            foreach (child : data.tree.nodes[node.left_or_first:2]) {
                for (uint axis = 0; axis < 3; axis++) {
                    assert(node.min[axis] <= child.min[axis] && node.max[axis] >= child.max[axis]);
                }
            }
        }
    }
}

fn void test_light_spatial_keeps_original_indices_and_global_order() @test {
    @pool() {
        LightGpu[7] lights = {
            finite_light({ 0, 0, 0 }, 0, LightKind.DIRECTIONAL),
            finite_light({ 2, 3, 4 }, 2),
            finite_light({ -10, -4, -2 }, 3, LightKind.SPOT),
            finite_light({ 8, 8, 8 }, 0),
            finite_light({ 30, 20, 10 }, 1),
            finite_light({ -20, 3, 1 }, 2),
            finite_light({ 4, -7, 10 }, 5),
        };
        LightSpatialData data = render::build_light_spatial_data(lights[..]);
        assert(data.tree.nodes.len > 1 && data.tree.primitives.len == 5);
        assert(data.globals.len == 2 && data.globals[0] == 0 && data.globals[1] == 3);
        check_spatial_indices(lights[..], &data);
    };
}

fn void test_light_spatial_large_coincident_leaf_keeps_every_light() @test {
    @pool() {
        LightGpu[257] lights;
        foreach (&light : lights) *light = finite_light({ 1, 2, 3 }, 4);
        LightSpatialData data = render::build_light_spatial_data(lights[..]);
        assert(data.tree.nodes.len == 1 && data.tree.nodes[0].count == lights.len);
        check_spatial_indices(lights[..], &data);
    };
}

fn void test_light_spatial_empty_global_and_numeric_fallbacks_keep_flat_selection() @test {
    @pool() {
        assert(!render::build_light_spatial_data({}).tree.nodes.len);
        LightGpu[2] globals = {
            finite_light({}, 0, LightKind.DIRECTIONAL),
            finite_light({ 1, 2, 3 }, 0),
        };
        assert(!render::build_light_spatial_data(globals[..]).tree.nodes.len);
        LightGpu[2] lights = { finite_light({}, 1), {} };
        LightGpu[5] unavailable = {
            finite_light({ math::FLOAT_MAX, 0, 0 }, 1),
            finite_light({}, 1e20f),
            finite_light({}, 1e-30f),
            finite_light({ bitcast(0x7fc00000u, float), 0, 0 }, 1),
            finite_light({}, bitcast(0x7f800000u, float)),
        };
        foreach (light : unavailable) {
            lights[1] = light;
            assert(!render::build_light_spatial_data(lights[..]).tree.nodes.len);
        }
    };
}

fn void test_light_spatial_bounds_round_outward_and_rebase_with_the_packed_list() @test {
    @pool() {
        LightGpu[6] lights = {
            finite_light({ 16777216, 0, 0 }, 1),
            finite_light({ -16777216, 0, 0 }, 1),
            finite_light({ 1, 2, 3 }, 0.25f),
            finite_light({ -1, -2, -3 }, 0.25f),
            finite_light({ 0, 0, 0 }, 1),
            finite_light({ 20, 30, 40 }, 2),
        };
        LightSpatialData data = render::build_light_spatial_data(lights[..]);
        assert(data.tree.nodes.len);
        check_spatial_indices(lights[..], &data);
        Vec3 origin = { 65536, -65536, 32768 };
        foreach (&light : lights) light.position_range.xyz -= origin;
        data = render::build_light_spatial_data(lights[..]);
        assert(data.tree.nodes.len);
        check_spatial_indices(lights[..], &data);
        LightSpatialData limited = render::build_light_spatial_data(lights[:3]);
        assert(limited.tree.primitives.len == 3);
        foreach (index : limited.tree.primitives) assert(index < 3);
    };
}

fn void test_light_spatial_raster_admission_preserves_small_and_dense_lists() @test {
    @pool() {
        LightGpu[] lights = alloc::alloc_array(tmem, LightGpu, 4097);
        for (uint index = 0; index < 4096; index++) {
            Vec3 position = { (float)(index % 16) * 8, (float)((index / 16) % 16) * 8, (float)(index / 256) * 8 };
            lights[index] = finite_light(position, 1);
        }
        assert(!render::build_light_spatial_data(lights[:4095], render::LIGHT_CLUSTER_BVH_BUILD, true).tree.nodes.len);
        LightSpatialData sparse = render::build_light_spatial_data(lights[:4096], render::LIGHT_CLUSTER_BVH_BUILD, true);
        assert(sparse.tree.nodes.len && sparse.tree.primitives.len == 4096);
        check_spatial_indices(lights[:4096], &sparse);
        lights[4096] = finite_light({}, 0, LightKind.DIRECTIONAL);
        sparse = render::build_light_spatial_data(lights[..], render::LIGHT_CLUSTER_BVH_BUILD, true);
        assert(sparse.tree.nodes.len && sparse.tree.primitives.len == 4096 && sparse.globals.len == 1);
        check_spatial_indices(lights[..], &sparse);
        lights[4095] = finite_light({}, 0);
        assert(!render::build_light_spatial_data(lights[..], render::LIGHT_CLUSTER_BVH_BUILD, true).tree.nodes.len);
        foreach (&light : lights[:4096]) *light = finite_light({ 1, 2, 3 }, 32);
        assert(!render::build_light_spatial_data(lights[:4096], render::LIGHT_CLUSTER_BVH_BUILD, true).tree.nodes.len);
        LightSpatialData traced = render::build_light_spatial_data(lights[:4096]);
        assert(traced.tree.nodes.len == 1 && traced.tree.primitives.len == 4096);
        check_spatial_indices(lights[:4096], &traced);
        foreach (&light : lights[:4096]) light.position_range.w = 1e17f;
        assert(!render::build_light_spatial_data(lights[:4096], render::LIGHT_CLUSTER_BVH_BUILD, true).tree.nodes.len);
    };
}

fn void test_light_spatial_raster_admission_checks_bound_overlap() @test {
    @pool() {
        LightGpu[] lights = alloc::alloc_array(tmem, LightGpu, 4096);
        foreach (index, &light : lights) *light = finite_light({ index % 2 ? 9.1f : 0, 0, 0 }, 1);
        assert(render::build_light_spatial_data(lights[..], render::LIGHT_CLUSTER_BVH_BUILD, true).tree.nodes.len);
        foreach (index, &light : lights) *light = finite_light({ index % 2 ? 8.9f : 0, 0, 0 }, 1);
        assert(!render::build_light_spatial_data(lights[..], render::LIGHT_CLUSTER_BVH_BUILD, true).tree.nodes.len);
    };
}

fn void test_light_spatial_bounds_keep_rounded_distance_candidates() @test {
    @pool() {
        float[5] radii = { 1.1f, 0.1f, 10, 1e-10f, 1e10f };
        foreach (radius : radii) {
            for (uint axis = 0; axis < 3; axis++) {
                for (uint sign = 0; sign < 2; sign++) {
                    Vec3 center;
                    Vec3 point;
                    center[axis] = sign ? radius : -radius;
                    point[axis] = (sign ? -1.0f : 1.0f) * (radius == 1.1f ? 2e-8f : radius * math::FLOAT_EPSILON * 0.125f);
                    Vec3 offset = center - point;
                    assert(offset.dot(offset) <= radius * radius);
                    LightGpu[1] lights = { finite_light(center, radius) };
                    LightSpatialData data = render::build_light_spatial_data(lights[..]);
                    assert(data.tree.nodes.len == 1);
                    for (uint coordinate = 0; coordinate < 3; coordinate++) {
                        assert(point[coordinate] >= data.tree.nodes[0].min[coordinate]);
                        assert(point[coordinate] <= data.tree.nodes[0].max[coordinate]);
                    }
                }
            }
        }
    };
}

fn void test_light_spatial_subnormal_squared_ranges_keep_flat_selection() @test {
    @pool() {
        LightGpu[1] lights = { finite_light({}, 3e-23f) };
        Vec3 point = { 4e-23f, 0, 0 };
        Vec3 offset = lights[0].position_range.xyz - point;
        assert(offset.dot(offset) <= lights[0].position_range.w * lights[0].position_range.w);
        assert(!render::build_light_spatial_data(lights[..]).tree.nodes.len);
    };
}
