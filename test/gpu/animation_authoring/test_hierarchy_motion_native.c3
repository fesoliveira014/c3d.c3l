module c3d::render::acceptance;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::io;
import std::io::file;
import std::math;
import std::os::env;

const uint HIERARCHY_NATIVE_NODES @private = 6;
const uint HIERARCHY_NATIVE_ROOT @private = 1;
const uint HIERARCHY_NATIVE_FRAMES @private = 240;
const float HIERARCHY_NATIVE_DT @private = 1.0f / 64;
const float HIERARCHY_NATIVE_DURATION @private = 0.5f;
const double HIERARCHY_NATIVE_RELATIVE_EPSILON @private = 1e-5;
const double HIERARCHY_NATIVE_WORLD_EPSILON @private = 0.0005;
const double HIERARCHY_NATIVE_DELTA_EPSILON @private = 2e-6;

struct HierarchyNativeFrame @private {
    double[<3>] position;
    double yaw;
}

struct HierarchyNativeOracle @private {
    MotionNativeOracle pose;
    HierarchyNativeFrame carrier;
    HierarchyNativeFrame anchor;
    HierarchyNativeFrame cycles;
    double[<3>] carrier_world_rate;
    double carrier_twist_rate;
    double[<3>] source_root_rate;
    double source_twist_rate;
    double[<3>] residual_root_rate;
    double residual_twist_rate;
    double[<3>] last_delta_rate;
    double last_twist_rate;
    bool pending;
}

struct HierarchyNativeErrors @private {
    double relative;
    double world;
    double carrier;
    double pivot;
    double delta;
    double twist;
    double radius;
    double translation_travel;
    double turning_travel;
    uint requests;
    uint node_samples;
}

fn HierarchyNativeFrame hierarchy_native_compose(HierarchyNativeFrame first, HierarchyNativeFrame second) @private {
    return {
        .position = first.position + motion_native_rotate(motion_native_exp({ 0, first.yaw, 0 }), second.position),
        .yaw = first.yaw + second.yaw,
    };
}

fn HierarchyNativeFrame hierarchy_native_inverse(HierarchyNativeFrame frame) @private {
    return {
        .position = motion_native_rotate(motion_native_exp({ 0, -frame.yaw, 0 }), -frame.position),
        .yaw = -frame.yaw,
    };
}

fn HierarchyNativeFrame hierarchy_native_from_pose(MotionNativePose pose) @private {
    return { .position = pose.position, .yaw = 2 * math::atan2(pose.rotation.vector.y, pose.rotation.scalar) };
}

fn HierarchyNativeFrame hierarchy_native_power(HierarchyNativeFrame frame, int count) @private {
    if (count < 0) {
        frame = hierarchy_native_inverse(frame);
        count = -count;
    }
    HierarchyNativeFrame result;
    for (int index = 0; index < count; index++) result = hierarchy_native_compose(result, frame);
    return result;
}

fn double[<3>] hierarchy_native_point(HierarchyNativeFrame frame, double[<3>] point) @private {
    return frame.position + motion_native_rotate(motion_native_exp({ 0, frame.yaw, 0 }), point);
}

fn Track hierarchy_native_track(
    Allocator allocator,
    uint target,
    TargetPath path,
    float[] values,
) @private {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = LINEAR,
        .times = alloc::new_array(allocator, float, 5),
        .values = alloc::clone_slice(allocator, values),
    };
    foreach (index, &time : track.times) *time = (float)index * 0.25f;
    return track;
}

