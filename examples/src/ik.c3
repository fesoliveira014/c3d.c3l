module ik_example;

import std::io;
import std::io::path;
import std::io::file;
import std::math;
import std::core::string;
import c3d;
import c3d::anim;
import c3d::anim::ik;
import c3d::asset;
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

const String MODEL_FILE @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String IDLE_CLIP @local = "Idle_Loop";
const String WALK_CLIP @local = "Walk_Loop";
const uint SCENE_NODE_CAPACITY @local = 256; // two 55-node characters, IK targets, ground, support, camera and light
const float TERRAIN_SIZE @local = 16;
const uint TERRAIN_SEGMENTS @local = 128; // 12.5 cm cells; finer than a foot, so the mesh matches the analytic ground
const float TERRAIN_AMPLITUDE @local = 0.15f;
const float TERRAIN_FREQUENCY @local = 1.2f; // radians per metre; feet a stride apart differ visibly in height
const float CHARACTER_START_X @local = 1.3f; // metres; the walk crosses crests there, not the flat midline
const float WALK_SPEED @local = 1.1f; // metres per second; roughly the clip's stride rate, so feet slide little
const float CROSS_FADE_SECONDS @local = 0.3f;
const float WEIGHT_STEP @local = 0.25f;
const float KNEE_POLE_DISTANCE @local = 0.5f;
const float ELBOW_POLE_DISTANCE @local = 0.4f;
const float ELBOW_POLE_DROP @local = 0.1f;
const float PROP_REACH @local = 0.3f; // metres in front of the hand's idle position
const float PROP_LIFT @local = 0.35f; // metres above it; chest height makes the reach visible
const float PROP_ORBIT_RADIUS @local = 0.15f;
const float PROP_ORBIT_SPEED @local = 1.5f; // radians per second
const float PROP_RADIUS @local = 0.04f;
const float KNEE_FLEX_LIMIT @local = 2.4f; // radians from rest; clips bend to 1.46, the rest is room for the solve
const float LOOK_MAX_ANGLE @local = 1.4f; // radians over spine, neck and head; past it a person turns the feet
const String[5] LOOK_JOINTS @local = { "DEF-spine.001", "DEF-spine.002", "DEF-spine.003", "DEF-neck", "DEF-head" };
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_MIN_DISTANCE @local = 0.5f;
const float ORBIT_START_DISTANCE @local = 3.5f;
const float ORBIT_START_YAW @local = 0.7f; // radians from the character's facing; the sunlit front quarter
const float ORBIT_START_PITCH @local = 0.25f;
const float ORBIT_MAX_DISTANCE @local = 20;
const Vec3 ORBIT_TARGET_OFFSET @local = { 0, 1, 0 };
const Vec3 WORLD_UP @local = { 0, 1, 0 };
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 400, 560 };
const Vec2 STATS_PANEL_POSITION @local = { 924, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 340, 300 };

const float CONTACT_PLAYBACK_SECONDS @local = 20;
const float CONTACT_SUPPORT_PERIOD @local = 10;
const float CONTACT_CUE_PERIOD @local = 4;
const float CONTACT_BODY_DROP @local = 0.2f;
const float CONTACT_REACH_MARGIN @local = 0.025f;
const float CONTACT_SWING_CLEARANCE @local = 0.12f;
const float CONTACT_SWING_ARC @local = 0.04f;
const float CONTACT_SWING_CLEARANCE_BOUND @local = 0.05f;
const float CONTACT_RELEASE_START @local = 1.4f;
const float CONTACT_SWING_START @local = 1.6f;
const float CONTACT_SECOND_PLANT_START @local = 2;
const float CONTACT_SECOND_RELEASE_START @local = 2.8f;
const float CONTACT_REPLANT_START @local = 2.9f;
const float CONTACT_INSTANCE_SPACING @local = 1;
const float CONTACT_CAPTURE_INTERVAL @local = 2;
const uint CONTACT_CAPTURE_WIDTH @local = 960;
const uint CONTACT_CAPTURE_HEIGHT @local = 540;
const float CONTACT_RESIDUAL_BOUND @local = 0.001f;
const float CONTACT_ANGLE_BOUND @local = 1;
const uint CONTACT_INSTANCES @local = 2;
const Vec3 CONTACT_REBASE_OFFSET @local = { 256, 0, -512 };

enum FootCue @local {
    PLANT,
    RELEASE,
    SWING,
    SECOND_PLANT,
    SECOND_RELEASE,
    REPLANT,
}

struct Orbit @local {
    float distance;
    float yaw;
    float pitch;
}

struct Controls @local {
    float legs;
    float arm;
    float look;
    bool  lines;
    bool  walking;
    bool  contact;
    bool  limits;
    bool  paused;
    bool  mode_changed;
    bool  walk_changed;
    bool  rebase_requested;
}

struct Character @local {
    Node*    root;
    Node*    hips;
    Node*[2] thighs;
    Node*    upper_arm;
    Node*    head;
    Node*    prop;
    Vec3     prop_center;   // character-root space
    Vec3     facing;        // character-root space, horizontal, unit
    ClipId   idle;
    ClipId   walk;
    float    prop_angle;
    float[2] legacy_heights;
    IkLimit[2] knee_limits;
    float[2] contact_heights;
    FootCue[2] cues;
    bool[2] cue_initialized;
    FootContactResult[2] results;
    float[2] reach_margins;
    float[2] inner_margins;
    float[2] incoming_clearances;
    float[2] actual_clearances;
    uint[2] begins;
    uint[2] ends;
}

struct ContactDemo @local {
    Node* platform;
    FootSupport support;
    Vec3 origin_offset;
    float elapsed;
    bool script_paused;
    bool rebased;
    uint rebase_count;
    uint planted_samples;
    uint failed_samples;
    uint swing_samples;
    uint failed_swing_samples;
    float min_swing_clearance;
    float max_residual;
    float max_normal_error;
    float max_heading_error;
    float min_reach_margin;
    float min_inner_margin;
}

