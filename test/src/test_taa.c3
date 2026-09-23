module c3d::test::taa;

import c3d;
import c3d::camera;
import c3d::maths;
import c3d::render;
import c3d::render::post;
import std::math;

const float EPSILON @local = 1e-5f;
const uint WIDTH @local = 1920;
const uint HEIGHT @local = 1080;

fn bool close(float first, float second, float tolerance = EPSILON) @local {
    return math::abs(first - second) <= tolerance;
}

fn Vec2 ndc_of(Mat4 view_proj, Vec3 point) @local {
    Vec4 clip = view_proj.apply({ point.x, point.y, point.z, 1 });
    return { clip.x / clip.w, clip.y / clip.w };
}

fn float depth_of(Mat4 view_proj, Vec3 point) @local {
    Vec4 clip = view_proj.apply({ point.x, point.y, point.z, 1 });
    return clip.z / clip.w;
}

fn void test_halton_matches_radical_inverse_values() @test {
    assert(maths::halton(1, 2) == 0.5f && maths::halton(2, 2) == 0.25f);
    assert(maths::halton(3, 2) == 0.75f && maths::halton(4, 2) == 0.125f);
    assert(close(maths::halton(1, 3), 1.0f / 3) && close(maths::halton(2, 3), 2.0f / 3));
    assert(close(maths::halton(3, 3), 1.0f / 9) && close(maths::halton(4, 3), 4.0f / 9));
    assert(maths::halton(0, 2) == 0);
}

fn void test_taa_jitter_stays_inside_the_pixel_and_cycles() @test {
    Vec2[post::TAA_SAMPLE_COUNT] offsets;
    for (uint index = 0; index < post::TAA_SAMPLE_COUNT; index++) {
        Vec2 jitter = post::taa_jitter(index, WIDTH, HEIGHT);
        assert(math::abs(jitter.x) * (float)WIDTH / 2 < 0.5f);
        assert(math::abs(jitter.y) * (float)HEIGHT / 2 < 0.5f);
        Vec2 repeated = post::taa_jitter(index + post::TAA_SAMPLE_COUNT, WIDTH, HEIGHT);
        assert(repeated.x == jitter.x && repeated.y == jitter.y);
        for (uint earlier = 0; earlier < index; earlier++) {
            assert(offsets[earlier].x != jitter.x || offsets[earlier].y != jitter.y);
        }
        offsets[index] = jitter;
    }

    Vec2 first = post::taa_jitter(0, WIDTH, HEIGHT);
    assert(first.x == 0);
    assert(close(first.y, 2 * (1.0f / 6) / (float)HEIGHT, 1e-8f));
}

fn void test_jitter_matrices_shift_clip_space_and_keep_culling() @test {
    Transform pose = {
        .position = { 3, 1, 8 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.4f),
        .scale    = { 1, 1, 1 },
    };
    Camera lens = camera::perspective_deg(60, 0.1f);
    CameraMatrices matrices = camera::derive_matrices(lens, pose.to_mat4(), { 800, 600 });
    Vec2 jitter = { 0.01f, -0.02f };
    CameraMatrices jittered = camera::jitter_matrices(matrices, jitter);

    Vec3 point = { 1, 2, -10 };
    Vec2 shifted = ndc_of(jittered.view_proj, point) - ndc_of(matrices.view_proj, point);
    assert(close(shifted.x, jitter.x, 1e-4f) && close(shifted.y, jitter.y, 1e-4f));
    assert(close(depth_of(jittered.view_proj, point), depth_of(matrices.view_proj, point)));

    assert(jittered.view == matrices.view);
    assert(jittered.frustum.plane_count == matrices.frustum.plane_count);
    for (uint plane = 0; plane < matrices.frustum.plane_count; plane++) {
        Plane expected = matrices.frustum.planes[plane];
        Plane actual = jittered.frustum.planes[plane];
        assert(actual.normal == expected.normal && actual.d == expected.d);
    }

    Mat4 product = jittered.inv_view_proj.mul(jittered.view_proj);
    for (uint row = 0; row < 4; row++) {
        for (uint column = 0; column < 4; column++) {
            float expected = row == column ? 1 : 0;
            assert(close(product.m[row * 4 + column], expected, 1e-4f));
        }
    }
}

fn void test_taa_params_are_validated_only_when_selected() @test {
    PostStack stack = post::default_post_stack();
    stack.anti_aliasing = AntiAliasing.TAA;
    assert(post::post_stack_valid(&stack));

    TaaParams defaults = stack.taa_params;
    TaaParams[8] invalid = { defaults, defaults, defaults, defaults, defaults, defaults, defaults, defaults };
    invalid[0].current_weight = 0;
    invalid[1].current_weight = 1.5f;
    invalid[2].clip_gamma = 0;
    invalid[3].depth_tolerance = 0;
    invalid[4].velocity_threshold = -1;
    invalid[5].mip_bias = 0.5f;
    invalid[6].mip_bias = post::TAA_MIP_BIAS_MIN - 0.1f;
    invalid[7].current_weight = float::nan;
    foreach (params : invalid) {
        stack.anti_aliasing = AntiAliasing.TAA;
        stack.taa_params = params;
        assert(!post::post_stack_valid(&stack));
        stack.anti_aliasing = AntiAliasing.FXAA;
        assert(post::post_stack_valid(&stack));
    }
}