fn ClipId? add_hierarchy_native_clip(AssetStore* assets, bool shifted) @private {
    Allocator allocator = assets.allocator;
    AnimationClip clip = {
        .name = (shifted ? "hierarchy shifted" : "hierarchy source").copy(allocator),
        .duration = 1,
        .tracks = alloc::new_array(allocator, Track, 5),
        .targets = alloc::new_array(allocator, uint, 5),
    };
    defer catch asset::free_clip(allocator, &clip);
    uint[5] targets = { 0, 0, 1, 1, 4 };
    clip.targets[..] = targets[..];
    float[15] ancestor_position;
    float[20] ancestor_rotation;
    float[15] root_position;
    float[20] root_rotation;
    float[5] morph;
    for (uint key = 0; key < 5; key++) {
        float time = (float)key * 0.25f;
        Vec3 ancestor = shifted ? (Vec3){ 0.65f - 0.1f * time, 0.2f, -0.8f + 0.1f * time }
          : (Vec3){ 0.25f + 0.2f * time, 0, -0.5f + 0.05f * time };
        Vec3 root = shifted ? (Vec3){ 1.4f - 0.25f * time, 0.2f + 0.1f * time, 1.7f + 0.35f * time }
          : (Vec3){ 1 + 0.4f * time, 0.2f * time, 2 - 0.15f * time };
        float ancestor_angle = shifted ? -0.3f * time : 0.4f * time;
        float root_angle = shifted ? 0.25f - 0.4f * time : 0.65f * time;
        Quat ancestor_turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, ancestor_angle);
        Quat root_turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, root_angle);
        for (uint axis = 0; axis < 3; axis++) {
            ancestor_position[key * 3 + axis] = ancestor[axis];
            root_position[key * 3 + axis] = root[axis];
        }
        for (uint axis = 0; axis < 4; axis++) {
            ancestor_rotation[key * 4 + axis] = ancestor_turn.v[axis];
            root_rotation[key * 4 + axis] = root_turn.v[axis];
        }
        morph[key] = 0.2f + 0.1f * time;
    }
    clip.tracks[0] = hierarchy_native_track(
        allocator: allocator,
        target: 0,
        path: TRANSLATION,
        values: ancestor_position[..],
    );
    clip.tracks[1] = hierarchy_native_track(
        allocator: allocator,
        target: 1,
        path: ROTATION,
        values: ancestor_rotation[..],
    );
    clip.tracks[2] = hierarchy_native_track(
        allocator: allocator,
        target: 2,
        path: TRANSLATION,
        values: root_position[..],
    );
    clip.tracks[3] = hierarchy_native_track(
        allocator: allocator,
        target: 3,
        path: ROTATION,
        values: root_rotation[..],
    );
    clip.tracks[4] = hierarchy_native_track(
        allocator: allocator,
        target: 4,
        path: MORPH_WEIGHTS,
        values: morph[..],
    );
    String key = shifted ? "hierarchy_motion/shifted" : "hierarchy_motion/source";
    ClipId? result = assets.add_clip_owned(&clip, key);
    if (catch excuse = result) {
        io::printfn("hierarchy fixture stage=clip key=%s tracks=%s targets=%s duration=%s fault=%s",
            key, clip.tracks.len, clip.targets.len, clip.duration, excuse);
        return excuse~;
    }
    return result;
}

