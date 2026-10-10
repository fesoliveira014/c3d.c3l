module c3d::test::animation_reference;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::collections::list;
import std::math;

const uint EXACT_CLIP_COUNT @private = 5;
const uint EXACT_MORPH_COUNT @private = 2;

struct ScriptAction @private {
    AnimationActionId identity;
    uint label;
}

struct ReferenceRig @private {
    AssetStore assets;
    Scene scene;
    ModelId model;
    Node* root;
    ClipId[] clips;
    List{ScriptAction} actions;
    uint sample;
}

fn Animator* ReferenceRig.playback(&self) => self.scene.get(self.root, Animator);

fn AnimationActionId? ReferenceRig.play(
    &self,
    uint clip,
    uint label,
    PlayDesc desc = anim::PLAY_DESC_DEFAULT,
) {
    AnimationActionId identity = self.playback().play(&self.assets, self.clips[clip], desc)!;
    self.actions.push({ .identity = identity, .label = label });

    return identity;
}

fn void ReferenceRig.label_space(&self, BlendSpace1D* space, uint first_label) {
    foreach (index, identity : space.actions[:space.count]) {
        self.actions.push({ .identity = identity, .label = first_label + (uint)index });
    }
}

fn uint? ReferenceRig.action_label(&self, AnimationActionId identity) {
    foreach (action : self.actions.array_view()) {
        if (c3d::same_id(action.identity, identity)) return action.label;
    }

    return c3d::INVALID_ARGUMENT~;
}

fn uint? ReferenceRig.clip_label(&self, ClipId identity) {
    foreach (index, clip : self.clips) {
        if (c3d::same_id(clip, identity)) return (uint)index;
    }

    return c3d::INVALID_ARGUMENT~;
}

fn ReferenceRig create_reference_rig(Allocator allocator) @private {
    ReferenceRig rig;
    rig.assets = asset::create_asset_store(allocator, {
        .max_geometries = 4,
        .max_textures = 8,
        .max_materials = 4,
        .max_samplers = 8,
        .max_models = 2,
        .max_skeletons = 2,
        .max_clips = 160,
    });
    rig.scene = scene::create_scene(allocator, { .max_nodes = 256 });
    rig.actions.init(allocator);
    return rig;
}

fn void destroy_reference_rig(ReferenceRig* rig) @private {
    rig.actions.free();
    scene::destroy_scene(&rig.scene);
    asset::destroy_asset_store(&rig.assets);
    *rig = {};
}

fn Track create_reference_track(
    Allocator allocator,
    TargetPath path,
    Interpolation interpolation,
    float[] times,
    float[] values,
    uint target = 0,
) @private {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = interpolation,
        .times = alloc::new_array(allocator, float, times.len),
        .values = alloc::new_array(allocator, float, values.len),
    };
    track.times[..] = times[..];
    track.values[..] = values[..];

    return track;
}

fn ClipId? add_reference_clip(
    ReferenceRig* rig,
    String name,
    Track[] tracks,
    uint[] targets,
    float duration,
) @private {
    Allocator allocator = rig.assets.allocator;
    AnimationClip clip = {
        .name = name.copy(allocator),
        .duration = duration,
        .tracks = alloc::new_array(allocator, Track, tracks.len),
        .targets = alloc::new_array(allocator, uint, targets.len),
    };
    defer catch asset::free_clip(allocator, &clip);
    clip.tracks[..] = tracks[..];
    clip.targets[..] = targets[..];

    ClipId identity = rig.assets.add_clip_owned(&clip)!;
    return identity;
}

