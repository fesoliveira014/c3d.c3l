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
    bool tracked;
}

struct ProfileOutputTracks @private {
    Track* translation;
    Track* rotation;
    Track* scale;
}

<*
 Bake an independent clip through immutable calibrated model frames.
 @param allocator : "Owns every array of the returned clip."
 @param [&in] source : "Borrowed only until return."
 @param source_nodes : "Exact prepared source template."
 @param [&in] target : "Exact prepared target template."
 @param [&in] profile : "Immutable borrow; never retained by the clip."
 @param [inout] diagnostic : "Optional deterministic failure context."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn AnimationClip? retarget_with_profile(
    Allocator allocator,
    AnimationClip* source,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetProfile* profile,
    RetargetBakeOptions options = RETARGET_BAKE_OPTIONS_DEFAULT,
    RetargetDiagnostic* diagnostic = null,
) {
    clear_retarget_diagnostic(diagnostic);

    defer catch {
        if (diagnostic && diagnostic.reason == RetargetReason.NONE) {
            diagnostic.reason = RetargetReason.CAPACITY_LIMIT;
        }
    }

    profile.validate_templates(source_nodes, target, diagnostic)!;
    ProfileData* data = (ProfileData*)profile.data;
    validate_profile_bake_options(data, options, diagnostic)!;

    AnimationClip clip;

    defer catch asset::free_clip(allocator, &clip);

    @pool() {
        ProfileChannels[] channels = alloc::new_array_try(tmem, ProfileChannels, source_nodes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        validate_profile_clip(
            clip: source,
            data: data,
            target: target,
            channels: channels,
            allow_partial: options.allow_partial,
            diagnostic: diagnostic,
        )!;
        float[] times = profile_bake_times(source.duration, options.bake_rate, diagnostic)!;
        usz track_count = profile_track_count(source, data, options.root_motion);
        if (track_count > uint::max) return c3d::CAPACITY_EXCEEDED~;

        clip.duration = source.duration;
        clip.name = profile_copy_name(allocator, source.name)!;
        clip.tracks = alloc::new_array_try(allocator, Track, (sz)track_count) ?? c3d::CAPACITY_EXCEEDED~!;
        clip.targets = alloc::new_array_try(allocator, uint, (sz)track_count) ?? c3d::CAPACITY_EXCEEDED~!;
        clip.events = alloc::new_array_try(allocator, ClipEvent, source.events.len) ?? c3d::CAPACITY_EXCEEDED~!;
        clip.events[..] = source.events[..];
        ProfileOutputTracks[] output = alloc::new_array_try(tmem, ProfileOutputTracks, target.nodes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        usz track_slot;
        usz target_count;

        foreach (uint index, &node : data.target_nodes) {
            bool carrier = options.root_motion == RootMotion.EXTRACT && index == data.target_carrier;
            bool boundary = options.root_motion != RootMotion.KEEP && node.boundary;
            if (node.mapped != RETARGET_NO_NODE
              || (options.root_motion == RootMotion.EXTRACT && (carrier || node.boundary))) {
                output[index].rotation = &clip.tracks[track_slot++];
                *output[index].rotation = profile_generated_track(
                    allocator: allocator,
                    times: times,
                    path: TargetPath.ROTATION,
                    target: target_slot(&clip, &target_count, index),
                )!;
            }

            if (node.motion || boundary || carrier) {
                output[index].translation = &clip.tracks[track_slot++];
                *output[index].translation = profile_generated_track(
                    allocator: allocator,
                    times: times,
                    path: TargetPath.TRANSLATION,
                    target: target_slot(&clip, &target_count, index),
                )!;
            }

            if (node.motion) {
                output[index].scale = &clip.tracks[track_slot++];
                *output[index].scale = profile_generated_track(
                    allocator: allocator,
                    times: times,
                    path: TargetPath.SCALE,
                    target: target_slot(&clip, &target_count, index),
                )!;
            }
        }

        foreach (&track : source.tracks) {
            uint source_node = source.targets[track.target];
            uint destination = data.source_nodes[source_node].mapped;
            if (destination == RETARGET_NO_NODE) continue;
            if (track.path != TargetPath.MORPH_WEIGHTS
                && (track.path != TargetPath.SCALE || data.target_nodes[destination].motion)) continue;
            clip.tracks[track_slot++] = profile_copy_track(
                allocator,
                track,
                target_slot(&clip, &target_count, destination),
            )!;
        }

        clip.targets = clip.targets[:target_count];

        Transform[] source_world = alloc::new_array_try(tmem, Transform, source_nodes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        Transform[] target_world = alloc::new_array_try(tmem, Transform, target.nodes.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        Vec3 initial_motion;
        float previous_yaw;
        double unwrapped_yaw;

        foreach (usz key, time : times) {
            sample_profile_source(
                data: data,
                channels: channels,
                time: time,
                worlds: source_world,
                diagnostic: diagnostic,
            )!;
            compose_profile_target(
                data: data,
                channels: channels,
                source_world: source_world,
                target_world: target_world,
                time: time,
                translation_scale: options.root_translation_scale,
                diagnostic: diagnostic,
            )!;
            Vec3 horizontal;
            if (data.target_motion_node != RETARGET_NO_NODE) {
                Vec3 motion = target_world[data.target_motion_node].position;
                if (key == 0) initial_motion = motion;
                horizontal = { motion.x - initial_motion.x, 0, motion.z - initial_motion.z };
            }

            if (options.root_motion != RootMotion.KEEP && !profile_finite_vec(horizontal)) {
                return profile_failure(
                    diagnostic: diagnostic,
                    excuse: c3d::UNSUPPORTED,
                    reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                    source_node: data.source_motion_node,
                    target_node: data.target_motion_node,
                )~;
            }

            switch (options.root_motion) {
                case KEEP: break;
                case STRIP_XZ:
                    foreach (index, &node : data.target_nodes) {
                        if (node.controlled) target_world[index].position -= horizontal;
                    }
                case EXTRACT:
                    float current_yaw = profile_yaw_angle(target_world[data.target_motion_node].rotation);
                    if (key > 0) unwrapped_yaw += profile_wrap_yaw(current_yaw - previous_yaw);
                    previous_yaw = current_yaw;
                    target_world[data.target_carrier].position += horizontal;
                    target_world[data.target_carrier].rotation = profile_yaw_rotation(unwrapped_yaw)
                      .mul(target_world[data.target_carrier].rotation).normalize();
            }

            foreach (uint index, &node : data.target_nodes) {
                bool shifted = options.root_motion == RootMotion.STRIP_XZ ? node.controlled
                  : options.root_motion == RootMotion.EXTRACT && index == data.target_carrier;
                if (shifted && !profile_finite_vec(target_world[index].position)) {
                    return profile_failure(
                        diagnostic: diagnostic,
                        excuse: c3d::UNSUPPORTED,
                        reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                        source_node: data.source_motion_node,
                        target_node: index,
                    )~;
                }

                Transform parent = node.parent < 0 ? maths::TRANSFORM_IDENTITY : target_world[node.parent];
                Transform local = profile_relative(parent, target_world[index]);
                if (output[index].rotation) write_rotation_key(output[index].rotation, key, local.rotation);
                if (output[index].translation) {
                    if (options.root_motion != RootMotion.KEEP && !profile_finite_vec(local.position)) {
                        return profile_failure(
                            diagnostic: diagnostic,
                            excuse: c3d::UNSUPPORTED,
                            reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                            source_node: data.source_motion_node,
                            target_node: index,
                        )~;
                    }

                    write_translation_key(output[index].translation, key, local.position);
                }

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

fn void? validate_profile_bake_options(
    ProfileData* data,
    RetargetBakeOptions options,
    RetargetDiagnostic* diagnostic,
) @private {
    if (!math::is_finite(options.bake_rate) || options.bake_rate <= 0
        || !math::is_finite(options.root_translation_scale) || options.root_translation_scale <= 0) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_BAKE_OPTIONS)~;
    }

    if (options.root_motion != RootMotion.KEEP && data.target_motion_node == RETARGET_NO_NODE) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_MOTION_PAIR)~;
    }

    if (options.root_motion == RootMotion.EXTRACT && data.target_carrier == RETARGET_NO_NODE) {
        return profile_failure(diagnostic, c3d::INVALID_ARGUMENT, RetargetReason.INVALID_MOTION_CARRIER)~;
    }
}

fn float[]? profile_bake_times(float duration, float rate, RetargetDiagnostic* diagnostic) @private {
    double intervals_float = duration == 0 ? 0 : math::max(1.0, math::ceil((double)duration * rate - PROFILE_KEY_SNAP));
    if (intervals_float > PROFILE_MAX_INTERVALS) {
        return profile_failure(diagnostic, c3d::CAPACITY_EXCEEDED, RetargetReason.CAPACITY_LIMIT)~;
    }

    uint intervals = (uint)intervals_float;
    float[] times = alloc::new_array_try(tmem, float, (sz)intervals + 1) ?? c3d::CAPACITY_EXCEEDED~!;

    for (uint key = 0; key < intervals; key++) {
        float time = key / rate;
        if (time >= duration) {
            intervals = key;
            break;
        }

        if (!math::is_finite(time) || (key > 0 && time <= times[key - 1])) {
            return profile_failure(diagnostic, c3d::CAPACITY_EXCEEDED, RetargetReason.CAPACITY_LIMIT)~;
        }

        times[key] = time;
    }

    times[intervals] = duration;

    return times[:(usz)intervals + 1];
}

fn usz profile_track_count(AnimationClip* source, ProfileData* data, RootMotion root_motion) @private {
    usz count;

    foreach (uint index, &node : data.target_nodes) {
        if (node.mapped != RETARGET_NO_NODE
          || (root_motion == RootMotion.EXTRACT && (index == data.target_carrier || node.boundary))) count++;
        if (node.motion || (root_motion != RootMotion.KEEP && node.boundary)
            || (root_motion == RootMotion.EXTRACT && index == data.target_carrier)) count++;
        if (node.motion) count++;
    }

    foreach (&track : source.tracks) {
        uint destination = data.source_nodes[source.targets[track.target]].mapped;
        if (destination == RETARGET_NO_NODE) continue;
        if (track.path == TargetPath.MORPH_WEIGHTS
            || (track.path == TargetPath.SCALE && !data.target_nodes[destination].motion)) count++;
    }

    return count;
}

fn String? profile_copy_name(Allocator allocator, String name) @private {
    char[] copy = alloc::new_array_try(allocator, char, name.len) ?? c3d::CAPACITY_EXCEEDED~!;
    copy[..] = name[..];

    return (String)copy;
}

fn Track? profile_generated_track(
    Allocator allocator,
    float[] times,
    TargetPath path,
    uint target,
) @private {
    Track track = { .target = target, .path = path, .interpolation = Interpolation.LINEAR };

    defer catch {
        alloc::free(allocator, track.times.ptr);
        alloc::free(allocator, track.values.ptr);
    }

    usz stride = path == TargetPath.ROTATION ? 4 : 3;
    if (times.len > (usz)sz::max / (stride * float::size)) return c3d::CAPACITY_EXCEEDED~;

    track.times = alloc::new_array_try(allocator, float, times.len) ?? c3d::CAPACITY_EXCEEDED~!;
    track.values = alloc::new_array_try(allocator, float, (sz)(times.len * stride))
      ?? c3d::CAPACITY_EXCEEDED~!;
    track.times[..] = times[..];

    return track;
}

fn Track? profile_copy_track(Allocator allocator, Track* source, uint target) @private {
    Track track = { .target = target, .path = source.path, .interpolation = source.interpolation };

    defer catch {
        alloc::free(allocator, track.times.ptr);
        alloc::free(allocator, track.values.ptr);
    }

    track.times = alloc::new_array_try(allocator, float, source.times.len) ?? c3d::CAPACITY_EXCEEDED~!;
    track.values = alloc::new_array_try(allocator, float, source.values.len) ?? c3d::CAPACITY_EXCEEDED~!;
    track.times[..] = source.times[..];
    track.values[..] = source.values[..];

    return track;
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
    RetargetDiagnostic* diagnostic,
) @private {
    foreach (uint index, &node : data.source_nodes) {
        if (!node.consumed) continue;
        Transform local = profile_sample_local(node, channels[index], time);
        if (!profile_finite_vec(local.position) || !profile_unit_rotation(local.rotation)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::ASSET_FORMAT_ERROR,
                reason: RetargetReason.INVALID_CLIP,
                source_node: index,
            )~;
        }

        if (node.requires_uniform_scale && !profile_uniform_scale(local.scale)) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::UNSUPPORTED,
                reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                source_node: index,
            )~;
        }

        local.rotation = local.rotation.normalize();
        if (!node.requires_uniform_scale) local.scale = { 1, 1, 1 };
        worlds[index] = node.parent < 0 ? local : profile_compose(worlds[node.parent], local);
        if (!profile_valid_transform(worlds[index])) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::UNSUPPORTED,
                reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                source_node: index,
            )~;
        }
    }
}

fn void? compose_profile_target(
    ProfileData* data,
    ProfileChannels[] channels,
    Transform[] source_world,
    Transform[] target_world,
    float time,
    float translation_scale,
    RetargetDiagnostic* diagnostic,
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
        if (!profile_finite_vec(target_world[index].position) || !profile_unit_rotation(target_world[index].rotation)
          || (node.requires_uniform_scale && !profile_uniform_scale(target_world[index].scale))) {
            return profile_failure(
                diagnostic: diagnostic,
                excuse: c3d::UNSUPPORTED,
                reason: RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM,
                source_node: node.mapped,
                target_node: index,
            )~;
        }
    }
}
