module c3d::test::light_spatial;

import c3d;
import c3d::light;
import c3d::render @public;
import c3d::shader;
import std::math::vector;

fn void test_light_spatial_bounds_keep_rounded_distance_candidates() @test {
    @pool() {
        LightGpu[1] lights = {
            { .position_range = { -1.1f, 0, 0, 1.1f }, .kind = (uint)LightKind.POINT.ordinal },
        };
        Vec3 point = { 2e-8f, 0, 0 };
        Vec3 offset = lights[0].position_range.xyz - point;
        float radius = lights[0].position_range.w;
        assert(offset.dot(offset) <= radius * radius);

        LightSpatialData data = render::build_light_spatial_data(lights[..]);
        assert(data.tree.nodes.len == 1);
        assert(data.tree.nodes[0].max[0] >= point.x);
    };
}

fn void test_light_spatial_subnormal_squared_ranges_keep_flat_selection() @test {
    @pool() {
        LightGpu[1] lights = {
            { .position_range = { 0, 0, 0, 3e-23f }, .kind = (uint)LightKind.POINT.ordinal },
        };
        Vec3 point = { 4e-23f, 0, 0 };
        Vec3 offset = lights[0].position_range.xyz - point;
        float radius = lights[0].position_range.w;
        assert(offset.dot(offset) <= radius * radius);
        assert(!render::build_light_spatial_data(lights[..]).tree.nodes.len);
    };
}
