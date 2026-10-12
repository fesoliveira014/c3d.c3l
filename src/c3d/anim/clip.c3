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
 Keyed values for one target property; target indexes the clip's targets list.
 Values are stride 3, 4, 3 or the morph count per key; cubic keys store in-tangent, value, out-tangent.
*>
struct Track {
    uint          target;
    TargetPath    path;
    Interpolation interpolation;
    float[]       times;
    float[]       values;
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
 Copy one slot of a key into out.
 @param [out] out : "Receives one stride of values at its start."
 @require key < self.key_count()
 @require slot == 0 || (self.interpolation == Interpolation.CUBIC_SPLINE && slot < CUBIC_SLOTS_PER_KEY)
 @require out.len >= self.stride()
*>
fn void Track.read_key(&self, uint key, uint slot, float[] out) {
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
