module c3d::physics;

import c3d;
import c3d::maths;
import c3d::physics::cloth;
import std::math;
import std::math::vector;

alias ContactVector @private = double[<3>];
alias ContactIntervals @private = ContactInterval[3];

const ulong CONTACT_SIGN_BIT @local = 1UL << 63;
const uint CONTACT_FLOAT_SIGN_BIT @local = 1u << 31;
const uint MAX_CONTACT_HULL_POINTS @private = 128;
const double CONTACT_AXIS_DISTANCE @local = 1e-7; // centreline contacts need a stable transverse direction

enum ClothCandidateKind @private {
    GROUND,
    SHAPE,
    TRIANGLE,
}

struct ClothCandidate @private {
    uint       particle;
    uint       shape;
    int        triangle_index;
    ClothCandidateKind kind;
    Vec3[3]    vertices;
}

struct ClothContact @private {
    uint candidate;
    Vec3 original;
    Vec3 corrected;
}

struct ContactInterval @private {
    double min;
    double max;
}

struct ContactFrame @private {
    ContactIntervals position;
    ContactInterval[9] rotation;
}

struct ContactProjection @private {
    Vec3 corrected;
    double residual;
}

struct ContactPlane @local {
    ContactVector normal;
    ContactInterval support;
}

fn bool contact_arithmetic_supported() @private {
    if ($$get_rounding_mode() != (int)math::RoundingMode.TO_NEAREST) return false;
    double subnormal = bitcast(1UL, double);
    return bitcast(@volatile_load(subnormal) * 2.0, ulong) == 2UL;
}

