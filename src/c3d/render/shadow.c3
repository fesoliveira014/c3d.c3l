module c3d::render;

import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::light;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import std::core::array;
import std::math;
import std::sort;

const float LIGHT_BASIS_PARALLEL_THRESHOLD @local = 0.99f; // avoids an unstable cross product near the reference axis
const uint SHADOW_GUARD_TEXELS @local = 2; // covers linear 3x3 comparisons and nearest-grid snapping
const uint SLICE_FACE_CORNERS @local = 4;
const float SHADOW_DEPTH_ROUNDING_MARGIN @local = 8 * math::FLOAT_EPSILON; // keeps fitted boundary planes inside after projection rounding

<* Complete layer request belonging to one selected light. *>
struct ShadowRequest {
    Entity light;
    uint light_index;
    int priority;
    uint layer_count;
    uint first_layer;
}

<* Selected lights and their complete shadow requests. *>
struct LightExtraction {
    LightGpu[] lights;
    ShadowRequest[] shadows;
}

<* Accepted request prefix and atlas budget results. *>
struct ShadowAllocation {
    ShadowRequest[] requests;
    uint layer_count;
    uint dropped;
}

<* Camera-depth intervals covered by a directional light. *>
struct CascadeSplits {
    float near_depth;
    float[light::MAX_SHADOW_CASCADES] far_depths;
    uint count;
}

<* Fitted directional camera and its receiver depth endpoint. *>
struct ShadowCascade {
    CameraMatrices camera;
    float split_depth;
}

<* Completed depth-pass timing with its original light identity. *>
struct ShadowTiming {
    Entity light;
    uint cascade;
    float gpu_ms;
}

<*
 Assign whole requests by priority; reorders requests and returns their prefix.
 @param requests : "Unique lights with positive layer counts."
 @param capacity : "Maximum atlas layers, including zero."
 @require array::@all(requests, fn (value, index) => value.layer_count > 0)
*>
fn ShadowAllocation assign_shadow_layers(ShadowRequest[] requests, uint capacity) {
    sort::quicksort(requests, &by_shadow_priority);
    ShadowAllocation result;
    uint accepted;
    foreach (request : requests) {
        if (request.layer_count > capacity - result.layer_count) {
            result.dropped++;
            continue;
        }
        request.first_layer = result.layer_count;
        result.layer_count += request.layer_count;
        requests[accepted++] = request;
    }
    result.requests = requests[:accepted];
    return result;
}

<*
 Partition the camera's finite shadow coverage.
 @param settings : "Valid enabled shadow settings."
 @require settings.enabled
 @require settings.cascades >= 1 && settings.cascades <= light::MAX_SHADOW_CASCADES
 @require settings.cascade_lambda >= 0 && settings.cascade_lambda <= 1
 @require settings.max_distance > 0 && math::is_finite(settings.max_distance)
 @pure
*>
fn CascadeSplits directional_cascade_splits(Camera camera, ShadowSettings settings) {
    float far_depth = camera.projection == Projection.PERSPECTIVE && camera.far == 0
      ? settings.max_distance : math::min(camera.far, settings.max_distance);
    CascadeSplits result = { .near_depth = camera.near };
    if (far_depth <= camera.near) return result;
    result.count = settings.cascades;
    for (uint index = 0; index < result.count; index++) {
        float weight = (float)(index + 1) / (float)result.count;
        float linear = camera.near + (far_depth - camera.near) * weight;
        result.far_depths[index] = camera.projection == Projection.ORTHOGRAPHIC ? linear
          : (1 - settings.cascade_lambda) * linear
          + settings.cascade_lambda * camera.near * math::pow(far_depth / camera.near, weight);
    }
    result.far_depths[result.count - 1] = far_depth;
    return result;
}

<*
 Fit stable receiver coverage and conservative caster depth.
 @param [&in] view : "Current invertible camera matrices."
 @param near_depth : "Slice start in camera-space forward depth."
 @param far_depth : "Slice end in camera-space forward depth."
 @param light_direction : "Unit world direction of emitted light."
 @param casters : "Scene candidates before camera or light-space culling."
 @param resolution : "Square shadow-map width in texels."
 @param normal_bias : "Maximum receiver displacement in world units."
 @require far_depth > near_depth
 @require resolution > 2 * SHADOW_GUARD_TEXELS
 @require normal_bias >= 0 && math::is_finite(normal_bias)
 @require math::abs(light_direction.length() - 1) < 0.0001f
