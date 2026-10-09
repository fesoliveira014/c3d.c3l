module retarget_example;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::core::string;
import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

alias ReferenceVec3 @local = double[<3>];
alias ReferenceQuat @local = double[<4>];

const uint FIXTURE_VERSION @local = 2;
const uint FIXTURE_NODES @local = 8;
const uint FIXTURE_TRACKS @local = 8;
const uint FIXTURE_FAMILIES @local = 6;
const uint FIXTURE_ROWS @local = 8;
const uint FIXTURE_SCENE_NODES @local = 2048;
const float PLAYBACK_SECONDS @local = 20;
const float FAMILY_SECONDS @local = 6;
const float TURN_FAMILY_SECONDS @local = 8;
const float PLAYBACK_CYCLE_SECONDS @local = FAMILY_SECONDS * 4 + TURN_FAMILY_SECONDS * 2;
const float BAKE_RATE @local = 60;
const float SAMPLE_STEP @local = 1.0f / 240;
const double KEY_POSITION_BOUND @local = 0.00001;
const double KEY_ROTATION_BOUND @local = 0.0001;
const double KEY_SCALE_BOUND @local = 0.00001;
const double SUBKEY_POSITION_BOUND @local = 0.0005;
const double SUBKEY_ROTATION_BOUND @local = 0.25 * math::PI / 180;
const double ACCUMULATED_POSITION_BOUND @local = 0.0005;
const float KEY_RECOGNITION_TOLERANCE @local = 0.0005f;
const float CAPTURE_INTERVAL @local = 2;
const uint CAPTURE_WIDTH @local = 960;
const uint CAPTURE_HEIGHT @local = 540;
const uint REFERENCE_COLOR @local = 0xFF66DD44;
const uint PROFILE_COLOR @local = 0xFF33BBFF;
const Vec3 DISPLAY_SPACING @local = { 3, 0, 0 };
const Vec3 WORLD_UP @local = { 0, 1, 0 };

const ZString[FIXTURE_FAMILIES] FAMILY_NAMES @local = {
    "T/A calibration", "Facing alignment", "Animated ancestors", "Carrier modes",
    "90 degree walking turn", "360 degree walking turn",
};

const float INSTANCE_SPACING @local = 0.8f; // metres between the two characters and the origin
const float LIGHT_INTENSITY @local = 3;
const Vec3  CAMERA_POSITION @local = { 0, 1.2f, 4.5f };
const Vec3  CAMERA_TARGET @local = { 0, 0.9f, 0 };
const String SOURCE_CHARACTER @local = "../assets/mixamo/eve_j_gonzales.fbx";
const String SOURCE_WALK @local = "../assets/mixamo/walk.fbx";
const String TARGET_CHARACTER @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String SOURCE_HIPS @local = "Hips";
const String TARGET_HIPS @local = "DEF-hips";
const String TARGET_ROOT @local = "root";

const NameMapping[] BODY_MAP @local = {
    { .source = "Hips",          .target = "DEF-hips" },
    { .source = "Spine",         .target = "DEF-spine.001" },
    { .source = "Spine1",        .target = "DEF-spine.002" },
    { .source = "Spine2",        .target = "DEF-spine.003" },
    { .source = "Neck",          .target = "DEF-neck" },
    { .source = "Head",          .target = "DEF-head" },
    { .source = "LeftShoulder",  .target = "DEF-shoulder.L" },
    { .source = "LeftArm",       .target = "DEF-upper_arm.L" },
    { .source = "LeftForeArm",   .target = "DEF-forearm.L" },
    { .source = "LeftHand",      .target = "DEF-hand.L" },
    { .source = "RightShoulder", .target = "DEF-shoulder.R" },
    { .source = "RightArm",      .target = "DEF-upper_arm.R" },
    { .source = "RightForeArm",  .target = "DEF-forearm.R" },
    { .source = "RightHand",     .target = "DEF-hand.R" },
    { .source = "LeftUpLeg",     .target = "DEF-thigh.L" },
    { .source = "LeftLeg",       .target = "DEF-shin.L" },
    { .source = "LeftFoot",      .target = "DEF-foot.L" },
    { .source = "LeftToeBase",   .target = "DEF-toe.L" },
    { .source = "RightUpLeg",    .target = "DEF-thigh.R" },
    { .source = "RightLeg",      .target = "DEF-shin.R" },
    { .source = "RightFoot",     .target = "DEF-foot.R" },
    { .source = "RightToeBase",  .target = "DEF-toe.R" },
};

enum FixtureKind @local {
    ANATOMY,
    FACING,
    ANCESTOR,
    CARRIER,
    TURN90,
    TURN360,
}

struct ReferencePose @local {
    ReferenceVec3 position;
    ReferenceQuat rotation;
    double scale;
}

struct Fixture @local {
    FixtureKind kind;
    uint variant;
    float facing_yaw;
    uint source_count;
    uint target_count;
    uint mapping_count;
    uint track_count;
    uint key_count;
    uint source_motion;
    uint target_motion;
    uint carrier;
    NodeTemplate[FIXTURE_NODES] source_nodes;
    NodeTemplate[FIXTURE_NODES] target_nodes;
    Quat[FIXTURE_NODES] source_calibration;
    Quat[FIXTURE_NODES] target_calibration;
    NodeIndexMapping[FIXTURE_NODES] mapping;
    uint[FIXTURE_NODES] targets;
    float[5] times;
    float[20][FIXTURE_TRACKS] values;
    Track[FIXTURE_TRACKS] tracks;
    ModelMesh mesh_role;
    ModelTemplate target;
    AnimationClip source;
}

struct RigView @local {
    Node* display;
    Node* root;
    Node*[FIXTURE_NODES] nodes;
    Node*[FIXTURE_NODES] glyphs;
    Node*[FIXTURE_NODES] bones;
    AnimationActionId action;
    RootMotion mode;
}

struct FixtureRow @local {
    Fixture fixture;
    RootMotion mode;
    RigView reference;
    RigView actual;
    double position_error;
    double rotation_error;
    double scale_error;
    double root_error;
    double root_rotation_error;
    double pivot_error;
    double root_radius;
    double pivot_radius;
    bool root_yaw;
    bool looping;
    float playback_speed;
    double loop_travel;
    long cycles;
}

struct FixtureFamily @local {
    FixtureKind kind;
    uint count;
    FixtureRow[FIXTURE_ROWS] rows;
}

struct Controls @local {
    uint family;
    bool automatic;
    bool paused;
    bool lines;
}

struct Metrics @local {
    ulong key_samples;
    ulong subkey_samples;
    ulong failures;
    double max_key_position;
    double max_key_rotation;
    double max_key_scale;
    double max_subkey_position;
    double max_subkey_rotation;
    double max_root_error;
    double max_root_rotation;
    double max_pivot_error;
    double max_root_radius;
    double max_pivot_radius;
    ulong carrier_key_samples;
    ulong carrier_subkey_samples;
    double max_carrier_key_position;
    double max_carrier_key_rotation;
    double max_carrier_key_scale;
    double max_carrier_subkey_position;
    double max_carrier_subkey_rotation;
    double max_carrier_subkey_scale;
    bool[FIXTURE_FAMILIES] families_seen;
    bool[3] modes_seen;
    bool[2][2] turn_yaw_seen;
    bool[2] turn_reverse_seen;
    bool[2] turn_loop_seen;
    bool[2] turn_reverse_loop_seen;
}

struct Showcase @local {
    Node*  source;
    Node*  target;
    ClipId source_clip;
    ClipId corrected_clip;
    ClipId copied_clip;
    bool   corrected;
    bool   resting;
}

fn Quat fixture_turn(Vec3 axis, float degrees) @local {
    return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180);
}

fn Transform fixture_transform(
    Vec3 position = {},
    Quat rotation = quaternion::IDENTITY,
    float scale = 1,
) @local {
    return { .position = position, .rotation = rotation, .scale = { scale, scale, scale } };
}

fn void fixture_initialize(Fixture* fixture, FixtureKind kind, uint variant) @local {
    *fixture = {
        .kind = kind,
        .variant = variant,
        .source_motion = retarget::RETARGET_NO_NODE,
        .target_motion = retarget::RETARGET_NO_NODE,
        .carrier = retarget::RETARGET_NO_NODE,
        .key_count = 2,
    };
    fixture.times[1] = 1;

    foreach (index, &node : fixture.source_nodes) {
        *node = {
            .parent = -1, .name = "joint", .local = maths::TRANSFORM_IDENTITY,
            .layers = scene::DEFAULT_LAYERS, .visible = true,
        };
        fixture.source_calibration[index] = quaternion::IDENTITY;
        fixture.targets[index] = (uint)index;
    }

    foreach (index, &node : fixture.target_nodes) {
        *node = {
            .parent = -1, .name = "joint", .local = maths::TRANSFORM_IDENTITY,
            .layers = scene::DEFAULT_LAYERS, .visible = true,
        };
        fixture.target_calibration[index] = quaternion::IDENTITY;
    }
}

fn void fixture_track(
    Fixture* fixture,
    uint node,
    TargetPath path,
    float[] values,
) @local {
    uint index = fixture.track_count++;
    fixture.values[index][:values.len] = values[..];
    fixture.tracks[index] = {
        .target = node,
        .path = path,
        .interpolation = Interpolation.LINEAR,
        .times = fixture.times[:fixture.key_count],
        .values = fixture.values[index][:values.len],
    };
}

fn void fixture_rotation(
    Fixture* fixture,
    uint node,
    Quat start,
    Quat end,
) @local {
    float[8] values = {
        start.v.x, start.v.y, start.v.z, start.v.w,
        end.v.x, end.v.y, end.v.z, end.v.w,
    };
    fixture_track(
        fixture: fixture,
        node: node,
        path: TargetPath.ROTATION,
        values: values[..],
    );
}