fn float terrain_height(float x, float z) @local {
    return TERRAIN_AMPLITUDE * math::sin(TERRAIN_FREQUENCY * x) * math::cos(TERRAIN_FREQUENCY * z);
}

fn Vec3 terrain_normal(float x, float z) @local {
    float slope = TERRAIN_AMPLITUDE * TERRAIN_FREQUENCY;
    float dx = slope * math::cos(TERRAIN_FREQUENCY * x) * math::cos(TERRAIN_FREQUENCY * z);
    float dz = -slope * math::sin(TERRAIN_FREQUENCY * x) * math::sin(TERRAIN_FREQUENCY * z);
    return (Vec3){ -dx, 1, -dz }.normalize();
}

fn GroundHit? terrain_hit(Ray ray, float length, Vec3 origin_offset) @local {
    float x = ray.origin.x + origin_offset.x;
    float z = ray.origin.z + origin_offset.z;
    Vec3 point = { ray.origin.x, terrain_height(x, z), ray.origin.z };
    if (point.y < ray.origin.y - length) return NOT_FOUND~;
    return { .point = point, .normal = terrain_normal(x, z) };
}

fn void? build_level(AssetStore* assets, Scene* scene) @local {
    GeometryId terrain_geometry;
    MaterialId terrain_material;
    @pool() {
        Geometry terrain = geometry::plane(
            allocator:  tmem,
            width:      TERRAIN_SIZE,
            depth:      TERRAIN_SIZE,
            segments_x: TERRAIN_SEGMENTS,
            segments_z: TERRAIN_SEGMENTS,
        );
        foreach (index, &position : terrain.positions) {
            position.y = terrain_height(position.x, position.z);
            terrain.normals[index] = terrain_normal(position.x, position.z);
        }
        terrain.finalize();
        TangentGeometry tangent_terrain = geometry::create_tangent_geometry(assets.allocator, &terrain)!;
        defer geometry::destroy_tangent_geometry(&tangent_terrain);
        terrain_geometry = assets.add_tangent_geometry_owned(&tangent_terrain, "ik/terrain")!;
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color = { 0.45f, 0.55f, 0.4f, 1 };
        params.metallic = 0;
        params.roughness = 0.9f;
        terrain_material = assets.add_material(material::standard(params), "ik/terrain_material")!;
    };
    scene.add_mesh(terrain_geometry, terrain_material, name: "terrain")!;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), WORLD_UP);
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
}