*>
fn ShadowCascade fit_directional_cascade(
    CameraMatrices* view,
    float near_depth,
    float far_depth,
    Vec3 light_direction,
    MeshCandidate[] casters,
    uint resolution,
    float normal_bias,
) {
    Mat4 inverse_projection = view.proj.inverse()!!;
    Mat4 camera_world = maths::inverse_affine(view.view);
    Vec3[2 * SLICE_FACE_CORNERS] offsets;
    Vec3 center;

    for (uint index = 0; index < offsets.len; index++) {
        float depth = index < SLICE_FACE_CORNERS ? near_depth : far_depth;
        Vec4 projected = view.proj.apply({ 0, 0, -depth, 1 });
        Vec4 corner = inverse_projection.apply({
            (index & 1) != 0 ? 1.0f : -1.0f,
            (index & 2) != 0 ? 1.0f : -1.0f,
            projected.z / projected.w, 1,
        });
        offsets[index] = maths::transform_dir(camera_world, corner.xyz / corner.w);
        center += offsets[index] / (float)offsets.len;
    }

    float radius;
    foreach (offset : offsets) radius = math::max(radius, (offset - center).length());
    center += maths::translation(camera_world);

    Vec3 reference = math::abs(light_direction.y) > LIGHT_BASIS_PARALLEL_THRESHOLD ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
    Vec3 right = light_direction.cross(reference).normalize();
    Vec3 up = right.cross(light_direction);
    Mat4 light_view = {
        .m00 = right.x, .m01 = right.y, .m02 = right.z,
        .m10 = up.x, .m11 = up.y, .m12 = up.z,
        .m20 = -light_direction.x, .m21 = -light_direction.y, .m22 = -light_direction.z,
        .m33 = 1,
    };

    float half_width = (radius + normal_bias) / (1 - (float)(2 * SHADOW_GUARD_TEXELS) / (float)resolution);
    float texel_size = 2 * half_width / (float)resolution;
    Vec3 light_center = maths::transform_point(light_view, center);
    light_view.m03 = -math::round(light_center.x / texel_size) * texel_size;
    light_view.m13 = -math::round(light_center.y / texel_size) * texel_size;

    float minimum = float::max;
    float maximum = -float::max;
    foreach (offset : offsets) {
        float depth = maths::transform_point(light_view, offset + maths::translation(camera_world)).z;
        minimum = math::min(minimum, depth - normal_bias);
        maximum = math::max(maximum, depth + normal_bias);
    }

    foreach (caster : casters) {
        Aabb bounds = maths::aabb_transform(caster.world_bounds, light_view);
        if (bounds.min.x > half_width || bounds.max.x < -half_width
            || bounds.min.y > half_width || bounds.max.y < -half_width) continue;
        minimum = math::min(minimum, bounds.min.z);
        maximum = math::max(maximum, bounds.max.z);
    }

    float depth_margin = math::max(math::abs(minimum), math::abs(maximum), maximum - minimum)
      * SHADOW_DEPTH_ROUNDING_MARGIN;
    minimum -= depth_margin;
    maximum += depth_margin;

    Mat4 projection = maths::orthographic_reverse_z(
        left: -half_width,
        right: half_width,
        bottom: -half_width,
        top: half_width,
        near: -maximum,
        far: -minimum,
    );
    Mat4 view_projection = projection.mul(light_view);

    return {
        .camera = {
            .view = light_view,
            .proj = projection,
            .view_proj = view_projection,
            .inv_view_proj = view_projection.inverse()!!,
            .position = maths::translation(maths::inverse_affine(light_view)),
            .projection = Projection.ORTHOGRAPHIC,
            .frustum = maths::frustum_from_view_proj(view_projection, false),
        },
        .split_depth = far_depth,
    };
}

fn int by_shadow_priority(ShadowRequest first, ShadowRequest second) @local {
    if (first.priority > second.priority) return -1;
    if (first.priority < second.priority) return 1;
    if (first.light.index < second.light.index) return -1;
    if (first.light.index > second.light.index) return 1;
    if (first.light.generation < second.light.generation) return -1;
    return first.light.generation > second.light.generation ? 1 : 0;
}