fn void fixture_authored(Fixture* fixture, FixtureKind kind, uint variant) @local {
    fixture_initialize(fixture, kind, variant);

    switch (kind) {
        case ANATOMY:
            fixture.source_count = 3;
            fixture.target_count = 3;
            fixture.source_nodes[1].parent = 0;
            fixture.source_nodes[1].local = fixture_transform(
                { 1, 0, 0 }, fixture_turn({ 0, 0, 1 }, variant == 0 ? 0 : -45));
            fixture.source_nodes[2].parent = 1;
            fixture.source_nodes[2].local.position = { 1, 0, 0 };
            fixture.target_nodes[1].parent = 0;
            fixture.target_nodes[1].local = fixture_transform(
                { 2, 0, 0 }, fixture_turn({ 0, 0, 1 }, variant == 0 ? -45 : 0));
            fixture.target_nodes[2].parent = 1;
            fixture.target_nodes[2].local.position = { 2, 0, 0 };
            fixture.mapping[0] = { .source_node = 0, .target_node = 0 };
            fixture.mapping[1] = { .source_node = 1, .target_node = 1 };
            fixture.mapping_count = 2;
            fixture_rotation(
                fixture: fixture,
                node: 1,
                start: quaternion::IDENTITY,
                end: fixture_turn({ 0, 0, 1 }, 30),
            );

        case FACING:
            fixture.source_count = 2;
            fixture.target_count = 2;
            float[4] yaws = { 0, 90, 180, 37 };
            fixture.facing_yaw = yaws[variant];
            fixture.source_nodes[0].local.rotation = fixture_turn(WORLD_UP, 20);
            fixture.source_nodes[1].parent = 0;
            fixture.source_nodes[1].local.rotation = fixture_turn({ 0, 0, 1 }, -10);
            fixture.target_nodes[0].local.rotation = fixture_turn(WORLD_UP, 90);
            fixture.target_nodes[1].parent = 0;
            fixture.target_nodes[1].local.rotation = fixture_turn({ 0, 0, 1 }, 10);
            fixture.source_calibration[0] = fixture.source_nodes[0].local.rotation;
            fixture.source_calibration[1] = fixture_turn({ 0, 0, 1 }, 45);
            fixture.target_calibration[0] = fixture_turn({ 1, 0, 0 }, 80);
            fixture.target_calibration[1] = fixture_turn({ 0, 0, 1 }, -45);
            fixture.mapping[0] = { .source_node = 1, .target_node = 1 };
            fixture.mapping_count = 1;
            Quat start = fixture.source_calibration[1];
            fixture_rotation(
                fixture: fixture,
                node: 1,
                start: start,
                end: fixture_turn({ 1, 0, 0 }, 30) * start,
            );

        case ANCESTOR:
            fixture.source_count = 3;
            fixture.target_count = 3;
            fixture.times[1] = 3;
            fixture.source_nodes[0].local = fixture_transform({ 1, 2, 3 }, quaternion::IDENTITY, 2);
            fixture.source_nodes[1].parent = 0;
            fixture.source_nodes[1].local = fixture_transform({ 1, 0, 0 }, quaternion::IDENTITY, 0.5f);
            fixture.source_nodes[2].parent = 1;
            fixture.source_nodes[2].local = fixture_transform({ 0, 1, 0 }, quaternion::IDENTITY, 3);
            fixture.target_nodes[0].local = fixture_transform({ -2, 1, 4 }, fixture_turn({ 0, 0, 1 }, 90), 2);
            fixture.target_nodes[1].parent = 0;
            fixture.target_nodes[1].local = fixture_transform({ 1, -2.5f, -0.5f }, fixture_turn({ 0, 0, 1 }, -90), 1.5f);
            fixture.target_nodes[2].parent = 1;
            fixture.target_nodes[2].local.position = { 0, 0, 1 };
            fixture.target_calibration[0] = fixture.target_nodes[0].local.rotation;
            fixture.target_calibration[1] = fixture.target_nodes[1].local.rotation;
            fixture.mapping[0] = { .source_node = 1, .target_node = 0 };
            fixture.mapping[1] = { .source_node = 2, .target_node = 1 };
            fixture.mapping_count = 2;
            fixture.source_motion = 2;
            fixture.target_motion = 1;
            Vec3[3] axes = { { 0, 1, 0 }, { 1, 0, 0 }, { 0, 0, 1 } };

            foreach (node, axis : axes) fixture_rotation(
                fixture: fixture,
                node: (uint)node,
                start: quaternion::IDENTITY,
                end: fixture_turn(axis, 90),
            );
            fixture_track(
                fixture: fixture,
                node: 0,
                path: TargetPath.SCALE,
                values: (float[6]){ 2, 2, 2, 4, 4, 4 }[..],
            );
            fixture_track(
                fixture: fixture,
                node: 1,
                path: TargetPath.SCALE,
                values: (float[6]){ 0.5f, 0.5f, 0.5f, 0.25f, 0.25f, 0.25f }[..],
            );
            fixture_track(
                fixture: fixture,
                node: 0,
                path: TargetPath.TRANSLATION,
                values: (float[6]){ 1, 2, 3, 1.6f, 2.3f, 2.7f }[..],
            );

        case CARRIER:
            fixture.source_count = 2;
            fixture.target_count = 5;
            fixture.source_nodes[1].parent = 0;
            fixture.target_nodes[0].local = fixture_transform({ 1, 0, 2 }, fixture_turn(WORLD_UP, 90), 2);
            fixture.target_nodes[1].parent = 0;
            fixture.target_nodes[1].local = fixture_transform({ 1, 2, 0 }, fixture_turn({ 0, 0, 1 }, 90), 0.5f);
            fixture.target_nodes[2].parent = 0;
            fixture.target_nodes[2].local.position = { -1, 0, 2 };
            fixture.target_nodes[3].parent = 1;
            fixture.target_nodes[3].local.position = { 0, 1, 0 };
            fixture.target_nodes[4].parent = 1;

            foreach (index, &node : fixture.target_nodes) fixture.target_calibration[index] = node.local.rotation;
            fixture.mapping[0] = { .source_node = 0, .target_node = 1 };
            fixture.mapping[1] = { .source_node = 1, .target_node = 4 };
            fixture.mapping_count = 2;
            fixture.source_motion = 1;
            fixture.target_motion = 4;
            fixture.carrier = 0;
            fixture.mesh_role = { .node = 2 };
            fixture_track(
                fixture: fixture,
                node: 1,
                path: TargetPath.TRANSLATION,
                values: (float[6]){ 0, 0, 0, 0.5f, 0, -0.25f }[..],
            );
            fixture_rotation(
                fixture: fixture,
                node: 1,
                start: quaternion::IDENTITY,
                end: fixture_turn(WORLD_UP, 30),
            );

        case TURN90:
        case TURN360:
            fixture.source_count = 2;
            fixture.target_count = 6;
            fixture.facing_yaw = 37;
            fixture.source_nodes[0].local.rotation = fixture_turn(WORLD_UP, 20);
            fixture.source_calibration[0] = fixture.source_nodes[0].local.rotation;
            fixture.source_nodes[1].parent = 0;
            fixture.source_nodes[1].local.position = { 1, 0, 0 };
            fixture.target_nodes[0].local = fixture_transform({}, fixture_turn(WORLD_UP, 30), 3);
            fixture.target_nodes[1].parent = 0;
            fixture.target_nodes[1].local = fixture_transform({ 1, 0, 2 }, fixture_turn(WORLD_UP, 90), 2);
            fixture.target_nodes[2].parent = 1;
            fixture.target_nodes[2].local = fixture_transform({ 0.5f, 1, 0 }, fixture_turn({ 0, 0, 1 }, 90), 0.5f);
            fixture.target_nodes[3].parent = 1;
            fixture.target_nodes[3].local.position = { -0.25f, 0, 0.25f };
            fixture.target_nodes[4].parent = 2;
            fixture.target_nodes[4].local.position = { 0, 0.5f, 0 };
            fixture.target_nodes[5].parent = 2;
            fixture.target_nodes[5].local.position = { 0, 1, 0 };

            foreach (index, &node : fixture.target_nodes) fixture.target_calibration[index] = node.local.rotation;
            fixture.mapping[0] = { .source_node = 0, .target_node = 2 };
            fixture.mapping[1] = { .source_node = 1, .target_node = 5 };
            fixture.mapping_count = 2;
            fixture.source_motion = 0;
            fixture.target_motion = 2;
            fixture.carrier = 1;
            fixture.mesh_role = { .node = 3 };
            fixture.key_count = kind == TURN90 ? 2 : 5;
            float[20] turns;
            float[15] translations;

            for (uint key = 0; key < fixture.key_count; key++) {
                fixture.times[key] = (float)key;
                Quat rotation = fixture_turn(WORLD_UP, (float)key * 90) * fixture.source_calibration[0];

                for (uint channel = 0; channel < 4; channel++) turns[key * 4 + channel] = rotation.v[channel];
                float fraction = (float)key / (float)(fixture.key_count - 1);
                translations[key * 3] = 0.5f * fraction;
                translations[key * 3 + 2] = -0.25f * fraction;
            }

            fixture_track(
                fixture: fixture,
                node: 0,
                path: TargetPath.ROTATION,
                values: turns[:fixture.key_count * 4],
            );
            fixture_track(
                fixture: fixture,
                node: 0,
                path: TargetPath.TRANSLATION,
                values: translations[:fixture.key_count * 3],
            );
    }

    fixture.source = {
        .name = "authored_motion", .duration = fixture.times[fixture.key_count - 1],
        .tracks = fixture.tracks[:fixture.track_count], .targets = fixture.targets[:fixture.source_count],
    };
    fixture.target = { .nodes = fixture.target_nodes[:fixture.target_count] };
    if (kind == CARRIER || kind == TURN90 || kind == TURN360) fixture.target.meshes = (&fixture.mesh_role)[:1];
}

fn ReferenceQuat reference_multiply(ReferenceQuat first, ReferenceQuat second) @local {
    ReferenceVec3 a = { first.x, first.y, first.z };
    ReferenceVec3 b = { second.x, second.y, second.z };
    ReferenceVec3 imaginary = a * second.w + b * first.w + a.cross(b);

    return { imaginary.x, imaginary.y, imaginary.z, first.w * second.w - a.dot(b) };
}

fn ReferenceVec3 reference_rotate(ReferenceQuat rotation, ReferenceVec3 position) @local {
    ReferenceVec3 axis = { rotation.x, rotation.y, rotation.z };

    return position + 2 * axis.cross(axis.cross(position) + position * rotation.w);
}

fn ReferenceQuat reference_turn(ReferenceVec3 axis, double degrees) @local {
    double angle = degrees * math::PI / 360;
    ReferenceVec3 imaginary = axis * math::sin(angle);

    return { imaginary.x, imaginary.y, imaginary.z, math::cos(angle) };
}

