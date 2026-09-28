module ragdoll_bones;

import c3d;
import c3d::anim;
import c3d::physics;

const usz RIGIFY_BONE_COUNT = 12;

// One simulated bone of the Rigify skin; angles in radians.
struct BoneSpec @local {
    String    name;
    JointKind kind;
    float     radius;
    float     length;  // leaf bones only
    float     cone;    // SPHERICAL half angle
    float     twist;   // SPHERICAL, symmetric
    float     lower;   // REVOLUTE
    float     upper;
}

const BoneSpec[RIGIFY_BONE_COUNT] BONES @local = {
    { .name = "DEF-hips", .kind = SPHERICAL, .radius = 0.12f, .cone = 0.3f, .twist = 0.3f },
    { .name = "DEF-spine.001", .kind = SPHERICAL, .radius = 0.12f, .cone = 0.4f, .twist = 0.3f },
    { .name = "DEF-spine.003", .kind = SPHERICAL, .radius = 0.13f, .cone = 0.4f, .twist = 0.3f },
    { .name = "DEF-head", .kind = SPHERICAL, .radius = 0.1f, .length = 0.22f, .cone = 0.6f, .twist = 0.6f },
    { .name = "DEF-upper_arm.L", .kind = SPHERICAL, .radius = 0.05f, .cone = 1.4f, .twist = 0.8f },
    { .name = "DEF-forearm.L", .kind = REVOLUTE, .radius = 0.045f, .lower = 0, .upper = 2.4f },
    { .name = "DEF-upper_arm.R", .kind = SPHERICAL, .radius = 0.05f, .cone = 1.4f, .twist = 0.8f },
    { .name = "DEF-forearm.R", .kind = REVOLUTE, .radius = 0.045f, .lower = 0, .upper = 2.4f },
    { .name = "DEF-thigh.L", .kind = SPHERICAL, .radius = 0.07f, .cone = 1.0f, .twist = 0.4f },
    { .name = "DEF-shin.L", .kind = REVOLUTE, .radius = 0.055f, .lower = -2.4f, .upper = 0 },
    { .name = "DEF-thigh.R", .kind = SPHERICAL, .radius = 0.07f, .cone = 1.0f, .twist = 0.4f },
    { .name = "DEF-shin.R", .kind = REVOLUTE, .radius = 0.055f, .lower = -2.4f, .upper = 0 },
};

<*
 Ragdoll bones of the quaternius library's Rigify skin, driven toward the animated pose.
 @param [&in] skeleton : "The skin's skeleton."
 @param [out] bones : "One per Rigify bone, parents first."
 @return? NOT_FOUND
*>
fn void? rigify_bones(
    Skeleton* skeleton,
    RagdollBone[] bones,
    float drive_hertz,
    float drive_damping,
) {
    foreach (index, &spec : BONES) {
        RagdollBone bone = physics::default_ragdoll_bone(skeleton.find_joint(spec.name)!);
        bone.kind = spec.kind;
        bone.radius = spec.radius;
        bone.length = spec.length;
        bone.cone = { .enabled = true, .upper = spec.cone };
        bone.twist = { .enabled = true, .lower = -spec.twist, .upper = spec.twist };
        bone.hinge_axis = { 1, 0, 0 };
        bone.angle = { .enabled = true, .lower = spec.lower, .upper = spec.upper };
        bone.drive = { .enabled = true, .hertz = drive_hertz, .damping_ratio = drive_damping };
        bones[index] = bone;
    }
}
