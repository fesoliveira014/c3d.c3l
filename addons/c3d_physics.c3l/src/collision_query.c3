module c3d::physics;

import std::math;
import c3d::maths;
import c3d::physics::collide;
import b3;

<* Convex contacts have no cooked triangle index. *>
const uint NO_COLLISION_TRIANGLE = uint::max;

const uint COLLISION_BOUND_CORNERS @local = 8;

<* World contact with an A-to-B normal and native signed separation. *>
struct CollisionContact {
    Vec3 point;
    Vec3 normal;
    float separation;
    uint triangle_index;
}

<*
 Complete native convex manifold in caller storage.
 @param output : "Caller-owned; contents are unspecified on failure."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.state != null && other.state != null
*>
fn usz? CollisionShapeView.contacts(
    self,
    maths::Transform pose_a,
    CollisionShapeView other,
    maths::Transform pose_b,
    CollisionContact[] output,
) {
    check_collision_pair(
        first: self.state,
        pose_a: pose_a,
        second: other.state,
        pose_b: pose_b,
    )!;
    collide::Manifold found = collide::manifold(
        a: self.state.shape,
        pose_a: pose_a,
        b: other.state.shape,
        pose_b: pose_b,
    );
    if (found.count > output.len) return c3d::CAPACITY_EXCEEDED~;

    check_collision_vector(found.normal)!;
    foreach (point : found.points[:found.count]) {
        check_collision_vector(point.point)!;
        if (!math::is_finite(point.separation)) return c3d::UNSUPPORTED~;
    }

    foreach (index, point : found.points[:found.count]) {
        output[index] = {
            .point = point.point,
            .normal = found.normal,
            .separation = point.separation,
            .triangle_index = NO_COLLISION_TRIANGLE,
        };
    }
    return found.count;
}

<*
 Unsigned native distance and world witnesses, including native zero-distance behavior.
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require self.state != null && other.state != null
*>
fn collide::Distance? CollisionShapeView.distance(
    self,
    maths::Transform pose_a,
    CollisionShapeView other,
    maths::Transform pose_b,
) {
    check_collision_pair(
        first: self.state,
        pose_a: pose_a,
        second: other.state,
        pose_b: pose_b,
    )!;
    collide::Distance found = collide::distance(
        a: self.state.shape,
        pose_a: pose_a,
        b: other.state.shape,
        pose_b: pose_b,
    );

    check_collision_vector(found.point_a)!;
    check_collision_vector(found.point_b)!;
    check_collision_vector(found.normal)!;
    if (!math::is_finite(found.distance)) return c3d::UNSUPPORTED~;
    return found;
}

<*
 Native closing-band hit for two world-space translations.
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, b3::NO_HIT
 @require self.state != null && other.state != null
*>
fn collide::Impact? CollisionShapeView.cast(
    self,
    maths::Transform pose_a,
    CollisionShapeView other,
    maths::Transform pose_b,
    Vec3 translation_a,
    Vec3 translation_b,
) {
    if (!collision_vector_finite(translation_a) || !collision_vector_finite(translation_b)) {
        return c3d::INVALID_ARGUMENT~;
    }
    check_collision_pair(
        first: self.state,
        pose_a: pose_a,
        second: other.state,
        pose_b: pose_b,
    )!;

    Vec3 translation = translation_b - translation_a;
    check_collision_vector(translation)!;
    Vec3 local_translation = collision_rotate(pose_a.rotation.conjugate(), translation)!;
    check_collision_relative(
        first: self.state.bounds,
        pose_a: pose_a,
        second: other.state.bounds,
        pose_b: pose_b,
        translation: local_translation,
    )!;
    check_collision_world(self.state.bounds, pose_a, translation_a)!;
    check_collision_world(other.state.bounds, pose_b, translation_b)!;

    collide::Impact found = collide::cast(
        a: self.state.shape,
        pose_a: pose_a,
        b: other.state.shape,
        pose_b: pose_b,
        translation: translation,
    )!;
    found.point += translation_a * found.time;
    check_collision_impact(found)!;
    return found;
}

<*
 Native rotational sweep hit in world space.
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, b3::NO_HIT
 @require self.state != null && other.state != null
*>
fn collide::Impact? CollisionShapeView.time_of_impact(
    self,
    collide::Sweep sweep_a,
    CollisionShapeView other,
    collide::Sweep sweep_b,
) {
    check_collision_pair(
        first: self.state,
        pose_a: sweep_a.start,
        second: other.state,
        pose_b: sweep_b.start,
    )!;
    check_collision_pair(
        first: self.state,
        pose_a: sweep_a.end,
        second: other.state,
        pose_b: sweep_b.end,
    )!;
    check_collision_sweeps(
        first: self.state.bounds,
        sweep_a: sweep_a,
        second: other.state.bounds,
        sweep_b: sweep_b,
    )!;

    collide::Impact found = collide::time_of_impact(
        a: self.state.shape,
        sweep_a: sweep_a,
        b: other.state.shape,
        sweep_b: sweep_b,
    )!;
    check_collision_impact(found)!;
    return found;
}

