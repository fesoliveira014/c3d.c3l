module c3d::anim;

import c3d;
import c3d::asset;
import c3d::scene;
import std::math;

<*
 Advance every crowd pose by dt and write palettes, morph weights and part batches.
 @param [&in] assets : "Holds every crowd's model, skeleton and clips."
 @param [&inout] scene : "Pending crowds skipped unchanged; prepared runtime is updated."
*>
fn void crowd_update(AssetStore* assets, Scene* scene, float dt) {
    scene.@each(AnimatedCrowd; Entity entity, AnimatedCrowd* crowd) {
        if (crowd.is_prepared()) update_crowd(assets, scene, crowd, dt);
    };
}

<*
 @require assets.models.is_live(crowd.model)
*>
fn void update_crowd(AssetStore* assets, Scene* scene, AnimatedCrowd* crowd, float dt) @local {
    ModelTemplate* template = &assets.model(crowd.model).data;
    ModelSkin* skin = &template.skins[0];
    Skeleton* skeleton = &assets.skeleton(skin.skeleton).data;
    @pool() {
        float[] sample = alloc::new_array(tmem, float, (sz)math::max((usz)4, (usz)crowd.morph_stride));
        for (uint instance = 0; instance < crowd.count; instance++) {
            CrowdPose* pose = &crowd.poses[instance];
            AnimationClip* clip = &assets.clip(pose.clip).data;
            advance_pose(pose, clip.duration, dt);

            foreach (index, &node : template.nodes) crowd.scratch_locals[index] = node.local;
            uint[] cursors = crowd.cursors[instance * crowd.max_tracks:crowd.max_tracks];
            foreach (track_index, &track : clip.tracks) {
                uint node = clip.targets[track.target];
                float[] value = sample[:track.stride()];
                sample_track(track, pose.time, &cursors[track_index], value);
                write_crowd_channel(crowd, instance, node, track.path, value);
            }

            foreach (index, &node : template.nodes) {
                Mat4 local = crowd.scratch_locals[index].to_mat4();
                crowd.scratch_worlds[index] = node.parent < 0 ? local : crowd.scratch_worlds[node.parent].mul(local);
            }
            Mat4[] palette = crowd.palettes[instance * crowd.joint_count:crowd.joint_count];
            foreach (joint, node : skin.joint_nodes) {
                palette[joint] = crowd.scratch_worlds[node].mul(skeleton.inverse_bind[joint]);
            }
        }
    };
    scene.write_crowd_batches(crowd);
}

fn void advance_pose(CrowdPose* pose, float duration, float dt) @local {
    pose.time += dt * pose.speed;
    if (duration == 0) {
        pose.time = 0;
    } else if (pose.loop) {
        pose.time -= math::floor(pose.time / duration) * duration;
    } else {
        pose.time = math::clamp(pose.time, 0.0f, duration);
    }
}

fn void write_crowd_channel(
    AnimatedCrowd* crowd,
    uint instance,
    uint node,
    TargetPath path,
    float[] value,
) @local {
    Transform* local = &crowd.scratch_locals[node];
    switch (path) {
        case TRANSLATION:
            local.position = { value[0], value[1], value[2] };
        case ROTATION:
            Vec4 rotation = { value[0], value[1], value[2], value[3] };
            if (rotation.dot(local.rotation.v) < 0) rotation = -rotation;
            local.rotation = { .v = rotation };
        case SCALE:
            local.scale = { value[0], value[1], value[2] };
        case MORPH_WEIGHTS:
            foreach (&part : crowd.parts) {
                if (part.template_node != node) continue;
                usz base = (usz)instance * crowd.morph_stride + part.target_offset;
                crowd.morph_weights[base:part.target_count] = value[:part.target_count];
            }
    }
}