fn ClipId? find_clip(AssetStore* assets, ClipId[] clips, String name) @local {
    foreach (clip : clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Vec3 to_root(Character* character, Vec3 world_position) @local {
    return maths::transform_point(maths::inverse_affine(character.root.world), world_position);
}

fn Node*? character_node(Scene* scene, Character* character, String name) @local {
    ModelInstance* instance = scene.get(character.root, ModelInstance);
    for (usz index = 0; index < instance.nodes.len; index++) {
        Node* node = instance.present_node(index);
        if (node && node.name == name) return node;
    }
    return NOT_FOUND~;
}

fn void? add_foot(
    Scene* scene,
    Character* character,
    Skeleton* skeleton,
    usz side,
    String thigh,
    String shin,
    String foot,
) @local {
    Node* thigh_node = character_node(scene, character, thigh)!;
    Node* shin_node = character_node(scene, character, shin)!;
    Node* foot_node = character_node(scene, character, foot)!;
    Node* target = scene.add_node(character.root, "foot_target")!;
    Node* pole = scene.add_node(character.root, "knee_pole")!;
    pole.local.position = to_root(character, shin_node.world_position()) + character.facing * KNEE_POLE_DISTANCE;

    FootIk foot_ik = ik::foot_ik(
        hip:    thigh_node,
        knee:   shin_node,
        ankle:  foot_node,
        target: target,
        pole:   pole,
    );
    foot_ik.leg.limits[1] = ik::hinge_limit(
        reference:  skeleton.rest_pose[skeleton.find_joint(shin)!].rotation,
        axis:       { 1, 0, 0 },
        min_angle:  0,
        max_angle:  KNEE_FLEX_LIMIT,
        twist_axis: { 0, 1, 0 },
    );
    Quat reference = maths::transform_from_mat4(foot_node.world).rotation;
    Vec3 facing = maths::transform_dir(character.root.world, character.facing).normalize();
    foot_ik.plant.sole_up = (reference.conjugate() * WORLD_UP).normalize();
    foot_ik.plant.sole_forward = (reference.conjugate() * facing).normalize();
    foot_ik.plant.validate()!;
    character.legacy_heights[side] = foot_ik.foot_height;
    character.knee_limits[side] = foot_ik.leg.limits[1];
    character.contact_heights[side] = math::max(foot_node.world_position().y - character.root.world_position().y, 0.0f);
    scene.add(thigh_node, foot_ik);
    character.thighs[side] = thigh_node;
}

fn Character? build_character(
    AssetStore* assets,
    Scene* scene,
    ModelId model,
    uint index,
) @local {
    Character character = { .root = model::instantiate(assets, scene, model, name: "character")! };
    float initial_x = CHARACTER_START_X - (float)index * 1.5f;
    character.root.local.position = { initial_x, terrain_height(initial_x, 0), 0 };
    ModelInstance* instance = scene.get(character.root, ModelInstance);
    character.idle = find_clip(assets, instance.clips, IDLE_CLIP)!;
    character.walk = find_clip(assets, instance.clips, WALK_CLIP)!;
    Skeleton* skeleton;
    for (usz node_index = 0; node_index < instance.nodes.len; node_index++) {
        Node* node = instance.present_node(node_index);
        if (!node) continue;
        if (!scene.has(node, SkinBinding)) continue;
        SkinBinding* skin = scene.get(node, SkinBinding);
        io::printfn("%s: %d skin joints", MODEL_FILE, skin.joints.len);
        skeleton = &assets.skeleton(skin.skeleton).data;
        break;
    }
    anim::add_animator(scene, character.root).play(assets, character.idle)!;
    anim::update(assets, scene, 0);
    scene.update_world();

    character.hips = character_node(scene, &character, "DEF-hips")!;
    character.upper_arm = character_node(scene, &character, "DEF-upper_arm.R")!;
    character.head = character_node(scene, &character, "DEF-head")!;
    Vec3 toe = character_node(scene, &character, "DEF-toe.L")!.world_position() - character_node(scene, &character, "DEF-foot.L")!.world_position();
    character.facing = (Vec3){ toe.x, 0, toe.z }.normalize();

    add_foot(
        scene:     scene,
        character: &character,
        skeleton:  skeleton,
        side:      0,
        thigh:     "DEF-thigh.L",
        shin:      "DEF-shin.L",
        foot:      "DEF-foot.L",
    )!;
    add_foot(
        scene:     scene,
        character: &character,
        skeleton:  skeleton,
        side:      1,
        thigh:     "DEF-thigh.R",
        shin:      "DEF-shin.R",
        foot:      "DEF-foot.R",
    )!;

    Node* forearm = character_node(scene, &character, "DEF-forearm.R")!;
    Node* hand = character_node(scene, &character, "DEF-hand.R")!;
    character.prop_center = to_root(&character, hand.world_position()) + character.facing * PROP_REACH
        + WORLD_UP * PROP_LIFT;
    Node* elbow_pole = scene.add_node(character.root, "elbow_pole")!;
    elbow_pole.local.position = to_root(&character, forearm.world_position())
        - character.facing * ELBOW_POLE_DISTANCE - WORLD_UP * ELBOW_POLE_DROP;
    GeometryId prop_geometry;
    if (try existing = assets.find_geometry("ik/prop")) {
        prop_geometry = existing;
    } else {
        @pool() {
            Geometry sphere = geometry::sphere(tmem, PROP_RADIUS);
            prop_geometry = assets.add_geometry(&sphere, "ik/prop")!;
        };
    }
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.9f, 0.5f, 0.15f, 1 };
    MaterialId prop_material;
    if (try existing = assets.find_material("ik/prop_material")) {
        prop_material = existing;
    } else {
        prop_material = assets.add_material(material::standard(params), "ik/prop_material")!;
    }
    character.prop = scene.add_mesh(prop_geometry, prop_material, character.root, "prop")!;
    IkChain arm = ik::ik_chain(
        root:   character.upper_arm,
        middle: forearm,
        end:    hand,
        target: character.prop,
        pole:   elbow_pole,
    );
    scene.add(character.upper_arm, arm);
    return character;
}

fn void? add_look(Scene* scene, Character* character, Node* camera_node) @local {
    Node*[LOOK_JOINTS.len] spine;
    foreach (index, name : LOOK_JOINTS) spine[index] = character_node(scene, character, name)!;
    Vec3 facing_world = maths::transform_dir(character.root.world, character.facing).normalize();
    Quat head_world = maths::transform_from_mat4(character.head.world).rotation;
    LookAt look_at = ik::look_at(spine[..], camera_node, head_world.conjugate() * facing_world);
    look_at.max_angle = LOOK_MAX_ANGLE;
    scene.add(character.head, look_at);
}

fn void handle_keys(Input* input, Controls* controls) @local {
    if (input.keyboard_captured_by_gui) return;
    if (input.key_pressed(platform::Scancode.W)) {
        controls.walking = !controls.walking;
        controls.walk_changed = true;
    }
    float step;
    if (input.key_pressed(platform::Scancode.LEFTBRACKET)) step = -WEIGHT_STEP;
    if (input.key_pressed(platform::Scancode.RIGHTBRACKET)) step = WEIGHT_STEP;
    if (step != 0) {
        controls.legs = math::clamp(controls.legs + step, 0.0f, 1.0f);
        controls.arm = math::clamp(controls.arm + step, 0.0f, 1.0f);
        controls.look = math::clamp(controls.look + step, 0.0f, 1.0f);
    }
    if (input.key_pressed(platform::Scancode.I)) controls.lines = !controls.lines;
    if (input.key_pressed(platform::Scancode.L)) controls.limits = !controls.limits;
    if (input.key_pressed(platform::Scancode.C)) {
        controls.contact = !controls.contact;
        controls.mode_changed = true;
    }
    if (input.key_pressed(platform::Scancode.SPACE)) controls.paused = !controls.paused;
    if (input.key_pressed(platform::Scancode.R)) controls.rebase_requested = true;
}

fn void change_walk(
    AssetStore* assets,
    Scene* scene,
    Character* character,
    bool walking,
) @local {
    Animator* animator = scene.get(character.root, Animator);
    AnimationActionId previous = animator.order[animator.action_count - 1];
    AnimationActionId next = animator.play(
        assets: assets,
        clip: walking ? character.walk : character.idle,
        desc: { .fade_in = CROSS_FADE_SECONDS },
    )!!;
    animator.cross_fade(previous, next, CROSS_FADE_SECONDS)!!;
}

fn void move_character(
    Character* character,
    Controls* controls,
    float delta_seconds,
    Vec3 origin_offset,
) @local {
    Vec3 absolute = character.root.local.position + origin_offset;
    Vec3* position = &absolute;
    if (controls.walking) {
        *position += character.facing * (WALK_SPEED * delta_seconds);
        float half = TERRAIN_SIZE * 0.5f - 1;
        if (math::abs(position.x) > half) position.x = -position.x;
        if (math::abs(position.z) > half) position.z = -position.z;
    }
    position.y = terrain_height(position.x, position.z);
    character.root.local.position = *position - origin_offset;
    character.root.local.rotation = quaternion::IDENTITY;

    character.prop_angle += PROP_ORBIT_SPEED * delta_seconds;
    Vec3 side = WORLD_UP.cross(character.facing);
    character.prop.local.position = character.prop_center
        + (side * math::cos(character.prop_angle) + WORLD_UP * math::sin(character.prop_angle)) * PROP_ORBIT_RADIUS;
}

fn float solve_legacy(
    Scene* scene,
    Character* character,
    Controls* controls,
    Vec3 origin_offset,
) @local {
    float floor_height = character.root.world_position().y;
    FootIk*[2] feet;
    foreach (side, thigh : character.thighs) {
        FootIk* foot = scene.get(thigh, FootIk);
        foot.leg.weight = controls.legs;
        foot.foot_height = character.legacy_heights[side];
        foot.leg.limits[1] = character.knee_limits[side];
        Ray ray = foot.ground_ray();
        if (try hit = terrain_hit(ray, foot.ray_length, origin_offset)) {
            foot.place(hit, floor_height);
        } else {
            foot.release();
        }
        feet[side] = foot;
    }
    float drop = ik::lower_pelvis(character.hips, feet[..]);
    scene.update_world();

    // The arm hangs off the upper spine, so the look turns the chest before the arm reads it.
    LookAt* look = scene.get(character.head, LookAt);
    look.weight = controls.look;
    look.solve();
    scene.update_world();

    foreach (foot : feet) foot.leg.solve();
    IkChain* arm = scene.get(character.upper_arm, IkChain);
    arm.weight = controls.arm;
    arm.solve();
    scene.update_world();

    foreach (foot : feet) foot.align();
    scene.update_world();
    return drop;
}

fn float cycle_time(float seconds, float period) @local {
    return seconds - math::floor(seconds / period) * period;
}

fn FootCue contact_cue(float seconds) @local {
    float phase = cycle_time(seconds, CONTACT_CUE_PERIOD);
    if (phase < CONTACT_RELEASE_START) return PLANT;
    if (phase < CONTACT_SWING_START) return RELEASE;
    if (phase < CONTACT_SECOND_PLANT_START) return SWING;
    if (phase < CONTACT_SECOND_RELEASE_START) return SECOND_PLANT;
    if (phase < CONTACT_REPLANT_START) return SECOND_RELEASE;
    return REPLANT;
}

fn ZString contact_phase_name(FootContactPhase phase) @local {
    switch (phase) {
        case INACTIVE: return "inactive";
        case ACQUIRING: return "acquiring";
        case PLANTED: return "planted";
        case RELEASING: return "releasing";
    }
}

fn ZString contact_status_name(FootContactStatus status) @local {
    switch (status) {
        case NO_TARGET: return "no target";
        case REACHED: return "reached";
        case MISSED: return "missed";
    }
}

fn Node*? build_support(AssetStore* assets, Scene* scene) @local {
    GeometryId geometry_id;
    @pool() {
        Geometry support = geometry::plane(tmem, 3, 3);
        geometry_id = assets.add_geometry(&support, "ik/support")!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.2f, 0.45f, 0.65f, 1 };
    params.metallic = 0;
    params.roughness = 0.8f;
    MaterialId material_id = assets.add_material(material::standard(params), "ik/support_material")!;
    return scene.add_mesh(geometry_id, material_id, name: "contact_support");
}

fn void move_support(ContactDemo* demo, Character[] characters) @local {
    float phase = cycle_time(demo.elapsed, CONTACT_SUPPORT_PERIOD) / CONTACT_SUPPORT_PERIOD;
    float angle = phase * 2 * (float)math::PI;
    float excursion = 0.5f - 0.5f * math::cos(angle);
    float scale = 0.5f + 1.5f * excursion;
    Vec3 tilt_axis = cycle_time(demo.elapsed, CONTACT_SUPPORT_PERIOD * 2) < CONTACT_SUPPORT_PERIOD
        ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 0, 1 };
    Quat yaw = quaternion::from_axis_angle{float}(WORLD_UP, 30 * excursion * (float)math::PI / 180);
    Quat tilt = quaternion::from_axis_angle{float}(tilt_axis, 20 * math::sin(angle) * (float)math::PI / 180);
    demo.support = {
        .identity = 17,
        .kind = SUPPORT,
        .transform = {
            .position = (Vec3){ 0.5f * excursion, 2, 0 } - demo.origin_offset,
            .rotation = (yaw * tilt).normalize(),
            .scale = { scale, scale, scale },
        },
    };
    demo.platform.local = demo.support.transform;
    demo.platform.visible = true;
    Vec3 normal = demo.support.transform.rotation * WORLD_UP;
    foreach (index, &character : characters) {
        float x = ((float)index * 2 - 1) * CONTACT_INSTANCE_SPACING;
        Vec3 center = maths::transform_point(demo.support.transform.to_mat4(), { x, 0, 0 });
        Vec3 sway = demo.support.transform.rotation
            * (Vec3){ 0.03f * math::sin(demo.elapsed), 0, 0.03f * math::sin(demo.elapsed * 0.7f) };
        character.root.local.position = center - normal * CONTACT_BODY_DROP + sway;
        character.root.local.rotation = demo.support.transform.rotation;
        character.prop.local.position = character.prop_center;
    }
}