fn ModelId? add_hierarchy_native_model(AssetStore* assets) @private {
    PartsFixture? source = animated_crowd_fixtures::add_parts_fixture(assets);
    if (catch excuse = source) {
        io::printfn("hierarchy fixture stage=source-F-MIXED fault=%s", excuse);
        return excuse~;
    }
    PartsFixture parts = source;
    Allocator allocator = assets.allocator;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialId material = assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, common))!;
    Skeleton skeleton = {
        .joint_names = alloc::new_array(allocator, String, 1),
        .parents = alloc::new_array(allocator, int, 1),
        .rest_pose = alloc::new_array(allocator, Transform, 1),
        .inverse_bind = alloc::new_array(allocator, Mat4, 1),
    };
    skeleton.joint_names[0] = "root".copy(allocator);
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    SkeletonId? skin_result = assets.add_skeleton_owned(&skeleton, "hierarchy_motion/skin");
    if (catch excuse = skin_result) {
        io::printfn("hierarchy fixture stage=skin joints=%s parents=%s binds=%s fault=%s",
            skeleton.joint_names.len, skeleton.parents.len, skeleton.inverse_bind.len, excuse);
        asset::free_skeleton(allocator, &skeleton);
        return excuse~;
    }
    SkeletonId skin = skin_result;
    ModelTemplate template = {
        .nodes = alloc::new_array(allocator, NodeTemplate, HIERARCHY_NATIVE_NODES),
        .meshes = alloc::new_array(allocator, ModelMesh, 3),
        .skins = alloc::new_array(allocator, ModelSkin, 1),
        .clips = alloc::new_array(allocator, ClipId, 2),
    };
    defer catch asset::free_model_template(allocator, &template);
    int[HIERARCHY_NATIVE_NODES] parents = { -1, 0, 1, 0, -1, 1 };
    String[HIERARCHY_NATIVE_NODES] names = {
        "ancestor", "root", "skin", "rigid_sibling", "morph_branch", "ik_target",
    };
    Vec3[HIERARCHY_NATIVE_NODES] positions = {
        { 0.25f, 0, -0.5f }, { 1, 0, 2 }, {}, { -1.5f, 0.5f, -0.5f }, { -2, 0, 1 }, { 0.5f, 1.5f, 0 },
    };
    foreach (index, &node : template.nodes) {
        *node = {
            .parent = parents[index],
            .name = names[index].copy(allocator),
            .local = maths::TRANSFORM_IDENTITY,
            .layers = scene::DEFAULT_LAYERS,
            .visible = true,
        };
        node.local.position = positions[index];
    }
    template.meshes[0] = { .node = 2, .geometry = parts.geometries[4], .material = material };
    template.meshes[1] = { .node = 3, .geometry = parts.geometries[1], .material = material };
    template.meshes[2] = {
        .node = 4,
        .geometry = parts.geometries[2],
        .material = material,
        .default_morph_weights = alloc::new_array(allocator, float, 1),
    };
    float[1] defaults = { 0.2f };
    template.meshes[2].default_morph_weights[..] = defaults[..];
    template.skins[0] = { .mesh_node = 2, .skeleton = skin, .joint_nodes = alloc::new_array(allocator, uint, 1) };
    template.skins[0].joint_nodes[0] = HIERARCHY_NATIVE_ROOT;
    template.clips[0] = add_hierarchy_native_clip(assets, false)!;
    template.clips[1] = add_hierarchy_native_clip(assets, true)!;
    ModelId? result = assets.add_model_owned(&template, "hierarchy_motion/model");
    if (catch excuse = result) {
        io::printfn("hierarchy fixture stage=model nodes=%s meshes=%s skins=%s clips=%s fault=%s",
            template.nodes.len, template.meshes.len, template.skins.len, template.clips.len, excuse);
        return excuse~;
    }
    return result;
}

fn HierarchyNativeFrame hierarchy_native_endpoint(
    ModelTemplate* template,
    AnimationClip* clip,
    float time,
) @private {
    MotionNativePose[HIERARCHY_NATIVE_NODES] poses;
    MotionNativeRate[HIERARCHY_NATIVE_NODES] rates;
    double[1] morph;
    double[1] morph_rate;
    motion_native_sample(
        template: template,
        clip: clip,
        time: time,
        speed: 0,
        poses: poses[..],
        rates: rates[..],
        morph: morph[..],
        morph_rate: morph_rate[..],
    );
    return hierarchy_native_compose(hierarchy_native_from_pose(poses[0]), hierarchy_native_from_pose(poses[1]));
}

fn HierarchyNativeFrame hierarchy_native_trajectory(
    ModelTemplate* template,
    AnimationClip* clip,
    double time,
) @private {
    int cycles = (int)math::floor(time / clip.duration);
    float phase = (float)(time - (double)cycles * clip.duration);
    HierarchyNativeFrame reference = hierarchy_native_endpoint(template, clip, 0);
    HierarchyNativeFrame endpoint = hierarchy_native_endpoint(template, clip, phase);
    HierarchyNativeFrame cycle = hierarchy_native_endpoint(template, clip, clip.duration);
    endpoint.yaw -= reference.yaw;
    cycle.yaw -= reference.yaw;
    endpoint.position -= motion_native_rotate(motion_native_exp({ 0, endpoint.yaw, 0 }), reference.position);
    cycle.position -= motion_native_rotate(motion_native_exp({ 0, cycle.yaw, 0 }), reference.position);
    return hierarchy_native_compose(hierarchy_native_power(cycle, cycles), endpoint);
}

