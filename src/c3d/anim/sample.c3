module c3d::anim;

import c3d::maths;
import std::math;

const float SLERP_DOT_THRESHOLD = 0.99875f; // cos(0.05 rad): keys further apart than 0.1 rad slerp, nearer ones nlerp

<*
 Slot of a cubic key's incoming tangent within its three-slot group.
*>
const uint CUBIC_SLOT_IN_TANGENT = 0;
<*
 Slot of a cubic key's value within its three-slot group.
*>
const uint CUBIC_SLOT_VALUE = 1;
<*
 Slot of a cubic key's outgoing tangent within its three-slot group.
*>
const uint CUBIC_SLOT_OUT_TANGENT = 2;
<*
 Slots one cubic key occupies: incoming tangent, value, outgoing tangent.
*>
const uint CUBIC_SLOTS_PER_KEY = 3;

<*
 Keyed values of the track at the time, clamped to the key range.
 @param [&in] track : "Times ascending; at least one key."
 @param [&inout] cursor : "Key index of the previous sample; any value on first use."
 @param [out] out : "One stride of values."
 @require track.times.len > 0, out.len == track.stride()
*>
fn void sample_track(Track* track, float time, uint* cursor, float[] out) {
    uint last = (uint)track.times.len - 1;
    if (time <= track.times[0]) {
        *cursor = 0;
        copy_key(track, 0, out);
        return;
    }
    if (time >= track.times[last]) {
        *cursor = last;
        copy_key(track, last, out);
        return;
    }
    if (*cursor >= last || time < track.times[*cursor]) {
        *cursor = seek(track.times, time);
    } else {
        while (track.times[*cursor + 1] <= time) (*cursor)++;
    }
    uint key = *cursor;
    float start = track.times[key];
    float duration = track.times[key + 1] - start;
    float fraction = (time - start) / duration;
    switch (track.interpolation) {
        case STEP: copy_key(track, key, out);
        case LINEAR: interpolate_linear(track, key, fraction, out);
        case CUBIC_SPLINE: interpolate_cubic(track, key, fraction, duration, out);
    }
}

fn uint seek(float[] times, float time) @local {
    uint low = 0;
    uint high = (uint)times.len - 1;
    while (high - low > 1) {
        uint middle = (low + high) / 2;
        if (times[middle] <= time) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return low;
}

fn float[] key_values(Track* track, uint key, uint slot) @local {
    uint stride = track.stride();
    usz offset = track.interpolation == Interpolation.CUBIC_SPLINE
      ? (usz)(key * CUBIC_SLOTS_PER_KEY + slot) * stride
      : (usz)key * stride;
    return track.values[offset:stride];
}

fn void copy_key(Track* track, uint key, float[] out) @local {
    out[..] = key_values(track, key, CUBIC_SLOT_VALUE)[..];
}

fn void interpolate_linear(Track* track, uint key, float fraction, float[] out) @local {
    float[] first = key_values(track, key, CUBIC_SLOT_VALUE);
    float[] second = key_values(track, key + 1, CUBIC_SLOT_VALUE);
    if (track.path == TargetPath.ROTATION) {
        Quat from = { .v = { first[0], first[1], first[2], first[3] } };
        Quat to = { .v = { second[0], second[1], second[2], second[3] } };
        float dot = from.v.dot(to.v);
        if (dot < 0) {
            to = -to;
            dot = -dot;
        }
        Quat result = dot > SLERP_DOT_THRESHOLD ? from.nlerp(to, fraction) : from.slerp(to, fraction);
        out[0] = result.v.x;
        out[1] = result.v.y;
        out[2] = result.v.z;
        out[3] = result.v.w;
        return;
    }
    foreach (index, &value : out) *value = first[index] + (second[index] - first[index]) * fraction;
}

fn void interpolate_cubic(Track* track, uint key, float fraction, float duration, float[] out) @local {
    float[] start_value = key_values(track, key, CUBIC_SLOT_VALUE);
    float[] start_tangent = key_values(track, key, CUBIC_SLOT_OUT_TANGENT);
    float[] end_value = key_values(track, key + 1, CUBIC_SLOT_VALUE);
    float[] end_tangent = key_values(track, key + 1, CUBIC_SLOT_IN_TANGENT);
    float squared = fraction * fraction;
    float cubed = squared * fraction;
    float h00 = 2 * cubed - 3 * squared + 1;
    float h10 = cubed - 2 * squared + fraction;
    float h01 = -2 * cubed + 3 * squared;
    float h11 = cubed - squared;
    foreach (index, &value : out) {
        *value = h00 * start_value[index] + h10 * duration * start_tangent[index]
          + h01 * end_value[index] + h11 * duration * end_tangent[index];
    }
    if (track.path == TargetPath.ROTATION) {
        Vec4 rotation = { out[0], out[1], out[2], out[3] };
        rotation = rotation.normalize();
        out[0] = rotation.x;
        out[1] = rotation.y;
        out[2] = rotation.z;
        out[3] = rotation.w;
    }
}