fn ClipId? add_reference_motion(
    ReferenceRig* rig,
    Transform reference,
    Vec3 displacement,
    float yaw,
    float duration,
    String name,
) @private {
    float[2] times = { 0, duration };
    Vec3 end_position = reference.position + displacement;
    Quat end_rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw).mul(reference.rotation);
    float[6] positions = {
        reference.position.x, reference.position.y, reference.position.z,
        end_position.x, end_position.y, end_position.z,
    };
    float[8] rotations = {
        reference.rotation.v.x, reference.rotation.v.y, reference.rotation.v.z, reference.rotation.v.w,
        end_rotation.v.x, end_rotation.v.y, end_rotation.v.z, end_rotation.v.w,
    };
    Track[2] tracks = {
        create_reference_track(
            allocator: rig.assets.allocator,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
        ),
        create_reference_track(
            allocator: rig.assets.allocator,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
    };

    uint[1] targets = { 1 };

    return add_reference_clip(
        rig: rig,
        name: name,
        tracks: tracks[..],
        targets: targets[..],
        duration: duration,
    );
}

fn void? build_exact_clips(ReferenceRig* rig, Transform reference, ClipId[] clips) @private {
    Allocator allocator = rig.assets.allocator;
    clips[0] = add_reference_motion(
        rig: rig,
        reference: reference,
        displacement: { 3, 0.5f, 2 },
        yaw: 1.2f,
        duration: 1,
        name: "forward",
    )!;
    clips[1] = add_reference_motion(
        rig: rig,
        reference: reference,
        displacement: { -2, 0.25f, 3 },
        yaw: -0.8f,
        duration: 2,
        name: "turn",
    )!;

    float[2] times = { 0, 1 };
    float[8] rotations = { 0, 0, 0, -1, 0, 0, -0.70710677f, -0.70710677f };
    float[4] morphs = { 0.2f, 0.4f, 0.8f, -0.2f };
    Track[2] overlay = {
        create_reference_track(
            allocator: allocator,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
        create_reference_track(
            allocator: allocator,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: morphs[..],
            target: 1,
        ),
    };
    uint[2] overlay_targets = { 2, 3 };
    clips[2] = add_reference_clip(
        rig: rig,
        name: "overlay",
        tracks: overlay[..],
        targets: overlay_targets[..],
        duration: 1,
    )!;

    float[18] cubic_positions = {
        7, 8, 9, 0, 2, 0, 0.5f, 1, 0,
        0.5f, 1, 0, 1, 3, 2, 5, 6, 7,
    };
    float[6] scales = { 1, 1, 1, 1.5f, 0.75f, 2 };
    float[8] additive_rotation = { 0, 0, 0, 1, 0.38268343f, 0, 0, 0.9238795f };
    Track[4] additive = {
        create_reference_track(
            allocator: allocator,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.CUBIC_SPLINE,
            times: times[..],
            values: cubic_positions[..],
        ),
        create_reference_track(
            allocator: allocator,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: scales[..],
        ),
        create_reference_track(
            allocator: allocator,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: additive_rotation[..],
        ),
        create_reference_track(
            allocator: allocator,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: morphs[..],
            target: 1,
        ),
    };
    clips[3] = add_reference_clip(
        rig: rig,
        name: "additive",
        tracks: additive[..],
        targets: overlay_targets[..],
        duration: 1,
    )!;

    float[3] step_times = { 0, 0.5f, 1 };
    float[6] step_morphs = { 0.1f, 0.3f, 0.7f, 0.6f, -0.2f, 1.2f };
    Track[1] step = {
        create_reference_track(
            allocator: allocator,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.STEP,
            times: step_times[..],
            values: step_morphs[..],
        ),
    };
    uint[1] step_targets = { 4 };
    clips[4] = add_reference_clip(
        rig: rig,
        name: "step",
        tracks: step[..],
        targets: step_targets[..],
        duration: 1,
    )!;

    ClipEvent[4] events = {
        { .time = 0, .id = 10 },
        { .time = 0.25f, .id = 11 },
        { .time = 0.5f, .id = 12 },
        { .time = 1, .id = 13 },
    };
    rig.assets.set_clip_events(clips[0], events[..])!;
    events = {
        { .time = 0, .id = 20 },
        { .time = 0.5f, .id = 21 },
        { .time = 1, .id = 22 },
        { .time = 2, .id = 23 },
    };
    rig.assets.set_clip_events(clips[1], events[..])!;
}

fn void? create_exact_rig(ReferenceRig* rig, Allocator allocator) @private {
    *rig = create_reference_rig(allocator);
    defer catch destroy_reference_rig(rig);

    MaterialId material = rig.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!;
    GeometryId geometry;

    @pool() {
        Geometry shape = geometry::box(tmem, 1, 1, 1);
        shape.joints = alloc::new_array(tmem, ushort[<4>], shape.positions.len);
        shape.weights = alloc::new_array(tmem, Vec4, shape.positions.len);
        shape.joints[..] = (ushort[<4>]){ 0, 0, 0, 0 };
        shape.weights[..] = (Vec4){ 1, 0, 0, 0 };
        shape.targets = alloc::new_array(tmem, MorphTarget, EXACT_MORPH_COUNT);

        foreach (index, &target : shape.targets) {
            target.position_deltas = alloc::new_array(tmem, Vec3, shape.positions.len);
            target.position_deltas[..] = (Vec3){ 0.1f * (float)(index + 1), 0, 0 };
        }

        geometry = rig.assets.add_geometry(&shape)!;
    };

    Skeleton skeleton = {
        .joint_names = alloc::new_array(allocator, String, 2),
        .parents = alloc::new_array(allocator, int, 2),
        .rest_pose = alloc::new_array(allocator, Transform, 2),
        .inverse_bind = alloc::new_array(allocator, Mat4, 2),
    };
    defer catch asset::free_skeleton(allocator, &skeleton);
    skeleton.joint_names[0] = "pivot".copy(allocator);
    skeleton.joint_names[1] = "upper".copy(allocator);
    skeleton.parents[0] = -1;
    skeleton.parents[1] = 0;
    skeleton.rest_pose[..] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    skeleton.inverse_bind[1] = matrix::IDENTITY4;
    SkeletonId skeleton_id = rig.assets.add_skeleton_owned(&skeleton)!;
    skeleton = {};

    ModelTemplate template = {
        .nodes = alloc::new_array(allocator, NodeTemplate, 5),
        .meshes = alloc::new_array(allocator, ModelMesh, 2),
        .skins = alloc::new_array(allocator, ModelSkin, 1),
        .clips = alloc::new_array(allocator, ClipId, EXACT_CLIP_COUNT),
    };
    defer catch asset::free_model_template(allocator, &template);
    String[5] names = { "ancestor", "pivot", "upper", "morph", "step_morph" };
    int[5] parents = { -1, 0, 1, 1, 0 };

    foreach (index, &node : template.nodes) {
        *node = {
            .parent = parents[index],
            .name = names[index].copy(allocator),
            .local = maths::TRANSFORM_IDENTITY,
            .layers = scene::DEFAULT_LAYERS,
            .visible = true,
        };
    }

    template.nodes[0].local = {
        .position = { 3, 1, -2 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.4f),
        .scale = { 1.5f, 1.5f, 1.5f },
    };
    template.nodes[1].local.position = { 2, 3, -1 };
    template.nodes[1].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.25f);
    template.nodes[2].local.position = { 0, 2, 0 };
    template.nodes[3].local.position = { 0.5f, 1, 0 };

    foreach (index, &mesh : template.meshes) {
        *mesh = {
            .node = (uint)index + 3,
            .geometry = geometry,
            .material = material,
            .default_morph_weights = alloc::new_array(allocator, float, EXACT_MORPH_COUNT),
        };
        mesh.default_morph_weights[0] = 0.15f;
        mesh.default_morph_weights[1] = 0.35f;
    }

    template.skins[0] = {
        .mesh_node = 3,
        .skeleton = skeleton_id,
        .joint_nodes = alloc::new_array(allocator, uint, 2),
    };
    template.skins[0].joint_nodes[0] = 1;
    template.skins[0].joint_nodes[1] = 2;

    build_exact_clips(rig, template.nodes[1].local, template.clips)!;
    rig.model = rig.assets.add_model_owned(&template)!;
    template = {};
    rig.clips = rig.assets.model(rig.model).data.clips;
    rig.root = model::instantiate(&rig.assets, &rig.scene, rig.model)!;
    anim::add_animator(&rig.scene, rig.root);
}
