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
