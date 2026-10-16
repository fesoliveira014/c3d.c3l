module c3d::physics;

import c3d;
import c3d::maths;
import c3d::physics::cloth;
import std::math;

const uint CONTACT_SERIES_TERMS @local = 21;
const double CONTACT_SERIES_REMAINDER @local = 1e-28;
const double CONTACT_HALF_PI_UPPER @local = 1.5707963267948968;
const double CONTACT_SERIES_ARGUMENT @local = 3.2;
const double CONTACT_SMALL_ROTATION @local = 0.000001;
const uint CONTACT_ANGLE_ITERATIONS @local = 64;

struct ContactRotation @local {
    ContactInterval sine;
    ContactInterval cosine;
}

struct ContactMotion @private {
    ContactFrame first;
    ContactVector last_position;
    ContactIntervals axis;
    ContactInterval angle;
    double translation_speed;
    double angular_speed;
    bool constant_rotation;
    bool small_rotation;
}

fn ContactRotation? contact_rotation(ContactInterval angle) @local {
    if (angle.min < -CONTACT_SERIES_ARGUMENT || angle.max > CONTACT_SERIES_ARGUMENT) return cloth::CONTACT_PRECISION_EXCEEDED~;
    ContactInterval negative_square = contact_multiply(contact_square(angle)!, contact_value(-1))!;
    ContactInterval sine = angle;
    ContactInterval cosine = contact_value(1);
    ContactRotation result = { .sine = sine, .cosine = cosine };
    for (uint order = 1; order <= CONTACT_SERIES_TERMS; order++) {
        sine = contact_divide(
            numerator: contact_multiply(sine, negative_square)!,
            denominator: contact_value((double)(2 * order * (2 * order + 1))),
        )!;
        cosine = contact_divide(
            numerator: contact_multiply(cosine, negative_square)!,
            denominator: contact_value((double)((2 * order - 1) * 2 * order)),
        )!;
        result.sine = contact_add(result.sine, sine)!;
        result.cosine = contact_add(result.cosine, cosine)!;
    }
    ContactInterval remainder = { .min = -CONTACT_SERIES_REMAINDER, .max = CONTACT_SERIES_REMAINDER };
    result.sine = contact_add(result.sine, remainder)!;
    result.cosine = contact_add(result.cosine, remainder)!;
    return result;
}

fn int contact_quaternion_sign(Quat first, Quat second) @local {
    double[8] expansion;
    uint count;
    for (uint index = 0; index < 4; index++) {
        double sum = (double)first.v[index] * second.v[index];
        uint retained;
        for (uint term = 0; term < count; term++) {
            double value = expansion[term];
            double next = sum + value;
            double part = next - sum;
            double error = (sum - (next - part)) + (value - part);
            if (error != 0) expansion[retained++] = error;
            sum = next;
        }
        if (sum != 0 || !retained) expansion[retained++] = sum;
        count = retained;
    }
    double leading = expansion[count - 1];
    return leading < 0 ? -1 : leading > 0 ? 1 : 0;
}

fn ContactInterval? contact_half_angle(ContactInterval cosine) @local {
    cosine.min = math::clamp(cosine.min, 0.0, 1.0);
    cosine.max = math::clamp(cosine.max, 0.0, 1.0);
    double low;
    double high = CONTACT_HALF_PI_UPPER;
    for (uint iteration = 0; iteration < CONTACT_ANGLE_ITERATIONS; iteration++) {
        double middle = low * 0.5 + high * 0.5;
        if (middle <= low || middle >= high) break;
        ContactInterval evaluated = contact_rotation(contact_value(middle))!.cosine;
        if (evaluated.min > cosine.max) {
            low = middle;
        } else if (evaluated.max < cosine.min) {
            high = middle;
        } else {
            double derivative = contact_rotation(contact_value(low))!.sine.min;
            if (derivative > 0) {
                ContactInterval error = contact_subtract(evaluated, cosine)!;
                double radius = contact_divide(
                    numerator: contact_value(math::max(math::abs(error.min), math::abs(error.max))),
                    denominator: contact_value(derivative),
                )!.max;
                low = math::max(low, contact_subtract(contact_value(middle), contact_value(radius))!.min);
                high = math::min(high, contact_add(contact_value(middle), contact_value(radius))!.max);
            }
            break;
        }
    }
    return { .min = low, .max = high };
}