<*
 Closest native convex ray hit, preserving inside-hit zero normals.
 @param direction : "Unit world direction."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, b3::NO_HIT
 @require self.state != null
*>
fn collide::ShapeRayHit? CollisionShapeView.ray_cast(
    self,
    maths::Transform pose,
    Vec3 origin,
    Vec3 direction,
    float max_distance,
) {
    check_collision_pose(pose)!;
    if (!collision_vector_finite(origin) || !collision_vector_finite(direction)
        || !math::is_finite(max_distance) || max_distance <= 0
        || math::abs(direction.length() - 1) > collide::UNIT_SCALE_TOLERANCE) {
        return c3d::INVALID_ARGUMENT~;
    }

    check_collision_world(self.state.bounds, pose, {})!;
    Vec3 displacement = origin - pose.position;
    check_collision_vector(displacement)!;
    Vec3 local_origin = collision_rotate(pose.rotation.conjugate(), displacement)!;
    Vec3 local_direction = collision_rotate(pose.rotation.conjugate(), direction)!;
    Vec3 local_translation = local_direction * max_distance;
    check_collision_vector(local_translation)!;
    Vec3 local_end = local_origin + local_translation;
    check_collision_vector(local_end)!;

    maths::Aabb ray_bounds = {
        .min = math::min(local_origin, local_end),
        .max = math::max(local_origin, local_end),
    };
    check_collision_span(self.state.bounds, ray_bounds)!;
    check_collision_length(local_translation)!;
    check_collision_vector(origin + direction * max_distance)!;

    collide::ShapeRayHit found = collide::ray_cast(
        shape: self.state.shape,
        pose: pose,
        origin: origin,
        direction: direction,
        max_distance: max_distance,
    )!;
    check_collision_vector(found.point)!;
    check_collision_vector(found.normal)!;
    if (!math::is_finite(found.fraction)) return c3d::UNSUPPORTED~;
    return found;
}

fn bool collision_vector_finite(Vec3 value) @local {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn void? check_collision_vector(Vec3 value) @local {
    if (!collision_vector_finite(value)) return c3d::UNSUPPORTED~;
}

fn void? check_collision_length(Vec3 value) @local {
    check_collision_vector(value)!;
    if (!math::is_finite(value.dot(value))) return c3d::UNSUPPORTED~;
}

fn void? check_collision_pose(maths::Transform pose) @local {
    if (!collision_vector_finite(pose.position) || !collision_vector_finite(pose.scale)) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (component : pose.rotation.v) {
        if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
    }
    float length = pose.rotation.v.length();
    if (!math::is_finite(length) || math::abs(length - 1) > collide::UNIT_SCALE_TOLERANCE) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!collide::unit_scale(pose)) return c3d::UNSUPPORTED~;
}

fn Vec3 collision_bound_corner(maths::Aabb bounds, uint corner) @local {
    return {
        corner & 1 ? bounds.max.x : bounds.min.x,
        corner & 2 ? bounds.max.y : bounds.min.y,
        corner & 4 ? bounds.max.z : bounds.min.z,
    };
}

fn Vec3? collision_rotate(Quat rotation, Vec3 point) @local {
    Quat product = rotation.mul((Quat){ .v = { point.x, point.y, point.z, 0 } });
    foreach (component : product.v) if (!math::is_finite(component)) return c3d::UNSUPPORTED~;
    Vec3 result = product.mul(rotation.conjugate()).v.xyz;
    check_collision_vector(result)!;
    return result;
}

fn Vec3? collision_native_rotate(Quat rotation, Vec3 point) @local {
    Vec3 first = rotation.v.xyz.cross(point);
    check_collision_vector(first)!;
    Vec3 second = first + rotation.v.w * point;
    check_collision_vector(second)!;
    Vec3 third = rotation.v.xyz.cross(second);
    check_collision_vector(third)!;
    Vec3 result = point + 2 * third;
    check_collision_vector(result)!;
    return result;
}