fn void hierarchy_native_compensate(
    ModelTemplate* template,
    HierarchyNativeOracle* oracle,
    MotionNativePose[] poses,
    MotionNativeRate[] rates,
) @private {
    HierarchyNativeFrame target_anchor = hierarchy_native_compose(oracle.anchor, oracle.cycles);
    HierarchyNativeFrame inverse_carrier = hierarchy_native_inverse(oracle.carrier);
    HierarchyNativeFrame correction = hierarchy_native_compose(inverse_carrier, target_anchor);
    MotionNativeRotation rotation = motion_native_exp({ 0, correction.yaw, 0 });
    double[<3>] angular_rate = { 0, -oracle.carrier_twist_rate, 0 };
    double[<3>] translation_rate = -motion_native_rotate(
        motion_native_exp({ 0, -oracle.carrier.yaw, 0 }), oracle.carrier_world_rate)
      + angular_rate.cross(correction.position);
    foreach (index, node : template.nodes) {
        if (node.parent >= 0) continue;
        double[<3>] rotated = motion_native_rotate(rotation, poses[index].position);
        poses[index].position = correction.position + rotated;
        poses[index].rotation = motion_native_product(rotation, poses[index].rotation);
        rates[index].position = translation_rate + angular_rate.cross(rotated)
          + motion_native_rotate(rotation, rates[index].position);
        rates[index].angular = angular_rate + motion_native_rotate(rotation, rates[index].angular);
    }
}

fn void hierarchy_native_request_capture(
    HierarchyNativeOracle* oracle,
    ModelTemplate* template,
    AnimationClip* target,
    float speed,
    MotionNativePose[] poses,
    MotionNativeRate[] rates,
    double[] morph,
    double[] morph_rate,
) @private {
    HierarchyNativeFrame source = hierarchy_native_compose(
        first: hierarchy_native_from_pose(oracle.pose.previous[0]),
        second: hierarchy_native_from_pose(oracle.pose.previous[1]),
    );
    HierarchyNativeFrame incoming = hierarchy_native_endpoint(template, target, 0);
    oracle.anchor = hierarchy_native_compose(
        first: hierarchy_native_compose(oracle.carrier, source),
        second: hierarchy_native_inverse(incoming),
    );
    oracle.cycles = {};
    motion_native_sample(
        template: template,
        clip: target,
        time: 0,
        speed: speed,
        poses: poses,
        rates: rates,
        morph: morph,
        morph_rate: morph_rate,
        onset: true,
    );
    hierarchy_native_compensate(
        template: template,
        oracle: oracle,
        poses: poses,
        rates: rates,
    );
    motion_native_capture_request(
        oracle: &oracle.pose,
        incoming: poses,
        rates: rates,
        morph: morph,
        morph_rate: morph_rate,
    );
    oracle.pose.duration = HIERARCHY_NATIVE_DURATION;
    oracle.source_root_rate = oracle.last_delta_rate;
    oracle.source_twist_rate = oracle.last_twist_rate;
    oracle.pending = true;
}

