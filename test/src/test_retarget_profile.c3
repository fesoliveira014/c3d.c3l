module c3d::test::retarget;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;
import std::io;

const float PROFILE_POSITION_EPSILON @local = 1e-5f;
const float PROFILE_SUBKEY_EPSILON @local = 0.0005f;

struct ProfileRig @local {
    NodeTemplate[] source;
    ModelTemplate target;
    RetargetProfileDesc desc;
    AnimationClip clip;
}

struct ProfileFaultAllocator (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz outstanding;
}

fn void*? ProfileFaultAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* allocation = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return allocation;
}

fn void*? ProfileFaultAllocator.resize(
    &self,
    void* pointer,
    sz new_size,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    return self.backing.resize(pointer, new_size, alignment);
}

fn void ProfileFaultAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn Quat profile_turn(Vec3 axis, float degrees) @local {
    return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180);
}

fn Transform profile_transform(
    Vec3 position = {},
    Quat rotation = quaternion::IDENTITY,
    float scale = 1,
) @local {
    return { .position = position, .rotation = rotation, .scale = { scale, scale, scale } };
}

fn ProfileRig profile_rig(uint source_count, uint target_count) @local {
    ProfileRig rig = {
        .source = alloc::new_array(tmem, NodeTemplate, source_count),
        .target = { .nodes = alloc::new_array(tmem, NodeTemplate, target_count) },
        .desc = retarget::RETARGET_PROFILE_DESC_DEFAULT,
        .clip = { .name = "authored_motion", .duration = 1 },
    };
    rig.desc.mapping_mode = ProfileMappingMode.BY_INDEX;
    rig.desc.source_calibration = alloc::new_array(tmem, Quat, source_count);
    rig.desc.target_calibration = alloc::new_array(tmem, Quat, target_count);
    rig.desc.source_calibration[..] = maths::TRANSFORM_IDENTITY.rotation;
    rig.desc.target_calibration[..] = maths::TRANSFORM_IDENTITY.rotation;
    foreach (&node : rig.source) *node = {
        .parent = -1, .name = "joint", .local = maths::TRANSFORM_IDENTITY, .visible = true,
    };
    foreach (&node : rig.target.nodes) *node = {
        .parent = -1, .name = "joint", .local = maths::TRANSFORM_IDENTITY, .visible = true,
    };
    return rig;
}

fn void profile_map(ProfileRig* rig, NodeIndexMapping[] mappings) @local {
    rig.desc.index_map = alloc::new_array(tmem, NodeIndexMapping, mappings.len);
    rig.desc.index_map[..] = mappings[..];
}

fn Track profile_input_track(
    uint target,
    TargetPath path,
    float[] times,
    float[] values,
    Interpolation interpolation = Interpolation.LINEAR,
) @local {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = interpolation,
        .times = alloc::new_array(tmem, float, times.len),
        .values = alloc::new_array(tmem, float, values.len),
    };
    track.times[..] = times[..];
    track.values[..] = values[..];
    return track;
}

fn void profile_clip(ProfileRig* rig, uint[] targets, Track[] tracks) @local {
    rig.clip.targets = alloc::new_array(tmem, uint, targets.len);
    rig.clip.targets[..] = targets[..];
    rig.clip.tracks = alloc::new_array(tmem, Track, tracks.len);
    rig.clip.tracks[..] = tracks[..];
}

fn RetargetProfile profile_prepare(ProfileRig* rig) @local {
    return retarget::create_retarget_profile(
        allocator: mem,
        source_nodes: rig.source,
        target: &rig.target,
        desc: rig.desc,
    )!!;
}

fn AnimationClip profile_bake(
    ProfileRig* rig,
    RetargetProfile* profile,
    RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT,
) @local {
    return retarget::retarget_with_profile(
        allocator: mem,
        source: &rig.clip,
        source_nodes: rig.source,
        target: &rig.target,
        profile: profile,
        options: options,
    )!!;
}

fn Track* profile_output_track(AnimationClip* clip, uint node, TargetPath path) @local {
    foreach (&track : clip.tracks) {
        if (clip.targets[track.target] == node && track.path == path) return track;
    }
    return null;
}

fn Transform profile_sample_node(
    AnimationClip* clip,
    ModelTemplate* target,
    uint node,
    float time,
) @local {
    Transform local = target.nodes[node].local;
    foreach (&track : clip.tracks) {
        if (clip.targets[track.target] != node || track.path == TargetPath.MORPH_WEIGHTS) continue;
        float[4] sample;
        uint cursor;
        anim::sample_track(
            track: track,
            time: time,
            cursor: &cursor,
            out: sample[:track.stride()],
        );
        switch (track.path) {
            case TRANSLATION: local.position = { sample[0], sample[1], sample[2] };
            case ROTATION: local.rotation = { .v = { sample[0], sample[1], sample[2], sample[3] } };
            case SCALE: local.scale = { sample[0], sample[1], sample[2] };
            case MORPH_WEIGHTS: break;
        }
    }
    return local;
}

fn Mat4 profile_sample_world(
    AnimationClip* clip,
    ModelTemplate* target,
    uint node,
    float time,
) @local {
    Mat4 matrix = profile_sample_node(
        clip: clip,
        target: target,
        node: node,
        time: time,
    ).to_mat4();
    for (int parent = target.nodes[node].parent; parent >= 0; parent = target.nodes[parent].parent) {
        matrix = profile_sample_node(
            clip: clip,
            target: target,
            node: (uint)parent,
            time: time,
        ).to_mat4().mul(matrix);
    }
    return matrix;
}

fn void profile_expect_position(Mat4 world, Vec3 expected, float epsilon = PROFILE_POSITION_EPSILON) @local {
    assert((maths::translation(world) - expected).length() <= epsilon);
}

fn void profile_expect_rotation(Mat4 world, Quat expected, float radians = 0.0001f) @local {
    Quat actual = maths::transform_from_mat4(world).rotation.normalize();
    double dot;
    double actual_length;
    double expected_length;
    foreach (index, component : actual.v) {
        dot += (double)component * expected.v[index];
        actual_length += (double)component * component;
        expected_length += (double)expected.v[index] * expected.v[index];
    }
    dot = math::abs(dot) / math::sqrt(actual_length * expected_length);
    double angle = 2 * math::acos(math::clamp(dot, 0.0, 1.0));
    assert(angle <= radians);
}

fn void profile_expect_scale(Mat4 world, float expected) @local {
    Transform transform = maths::transform_from_mat4(world);
    assert((transform.scale - (Vec3){ expected, expected, expected }).length() <= PROFILE_POSITION_EPSILON);
}