fn void shift_contact_demo(
    Renderer* renderer,
    Scene* scene,
    ContactDemo* demo,
) @local {
    scene.shift_origin(CONTACT_REBASE_OFFSET);
    scene.update_world();
    scene.shift_foot_contacts(CONTACT_REBASE_OFFSET);
    renderer.shift_origin(scene, CONTACT_REBASE_OFFSET);
    demo.origin_offset += CONTACT_REBASE_OFFSET;
    demo.rebase_count++;
    io::printfn("contact_rebase count=%d offset=%s", demo.rebase_count, CONTACT_REBASE_OFFSET);
}

fn void? pose_contact_swing(Scene* scene, Character[] characters, ContactDemo* demo) @local {
    Vec3 normal = (demo.support.transform.rotation * WORLD_UP).normalize();
    foreach (index, &character : characters) {
        foreach (side, thigh : character.thighs) {
            FootIk* foot = scene.get(thigh, FootIk);
            Node* ankle = foot.leg.joints[2];
            Transform incoming = maths::transform_from_mat4(ankle.world);
            float phase = cycle_time(demo.elapsed + (float)index * 0.6f + (float)side * 0.3f, CONTACT_CUE_PERIOD);
            float clearance = CONTACT_SWING_CLEARANCE;
            if (phase >= CONTACT_SWING_START && phase < CONTACT_SECOND_PLANT_START) {
                float progress = (phase - CONTACT_SWING_START) / (CONTACT_SECOND_PLANT_START - CONTACT_SWING_START);
                float arc = math::sin(progress * (float)math::PI);
                clearance += CONTACT_SWING_ARC * arc * arc;
            }
            Vec3 point = incoming.position - normal * (incoming.position - demo.support.transform.position).dot(normal);
            Vec3 swing_position = point + normal * (character.contact_heights[side] + clearance);
            Transform target = foot.leg.target.local;
            foot.leg.target.set_world_position(swing_position);
            scene.update_world();
            IkChain pose_chain = foot.leg;
            pose_chain.weight = 1;
            foreach (&limit : pose_chain.limits) limit.kind = NONE;
            pose_chain.solve();
            scene.update_world();
            Quat parent = maths::transform_from_mat4(ankle.transform_basis()).rotation;
            ankle.local.rotation = (parent.conjugate() * incoming.rotation).normalize();
            foot.leg.target.local = target;
            scene.update_world();
            Transform posed = maths::transform_from_mat4(ankle.world);
            if ((posed.position - swing_position).length() > CONTACT_RESIDUAL_BOUND) {
                return c3d::INVALID_ARGUMENT~;
            }
            Vec3 sole = posed.position - posed.rotation * foot.plant.sole_up * character.contact_heights[side];
            character.incoming_clearances[side] = (sole - demo.support.transform.position).dot(normal);
        }
    }
}

