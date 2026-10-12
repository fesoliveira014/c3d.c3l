module c3d::anim;

import c3d::maths;
import std::math;

<* Model-local index meaning no root joint. *>
const uint NO_ROOT_NODE = uint::max;

<* Keep, pin or extract horizontal root motion. *>
enum RootMotion {
    KEEP,
    STRIP_XZ,
    EXTRACT,
}

<*
 Node property a track animates.
*>
enum TargetPath {
    TRANSLATION,
    ROTATION,
    SCALE,
    MORPH_WEIGHTS,
}

<*
 Key interpolation of a track.
*>
enum Interpolation {
    STEP,
    LINEAR,
    CUBIC_SPLINE,
}

<*
 Storage form of a track's keys.
*>
enum TrackEncoding : char {
    RAW,
    PACKED,
}

<*
 Quantized keys of a packed track, stored in the block of the clip.
*>
struct PackedValues {
    ushort* codes;
    float*  ranges; // minimum and step per slot and component; rotations have none
}

<*
 Keyed values for one target property; target indexes the clip's targets list.
 Raw values are stride 3, 4, 3 or the morph count per key; cubic keys store in-tangent, value, out-tangent.
 Read packed tracks through the key accessors only.
*>
struct Track {
    uint          target;
    TargetPath    path;
    Interpolation interpolation;
    TrackEncoding encoding;
    ushort        packed_stride; // morph weights per key when packed
    float[]       times;
    union {
        float[]      values;
        PackedValues packed;
    }
}

<* Authored clip instant with application-defined meaning. *>
struct ClipEvent {
    float time;
    uint id;
}

<* Clip over model-local nodes, with time-ordered events. *>
struct AnimationClip {
    String  name;
    float   duration;
    Track[] tracks;
    uint[]  targets;
    ClipEvent[] events;
    float[] packed_keys;
}

<*
 Joint hierarchy, rest pose and inverse-bind matrices shared by skins.
*>
struct Skeleton {
    String[]    joint_names;
    int[]       parents;
    Transform[] rest_pose;
    Mat4[]      inverse_bind;
}

<*
 Number of values one key of the track holds.
 @pure
*>
fn uint Track.stride(&self) {
    switch (self.path) {
        case TRANSLATION:
        case SCALE:
            return 3;
        case ROTATION:
            return 4;
        case MORPH_WEIGHTS:
            if (self.encoding == TrackEncoding.PACKED) return self.packed_stride;
            uint per_key = (uint)(self.values.len / self.times.len);
            return self.interpolation == Interpolation.CUBIC_SPLINE ? per_key / 3 : per_key;
    }
}

<*
 Number of keys the track holds.
 @pure
*>
fn uint Track.key_count(&self) {
    return (uint)self.times.len;
}

<*
 Time of the key in seconds.
 @require key < self.key_count()
 @pure
*>
fn float Track.key_time(&self, uint key) {
    return self.times[key];
}

<*
 Slot of a key that holds its value.
 @pure
*>
fn uint Track.value_slot(&self) {
    return self.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOT_VALUE : 0;
}

<*
 Number of slots each key occupies.
 @pure
*>
fn uint Track.slot_count(&self) {
    return self.interpolation == Interpolation.CUBIC_SPLINE ? CUBIC_SLOTS_PER_KEY : 1;
}

<*
 Whether the keys are quantized.
 @pure
*>
fn bool Track.is_packed(&self) {
    return self.encoding == TrackEncoding.PACKED;
}

<*
 Whether any track of the clip is quantized.
 @pure
*>
fn bool AnimationClip.is_compressed(&self) {
    return self.packed_keys.len != 0;
}

<*
 Copy one slot of a key into out.
 @param [out] out : "Receives one stride of values at its start."
 @require key < self.key_count()
 @require slot == 0 || (self.interpolation == Interpolation.CUBIC_SPLINE && slot < CUBIC_SLOTS_PER_KEY)
 @require out.len >= self.stride()
*>
fn void Track.read_key(&self, uint key, uint slot, float[] out) {
    if (self.encoding == TrackEncoding.PACKED) {
        unpack_key(self, key, slot, out);
        return;
    }
    float[] stored = key_values(self, key, slot);
    out[:stored.len] = stored[..];
}

<*
 Skeleton joint index of the name.
 @return? NOT_FOUND
 @pure
*>
fn uint? Skeleton.find_joint(&self, String name) {
    foreach (index, joint_name : self.joint_names) {
        if (joint_name == name) return (uint)index;
    }
    return NOT_FOUND~;
}