fn void test_profile_anatomical_calibration_preserves_target_bone_proportions() @test {
    @pool() {
        foreach (bool reverse : (bool[2]){ false, true }) {
            ProfileRig rig = profile_rig(3, 3);
            rig.source[1].parent = 0;
            rig.source[1].local = profile_transform({ 1, 0, 0 }, profile_turn({ 0, 0, 1 }, reverse ? -45 : 0));
            rig.source[2].parent = 1;
            rig.source[2].local.position = { 1, 0, 0 };
            rig.target.nodes[1].parent = 0;
            rig.target.nodes[1].local = profile_transform({ 2, 0, 0 }, profile_turn({ 0, 0, 1 }, reverse ? 0 : -45));
            rig.target.nodes[2].parent = 1;
            rig.target.nodes[2].local.position = { 2, 0, 0 };
            profile_map(&rig, (NodeIndexMapping[2]){
                { .source_node = 0, .target_node = 0 }, { .source_node = 1, .target_node = 1 },
            }[..]);
            Quat end = profile_turn({ 0, 0, 1 }, 30);
            profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
                profile_input_track(
                    target: 0,
                    path: TargetPath.ROTATION,
                    times: (float[2]){ 0, 1 }[..],
                    values: (float[8]){ 0, 0, 0, 1, end.v.x, end.v.y, end.v.z, end.v.w }[..],
                ),
            }[..]);
            Transform source_rest = rig.source[1].local;
            Transform target_rest = rig.target.nodes[1].local;
            RetargetProfile profile = profile_prepare(&rig);
            defer retarget::destroy_retarget_profile(&profile);
            AnimationClip result = profile_bake(&rig, &profile);
            defer asset::free_clip(mem, &result);
            profile_expect_rotation(profile_sample_world(
                clip: &result,
                target: &rig.target,
                node: 1,
                time: 0,
            ), quaternion::IDENTITY);
            profile_expect_position(profile_sample_world(
                clip: &result,
                target: &rig.target,
                node: 2,
                time: 1,
            ), { 2 + math::sqrt(3.0f), 1, 0 });
            profile_expect_position(profile_sample_world(
                clip: &result,
                target: &rig.target,
                node: 2,
                time: 0.5f,
            ), {
                2 + (math::sqrt(6.0f) + math::sqrt(2.0f)) / 2,
                (math::sqrt(6.0f) - math::sqrt(2.0f)) / 2,
                0,
            });
            assert(profile_output_track(&result, 2, TargetPath.ROTATION) == null);
            assert(profile_output_track(&result, 1, TargetPath.TRANSLATION) == null);
            assert(rig.source[1].local.rotation.v == source_rest.rotation.v);
            assert(rig.target.nodes[1].local.rotation.v == target_rest.rotation.v);
            assert(rig.target.nodes[2].local.position == (Vec3){ 2, 0, 0 });
        }
    };
}

fn void test_profile_facing_calibration_and_noncommuting_target_parents() @test {
    @pool() {
        foreach (yaw : (float[4]){ 0, 90, 180, 37 }) {
            ProfileRig rig = profile_rig(2, 2);
            rig.source[0].local.rotation = profile_turn({ 0, 1, 0 }, 20);
            rig.source[1].parent = 0;
            rig.source[1].local.rotation = profile_turn({ 0, 0, 1 }, -10);
            rig.target.nodes[0].local.rotation = profile_turn({ 0, 1, 0 }, 90);
            rig.target.nodes[1].parent = 0;
            rig.target.nodes[1].local.rotation = profile_turn({ 0, 0, 1 }, 10);
            rig.desc.source_calibration[0] = rig.source[0].local.rotation;
            rig.desc.source_calibration[1] = profile_turn({ 0, 0, 1 }, 45);
            rig.desc.target_calibration[0] = profile_turn({ 1, 0, 0 }, 80);
            rig.desc.target_calibration[1] = profile_turn({ 0, 0, 1 }, -45);
            rig.desc.facing = profile_turn({ 0, 1, 0 }, yaw).to_matrix();
            profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 1, .target_node = 1 } }[..]);
            Quat start = rig.desc.source_calibration[1];
            Quat end = profile_turn({ 1, 0, 0 }, 30).mul(start);
            profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
                profile_input_track(
                    target: 0,
                    path: TargetPath.ROTATION,
                    times: (float[2]){ 0, 1 }[..],
                    values: (float[8]){
                        start.v.x, start.v.y, start.v.z, start.v.w,
                        end.v.x, end.v.y, end.v.z, end.v.w,
                    }[..],
                ),
            }[..]);
            RetargetProfile profile = profile_prepare(&rig);
            defer retarget::destroy_retarget_profile(&profile);
            AnimationClip result = profile_bake(&rig, &profile);
            defer asset::free_clip(mem, &result);
            Quat target_calibration = rig.target.nodes[0].local.rotation.mul(rig.desc.target_calibration[1]);
            profile_expect_rotation(profile_sample_world(
                clip: &result,
                target: &rig.target,
                node: 1,
                time: 0,
            ), target_calibration);
            float angle = (yaw + 20) * (float)math::PI / 180;
            Quat expected = profile_turn({ math::cos(angle), 0, -math::sin(angle) }, 30).mul(target_calibration);
            profile_expect_rotation(profile_sample_world(
                clip: &result,
                target: &rig.target,
                node: 1,
                time: 1,
            ), expected);
            assert(profile_output_track(&result, 0, TargetPath.ROTATION) == null);
        }
    };
}

fn ProfileRig profile_ancestor_rig() @local {
    ProfileRig rig = profile_rig(3, 3);
    rig.source[0].local = profile_transform({ 1, 2, 3 }, quaternion::IDENTITY, 2);
    rig.source[1].parent = 0;
    rig.source[1].local = profile_transform({ 1, 0, 0 }, quaternion::IDENTITY, 0.5f);
    rig.source[2].parent = 1;
    rig.source[2].local = profile_transform({ 0, 1, 0 }, quaternion::IDENTITY, 3);
    rig.target.nodes[0].local = profile_transform({ -2, 1, 4 }, profile_turn({ 0, 0, 1 }, 90), 2);
    rig.target.nodes[1].parent = 0;
    rig.target.nodes[1].local = profile_transform({ 1, -2.5f, -0.5f }, profile_turn({ 0, 0, 1 }, -90), 1.5f);
    rig.target.nodes[2].parent = 1;
    rig.target.nodes[2].local.position = { 0, 0, 1 };
    rig.desc.target_calibration[0] = rig.target.nodes[0].local.rotation;
    rig.desc.target_calibration[1] = rig.target.nodes[1].local.rotation;
    profile_map(&rig, (NodeIndexMapping[2]){
        { .source_node = 1, .target_node = 0 }, { .source_node = 2, .target_node = 1 },
    }[..]);
    rig.desc.source_motion_node = 2;
    rig.desc.target_motion_node = 1;
    rig.clip.duration = 3;
    rig.clip.targets = alloc::new_array(tmem, uint, 3);
    rig.clip.targets[..] = (uint[3]){ 0, 1, 2 }[..];
    rig.clip.tracks = alloc::new_array(tmem, Track, 5);
    Quat yaw = profile_turn({ 0, 1, 0 }, 90);
    Quat pitch = profile_turn({ 1, 0, 0 }, 90);
    Quat roll = profile_turn({ 0, 0, 1 }, 90);
    Quat[3] turns = { yaw, pitch, roll };
    foreach (uint index, turn : turns) rig.clip.tracks[index] = profile_input_track(
        target: index,
        path: TargetPath.ROTATION,
        times: (float[2]){ 0, 3 }[..],
        values: (float[8]){ 0, 0, 0, 1, turn.v.x, turn.v.y, turn.v.z, turn.v.w }[..],
    );
    rig.clip.tracks[3] = profile_input_track(
        target: 0,
        path: TargetPath.SCALE,
        times: (float[2]){ 0, 3 }[..],
        values: (float[6]){ 2, 2, 2, 4, 4, 4 }[..],
    );
    rig.clip.tracks[4] = profile_input_track(
        target: 1,
        path: TargetPath.SCALE,
        times: (float[2]){ 0, 3 }[..],
        values: (float[6]){ 0.5f, 0.5f, 0.5f, 0.25f, 0.25f, 0.25f }[..],
    );
    return rig;
}

