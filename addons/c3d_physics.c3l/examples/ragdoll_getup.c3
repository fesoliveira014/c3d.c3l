module c3d::physics::getup_fixture;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::scene;

alias Quat @local = Quaternionf;

<* Stable shared humanoid key dataset. *>
const String DATASET = "humanoid_getup_v1";

<* Number of skeleton joints, including unmapped endpoints. *>
const uint JOINT_COUNT = 20;

<* Number of mapped capsule bodies. *>
const uint BONE_COUNT = 15;

<* Duration including the final standing hold, in seconds. *>
const float DURATION = 18;

<* First standing key, in seconds. *>
const float STANDING_TIME = 12;

<* Duration of the initial recovery-source fade, in seconds. *>
const float SOURCE_FADE_TIME = 0.75f;

<* Native capsule density, in kilograms per cubic metre. *>
const float DENSITY = 200;

<* Numerical fixture penetration limit, in metres. *>
const float PENETRATION_LIMIT = 0.025f;

<* Repeated frame deltas as multiples of the world's fixed step. *>
const float[7] FRAME_MULTIPLIERS = { 0, 0.25f, 0.75f, 1, 2.5f, 0.5f, 1 };

<* Shared focused contact sequence and physical dimensions. *>
const String CONTACT_DATASET = "ragdoll_contact_v1";

<* Focused capsule length, in metres. *>
const float CONTACT_BONE_LENGTH = 0.84f;

<* Focused capsule radius, in metres. *>
const float CONTACT_BONE_RADIUS = 0.12f;

<* Focused capsule density, in kilograms per cubic metre. *>
const float CONTACT_BONE_DENSITY = 200;

<* Capsule-local centre-of-mass offset, in metres. *>
const Vec3 CONTACT_COM_OFFSET = { 0.04f, 0, 0 };

<* Initial mapped joint world position, in metres. *>
const Vec3 CONTACT_JOINT_START = { -0.8f, 0.18f, 0 };

<* Initial neighbour box world position, in metres. *>
const Vec3 CONTACT_BOX_POSITION = { 0.6f, 0.4f, 0 };

<* Neighbour box half-extents, in metres. *>
const Vec3 CONTACT_BOX_HALF_EXTENTS = { 0.2f, 0.4f, 0.2f };

<* Neighbour box density, in kilograms per cubic metre. *>
const float CONTACT_BOX_DENSITY = 100;

<* Ground box world position, in metres. *>
const Vec3 CONTACT_GROUND_POSITION = { 0, -0.5f, 0 };

<* Ground box half-extents, in metres. *>
const Vec3 CONTACT_GROUND_HALF_EXTENTS = { 10, 0.5f, 10 };

<* Focused sequence duration, in seconds. *>
const float CONTACT_DURATION = 7;

<* Minimum neighbour displacement, in metres. *>
const float CONTACT_RESPONSE_LIMIT = 0.05f;

<* Focused joint bind locals, in metres. *>
const Vec3[3] CONTACT_JOINT_POSITIONS = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };

<* Focused joint parent indices; minus one denotes the root. *>
const int[3] CONTACT_PARENTS = { -1, 0, 1 };

<* Skeleton indices, parents before children. *>
enum HumanoidJoint : uint {
    PELVIS, SPINE, HEAD, HEAD_TIP,
    LEFT_UPPER_ARM, LEFT_LOWER_ARM, LEFT_HAND, LEFT_FINGERS,
    RIGHT_UPPER_ARM, RIGHT_LOWER_ARM, RIGHT_HAND, RIGHT_FINGERS,
    LEFT_THIGH, LEFT_SHIN, LEFT_FOOT, LEFT_TOES,
    RIGHT_THIGH, RIGHT_SHIN, RIGHT_FOOT, RIGHT_TOES,
}

<* Bind-pose joint data in parent-local space, in metres. *>
struct JointSpec {
    String name;
    int parent;
    Vec3 position;
}

<* Capsule endpoint mapping and retained anatomical angular limits. *>
struct BoneSpec {
    HumanoidJoint joint;
    HumanoidJoint endpoint;
    float radius;
    JointKind kind;
    float lower;
    float upper;
    float cone;
    float twist;
}

<* Timed local quaternion keys; unlisted joint locals retain bind values. *>
struct GetupKey {
    float seconds;
    Vec3 pelvis;
    Quat[BONE_COUNT] rotations;
}