fn void? solve_contacts(
    Scene* scene,
    Character* character,
    Controls* controls,
    ContactDemo* demo,
    uint instance_index,
    float dt,
) @local {
    FootIk*[2] feet;
    Vec3 normal = (demo.support.transform.rotation * WORLD_UP).normalize();
    foreach (side, thigh : character.thighs) {
        FootIk* foot = scene.get(thigh, FootIk);
        foot.leg.weight = controls.legs;
        foot.foot_height = character.contact_heights[side];
        foot.leg.limits[1] = controls.limits ? character.knee_limits[side] : (IkLimit){ .kind = NONE };
        FootCue cue = contact_cue(demo.elapsed + (float)instance_index * 0.6f + (float)side * 0.3f);
        if (!character.cue_initialized[side] || cue != character.cues[side]) {
            character.cues[side] = cue;
            character.cue_initialized[side] = true;
            switch (cue) {
                case PLANT:
                case SECOND_PLANT:
                case REPLANT:
                    Vec3 ankle = foot.leg.joints[2].world_position();
                    GroundHit hit = {
                        .point = ankle - normal * (ankle - demo.support.transform.position).dot(normal),
                        .normal = normal,
                    };
                    foot.begin_contact(hit, demo.support, demo.support.transform.position.y)!;
                    character.begins[side]++;
                case RELEASE:
                case SECOND_RELEASE:
                    foot.end_contact(demo.support, demo.support.transform.position.y)!;
                    character.ends[side]++;
                case SWING:
                    break;
            }
        }
        foot.update_contact(demo.support, dt, demo.support.transform.position.y)!;
        Vec3 hip = foot.leg.joints[0].world_position();
        Vec3 knee = foot.leg.joints[1].world_position();
        Vec3 ankle = foot.leg.joints[2].world_position();
        float upper = (knee - hip).length();
        float lower = (ankle - knee).length();
        float reach = (foot.contact.requested.position - hip).length();
        character.reach_margins[side] = upper + lower - reach;
        character.inner_margins[side] = reach - math::abs(upper - lower);
        feet[side] = foot;
    }
    scene.update_world();
    LookAt* look = scene.get(character.head, LookAt);
    look.weight = controls.look;
    look.solve();
    scene.update_world();
    foreach (foot : feet) foot.leg.solve();
    IkChain* arm = scene.get(character.upper_arm, IkChain);
    arm.weight = controls.arm;
    arm.solve();
    scene.update_world();
    foreach (foot : feet) foot.align_contact();
    scene.update_world();
    foreach (side, foot : feet) {
        FootContactResult result = foot.contact_result();
        character.results[side] = result;
        Transform actual = maths::transform_from_mat4(foot.leg.joints[2].world);
        Vec3 sole = actual.position - actual.rotation * foot.plant.sole_up * character.contact_heights[side];
        float clearance = (sole - demo.support.transform.position).dot(normal);
        character.actual_clearances[side] = clearance;
        if (result.phase == INACTIVE) {
            demo.swing_samples++;
            demo.min_swing_clearance = math::min(demo.min_swing_clearance, clearance);
            if (!math::is_finite(clearance) || clearance < CONTACT_SWING_CLEARANCE_BOUND) demo.failed_swing_samples++;
        }
        if (result.phase != PLANTED) continue;
        demo.planted_samples++;
        demo.max_residual = math::max(demo.max_residual, result.residual);
        demo.max_normal_error = math::max(demo.max_normal_error, result.normal_error_degrees);
        demo.max_heading_error = math::max(demo.max_heading_error, result.heading_error_degrees);
        demo.min_reach_margin = math::min(demo.min_reach_margin, character.reach_margins[side]);
        demo.min_inner_margin = math::min(demo.min_inner_margin, character.inner_margins[side]);
        bool failed = !math::is_finite(result.residual) || !math::is_finite(result.normal_error_degrees)
            || !math::is_finite(result.heading_error_degrees) || result.residual > CONTACT_RESIDUAL_BOUND
            || result.normal_error_degrees > CONTACT_ANGLE_BOUND || result.heading_error_degrees > CONTACT_ANGLE_BOUND
            || foot.leg.weight != 1 || character.reach_margins[side] < CONTACT_REACH_MARGIN
            || character.inner_margins[side] < CONTACT_REACH_MARGIN;
        if (failed) demo.failed_samples++;
    }
}

