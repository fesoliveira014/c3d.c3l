module c3d::test::screen_space_gi;

import c3d;
import c3d::camera;
import c3d::render @public;
import c3d::render::post @public;
import std::math;

const float EPSILON @local = 1e-5f;
const float TOLERANCE @local = 0.05f;
const float THRESHOLD @local = 2;
const Vec2 VIEWPORT @local = { 800, 600 };
const float DISTANCE @local = 5;

fn bool close(float first, float second, float tolerance = EPSILON) @local {
    return math::abs(first - second) <= tolerance;
}

fn CameraMatrices camera_at(Vec3 position) @local {
    Transform pose = { .position = position, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } };
    return camera::derive_matrices(camera::perspective_deg(60, 0.1f), pose.to_mat4(), VIEWPORT);
}

fn Vec3 uv_depth_of(Mat4 view_proj, Vec3 point) @local {
    Vec4 clip = view_proj.apply({ point.x, point.y, point.z, 1 });
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f, clip.z / clip.w };
}

fn ProjectionTerms terms_of(CameraMatrices* matrices) @local {
    return { .m22 = matrices.proj.m22, .m23 = matrices.proj.m23, .orthographic = false };
}

fn void test_screen_space_gi_desc_validity() @test {
    ScreenSpaceGiDesc desc = render::SCREEN_SPACE_GI_DEFAULT;
    assert(render::screen_space_gi_desc_valid(&desc));
    ScreenSpaceGiDesc off;
    assert(render::screen_space_gi_desc_valid(&off));

    uint[2] bad_rays = { 0, 9 };
    foreach (rays : bad_rays) {
        ScreenSpaceGiDesc changed = desc;
        changed.rays = rays;
        assert(!render::screen_space_gi_desc_valid(&changed));
    }
    uint[2] bad_steps = { 3, 65 };
    foreach (steps : bad_steps) {
        ScreenSpaceGiDesc changed = desc;
        changed.max_steps = steps;
        assert(!render::screen_space_gi_desc_valid(&changed));
    }
    float[2] bad_distances = { 0, float::nan };
    foreach (distance : bad_distances) {
        ScreenSpaceGiDesc changed = desc;
        changed.max_distance = distance;
        assert(!render::screen_space_gi_desc_valid(&changed));
    }
    ScreenSpaceGiDesc flat = desc;
    flat.thickness = 0;
    assert(!render::screen_space_gi_desc_valid(&flat));
    float[3] bad_intensities = { -0.1f, 1.1f, float::nan };
    foreach (intensity : bad_intensities) {
        ScreenSpaceGiDesc changed = desc;
        changed.intensity = intensity;
        assert(!render::screen_space_gi_desc_valid(&changed));
    }
    float[3] bad_weights = { 1, -0.1f, float::nan };
    foreach (weight : bad_weights) {
        ScreenSpaceGiDesc changed = desc;
        changed.history_weight = weight;
        assert(!render::screen_space_gi_desc_valid(&changed));
    }
    float[2] bounds = { 0, 1 };
    foreach (intensity : bounds) {
        ScreenSpaceGiDesc changed = desc;
        changed.intensity = intensity;
        assert(render::screen_space_gi_desc_valid(&changed));
    }
}

fn void test_ssgi_depth_matches_follows_the_taa_rule() @test {
    CameraMatrices matrices = camera_at({ 0, 0, 0 });
    ProjectionTerms terms = terms_of(&matrices);
    float near_surface = uv_depth_of(matrices.view_proj, { 0, 0, -DISTANCE }).z;
    float far_surface = uv_depth_of(matrices.view_proj, { 0, 0, -DISTANCE * (1 + 2 * TOLERANCE) }).z;
    float[4] same = { near_surface, near_surface, near_surface, near_surface };
    float[4] far = { far_surface, far_surface, far_surface, far_surface };
    float[4] background = { 0, 0, 0, 0 };
    float[4] one_matching = { far_surface, 0, far_surface, near_surface };

    assert(render::ssgi_depth_matches(terms, near_surface, same, TOLERANCE));
    assert(!render::ssgi_depth_matches(terms, near_surface, far, TOLERANCE));
    assert(render::ssgi_depth_matches(terms, 0, background, TOLERANCE));
    assert(!render::ssgi_depth_matches(terms, near_surface, background, TOLERANCE));
    assert(!render::ssgi_depth_matches(terms, 0, same, TOLERANCE));
    assert(render::ssgi_depth_matches(terms, near_surface, one_matching, TOLERANCE));
}

