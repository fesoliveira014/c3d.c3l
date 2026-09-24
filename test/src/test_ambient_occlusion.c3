module c3d::test::ambient_occlusion;

import c3d;
import c3d::render @public;

fn void test_ambient_occlusion_desc_validity() @test {
    AmbientOcclusionDesc none = {};
    assert(render::ambient_occlusion_desc_valid(&none));
    AmbientOcclusionDesc ignored = { .kind = AoKind.NONE, .radius = -1, .intensity = float::nan };
    assert(render::ambient_occlusion_desc_valid(&ignored));

    AmbientOcclusionDesc desc = render::AMBIENT_OCCLUSION_DEFAULT;
    assert(render::ambient_occlusion_desc_valid(&desc));
    desc.intensity = 0;
    assert(render::ambient_occlusion_desc_valid(&desc));

    float[4] bad_radii = { 0, -0.5f, float::inf, float::nan };
    foreach (radius : bad_radii) {
        desc = render::AMBIENT_OCCLUSION_DEFAULT;
        desc.radius = radius;
        assert(!render::ambient_occlusion_desc_valid(&desc));
    }
    float[3] bad_intensities = { -0.01f, float::inf, float::nan };
    foreach (intensity : bad_intensities) {
        desc = render::AMBIENT_OCCLUSION_DEFAULT;
        desc.intensity = intensity;
        assert(!render::ambient_occlusion_desc_valid(&desc));
    }

    desc = render::AMBIENT_OCCLUSION_DEFAULT;
    desc.kind = AoKind.RAY_TRACED;
    assert(!render::ambient_occlusion_desc_valid(&desc));
}

fn void test_ambient_occlusion_extent_halves_and_rounds_up() @test {
    assert(render::ambient_occlusion_extent(1920, 1080, false) == (uint[<2>]){ 960, 540 });
    assert(render::ambient_occlusion_extent(1921, 1081, false) == (uint[<2>]){ 961, 541 });
    assert(render::ambient_occlusion_extent(1, 1, false) == (uint[<2>]){ 1, 1 });
    assert(render::ambient_occlusion_extent(1921, 1081, true) == (uint[<2>]){ 1921, 1081 });
}
