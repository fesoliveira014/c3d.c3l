module c3d::test::camera;

import c3d::camera;
import c3d::maths;
import std::math;

const float TOLERANCE @local = 0.0005f;
const Vec2 VIEWPORT @local = { 1600, 900 };

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn bool close_vec3(Vec3 first, Vec3 second) @local {
    return close(first.x, second.x) && close(first.y, second.y) && close(first.z, second.z);
}

fn Mat4 camera_world(Vec3 position, Quat rotation) @local {
    Transform transform = { .position = position, .rotation = rotation, .scale = { 1, 1, 1 } };
    return transform.to_mat4();
}

fn Mat4 camera_at(Vec3 position) @local => camera_world(position, quaternion::IDENTITY);

fn Quat quarter_turn_y() @local => quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 2);

fn void test_derive_uses_viewport_aspect_when_camera_aspect_is_zero() @test {
    Camera camera = camera::perspective_deg(60, 0.1f);
    CameraMatrices matrices = camera::derive_matrices(camera, camera_at({ 0, 0, 5 }), VIEWPORT);
    assert(close(matrices.proj.m00, matrices.proj.m11 * 900.0f / 1600.0f));
}

fn void test_derive_uses_explicit_aspect() @test {
    Camera camera = camera::perspective_deg(60, 0.1f);
    camera.aspect = 2;
    CameraMatrices matrices = camera::derive_matrices(camera, camera_at({ 0, 0, 5 }), VIEWPORT);
    assert(close(matrices.proj.m00, matrices.proj.m11 / 2));
}

fn void test_view_inverts_camera_world() @test {
    Mat4 world = camera_world({ 1, 2, 3 }, quarter_turn_y());
    CameraMatrices matrices = camera::derive_matrices(camera::perspective_deg(60, 0.1f), world, VIEWPORT);
    Mat4 product = matrices.view.mul(world);
    Mat4 identity = matrix::IDENTITY4;
    for (usz index = 0; index < 16; index++) {
        assert(close(product.m[index], identity.m[index]));
    }
    assert(close_vec3(matrices.position, { 1, 2, 3 }));
}

fn void test_point_ahead_projects_to_viewport_center() @test {
    Camera[2] cameras = { camera::perspective_deg(60, 0.1f), camera::orthographic(10, 0.1f, 100) };
    foreach (lens : cameras) {
        CameraMatrices matrices = camera::derive_matrices(lens, camera_at({ 0, 0, 5 }), VIEWPORT);
        Vec3 screen = camera::world_to_screen(&matrices, { 0, 0, 0 }, VIEWPORT);
        assert(close(screen.x, 800) && close(screen.y, 450));
        assert(screen.z > 0 && screen.z < 1);
    }
}

fn void test_infinite_perspective_has_five_planes() @test {
    Mat4 world = camera_at({ 0, 0, 0 });
    assert(camera::derive_matrices(camera::perspective(1, 0.1f), world, VIEWPORT).frustum.plane_count == 5);
    assert(camera::derive_matrices(camera::perspective(1, 0.1f, 100), world, VIEWPORT).frustum.plane_count == 6);
    assert(camera::derive_matrices(camera::orthographic(10, 0.1f, 100), world, VIEWPORT).frustum.plane_count == 6);
}

fn void test_infinite_frustum_keeps_distant_box() @test {
    Mat4 world = camera_at({ 0, 0, 0 });
    CameraMatrices infinite = camera::derive_matrices(camera::perspective(1, 0.1f), world, VIEWPORT);
    CameraMatrices finite = camera::derive_matrices(camera::perspective(1, 0.1f, 100), world, VIEWPORT);
    Aabb far_box = { .min = { -1, -1, -1000001 }, .max = { 1, 1, -999999 } };
    Aabb near_box = { .min = { -1, -1, -11 }, .max = { 1, 1, -9 } };
    assert(maths::frustum_intersects_aabb(&infinite.frustum, far_box));
    assert(!maths::frustum_intersects_aabb(&finite.frustum, far_box));
    assert(maths::frustum_intersects_aabb(&infinite.frustum, near_box));
    assert(maths::frustum_intersects_aabb(&finite.frustum, near_box));
}

fn void test_lens_shift_moves_projected_center() @test {
    Camera[2] cameras = { camera::perspective_deg(60, 0.1f), camera::orthographic(10, 0.1f, 100) };
    foreach (lens : cameras) {
        lens.lens_shift = { 0.5f, 0 };
        CameraMatrices matrices = camera::derive_matrices(lens, camera_at({ 0, 0, 5 }), VIEWPORT);
        Vec3 screen = camera::world_to_screen(&matrices, { 0, 0, 0 }, VIEWPORT);
        assert(close(screen.x, 1200) && close(screen.y, 450));
    }
}

fn void test_screen_to_ray_center_points_along_camera_forward() @test {
    Mat4 world = camera_world({ 1, 2, 3 }, quarter_turn_y());
    CameraMatrices matrices = camera::derive_matrices(camera::perspective_deg(60, 0.1f), world, VIEWPORT);
    Ray ray = camera::screen_to_ray(&matrices, { 800, 450 }, VIEWPORT);
    assert(close_vec3(ray.origin, { 1, 2, 3 }));
    assert(close_vec3(ray.direction, maths::transform_dir(world, { 0, 0, -1 })));
}

fn void test_orthographic_ray_origin_moves_with_pixel() @test {
    Camera camera = camera::orthographic(10, 0.1f, 100);
    CameraMatrices matrices = camera::derive_matrices(camera, camera_at({ 0, 0, 5 }), VIEWPORT);
    Ray ray = camera::screen_to_ray(&matrices, { 1200, 450 }, VIEWPORT);
    assert(close(ray.origin.x, 0.5f * 5.0f * 1600.0f / 900.0f));
    assert(close(ray.origin.y, 0));
    assert(close(ray.origin.z, 5 - 0.1f));
    assert(close_vec3(ray.direction, { 0, 0, -1 }));
}

fn void test_screen_to_ray_round_trips_world_to_screen() @test {
    Mat4 world = camera_world({ 1, 2, 3 }, quarter_turn_y());
    Camera[2] cameras = { camera::perspective_deg(60, 0.1f), camera::orthographic(10, 0.1f, 100) };
    foreach (lens : cameras) {
        CameraMatrices matrices = camera::derive_matrices(lens, world, VIEWPORT);
        Ray ray = camera::screen_to_ray(&matrices, { 300, 700 }, VIEWPORT);
        Vec3 point = ray.origin + ray.direction * 7.0f;
        Vec3 screen = camera::world_to_screen(&matrices, point, VIEWPORT);
        assert(close(screen.x, 300) && close(screen.y, 700));
    }
}