fn void draw_contact_targets(debug::DebugDraw* debug, Scene* scene, Character[] characters) @local {
    foreach (&character : characters) {
        foreach (thigh : character.thighs) {
            FootIk* foot = scene.get(thigh, FootIk);
            if (foot.contact.phase == INACTIVE) continue;
            debug.line(
                from: foot.leg.joints[2].world_position(),
                to: foot.contact.requested.position,
                rgba: debug::COLOR_RED,
            );
            debug.line(
                from: foot.ground.point,
                to: foot.ground.point + foot.ground.normal * 0.2f,
                rgba: debug::COLOR_GREEN,
            );
        }
    }
}

fn void print_calibration(Scene* scene, Character[] characters) @local {
    io::printfn("contact_source=%s reference=Idle_Loop:0 sole_up=world_Y forward=toe_heading", MODEL_FILE);
    foreach (index, &character : characters) {
        foreach (side, thigh : character.thighs) {
            FootIk* foot = scene.get(thigh, FootIk);
            io::printfn("contact_calibration instance=%d side=%d height=%.9f up=(%.9f,%.9f,%.9f) forward=(%.9f,%.9f,%.9f)",
                index, side, character.contact_heights[side],
                foot.plant.sole_up.x, foot.plant.sole_up.y, foot.plant.sole_up.z,
                foot.plant.sole_forward.x, foot.plant.sole_forward.y, foot.plant.sole_forward.z);
        }
    }
}

fn void? write_telemetry(
    File* output,
    Scene* scene,
    Character[] characters,
    ContactDemo* demo,
    uint frame,
    float wall_seconds,
    float dt,
    bool paused,
    int capture_index,
) @local {
    foreach (index, &character : characters) {
        foreach (side, thigh : character.thighs) {
            FootIk* foot = scene.get(thigh, FootIk);
            FootContactResult result = character.results[side];
            Vec3 requested = foot.contact.requested.position;
            Vec3 actual = foot.leg.joints[2].world_position();
            io::fprintfn(output,
                "%d,%.9f,%.9f,%.9f,%d,%d,%d,%d,%.9f,%.9f,%.9f,%.9f,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%d,%d,%d,%d,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f",
                frame, wall_seconds, demo.elapsed, dt, index, side, result.phase.ordinal, result.status.ordinal,
                result.residual, result.normal_error_degrees, result.heading_error_degrees, foot.leg.weight, foot.leg.limits[1].kind.ordinal,
                character.reach_margins[side], character.inner_margins[side],
                character.incoming_clearances[side], character.actual_clearances[side], demo.support.transform.scale.x,
                paused ? 1 : 0, demo.rebase_count, capture_index, character.begins[side], character.ends[side],
                foot.contact.local_point.x, foot.contact.local_point.y, foot.contact.local_point.z,
                requested.x, requested.y, requested.z, actual.x, actual.y, actual.z)!;
        }
    }
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node, Vec3 target) @local {
    if (!input.mouse_captured_by_gui && input.button_down(platform::MouseButton.LEFT)) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (!input.mouse_captured_by_gui && input.wheel != 0) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, WORLD_UP);
}

fn void? draw_panel(
    Renderer* renderer,
    Scene* scene,
    Character[] characters,
    Controls* controls,
    ContactDemo* demo,
    float drop,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Inverse kinematics", null, {})) {
        imgui::text("W walk/idle, [ ] weights, I lines");
        imgui::text("C contact/legacy, L knee limits, Space pause, R rebase");
        imgui::text("Drag orbits, wheel zooms, Escape quits");
        controls.mode_changed |= imgui::checkbox("Contact demo", &controls.contact);
        imgui::checkbox("Pause animation and contact clocks", &controls.paused);
        imgui::checkbox("Authored knee hinges", &controls.limits);
        imgui::text("Knees: %s", !controls.contact || controls.limits ? "authored hinges" : "unconstrained");
        controls.walk_changed |= imgui::checkbox("Walk", &controls.walking);
        imgui::slider_float("Legs", &controls.legs, 0, 1);
        imgui::slider_float("Arm", &controls.arm, 0, 1);
        imgui::slider_float("Look", &controls.look, 0, 1);
        imgui::checkbox("Lines", &controls.lines);
        imgui::separator();
        imgui::text("CC0 Quaternius / Idle_Loop reference");
        imgui::text("Script %.2fs, support scale %.3f", demo.elapsed, demo.support.transform.scale.x);
        imgui::text("Zero step: %s, rebases: %u", demo.script_paused || controls.paused ? "yes" : "no", demo.rebase_count);
        ZString[2] sides = { "Left", "Right" };
        foreach (index, &character : characters) {
            imgui::separator();
            imgui::text("Instance %u", (uint)index + 1);
            foreach (side, thigh : character.thighs) {
                FootIk* foot = scene.get(thigh, FootIk);
                if (controls.contact) {
                    FootContactResult result = character.results[side];
                    imgui::text("%s: %s / %s", sides[side], contact_phase_name(result.phase), contact_status_name(result.status));
                    imgui::text("%.3f mm, normal %.3f deg, heading %.3f deg",
                        result.residual * 1000, result.normal_error_degrees, result.heading_error_degrees);
                    imgui::text("Reach margins: %.3f / %.3f m", character.inner_margins[side], character.reach_margins[side]);
                } else {
                    imgui::text("%s: %s, offset %.3f m", sides[side], foot.grounded ? "grounded" : "free", foot.ground_offset);
                }
            }
        }
        if (controls.contact) {
            imgui::text("Planted samples %u, failed bounds %u", demo.planted_samples, demo.failed_samples);
            imgui::text("Swing samples %u, failed clearance %u", demo.swing_samples, demo.failed_swing_samples);
        } else {
            imgui::text("Pelvis drop: %.3f m", drop);
        }
    }
    imgui::end();
    imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    return gui::stats_panel(renderer);
}

