module c3d::maths;

import std::math;

<*
 Axis-aligned bounding box.
*>
struct Aabb {
    Vec3 min;
    Vec3 max;
}

<*
 Bounding sphere.
*>
struct Sphere {
    Vec3  center;
    float radius;
}

<*
 Half-line with an origin and a direction.
*>
struct Ray {
    Vec3 origin;
    Vec3 direction;
}

<*
 Smallest box containing both inputs.
*>
fn Aabb aabb_merge(Aabb first, Aabb second) {
    return {
        .min = math::min(first.min, second.min),
        .max = math::max(first.max, second.max),
    };
}

<*
 Smallest box containing the transformed input, from its center and extents.
 @param model : "Affine."
*>
fn Aabb aabb_transform(Aabb bounds, Mat4 model) {
    Vec3 center = (bounds.min + bounds.max) * 0.5f;
    Vec3 extent = (bounds.max - bounds.min) * 0.5f;
    Vec3 column_x = { model.m00, model.m10, model.m20 };
    Vec3 column_y = { model.m01, model.m11, model.m21 };
    Vec3 column_z = { model.m02, model.m12, model.m22 };
    Vec3 world_center = transform_point(model, center);
    Vec3 world_extent = math::abs(column_x) * extent.x
                      + math::abs(column_y) * extent.y
                      + math::abs(column_z) * extent.z;
    return { .min = world_center - world_extent, .max = world_center + world_extent };
}

<*
 Whether the ray meets the box, and how far along it.
 @param [&out] distance : "Entry distance; untouched when there is no hit."
*>
fn bool ray_intersects_aabb(Ray ray, Aabb bounds, float* distance) {
    float entry = 0;
    float exit = math::FLOAT_MAX;

    for (usz axis = 0; axis < 3; axis++) {
        float origin = ray.origin[axis];
        float direction = ray.direction[axis];
        float slab_min = bounds.min[axis];
        float slab_max = bounds.max[axis];

        if (direction == 0) {
            if (origin < slab_min || origin > slab_max) return false;
            continue;
        }
        float inverse_direction = 1.0f / direction;
        float slab_entry = (slab_min - origin) * inverse_direction;
        float slab_exit = (slab_max - origin) * inverse_direction;
        if (slab_entry > slab_exit) {
            float crossed = slab_entry;
            slab_entry = slab_exit;
            slab_exit = crossed;
        }
        if (slab_entry > entry) entry = slab_entry;
        if (slab_exit < exit) exit = slab_exit;
        if (entry > exit) return false;
    }

    *distance = entry;
    return true;
}