fn void hierarchy_native_update_carrier(
    HierarchyNativeOracle* oracle,
    ModelTemplate* template,
    AnimationClip* clip,
    Action* action,
    RootMotionDelta published,
    HierarchyNativeErrors* errors,
) @private {
    HierarchyNativeFrame first = hierarchy_native_trajectory(template, clip, action.previous_time);
    HierarchyNativeFrame last = hierarchy_native_trajectory(template, clip, action.previous_time + action.clock_delta);
    HierarchyNativeFrame delta = hierarchy_native_compose(hierarchy_native_inverse(first), last);
    int crossings = (int)math::floor((action.previous_time + action.clock_delta) / clip.duration)
      - (int)math::floor(action.previous_time / clip.duration);
    HierarchyNativeFrame cycle = hierarchy_native_trajectory(template, clip, clip.duration);
    oracle.cycles = hierarchy_native_compose(oracle.cycles, hierarchy_native_power(cycle, crossings));
    double elapsed = math::min(oracle.pose.duration, oracle.pose.elapsed + (double)HIERARCHY_NATIVE_DT);
    bool active = oracle.pose.transitioned && elapsed < oracle.pose.duration;
    if (active) {
        if (oracle.pending) {
            oracle.residual_root_rate = oracle.source_root_rate - delta.position / (double)HIERARCHY_NATIVE_DT;
            oracle.residual_twist_rate = oracle.source_twist_rate - delta.yaw / (double)HIERARCHY_NATIVE_DT;
            oracle.pending = false;
        }
        double decay = motion_native_h0(elapsed / oracle.pose.duration);
        delta.position += oracle.residual_root_rate * (decay * (double)HIERARCHY_NATIVE_DT);
        delta.yaw += oracle.residual_twist_rate * decay * (double)HIERARCHY_NATIVE_DT;
    }
    errors.delta = math::max(errors.delta,
        (motion_native_vector(published.translation) - delta.position).length());
    double actual_yaw = 2 * math::atan2((double)published.rotation.j, (double)published.rotation.l);
    errors.twist = math::max(errors.twist, math::abs(actual_yaw - delta.yaw));
    errors.translation_travel += delta.position.length();
    errors.turning_travel += math::abs(delta.yaw);
    Vec3 represented = { (float)delta.position.x, (float)delta.position.y, (float)delta.position.z };
    MotionNativeRotation exact_rotation = motion_native_exp({ 0, delta.yaw, 0 });
    double represented_sine = (float)exact_rotation.vector.y;
    double represented_cosine = (float)exact_rotation.scalar;
    double represented_yaw = 2 * math::atan2(represented_sine, represented_cosine);
    HierarchyNativeFrame emitted = { .position = motion_native_vector(represented), .yaw = represented_yaw };
    MotionNativeRotation carrier_rotation = motion_native_exp({ 0, oracle.carrier.yaw, 0 });
    oracle.carrier_world_rate = motion_native_rotate(carrier_rotation, emitted.position / (double)HIERARCHY_NATIVE_DT);
    oracle.carrier_twist_rate = delta.yaw / (double)HIERARCHY_NATIVE_DT;
    oracle.carrier = hierarchy_native_compose(oracle.carrier, emitted);
    oracle.last_delta_rate = emitted.position / (double)HIERARCHY_NATIVE_DT;
    oracle.last_twist_rate = delta.yaw / (double)HIERARCHY_NATIVE_DT;
}

fn void hierarchy_native_apply_residual(
    HierarchyNativeOracle* oracle,
    MotionNativePose[] poses,
    double[] morph,
) @private {
    double elapsed = math::min(oracle.pose.duration, oracle.pose.elapsed + (double)HIERARCHY_NATIVE_DT);
    if (!oracle.pose.transitioned || elapsed >= oracle.pose.duration) return;
    double h0 = motion_native_h0(elapsed / oracle.pose.duration);
    double h1 = oracle.pose.duration * motion_native_h1(elapsed / oracle.pose.duration);
    foreach (index, &pose : poses) {
        pose.position += oracle.pose.offset[index].position * h0 + oracle.pose.offset_rate[index].position * h1;
        MotionNativeRotation residual_rotation = motion_native_exp(
          oracle.pose.offset[index].angular * h0 + oracle.pose.offset_rate[index].angular * h1);
        pose.rotation = motion_native_product(residual_rotation, pose.rotation);
    }
    foreach (index, &weight : morph) {
        *weight += oracle.pose.morph_offset[index] * h0 + oracle.pose.morph_offset_rate[index] * h1;
    }
}

