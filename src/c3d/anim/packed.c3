module c3d::anim;

import std::math;

<*
 Largest code of a quantized track component.
*>
const float QUANTIZED_CODE_MAX = 65535;
<*
 Words of one packed rotation: the dropped component's index and three 15-bit codes.
*>
const uint ROTATION_WORDS = 3;
const uint ROTATION_BITS @local = 15;
const uint ROTATION_INDEX_SHIFT @local = 45;
const float ROTATION_CODE_MAX @local = 32767;
const float ROTATION_BOUND @local = 0.70710678f; // 1 / sqrt(2): bound of the smallest three components
const float ROTATION_STEP @local = 2 * ROTATION_BOUND / ROTATION_CODE_MAX;

<*
 Pack a rotation as smallest-three codes.
 @param [in] rotation : "Four components; normalized before packing."
 @param [out] words : "Receives three words."
 @require rotation.len == 4 && words.len == ROTATION_WORDS
*>
fn void pack_rotation(float[] rotation, ushort[] words) {
    float length = math::sqrt(rotation[0] * rotation[0] + rotation[1] * rotation[1]
      + rotation[2] * rotation[2] + rotation[3] * rotation[3]);
    uint largest;
    foreach (component, value : rotation) {
        if (math::abs(value) > math::abs(rotation[largest])) largest = (uint)component;
    }
    float sign = rotation[largest] < 0 ? -1 : 1;

    ulong bits = (ulong)largest << ROTATION_INDEX_SHIFT;
    uint shift = 2 * ROTATION_BITS;
    for (uint component = 0; component < 4; component++) {
        if (component == largest) continue;
        float scaled = (rotation[component] * sign / length + ROTATION_BOUND) / ROTATION_STEP;
        bits |= (ulong)math::clamp(math::round(scaled), 0, ROTATION_CODE_MAX) << shift;
        shift -= ROTATION_BITS;
    }
    foreach (word, &slot : words) *slot = (ushort)(bits >> (16 * word));
}

fn void unpack_rotation(ushort* words, float[] out) @local {
    ulong bits = (ulong)words[0] | (ulong)words[1] << 16 | (ulong)words[2] << 32;
    uint largest = (uint)(bits >> ROTATION_INDEX_SHIFT) & 3;
    float remaining = 1;
    uint shift = 2 * ROTATION_BITS;
    for (uint component = 0; component < 4; component++) {
        if (component == largest) continue;
        float value = (float)((bits >> shift) & (ulong)ROTATION_CODE_MAX) * ROTATION_STEP - ROTATION_BOUND;
        out[component] = value;
        remaining -= value * value;
        shift -= ROTATION_BITS;
    }
    out[largest] = math::sqrt(math::max(remaining, 0.0f));
}

<*
 Dequantized component of a packed key slot.
 @require self.is_packed() && self.path != TargetPath.ROTATION
*>
fn float Track.packed_value(&self, uint key, uint slot, uint component) {
    uint stride = self.stride();
    usz index = ((usz)key * self.slot_count() + slot) * stride + component;
    float* range = self.packed.ranges + (slot * stride + component) * 2;
    return range[0] + (float)self.packed.codes[index] * range[1];
}

fn void unpack_key(Track* track, uint key, uint slot, float[] out) @private {
    if (track.path == TargetPath.ROTATION) {
        unpack_rotation(track.packed.codes + (usz)key * ROTATION_WORDS, out);
        return;
    }
    foreach (component, &value : out[:track.stride()]) *value = track.packed_value(key, slot, (uint)component);
}
