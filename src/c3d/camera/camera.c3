module c3d::camera;

import c3d::maths;
import std::math;

<*
 Layer mask that renders every node.
*>
const uint ALL_LAYERS = 0xFFFFFFFF;

const float RAY_INTERIOR_DEPTH @private = 0.5f; // inside (0, 1), so unprojection never meets an infinite far plane

<*
 Lens model of a camera.
*>
enum Projection {
    PERSPECTIVE,
    ORTHOGRAPHIC,
}

<*
 Lens parameters of a camera node; matrices are derived per view.
*>
struct Camera {
    Projection projection;
    float      fov_y;
    float      ortho_height;
    float      near;
    float      far;
    float      aspect;
    Vec2       lens_shift;
    float      exposure;
    uint       layers;
}

<*
 Matrices, position and frustum of one camera in one viewport.
*>
struct CameraMatrices {
    Mat4       view;
    Mat4       proj;
    Mat4       view_proj;
    Mat4       inv_view_proj;
    Vec3       position;
    Projection projection;
    Frustum    frustum;
}

<*
 Perspective camera; far 0 selects an infinite far plane.
 @param fov_y : "Vertical field of view in radians."
 @require fov_y > 0 && near > 0, far == 0 || far > near
*>
fn Camera perspective(float fov_y, float near, float far = 0) {
    return {
        .projection   = Projection.PERSPECTIVE,
        .fov_y        = fov_y,
        .ortho_height = 0,
        .near         = near,
        .far          = far,
        .aspect       = 0,
        .lens_shift   = { 0, 0 },
        .exposure     = 1,
        .layers       = ALL_LAYERS,
    };
}

<*
 Perspective camera; far 0 selects an infinite far plane.
 @param fov_y_degrees : "Vertical field of view in degrees."
 @require fov_y_degrees > 0 && near > 0, far == 0 || far > near
*>
fn Camera perspective_deg(float fov_y_degrees, float near, float far = 0) {
    return perspective(math::deg_to_rad(fov_y_degrees), near, far);
}

<*
 Orthographic camera covering the height vertically.
 @param height : "World units covered by the viewport height."
 @require height > 0, far > near
*>
fn Camera orthographic(float height, float near, float far) {
    return {
        .projection   = Projection.ORTHOGRAPHIC,
        .fov_y        = 0,
        .ortho_height = height,
        .near         = near,
        .far          = far,
        .aspect       = 0,
        .lens_shift   = { 0, 0 },
        .exposure     = 1,
        .layers       = ALL_LAYERS,
    };
}

<*
 Derive the view matrices and frustum for one viewport.
 @param camera_world : "Affine world matrix of the camera node."
 @param viewport : "Pixels; supplies the aspect when the camera's is zero."
 @require viewport.x > 0 && viewport.y > 0
 @require camera_world.m30 == 0 && camera_world.m31 == 0 && camera_world.m32 == 0
 @require camera_world.determinant() != 0
*>
fn CameraMatrices derive_matrices(Camera camera, Mat4 camera_world, Vec2 viewport) {
    float aspect = camera.aspect > 0 ? camera.aspect : viewport.x / viewport.y;
    Mat4 proj;
    switch (camera.projection) {
        case PERSPECTIVE:
            proj = maths::perspective_reverse_z(
                fov_y:  camera.fov_y,
                aspect: aspect,
                near:   camera.near,
                far:    camera.far,
            );
        case ORTHOGRAPHIC:
            float half_height = camera.ortho_height * 0.5f;
            float half_width = half_height * aspect;
            proj = maths::orthographic_reverse_z(
                left:   -half_width,
                right:  half_width,
                bottom: -half_height,
                top:    half_height,
                near:   camera.near,
                far:    camera.far,
            );
    }
    Mat4 shift = matrix::IDENTITY4;
    shift.m03 = camera.lens_shift.x;
    shift.m13 = camera.lens_shift.y;
    proj = shift.mul(proj);

    Mat4 view = maths::inverse_affine(camera_world);
    Mat4 view_proj = proj.mul(view);
    bool infinite_far = camera.projection == Projection.PERSPECTIVE && camera.far == 0;
    return {
        .view          = view,
        .proj          = proj,
        .view_proj     = view_proj,
        .inv_view_proj = view_proj.inverse()!!,
        .position      = maths::translation(camera_world),
        .projection    = camera.projection,
        .frustum       = maths::frustum_from_view_proj(view_proj, infinite_far),
    };
}

<*
 World-space ray through a pixel of the viewport.
 @param [&in] matrices : "Derived for the same viewport."
 @param pixel : "Relative to the viewport's top-left corner."
 @param viewport : "Pixels."
*>
fn Ray screen_to_ray(CameraMatrices* matrices, Vec2 pixel, Vec2 viewport) {
    Vec2 ndc = pixel_to_ndc(pixel, viewport);
    Vec3 interior = unproject(matrices, ndc, RAY_INTERIOR_DEPTH);
    switch (matrices.projection) {
        case PERSPECTIVE:
            return { .origin = matrices.position, .direction = (interior - matrices.position).normalize() };
        case ORTHOGRAPHIC:
            Vec3 near_point = unproject(matrices, ndc, 1.0f);
            return { .origin = near_point, .direction = (interior - near_point).normalize() };
    }
}

<*
 Pixel position and reverse-Z depth of a world point; unusable behind the camera.
 @param [&in] matrices : "Derived for the same viewport."
 @param viewport : "Pixels."
*>
fn Vec3 world_to_screen(CameraMatrices* matrices, Vec3 point, Vec2 viewport) {
    Vec4 clip = matrices.view_proj.apply({ point.x, point.y, point.z, 1.0f });
    Vec3 ndc = clip.xyz / clip.w;
    return { (ndc.x + 1.0f) * 0.5f * viewport.x, (1.0f - ndc.y) * 0.5f * viewport.y, ndc.z };
}

fn Vec2 pixel_to_ndc(Vec2 pixel, Vec2 viewport) @local {
    return { 2.0f * pixel.x / viewport.x - 1.0f, 1.0f - 2.0f * pixel.y / viewport.y };
}

fn Vec3 unproject(CameraMatrices* matrices, Vec2 ndc, float depth) @local {
    Vec4 homogeneous = matrices.inv_view_proj.apply({ ndc.x, ndc.y, depth, 1.0f });
    return homogeneous.xyz / homogeneous.w;
}
