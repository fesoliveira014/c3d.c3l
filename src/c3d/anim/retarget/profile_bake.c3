module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::math;

const Vec3 PROFILE_YAW_UP @private = { 0, 1, 0 };

struct ProfileChannels @private {
    Track* translation;
    Track* rotation;
    Track* scale;
}

struct ProfileOutputTracks @private {
    Track* translation;
    Track* rotation;
    Track* scale;
}

struct ProfilePaths @private {
    bool rotation;
    bool translation;
    bool scale;
}

<*
 Bake an independent clip through immutable calibrated model frames.
 @param allocator : "Owns every array of the returned clip."
 @param [&in] source : "Borrowed only until return."
 @param source_nodes : "Exact prepared source template."
 @param [&in] target : "Exact prepared target template."
 @param [&in] profile : "Immutable borrow; never retained by the clip."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn AnimationClip? retarget_with_profile(
    Allocator allocator,
    AnimationClip* source,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetProfile* profile,
    RetargetBakeOptions options = RETARGET_BAKE_OPTIONS_DEFAULT,
) {
    profile.validate_templates(source_nodes, target)!;

    return bake_profile_clip(
        allocator: allocator,
        source: source,
        target: target,
        profile: profile,
        options: options,
    );
}

fn AnimationClip? bake_profile_clip(
    Allocator allocator,
    AnimationClip* source,
    ModelTemplate* target,
    RetargetProfile* profile,
    RetargetBakeOptions options,
) @private {
    ProfileData* data = (ProfileData*)profile.data;
    validate_profile_bake_options(data, options, source.duration)!;

    AnimationClip clip;
    defer catch asset::free_clip(allocator, &clip);

    @pool() {
        ProfileChannels[] channels = alloc::new_array(tmem, ProfileChannels, data.source_nodes.len);
        bind_profile_clip(
            clip: source,
            data: data,
            target: target,
            channels: channels,
            allow_partial: options.allow_partial,
        )!;

        sz track_count;

        for (uint index = 0; index < data.target_nodes.len; index++) {
            ProfilePaths paths = profile_paths(data, index, options.root_motion);
            track_count += (sz)paths.rotation + (sz)paths.translation + (sz)paths.scale;
        }

        foreach (&track : source.tracks) if (profile_copies(data, source, track)) track_count++;

        float[] times = bake_times(tmem, source.duration, options.bake_rate);
        clip = {
            .name = source.name.copy(allocator),
            .duration = source.duration,
            .tracks = alloc::new_array(allocator, Track, track_count),
            .targets = alloc::new_array(allocator, uint, track_count),
            .events = copy_events(allocator, source.events),
        };

        ProfileOutputTracks[] output = alloc::new_array(tmem, ProfileOutputTracks, target.nodes.len);
        usz track_slot;
        usz target_count;

        for (uint index = 0; index < data.target_nodes.len; index++) {
            ProfilePaths paths = profile_paths(data, index, options.root_motion);
            if (paths.rotation) {
                output[index].rotation = &clip.tracks[track_slot++];
                *output[index].rotation = baked_track(
                    allocator: allocator,
                    times: times,
                    path: TargetPath.ROTATION,
                    target: target_slot(&clip, &target_count, index),
                );
            }

            if (paths.translation) {
                output[index].translation = &clip.tracks[track_slot++];
                *output[index].translation = baked_track(
                    allocator: allocator,
                    times: times,
                    path: TargetPath.TRANSLATION,
                    target: target_slot(&clip, &target_count, index),
                );
            }

            if (paths.scale) {
                output[index].scale = &clip.tracks[track_slot++];
                *output[index].scale = baked_track(
                    allocator: allocator,
                    times: times,
                    path: TargetPath.SCALE,
                    target: target_slot(&clip, &target_count, index),
                );
            }
        }

        foreach (&track : source.tracks) {
            if (!profile_copies(data, source, track)) continue;
            uint destination = data.source_nodes[source.targets[track.target]].mapped;
            clip.tracks[track_slot++] = copy_track(allocator, track, target_slot(&clip, &target_count, destination));
        }

        clip.targets = clip.targets[:target_count];

        Transform[] source_world = alloc::new_array(tmem, Transform, data.source_nodes.len);
        Transform[] target_world = alloc::new_array(tmem, Transform, target.nodes.len);
        Vec3 initial_motion;
        float previous_yaw;
        double unwrapped_yaw;

        foreach (usz key, time : times) {
            sample_profile_source(
                data: data,
                channels: channels,
                time: time,
                worlds: source_world,
            )!;
            compose_profile_target(
                data: data,
                channels: channels,
                source_world: source_world,
                target_world: target_world,
                time: time,
                translation_scale: options.root_translation_scale,
            );

            Vec3 horizontal;
            if (data.target_motion_node != RETARGET_NO_NODE) {
                Vec3 motion = target_world[data.target_motion_node].position;
                if (key == 0) initial_motion = motion;
                horizontal = { motion.x - initial_motion.x, 0, motion.z - initial_motion.z };
            }

            if (options.root_motion == RootMotion.EXTRACT) {
                float current_yaw = profile_yaw_angle(target_world[data.target_motion_node].rotation);
                if (key > 0) unwrapped_yaw += profile_wrap_yaw(current_yaw - previous_yaw);
                previous_yaw = current_yaw;
                target_world[data.target_carrier].position += horizontal;
                target_world[data.target_carrier].rotation = profile_yaw_rotation(unwrapped_yaw)
                  .mul(target_world[data.target_carrier].rotation).normalize();
            }

            foreach (uint index, &node : data.target_nodes) {
                Transform world = target_world[index];
                if (options.root_motion == RootMotion.STRIP_XZ && index == data.target_boundary) {
                    world.position -= horizontal;
                }

                Transform parent = node.parent < 0 ? maths::TRANSFORM_IDENTITY : target_world[node.parent];
                Transform local = profile_relative(parent, world);
                if (output[index].rotation) write_rotation_key(output[index].rotation, key, local.rotation);
                if (output[index].translation) write_translation_key(output[index].translation, key, local.position);
                if (output[index].scale) write_translation_key(output[index].scale, key, local.scale);
            }
        }
    };

    return clip;
}