fn ReferenceQuat reference_small_turn(ReferenceVec3 axis, double degrees, double fraction) @local {
    ReferenceQuat start = { 0, 0, 0, 1 };
    ReferenceQuat end = reference_turn(axis, degrees);

    return (start * (1 - fraction) + end * fraction).normalize();
}

fn ReferencePose reference_pose(
    ReferenceVec3 position = {},
    ReferenceQuat rotation = { 0, 0, 0, 1 },
    double scale = 1,
) @local {
    return { .position = position, .rotation = rotation, .scale = scale };
}

fn ReferencePose reference_compose(ReferencePose parent, ReferencePose local) @local {
    return {
        .position = parent.position + reference_rotate(parent.rotation, local.position * parent.scale),
        .rotation = reference_multiply(parent.rotation, local.rotation),
        .scale = parent.scale * local.scale,
    };
}

fn ReferencePose reference_relative(ReferencePose world, ReferencePose parent) @local {
    ReferenceQuat inverse = { -parent.rotation.x, -parent.rotation.y, -parent.rotation.z, parent.rotation.w };

    return {
        .position = reference_rotate(inverse, world.position - parent.position) / parent.scale,
        .rotation = reference_multiply(inverse, world.rotation).normalize(),
        .scale = world.scale / parent.scale,
    };
}

fn bool turning_fixture(Fixture* fixture) @local {
    return fixture.kind == TURN90 || fixture.kind == TURN360;
}

fn ReferencePose carrier_reference(Fixture* fixture) @local {
    if (!turning_fixture(fixture)) return reference_pose({ 1, 0, 2 }, reference_turn({ 0, 1, 0 }, 90), 2);

    return reference_pose(
        reference_rotate(reference_turn({ 0, 1, 0 }, 30), { 3, 0, 6 }),
        reference_turn({ 0, 1, 0 }, 120),
        6,
    );
}

fn ReferenceVec3 walking_displacement(Fixture* fixture, double fraction) @local {
    return reference_rotate(reference_turn({ 0, 1, 0 }, fixture.facing_yaw), { 0.5 * fraction, 0, -0.25 * fraction });
}

fn ReferenceVec3 cycle_translation(Fixture* fixture, long cycles, bool root_yaw) @local {
    ReferenceVec3 end = walking_displacement(fixture, 1);
    if (!root_yaw || fixture.kind == TURN360) return end * (double)cycles;
    long remainder = cycles % 4;
    ReferenceVec3 displacement;
    if (remainder >= 0) {
        for (long cycle = 0; cycle < remainder; cycle++) {
            displacement += reference_rotate(reference_turn({ 0, 1, 0 }, (double)cycle * 90), end);
        }
    } else {
        for (long cycle = remainder; cycle < 0; cycle++) {
            displacement -= reference_rotate(reference_turn({ 0, 1, 0 }, (double)cycle * 90), end);
        }
    }

    return displacement;
}

fn ReferencePose reference_worlds(
    Fixture* fixture,
    RootMotion mode,
    float time,
    ReferencePose[] poses,
    bool root_yaw = false,
    long cycles = 0,
) @local {
    double fraction = (double)time / fixture.source.duration;
    ReferenceVec3 displacement;
    ReferenceQuat turn = { 0, 0, 0, 1 };

    switch (fixture.kind) {
        case ANATOMY:
            poses[0] = reference_pose();
            poses[1] = reference_pose({ 2, 0, 0 }, reference_small_turn({ 0, 0, 1 }, 30, fraction));
            poses[2] = reference_compose(poses[1], reference_pose({ 2, 0, 0 }));

        case FACING:
            poses[0] = reference_pose({}, reference_turn({ 0, 1, 0 }, 90));
            double angle = (double)(fixture.facing_yaw + 20) * math::PI / 180;
            ReferenceQuat calibration = reference_multiply(
                reference_turn({ 0, 1, 0 }, 90), reference_turn({ 0, 0, 1 }, -45));
            ReferenceQuat motion = reference_small_turn({ math::cos(angle), 0, -math::sin(angle) }, 30, fraction);
            poses[1] = reference_pose({}, reference_multiply(motion, calibration));

        case ANCESTOR:
            ReferenceQuat yaw = reference_turn({ 0, 1, 0 }, 90 * fraction);
            ReferenceQuat pitch = reference_turn({ 1, 0, 0 }, 90 * fraction);
            ReferenceQuat roll = reference_turn({ 0, 0, 1 }, 90 * fraction);
            ReferenceQuat parent_rotation = reference_multiply(yaw, pitch);
            double source_parent_scale = (2 + 2 * fraction) * (0.5 - 0.25 * fraction);
            ReferenceVec3 wrapper = { 1 + 0.6 * fraction, 2 + 0.3 * fraction, 3 - 0.3 * fraction };
            ReferenceVec3 parent = wrapper + reference_rotate(yaw, { 2 + 2 * fraction, 0, 0 });
            ReferenceVec3 motion = parent + reference_rotate(parent_rotation, { 0, source_parent_scale, 0 });
            poses[0] = reference_pose(
                parent + (ReferenceVec3){ -5, -1, 1 },
                reference_multiply(parent_rotation, reference_turn({ 0, 0, 1 }, 90)),
                2 * source_parent_scale,
            );
            poses[1] = reference_pose(motion, reference_multiply(parent_rotation, roll), 3 * source_parent_scale);
            poses[2] = reference_compose(poses[1], reference_pose({ 0, 0, 1 }));
            displacement = motion - (ReferenceVec3){ 3, 3, 3 };
            displacement.y = 0;

        case CARRIER:
            ReferenceQuat yaw = reference_turn({ 0, 1, 0 }, 90);
            ReferenceQuat roll = reference_turn({ 0, 0, 1 }, 90);
            ReferenceQuat calibrated = reference_multiply(yaw, roll);
            displacement = { 0.5 * fraction, 0, -0.25 * fraction };
            turn = reference_small_turn({ 0, 1, 0 }, 30, fraction);
            poses[0] = reference_pose({ 1, 0, 2 }, yaw, 2);
            poses[1] = reference_pose({ 1, 4, 0 }, calibrated);
            poses[2] = reference_pose({ 5, 0, 4 }, yaw, 2);
            poses[3] = reference_pose({ 1, 4, 1 }, calibrated);
            poses[4] = reference_pose(
                (ReferenceVec3){ 1, 4, 0 } + displacement,
                reference_multiply(reference_small_turn({ 0, 1, 0 }, 30, fraction), calibrated),
            );

        case TURN90:
        case TURN360:
            double degrees = fixture.kind == TURN90 ? 90 : 360;
            turn = reference_turn({ 0, 1, 0 }, degrees * fraction);
            displacement = walking_displacement(fixture, fraction);
            ReferencePose carrier = carrier_reference(fixture);
            ReferenceQuat calibrated = reference_multiply(carrier.rotation, reference_turn({ 0, 0, 1 }, 90));
            poses[0] = reference_pose({}, reference_turn({ 0, 1, 0 }, 30), 3);
            poses[1] = carrier;
            poses[2] = reference_pose(
                carrier.position + reference_rotate(carrier.rotation, { 3, 6, 0 }) + displacement,
                reference_multiply(turn, calibrated),
                3,
            );
            poses[3] = reference_pose(
                carrier.position + reference_rotate(carrier.rotation, { -1.5, 0, 1.5 }),
                carrier.rotation,
                6,
            );
            poses[4] = reference_compose(poses[2], reference_pose({ 0, 0.5, 0 }));
            poses[5] = reference_compose(poses[2], reference_pose({ 0, 1, 0 }));
    }

    ReferencePose root = reference_pose();
    if (mode == RootMotion.KEEP) return root;
    if (mode == RootMotion.STRIP_XZ) {
        foreach (index, &pose : poses) {
            if (fixture.carrier != retarget::RETARGET_NO_NODE && index <= fixture.carrier) continue;
            pose.position -= displacement;
        }

        return root;
    }

    ReferencePose carrier = carrier_reference(fixture);
    ReferenceVec3 total = displacement;
    ReferenceQuat cycle_rotation = { 0, 0, 0, 1 };
    if (turning_fixture(fixture)) {
        double degrees = fixture.kind == TURN90 ? 90 : 360;
        if (root_yaw) cycle_rotation = reference_turn({ 0, 1, 0 }, degrees * (double)cycles);
        total = cycle_translation(fixture, cycles, root_yaw) + reference_rotate(cycle_rotation, displacement);
    }

    if (root_yaw) {
        root.rotation = reference_multiply(cycle_rotation, turn);
        root.position = carrier.position + total - reference_rotate(root.rotation, carrier.position);
        ReferenceQuat inverse = { -turn.x, -turn.y, -turn.z, turn.w };

        foreach (index, &pose : poses) {
            if (index <= fixture.carrier) continue;
            pose.position = carrier.position + reference_rotate(inverse, pose.position - carrier.position - displacement);
            pose.rotation = reference_multiply(inverse, pose.rotation);
        }
    } else {
        root.position = total;

        foreach (index, &pose : poses) {
            if (index <= fixture.carrier) continue;
            pose.position -= displacement;
        }

        poses[fixture.carrier].rotation = reference_multiply(turn, carrier.rotation);
    }

    return root;
}

fn Vec3 visible_position(ReferenceVec3 position) @local {
    return { (float)position.x, (float)position.y, (float)position.z };
}

fn Quat visible_rotation(ReferenceQuat rotation) @local {
    rotation = rotation.normalize();

    return { .v = { (float)rotation.x, (float)rotation.y, (float)rotation.z, (float)rotation.w } };
}

fn Transform reference_local(ReferencePose world, ReferencePose parent) @local {
    ReferenceQuat inverse = { -parent.rotation.x, -parent.rotation.y, -parent.rotation.z, parent.rotation.w };

    return {
        .position = visible_position(reference_rotate(inverse, world.position - parent.position) / parent.scale),
        .rotation = visible_rotation(reference_multiply(inverse, world.rotation)),
        .scale = {
            (float)(world.scale / parent.scale), (float)(world.scale / parent.scale), (float)(world.scale / parent.scale),
        },
    };
}

fn ModelId? publish_fixture_model(AssetStore* assets, NodeTemplate[] nodes) @local {
    ModelTemplate model = { .nodes = alloc::new_array(assets.allocator, NodeTemplate, nodes.len) };
    defer catch asset::free_model_template(assets.allocator, &model);

    foreach (index, &node : model.nodes) {
        *node = nodes[index];
        node.name = nodes[index].name.copy(assets.allocator);
    }

    return assets.add_model_owned(&model);
}