fn ContactMotion? contact_motion(maths::Transform first, maths::Transform last) @private {
    ContactMotion result = { .first = contact_frame_of(first)!, .last_position = (ContactVector)last.position };
    if (!contact_finite(last.position)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    result.translation_speed = contact_length(
        value: contact_vector_subtract(contact_vector(result.last_position), result.first.position)!,
    )!.max;
    if (first.rotation.v == last.rotation.v || first.rotation.v == -last.rotation.v) {
        result.constant_rotation = true;
        return result;
    }
    ContactInterval[4] start;
    ContactInterval[4] end;
    ContactInterval start_squared = contact_value(0);
    ContactInterval end_squared = contact_value(0);
    int sign = contact_quaternion_sign(first.rotation, last.rotation);
    for (uint index = 0; index < 4; index++) {
        if (!math::is_finite(last.rotation.v[index])) return cloth::CONTACT_PRECISION_EXCEEDED~;
        start[index] = contact_value(first.rotation.v[index]);
        end[index] = contact_value(sign < 0 ? -(double)last.rotation.v[index] : (double)last.rotation.v[index]);
        start_squared = contact_add(start_squared, contact_square(start[index])!)!;
        end_squared = contact_add(end_squared, contact_square(end[index])!)!;
    }
    ContactInterval start_length = contact_root(start_squared)!;
    ContactInterval end_length = contact_root(end_squared)!;
    for (uint index = 0; index < 4; index++) {
        start[index] = contact_divide(start[index], start_length)!;
        end[index] = contact_divide(end[index], end_length)!;
    }
    ContactInterval cosine = contact_value(0);
    for (uint index = 0; index < 4; index++) cosine = contact_add(cosine, contact_multiply(start[index], end[index])!)!;
    if (sign == 0) cosine = contact_value(0);
    result.angle = contact_multiply(contact_half_angle(cosine)!, contact_value(2))!;
    result.angular_speed = result.angle.max;
    for (uint axis = 0; axis < 3; axis++) {
        uint next = (axis + 1) % 3;
        uint last_axis = (axis + 2) % 3;
        result.axis[axis] = contact_add(
            first: contact_subtract(contact_multiply(start[3], end[axis])!, contact_multiply(start[axis], end[3])!)!,
            second: contact_subtract(
                first: contact_multiply(start[last_axis], end[next])!,
                second: contact_multiply(start[next], end[last_axis])!,
            )!,
        )!;
    }
    ContactInterval axis_length = contact_length(result.axis)!;
    if (!(axis_length.min > 0)) {
        if (result.angle.max > CONTACT_SMALL_ROTATION) return cloth::CONTACT_PRECISION_EXCEEDED~;
        result.small_rotation = true;
    } else {
        result.axis = contact_vector_scale(result.axis, contact_divide(contact_value(1), axis_length)!)!;
    }
    return result;
}

fn ContactFrame? contact_motion_frame(ContactMotion* motion, ContactInterval time) @private {
    ContactFrame result = motion.first;
    result.position = contact_vector_add(
        first: motion.first.position,
        second: contact_vector_scale(
            value: contact_vector_subtract(contact_vector(motion.last_position), motion.first.position)!,
            scale: time,
        )!,
    )!;
    if (motion.constant_rotation) return result;
    if (motion.small_rotation) {
        double extent = contact_multiply(motion.angle, time)!.max;
        ContactInterval error = { .min = -extent, .max = extent };
        foreach (&value : result.rotation) *value = contact_add(*value, error)!;
        return result;
    }
    ContactRotation rotation = contact_rotation(contact_multiply(motion.angle, time)!)!;
    ContactInterval complement = contact_subtract(contact_value(1), rotation.cosine)!;
    ContactFrame relative;
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) {
            ContactInterval value = contact_multiply(
                first: contact_multiply(motion.axis[row], motion.axis[column])!,
                second: complement,
            )!;
            if (row == column) {
                value = contact_add(value, rotation.cosine)!;
            } else {
                uint remaining = 3 - row - column;
                double sign = (row + 1) % 3 == column ? -1 : 1;
                value = contact_add(
                    first: value,
                    second: contact_multiply(
                        first: contact_multiply(motion.axis[remaining], rotation.sine)!,
                        second: contact_value(sign),
                    )!,
                )!;
            }
            relative.rotation[3 * row + column] = value;
        }
    }
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) {
            ContactInterval value = contact_value(0);
            for (uint index = 0; index < 3; index++) {
                value = contact_add(
                    first: value,
                    second: contact_multiply(
                        first: motion.first.rotation[3 * row + index],
                        second: relative.rotation[3 * index + column],
                    )!,
                )!;
            }
            result.rotation[3 * row + column] = value;
        }
    }
    return result;
}

fn ContactFrame? contact_motion_leaf(ContactMotion* motion, maths::Transform local, ContactInterval time) @private {
    ContactFrame outer = contact_motion_frame(motion, time)!;
    ContactFrame inner = contact_frame_of(local)!;
    ContactFrame result = { .position = contact_vector_add(outer.position, contact_rotate(&outer, inner.position)!)! };
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) {
            ContactInterval value = contact_value(0);
            for (uint index = 0; index < 3; index++) {
                value = contact_add(
                    first: value,
                    second: contact_multiply(outer.rotation[row * 3 + index], inner.rotation[index * 3 + column])!,
                )!;
            }
            result.rotation[row * 3 + column] = value;
        }
    }
    return result;
}

fn ContactIntervals? contact_inverse_rotate(ContactFrame* frame, ContactIntervals value) @private {
    ContactFrame inverse;
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) inverse.rotation[3 * row + column] = frame.rotation[3 * column + row];
    }
    return contact_rotate(&inverse, value);
}