fn float profile_yaw_angle(Quat rotation) @private {
    Quat twist = maths::twist_about(rotation, PROFILE_YAW_UP);

    return 2 * math::atan2(twist.v.y, twist.v.w);
}

fn float profile_wrap_yaw(float value) @private => math::atan2(math::sin(value), math::cos(value));

fn Quat profile_yaw_rotation(double angle) @private {
    double half = angle / 2;

    return { .v = { 0, (float)math::sin(half), 0, (float)math::cos(half) } };
}

fn void? validate_profile_bake_options(ProfileData* data, RetargetBakeOptions options, float duration) @private {
    bool valid = math::is_finite(options.bake_rate) && options.bake_rate > 0
        && math::is_finite(options.root_translation_scale) && options.root_translation_scale > 0
        && (options.root_motion == RootMotion.KEEP || data.target_motion_node != RETARGET_NO_NODE)
        && (options.root_motion != RootMotion.EXTRACT || data.target_carrier != RETARGET_NO_NODE);
    if (!valid) return c3d::INVALID_ARGUMENT~;
    if ((double)duration * options.bake_rate > PROFILE_MAX_INTERVALS) return c3d::CAPACITY_EXCEEDED~;
}

fn ProfilePaths profile_paths(ProfileData* data, uint index, RootMotion root_motion) @private {
    ProfileNode* node = &data.target_nodes[index];
    bool extract = root_motion == RootMotion.EXTRACT;
    bool carrier = extract && index == data.target_carrier;
    bool boundary = root_motion != RootMotion.KEEP && index == data.target_boundary;

    return {
        .rotation = node.mapped != RETARGET_NO_NODE || carrier || (extract && boundary),
        .translation = node.motion || boundary || carrier,
        .scale = node.motion,
    };
}

fn bool profile_copies(ProfileData* data, AnimationClip* source, Track* track) @private {
    uint destination = data.source_nodes[source.targets[track.target]].mapped;
    if (destination == RETARGET_NO_NODE) return false;

    return track.path == TargetPath.MORPH_WEIGHTS
        || (track.path == TargetPath.SCALE && !data.target_nodes[destination].motion);
}

fn Transform profile_sample_local(ProfileNode* node, ProfileChannels channels, float time) @private {
    Transform local = node.authored;
    float[4] values;
    uint cursor;
    if (channels.translation) {
        anim::sample_track(
            track: channels.translation,
            time: time,
            cursor: &cursor,
            out: values[:3],
        );
        local.position = { values[0], values[1], values[2] };
    }

    if (channels.rotation) {
        anim::sample_track(
            track: channels.rotation,
            time: time,
            cursor: &cursor,
            out: values[..],
        );
        local.rotation = { .v = { values[0], values[1], values[2], values[3] } };
    }

    if (channels.scale) {
        anim::sample_track(
            track: channels.scale,
            time: time,
            cursor: &cursor,
            out: values[:3],
        );
        local.scale = { values[0], values[1], values[2] };
    }

    return local;
}

fn void? sample_profile_source(
    ProfileData* data,
    ProfileChannels[] channels,
    float time,
    Transform[] worlds,
) @private {
    foreach (uint index, &node : data.source_nodes) {
        if (!node.consumed) continue;
        Transform local = profile_sample_local(node, channels[index], time);
        if (node.requires_uniform_scale && !profile_uniform_scale(local.scale)) return c3d::UNSUPPORTED~;

        local.rotation = local.rotation.normalize();
        if (!node.requires_uniform_scale) local.scale = { 1, 1, 1 };
        worlds[index] = node.parent < 0 ? local : profile_compose(worlds[node.parent], local);
    }
}

fn void compose_profile_target(
    ProfileData* data,
    ProfileChannels[] channels,
    Transform[] source_world,
    Transform[] target_world,
    float time,
    float translation_scale,
) @private {
    foreach (uint index, &node : data.target_nodes) {
        Transform local = node.authored;
        Transform parent = node.parent < 0 ? maths::TRANSFORM_IDENTITY : target_world[node.parent];
        if (node.mapped != RETARGET_NO_NODE) {
            ProfileNode* source = &data.source_nodes[node.mapped];
            Transform sampled = source_world[node.mapped];
            Quat desired_rotation = data.facing.mul(sampled.rotation.mul(source.reference.rotation.conjugate()))
              .mul(data.facing.conjugate()).mul(node.reference.rotation).normalize();
            local.rotation = parent.rotation.conjugate().mul(desired_rotation).normalize();
            if (node.motion) {
                Transform desired = {
                    .position = node.reference.position + data.facing.rotate_vec3(
                        sampled.position - source.reference.position,
                    ) * translation_scale,
                    .rotation = desired_rotation,
                    .scale = node.reference.scale * (sampled.scale.x / source.reference.scale.x),
                };

                local = profile_relative(parent, desired);
            } else if (channels[node.mapped].scale) {
                local.scale = profile_sample_local(source, channels[node.mapped], time).scale;
            }
        }

        target_world[index] = profile_compose(parent, local);
    }
}