fn void test_profile_composes_unmapped_animated_ancestors_and_affine_motion_chain() @test {
    @pool() {
        ProfileRig rig = profile_ancestor_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);
        Mat4 parent = profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 3,
        );
        Mat4 motion = profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 3,
        );
        profile_expect_position(parent, { -4, 1, 0 });
        profile_expect_position(motion, { 2, 2, -1 });
        profile_expect_rotation(parent, profile_turn({ 1, 0, 0 }, 90));
        profile_expect_rotation(motion, profile_turn({ 1, 0, 0 }, 90));
        profile_expect_scale(parent, 2);
        profile_expect_scale(motion, 3);
        Transform local = profile_sample_node(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 3,
        );
        assert((local.position - (Vec3){ 3, -0.5f, -0.5f }).length() <= PROFILE_POSITION_EPSILON);
        assert((local.scale - (Vec3){ 1.5f, 1.5f, 1.5f }).length() <= PROFILE_POSITION_EPSILON);
        assert(profile_output_track(&result, 2, TargetPath.TRANSLATION) == null);
        float half = math::sqrt(0.5f);
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 1.5f,
        ), {
            -4 + 3 * half, 1, 4 - 3 * half,
        });
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 1.5f,
        ), {
            1.5625f + 3 * half, 2 + 1.125f * half, 3.5625f - 3 * half,
        });
        profile_expect_scale(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 1.5f,
        ), 2.25f);
        profile_expect_scale(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 1.5f,
        ), 3.375f);
    };
}

fn ProfileRig profile_carrier_rig() @local {
    ProfileRig rig = profile_rig(2, 5);
    rig.source[1].parent = 0;
    rig.target.nodes[0].local = profile_transform({ 1, 0, 2 }, profile_turn({ 0, 1, 0 }, 90), 2);
    rig.target.nodes[1].parent = 0;
    rig.target.nodes[1].local = profile_transform({ 1, 2, 0 }, profile_turn({ 0, 0, 1 }, 90), 0.5f);
    rig.target.nodes[2].parent = 0;
    rig.target.nodes[2].local.position = { -1, 0, 2 };
    rig.target.nodes[3].parent = 1;
    rig.target.nodes[3].local.position = { 0, 1, 0 };
    rig.target.nodes[4].parent = 1;
    foreach (index, &node : rig.target.nodes) rig.desc.target_calibration[index] = node.local.rotation;
    profile_map(&rig, (NodeIndexMapping[2]){
        { .source_node = 0, .target_node = 1 }, { .source_node = 1, .target_node = 4 },
    }[..]);
    rig.desc.source_motion_node = 1;
    rig.desc.target_motion_node = 4;
    rig.desc.target_carrier = 0;
    rig.target.meshes = alloc::new_array(tmem, ModelMesh, 1);
    rig.target.meshes[0].node = 2;
    rig.target.skins = alloc::new_array(tmem, ModelSkin, 1);
    uint[] joints = alloc::new_array(tmem, uint, 2);
    joints[..] = (uint[2]){ 1, 4 }[..];
    rig.target.skins[0] = { .mesh_node = 2, .joint_nodes = joints };
    profile_clip(&rig, (uint[1]){ 1 }[..], (Track[1]){
        profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[6]){ 0, 0, 0, 0.5f, 0, -0.25f }[..],
        ),
    }[..]);
    return rig;
}

fn void test_profile_carrier_compensates_each_branch_once() @test {
    @pool() {
        ProfileRig rig = profile_carrier_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip keep = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &keep);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.EXTRACT;
        AnimationClip extract = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &extract);
        options.root_motion = RootMotion.STRIP_XZ;
        AnimationClip strip = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &strip);
        Vec3[4] expected = { { 1, 4, 0 }, { 5, 0, 4 }, { 1, 4, 1 }, { 1.5f, 4, -0.25f } };
        foreach (uint index, position : expected) {
            uint node = index + 1;
            profile_expect_position(profile_sample_world(
                clip: &keep,
                target: &rig.target,
                node: node,
                time: 1,
            ), position);
            profile_expect_position(profile_sample_world(
                clip: &extract,
                target: &rig.target,
                node: node,
                time: 1,
            ), position);
            profile_expect_position(profile_sample_world(
                clip: &strip,
                target: &rig.target,
                node: node,
                time: 1,
            ), position - (Vec3){ 0.5f, 0, -0.25f });
        }
        assert((profile_sample_node(
            clip: &extract,
            target: &rig.target,
            node: 0,
            time: 1,
        ).position - (Vec3){ 1.5f, 0, 1.75f }).length()
            <= PROFILE_POSITION_EPSILON);
        assert((profile_sample_node(
            clip: &extract,
            target: &rig.target,
            node: 1,
            time: 1,
        ).position - (Vec3){ 0.875f, 2, -0.25f }).length()
            <= PROFILE_POSITION_EPSILON);
        assert((profile_sample_node(
            clip: &extract,
            target: &rig.target,
            node: 2,
            time: 1,
        ).position - (Vec3){ -1.125f, 0, 1.75f }).length()
            <= PROFILE_POSITION_EPSILON);
        assert(profile_output_track(&extract, 3, TargetPath.TRANSLATION) == null);
        foreach (&track : extract.tracks) assert(track.times.len == 61 && track.interpolation == Interpolation.LINEAR);
    };
}

fn ProfileRig profile_forest_rig(float yaw = 90) @local {
    ProfileRig rig = profile_rig(1, 2);
    rig.source[0].local.position = { 0, 2, 0 };
    rig.target.nodes[0].local = profile_transform({ 2, 1, -3 }, profile_turn({ 1, 0, 0 }, 30));
    rig.target.nodes[1].local = profile_transform({ -1, 1, 2 }, profile_turn({ 0, 1, 0 }, 37), 0.5f);
    rig.desc.target_calibration[0] = rig.target.nodes[0].local.rotation;
    rig.desc.facing = profile_turn({ 0, 1, 0 }, yaw).to_matrix();
    rig.desc.source_motion_node = 0;
    rig.desc.target_motion_node = 0;
    profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
    Quat turn = profile_turn({ 0, 1, 0 }, 90);
    profile_clip(&rig, (uint[1]){ 0 }[..], (Track[2]){
        profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[6]){ 0, 2, 0, 1, 2.5f, 3 }[..],
        ),
        profile_input_track(
            target: 0,
            path: TargetPath.ROTATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[8]){ 0, 0, 0, 1, turn.v.x, turn.v.y, turn.v.z, turn.v.w }[..],
        ),
    }[..]);
    return rig;
}

fn RetargetDiagnostic profile_creation_failure(
    ProfileRig* rig,
    fault expected_fault,
    RetargetReason expected_reason,
) @local {
    RetargetDiagnostic diagnostic;
    bool failed;
    if (catch excuse = retarget::create_retarget_profile(
        allocator: mem,
        source_nodes: rig.source,
        target: &rig.target,
        desc: rig.desc,
        diagnostic: &diagnostic,
    )) {
        failed = true;
        assert(excuse == expected_fault);
        assert(diagnostic.reason == expected_reason);
    }
    assert(failed);
    return diagnostic;
}

fn RetargetDiagnostic profile_bake_failure(
    ProfileRig* rig,
    RetargetProfile* profile,
    fault expected_fault,
    RetargetReason expected_reason,
    RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT,
) @local {
    RetargetDiagnostic diagnostic;
    bool failed;
    if (catch excuse = retarget::retarget_with_profile(
        allocator: mem,
        source: &rig.clip,
        source_nodes: rig.source,
        target: &rig.target,
        profile: profile,
        options: options,
        diagnostic: &diagnostic,
    )) {
        failed = true;
        assert(excuse == expected_fault);
        assert(diagnostic.reason == expected_reason);
    }
    assert(failed);
    return diagnostic;
}