fn void hierarchy_native_compare(
    ModelTemplate* template,
    ModelInstance* instance,
    Scene* scene,
    Node* owner,
    MotionNativePose[] expected,
    double[] morph,
    HierarchyNativeOracle* oracle,
    HierarchyNativeErrors* errors,
    double source_x,
) @private {
    HierarchyNativeFrame[HIERARCHY_NATIVE_NODES] expected_world;
    HierarchyNativeFrame[HIERARCHY_NATIVE_NODES] actual_relative;
    foreach (usz index, node : template.nodes) {
        HierarchyNativeFrame local = hierarchy_native_from_pose(expected[index]);
        Node* present = instance.present_node(index);
        HierarchyNativeFrame actual = hierarchy_native_from_pose(motion_native_pose(present.local));
        expected_world[index] = node.parent < 0 ? local : hierarchy_native_compose(expected_world[node.parent], local);
        actual_relative[index] = node.parent < 0 ? actual
          : hierarchy_native_compose(actual_relative[node.parent], actual);
    }
    HierarchyNativeFrame expected_motion_inverse = hierarchy_native_inverse(expected_world[HIERARCHY_NATIVE_ROOT]);
    HierarchyNativeFrame actual_motion_inverse = hierarchy_native_inverse(actual_relative[HIERARCHY_NATIVE_ROOT]);
    double[<3>][4] points = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    foreach (usz index, node : template.nodes) {
        HierarchyNativeFrame expected_relative = hierarchy_native_compose(
            expected_motion_inverse, expected_world[index]);
        HierarchyNativeFrame actual = hierarchy_native_compose(actual_motion_inverse, actual_relative[index]);
        HierarchyNativeFrame placed = hierarchy_native_compose(oracle.carrier, expected_world[index]);
        foreach (point : points) {
            double relative_error =
              (hierarchy_native_point(actual, point) - hierarchy_native_point(expected_relative, point)).length();
            errors.relative = math::max(errors.relative, relative_error);
            double[<3>] expected_point = hierarchy_native_point(placed, point) * 0.5 + (double[<3>]){ source_x, 0, 0 };
            Vec3 corner = { (float)point.x, (float)point.y, (float)point.z };
            Vec3 transformed = maths::transform_point(instance.present_node(index).world, corner);
            double[<3>] actual_point = motion_native_vector(transformed);
            errors.world = math::max(errors.world, (actual_point - expected_point).length());
        }
        errors.node_samples++;
    }
    double[<3>] expected_carrier = oracle.carrier.position * 0.5 + (double[<3>]){ source_x, 0, 0 };
    double carrier_error = (motion_native_vector(owner.local.position) - expected_carrier).length();
    errors.carrier = math::max(errors.carrier, carrier_error);
    double[<3>] expected_pivot = hierarchy_native_point(
        hierarchy_native_compose(oracle.carrier, expected_world[HIERARCHY_NATIVE_ROOT]), {}) * 0.5
      + (double[<3>]){ source_x, 0, 0 };
    Node* root_node = instance.present_node(HIERARCHY_NATIVE_ROOT);
    double[<3>] actual_pivot = motion_native_vector(maths::transform_point(root_node.world, {}));
    errors.pivot = math::max(errors.pivot, (actual_pivot - expected_pivot).length());
    errors.radius = math::max(errors.radius, expected_carrier.length());
    float[] actual_morph = scene.get(instance.present_node(4), Mesh).morph_weights;
    foreach (index, weight : actual_morph) assert(math::abs((double)weight - morph[index]) <= 1e-6);
    assert(errors.relative <= HIERARCHY_NATIVE_RELATIVE_EPSILON);
    assert(errors.world <= HIERARCHY_NATIVE_WORLD_EPSILON && errors.carrier <= HIERARCHY_NATIVE_WORLD_EPSILON);
    assert(errors.pivot <= HIERARCHY_NATIVE_WORLD_EPSILON);
    assert(errors.delta <= HIERARCHY_NATIVE_DELTA_EPSILON && errors.twist <= HIERARCHY_NATIVE_DELTA_EPSILON);
}

