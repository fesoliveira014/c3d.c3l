module c3d::anim;

import c3d::maths;
import std::math;

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

<*
 Clip over model-local node indices.
*>
struct AnimationClip {
    String  name;
    float   duration;
    Track[] tracks;
    uint[]  targets;
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