fn void test_profile_virtual_forest_strips_all_roots_and_retains_initial_placement() @test {
    @pool() {
        foreach (yaw : (float[2]){ 90, 180 }) {
            ProfileRig rig = profile_forest_rig(yaw);
            RetargetProfile profile = profile_prepare(&rig);
            defer retarget::destroy_retarget_profile(&profile);
            RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
            options.root_translation_scale = 0.5f;
            AnimationClip keep = profile_bake(&rig, &profile, options);
            defer asset::free_clip(mem, &keep);
            options.root_motion = RootMotion.STRIP_XZ;
            AnimationClip strip = profile_bake(&rig, &profile, options);
            defer asset::free_clip(mem, &strip);
            Vec3 horizontal = yaw == 90 ? (Vec3){ 1.5f, 0, -0.5f } : (Vec3){ -0.5f, 0, -1.5f };
            profile_expect_position(profile_sample_world(
                clip: &keep,
                target: &rig.target,
                node: 0,
                time: 1,
            ), (Vec3){ 2, 1.25f, -3 } + horizontal);
            profile_expect_position(profile_sample_world(
                clip: &strip,
                target: &rig.target,
                node: 0,
                time: 1,
            ), { 2, 1.25f, -3 });
            profile_expect_position(profile_sample_world(
                clip: &strip,
                target: &rig.target,
                node: 1,
                time: 1,
            ), (Vec3){ -1, 1, 2 } - horizontal);
            profile_expect_position(profile_sample_world(
                clip: &keep,
                target: &rig.target,
                node: 1,
                time: 1,
            ), { -1, 1, 2 });
            options.root_motion = RootMotion.EXTRACT;
            profile_bake_failure(
                rig: &rig,
                profile: &profile,
                expected_fault: c3d::INVALID_ARGUMENT,
                expected_reason: RetargetReason.INVALID_MOTION_CARRIER,
                options: options,
            );
            if (yaw == 90) {
                profile_expect_position(profile_sample_world(
                    clip: &keep,
                    target: &rig.target,
                    node: 0,
                    time: 1.0f / 120,
                ), {
                    2.0125f, 1.002083333333f, -3.004166666667f,
                });
                profile_expect_position(profile_sample_world(
                    clip: &strip,
                    target: &rig.target,
                    node: 1,
                    time: 1.0f / 120,
                ), {
                    -1.0125f, 1, 2.004166666667f,
                });
            }
        }
        ProfileRig rig = profile_forest_rig();
        rig.clip.tracks[0].values[0] = 1;
        rig.clip.tracks[0].values[2] = 3;
        rig.clip.tracks[0].values[3] = 2;
        rig.clip.tracks[0].values[5] = 6;
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.STRIP_XZ;
        AnimationClip strip = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &strip);
        profile_expect_position(profile_sample_world(
            clip: &strip,
            target: &rig.target,
            node: 0,
            time: 1,
        ), { 5, 1.5f, -4 });
    };
}

fn void test_profile_index_mapping_is_authoritative_for_duplicate_names() @test {
    @pool() {
        ProfileRig rig = profile_rig(3, 3);
        profile_map(&rig, (NodeIndexMapping[2]){
            { .source_node = 0, .target_node = 2 }, { .source_node = 1, .target_node = 0 },
        }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);
        assert(profile_output_track(&result, 0, TargetPath.ROTATION) != null);
        assert(profile_output_track(&result, 2, TargetPath.ROTATION) != null);
        assert(profile_output_track(&result, 1, TargetPath.ROTATION) == null);
        rig.desc.mapping_mode = ProfileMappingMode.BY_NAME;
        rig.desc.index_map = {};
        RetargetDiagnostic diagnostic = profile_creation_failure(
            &rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.AMBIGUOUS_TARGET,
        );
        assert(diagnostic.source_node == 0 && diagnostic.target_node == 0);
        rig.target.nodes = rig.target.nodes[:1];
        rig.desc.target_calibration = rig.desc.target_calibration[:1];
        diagnostic = profile_creation_failure(&rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.AMBIGUOUS_SOURCE);
        assert(diagnostic.source_node == 0 && diagnostic.target_node == 0);
    };
}

fn void test_profile_mapping_rows_report_first_conflict_and_invalid_index() @test {
    @pool() {
        ProfileRig rig = profile_rig(2, 2);
        profile_map(&rig, (NodeIndexMapping[2]){
            { .source_node = 0, .target_node = 0 }, { .source_node = 1, .target_node = 0 },
        }[..]);
        RetargetDiagnostic diagnostic = profile_creation_failure(
            rig: &rig,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.CONFLICTING_MAPPING,
        );
        assert(diagnostic.source_node == 1 && diagnostic.target_node == 0 && diagnostic.mapping_row == 1);
        rig.desc.index_map[1] = rig.desc.index_map[0];
        diagnostic = profile_creation_failure(&rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.CONFLICTING_MAPPING);
        assert(diagnostic.source_node == 0 && diagnostic.target_node == 0 && diagnostic.mapping_row == 1);
        rig.desc.index_map[1] = { .source_node = 99, .target_node = 1 };
        diagnostic = profile_creation_failure(&rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.INVALID_MAPPING_INDEX);
        assert(diagnostic.source_node == 99 && diagnostic.target_node == 1 && diagnostic.mapping_row == 1);
        rig.desc.mapping_mode = ProfileMappingMode.BY_NAME;
        rig.desc.index_map = {};
        rig.desc.name_map = (NameMapping[1]){ { .source = "joint", .target = "joint" } }[..];
        diagnostic = profile_creation_failure(&rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.AMBIGUOUS_SOURCE);
        assert(diagnostic.mapping_row == 0);
    };
}

fn void test_profile_name_mapping_uses_unique_exact_names_then_canonical_fallback() @test {
    @pool() {
        ProfileRig rig = profile_rig(3, 3);
        rig.source[0].name = "source:Hips";
        rig.source[1].name = "source:Arm";
        rig.source[2].name = "helper";
        rig.target.nodes[0].name = "hips";
        rig.target.nodes[1].name = "Elbow";
        rig.target.nodes[2].name = "unused";
        rig.desc.mapping_mode = ProfileMappingMode.BY_NAME;
        rig.desc.name_map = (NameMapping[1]){ { .source = "source:Arm", .target = "Elbow" } }[..];
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);
        assert(result.tracks.len == 2);
        rig.desc.name_map[0].source = "absent";
        RetargetDiagnostic diagnostic = profile_creation_failure(
            rig: &rig,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.MISSING_SOURCE,
        );
        assert(diagnostic.mapping_row == 0);
        rig.desc.name_map[0].source = "source:Arm";
        rig.desc.name_map[0].target = "absent";
        diagnostic = profile_creation_failure(&rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.MISSING_TARGET);
        assert(diagnostic.mapping_row == 0);
    };
}

fn void test_profile_exact_fingerprint_rejects_template_changes() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        RetargetDiagnostic diagnostic;
        String source_name = rig.source[0].name;
        rig.source[0].name = "renamed";
        diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_LAYOUT_MISMATCH,
        );
        assert(diagnostic.source_node == 0 && diagnostic.target_node == retarget::RETARGET_NO_NODE);
        rig.source[0].name = source_name;
        rig.target.nodes[1].local.position.x += 1;
        diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_REFERENCE_MISMATCH,
        );
        assert(diagnostic.target_node == 1);
        rig.target.nodes[1].local.position.x -= 1;
        rig.target.nodes[1].parent = 0;
        diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_REFERENCE_MISMATCH,
        );
        assert(diagnostic.target_node == 1);
        rig.target.nodes[1].parent = -1;
        NodeTemplate[] original = rig.target.nodes;
        rig.target.nodes = rig.target.nodes[:1];
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_LAYOUT_MISMATCH,
        );
        rig.target.nodes = original;
        rig.source[0].local.scale = { 2, 2, 2 };
        diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_REFERENCE_MISMATCH,
        );
        assert(diagnostic.source_node == 0);
        rig.source[0].local.scale = { 1, 1, 1 };
        rig.target.meshes = (ModelMesh[1]){ { .node = 0, .material = { .index = 2 } } }[..];
        AnimationClip compatible = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &compatible);
        assert(compatible.duration == rig.clip.duration);
    };
}