<* Borrowed scene nodes; scene and asset store own all resources. *>
struct Humanoid {
    Node* character;
    Node* skin;
    Node*[] joints;
}

<* Explicit bind data; rotations and scale are identity. *>
const JointSpec[JOINT_COUNT] JOINTS = {
    { .name = "pelvis", .parent = -1, .position = { 0, 0.91f, 0 } },
    { .name = "spine", .parent = 0, .position = { 0, 0.25f, 0 } },
    { .name = "head", .parent = 1, .position = { 0, 0.32f, 0 } },
    { .name = "head_tip", .parent = 2, .position = { 0, 0.24f, 0 } },
    { .name = "left_upper_arm", .parent = 1, .position = { -0.22f, 0.24f, 0 } },
    { .name = "left_lower_arm", .parent = 4, .position = { 0, -0.32f, 0 } },
    { .name = "left_hand", .parent = 5, .position = { 0, -0.30f, 0 } },
    { .name = "left_fingers", .parent = 6, .position = { 0, -0.13f, 0 } },
    { .name = "right_upper_arm", .parent = 1, .position = { 0.22f, 0.24f, 0 } },
    { .name = "right_lower_arm", .parent = 8, .position = { 0, -0.32f, 0 } },
    { .name = "right_hand", .parent = 9, .position = { 0, -0.30f, 0 } },
    { .name = "right_fingers", .parent = 10, .position = { 0, -0.13f, 0 } },
    { .name = "left_thigh", .parent = 0, .position = { -0.12f, 0, 0 } },
    { .name = "left_shin", .parent = 12, .position = { 0, -0.41f, 0 } },
    { .name = "left_foot", .parent = 13, .position = { 0, -0.40f, 0 } },
    { .name = "left_toes", .parent = 14, .position = { 0, 0, 0.18f } },
    { .name = "right_thigh", .parent = 0, .position = { 0.12f, 0, 0 } },
    { .name = "right_shin", .parent = 16, .position = { 0, -0.41f, 0 } },
    { .name = "right_foot", .parent = 17, .position = { 0, -0.40f, 0 } },
    { .name = "right_toes", .parent = 18, .position = { 0, 0, 0.18f } },
};

<* Capsule radii in metres and anatomical limits in radians. *>
const BoneSpec[BONE_COUNT] BONES = {
    { .joint = PELVIS, .endpoint = SPINE, .radius = 0.10f, .kind = SPHERICAL },
    { .joint = SPINE, .endpoint = HEAD, .radius = 0.105f, .kind = SPHERICAL, .cone = 1.2f, .twist = 1.0f },
    { .joint = HEAD, .endpoint = HEAD_TIP, .radius = 0.09f, .kind = SPHERICAL, .cone = 1.0f, .twist = 1.0f },
    { .joint = LEFT_UPPER_ARM, .endpoint = LEFT_LOWER_ARM, .radius = 0.045f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.2f },
    { .joint = LEFT_LOWER_ARM, .endpoint = LEFT_HAND, .radius = 0.04f, .kind = REVOLUTE, .lower = 0, .upper = 2.6f },
    { .joint = LEFT_HAND, .endpoint = LEFT_FINGERS, .radius = 0.035f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.0f },
    { .joint = RIGHT_UPPER_ARM, .endpoint = RIGHT_LOWER_ARM, .radius = 0.045f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.2f },
    { .joint = RIGHT_LOWER_ARM, .endpoint = RIGHT_HAND, .radius = 0.04f, .kind = REVOLUTE, .lower = 0, .upper = 2.6f },
    { .joint = RIGHT_HAND, .endpoint = RIGHT_FINGERS, .radius = 0.035f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.0f },
    { .joint = LEFT_THIGH, .endpoint = LEFT_SHIN, .radius = 0.065f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.2f },
    { .joint = LEFT_SHIN, .endpoint = LEFT_FOOT, .radius = 0.05f, .kind = REVOLUTE, .lower = 0, .upper = 2.6f },
    { .joint = LEFT_FOOT, .endpoint = LEFT_TOES, .radius = 0.045f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.0f },
    { .joint = RIGHT_THIGH, .endpoint = RIGHT_SHIN, .radius = 0.065f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.2f },
    { .joint = RIGHT_SHIN, .endpoint = RIGHT_FOOT, .radius = 0.05f, .kind = REVOLUTE, .lower = 0, .upper = 2.6f },
    { .joint = RIGHT_FOOT, .endpoint = RIGHT_TOES, .radius = 0.045f, .kind = SPHERICAL, .cone = 2.8f, .twist = 1.0f },
};

