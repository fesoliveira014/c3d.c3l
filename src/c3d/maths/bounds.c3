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
 Smallest box containing every transformed corner of the input.
*>
fn Aabb aabb_transform(Aabb bounds, Mat4 model) {
    Vec3 first = transform_point(model, bounds.min);
    Aabb result = { .min = first, .max = first };

    for (uint corner = 1; corner < 8; corner++) {
        Vec3 source = {
            (corner & 1) != 0 ? bounds.max.x : bounds.min.x,
            (corner & 2) != 0 ? bounds.max.y : bounds.min.y,
            (corner & 4) != 0 ? bounds.max.z : bounds.min.z,
        };
        Vec3 transformed = transform_point(model, source);
        result.min = math::min(result.min, transformed);
        result.max = math::max(result.max, transformed);
    }
    return result;
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