fn void test_profile_invalid_descriptors_and_carriers_have_precise_reasons() @test {
    @pool() {
        ProfileRig rig = profile_carrier_rig();
        Quat[] original_calibration = rig.desc.source_calibration;
        rig.desc.source_calibration = original_calibration[:1];
        profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_CALIBRATION);
        rig.desc.source_calibration = original_calibration;
        rig.desc.source_calibration[1] = {};
        RetargetDiagnostic diagnostic = profile_creation_failure(
            rig: &rig,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.INVALID_CALIBRATION,
        );
        assert(diagnostic.source_node == 1);
        rig.desc.source_calibration[1] = quaternion::IDENTITY;
        foreach (Mat4 basis : (Mat4[4]){
            profile_turn({ 1, 0, 0 }, 90).to_matrix(),
            maths::TRANSFORM_IDENTITY.to_mat4().scale({ -1, 1, 1 }),
            { .m00 = 1, .m01 = 0.1f, .m11 = 1, .m22 = 1, .m33 = 1 },
            maths::TRANSFORM_IDENTITY.to_mat4().scale({ 2, 2, 2 }),
        }) {
            rig.desc.facing = basis;
            profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_FACING_BASIS);
        }
        rig.desc.facing = matrix::IDENTITY4;
        rig.source[0].local.scale = { 1, 2, 1 };
        diagnostic = profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_STATIC_TRANSFORM);
        assert(diagnostic.source_node == 0);
        rig.source[0].local.scale = { 1, 1, 1 };
        rig.target.nodes[0].local.rotation = profile_turn({ 1, 0, 0 }, 10);
        diagnostic = profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_MOTION_CARRIER);
        assert(diagnostic.target_node == 0);
        rig.target.nodes[0].local.rotation = profile_turn({ 0, 1, 0 }, 90);
        rig.target.meshes[0].node = 0;
        diagnostic = profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_MOTION_CARRIER);
        assert(diagnostic.target_node == 0);
        rig.target.meshes[0].node = 2;
        rig.desc.index_map[0].target_node = 0;
        diagnostic = profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_MOTION_CARRIER);
        assert(diagnostic.target_node == 0);
    };
}

fn void test_profile_clip_validation_and_partial_unmatched_policy() @test {
    @pool() {
        ProfileRig rig = profile_ancestor_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        uint track_target = rig.clip.tracks[0].target;
        rig.clip.tracks[0].target = 99;
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.INVALID_CLIP,
        );
        rig.clip.tracks[0].target = track_target;
        float time = rig.clip.tracks[0].times[1];
        rig.clip.tracks[0].times[1] = 0;
        RetargetDiagnostic diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.INVALID_CLIP,
        );
        assert(diagnostic.source_node == 0);
        rig.clip.tracks[0].times[1] = time;
        rig.clip.tracks[3].values[4] = 8;
        diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::UNSUPPORTED,
            expected_reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
        );
        assert(diagnostic.source_node == 0);
        rig.clip.tracks[3].values[4] = 4;
        ProfileRig partial = profile_rig(2, 1);
        profile_map(&partial, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        profile_clip(&partial, (uint[1]){ 1 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.TRANSLATION,
                times: (float[2]){ 0, 1 }[..],
                values: (float[6]){ 0, 0, 0, 1, 0, 0 }[..],
            ),
        }[..]);
        RetargetProfile partial_profile = profile_prepare(&partial);
        defer retarget::destroy_retarget_profile(&partial_profile);
        diagnostic = profile_bake_failure(
            rig: &partial,
            profile: &partial_profile,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.UNMATCHED_SOURCE,
        );
        assert(diagnostic.source_node == 1);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.allow_partial = true;
        AnimationClip accepted = profile_bake(&partial, &partial_profile, options);
        defer asset::free_clip(mem, &accepted);
        assert(accepted.tracks.len == 1);
    };
}

fn void test_profile_cadence_includes_zero_tiny_and_nonintegral_endpoints() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        foreach (rate : (float[3]){ 30, 60, 120 }) {
            foreach (duration : (float[6]){ 0, 0.000001f, 1, 1.013f, (60 + 0.0005f) / 60, (60 + 0.0015f) / 60 }) {
                rig.clip.duration = duration;
                uint count = duration == 0 ? 1 : 2;
                float[] times = alloc::new_array(tmem, float, count);
                times[count - 1] = duration;
                float[] values = alloc::new_array(tmem, float, (sz)count * 4);
                values[3] = 1;
                if (count > 1) values[7] = -1;
                profile_clip(&rig, (uint[1]){ 0 }[..], (Track[1]){
                    profile_input_track(
                        target: 0,
                        path: TargetPath.ROTATION,
                        times: times,
                        values: values,
                    ),
                }[..]);
                RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
                options.bake_rate = rate;
                AnimationClip result = profile_bake(&rig, &profile, options);
                defer asset::free_clip(mem, &result);
                Track* rotation = profile_output_track(&result, 0, TargetPath.ROTATION);
                uint intervals = duration == 0 ? 0 : (uint)math::max(1.0, math::ceil((double)duration * rate - 0.001));
                assert(rotation.times.len == (usz)intervals + 1);
                assert(rotation.times[0] == 0 && rotation.times[^1] == duration);
                for (usz key = 1; key < rotation.times.len; key++) {
                    assert(rotation.times[key] > rotation.times[key - 1]);
                    float[] before = rotation.values[(key - 1) * 4:4];
                    float[] after = rotation.values[key * 4:4];
                    Vec4 first = { before[0], before[1], before[2], before[3] };
                    Vec4 second = { after[0], after[1], after[2], after[3] };
                    assert(first.dot(second) >= 0);
                    assert(math::abs(second.dot(second) - 1) <= 1e-5f);
                }
            }
        }
        RetargetBakeOptions invalid = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        invalid.bake_rate = 0;
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.INVALID_BAKE_OPTIONS,
            options: invalid,
        );
        invalid.bake_rate = float::max;
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::CAPACITY_EXCEEDED,
            expected_reason: RetargetReason.CAPACITY_LIMIT,
            options: invalid,
        );
    };
}

fn void profile_expect_ancestor_pose(
    AnimationClip* clip,
    ProfileRig* rig,
    float time,
    float position_epsilon,
    float rotation_radians,
) @local {
    float fraction = time / 3;
    float angle = fraction * (float)math::PI / 2;
    float sine = math::sin(angle);
    float cosine = math::cos(angle);
    float wrapper_scale = 2 + 2 * fraction;
    float ancestor_scale = (1 + fraction) * (1 - 0.5f * fraction);
    profile_expect_position(profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 0,
        time: time,
    ), {
        -4 + wrapper_scale * cosine, 1, 4 - wrapper_scale * sine,
    }, position_epsilon);
    profile_expect_position(profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 1,
        time: time,
    ), {
        1 + wrapper_scale * cosine + ancestor_scale * sine * sine,
        2 + ancestor_scale * cosine,
        3 - wrapper_scale * sine + ancestor_scale * sine * cosine,
    }, position_epsilon);
    Quat expected = profile_turn({ 0, 1, 0 }, fraction * 90)
      .mul(profile_turn({ 1, 0, 0 }, fraction * 90))
      .mul(profile_turn({ 0, 0, 1 }, fraction * 90));
    profile_expect_rotation(profile_sample_world(
        clip: clip,
        target: &rig.target,
        node: 1,
        time: time,
    ), expected, rotation_radians);
}