fn ClipId? publish_fixture_clip(
    AssetStore* assets,
    Fixture* fixture,
    RetargetProfile* profile,
    RootMotion mode,
) @local {
    RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
    options.bake_rate = BAKE_RATE;
    options.root_motion = mode;
    AnimationClip clip = retarget::retarget_with_profile(
        allocator: assets.allocator,
        source: &fixture.source,
        source_nodes: fixture.source_nodes[:fixture.source_count],
        target: &fixture.target,
        profile: profile,
        options: options,
    )!;
    defer catch asset::free_clip(assets.allocator, &clip);
    if (mode == RootMotion.EXTRACT) {
        foreach (&track : clip.tracks) {
            if (clip.targets[track.target] == fixture.carrier && track.path == TargetPath.SCALE) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
    }

    return assets.add_clip_owned(&clip);
}

fn RigView? build_rig_view(
    Scene* scene,
    AssetStore* assets,
    ModelId model_id,
    GeometryId joint_geometry,
    GeometryId bone_geometry,
    MaterialId material_id,
    Fixture* fixture,
    Vec3 placement,
    bool actual,
    RootMotion mode,
    ClipId clip = {},
    bool root_yaw = false,
    bool looping = false,
    float playback_speed = 1,
) @local {
    RigView view = {
        .display = scene.add_node(name: actual ? "profiled" : "expected")!,
        .mode = mode,
    };
    view.display.local.position = placement;
    view.root = model::instantiate(
        assets: assets,
        scene: scene,
        model: model_id,
        parent: view.display,
        name: "rig",
    )!;
    ModelInstance* instance = scene.get(view.root, ModelInstance);

    for (uint index = 0; index < fixture.target_count; index++) {
        Node* node = instance.present_node(index);
        view.nodes[index] = node;
        bool frame_helper = (fixture.kind == FACING && index == 0)
            || (fixture.carrier != retarget::RETARGET_NO_NODE && index <= fixture.carrier);
        if (!frame_helper) {
            view.glyphs[index] = scene.add_mesh(
                geometry: joint_geometry,
                material: material_id,
                parent: node,
                name: "joint_glyph",
            )!;
        }

        if (fixture.target_nodes[index].parent >= 0) {
            view.bones[index] = scene.add_mesh(
                geometry: bone_geometry,
                material: material_id,
                parent: view.display,
                name: "bone_glyph",
            )!;
        }
    }

    if (actual) {
        Animator* animator = anim::add_animator(scene, view.root);
        if (mode == RootMotion.EXTRACT) animator.root_node = fixture.carrier;
        view.action = animator.play(
            assets: assets,
            clip: clip,
            desc: { .root_motion = mode == RootMotion.EXTRACT ? RootMotion.EXTRACT : RootMotion.KEEP, .root_yaw = root_yaw },
        )!;
        animator.action(view.action).loop = looping;
        animator.action(view.action).speed = playback_speed;
        animator.action(view.action).playing = false;
    }

    return view;
}

fn void? build_fixture_row(
    FixtureRow* row,
    FixtureKind kind,
    uint variant,
    RootMotion mode,
    Scene* scene,
    AssetStore* assets,
    GeometryId joint_geometry,
    GeometryId bone_geometry,
    MaterialId reference_material,
    MaterialId actual_material,
    float row_height,
    bool root_yaw = false,
    bool looping = false,
    float playback_speed = 1,
) @local {
    fixture_authored(&row.fixture, kind, variant);
    row.mode = mode;
    row.root_yaw = root_yaw;
    row.looping = looping;
    row.playback_speed = playback_speed;
    RetargetProfileDesc desc = retarget::RETARGET_PROFILE_DESC_DEFAULT;
    desc.mapping_mode = ProfileMappingMode.BY_INDEX;
    desc.index_map = row.fixture.mapping[:row.fixture.mapping_count];
    desc.source_calibration = row.fixture.source_calibration[:row.fixture.source_count];
    desc.target_calibration = row.fixture.target_calibration[:row.fixture.target_count];
    desc.source_motion_node = row.fixture.source_motion;
    desc.target_motion_node = row.fixture.target_motion;
    desc.target_carrier = row.fixture.carrier;
    desc.facing = fixture_turn(WORLD_UP, row.fixture.facing_yaw).to_matrix();
    RetargetProfile profile = retarget::create_retarget_profile(
        allocator: assets.allocator,
        source_nodes: row.fixture.source_nodes[:row.fixture.source_count],
        target: &row.fixture.target,
        desc: desc,
    )!;
    defer retarget::destroy_retarget_profile(&profile);
    ClipId clip = publish_fixture_clip(
        assets: assets,
        fixture: &row.fixture,
        profile: &profile,
        mode: mode,
    )!;
    ModelId model_id = publish_fixture_model(assets, row.fixture.target_nodes[:row.fixture.target_count])!;
    Vec3 placement = { -DISPLAY_SPACING.x, row_height, 0 };
    row.reference = build_rig_view(
        scene: scene,
        assets: assets,
        model_id: model_id,
        joint_geometry: joint_geometry,
        bone_geometry: bone_geometry,
        material_id: reference_material,
        fixture: &row.fixture,
        placement: placement,
        actual: false,
        mode: mode,
    )!;
    placement.x = DISPLAY_SPACING.x;
    row.actual = build_rig_view(
        scene: scene,
        assets: assets,
        model_id: model_id,
        joint_geometry: joint_geometry,
        bone_geometry: bone_geometry,
        material_id: actual_material,
        fixture: &row.fixture,
        placement: placement,
        actual: true,
        mode: mode,
        clip: clip,
        root_yaw: root_yaw,
        looping: looping,
        playback_speed: playback_speed,
    )!;
}

fn void set_reference_pose(FixtureRow* row, float time) @local {
    ReferencePose[FIXTURE_NODES] poses;
    ReferencePose root = reference_worlds(
        fixture: &row.fixture,
        mode: row.mode,
        time: time,
        poses: poses[:row.fixture.target_count],
        root_yaw: row.root_yaw,
        cycles: row.cycles,
    );
    row.reference.root.local.position = visible_position(root.position);
    row.reference.root.local.rotation = visible_rotation(root.rotation);

    for (uint index = 0; index < row.fixture.target_count; index++) {
        int parent_index = row.fixture.target_nodes[index].parent;
        ReferencePose parent = parent_index < 0 ? reference_pose() : poses[parent_index];
        row.reference.nodes[index].local = reference_local(poses[index], parent);
    }
}

fn void update_bone_glyphs(RigView* view, Fixture* fixture) @local {
    for (uint index = 0; index < fixture.target_count; index++) {
        Node* bone = view.bones[index];
        if (!bone) continue;
        int parent = fixture.target_nodes[index].parent;
        Vec3 start = view.nodes[parent].world_position();
        Vec3 end = view.nodes[index].world_position();
        Vec3 direction = end - start;
        float length = direction.length();
        bone.visible = length > 1e-5f;
        if (!bone.visible) continue;
        bone.local.position = (start + end) * 0.5f - view.display.world_position();
        bone.local.rotation = maths::rotation_between(WORLD_UP, direction / length);
        bone.local.scale = { 1, length, 1 };
    }
}

fn ReferenceVec3 relative_position(Node* node, RigView* view) @local {
    Vec3 point = node.world_position() - view.display.world_position();

    return { point.x, point.y, point.z };
}

fn double pose_rotation_error(Node* node, ReferenceQuat expected) @local {
    Quat actual = maths::transform_from_mat4(node.world).rotation;
    double dot;
    double actual_length;
    double expected_length;

    foreach (index, value : actual.v) {
        dot += (double)value * expected[index];
        actual_length += (double)value * value;
        expected_length += expected[index] * expected[index];
    }

    dot = math::abs(dot) / math::sqrt(actual_length * expected_length);

    return 2 * math::acos(math::clamp(dot, 0.0, 1.0));
}

fn ReferencePose observed_pose(Node* node, RigView* view) @local {
    Transform transform = maths::transform_from_mat4(node.world);
    Vec3 position = node.world_position();
    Vec3 display = view.display.world_position();
    ReferenceQuat rotation = {
        transform.rotation.v.x, transform.rotation.v.y, transform.rotation.v.z, transform.rotation.v.w,
    };

    return {
        .position = {
            (double)position.x - display.x,
            (double)position.y - display.y,
            (double)position.z - display.z,
        },
        .rotation = rotation.normalize(),
        .scale = transform.scale.x,
    };
}

fn double reference_rotation_error(ReferenceQuat actual, ReferenceQuat expected) @local {
    double dot;
    double actual_length;
    double expected_length;

    foreach (index, value : actual) {
        dot += value * expected[index];
        actual_length += value * value;
        expected_length += expected[index] * expected[index];
    }

    dot = math::abs(dot) / math::sqrt(actual_length * expected_length);

    return 2 * math::acos(math::clamp(dot, 0.0, 1.0));
}

fn bool accumulated_row(FixtureRow* row) @local {
    return turning_fixture(&row.fixture) && row.mode == RootMotion.EXTRACT;
}

fn bool sample_is_key(float time) @local {
    float frame = time * BAKE_RATE;

    return math::abs(frame - math::round(frame)) <= KEY_RECOGNITION_TOLERANCE;
}

fn ReferenceVec3 reference_pivot(FixtureRow* row, float time) @local {
    ReferencePose carrier = carrier_reference(&row.fixture);
    if (row.mode != RootMotion.EXTRACT) return carrier.position;
    double fraction = (double)time / row.fixture.source.duration;
    ReferenceVec3 displacement = { 0.5 * fraction, 0, -0.25 * fraction };
    if (turning_fixture(&row.fixture)) {
        double degrees = row.fixture.kind == TURN90 ? 90 : 360;
        ReferenceQuat cycle = row.root_yaw ? reference_turn({ 0, 1, 0 }, degrees * (double)row.cycles)
            : (ReferenceQuat){ 0, 0, 0, 1 };
        displacement = cycle_translation(&row.fixture, row.cycles, row.root_yaw)
            + reference_rotate(cycle, walking_displacement(&row.fixture, fraction));
    }

    return carrier.position + displacement;
}

fn void measure_row(FixtureRow* row, float time, Metrics* metrics) @local {
    ReferencePose[FIXTURE_NODES] poses;
    ReferencePose root = reference_worlds(
        fixture: &row.fixture,
        mode: row.mode,
        time: time,
        poses: poses[:row.fixture.target_count],
        root_yaw: row.root_yaw,
        cycles: row.cycles,
    );
    bool key = sample_is_key(time);
    bool accumulated = accumulated_row(row);
    ReferenceVec3 actual_root = relative_position(row.actual.root, &row.actual);
    ReferencePose expected_carrier;
    ReferencePose actual_carrier;
    Transform actual_carrier_transform;
    row.position_error = 0;
    row.rotation_error = 0;
    row.scale_error = 0;
    row.root_error = (actual_root - root.position).length();
    row.root_rotation_error = pose_rotation_error(row.actual.root, root.rotation);
    row.root_radius = math::max(actual_root.length(), root.position.length());
    row.pivot_error = 0;
    row.pivot_radius = 0;

    if (row.fixture.carrier != retarget::RETARGET_NO_NODE) {
        ReferenceVec3 pivot = reference_pivot(row, time);
        ReferenceVec3 actual_pivot = relative_position(row.actual.nodes[row.fixture.carrier], &row.actual);
        row.pivot_error = (actual_pivot - pivot).length();
        row.pivot_radius = math::max(actual_pivot.length(), pivot.length());

        if (accumulated) {
            expected_carrier = reference_compose(root, poses[row.fixture.carrier]);
            actual_carrier = observed_pose(row.actual.nodes[row.fixture.carrier], &row.actual);
            actual_carrier_transform = maths::transform_from_mat4(row.actual.nodes[row.fixture.carrier].world);
        }
    }

    metrics.max_root_error = math::max(metrics.max_root_error, row.root_error);
    metrics.max_root_rotation = math::max(metrics.max_root_rotation, row.root_rotation_error);
    metrics.max_pivot_error = math::max(metrics.max_pivot_error, row.pivot_error);
    metrics.max_root_radius = math::max(metrics.max_root_radius, row.root_radius);
    metrics.max_pivot_radius = math::max(metrics.max_pivot_radius, row.pivot_radius);

    for (uint index = 0; index < row.fixture.target_count; index++) {
        ReferencePose desired = poses[index];
        Node* actual = row.actual.nodes[index];
        double position_error = (relative_position(actual, &row.actual) - root.position - reference_rotate(root.rotation, desired.position)).length();
        double rotation_error = pose_rotation_error(actual, reference_multiply(root.rotation, desired.rotation));
        Transform actual_pose = maths::transform_from_mat4(actual.world);
        double scale_error = math::abs((double)actual_pose.scale.x - desired.scale);
        scale_error = math::max(scale_error, math::abs((double)actual_pose.scale.y - desired.scale));
        scale_error = math::max(scale_error, math::abs((double)actual_pose.scale.z - desired.scale));
        bool controlled = accumulated && index > row.fixture.carrier;

        if (controlled) {
            ReferencePose expected_relative = reference_relative(reference_compose(root, desired), expected_carrier);
            ReferencePose actual_relative = reference_relative(observed_pose(actual, &row.actual), actual_carrier);
            position_error = (actual_relative.position - expected_relative.position).length();
            rotation_error = reference_rotation_error(actual_relative.rotation, expected_relative.rotation);
            scale_error = math::abs(actual_relative.scale - expected_relative.scale);
            scale_error = math::max(scale_error,
                math::abs((double)actual_pose.scale.y / actual_carrier_transform.scale.y - expected_relative.scale));
            scale_error = math::max(scale_error,
                math::abs((double)actual_pose.scale.z / actual_carrier_transform.scale.z - expected_relative.scale));
        }

        row.position_error = math::max(row.position_error, position_error);
        row.rotation_error = math::max(row.rotation_error, rotation_error);
        row.scale_error = math::max(row.scale_error, scale_error);

        bool failed = !math::is_finite(position_error) || !math::is_finite(rotation_error)
            || !math::is_finite(scale_error) || !math::is_finite(row.root_error)
            || !math::is_finite(row.root_rotation_error) || !math::is_finite(row.pivot_error)
            || !math::is_finite(row.root_radius) || !math::is_finite(row.pivot_radius);
        double position_bound = key ? KEY_POSITION_BOUND : SUBKEY_POSITION_BOUND;
        double rotation_bound = key ? KEY_ROTATION_BOUND : SUBKEY_ROTATION_BOUND;
        double path_bound = accumulated ? ACCUMULATED_POSITION_BOUND : position_bound;
        double root_rotation_bound = accumulated ? KEY_ROTATION_BOUND : rotation_bound;
        if (accumulated && !controlled) position_bound = ACCUMULATED_POSITION_BOUND;

        failed |= position_error > position_bound || rotation_error > rotation_bound
            || row.root_error > path_bound || row.root_rotation_error > root_rotation_bound
            || row.pivot_error > path_bound;

        if (key) {
            metrics.key_samples++;
            failed |= scale_error > KEY_SCALE_BOUND;

            if (!accumulated) {
                metrics.max_key_position = math::max(metrics.max_key_position, position_error);
                metrics.max_key_rotation = math::max(metrics.max_key_rotation, rotation_error);
                metrics.max_key_scale = math::max(metrics.max_key_scale, scale_error);
            } else if (controlled) {
                metrics.carrier_key_samples++;
                metrics.max_carrier_key_position = math::max(metrics.max_carrier_key_position, position_error);
                metrics.max_carrier_key_rotation = math::max(metrics.max_carrier_key_rotation, rotation_error);
                metrics.max_carrier_key_scale = math::max(metrics.max_carrier_key_scale, scale_error);
            }
        } else {
            metrics.subkey_samples++;

            if (!accumulated) {
                metrics.max_subkey_position = math::max(metrics.max_subkey_position, position_error);
                metrics.max_subkey_rotation = math::max(metrics.max_subkey_rotation, rotation_error);
            } else if (controlled) {
                metrics.carrier_subkey_samples++;
                metrics.max_carrier_subkey_position = math::max(metrics.max_carrier_subkey_position, position_error);
                metrics.max_carrier_subkey_rotation = math::max(metrics.max_carrier_subkey_rotation, rotation_error);
                metrics.max_carrier_subkey_scale = math::max(metrics.max_carrier_subkey_scale, scale_error);
            }
        }

        if (failed) metrics.failures++;
    }

    metrics.families_seen[row.fixture.kind.ordinal] = true;
    metrics.modes_seen[row.mode.ordinal] = true;

    if (turning_fixture(&row.fixture)) {
        uint turn = row.fixture.kind == TURN90 ? 0 : 1;
        if (row.mode == RootMotion.EXTRACT) metrics.turn_yaw_seen[turn][row.root_yaw ? 1 : 0] = true;

        if (row.looping && row.cycles != 0) {
            metrics.turn_loop_seen[turn] = true;
            if (row.playback_speed < 0) metrics.turn_reverse_loop_seen[turn] = true;
        }
    }
}

fn ZString root_mode_name(RootMotion mode) @local {
    switch (mode) {
        case KEEP: return "KEEP";
        case STRIP_XZ: return "STRIP_XZ";
        case EXTRACT: return "EXTRACT";
    }
}

fn void set_family_active(FixtureFamily[] families, uint selected) @local {
    foreach (index, &family : families) {
        for (uint row_index = 0; row_index < family.count; row_index++) {
            family.rows[row_index].actual.display.visible = index == selected;
            family.rows[row_index].reference.display.visible = index == selected;
        }
    }
}

fn void advance_fixture_clocks(
    Scene* scene,
    FixtureFamily[] families,
    uint selected,
    bool paused,
    float dt,
) @local {
    foreach (index, &family : families) {
        for (uint row_index = 0; row_index < family.count; row_index++) {
            FixtureRow* row = &family.rows[row_index];
            Animator* animator = scene.get(row.actual.root, Animator);
            Action* action = animator.action(row.actual.action);
            if (index != selected || paused) {
                action.playing = false;
                continue;
            }

            float duration = row.fixture.source.duration;
            if (row.looping) {
                action.speed = row.playback_speed;
                row.loop_travel += (double)dt * row.playback_speed;
                row.cycles = (long)math::floor(row.loop_travel / duration);
            } else if ((action.speed > 0 && action.time >= duration) || (action.speed < 0 && action.time <= 0)) {
                action.speed = -action.speed;
            }

            action.playing = true;
        }
    }
}

fn void apply_fixture_motion(Scene* scene, FixtureFamily* family) @local {
    for (uint index = 0; index < family.count; index++) {
        FixtureRow* row = &family.rows[index];
        if (row.mode != RootMotion.EXTRACT) continue;
        Animator* animator = scene.get(row.actual.root, Animator);
        anim::apply_root_motion(row.actual.root, animator.root_motion);
    }
}

fn float row_time(Scene* scene, FixtureRow* row) @local {
    return scene.get(row.actual.root, Animator).action(row.actual.action).time;
}

fn void draw_rig_axes(debug::DebugDraw* debug, RigView* view, Fixture* fixture, uint color) @local {
    for (uint index = 0; index < fixture.target_count; index++) {
        Node* node = view.nodes[index];
        int parent = fixture.target_nodes[index].parent;
        if (parent >= 0) debug.line(
            from: view.nodes[parent].world_position(),
            to: node.world_position(),
            rgba: color,
        );
        debug.axes(node.world, 0.35f);
    }
}

fn void draw_rest_pose(
    debug::DebugDraw* debug,
    NodeTemplate[] nodes,
    Vec3 placement,
    uint color,
) @local {
    ReferencePose[FIXTURE_NODES] poses;

    foreach (index, &node : nodes) {
        Quat rotation = node.local.rotation;
        ReferencePose local = reference_pose(
            { node.local.position.x, node.local.position.y, node.local.position.z },
            (ReferenceQuat){ rotation.v.x, rotation.v.y, rotation.v.z, rotation.v.w }.normalize(),
            node.local.scale.x,
        );
        poses[index] = node.parent < 0 ? local : reference_compose(poses[node.parent], local);
        if (node.parent < 0) continue;
        debug.line(
            from: visible_position(poses[node.parent].position) + placement,
            to: visible_position(poses[index].position) + placement,
            rgba: color,
        );
    }
}

fn void draw_fixture(debug::DebugDraw* debug, FixtureFamily* family) @local {
    for (uint index = 0; index < family.count; index++) {
        FixtureRow* row = &family.rows[index];
        draw_rig_axes(
            debug: debug,
            view: &row.reference,
            fixture: &row.fixture,
            color: REFERENCE_COLOR,
        );
        draw_rig_axes(
            debug: debug,
            view: &row.actual,
            fixture: &row.fixture,
            color: PROFILE_COLOR,
        );
        if (family.kind == ANATOMY) {
            draw_rest_pose(
                debug: debug,
                nodes: row.fixture.source_nodes[:row.fixture.source_count],
                placement: row.reference.display.world_position() + (Vec3){ 0, -1, 0 },
                color: debug::COLOR_BLUE,
            );
            draw_rest_pose(
                debug: debug,
                nodes: row.fixture.target_nodes[:row.fixture.target_count],
                placement: row.actual.display.world_position() + (Vec3){ 0, -1, 0 },
                color: debug::COLOR_WHITE,
            );
        }

        if (row.mode == RootMotion.EXTRACT) {
            debug.line(
                from: row.actual.display.world_position(),
                to: row.actual.root.world_position(),
                rgba: debug::COLOR_RED,
            );
        }
    }
}

fn void? profile_panel(
    Renderer* renderer,
    Scene* scene,
    FixtureFamily[] families,
    Controls* controls,
    Metrics* metrics,
) @local {
    imgui::set_next_window_pos({ 16, 16 }, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size({ 440, 640 }, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Calibrated retargeting", null, {})) {
        imgui::text("Repository-authored fixtures, version %u", FIXTURE_VERSION);
        imgui::text("Green left: expected / amber right: profiled");
        imgui::text("F next case, Space pause, A automatic, I axes");
        imgui::text("Current: %s", FAMILY_NAMES[controls.family]);
        imgui::checkbox("Automatic cases", &controls.automatic);
        imgui::checkbox("Pause", &controls.paused);
        imgui::checkbox("Axes and rest ghosts", &controls.lines);
        FixtureFamily* family = &families[controls.family];

        for (uint index = 0; index < family.count; index++) {
            FixtureRow* row = &family.rows[index];
            imgui::separator();
            imgui::text("Row %u: %s, time %.3f", index + 1, root_mode_name(row.mode), row_time(scene, row));
            if (turning_fixture(&row.fixture)) imgui::text("Yaw %s, %s, cycles %lld",
                row.root_yaw ? "on" : "off", row.looping ? (row.playback_speed < 0 ? "reverse loop" : "loop") : "forward/reverse",
                row.cycles);
            if (family.kind == FACING) imgui::text("Facing %.0f degrees", row.fixture.facing_yaw);
            imgui::text("Pose %.6f m, rotation %.6f deg", row.position_error, row.rotation_error * 180 / math::PI);
            if (accumulated_row(row)) imgui::text("Controlled poses: carrier-relative; paths: 0.5 mm");
            imgui::text("Root %.6f m / %.6f rad, pivot %.6f m", row.root_error, row.root_rotation_error, row.pivot_error);
        }

        imgui::separator();
        imgui::text("Key samples %llu, subkeys %llu, failed %llu", metrics.key_samples, metrics.subkey_samples, metrics.failures);
        imgui::text("Key bounds: 10 um / 0.0001 rad / 0.00001 scale");
        imgui::text("Between keys: 0.5 mm / 0.25 degrees");
        imgui::text("EXTRACT turns: root rotation 0.0001 rad throughout");
    }

    imgui::end();
    imgui::set_next_window_pos({ 924, 16 }, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size({ 340, 280 }, imgui::COND_FIRST_USE_EVER);

    return gui::stats_panel(renderer);
}

fn bool? render_profile_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera,
    GuiRenderer* gui,
    debug::DebugDraw* debug,
    FrameInfo info,
    ViewId capture_view,
    bool capture,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    bool captured;
    if (renderer.has_output) {
        renderer.render_view(
            scene: scene,
            camera_node: camera,
            view: renderer.default_view,
            debug: debug,
        )!;
        renderer.finish_view(renderer.default_view)!;
        if (capture) {
            renderer.render_view(
                scene: scene,
                camera_node: camera,
                view: capture_view,
                debug: debug,
            )!;
            renderer.finish_view(capture_view)!;
            captured = true;
        }

        OverlayContext overlay = renderer.begin_overlay()!;
        gui.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    renderer.end_frame()!;

    return captured;
}

fn void? profile_csv(
    File* output,
    Scene* scene,
    FixtureFamily* family,
    uint frame,
    float wall,
    float elapsed,
    int capture_index,
) @local {
    for (uint row_index = 0; row_index < family.count; row_index++) {
        FixtureRow* row = &family.rows[row_index];
        float time = row_time(scene, row);
        ReferencePose[FIXTURE_NODES] poses;
        ReferencePose root = reference_worlds(
            fixture: &row.fixture,
            mode: row.mode,
            time: time,
            poses: poses[:row.fixture.target_count],
            root_yaw: row.root_yaw,
            cycles: row.cycles,
        );
        bool accumulated = accumulated_row(row);
        bool key = sample_is_key(time);
        ReferenceVec3 pivot;
        ReferenceVec3 actual_pivot;
        ReferencePose expected_carrier;
        ReferencePose actual_carrier;
        Transform actual_carrier_transform;

        if (row.fixture.carrier != retarget::RETARGET_NO_NODE) {
            pivot = reference_pivot(row, time);
            actual_pivot = relative_position(row.actual.nodes[row.fixture.carrier], &row.actual);

            if (accumulated) {
                expected_carrier = reference_compose(root, poses[row.fixture.carrier]);
                actual_carrier = observed_pose(row.actual.nodes[row.fixture.carrier], &row.actual);
                actual_carrier_transform = maths::transform_from_mat4(row.actual.nodes[row.fixture.carrier].world);
            }
        }

        Quat actual_root_rotation = row.actual.root.local.rotation;
        float speed = scene.get(row.actual.root, Animator).action(row.actual.action).speed;

        for (uint node = 0; node < row.fixture.target_count; node++) {
            ReferenceVec3 actual = relative_position(row.actual.nodes[node], &row.actual);
            ReferenceVec3 expected = root.position + reference_rotate(root.rotation, poses[node].position);
            Transform actual_pose = maths::transform_from_mat4(row.actual.nodes[node].world);
            double rotation_error = pose_rotation_error(row.actual.nodes[node], reference_multiply(root.rotation, poses[node].rotation));
            double scale_error = math::abs((double)actual_pose.scale.x - poses[node].scale);
            scale_error = math::max(scale_error, math::abs((double)actual_pose.scale.y - poses[node].scale));
            scale_error = math::max(scale_error, math::abs((double)actual_pose.scale.z - poses[node].scale));
            bool controlled = accumulated && node > row.fixture.carrier;
            ReferencePose expected_relative;
            ReferencePose actual_relative;
            double carrier_position_error;
            double carrier_rotation_error;
            double carrier_scale_error;

            if (controlled) {
                expected_relative = reference_relative(reference_compose(root, poses[node]), expected_carrier);
                actual_relative = reference_relative(observed_pose(row.actual.nodes[node], &row.actual), actual_carrier);
                carrier_position_error = (actual_relative.position - expected_relative.position).length();
                carrier_rotation_error = reference_rotation_error(actual_relative.rotation, expected_relative.rotation);
                carrier_scale_error = math::abs(actual_relative.scale - expected_relative.scale);
                carrier_scale_error = math::max(carrier_scale_error,
                    math::abs((double)actual_pose.scale.y / actual_carrier_transform.scale.y - expected_relative.scale));
                carrier_scale_error = math::max(carrier_scale_error,
                    math::abs((double)actual_pose.scale.z / actual_carrier_transform.scale.z - expected_relative.scale));
            }

            double position_bound = key ? KEY_POSITION_BOUND : SUBKEY_POSITION_BOUND;
            double rotation_bound = key ? KEY_ROTATION_BOUND : SUBKEY_ROTATION_BOUND;
            double path_bound = accumulated ? ACCUMULATED_POSITION_BOUND : position_bound;
            double root_rotation_bound = accumulated ? KEY_ROTATION_BOUND : rotation_bound;
            if (accumulated && !controlled) position_bound = ACCUMULATED_POSITION_BOUND;

            io::fprintfn(output,
                "%d,%.9f,%.9f,%d,%d,%d,%d,%.9f,%d,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%d,%d,%d,%.9f,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f",
                frame, wall, elapsed, FIXTURE_VERSION, family.kind.ordinal, row.fixture.variant, row.mode.ordinal,
                time, key ? 1 : 0, node,
                expected.x, expected.y, expected.z, actual.x, actual.y, actual.z,
                (actual - expected).length(), rotation_error, poses[node].scale, actual_pose.scale.x,
                root.position.x, root.position.z, row.actual.root.local.position.x, row.actual.root.local.position.z,
                row.root_error, capture_index, row.root_yaw ? 1 : 0, row.looping ? 1 : 0, speed, row.cycles,
                row.fixture.facing_yaw,
                root.rotation.x, root.rotation.y, root.rotation.z, root.rotation.w,
                actual_root_rotation.v.x, actual_root_rotation.v.y, actual_root_rotation.v.z, actual_root_rotation.v.w,
                row.root_rotation_error, pivot.x, pivot.y, pivot.z,
                actual_pivot.x, actual_pivot.y, actual_pivot.z, row.pivot_error,
                controlled ? 1 : 0,
                expected_relative.position.x, expected_relative.position.y, expected_relative.position.z,
                actual_relative.position.x, actual_relative.position.y, actual_relative.position.z,
                expected_relative.rotation.x, expected_relative.rotation.y, expected_relative.rotation.z, expected_relative.rotation.w,
                actual_relative.rotation.x, actual_relative.rotation.y, actual_relative.rotation.z, actual_relative.rotation.w,
                expected_relative.scale, actual_relative.scale,
                carrier_position_error, carrier_rotation_error, carrier_scale_error, row.root_radius, row.pivot_radius,
                position_bound, rotation_bound, path_bound, root_rotation_bound, scale_error)!;
        }
    }
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;

    return (String)source.parent()!!.tappend(relative)!!;
}

fn uint? node_named(ModelTemplate* template, String name) @local {
    foreach (uint index, &node : template.nodes) {
        if (node.name == name || node.name.ends_with(string::tformat(":%s", name))) return index;
    }

    return NOT_FOUND~;
}

fn usz mapped_joints(AssetStore* assets, ClipId clip) @local {
    usz count;

    foreach (&track : assets.clip(clip).data.tracks) {
        if (track.path == TargetPath.ROTATION) count++;
    }

    return count;
}

fn void play(AssetStore* assets, Scene* scene, Showcase* showcase) @local {
    Animator* source = scene.get(showcase.source, Animator);
    Animator* target = scene.get(showcase.target, Animator);

    while (source.action_count) source.stop(source.order[0])!!;

    while (target.action_count) target.stop(target.order[0])!!;
    if (showcase.resting) return;
    source.play(assets, showcase.source_clip)!!;
    target.play(assets, showcase.corrected ? showcase.corrected_clip : showcase.copied_clip)!!;
}

fn void report(Showcase* showcase, float scale, usz mapped) @local {
    io::printfn("right: %s, %s, root scale %.3f, %d mapped joints",
        showcase.corrected ? "CORRECT" : "COPY", showcase.resting ? "rest pose" : "walking", scale, mapped);
}

fn ClipId? retargeted_walk(
    AssetStore* assets,
    String walk,
    ModelId model,
    RetargetOptions options,
) @local {
    ClipId[] clips = fbx::load_animations(mem, assets, walk, model, options)!;
    defer alloc::free(mem, clips.ptr);
    if (!clips.len) return c3d::ASSET_FORMAT_ERROR~;

    return clips[0];
}

fn int run_mixamo(uint frame_limit) @local {
    String[3] required = { example_path(SOURCE_CHARACTER), example_path(SOURCE_WALK), example_path(TARGET_CHARACTER) };

    foreach (candidate : required) {
        if (!file::is_file(candidate)) {
            io::eprintfn("missing %s; examples/assets/mixamo/README.md lists the files this example needs", candidate);

            return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d retarget", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_retarget" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ModelId source_model = fbx::load_model(&assets, required[0])!!;
    ModelId target_model = gltf::load_model(&assets, required[2])!!;
    ModelTemplate* source_template = &assets.model(source_model).data;
    ModelTemplate* target_template = &assets.model(target_model).data;
    uint source_hips = node_named(source_template, SOURCE_HIPS)!!;
    uint target_hips = node_named(target_template, TARGET_HIPS)!!;
    float scale = retarget::rest_world_position(target_template.nodes, target_hips).y
        / retarget::rest_world_position(source_template.nodes, source_hips).y;

    RetargetOptions copy_options = retarget::RETARGET_OPTIONS_DEFAULT;
    copy_options.root_motion = RootMotion.STRIP_XZ;
    RetargetOptions target_options = copy_options;
    target_options.name_map = BODY_MAP[..];
    target_options.allow_partial = true;
    target_options.root_translation_scale = scale;
    RetargetOptions corrected_options = target_options;
    corrected_options.rest_pose = RestPose.CORRECT;

    Showcase showcase = {
        .source_clip    = retargeted_walk(&assets, required[1], source_model, copy_options)!!,
        .copied_clip    = retargeted_walk(&assets, required[1], target_model, target_options)!!,
        .corrected_clip = retargeted_walk(&assets, required[1], target_model, corrected_options)!!,
        .corrected      = true,
    };

    usz mapped = mapped_joints(&assets, showcase.corrected_clip);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    showcase.source = model::instantiate(&assets, &scene, source_model, name: "source")!!;
    showcase.target = model::instantiate(&assets, &scene, target_model, name: "target")!!;
    showcase.source.local.position = { -INSTANCE_SPACING, 0, 0 };
    showcase.target.local.position = { INSTANCE_SPACING, 0, 0 };
    anim::add_animator(&scene, showcase.source);
    anim::add_animator(&scene, showcase.target);
    play(&assets, &scene, &showcase);

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(CAMERA_TARGET - CAMERA_POSITION, { 0, 1, 0 });
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("left: Mixamo source (COPY); right: Quaternius target");
    io::printn("T toggles CORRECT and COPY on the right, R toggles the rest pose, Escape quits");
    report(&showcase, scale, mapped);
    uint frame;

    while (window.poll()) {
        if (frame_limit && frame >= frame_limit) break;
        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE)) break;
        if (input.key_pressed(Scancode.T) || input.key_pressed(Scancode.R)) {
            if (input.key_pressed(Scancode.T)) showcase.corrected = !showcase.corrected;
            if (input.key_pressed(Scancode.R)) showcase.resting = !showcase.resting;
            play(&assets, &scene, &showcase);
            report(&showcase, scale, mapped);
        }

        anim::update(&assets, &scene, window.clock.delta);
        scene.update_world();
        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
        frame++;
    }

    renderer.log.check_validation()!!;

    return 0;
}

fn void? run_profile(
    platform::Window* window,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    uint frame_limit,
    bool acceptance,
    String capture_directory,
    String telemetry_path,
) @local {
    GeometryId joint_geometry;
    GeometryId bone_geometry;
    @pool() {
        Geometry joint = geometry::box(
            allocator: tmem,
            width: 0.25f,
            height: 0.12f,
            depth: 0.4f,
        );
        joint_geometry = assets.add_geometry(&joint, "retarget/joint")!;
        Geometry bone = geometry::cylinder(
            allocator: tmem,
            radius_top: 0.025f,
            radius_bottom: 0.025f,
            height: 1,
            slices: 12,
        );
        bone_geometry = assets.add_geometry(&bone, "retarget/bone")!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = 0.8f;
    params.base_color = { 0.16f, 0.85f, 0.4f, 1 };
    MaterialId reference_material = assets.add_material(material::standard(params), "retarget/reference")!;
    params.base_color = { 1, 0.64f, 0.16f, 1 };
    MaterialId actual_material = assets.add_material(material::standard(params), "retarget/profiled")!;
    FixtureFamily[] families = mem::new_array(FixtureFamily, FIXTURE_FAMILIES);
    defer free(families);

    foreach (index, &family : families) {
        family.kind = (FixtureKind)index;

        switch (family.kind) {
            case ANATOMY: family.count = 2;
            case FACING: family.count = 4;
            case ANCESTOR: family.count = 2;
            case CARRIER: family.count = 3;
            case TURN90:
            case TURN360:
                family.count = 8;
        }

        for (uint row = 0; row < family.count; row++) {
            bool turning = family.kind == TURN90 || family.kind == TURN360;
            RootMotion mode = turning ? (row < 2 ? (RootMotion)row : RootMotion.EXTRACT)
                : family.kind == ANCESTOR || family.kind == CARRIER ? (RootMotion)row : RootMotion.KEEP;
            bool root_yaw = turning && row >= 2 && row % 2 != 0;
            bool looping = turning && row >= 4;
            float playback_speed = turning && row >= 6 ? -1 : 1;
            uint variant = family.kind == ANATOMY || family.kind == FACING ? row : 0;
            build_fixture_row(
                row: &family.rows[row],
                kind: family.kind,
                variant: variant,
                mode: mode,
                scene: scene,
                assets: assets,
                joint_geometry: joint_geometry,
                bone_geometry: bone_geometry,
                reference_material: reference_material,
                actual_material: actual_material,
                row_height: (float)row * (turning ? 1.2f : 1.8f),
                root_yaw: root_yaw,
                looping: looping,
                playback_speed: playback_speed,
            )!;
            set_reference_pose(&family.rows[row], 0);
        }
    }

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.6f }.normalize(), WORLD_UP);
    scene.background = { .kind = COLOR, .color = { 0.04f, 0.05f, 0.07f, 1 } };
    Node* camera = scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!;
    camera.local.position = { 2, 8, 22 };
    camera.local.rotation = maths::look_rotation((Vec3){ 2, 2, 2 } - camera.local.position, WORLD_UP);
    scene.update_world();

    foreach (&family : families) {
        for (uint row = 0; row < family.count; row++) {
            update_bone_glyphs(&family.rows[row].reference, &family.rows[row].fixture);
            update_bone_glyphs(&family.rows[row].actual, &family.rows[row].fixture);
        }
    }

    scene.update_world();
    renderer.prepare_scene(scene)!;
    GuiRenderer gui = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    bool telemetry_enabled = telemetry_path.len != 0 || capture_directory.len != 0;
    File telemetry;
    if (telemetry_enabled) {
        @pool() {
            String destination = telemetry_path.len ? telemetry_path
                : string::tformat("%s/retarget-profile.csv", capture_directory);
            telemetry = file::open(destination, "w")!;
            io::printfn("retarget_telemetry=%s", destination);
        };
    }

    defer { if (telemetry_enabled) (void)telemetry.close(); }
    if (telemetry_enabled) io::fprintfn(&telemetry,
        "frame,wall_seconds,simulation_seconds,fixture_version,case_id,variant_id,mode_id,clip_time,is_key,node,expected_x,expected_y,expected_z,actual_x,actual_y,actual_z,position_error_m,rotation_error_rad,expected_scale,actual_scale,expected_root_x,expected_root_z,actual_root_x,actual_root_z,root_error_m,capture_index,root_yaw,looping,speed,cycles,facing_degrees,expected_root_qx,expected_root_qy,expected_root_qz,expected_root_qw,actual_root_qx,actual_root_qy,actual_root_qz,actual_root_qw,root_rotation_error_rad,expected_pivot_x,expected_pivot_y,expected_pivot_z,actual_pivot_x,actual_pivot_y,actual_pivot_z,pivot_error_m,carrier_relative,expected_carrier_relative_x,expected_carrier_relative_y,expected_carrier_relative_z,actual_carrier_relative_x,actual_carrier_relative_y,actual_carrier_relative_z,expected_carrier_relative_qx,expected_carrier_relative_qy,expected_carrier_relative_qz,expected_carrier_relative_qw,actual_carrier_relative_qx,actual_carrier_relative_qy,actual_carrier_relative_qz,actual_carrier_relative_qw,expected_carrier_relative_scale,actual_carrier_relative_scale,carrier_relative_position_error_m,carrier_relative_rotation_error_rad,carrier_relative_scale_error,root_radius_m,pivot_radius_m,pose_position_bound_m,pose_rotation_bound_rad,path_position_bound_m,root_rotation_bound_rad,world_scale_error")!;
    RenderTargetId capture_target;
    if (capture_directory.len) capture_target = render::create_render_target(
        renderer: renderer,
        desc: render::render_target_desc(CAPTURE_WIDTH, CAPTURE_HEIGHT, material::PixelFormat.RGBA8_SRGB),
    )!;
    defer { if (capture_directory.len) (void)render::destroy_render_target(renderer, capture_target); }
    ViewId capture_view;
    if (capture_directory.len) {
        ViewDesc desc = render::texture_view_desc(capture_target, OutputMode.DISPLAY_LDR);
        desc.post.anti_aliasing = AntiAliasing.FXAA;
        capture_view = render::create_view(renderer, desc)!;
    }

    defer { if (capture_directory.len) (void)render::destroy_view(renderer, capture_view); }
    char[] pixels;
    if (capture_directory.len) pixels = mem::new_array(char, CAPTURE_WIDTH * CAPTURE_HEIGHT * 4);
    defer free(pixels);

    Controls controls = { .automatic = true, .lines = true };
    Metrics metrics;
    float elapsed;
    float wall;
    double wall_start;
    float next_capture;
    uint captures;
    uint frame;
    io::printfn("retarget_fixture_version=%d generated_bake_rate=%.0f sample_step=%.9f", FIXTURE_VERSION, BAKE_RATE, SAMPLE_STEP);
    io::printn("expected left / profiled right; F next case, Space pause, A automatic, I axes; Escape quits");

    while (window.poll()) {
        if (frame == 0) wall_start = window.clock.total;
        if (frame_limit && frame >= frame_limit) break;
        wall = (float)(window.clock.total - wall_start);
        Input* input = &window.input;
        if (!input.keyboard_captured_by_gui) {
            if (input.key_released(Scancode.ESCAPE)) break;
            if (input.key_pressed(Scancode.SPACE)) controls.paused = !controls.paused;
            if (input.key_pressed(Scancode.A)) controls.automatic = !controls.automatic;
            if (input.key_pressed(Scancode.I)) controls.lines = !controls.lines;
            if (input.key_pressed(Scancode.F)) {
                controls.family = (controls.family + 1) % FIXTURE_FAMILIES;
                controls.automatic = false;
            }
        }

        float delta = acceptance ? SAMPLE_STEP : math::min(window.clock.delta, 1.0f / 30);
        float animation_dt = controls.paused ? 0 : delta;
        if (controls.automatic) {
            float phase = elapsed - math::floor(elapsed / PLAYBACK_CYCLE_SECONDS) * PLAYBACK_CYCLE_SECONDS;
            controls.family = phase < FAMILY_SECONDS * 4 ? (uint)(phase / FAMILY_SECONDS)
                : phase < FAMILY_SECONDS * 4 + TURN_FAMILY_SECONDS ? 4 : 5;
        }

        if (controls.family >= 4) {
            camera.local.position = { 6, 13, 35 };
            camera.local.rotation = maths::look_rotation((Vec3){ 6, 7, 3 } - camera.local.position, WORLD_UP);
        } else {
            camera.local.position = { 2, 8, 22 };
            camera.local.rotation = maths::look_rotation((Vec3){ 2, 2, 2 } - camera.local.position, WORLD_UP);
        }

        set_family_active(families[..], controls.family);
        advance_fixture_clocks(
            scene: scene,
            families: families[..],
            selected: controls.family,
            paused: controls.paused,
            dt: animation_dt,
        );
        anim::update(assets, scene, animation_dt);
        FixtureFamily* family = &families[controls.family];
        apply_fixture_motion(scene, family);

        for (uint row = 0; row < family.count; row++) set_reference_pose(&family.rows[row], row_time(scene, &family.rows[row]));
        scene.update_world();

        for (uint row = 0; row < family.count; row++) {
            FixtureRow* current = &family.rows[row];
            measure_row(current, row_time(scene, current), &metrics);
            if (turning_fixture(&current.fixture) && !current.looping
                && scene.get(current.actual.root, Animator).action(current.actual.action).speed < 0) {
                metrics.turn_reverse_seen[current.fixture.kind == TURN90 ? 0 : 1] = true;
            }

            update_bone_glyphs(&current.reference, &current.fixture);
            update_bone_glyphs(&current.actual, &current.fixture);
        }

        scene.update_world();
        elapsed += animation_dt;
        gui.new_frame();
        defer { if (gui.frame_open) gui.finish_frame(); }
        profile_panel(
            renderer: renderer,
            scene: scene,
            families: families[..],
            controls: &controls,
            metrics: &metrics,
        )!;
        debug.clear();
        if (controls.lines) draw_fixture(&debug, family);
        gui.finish_frame();
        bool capture_due = capture_directory.len != 0 && wall >= next_capture;
        platform::sync_window(window, renderer);
        bool captured = render_profile_frame(
            renderer: renderer,
            scene: scene,
            camera: camera,
            gui: &gui,
            debug: &debug,
            info: { .time = window.clock.total, .delta = delta },
            capture_view: capture_view,
            capture: capture_due,
        )!;
        int capture_index = -1;
        if (captured) {
            renderer.read_render_target(capture_target, pixels)!;
            @pool() {
                String destination = string::tformat("%s/retarget-profile-%06d.png", capture_directory, captures);
                image::write_png(
                    path: destination,
                    width: CAPTURE_WIDTH,
                    height: CAPTURE_HEIGHT,
                    pixels: pixels,
                )!;
                io::printfn("retarget_capture=%s frame=%d wall=%.6f simulation=%.6f case=%d",
                    destination, frame, wall, elapsed, controls.family);
            };
            capture_index = (int)captures++;
            next_capture += CAPTURE_INTERVAL;
        }

        if (telemetry_enabled) profile_csv(
            output: &telemetry,
            scene: scene,
            family: family,
            frame: frame,
            wall: wall,
            elapsed: elapsed,
            capture_index: capture_index,
        )!;
        if (frame % 120 == 0) {
            io::printfn("retarget_progress frame=%d wall=%.6f simulation=%.6f case=%d keys=%d subkeys=%d failed=%d",
                frame, wall, elapsed, controls.family, metrics.key_samples, metrics.subkey_samples, metrics.failures);
            if (telemetry_enabled) telemetry.flush()!;
        }

        frame++;
        if (acceptance && elapsed >= PLAYBACK_CYCLE_SECONDS && wall >= PLAYBACK_SECONDS) break;
    }

    if (telemetry_enabled) telemetry.flush()!;
    io::printfn("retarget_summary frames=%d wall=%.6f simulation=%.6f keys=%d subkeys=%d failures=%d captures=%d",
        frame, wall, elapsed, metrics.key_samples, metrics.subkey_samples, metrics.failures, captures);
    io::printfn("retarget_keys position=%.9f rotation_rad=%.9f scale=%.9f",
        metrics.max_key_position, metrics.max_key_rotation, metrics.max_key_scale);
    io::printfn("retarget_subkeys position=%.9f rotation_rad=%.9f root=%.9f root_rotation=%.9f pivot=%.9f",
        metrics.max_subkey_position, metrics.max_subkey_rotation, metrics.max_root_error,
        metrics.max_root_rotation, metrics.max_pivot_error);
    io::printfn("retarget_carrier_keys samples=%d position=%.9f rotation_rad=%.9f scale=%.9f",
        metrics.carrier_key_samples, metrics.max_carrier_key_position,
        metrics.max_carrier_key_rotation, metrics.max_carrier_key_scale);
    io::printfn("retarget_carrier_subkeys samples=%d position=%.9f rotation_rad=%.9f scale=%.9f",
        metrics.carrier_subkey_samples, metrics.max_carrier_subkey_position,
        metrics.max_carrier_subkey_rotation, metrics.max_carrier_subkey_scale);
    io::printfn("retarget_accumulation root_drift=%.9f pivot_drift=%.9f root_rotation=%.9f root_radius=%.9f pivot_radius=%.9f position_bound=%.9f",
        metrics.max_root_error, metrics.max_pivot_error, metrics.max_root_rotation,
        metrics.max_root_radius, metrics.max_pivot_radius, ACCUMULATED_POSITION_BOUND);

    renderer.log.check_validation()!;
    bool complete = metrics.key_samples != 0 && metrics.subkey_samples != 0 && metrics.failures == 0
        && metrics.carrier_key_samples != 0 && metrics.carrier_subkey_samples != 0;

    foreach (seen : metrics.families_seen) complete &= seen;

    foreach (seen : metrics.modes_seen) complete &= seen;

    foreach (flags : metrics.turn_yaw_seen) foreach (seen : flags) complete &= seen;

    foreach (seen : metrics.turn_reverse_seen) complete &= seen;

    foreach (seen : metrics.turn_loop_seen) complete &= seen;

    foreach (seen : metrics.turn_reverse_loop_seen) complete &= seen;
    if (acceptance && (!complete || elapsed < PLAYBACK_CYCLE_SECONDS || wall < PLAYBACK_SECONDS)) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn int main(String[] args) {
    uint frame_limit;
    bool acceptance;
    bool mixamo;
    String capture_directory;
    String telemetry_path;

    foreach (argument : args[1..]) {
        if (argument == "--mixamo") {
            mixamo = true;
        } else if (argument == "--acceptance") {
            acceptance = true;
        } else if (argument.starts_with("--frames=")) {
            frame_limit = argument[9..].to_uint()!!;
        } else if (argument.starts_with("--capture-dir=")) {
            capture_directory = argument[14..];
            if (!capture_directory.len) return 1;
        } else if (argument.starts_with("--telemetry=")) {
            telemetry_path = argument[12..];
            if (!telemetry_path.len) return 1;
        } else {
            io::eprintfn("Unknown option: %s", argument);

            return 1;
        }
    }

    if (mixamo) {
        if (acceptance || capture_directory.len || telemetry_path.len) {
            io::eprintn("Profile metrics and rendered exports use the default authored fixtures.");

            return 1;
        }

        return run_mixamo(frame_limit);
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d calibrated retarget", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "c3d_retarget" },
    )!!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, { .max_nodes = FIXTURE_SCENE_NODES });
    defer scene::destroy_scene(&scene);
    if (catch excuse = run_profile(
        window: &window,
        renderer: &renderer,
        assets: &assets,
        scene: &scene,
        frame_limit: frame_limit,
        acceptance: acceptance,
        capture_directory: capture_directory,
        telemetry_path: telemetry_path,
    )) {
        io::eprintfn("retarget example failed: %s", excuse);

        return 1;
    }

    return 0;
}