fn Vec3? collision_matrix_rotate(Quat rotation, Vec3 point) @local {
    Vec3 result;
    float x = rotation.v.x;
    float y = rotation.v.y;
    float z = rotation.v.z;
    float w = rotation.v.w;
    result.x = (1 - 2 * (y * y + z * z)) * point.x
      + (2 * (x * y - z * w)) * point.y + (2 * (x * z + y * w)) * point.z;
    result.y = (2 * (x * y + z * w)) * point.x
      + (1 - 2 * (x * x + z * z)) * point.y + (2 * (y * z - x * w)) * point.z;
    result.z = (2 * (x * z - y * w)) * point.x
      + (2 * (y * z + x * w)) * point.y + (1 - 2 * (x * x + y * y)) * point.z;
    check_collision_vector(result)!;
    return result;
}

fn void? check_collision_world(maths::Aabb bounds, maths::Transform pose, Vec3 translation) @local {
    check_collision_vector(pose.position + translation)!;
    for (uint corner = 0; corner < COLLISION_BOUND_CORNERS; corner++) {
        Vec3 rotated = collision_rotate(pose.rotation, collision_bound_corner(bounds, corner))!;
        Vec3 world = rotated + pose.position;
        check_collision_vector(world)!;
        check_collision_vector(world + translation)!;
    }
}

fn void? check_collision_span(maths::Aabb first, maths::Aabb second, Vec3 source_span = {}) @local {
    Vec3 lower = second.min - first.max;
    Vec3 upper = second.max - first.min;
    Vec3 local_span = math::max(math::abs(first.max - first.min), math::abs(second.max - second.min));
    check_collision_contractions(
        math::max(math::abs(lower), math::abs(upper)),
        math::max(local_span, source_span),
    )!;
}

fn void? check_collision_contractions(Vec3 span, Vec3 local_span) @local {
    check_collision_length(span)!;
    check_collision_vector(local_span)!;
    float coordinate = math::max(span.x, math::max(span.y, span.z));
    float edge = collision_bound_sum(coordinate, coordinate)!;

    // Segment closest-point numerators and denominator multiply pairs of dot products.
    float dot = collision_bound_dot(edge, edge)!;
    float product = collision_bound_product(dot, dot)!;
    (void)collision_bound_sum(product, product)!;

    // GJK triangle barycentrics square a cross product; tetrahedra use scalar triples.
    float normal = collision_bound_cross(edge, edge)!;
    (void)collision_bound_dot(normal, normal)!;
    (void)collision_bound_dot(normal, edge)!;

    // The edge search direction is a double cross, whose squared length is sixth order.
    float first_cross = collision_bound_cross(edge, coordinate)!;
    float search = collision_bound_cross(first_cross, edge)!;
    search = math::max(coordinate, math::max(normal, search));
    (void)collision_bound_dot(search, search)!;

    // Native support projections subtract points[0] in each proxy's own local frame.
    float support_axis = collision_rotation_bound({ search, search, search })!;
    float support_span = math::max(local_span.x, math::max(local_span.y, local_span.z));
    (void)collision_bound_dot(support_axis, support_span)!;
}

fn void? check_collision_relative(
    maths::Aabb first,
    maths::Transform pose_a,
    maths::Aabb second,
    maths::Transform pose_b,
    Vec3 translation = {},
) @local {
    Vec3 displacement = pose_b.position - pose_a.position;
    check_collision_vector(displacement)!;
    Quat inverse = pose_a.rotation.conjugate();
    Vec3 position = collision_rotate(inverse, displacement)!;
    Quat rotation = inverse.mul(pose_b.rotation).normalize();
    check_collision_vector(position + translation)!;

    maths::Aabb transformed = {
        .min = { float::max, float::max, float::max },
        .max = { -float::max, -float::max, -float::max },
    };
    for (uint corner = 0; corner < COLLISION_BOUND_CORNERS; corner++) {
        Vec3 local = collision_bound_corner(second, corner);
        Vec3[2] rotations = { collision_native_rotate(rotation, local)!, collision_matrix_rotate(rotation, local)! };
        foreach (rotated : rotations) {
            Vec3 start = rotated + position;
            Vec3 end = rotated + (position + translation);
            check_collision_vector(start)!;
            check_collision_vector(end)!;
            transformed.min = math::min(transformed.min, math::min(start, end));
            transformed.max = math::max(transformed.max, math::max(start, end));
        }
    }

    Vec3 source_span = math::max(math::abs(first.max - first.min), math::abs(second.max - second.min));
    check_collision_span(first, transformed, source_span)!;
}

fn void? check_collision_pair(
    CollisionShapeState* first,
    maths::Transform pose_a,
    CollisionShapeState* second,
    maths::Transform pose_b,
) @local {
    check_collision_pose(pose_a)!;
    check_collision_pose(pose_b)!;
    float radius = first.shape.radius + second.shape.radius;
    if (!math::is_finite(radius * radius)) return c3d::UNSUPPORTED~;

    check_collision_world(first.bounds, pose_a, {})!;
    check_collision_world(second.bounds, pose_b, {})!;
    check_collision_relative(
        first: first.bounds,
        pose_a: pose_a,
        second: second.bounds,
        pose_b: pose_b,
    )!;
    check_collision_relative(
        first: second.bounds,
        pose_a: pose_b,
        second: first.bounds,
        pose_b: pose_a,
    )!;
}