fn void test_profile_key_and_subkey_goldens_at_thirty_sixty_and_one_twenty_hertz() @test {
    @pool() {
        ProfileRig rig = profile_ancestor_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        foreach (rate : (float[3]){ 30, 60, 120 }) {
            RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
            options.bake_rate = rate;
            AnimationClip result = profile_bake(&rig, &profile, options);
            defer asset::free_clip(mem, &result);
            Track* track = profile_output_track(&result, 1, TargetPath.TRANSLATION);
            foreach (time : track.times) profile_expect_ancestor_pose(
                clip: &result,
                rig: &rig,
                time: time,
                position_epsilon: PROFILE_POSITION_EPSILON,
                rotation_radians: 0.0001f,
            );
            if (rate < 60) continue;
            for (usz key = 1; key < track.times.len; key++) {
                foreach (fraction : (float[3]){ 0.25f, 0.5f, 0.75f }) {
                    float time = track.times[key - 1] + (track.times[key] - track.times[key - 1]) * fraction;
                    profile_expect_ancestor_pose(
                        clip: &result,
                        rig: &rig,
                        time: time,
                        position_epsilon: PROFILE_SUBKEY_EPSILON,
                        rotation_radians: 0.25f * (float)math::PI / 180,
                    );
                }
            }
        }
    };
}

fn void test_profile_copied_scale_morph_and_events_keep_interpolation_and_ownership() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        rig.target.meshes = alloc::new_array(tmem, ModelMesh, 1);
        rig.target.meshes[0] = { .node = 0, .default_morph_weights = (float[2]){ 0, 0 }[..] };
        profile_clip(&rig, (uint[1]){ 0 }[..], (Track[2]){
            profile_input_track(
                target: 0,
                path: TargetPath.SCALE,
                times: (float[2]){ 0, 1 }[..],
                values: (float[6]){ 1, 1, 1, 2, 2, 2 }[..],
                interpolation: Interpolation.STEP,
            ),
            profile_input_track(
                target: 0,
                path: TargetPath.MORPH_WEIGHTS,
                times: (float[2]){ 0, 1 }[..],
                values: (float[12]){ 0, 0, 0.2f, 0.4f, 1, 1, 1, 1, 0.8f, 0.6f, 0, 0 }[..],
                interpolation: Interpolation.CUBIC_SPLINE,
            ),
        }[..]);
        rig.clip.events = (ClipEvent[2]){ { .time = 0, .id = 7 }, { .time = 0.5f, .id = 9 } }[..];
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);
        Track* scale = profile_output_track(&result, 0, TargetPath.SCALE);
        Track* morph = profile_output_track(&result, 0, TargetPath.MORPH_WEIGHTS);
        assert(scale.interpolation == Interpolation.STEP && scale.times.len == 2);
        assert(morph.interpolation == Interpolation.CUBIC_SPLINE && morph.values.len == 12);
        assert(scale.values.ptr != rig.clip.tracks[0].values.ptr && morph.values.ptr != rig.clip.tracks[1].values.ptr);
        foreach (index, value : morph.values) assert(value == rig.clip.tracks[1].values[index]);
        rig.clip.tracks[0].values[0] = 99;
        rig.clip.tracks[1].values[0] = 99;
        rig.clip.events[0].id = 99;
        assert(scale.values[0] == 1 && morph.values[0] == 0 && result.events[0].id == 7);
        rig.clip.tracks[0].values[0] = 1;
        rig.clip.tracks[1].values[0] = 0;
        rig.target.meshes[0].default_morph_weights = (float[1]){ 0 }[..];
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.INVALID_MORPH_STRIDE,
        );
    };
}

fn void test_profile_owns_preparation_and_failure_preserves_existing_resource_bytes() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        NodeIndexMapping[] mapping = alloc::new_array(mem, NodeIndexMapping, rig.desc.index_map.len);
        mapping[..] = rig.desc.index_map[..];
        Quat[] source_calibration = alloc::new_array(mem, Quat, rig.desc.source_calibration.len);
        source_calibration[..] = rig.desc.source_calibration[..];
        Quat[] target_calibration = alloc::new_array(mem, Quat, rig.desc.target_calibration.len);
        target_calibration[..] = rig.desc.target_calibration[..];
        rig.desc.index_map = mapping;
        rig.desc.source_calibration = source_calibration;
        rig.desc.target_calibration = target_calibration;
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        RetargetProfile profile = retarget::create_retarget_profile(
            allocator: &tracker,
            source_nodes: rig.source,
            target: &rig.target,
            desc: rig.desc,
        )!!;
        assert(tracker.allocation_count() == 1);
        sz bytes = tracker.allocated();
        io::printfn("Profile owner %d bytes; prepared resource %d bytes.", RetargetProfile::size, bytes);
        char[] captured = alloc::new_array(tmem, char, bytes);
        captured[..] = ((char*)profile.data)[:bytes];
        mapping[0].target_node = 99;
        source_calibration[0] = {};
        target_calibration[0] = {};
        alloc::free(mem, mapping.ptr);
        alloc::free(mem, source_calibration.ptr);
        alloc::free(mem, target_calibration.ptr);
        rig.desc.index_map = {};
        rig.desc.source_calibration = {};
        rig.desc.target_calibration = {};
        profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_CALIBRATION);
        foreach (index, value : captured) assert(((char*)profile.data)[index] == value);
        AnimationClip first = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &first);
        AnimationClip second = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &second);
        foreach (index, value : captured) assert(((char*)profile.data)[index] == value);
        retarget::destroy_retarget_profile(&profile);
        assert(!profile.data && tracker.allocation_count() == 0 && tracker.allocated() == 0);
        rig.clip.tracks[0].values[3] = 99;
        assert(first.name == "authored_motion" && second.name == "authored_motion");
        assert(first.tracks[0].times.ptr != second.tracks[0].times.ptr);
        profile_expect_position(profile_sample_world(
            clip: &first,
            target: &rig.target,
            node: 0,
            time: 1,
        ), { 5, 1.5f, -4 });
        profile_expect_position(profile_sample_world(
            clip: &second,
            target: &rig.target,
            node: 0,
            time: 1,
        ), { 5, 1.5f, -4 });
    };
}

fn void test_profile_failed_sample_frees_every_partial_clip_allocation() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        profile_clip(&rig, (uint[1]){ 0 }[..], (Track[1]){
            profile_input_track(
                target: 0,
                path: TargetPath.SCALE,
                times: (float[2]){ 0, 1 }[..],
                values: (float[18]){
                    0, 0, 0, 1, 1, 1, -10, -10, -10,
                    10, 10, 10, 1, 1, 1, 0, 0, 0,
                }[..],
                interpolation: Interpolation.CUBIC_SPLINE,
            ),
        }[..]);
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        for (uint attempt = 0; attempt < 100; attempt++) {
            RetargetDiagnostic diagnostic;
            if (catch excuse = retarget::retarget_with_profile(
                allocator: &tracker,
                source: &rig.clip,
                source_nodes: rig.source,
                target: &rig.target,
                profile: &profile,
                diagnostic: &diagnostic,
            )) {
                assert(excuse == c3d::UNSUPPORTED);
                assert(diagnostic.reason == RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM
                  && diagnostic.source_node == 0);
            } else {
                assert(false, "expected unsupported sampled scale");
            }
            assert(tracker.allocation_count() == 0 && tracker.allocated() == 0);
        }
        assert(rig.clip.tracks[0].values[6] == -10 && rig.source[0].local.scale == (Vec3){ 1, 1, 1 });
    };
}