fn void save_hierarchy_native_image(CrowdNativeImages* images, uint frame, bool expected) @private {
    @pool() {
        String directory = env::tget_var("C3D_ANIMATION_CAPTURE_DIR") ?? "";
        if (!directory.len) return;
        String filename = string::tformat("%s/hierarchy-frame-%04d-%s.rgba32f.bin",
            directory, frame, expected ? "expected" : "actual");
        file::save(filename, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!!;
        io::printfn("hierarchy capture=%s width=%s height=%s", filename, CROWD_NATIVE_WIDTH, CROWD_NATIVE_HEIGHT);
    };
}

fn void test_animation_authoring_motion_native_hierarchy_worlds_and_interrupted_references() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = add_hierarchy_native_model(&fixture.assets)!!;
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (index, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)index - 1) * 9;
        placement.scale = { 0.5f, 0.5f, 0.5f };
    }
    CrowdNativePair pair;
    fault pair_error = @catch(create_crowd_native_pair(
        allocator: &tracker,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: template.clips[0],
        bounds: { .min = { -5, -4, -5 }, .max = { 8, 4, 6 } },
        placements: placements[..],
        tinted: false,
    ));
    if (pair_error) {
        Geometry* geometry = &fixture.assets.geometry(template.meshes[2].geometry).data;
        io::printfn(
            "hierarchy fixture stage=pair-preparation fault=%s morph_defaults=%s "
            "physical_targets=%s logical_channels=%s clip_stride=%s",
            pair_error,
            template.meshes[2].default_morph_weights.len,
            geometry.targets.len,
            geometry.channels.len,
            fixture.assets.clip(template.clips[0]).data.tracks[4].stride(),
        );
    }
    assert(!pair_error);
    defer scene::destroy_scene(&pair.scene);
    configure_motion_native_pair(&fixture, &pair, false);
    PlayDesc config = {
        .root_motion = EXTRACT,
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 1, 0 },
            .twist = true,
        },
    };
    HierarchyNativeOracle[CROWD_NATIVE_INSTANCES] oracles;
    MotionNativePose[HIERARCHY_NATIVE_NODES] poses;
    MotionNativeRate[HIERARCHY_NATIVE_NODES] rates;
    double[1] morph;
    double[1] morph_rate;
    MotionNativeErrors pose_errors;
    HierarchyNativeErrors errors;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        oracles[source].pose = motion_native_oracle(mem, template, HIERARCHY_NATIVE_ROOT);
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        AnimationActionId ordinary = animator.play(&fixture.assets, template.clips[0], config)!!;
        AnimationActionId crowded = player.play(&fixture.assets, template.clips[0], config)!!;
        float speed = source == 1 ? -1.0f : 1.0f;
        animator.action(ordinary).speed = speed;
        player.action(crowded).speed = speed;
    }
    defer {
        foreach (&oracle : oracles) destroy_motion_native_oracle(mem, &oracle.pose);
    }
    crowd_native_update(&fixture, &pair, 0);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        motion_native_sample(
            template: template,
            clip: &fixture.assets.clip(template.clips[0]).data,
            time: 0,
            speed: source == 1 ? -1.0f : 1.0f,
            poses: poses[..],
            rates: rates[..],
            morph: morph[..],
            morph_rate: morph_rate[..],
        );
        motion_native_check_and_record(
            template: template,
            instance: pair.scene.get(pair.ordinary[source], ModelInstance),
            scene: &pair.scene,
            oracle: &oracles[source].pose,
            expected: poses[..],
            morph: morph[..],
            errors: &pose_errors,
            independent: false,
            dt: 0,
        );
    }
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    uint captures;
    for (uint frame = 0; frame < HIERARCHY_NATIVE_FRAMES; frame++) {
        if (frame == 48 || frame == 60 || frame == 144) {
            ClipId target = template.clips[frame == 60 ? 0 : 1];
            AnimationClip* clip = &fixture.assets.clip(target).data;
            for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
                Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
                CrowdPlayer player = crowd_native_player(&pair, source)!!;
                float speed = source == 1 ? -1.0f : 1.0f;
                hierarchy_native_request_capture(
                    oracle: &oracles[source],
                    template: template,
                    target: clip,
                    speed: speed,
                    poses: poses[..],
                    rates: rates[..],
                    morph: morph[..],
                    morph_rate: morph_rate[..],
                );
                AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
                targets[0].clip = target;
                targets[0].play = config;
                targets[0].speed = speed;
                animator.inertialize(&fixture.assets, {
                    .duration = HIERARCHY_NATIVE_DURATION,
                    .actions = targets[..],
                })!!;
                player.inertialize(&fixture.assets, {
                    .duration = HIERARCHY_NATIVE_DURATION,
                    .actions = targets[..],
                })!!;
                errors.requests++;
            }
        }
        sz acquisitions = tracker.total_allocation_count();
        crowd_native_update(&fixture, &pair, HIERARCHY_NATIVE_DT);
        assert(tracker.total_allocation_count() == acquisitions);
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            Action* action = animator.action(animator.order[0]);
            AnimationClip* clip = &fixture.assets.clip(action.clip).data;
            hierarchy_native_update_carrier(
                oracle: &oracles[source],
                template: template,
                clip: clip,
                action: action,
                published: animator.root_motion,
                errors: &errors,
            );
            motion_native_sample(
                template: template,
                clip: clip,
                time: action.time,
                speed: action.speed,
                poses: poses[..],
                rates: rates[..],
                morph: morph[..],
                morph_rate: morph_rate[..],
            );
            hierarchy_native_compensate(
                template: template,
                oracle: &oracles[source],
                poses: poses[..],
                rates: rates[..],
            );
            hierarchy_native_apply_residual(&oracles[source], poses[..], morph[..]);
            anim::apply_root_motion(pair.ordinary[source], animator.root_motion);
            pair.scene.update_world();
            hierarchy_native_compare(
                template: template,
                instance: pair.scene.get(pair.ordinary[source], ModelInstance),
                scene: &pair.scene,
                owner: pair.ordinary[source],
                expected: poses[..],
                morph: morph[..],
                oracle: &oracles[source],
                errors: &errors,
                source_x: (double)placements[source].position.x,
            );
            motion_native_check_and_record(
                template: template,
                instance: pair.scene.get(pair.ordinary[source], ModelInstance),
                scene: &pair.scene,
                oracle: &oracles[source].pose,
                expected: poses[..],
                morph: morph[..],
                errors: &pose_errors,
                independent: false,
                dt: (double)HIERARCHY_NATIVE_DT,
            );
        }
        pair.scene.apply_crowd_root_motion(crowd);
        pair.scene.update_world();
        check_motion_native_pair(&pair, &pose_errors);
        if (frame == 0 || frame == 60 || frame == 128 || frame + 1 == HIERARCHY_NATIVE_FRAMES) {
            *pair.scene.get(pair.camera, Camera) = camera::orthographic(20, 0.1f, 100);
            pair.camera.local.position = { 0, 1, 20 };
            for (uint path = 0; path < 2; path++) {
                ViewDesc desc = render::texture_view_desc(output.target);
                desc.shading = path == 0 ? ShadingPath.FORWARD : ShadingPath.DEFERRED;
                desc.depth_prepass = true;
                desc.post.motion_blur = true;
                render::configure_view(&fixture.renderer, output.view, desc)!!;
                capture_crowd_native(
                    fixture: &fixture,
                    pair: &pair,
                    probe: &output.probe,
                    output: output.target,
                    view: output.view,
                    crowd_visible: true,
                    images: &output.actual,
                )!!;
                capture_crowd_native(
                    fixture: &fixture,
                    pair: &pair,
                    probe: &output.probe,
                    output: output.target,
                    view: output.view,
                    crowd_visible: false,
                    images: &output.expected,
                )!!;
                save_hierarchy_native_image(&output.actual, frame * 2 + path, false);
                save_hierarchy_native_image(&output.expected, frame * 2 + path, true);
                io::printfn("hierarchy frame=%s path=%s parts=%s tested=%s visible=%s draws=%s/%s",
                    frame, path, crowd.parts.len, output.actual.stats.instances_tested,
                    output.actual.stats.instances_visible, output.actual.stats.draws, output.expected.stats.draws);
                check_crowd_native_parity(&output.actual, &output.expected, false);
                captures++;
            }
        }
    }
    assert(errors.requests == 9);
    assert(errors.node_samples == HIERARCHY_NATIVE_FRAMES * CROWD_NATIVE_INSTANCES * HIERARCHY_NATIVE_NODES);
    assert(errors.translation_travel > 1 && errors.turning_travel > 1);
    io::printfn("hierarchy frames=%s seconds=%s requests=%s captures=%s node_samples=%s",
        HIERARCHY_NATIVE_FRAMES, (double)HIERARCHY_NATIVE_FRAMES * HIERARCHY_NATIVE_DT,
        errors.requests, captures, errors.node_samples);
    io::printfn("hierarchy independent relative=%s world=%s carrier=%s pivot=%s delta=%s twist=%s radius=%s",
        errors.relative, errors.world, errors.carrier, errors.pivot, errors.delta, errors.twist, errors.radius);
    io::printfn("hierarchy independent translation_travel=%s turning_travel=%s retained_bytes=%s",
        errors.translation_travel, errors.turning_travel, tracker.allocated());
    check_crowd_native_validation(&fixture.renderer);
}
