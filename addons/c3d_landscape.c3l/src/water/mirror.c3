module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::material;
import c3d::scene;
import std::math;

// A valid lens on no layer: the mirror draws nothing until update copies the viewing camera.
const Camera MIRROR_PLACEHOLDER @private = { .projection = PERSPECTIVE, .fov_y = 1, .near = 1, .layers = 0 };

// The image of the node's local XZ plane: the plane the waves rest on and the mirror reflects across.
fn Plane rest_plane(Mat4 world) @private {
    Vec3 axis_x = maths::transform_dir(world, { 1, 0, 0 });
    Vec3 axis_z = maths::transform_dir(world, { 0, 0, 1 });
    Vec3 normal = axis_z.cross(axis_x).normalize();
    return { .normal = normal, .d = -normal.dot(maths::translation(world)) };
}

// Lowered to the deepest trough: everything above it stays, so the reflection keeps no holes at troughs.
fn Plane mirror_clip_plane(Mat4 world, float amplitude) @private {
    Plane rest = rest_plane(world);
    float lowered = amplitude * rest.normal.dot(maths::transform_dir(world, { 0, 1, 0 }));
    return { .normal = rest.normal, .d = rest.d + lowered };
}

fn void? place_mirror(
    Scene* scene,
    Node* node,
    WaterDesc* desc,
    WaterRuntime* runtime,
    Node* viewing,
    Camera camera,
) @private {
    Mat4 mirrored = maths::reflection_matrix(rest_plane(node.world)).mul(viewing.local.to_mat4());
    Node* mirror = scene.node(runtime.mirror);
    mirror.local = maths::transform_from_affine(mirrored)!;
    // The value update_world writes for a root node, so the mirror is current whichever runs first.
    mirror.world = mirror.local.to_mat4();
    camera.layers &= ~node.layers;
    *scene.get(mirror, Camera) = camera;
    runtime.clip_plane = mirror_clip_plane(node.world, total_amplitude(desc));
}

// Repacks only when the node-local scroll velocities change; the offset stays continuous across the change.
fn void follow_wind(
    AssetStore* assets,
    Node* node,
    WaterDesc* desc,
    WaterRuntime* runtime,
    Vec3 wind_velocity,
    double time,
) @private {
    WaterParams* params = assets.@custom_params(runtime.material, WaterParams);
    Vec4 velocity = ripple_velocity(wind_velocity, node.world, desc.ripple_drift);
    if (velocity == params.scroll_velocity) return;
    float now = shader_time(time);
    Vec4 offset = params.scroll_origin + params.scroll_velocity * (now - params.scroll_time);
    params.scroll_origin = wrap_scroll(assets, desc.ripples, offset);
    params.scroll_velocity = velocity;
    params.scroll_time = now;
    assets.mark_material_dirty(runtime.material);
}

fn Vec4 ripple_velocity(Vec3 wind_velocity, Mat4 world, float drift) @private {
    Vec3 local = maths::transform_dir(maths::inverse_affine(world), wind_velocity);
    Vec2 first = (Vec2){ local.x, local.z } * drift;
    float cosine = math::cos(RIPPLE_CROSS_ANGLE);
    float sine = math::sin(RIPPLE_CROSS_ANGLE);
    return { first.x, first.y, cosine * first.x - sine * first.y, sine * first.x + cosine * first.y };
}

// A whole number of normal-map periods in the ripple reference's texture space leaves the ripples unchanged.
fn Vec4 wrap_scroll(AssetStore* assets, MaterialId ripples, Vec4 offset) @private {
    if (!ripples.generation || !assets.materials.is_live(ripples)) return offset;
    Material* reference = &assets.materials.get(ripples).data;
    if (reference.kind != MaterialKind.STANDARD) return offset;
    UvTransform transform = reference.standard.normal_map.transform;
    if (transform.scale.x == 0 || transform.scale.y == 0) return offset;
    Vec2 first = wrap_to_period({ offset.x, offset.y }, transform);
    Vec2 second = wrap_to_period({ offset.z, offset.w }, transform);
    return { first.x, first.y, second.x, second.y };
}

// The linear part of texture_uv_rows in render/texture_binding.c3, forward and back.
fn Vec2 wrap_to_period(Vec2 offset, UvTransform transform) @private {
    float cosine = math::cos(transform.rotation);
    float sine = math::sin(transform.rotation);
    Vec2 scaled = offset * transform.scale;
    Vec2 texture = { cosine * scaled.x - sine * scaled.y, sine * scaled.x + cosine * scaled.y };
    Vec2 wrapped = texture - math::floor(texture);
    Vec2 unrotated = { cosine * wrapped.x + sine * wrapped.y, cosine * wrapped.y - sine * wrapped.x };
    return unrotated / transform.scale;
}