fn void test_profile_runtime_extract_consumes_carrier_once_and_clips_outlive_profile() @test {
    @pool() {
        foreach (rate : (uint[2]){ 60, 120 }) {
            ProfileRig rig = profile_carrier_rig();
            rig.target.meshes = {};
            rig.target.skins = {};
            RetargetProfile profile = profile_prepare(&rig);
            AnimationClip keep = profile_bake(&rig, &profile);
            RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
            options.root_motion = RootMotion.EXTRACT;
            AnimationClip extract = profile_bake(&rig, &profile, options);
            retarget::destroy_retarget_profile(&profile);
            AssetStore assets = asset::create_asset_store(mem, {
                .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 8,
                .max_models = 1, .max_skeletons = 1, .max_clips = 2,
            });
            defer asset::destroy_asset_store(&assets);
            ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, rig.target.nodes.len) };
            template.nodes[..] = rig.target.nodes[..];
            foreach (&node : template.nodes) node.name = node.name.copy(mem);
            ModelId model_id = assets.add_model_owned(&template)!!;
            ClipId kept_clip = assets.add_clip_owned(&keep)!!;
            ClipId extracted_clip = assets.add_clip_owned(&extract)!!;
            Scene scene = scene::create_scene(mem, { .max_nodes = 20 });
            defer scene::destroy_scene(&scene);
            Node* kept_root = model::instantiate(&assets, &scene, model_id)!!;
            Node* extracted_root = model::instantiate(&assets, &scene, model_id)!!;
            Animator* kept = anim::add_animator(&scene, kept_root);
            Animator* extracted = anim::add_animator(&scene, extracted_root);
            extracted.root_node = 0;
            AnimationActionId kept_action = kept.play(&assets, kept_clip)!!;
            AnimationActionId extracted_action = extracted.play(
                assets: &assets,
                clip: extracted_clip,
                desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = false },
            )!!;
            kept.action(kept_action).loop = false;
            extracted.action(extracted_action).loop = false;
            for (uint frame = 0; frame < rate; frame++) {
                anim::update(&assets, &scene, 1.0f / rate);
                anim::apply_root_motion(extracted_root, extracted.root_motion);
                scene.update_world();
                ModelInstance* kept_instance = scene.get(kept_root, ModelInstance);
                ModelInstance* extracted_instance = scene.get(extracted_root, ModelInstance);
                for (uint node = 1; node < rig.target.nodes.len; node++) {
                    Vec3 kept_position = maths::translation(kept_instance.present_node(node).world);
                    Vec3 extracted_position = maths::translation(extracted_instance.present_node(node).world);
                    assert((kept_position - extracted_position).length() <= PROFILE_POSITION_EPSILON);
                }
            }
            Vec3 last_root = extracted_root.local.position;
            anim::update(&assets, &scene, 0);
            assert(extracted.root_motion.translation.length() <= 1e-6f);
            assert(extracted_root.local.position == last_root);
        }
    };
}

fn void test_profile_unmapped_ancestor_translation_contributes_once() @test {
    @pool() {
        ProfileRig rig = profile_ancestor_rig();
        Track[] tracks = alloc::new_array(tmem, Track, 6);
        tracks[:5] = rig.clip.tracks[..];
        tracks[5] = profile_input_track(
            target: 0,
            path: TargetPath.TRANSLATION,
            times: (float[2]){ 0, 3 }[..],
            values: (float[6]){ 1, 2, 3, 1.6f, 2.3f, 2.7f }[..],
        );
        rig.clip.tracks = tracks;
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip result = profile_bake(&rig, &profile);
        defer asset::free_clip(mem, &result);
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 3,
        ), { -3.4f, 1.3f, -0.3f });
        profile_expect_position(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 3,
        ), { 2.6f, 2.3f, -1.3f });
        Transform local = profile_sample_node(
            clip: &result,
            target: &rig.target,
            node: 1,
            time: 3,
        );
        assert((local.position - (Vec3){ 3, -0.5f, -0.5f }).length() <= PROFILE_POSITION_EPSILON);
    };
}

fn void test_profile_carrier_split_preserves_anatomical_yaw() @test {
    @pool() {
        ProfileRig rig = profile_carrier_rig();
        Track[] tracks = alloc::new_array(tmem, Track, 2);
        tracks[0] = rig.clip.tracks[0];
        Quat yaw = profile_turn({ 0, 1, 0 }, 30);
        tracks[1] = profile_input_track(
            target: 0,
            path: TargetPath.ROTATION,
            times: (float[2]){ 0, 1 }[..],
            values: (float[8]){ 0, 0, 0, 1, yaw.v.x, yaw.v.y, yaw.v.z, yaw.v.w }[..],
        );
        rig.clip.tracks = tracks;
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.EXTRACT;
        AnimationClip result = profile_bake(&rig, &profile, options);
        defer asset::free_clip(mem, &result);
        Quat expected = profile_turn({ 0, 1, 0 }, 120).mul(profile_turn({ 0, 0, 1 }, 90));
        profile_expect_rotation(profile_sample_world(
            clip: &result,
            target: &rig.target,
            node: 4,
            time: 1,
        ), expected);
        assert(profile_output_track(&result, 0, TargetPath.ROTATION) == null);
        assert(profile_sample_node(
            clip: &result,
            target: &rig.target,
            node: 0,
            time: 1,
        ).rotation.v == rig.target.nodes[0].local.rotation.v);
    };
}

fn void test_profile_reordered_names_and_source_count_invalidate_layout() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        rig.target.nodes[0].name = "motion";
        rig.target.nodes[1].name = "other_root";
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        rig.target.nodes[0].name = "other_root";
        rig.target.nodes[1].name = "motion";
        RetargetDiagnostic diagnostic = profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_LAYOUT_MISMATCH,
        );
        assert(diagnostic.target_node == 0);
        rig.target.nodes[0].name = "motion";
        rig.target.nodes[1].name = "other_root";
        NodeTemplate[] nodes = alloc::new_array(tmem, NodeTemplate, 2);
        nodes[0] = rig.source[0];
        nodes[1] = { .parent = -1, .name = "new_helper", .local = maths::TRANSFORM_IDENTITY };
        rig.source = nodes;
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.TEMPLATE_LAYOUT_MISMATCH,
        );
    };
}

fn void test_profile_rejects_nonfinite_input_and_composed_reference_range() @test {
    @pool() {
        uint nan_bits = 0x7fc00000;
        float nonfinite = *(float*)&nan_bits;
        ProfileRig rig = profile_forest_rig();
        rig.desc.facing.m00 = nonfinite;
        profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_FACING_BASIS);
        rig.desc.facing = profile_turn({ 0, 1, 0 }, 90).to_matrix();
        rig.desc.source_calibration[0].v.x = nonfinite;
        profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_CALIBRATION);
        rig.desc.source_calibration[0] = quaternion::IDENTITY;
        rig.source[0].local.position.x = nonfinite;
        profile_creation_failure(&rig, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_STATIC_TRANSFORM);
        rig.source[0].local.position.x = 0;
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        rig.clip.tracks[0].values[3] = nonfinite;
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::ASSET_FORMAT_ERROR,
            expected_reason: RetargetReason.INVALID_CLIP,
        );
        foreach (scale : (float[2]){ 1e30f, 1e-30f }) {
            ProfileRig extreme = profile_rig(2, 1);
            extreme.source[0].local.scale = { scale, scale, scale };
            extreme.source[1].parent = 0;
            extreme.source[1].local.scale = { scale, scale, scale };
            profile_map(&extreme, (NodeIndexMapping[1]){ { .source_node = 1, .target_node = 0 } }[..]);
            RetargetDiagnostic diagnostic = profile_creation_failure(
                &extreme, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_STATIC_TRANSFORM,
            );
            assert(diagnostic.source_node == 1 && diagnostic.target_node == retarget::RETARGET_NO_NODE);
        }
    };
}