fn void? check_collision_sweeps(
    maths::Aabb first,
    collide::Sweep sweep_a,
    maths::Aabb second,
    collide::Sweep sweep_b,
) @local {
    Vec3 end_a = sweep_a.end.position - sweep_a.start.position;
    Vec3 start_b = sweep_b.start.position - sweep_a.start.position;
    Vec3 end_b = sweep_b.end.position - sweep_a.start.position;
    check_collision_vector(end_a)!;
    check_collision_vector(start_b)!;
    check_collision_vector(end_b)!;
    check_collision_vector(end_b - start_b)!;

    float first_radius = collision_rotation_bound(math::max(math::abs(first.min), math::abs(first.max)))!;
    float second_radius = collision_rotation_bound(math::max(math::abs(second.min), math::abs(second.max)))!;
    maths::Aabb moving_a = {
        .min = math::min((Vec3){}, end_a) - first_radius,
        .max = math::max((Vec3){}, end_a) + first_radius,
    };
    maths::Aabb moving_b = {
        .min = math::min(start_b, end_b) - second_radius,
        .max = math::max(start_b, end_b) + second_radius,
    };
    Vec3 span = math::max(math::abs(moving_b.min - moving_a.max), math::abs(moving_b.max - moving_a.min));
    float relative_bound = collision_rotation_bound(span)!;
    Vec3 source_span = math::max(math::abs(first.max - first.min), math::abs(second.max - second.min));
    check_collision_contractions({ relative_bound, relative_bound, relative_bound }, source_span)!;

    Vec3[4] endpoints = {
        sweep_a.start.position,
        sweep_a.end.position,
        sweep_b.start.position,
        sweep_b.end.position,
    };
    foreach (position : endpoints) {
        float radius = math::max(first_radius, second_radius);
        check_collision_vector(position - radius)!;
        check_collision_vector(position + radius)!;
    }
}

fn float? collision_upper_bound(double value) @local {
    if (!math::is_finite(value) || value > float::max) return c3d::UNSUPPORTED~;
    float upper = (float)value;
    if ((double)upper < value) upper = bitcast(bitcast(upper, uint) + 1, float);
    if (!math::is_finite(upper)) return c3d::UNSUPPORTED~;
    return upper;
}

fn float? collision_rotation_bound(Vec3 extent) @local {
    // Sweeps change rotation between endpoints; enclose native and C3 intermediate operations.
    check_collision_vector(extent)!;
    float coordinate = math::max(extent.x, math::max(extent.y, extent.z));
    double component = 1 + (double)collide::UNIT_SCALE_TOLERANCE;
    float rotation = collision_upper_bound(component * component)!;

    float product = collision_bound_product(rotation, coordinate)!;
    float first = collision_bound_sum(product, product)!;
    float second = collision_bound_sum(first, product)!;
    float outer = collision_bound_product(rotation, second)!;
    float third = collision_bound_sum(outer, outer)!;
    float native = collision_bound_sum(coordinate, collision_bound_sum(third, third)!)!;
    float standard = collision_bound_sum(third, third)!;

    float square = collision_bound_product(rotation, rotation)!;
    float twice = collision_bound_sum(square, square)!;
    float coefficient = collision_bound_sum(twice, twice)!;
    float off_diagonal = collision_bound_product(coefficient, coordinate)!;
    float diagonal = collision_bound_product(collision_bound_sum(1, coefficient)!, coordinate)!;
    float matrix = collision_bound_sum(collision_bound_sum(diagonal, off_diagonal)!, off_diagonal)!;
    return math::max(native, math::max(standard, matrix));
}

fn float? collision_bound_sum(float first, float second) @local {
    return collision_upper_bound((double)first + second);
}

fn float? collision_bound_product(float first, float second) @local {
    return collision_upper_bound((double)first * second);
}

fn float? collision_bound_dot(float first, float second) @local {
    float product = collision_bound_product(first, second)!;
    return collision_bound_sum(collision_bound_sum(product, product)!, product);
}

fn float? collision_bound_cross(float first, float second) @local {
    float product = collision_bound_product(first, second)!;
    return collision_bound_sum(product, product);
}

fn void? check_collision_impact(collide::Impact impact) @local {
    check_collision_vector(impact.point)!;
    check_collision_vector(impact.normal)!;
    if (!math::is_finite(impact.time)) return c3d::UNSUPPORTED~;
}