fn bool? draw_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* debug,
    FrameInfo info,
    ViewId capture_view,
    bool capture,
) @local {
    renderer.begin_frame(info)!;
    bool capture_rendered;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, debug)!;
        renderer.finish_view(renderer.default_view)!;
        if (capture) {
            renderer.render_view(
                scene: scene,
                camera_node: camera_node,
                view: capture_view,
                debug: debug,
            )!;
            renderer.finish_view(capture_view)!;
            capture_rendered = true;
        }
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    renderer.end_frame()!;
    return capture_rendered;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn void? run(
    platform::Window* window,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    uint frame_limit,
    bool acceptance,
    bool contact,
    bool limits,
    String telemetry_path,
    String capture_directory,
) @local {
    build_level(assets, scene)!;
    ModelId model_id = gltf::load_model(assets, example_path(MODEL_FILE))!;
    Character[CONTACT_INSTANCES] characters;
    foreach (index, &character : characters) {
        *character = build_character(
            assets: assets,
            scene: scene,
            model: model_id,
            index: (uint)index,
        )!;
        if (index == 1) {
            foreach (thigh : character.thighs) {
                FootIk* foot = scene.get(thigh, FootIk);
                foot.plant.acquire_seconds = 0.18f;
                foot.plant.release_seconds = 0.28f;
            }
        }
    }
    ContactDemo demo = {
        .platform = build_support(assets, scene)!,
        .min_reach_margin = float::max,
        .min_inner_margin = float::max,
        .min_swing_clearance = float::max,
    };
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.05f), name: "camera")!;
    Orbit orbit = {
        .distance = contact ? 7.5f : ORBIT_START_DISTANCE,
        .yaw = math::atan2(characters[0].facing.x, characters[0].facing.z) + ORBIT_START_YAW,
        .pitch = ORBIT_START_PITCH,
    };
    apply_orbit(
        orbit: &orbit,
        input: &window.input,
        camera_node: camera_node,
        target: characters[0].root.world_position() + ORBIT_TARGET_OFFSET,
    );
    scene.update_world();
    foreach (&character : characters) add_look(scene, character, camera_node)!;
    print_calibration(scene, characters[..]);
    io::printfn("contact_knee_mode=%s", contact && !limits ? "unconstrained" : "authored_hinges");

    File telemetry;
    bool telemetry_enabled = telemetry_path.len != 0 || capture_directory.len != 0;
    if (telemetry_enabled) {
        @pool() {
            String destination = telemetry_path.len ? telemetry_path
                : string::tformat("%s/ik-contact.csv", capture_directory);
            telemetry = file::open(destination, "w")!;
            io::printfn("contact_telemetry=%s", destination);
        };
    }
    defer { if (telemetry_enabled) (void)telemetry.close(); }
    if (telemetry_enabled) {
        io::fprintfn(&telemetry,
            "frame,wall_seconds,script_seconds,animation_dt,instance,side,phase_id,status_id,residual_m,normal_degrees,heading_degrees,leg_weight,knee_limit_id,outer_margin_m,inner_margin_m,incoming_clearance_m,actual_clearance_m,support_scale,paused,rebase_count,capture_index,begin_count,end_count,anchor_local_x,anchor_local_y,anchor_local_z,requested_x,requested_y,requested_z,actual_x,actual_y,actual_z")!;
    }

    RenderTargetId capture_target;
    if (capture_directory.len) {
        capture_target = render::create_render_target(renderer,
            render::render_target_desc(CONTACT_CAPTURE_WIDTH, CONTACT_CAPTURE_HEIGHT, material::PixelFormat.RGBA8_SRGB))!;
    }
    defer { if (capture_directory.len) (void)render::destroy_render_target(renderer, capture_target); }
    ViewId capture_view;
    if (capture_directory.len) {
        ViewDesc desc = render::texture_view_desc(capture_target, OutputMode.DISPLAY_LDR);
        desc.post.anti_aliasing = AntiAliasing.FXAA;
        capture_view = render::create_view(renderer, desc)!;
    }
    defer { if (capture_directory.len) (void)render::destroy_view(renderer, capture_view); }
    char[] capture_pixels;
    if (capture_directory.len) {
        capture_pixels = mem::new_array(char, CONTACT_CAPTURE_WIDTH * CONTACT_CAPTURE_HEIGHT * 4);
    }
    defer free(capture_pixels);

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    Controls controls = {
        .legs = 1, .arm = 1, .look = 1, .lines = true, .contact = contact, .limits = limits,
    };
    renderer.prepare_scene(scene)!;

    float drop;
    uint frame;
    uint captures;
    float next_capture_wall;
    double wall_start;
    float wall_seconds;
    while (window.poll()) {
        if (frame == 0) wall_start = window.clock.total;
        if (frame_limit && frame >= frame_limit) break;
        wall_seconds = (float)(window.clock.total - wall_start);
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = acceptance ? 1.0f / 60 : math::min(window.clock.delta, 1.0f / 30);
        gui_renderer.new_frame();
        defer { if (gui_renderer.frame_open) gui_renderer.finish_frame(); }
        handle_keys(input, &controls);
        if (controls.walk_changed) {
            foreach (&character : characters) change_walk(
                assets: assets,
                scene: scene,
                character: character,
                walking: controls.walking,
            );
            controls.walk_changed = false;
        }
        if (controls.rebase_requested || (controls.contact && !demo.rebased && demo.elapsed >= 7)) {
            shift_contact_demo(renderer, scene, &demo);
            demo.rebased = true;
            controls.rebase_requested = false;
        }
        demo.elapsed += delta;
        float support_phase = cycle_time(demo.elapsed, CONTACT_SUPPORT_PERIOD);
        demo.script_paused = controls.contact && support_phase >= 6 && support_phase < 6.6f;
        bool paused = controls.paused || demo.script_paused;
        float animation_dt = paused ? 0 : delta;
        if (controls.contact) {
            move_support(&demo, characters[..]);
        } else {
            demo.platform.visible = false;
            foreach (&character : characters) move_character(
                character: character,
                controls: &controls,
                delta_seconds: animation_dt,
                origin_offset: demo.origin_offset,
            );
        }
        anim::update(assets, scene, animation_dt);
        scene.update_world();
        if (controls.mode_changed) {
            foreach (&character : characters) {
                foreach (side, thigh : character.thighs) {
                    scene.get(thigh, FootIk).reset_contact();
                    character.cue_initialized[side] = false;
                }
            }
            orbit.distance = controls.contact ? 7.5f : ORBIT_START_DISTANCE;
            controls.mode_changed = false;
        }
        if (controls.contact) pose_contact_swing(scene, characters[..], &demo)!;
        drop = 0;
        foreach (index, &character : characters) {
            if (controls.contact) {
                solve_contacts(
                    scene: scene,
                    character: character,
                    controls: &controls,
                    demo: &demo,
                    instance_index: (uint)index,
                    dt: animation_dt,
                )!;
            } else {
                drop = math::max(drop, solve_legacy(
                    scene: scene,
                    character: character,
                    controls: &controls,
                    origin_offset: demo.origin_offset,
                ));
                foreach (side, thigh : character.thighs) {
                    character.results[side] = scene.get(thigh, FootIk).contact_result();
                }
            }
        }
        Vec3 center = (characters[0].root.world_position() + characters[1].root.world_position()) * 0.5f;
        apply_orbit(
            orbit: &orbit,
            input: input,
            camera_node: camera_node,
            target: center + ORBIT_TARGET_OFFSET,
        );
        scene.update_world();
        draw_panel(
            renderer: renderer,
            scene: scene,
            characters: characters[..],
            controls: &controls,
            demo: &demo,
            drop: drop,
        )!;
        debug.clear();
        if (controls.lines) {
            debug.ik(scene, debug::COLOR_YELLOW);
            if (controls.contact) draw_contact_targets(&debug, scene, characters[..]);
        }
        gui_renderer.finish_frame();
        bool capture_due = capture_directory.len != 0 && wall_seconds >= next_capture_wall;
        platform::sync_window(window, renderer);
        bool capture_rendered = draw_frame(
            renderer: renderer,
            scene: scene,
            camera_node: camera_node,
            gui_renderer: &gui_renderer,
            debug: &debug,
            info: { .time = window.clock.total, .delta = animation_dt },
            capture_view: capture_view,
            capture: capture_due,
        )!;
        int capture_index = -1;
        if (capture_rendered) {
            renderer.read_render_target(capture_target, capture_pixels)!;
            @pool() {
                String destination = string::tformat("%s/ik-contact-%06d.png", capture_directory, captures);
                image::write_png(
                    path: destination,
                    width: CONTACT_CAPTURE_WIDTH,
                    height: CONTACT_CAPTURE_HEIGHT,
                    pixels: capture_pixels,
                )!;
                io::printfn("contact_capture=%s frame=%d wall=%.6f script=%.6f",
                    destination, frame, wall_seconds, demo.elapsed);
            };
            capture_index = (int)captures;
            captures++;
            next_capture_wall += CONTACT_CAPTURE_INTERVAL;
        }
        if (telemetry_enabled) write_telemetry(
            output: &telemetry,
            scene: scene,
            characters: characters[..],
            demo: &demo,
            frame: frame,
            wall_seconds: wall_seconds,
            dt: animation_dt,
            paused: paused,
            capture_index: capture_index,
        )!;
        if (frame % 60 == 0) {
            io::printfn("contact_progress frame=%d wall=%.3f script=%.3f planted=%d failed=%d pause=%d rebases=%d",
                frame, wall_seconds, demo.elapsed, demo.planted_samples, demo.failed_samples,
                paused ? 1 : 0, demo.rebase_count);
            if (telemetry_enabled) telemetry.flush()!;
        }
        frame++;
        if (acceptance && demo.elapsed >= CONTACT_PLAYBACK_SECONDS && wall_seconds >= CONTACT_PLAYBACK_SECONDS) break;
    }
    if (telemetry_enabled) telemetry.flush()!;
    io::printfn("contact_summary frames=%d wall=%.6f script=%.6f planted=%d failed=%d captures=%d rebases=%d",
        frame, wall_seconds, demo.elapsed, demo.planted_samples, demo.failed_samples, captures, demo.rebase_count);
    io::printfn("contact_bounds residual=%.9f normal=%.9f heading=%.9f outer_margin=%.9f inner_margin=%.9f",
        demo.max_residual, demo.max_normal_error, demo.max_heading_error, demo.min_reach_margin, demo.min_inner_margin);
    io::printfn("contact_swing samples=%d failed=%d minimum_clearance=%.9f",
        demo.swing_samples, demo.failed_swing_samples, demo.min_swing_clearance);
    renderer.log.check_validation()!;
    if (acceptance && (!controls.contact || demo.elapsed < CONTACT_PLAYBACK_SECONDS
        || wall_seconds < CONTACT_PLAYBACK_SECONDS || demo.planted_samples == 0 || demo.failed_samples != 0
        || demo.swing_samples == 0 || demo.failed_swing_samples != 0)) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn int main(String[] args) {
    uint frame_limit;
    bool acceptance;
    bool contact = true;
    bool limits;
    String telemetry_path;
    String capture_directory;
    foreach (argument : args[1..]) {
        if (argument.starts_with("--frames=")) {
            frame_limit = argument[9..].to_uint()!!;
        } else if (argument == "--acceptance") {
            acceptance = true;
        } else if (argument == "--legacy") {
            contact = false;
        } else if (argument == "--limits") {
            limits = true;
        } else if (argument.starts_with("--telemetry=")) {
            telemetry_path = argument[12..];
            if (!telemetry_path.len) return 1;
        } else if (argument.starts_with("--capture-dir=")) {
            capture_directory = argument[14..];
            if (!capture_directory.len) return 1;
        } else {
            io::eprintfn("Unknown option: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d ik", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_ik" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        frame_limit: frame_limit,
        acceptance: acceptance,
        contact: contact,
        limits: limits,
        telemetry_path: telemetry_path,
        capture_directory: capture_directory,
    )) {
        io::eprintfn("ik example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
