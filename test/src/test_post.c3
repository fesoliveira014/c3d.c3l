module c3d::test::post;

import c3d;
import c3d::render;
import c3d::render::post;
import c3d::shader;
import gpu;
import std::math;

fn void test_default_post_stack_is_neutral() @test {
    PostStack stack = post::default_post_stack();
    assert(stack.fxaa);
    assert(stack.grade.tonemap == Tonemap.ACES);
    assert(stack.grade.contrast == 1 && stack.grade.saturation == 1);
    assert(stack.grade.temperature == 0 && stack.grade.tint == 0);
    assert(stack.grade.lift.x == 0 && stack.grade.lift.y == 0 && stack.grade.lift.z == 0);
    assert(stack.grade.gamma.x == 1 && stack.grade.gamma.y == 1 && stack.grade.gamma.z == 1);
    assert(stack.grade.gain.x == 1 && stack.grade.gain.y == 1 && stack.grade.gain.z == 1);
    assert(stack.grade.lut.generation == 0);
}

fn void test_white_balance_is_identity_at_neutral() @test {
    Vec3 neutral = post::white_balance_coefficients(0, 0);
    assert(math::abs(neutral.x - 1) < 1e-3f && math::abs(neutral.y - 1) < 1e-3f && math::abs(neutral.z - 1) < 1e-3f);

    Vec3 warm = post::white_balance_coefficients(1, 0);
    Vec3 cool = post::white_balance_coefficients(-1, 0);
    assert(warm.x / warm.z > 1 && cool.x / cool.z < 1);

    Vec3 tinted = post::white_balance_coefficients(0, 1);
    assert(math::abs(tinted.y - neutral.y) > 1e-3f);
}

fn void test_identity_lut_maps_texels_to_their_coordinates() @test {
    char[] pixels = post::identity_lut(mem, 4);
    defer free(pixels.ptr);
    assert(pixels.len == 4 * 4 * 4 * 4);

    // texel (x, y, z) starts at ((z * 4 + y) * 4 + x) * 4
    assert(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 255);
    assert(pixels[3 * 4] == 255 && pixels[3 * 4 + 1] == 0 && pixels[3 * 4 + 2] == 0);
    assert(pixels[3 * 4 * 4] == 0 && pixels[3 * 4 * 4 + 1] == 255);
    assert(pixels[3 * 4 * 4 * 4 + 2] == 255);
    usz mixed = ((3 * 4 + 2) * 4 + 1) * 4;
    assert(pixels[mixed] == 85 && pixels[mixed + 1] == 170 && pixels[mixed + 2] == 255 && pixels[mixed + 3] == 255);
}

fn void test_lut_coordinate_transform_centers_texels() @test {
    float scale = post::lut_scale(32);
    float offset = post::lut_offset(32);
    assert(math::abs(0 * scale + offset - 1.0f / 64) < 1e-6f);
    assert(math::abs(1 * scale + offset - 63.0f / 64) < 1e-6f);
}

fn void test_grade_gpu_packs_settings_and_camera_exposure() @test {
    GradeParams params = post::default_post_stack().grade;
    params.tonemap = Tonemap.AGX;
    params.temperature = 0.5f;
    params.lift = { 0.1f, 0.2f, 0.3f };

    GradeGpu packed;
    post::write_grade_gpu(
        gpu_grade:       &packed,
        params:          &params,
        camera_exposure: 2.0f,
        lut_texture:     (gpu::TextureIndex)7,
        lut_sampler:     (gpu::SamplerIndex)3,
        lut_size:        32,
    );
    assert(packed.exposure == 2.0f);
    assert(packed.tonemap == shader::TONEMAP_AGX);
    Vec3 balance = post::white_balance_coefficients(0.5f, 0);
    assert(packed.balance.x == balance.x && packed.balance.y == balance.y && packed.balance.z == balance.z);
    assert(packed.lift.x == 0.1f && packed.lift.y == 0.2f && packed.lift.z == 0.3f);
    assert(packed.lut_texture == (gpu::TextureIndex)7 && packed.lut_sampler == (gpu::SamplerIndex)3);
    assert(packed.lut_scale == post::lut_scale(32) && packed.lut_offset == post::lut_offset(32));

    post::write_grade_gpu(&packed, &params, 1.0f);
    assert(packed.lut_texture == (gpu::TextureIndex)0 && packed.lut_sampler == (gpu::SamplerIndex)0);
    assert(packed.lut_scale == 0 && packed.lut_offset == 0);
}