fn void test_ssgi_history_weight_follows_velocity() @test {
    assert(render::ssgi_history_confidence(true, 0, THRESHOLD) == 1);
    assert(render::ssgi_history_confidence(true, THRESHOLD, THRESHOLD) == 1);
    float between = render::ssgi_history_confidence(true, 1.5f * THRESHOLD, THRESHOLD);
    assert(between > 0 && between < 1);
    assert(render::ssgi_history_confidence(true, 2 * THRESHOLD, THRESHOLD) == 0);
    assert(render::ssgi_history_confidence(true, 3 * THRESHOLD, THRESHOLD) == 0);
    assert(render::ssgi_history_confidence(false, 0, THRESHOLD) == 0);
}

fn void test_camera_velocity_reprojects_a_still_texel_onto_itself() @test {
    CameraMatrices matrices = camera_at({ 0, 0, 0 });
    Vec3 point = { 0.4f, -0.3f, -DISTANCE };
    Vec3 texel = uv_depth_of(matrices.view_proj, point);
    Vec2 uv = { texel.x, texel.y };
    Vec3 still = post::camera_velocity(uv, texel.z, matrices.inv_view_proj, matrices.view_proj, {}, false);
    assert(close(still.x, 0) && close(still.y, 0) && close(still.z, texel.z));
    Vec3 background = post::camera_velocity(uv, 0, matrices.inv_view_proj, matrices.view_proj, {}, false);
    assert(close(background.x, 0) && close(background.y, 0) && background.z == 0);

    Vec2 jitter = { 0.002f, -0.003f };
    CameraMatrices jittered = camera::jitter_matrices(matrices, jitter);
    Vec3 jittered_texel = uv_depth_of(jittered.view_proj, point);
    Vec3 steady = post::camera_velocity(
        uv:             { jittered_texel.x, jittered_texel.y },
        depth:          jittered_texel.z,
        inv_view_proj:  jittered.inv_view_proj,
        prev_view_proj: matrices.view_proj,
        jitter_offset:  post::jitter_uv(jitter),
        orthographic:   false,
    );
    assert(close(steady.x, 0, 1e-4f) && close(steady.y, 0, 1e-4f));

    CameraMatrices moved = camera_at({ 1, 0, 0 });
    Vec3 ahead = { 1, 0, -DISTANCE };
    Vec3 moved_texel = uv_depth_of(moved.view_proj, ahead);
    Vec3 motion = post::camera_velocity(
        uv:             { moved_texel.x, moved_texel.y },
        depth:          moved_texel.z,
        inv_view_proj:  moved.inv_view_proj,
        prev_view_proj: matrices.view_proj,
        jitter_offset:  {},
        orthographic:   false,
    );
    // One unit of camera travel at DISTANCE shifts the previous image by half the projected unit.
    assert(close(motion.x, -0.5f * matrices.proj.m00 / DISTANCE, 1e-4f));
    assert(close(motion.y, 0, 1e-4f));
    assert(close(motion.z, moved_texel.z, 1e-4f));
}

fn void test_screen_space_composite_bounds_the_base() @test {
    Vec4 none = {};
    assert(render::screen_space_base_share(0.7f, 0.4f, none) == 0.4f);
    assert(render::screen_space_base_share(0.3f, 0.9f, none) == 0.3f);
    Vec4 full = { 0.5f, 0.2f, 0.1f, 1 };
    assert(render::screen_space_base_share(1, 1, full) == 0);
    for (uint occlusion_step = 0; occlusion_step <= 4; occlusion_step++) {
        for (uint ambient_step = 0; ambient_step <= 4; ambient_step++) {
            for (uint share_step = 0; share_step <= 4; share_step++) {
                float occlusion = (float)occlusion_step / 4;
                float ambient_occlusion = (float)ambient_step / 4;
                Vec4 screen = { 0, 0, 0, (float)share_step / 4 };
                float base = render::screen_space_base_share(occlusion, ambient_occlusion, screen);
                assert(base <= math::min(occlusion, ambient_occlusion));
                assert(base >= 0);
            }
        }
    }
}
