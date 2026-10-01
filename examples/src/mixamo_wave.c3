module mixamo_example;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::math;

const uint WAVE_KEYS @private = 5;
const float WAVE_DURATION @private = 2;
const uint POSE_TRACKS @private = 3;

struct Wave @private {
    ClipId clip;
    String mask_node;
}

fn Wave? create_wave(AssetStore* assets, ModelId model) @private {
    ModelTemplate* template = &assets.model(model).data;
    uint spine = wave_joint(template, "Spine1")!;
    uint arm = wave_joint(template, "LeftArm")!;
    uint forearm = wave_joint(template, "LeftForeArm")!;

    Vec3 arm_axis;
    Vec3 forearm_axis;
    @pool() {
        Mat4[] worlds = alloc::new_array(tmem, Mat4, template.nodes.len);
        foreach (index, node : template.nodes) {
            Mat4 local = node.local.to_mat4();
            worlds[index] = node.parent < 0 ? local : worlds[node.parent].mul(local);
        }
        Vec3 direction = maths::transform_point(worlds[forearm], {}) - maths::transform_point(worlds[arm], {});
        Vec3 bend_axis = direction.normalize().cross({ 0, 1, 0 }).normalize();
        Mat4 arm_inverse = worlds[arm].inverse()!;
        Mat4 forearm_inverse = worlds[forearm].inverse()!;
        arm_axis = maths::transform_dir(arm_inverse, bend_axis).normalize();
        forearm_axis = maths::transform_dir(forearm_inverse, bend_axis).normalize();
    };

    Allocator allocator = assets.allocator;
    AnimationClip clip = {
        .name = "Upper body wave".copy(allocator),
        .duration = WAVE_DURATION,
        .tracks = alloc::new_array(allocator, Track, (sz)(template.nodes.len * POSE_TRACKS)),
        .targets = alloc::new_array(allocator, uint, template.nodes.len),
    };
    defer catch asset::free_clip(allocator, &clip);

    float[WAVE_KEYS] times = { 0, 0.5f, 1, 1.5f, WAVE_DURATION };
    float[WAVE_KEYS] arm_angles = { 0, 1.2f, 1, 1.2f, 0 };
    float[WAVE_KEYS] forearm_angles = { 0, 0.4f, -0.2f, 0.4f, 0 };
    foreach (index, node : template.nodes) {
        clip.targets[index] = (uint)index;
        Transform pose = node.local;
        float[3] positions = { pose.position.x, pose.position.y, pose.position.z };
        float[3] scales = { pose.scale.x, pose.scale.y, pose.scale.z };
        uint count = index == arm || index == forearm ? WAVE_KEYS : 1;
        float[WAVE_KEYS * 4] rotations;
        for (uint key = 0; key < count; key++) {
            Quat rotation = pose.rotation;
            if (index == arm) {
                rotation = rotation.mul(quaternion::from_axis_angle{float}(arm_axis, arm_angles[key]));
            }
            if (index == forearm) {
                rotation = rotation.mul(quaternion::from_axis_angle{float}(forearm_axis, forearm_angles[key]));
            }
            for (uint channel = 0; channel < 4; channel++) rotations[key * 4 + channel] = rotation.v[channel];
        }

        clip.tracks[index * POSE_TRACKS] = wave_track(
            allocator: allocator,
            target: (uint)index,
            path: TargetPath.TRANSLATION,
            times: times[:1],
            values: positions[..],
        );
        clip.tracks[index * POSE_TRACKS + 1] = wave_track(
            allocator: allocator,
            target: (uint)index,
            path: TargetPath.ROTATION,
            times: times[:count],
            values: rotations[:count * 4],
        );
        clip.tracks[index * POSE_TRACKS + 2] = wave_track(
            allocator: allocator,
            target: (uint)index,
            path: TargetPath.SCALE,
            times: times[:1],
            values: scales[..],
        );
    }
    return { .clip = assets.add_clip_owned(&clip)!, .mask_node = template.nodes[spine].name };
}

fn uint? wave_joint(ModelTemplate* template, String short_name) @private {
    foreach (index, node : template.nodes) {
        usz start;
        foreach (usz offset, character : node.name) if (character == ':') start = offset + 1;
        if (node.name[start..] == short_name) return (uint)index;
    }
    return NOT_FOUND~;
}

fn Track wave_track(
    Allocator allocator,
    uint target,
    TargetPath path,
    float[] times,
    float[] values,
) @private {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(allocator, float, times.len),
        .values = alloc::new_array(allocator, float, values.len),
    };
    track.times[..] = times[..];
    track.values[..] = values[..];
    return track;
}
