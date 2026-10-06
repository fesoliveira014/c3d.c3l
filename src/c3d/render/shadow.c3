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

const float LIGHT_BASIS_PARALLEL_THRESHOLD @private = 0.99f; // avoids an unstable cross product near the reference axis
const uint SHADOW_GUARD_TEXELS @private = 2; // covers linear 3x3 comparisons and nearest-grid snapping
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
    uint sun_light; // packed index plus one of the atmosphere's sun; zero when it packed nothing
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

<* Fitted directional camera, its receiver depth endpoint and normal offset. *>
struct ShadowCascade {
    CameraMatrices camera;
    float split_depth;
    float normal_bias; // metres: the requested texels times this cascade's texel
}

struct LightBasis @private {
    Vec3 right;
    Vec3 up;
}

<* Completed depth-pass timing with its original light identity. *>
struct ShadowTiming {
    Entity light;
    LightKind kind;
    uint layer_index;
    float gpu_ms;
    ViewId view;
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
 Camera depth where cascade index starts blending into the next one.
 The span is the cascade's own split interval, so bands never compound.
 @require index < splits.count
 @require blend >= 0 && blend <= 0.5
 @pure
*>
fn float cascade_blend_depth(CascadeSplits splits, uint index, float blend) {
    float split = splits.far_depths[index];
    if (index + 1 == splits.count) return split;
    float near_depth = index ? splits.far_depths[index - 1] : splits.near_depth;
    return split - blend * (split - near_depth);
}

<*
 Fit stable receiver coverage and conservative caster depth.
 @param [&in] view : "Current invertible camera matrices."
 @param near_depth : "Slice start in camera-space forward depth."
 @param far_depth : "Slice end in camera-space forward depth."
 @param light_direction : "Unit world direction of emitted light."
 @param casters : "Scene candidates before camera or light-space culling."
 @param resolution : "Square shadow-map width in texels."
 @param normal_bias_texels : "Receiver normal offset in texels of this cascade."
 @param origin : "Absolute origin of the camera and caster coordinates."
 @require far_depth > near_depth
 @require normal_bias_texels >= 0 && math::is_finite(normal_bias_texels)
 @require (float)resolution > 2 * ((float)SHADOW_GUARD_TEXELS + normal_bias_texels)
 @require math::abs(light_direction.length() - 1) < 0.0001f
*>
fn ShadowCascade fit_directional_cascade(
    CameraMatrices* view,
    float near_depth,
    float far_depth,
    Vec3 light_direction,
    MeshCandidate[] casters,
    uint resolution,
    float normal_bias_texels,
    Vec3 origin = {},
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

    LightBasis basis = light_basis(light_direction);
    Mat4 light_view = {
        .m00 = basis.right.x, .m01 = basis.right.y, .m02 = basis.right.z,
        .m10 = basis.up.x, .m11 = basis.up.y, .m12 = basis.up.z,
        .m20 = -light_direction.x, .m21 = -light_direction.y, .m22 = -light_direction.z,
        .m33 = 1,
    };

    // Fixed point: half_width = radius + margin_texels * texel_size, where texel_size = 2 * half_width / resolution.
    float margin_texels = (float)SHADOW_GUARD_TEXELS + normal_bias_texels;
    float half_width = radius / (1 - 2 * margin_texels / (float)resolution);
    float texel_size = 2 * half_width / (float)resolution;
    float normal_bias = normal_bias_texels * texel_size;
    Vec3 light_center = maths::transform_point(light_view, center);
    light_view.m03 = -math::round(light_center.x / texel_size) * texel_size;
    light_view.m13 = -math::round(light_center.y / texel_size) * texel_size;
    if (origin != (Vec3){}) {
        // Keep the texel lattice fixed when only the render origin changes.
        double origin_x = (double)basis.right.x * origin.x
          + (double)basis.right.y * origin.y + (double)basis.right.z * origin.z;
        double origin_y = (double)basis.up.x * origin.x + (double)basis.up.y * origin.y + (double)basis.up.z * origin.z;
        light_view.m03 = (float)(origin_x - math::round((origin_x + light_center.x) / texel_size) * texel_size);
        light_view.m13 = (float)(origin_y - math::round((origin_y + light_center.y) / texel_size) * texel_size);
    }

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
        .normal_bias = normal_bias,
    };
}

fn LightBasis light_basis(Vec3 direction) @private {
    Vec3 reference = math::abs(direction.y) > LIGHT_BASIS_PARALLEL_THRESHOLD
      ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
    Vec3 right = direction.cross(reference).normalize();
    return { .right = right, .up = right.cross(direction) };
}

fn int by_shadow_priority(ShadowRequest first, ShadowRequest second) @local {
    if (first.priority > second.priority) return -1;
    if (first.priority < second.priority) return 1;
    if (first.light.index < second.light.index) return -1;
    if (first.light.index > second.light.index) return 1;
    if (first.light.generation < second.light.generation) return -1;
    return first.light.generation > second.light.generation ? 1 : 0;
}
