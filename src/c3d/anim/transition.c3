module c3d::anim;

import c3d;
import std::math;

<* Full-weight looping destination action at its first sample. *>
const AnimationTargetDesc ANIMATION_TARGET_DEFAULT = {
    .speed = 1,
    .weight = 1,
    .loop = true,
    .playing = true,
};

<* Captured translation axes and twist in the instance-root frame. *>
struct RootExtractionDesc {
    bool generalized;
    bool[3] translation_axes;
    Vec3 up;
    bool twist;
}

<* Fixed animation storage selected when an owner is prepared. *>
struct AnimatorDesc {
    bool inertia_enabled;
}

<* One copied destination action of an inertial request. *>
struct AnimationTargetDesc {
    ClipId clip;
    PlayDesc play;
    float start_time;
    float speed;
    float weight;
    bool loop;
    bool playing;
}

<* Replacement actions and groups corrected over update seconds. *>
struct AnimationTransitionDesc {
    float duration;
    AnimationTargetDesc[] actions;
    CrowdSpaceAuthoring[] spaces;
}