<* Supine, seated support, roll, kneel, half-kneel, and standing. *>
const GetupKey[12] SUPINE_KEYS = {
    { .seconds = 0f, .pelvis = { 0.000000000f, 0.110000000f, 0.000000000f }, .rotations = {
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
    { .seconds = 1f, .pelvis = { 0.000000000f, 0.400000000f, 0.000000000f }, .rotations = {
        { .v = { -0.382683432f, 0.000000000f, 0.000000000f, 0.923879532f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.043619387f, 0.000000000f, 0.000000000f, 0.999048222f } },
        { .v = { 0.237685892f, 0.000000000f, 0.000000000f, 0.971342070f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.043619387f, 0.000000000f, 0.000000000f, 0.999048222f } },
        { .v = { 0.237685892f, 0.000000000f, 0.000000000f, 0.971342070f } },
        { .v = { -0.382683432f, 0.000000000f, 0.000000000f, 0.923879532f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.382683432f, 0.000000000f, 0.000000000f, 0.923879532f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
    { .seconds = 1.5f, .pelvis = { 0.000000000f, 0.310000000f, 0.000000000f }, .rotations = {
        { .v = { -0.195090322f, 0.000000000f, 0.000000000f, 0.980785280f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.162895474f, 0.000000000f, 0.000000000f, 0.986643332f } },
        { .v = { 0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.352250048f, 0.000000000f, 0.000000000f, 0.935905927f } },
        { .v = { 0.162895474f, 0.000000000f, 0.000000000f, 0.986643332f } },
        { .v = { 0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.352250048f, 0.000000000f, 0.000000000f, 0.935905927f } },
        { .v = { -0.555570233f, 0.000000000f, 0.000000000f, 0.831469612f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.555570233f, 0.000000000f, 0.000000000f, 0.831469612f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
    { .seconds = 2f, .pelvis = { 0.000000000f, 0.090000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.087155743f, 0.000000000f, 0.000000000f, 0.996194698f } },
        { .v = { 0.461748613f, 0.000000000f, 0.000000000f, 0.887010833f } },
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.087155743f, 0.000000000f, 0.000000000f, 0.996194698f } },
        { .v = { 0.461748613f, 0.000000000f, 0.000000000f, 0.887010833f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
    { .seconds = 3f, .pelvis = { 0.000000000f, 0.590000000f, 0.000000000f }, .rotations = {
        { .v = { -0.043338832f, -0.005705665f, 0.065216055f, 0.996913265f } },
        { .v = { 0.043619387f, 0.000000000f, 0.000000000f, 0.999048222f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.152123386f, 0.000000000f, 0.000000000f, 0.988361510f } },
        { .v = { 0.195090322f, 0.000000000f, 0.000000000f, 0.980785280f } },
        { .v = { 0.422618261f, 0.000000000f, 0.000000000f, 0.906307787f } },
        { .v = { 0.021814885f, 0.000000000f, 0.000000000f, 0.999762027f } },
        { .v = { 0.300705800f, 0.000000000f, 0.000000000f, 0.953716951f } },
        { .v = { 0.442288690f, 0.000000000f, 0.000000000f, 0.896872741f } },
        { .v = { -0.573576436f, -0.000000000f, 0.000000000f, 0.819152044f } },
        { .v = { 0.461748613f, 0.000000000f, 0.000000000f, 0.887010833f } },
        { .v = { -0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { -0.675590208f, -0.000000000f, 0.000000000f, 0.737277337f } },
        { .v = { 0.537299608f, 0.000000000f, 0.000000000f, 0.843391446f } },
        { .v = { -0.173648177f, 0.000000000f, 0.000000000f, 0.984807753f } },
    } },
    { .seconds = 4f, .pelvis = { 0.000000000f, 0.650000000f, 0.000000000f }, .rotations = {
        { .v = { -0.086410113f, -0.011376107f, 0.130029501f, 0.987672114f } },
        { .v = { 0.087155743f, 0.000000000f, 0.000000000f, 0.996194698f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.087155743f, 0.000000000f, 0.000000000f, 0.996194698f } },
        { .v = { 0.300705800f, 0.000000000f, 0.000000000f, 0.953716951f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879533f } },
        { .v = { -0.173648178f, -0.000000000f, 0.000000000f, 0.984807753f } },
        { .v = { 0.500000000f, 0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.422618262f, 0.000000000f, 0.000000000f, 0.906307787f } },
        { .v = { -0.422618262f, -0.000000000f, 0.000000000f, 0.906307787f } },
        { .v = { 0.819152044f, 0.000000000f, 0.000000000f, 0.573576436f } },
        { .v = { -0.422618262f, -0.000000000f, 0.000000000f, 0.906307787f } },
        { .v = { -0.642787610f, -0.000000000f, 0.000000000f, 0.766044443f } },
        { .v = { 0.906307787f, 0.000000000f, 0.000000000f, 0.422618262f } },
        { .v = { -0.342020143f, -0.000000000f, 0.000000000f, 0.939692621f } },
    } },
    { .seconds = 6f, .pelvis = { 0.000000000f, 0.480000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
    } },
    { .seconds = 7.5f, .pelvis = { 0.000000000f, 0.650000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.500000000f, -0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.659345815f, 0.000000000f, 0.000000000f, 0.751839807f } },
        { .v = { -0.659345815f, -0.000000000f, 0.000000000f, 0.751839807f } },
    } },
    { .seconds = 9f, .pelvis = { 0.000000000f, 0.620000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.130526192f, -0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.130526192f, -0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.500000000f, -0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.258819045f, -0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.608761429f, 0.000000000f, 0.000000000f, 0.793353340f } },
        { .v = { -0.608761429f, -0.000000000f, 0.000000000f, 0.793353340f } },
    } },
    { .seconds = 10.5f, .pelvis = { 0.000000000f, 0.820000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879532f } },
        { .v = { -0.130526192f, 0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.321439465f, 0.000000000f, 0.000000000f, 0.946930129f } },
        { .v = { -0.321439465f, 0.000000000f, 0.000000000f, 0.946930129f } },
    } },
    { .seconds = 12f, .pelvis = { 0.000000000f, 0.910000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
    { .seconds = 18f, .pelvis = { 0.000000000f, 0.910000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
};

<* Prone, hand-supported rise, tucked knees, kneel, half-kneel, and standing. *>
const GetupKey[10] PRONE_KEYS = {
    { .seconds = 0f, .pelvis = { 0.000000000f, 0.110000000f, 0.000000000f }, .rotations = {
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
    } },
    { .seconds = 1f, .pelvis = { 0.000000000f, 0.345000000f, 0.000000000f }, .rotations = {
        { .v = { 0.608761429f, 0.000000000f, 0.000000000f, 0.793353340f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { -0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.130526192f, 0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { -0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.130526192f, 0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.321439465f, 0.000000000f, 0.000000000f, 0.946930129f } },
        { .v = { -0.195090322f, 0.000000000f, 0.000000000f, 0.980785280f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.321439465f, 0.000000000f, 0.000000000f, 0.946930129f } },
        { .v = { -0.195090322f, 0.000000000f, 0.000000000f, 0.980785280f } },
    } },
    { .seconds = 2f, .pelvis = { 0.000000000f, 0.380000000f, 0.000000000f }, .rotations = {
        { .v = { 0.500000000f, 0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.130526192f, -0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { -0.500000000f, -0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.500000000f, 0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { -0.500000000f, -0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.500000000f, 0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.608761429f, 0.000000000f, 0.000000000f, 0.793353340f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879533f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.608761429f, 0.000000000f, 0.000000000f, 0.793353340f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879533f } },
    } },
    { .seconds = 4f, .pelvis = { 0.000000000f, 0.460000000f, 0.000000000f }, .rotations = {
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.087155743f, -0.000000000f, 0.000000000f, 0.996194698f } },
        { .v = { -0.258819045f, -0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879533f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.258819045f, -0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879533f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.537299608f, 0.000000000f, 0.000000000f, 0.843391446f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.537299608f, 0.000000000f, 0.000000000f, 0.843391446f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
    } },
    { .seconds = 6f, .pelvis = { 0.000000000f, 0.480000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.707106781f, -0.000000000f, 0.000000000f, 0.707106781f } },
    } },
    { .seconds = 7.5f, .pelvis = { 0.000000000f, 0.650000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.500000000f, -0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.659345815f, 0.000000000f, 0.000000000f, 0.751839807f } },
        { .v = { -0.659345815f, -0.000000000f, 0.000000000f, 0.751839807f } },
    } },
    { .seconds = 9f, .pelvis = { 0.000000000f, 0.620000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.130526192f, -0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.130526192f, -0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.216439614f, 0.000000000f, 0.000000000f, 0.976296007f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.500000000f, -0.000000000f, 0.000000000f, 0.866025404f } },
        { .v = { 0.707106781f, 0.000000000f, 0.000000000f, 0.707106781f } },
        { .v = { -0.258819045f, -0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.608761429f, 0.000000000f, 0.000000000f, 0.793353340f } },
        { .v = { -0.608761429f, -0.000000000f, 0.000000000f, 0.793353340f } },
    } },
    { .seconds = 10.5f, .pelvis = { 0.000000000f, 0.820000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.065403129f, 0.000000000f, 0.000000000f, 0.997858923f } },
        { .v = { 0.108866875f, 0.000000000f, 0.000000000f, 0.994056338f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { -0.258819045f, 0.000000000f, 0.000000000f, 0.965925826f } },
        { .v = { 0.382683432f, 0.000000000f, 0.000000000f, 0.923879532f } },
        { .v = { -0.130526192f, 0.000000000f, 0.000000000f, 0.991444861f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.321439465f, 0.000000000f, 0.000000000f, 0.946930129f } },
        { .v = { -0.321439465f, 0.000000000f, 0.000000000f, 0.946930129f } },
    } },
    { .seconds = 12f, .pelvis = { 0.000000000f, 0.910000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
    { .seconds = 18f, .pelvis = { 0.000000000f, 0.910000000f, 0.000000000f }, .rotations = {
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
        { .v = { 0.000000000f, 0.000000000f, 0.000000000f, 1.000000000f } },
    } },
};

<*
 Sample shared local keys, clamping outside the authored interval.
 @param [&inout] humanoid : "Joint locals receive the fresh authored target."
*>
fn void sample_getup(Humanoid* humanoid, RagdollFacing facing, float seconds) {
    GetupKey[] keys = facing == FACE_UP ? SUPINE_KEYS[..] : PRONE_KEYS[..];
    usz first;
    while (first + 2 < keys.len && seconds > keys[first + 1].seconds) first++;
    GetupKey* before = &keys[first];
    GetupKey* after = &keys[first + 1];
    float fraction = math::clamp((seconds - before.seconds) / (after.seconds - before.seconds), 0.0f, 1.0f);

    sample_standing(humanoid);
    humanoid.joints[HumanoidJoint.PELVIS.ordinal].local.position =
      before.pelvis * (1 - fraction) + after.pelvis * fraction;
    foreach (index, spec : BONES) {
        humanoid.joints[spec.joint.ordinal].local.rotation =
          before.rotations[index].slerp(after.rotations[index], fraction);
    }
}

<*
 Restore every joint's authored bind local.
 @param [&inout] humanoid : "Joint locals receive the standing target."
*>
fn void sample_standing(Humanoid* humanoid) {
    foreach (index, spec : JOINTS) {
        humanoid.joints[index].local = maths::TRANSFORM_IDENTITY;
        humanoid.joints[index].local.position = spec.position;
    }
}

<*
 Build the shared skinned rig and its initially animated ragdoll.
 @param [&inout] assets : "Owns generated geometry, material, and skeleton."
 @param [&inout] scene : "Owns the returned nodes and physics authoring."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, physics::NO_SKIN, physics::RAGDOLL_EXISTS
*>
fn Humanoid? create_humanoid(AssetStore* assets, Scene* scene) {
    Skeleton skeleton = {
        .joint_names = alloc::new_array(assets.allocator, String, JOINT_COUNT),
        .parents = alloc::new_array(assets.allocator, int, JOINT_COUNT),
        .rest_pose = alloc::new_array(assets.allocator, Transform, JOINT_COUNT),
        .inverse_bind = alloc::new_array(assets.allocator, Mat4, JOINT_COUNT),
    };
    defer catch asset::free_skeleton(assets.allocator, &skeleton);

    Vec3[JOINT_COUNT] bind_positions;
    foreach (index, spec : JOINTS) {
        skeleton.joint_names[index] = (String)alloc::new_array(assets.allocator, char, spec.name.len);
        skeleton.joint_names[index][..] = spec.name[..];
        skeleton.parents[index] = spec.parent;
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
        skeleton.rest_pose[index].position = spec.position;
        bind_positions[index] = spec.position;
        if (spec.parent >= 0) bind_positions[index] += bind_positions[spec.parent];
        Transform inverse_bind = maths::TRANSFORM_IDENTITY;
        inverse_bind.position = -bind_positions[index];
        skeleton.inverse_bind[index] = inverse_bind.to_mat4();
    }

    SkeletonId skeleton_id = assets.add_skeleton_owned(&skeleton)!;
    skeleton = {};

    GeometryId geometry;
    @pool() {
        Geometry[BONE_COUNT] parts;
        foreach (index, spec : BONES) {
            Vec3 start = bind_positions[spec.joint.ordinal];
            Vec3 end = bind_positions[spec.endpoint.ordinal];
            float length = (end - start).length();
            parts[index] = geometry::capsule(
                allocator: tmem,
                radius: spec.radius,
                height: math::max(length - 2 * spec.radius, 0.0f),
                slices: 12,
                stacks: 4,
            );
            Transform placement = {
                .position = (start + end) * 0.5f,
                .rotation = maths::rotation_between({ 0, 1, 0 }, (end - start).normalize()),
                .scale = { 1, 1, 1 },
            };
            parts[index].transform(placement.to_mat4());
        }

        Geometry merged = geometry::merge(tmem, parts[..]);
        merged.joints = alloc::new_array(tmem, ushort[<4>], merged.positions.len);
        merged.weights = alloc::new_array(tmem, Vec4, merged.positions.len);

        usz vertex;
        foreach (index, part : parts) {
            for (usz part_vertex = 0; part_vertex < part.positions.len; part_vertex++) {
                merged.joints[vertex] = { (ushort)BONES[index].joint.ordinal, 0, 0, 0 };
                merged.weights[vertex++] = { 1, 0, 0, 0 };
            }
        }

        geometry = assets.add_geometry(&merged)!;
    };

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.16f, 0.55f, 0.8f, 1 };
    params.roughness = 0.7f;
    MaterialId material_id = assets.add_material(material::standard(params))!;

    Humanoid humanoid = { .character = scene.add_node(name: "humanoid")! };
    defer catch scene.remove(humanoid.character);
    humanoid.skin = scene.add_mesh(
        geometry: geometry,
        material: material_id,
        parent: humanoid.character,
        name: "humanoid_skin",
    )!;
    humanoid.joints = alloc::new_array(scene.allocator, Node*, JOINT_COUNT);
    scene.add(humanoid.skin, (SkinBinding){ .skeleton = skeleton_id, .joints = humanoid.joints });
    foreach (index, spec : JOINTS) {
        Node* parent = spec.parent < 0 ? humanoid.character : humanoid.joints[spec.parent];
        humanoid.joints[index] = scene.add_node(parent, spec.name)!;
    }
    sample_standing(&humanoid);
    scene.update_world();

    RagdollBone[BONE_COUNT] bones;
    foreach (index, spec : BONES) {
        bones[index] = physics::default_ragdoll_bone(spec.joint.ordinal);
        bones[index].radius = spec.radius;
        bones[index].density = DENSITY;
        bones[index].kind = spec.kind;
        bones[index].hinge_axis = { 1, 0, 0 };
        bones[index].angle = { .enabled = true, .lower = spec.lower, .upper = spec.upper };
        bones[index].cone = { .enabled = true, .upper = spec.cone };
        bones[index].twist = { .enabled = true, .lower = -spec.twist, .upper = spec.twist };
        bones[index].drive = { .enabled = true, .hertz = 4, .damping_ratio = 1 };
    }

    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    desc.filter.group = -1;
    scene.build_ragdoll(assets, humanoid.skin, desc)!;

    return humanoid;
}

<* The focused capsule advances two metres, holds, retreats, then settles. *>
fn Transform sample_contact_target(float seconds, bool rotate = false) {
    float reach = math::min(seconds / 2, 1.0f);
    if (seconds > 4) reach = math::max(1 - (seconds - 4), 0.0f);
    float angle = rotate ? 20 * reach * (float)math::PI / 180 : 0;

    return {
        .position = CONTACT_JOINT_START + (Vec3){ 2 * reach, 0, 0 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, angle),
        .scale = { 1, 1, 1 },
    };
}