fn double? contact_adjacent(double value, bool upward) @local {
    if (!math::is_finite(value)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    ulong bits = bitcast(value, ulong);
    if (value == 0) {
        bits = upward ? 1UL : CONTACT_SIGN_BIT | 1UL;
    } else if ((value > 0) == upward) {
        bits++;
    } else {
        bits--;
    }
    double adjacent = bitcast(bits, double);
    if (!math::is_finite(adjacent)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    return adjacent;
}

fn ContactInterval contact_value(double value) @private => { .min = value, .max = value };

fn ContactInterval? contact_add(ContactInterval first, ContactInterval second) @private {
    return { .min = contact_adjacent(first.min + second.min, false)!, .max = contact_adjacent(first.max + second.max, true)! };
}

fn ContactInterval? contact_subtract(ContactInterval first, ContactInterval second) @private {
    return { .min = contact_adjacent(first.min - second.max, false)!, .max = contact_adjacent(first.max - second.min, true)! };
}

fn ContactInterval? contact_multiply(ContactInterval first, ContactInterval second) @private {
    double[4] products = { first.min * second.min, first.min * second.max, first.max * second.min, first.max * second.max };
    double low = products[0];
    double high = products[0];
    foreach (product : products) {
        if (!math::is_finite(product)) return cloth::CONTACT_PRECISION_EXCEEDED~;
        low = math::min(low, product);
        high = math::max(high, product);
    }
    return { .min = contact_adjacent(low, false)!, .max = contact_adjacent(high, true)! };
}

fn ContactInterval? contact_divide(ContactInterval numerator, ContactInterval denominator) @private {
    if (denominator.min <= 0) return cloth::CONTACT_PRECISION_EXCEEDED~;
    double[4] quotients = {
        numerator.min / denominator.min, numerator.min / denominator.max,
        numerator.max / denominator.min, numerator.max / denominator.max,
    };
    double low = quotients[0];
    double high = quotients[0];
    foreach (quotient : quotients) {
        if (!math::is_finite(quotient)) return cloth::CONTACT_PRECISION_EXCEEDED~;
        low = math::min(low, quotient);
        high = math::max(high, quotient);
    }
    return { .min = contact_adjacent(low, false)!, .max = contact_adjacent(high, true)! };
}

fn ContactInterval? contact_square(ContactInterval value) @local {
    double first = value.min * value.min;
    double second = value.max * value.max;
    if (!math::is_finite(first) || !math::is_finite(second)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    double low = value.min <= 0 && value.max >= 0 ? 0 : math::min(first, second);
    return { .min = math::max(0.0, contact_adjacent(low, false)!), .max = contact_adjacent(math::max(first, second), true)! };
}

fn ContactInterval? contact_root(ContactInterval value) @local {
    if (value.max < 0) return cloth::CONTACT_PRECISION_EXCEEDED~;
    return {
        .min = math::max(0.0, contact_adjacent(math::sqrt(math::max(0.0, value.min)), false)!),
        .max = contact_adjacent(math::sqrt(value.max), true)!,
    };
}

fn ContactIntervals contact_vector(ContactVector value) @private {
    return { contact_value(value.x), contact_value(value.y), contact_value(value.z) };
}

fn ContactIntervals? contact_vector_add(ContactIntervals first, ContactIntervals second) @private {
    return { contact_add(first[0], second[0])!, contact_add(first[1], second[1])!, contact_add(first[2], second[2])! };
}

fn ContactIntervals? contact_vector_subtract(ContactIntervals first, ContactIntervals second) @private {
    return { contact_subtract(first[0], second[0])!, contact_subtract(first[1], second[1])!, contact_subtract(first[2], second[2])! };
}

fn ContactIntervals? contact_vector_scale(ContactIntervals value, ContactInterval scale) @private {
    return { contact_multiply(value[0], scale)!, contact_multiply(value[1], scale)!, contact_multiply(value[2], scale)! };
}

fn ContactInterval? contact_dot(ContactIntervals first, ContactIntervals second) @private {
    return contact_add(contact_add(contact_multiply(first[0], second[0])!, contact_multiply(first[1], second[1])!)!,
        contact_multiply(first[2], second[2])!);
}

fn ContactInterval? contact_length(ContactIntervals value) @private {
    return contact_root(contact_add(contact_add(contact_square(value[0])!, contact_square(value[1])!)!, contact_square(value[2])!)!);
}

fn ContactVector contact_middle(ContactIntervals value) @private {
    return { value[0].min * 0.5 + value[0].max * 0.5,
        value[1].min * 0.5 + value[1].max * 0.5,
        value[2].min * 0.5 + value[2].max * 0.5 };
}

fn ContactFrame? contact_frame_of(maths::Transform pose) @local {
    if (!contact_finite(pose.position)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    ContactInterval[4] quaternion;
    ContactInterval squared = contact_value(0);
    for (uint index = 0; index < 4; index++) {
        if (!math::is_finite(pose.rotation.v[index])) return cloth::CONTACT_PRECISION_EXCEEDED~;
        quaternion[index] = contact_value(pose.rotation.v[index]);
        squared = contact_add(squared, contact_square(quaternion[index])!)!;
    }
    ContactInterval magnitude = contact_root(squared)!;
    foreach (&value : quaternion) *value = contact_divide(*value, magnitude)!;
    ContactInterval xx = contact_square(quaternion[0])!;
    ContactInterval yy = contact_square(quaternion[1])!;
    ContactInterval zz = contact_square(quaternion[2])!;
    ContactInterval xy = contact_multiply(quaternion[0], quaternion[1])!;
    ContactInterval xz = contact_multiply(quaternion[0], quaternion[2])!;
    ContactInterval yz = contact_multiply(quaternion[1], quaternion[2])!;
    ContactInterval wx = contact_multiply(quaternion[3], quaternion[0])!;
    ContactInterval wy = contact_multiply(quaternion[3], quaternion[1])!;
    ContactInterval wz = contact_multiply(quaternion[3], quaternion[2])!;
    ContactInterval one = contact_value(1);
    ContactInterval two = contact_value(2);
    return {
        .position = contact_vector((ContactVector)pose.position),
        .rotation = {
            contact_subtract(one, contact_multiply(two, contact_add(yy, zz)!)!)!,
            contact_multiply(two, contact_subtract(xy, wz)!)!,
            contact_multiply(two, contact_add(xz, wy)!)!,
            contact_multiply(two, contact_add(xy, wz)!)!,
            contact_subtract(one, contact_multiply(two, contact_add(xx, zz)!)!)!,
            contact_multiply(two, contact_subtract(yz, wx)!)!,
            contact_multiply(two, contact_subtract(xz, wy)!)!,
            contact_multiply(two, contact_add(yz, wx)!)!,
            contact_subtract(one, contact_multiply(two, contact_add(xx, yy)!)!)!,
        },
    };
}

fn ContactIntervals? contact_rotate(ContactFrame* frame, ContactIntervals vector) @private {
    ContactIntervals result;
    for (uint row = 0; row < 3; row++) {
        result[row] = contact_value(0);
        for (uint column = 0; column < 3; column++) {
            result[row] = contact_add(result[row], contact_multiply(frame.rotation[row * 3 + column], vector[column])!)!;
        }
    }
    return result;
}

fn ContactIntervals? contact_point(ContactFrame* frame, Vec3 point) @private {
    if (!contact_finite(point)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    return contact_vector_add(frame.position, contact_rotate(frame, contact_vector((ContactVector)point))!);
}

fn ContactFrame? contact_frame(maths::Transform body, maths::Transform local) @private {
    ContactFrame outer = contact_frame_of(body)!;
    ContactFrame inner = contact_frame_of(local)!;
    ContactFrame result = { .position = contact_vector_add(outer.position, contact_rotate(&outer, inner.position)!)! };
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) {
            ContactInterval value = contact_value(0);
            for (uint index = 0; index < 3; index++) {
                value = contact_add(value, contact_multiply(outer.rotation[row * 3 + index], inner.rotation[index * 3 + column])!)!;
            }
            result.rotation[row * 3 + column] = value;
        }
    }
    return result;
}

fn float? contact_float_bound(double value, bool upward) @private {
    float rounded = (float)value;
    if (!math::is_finite(rounded)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    if ((upward && (double)rounded >= value) || (!upward && (double)rounded <= value)) return rounded;
    uint bits = bitcast(rounded, uint);
    if (rounded == 0) {
        bits = upward ? 1u : CONTACT_FLOAT_SIGN_BIT | 1u;
    } else if ((rounded > 0) == upward) {
        bits++;
    } else {
        bits--;
    }
    rounded = bitcast(bits, float);
    if (!math::is_finite(rounded)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    return rounded;
}

fn Aabb? contact_query_bounds(ContactFrame* frame, Vec3 point, double radius) @private {
    if (!contact_finite(point) || !math::is_finite(radius)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    ContactIntervals relative = contact_vector_subtract(contact_vector((ContactVector)point), frame.position)!;
    Aabb bounds;
    for (uint row = 0; row < 3; row++) {
        ContactInterval value = contact_value(0);
        for (uint column = 0; column < 3; column++) {
            value = contact_add(value, contact_multiply(frame.rotation[column * 3 + row], relative[column])!)!;
        }
        bounds.min[row] = contact_float_bound(contact_subtract(value, contact_value(radius))!.min, false)!;
        bounds.max[row] = contact_float_bound(contact_add(value, contact_value(radius))!.max, true)!;
    }
    return bounds;
}

fn ContactVector contact_perpendicular(ContactVector axis) @local {
    double squared = axis.dot(axis);
    if (!(squared > 0)) return { 0, 1, 0 };
    ContactVector unit = axis / math::sqrt(squared);
    ContactVector reference = math::abs(unit.y) < 0.9 ? (ContactVector){ 0, 1, 0 } : (ContactVector){ 1, 0, 0 };
    return unit.cross(reference);
}

fn ContactVector contact_triangle_weights(
    ContactVector point,
    ContactVector first,
    ContactVector second,
    ContactVector third,
) @local {
    ContactVector first_edge = second - first;
    ContactVector second_edge = third - first;
    ContactVector relative = point - first;
    double first_squared = first_edge.dot(first_edge);
    double mixed = first_edge.dot(second_edge);
    double second_squared = second_edge.dot(second_edge);
    double denominator = first_squared * second_squared - mixed * mixed;
    if (denominator > 0) {
        double u = (second_squared * first_edge.dot(relative) - mixed * second_edge.dot(relative)) / denominator;
        double v = (first_squared * second_edge.dot(relative) - mixed * first_edge.dot(relative)) / denominator;
        if (u >= 0 && v >= 0 && u + v <= 1) return { math::max(0.0, 1 - u - v), u, v };
    }
    ContactVector[3] corners = { first, second, third };
    ContactVector weights = { 1, 0, 0 };
    double nearest = double::max;
    for (uint corner = 0; corner < 3; corner++) {
        uint next = (corner + 1) % 3;
        ContactVector edge = corners[next] - corners[corner];
        double squared = edge.dot(edge);
        double along = squared > 0 ? math::clamp((point - corners[corner]).dot(edge) / squared, 0.0, 1.0) : 0;
        ContactVector delta = point - corners[corner] - edge * along;
        double distance = delta.dot(delta);
        if (distance >= nearest) continue;
        nearest = distance;
        weights = {};
        weights[corner] = 1 - along;
        weights[next] = along;
    }
    return weights;
}

fn ContactIntervals? contact_triangle_witness(
    ContactIntervals first,
    ContactIntervals second,
    ContactIntervals third,
    ContactVector weights,
) @local {
    weights = math::max(weights, (ContactVector){});
    ContactInterval total = contact_add(contact_add(contact_value(weights.x), contact_value(weights.y))!, contact_value(weights.z))!;
    ContactIntervals sum = contact_vector_add(contact_vector_add(
        contact_vector_scale(first, contact_value(weights.x))!, contact_vector_scale(second, contact_value(weights.y))!)!,
        contact_vector_scale(third, contact_value(weights.z))!)!;
    return contact_vector_scale(sum, contact_divide(contact_value(1), total)!);
}

fn ContactPlane? contact_support(ContactIntervals[] points, ContactVector normal) @local {
    ContactPlane plane = { .normal = normal, .support = { .min = -double::max, .max = -double::max } };
    foreach (point : points) {
        ContactInterval projection = contact_dot(contact_vector(normal), point)!;
        plane.support.min = math::max(plane.support.min, projection.min);
        plane.support.max = math::max(plane.support.max, projection.max);
    }
    return plane;
}

fn ContactInterval? contact_separation(ContactPlane plane, Vec3 point) @local {
    return contact_divide(contact_subtract(contact_dot(contact_vector(plane.normal), contact_vector((ContactVector)point))!, plane.support)!,
        contact_length(contact_vector(plane.normal))!);
}

fn ContactProjection? contact_project_plane(
    ContactPlane plane,
    Vec3 position,
    ContactInterval reach,
    float tolerance,
    bool correct,
) @local {
    ContactInterval separation = contact_separation(plane, position)!;
    double residual = math::max(0.0, reach.max - separation.min);
    ContactProjection projection = { .corrected = position, .residual = residual };
    if (!correct || residual <= tolerance) return projection;

    ContactIntervals normal = contact_vector(plane.normal);
    ContactInterval level = contact_add(plane.support,
        contact_multiply(contact_add(reach, contact_value((double)tolerance / 4))!, contact_length(normal)!)!)!;
    ContactInterval displacement = contact_divide(
        contact_subtract(level, contact_dot(normal, contact_vector((ContactVector)position))!)!, contact_dot(normal, normal)!,
    )!;
    ContactIntervals result = contact_vector_add(contact_vector((ContactVector)position), contact_vector_scale(normal, contact_value(displacement.max))!)!;
    projection.corrected = (Vec3)contact_middle(result);
    if (!contact_finite(projection.corrected) || projection.corrected == position) return cloth::CONTACT_PRECISION_EXCEEDED~;
    return projection;
}

fn ContactProjection? contact_capsule(
    ContactFrame* frame,
    Vec3 start,
    Vec3 end,
    float radius,
    Vec3 position,
    float thickness,
    float tolerance,
    bool correct,
) @private {
    ContactIntervals[2] points = { contact_point(frame, start)!, contact_point(frame, end)! };
    ContactVector first = contact_middle(points[0]);
    ContactVector axis = contact_middle(points[1]) - first;
    double squared = axis.dot(axis);
    double along = squared > 0 ? math::clamp(((ContactVector)position - first).dot(axis) / squared, 0.0, 1.0) : 0;
    ContactVector normal = (ContactVector)position - first - axis * along;
    if (normal.dot(normal) <= CONTACT_AXIS_DISTANCE * CONTACT_AXIS_DISTANCE) normal = contact_perpendicular(axis);
    ContactPlane plane = contact_support(points[..], normal)!;
    return contact_project_plane(
        plane: plane,
        position: position,
        reach: contact_add(contact_value(radius), contact_value(thickness))!,
        tolerance: tolerance,
        correct: correct,
    );
}

fn ContactProjection? contact_triangle(
    ContactFrame* frame,
    Vec3[3] vertices,
    Vec3 position,
    float thickness,
    float tolerance,
    bool correct,
) @private {
    ContactIntervals[3] points = { contact_point(frame, vertices[0])!, contact_point(frame, vertices[1])!, contact_point(frame, vertices[2])! };
    ContactVector first = contact_middle(points[0]);
    ContactVector second = contact_middle(points[1]);
    ContactVector third = contact_middle(points[2]);
    ContactVector weights = contact_triangle_weights(point: (ContactVector)position, first: first, second: second, third: third);
    ContactIntervals witness = contact_triangle_witness(first: points[0], second: points[1], third: points[2], weights: weights)!;
    ContactVector normal = (ContactVector)position - contact_middle(witness);
    if (normal.dot(normal) <= CONTACT_AXIS_DISTANCE * CONTACT_AXIS_DISTANCE) {
        normal = (second - first).cross(third - first);
        if (normal.dot(normal) <= 0) normal = contact_perpendicular(second - first);
    }
    return contact_project_plane(
        plane: contact_support(points[..], normal)!,
        position: position,
        reach: contact_value(thickness),
        tolerance: tolerance,
        correct: correct,
    );
}

fn ContactProjection? contact_convex(
    ContactFrame* frame,
    Vec3[] vertices,
    uint[] triangles,
    Vec3[] normals,
    Vec3 position,
    float thickness,
    float tolerance,
    bool correct,
) @private {
    ContactIntervals[MAX_CONTACT_HULL_POINTS] storage;
    if (!vertices.len || vertices.len > storage.len || !triangles.len) return cloth::CONTACT_PRECISION_EXCEEDED~;
    ContactIntervals[] points = storage[:vertices.len];
    foreach (index, vertex : vertices) points[index] = contact_point(frame, vertex)!;
    ContactVector nearest_point;
    ContactVector exit_normal;
    double nearest = double::max;
    double closest_plane = -double::max;
    for (usz triangle = 0; triangle < triangles.len / 3; triangle++) {
        uint first = triangles[3 * triangle];
        uint second = triangles[3 * triangle + 1];
        uint third = triangles[3 * triangle + 2];
        ContactVector weights = contact_triangle_weights(
            point: (ContactVector)position,
            first: contact_middle(points[first]),
            second: contact_middle(points[second]),
            third: contact_middle(points[third]),
        );
        ContactIntervals witness = contact_triangle_witness(
            first: points[first], second: points[second], third: points[third], weights: weights,
        )!;
        ContactInterval distance = contact_length(contact_vector_subtract(contact_vector((ContactVector)position), witness)!)!;
        if (distance.max < nearest) {
            nearest = distance.max;
            nearest_point = contact_middle(witness);
        }
        ContactVector normal = contact_middle(contact_rotate(frame, contact_vector((ContactVector)normals[triangle]))!);
        double magnitude = normal.length();
        if (!(magnitude > 0)) return cloth::CONTACT_PRECISION_EXCEEDED~;
        double signed_distance = normal.dot((ContactVector)position - contact_middle(points[first])) / magnitude;
        if (signed_distance > closest_plane) {
            closest_plane = signed_distance;
            exit_normal = normal;
        }
    }
    ContactVector normal = (ContactVector)position - nearest_point;
    ContactPlane plane;
    if (normal.dot(normal) > CONTACT_AXIS_DISTANCE * CONTACT_AXIS_DISTANCE) {
        plane = contact_support(points, normal)!;
        if (contact_separation(plane, position)!.min <= 0) normal = exit_normal;
    } else {
        normal = exit_normal;
    }
    plane = contact_support(points, normal)!;
    return contact_project_plane(
        plane: plane, position: position, reach: contact_value(thickness), tolerance: tolerance, correct: correct,
    );
}

fn bool contact_finite(Vec3 value) @private => math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