fn void test_profile_cadence_rejects_collapsed_float_key_indices() @test {
    @pool() {
        ProfileRig rig = profile_forest_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        uint first = 1u << 24;
        uint second = first + 1;
        assert((float)first == (float)second);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.bake_rate = (float)(first + 2);
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::CAPACITY_EXCEEDED,
            expected_reason: RetargetReason.CAPACITY_LIMIT,
            options: options,
        );
        options.bake_rate = 60;
        options.root_translation_scale = 0;
        profile_bake_failure(
            rig: &rig,
            profile: &profile,
            expected_fault: c3d::INVALID_ARGUMENT,
            expected_reason: RetargetReason.INVALID_BAKE_OPTIONS,
            options: options,
        );
    };
}

fn void test_profile_allocation_fault_prefixes_release_outputs_and_preserve_inputs() @test {
    @pool() {
        ProfileRig rig = profile_carrier_rig();
        RetargetProfile profile = profile_prepare(&rig);
        defer retarget::destroy_retarget_profile(&profile);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.EXTRACT;
        uint failures;
        uint successes;
        for (uint budget = 0; budget < 24; budget++) {
            ProfileFaultAllocator allocator = { .backing = mem, .remaining = (sz)budget };
            RetargetDiagnostic diagnostic;
            AnimationClip? attempt = retarget::retarget_with_profile(
                allocator: &allocator,
                source: &rig.clip,
                source_nodes: rig.source,
                target: &rig.target,
                profile: &profile,
                options: options,
                diagnostic: &diagnostic,
            );
            if (catch excuse = attempt) {
                failures++;
                assert(excuse == c3d::CAPACITY_EXCEEDED && diagnostic.reason == RetargetReason.CAPACITY_LIMIT);
            } else {
                successes++;
                AnimationClip result = attempt;
                asset::free_clip(&allocator, &result);
                assert(diagnostic.reason == RetargetReason.NONE);
            }
            assert(allocator.outstanding == 0);
        }
        assert(failures > 0 && successes > 0);
        ProfileFaultAllocator allocator = { .backing = mem };
        RetargetDiagnostic diagnostic;
        bool failed;
        if (catch excuse = retarget::create_retarget_profile(
            allocator: &allocator,
            source_nodes: rig.source,
            target: &rig.target,
            desc: rig.desc,
            diagnostic: &diagnostic,
        )) {
            failed = true;
            assert(excuse == c3d::CAPACITY_EXCEEDED && diagnostic.reason == RetargetReason.CAPACITY_LIMIT);
        }
        assert(failed && allocator.outstanding == 0);
        assert(rig.clip.tracks[0].values[3] == 0.5f);
        assert(rig.target.nodes[0].local.position == (Vec3){ 1, 0, 2 });
    };
}

fn void test_profile_conflicting_mapping_arrays_are_format_errors() @test {
    @pool() {
        ProfileRig rig = profile_rig(1, 1);
        profile_map(&rig, (NodeIndexMapping[1]){ { .source_node = 0, .target_node = 0 } }[..]);
        rig.desc.name_map = (NameMapping[1]){ { .source = "joint", .target = "joint" } }[..];
        RetargetDiagnostic diagnostic = profile_creation_failure(
            &rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.CONFLICTING_MAPPING,
        );
        assert(diagnostic.mapping_row == 0);
        rig.desc.mapping_mode = ProfileMappingMode.BY_NAME;
        diagnostic = profile_creation_failure(&rig, c3d::ASSET_FORMAT_ERROR, RetargetReason.CONFLICTING_MAPPING);
        assert(diagnostic.mapping_row == 0 && diagnostic.source_node == 0 && diagnostic.target_node == 0);
    };
}

fn void test_profile_split_position_overflow_is_transactional_and_unsupported() @test {
    @pool() {
        ProfileRig displacement = profile_forest_rig();
        displacement.clip.tracks[0].interpolation = Interpolation.STEP;
        displacement.clip.tracks[0].values[..] = (float[6]){ -10, 2, 0, 10, 2, 0 }[..];
        RetargetProfile profile = profile_prepare(&displacement);
        defer retarget::destroy_retarget_profile(&profile);
        RetargetBakeOptions options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        options.root_translation_scale = 2e37f;
        options.root_motion = RootMotion.STRIP_XZ;
        RetargetDiagnostic diagnostic = profile_bake_failure(
            rig: &displacement,
            profile: &profile,
            expected_fault: c3d::UNSUPPORTED,
            expected_reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
            options: options,
        );
        assert(diagnostic.source_node == 0 && diagnostic.target_node == 0);
        assert(displacement.clip.tracks[0].values[0] == -10);
        assert(displacement.target.nodes[0].local.position == (Vec3){ 2, 1, -3 });

        ProfileRig compensation = profile_carrier_rig();
        compensation.target.nodes[0].local = profile_transform({ 1, 0, 2 });
        compensation.target.nodes[1].local = profile_transform({ 1, 2, 0 });
        compensation.target.nodes[2].local.position = { -2e38f, 0, 0 };
        compensation.desc.target_calibration[1] = maths::TRANSFORM_IDENTITY.rotation;
        compensation.clip.tracks[0].interpolation = Interpolation.STEP;
        compensation.clip.tracks[0].values[..] = (float[6]){ 0, 0, 0, 10, 0, 0 }[..];
        RetargetProfile carrier = profile_prepare(&compensation);
        defer retarget::destroy_retarget_profile(&carrier);
        options.root_motion = RootMotion.EXTRACT;
        diagnostic = profile_bake_failure(
            rig: &compensation,
            profile: &carrier,
            expected_fault: c3d::UNSUPPORTED,
            expected_reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
            options: options,
        );
        assert(diagnostic.source_node == 1 && diagnostic.target_node == 2);
        assert(compensation.target.nodes[2].local.position == (Vec3){ -2e38f, 0, 0 });

        ProfileRig descendant = profile_forest_rig(0);
        NodeTemplate[] nodes = alloc::new_array(tmem, NodeTemplate, 3);
        nodes[:2] = descendant.target.nodes[..];
        nodes[1].local = maths::TRANSFORM_IDENTITY;
        nodes[2] = {
            .parent = 1,
            .name = "unmapped_child",
            .local = profile_transform({ -2e38f, 0, 0 }),
        };
        descendant.target.nodes = nodes;
        Quat[] calibration = alloc::new_array(tmem, Quat, 3);
        calibration[..] = maths::TRANSFORM_IDENTITY.rotation;
        calibration[0] = descendant.desc.target_calibration[0];
        descendant.desc.target_calibration = calibration;
        descendant.clip.tracks[0].interpolation = Interpolation.STEP;
        descendant.clip.tracks[0].values[..] = (float[6]){ 0, 2, 0, 10, 2, 0 }[..];
        RetargetProfile forest = profile_prepare(&descendant);
        defer retarget::destroy_retarget_profile(&forest);
        options.root_motion = RootMotion.STRIP_XZ;
        diagnostic = profile_bake_failure(
            rig: &descendant,
            profile: &forest,
            expected_fault: c3d::UNSUPPORTED,
            expected_reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
            options: options,
        );
        assert(diagnostic.source_node == 0 && diagnostic.target_node == 2);
        assert(descendant.target.nodes[2].local.position == (Vec3){ -2e38f, 0, 0 });
    };
}
