module c3d::asset::fbx;

import c3d;
import c3d::anim;
import c3d::asset;
import std::math;
import std::sort;
import ufbx;

const String DEFORM_PERCENT @private = "DeformPercent";
const float DEFORM_PERCENT_SCALE @private = 100;
const double KEY_TIME_EPSILON @private = 1e-6; // stepped keys bake one millisecond apart, far above this
const usz VEC3_COMPONENTS @private = 3;
const usz QUAT_COMPONENTS @private = 4;

fn void? convert_animations(Importer* importer) @private {
    ufbx::Scene* scene = importer.scene;
    alloc::Allocator allocator = importer.assets.allocator;
    foreach (stack_index, stack : scene.anim_stacks) {
        AnimationClip clip = convert_stack(importer, stack)!;
        defer catch asset::free_clip(allocator, &clip);
        String key = string::tformat("%s#anim/%d", importer.key, stack_index);
        importer.clips[stack_index] = importer.assets.add_clip_owned(&clip, key)!;
    }
    if (!scene.anim_stacks.len) return;
    importer.template.clips = alloc::new_array(allocator, ClipId, scene.anim_stacks.len);
    importer.template.clips[..] = importer.clips[..];
    return;
}

fn AnimationClip? convert_stack(Importer* importer, ufbx::AnimStack* stack) @private {
    ufbx::Scene* scene = importer.scene;
    alloc::Allocator allocator = importer.assets.allocator;
    ufbx::BakeOpts options = { .trim_start_time = true, .resample_rate = scene.settings.frames_per_second };
    ufbx::BakedAnim*? baking = ufbx::bake_anim(scene, stack.anim, &options);
    if (catch excuse = baking) return load_fault(excuse)~;
    ufbx::BakedAnim* baked = baking;
    defer ufbx::free_baked_anim(baked);

    usz track_count;
    foreach (&node : baked.nodes) {
        if (importer.node_remap[node.typed_id] == NOT_IMPORTED) continue;
        track_count += node_track_count(node);
    }
    foreach (mesh : scene.meshes) {
        if (!has_animated_channel(baked, mesh)) continue;
        track_count += imported_instances(importer, mesh) * live_part_count(mesh);
    }

    AnimationClip clip = {
        .name    = copy_name(allocator, stack.name),
        .tracks  = alloc::new_array(allocator, Track, (sz)track_count),
        .targets = alloc::new_array(allocator, uint, (sz)track_count),
    };
    defer catch asset::free_clip(allocator, &clip);

    usz track_slot;
    usz target_count;
    foreach (&node : baked.nodes) {
        uint template_index = importer.node_remap[node.typed_id];
        if (template_index == NOT_IMPORTED || !node_track_count(node)) continue;
        uint target = target_slot(&clip, &target_count, template_index);
        if (node.translation_keys.len) {
            clip.tracks[track_slot++] = vec3_track(
                allocator: allocator,
                target:    target,
                path:      TargetPath.TRANSLATION,
                keys:      node.translation_keys,
            );
        }
        if (node.rotation_keys.len) clip.tracks[track_slot++] = rotation_track(allocator, target, node.rotation_keys);
        if (node.scale_keys.len) {
            clip.tracks[track_slot++] = vec3_track(
                allocator: allocator,
                target:    target,
                path:      TargetPath.SCALE,
                keys:      node.scale_keys,
            );
        }
    }
    foreach (mesh : scene.meshes) {
        if (!has_animated_channel(baked, mesh)) continue;
        foreach (instance : mesh.instances) {
            uint node_index = importer.node_remap[instance.typed_id];
            if (node_index == NOT_IMPORTED) continue;
            uint child = node_index + 1;
            foreach (&part : mesh.material_parts) {
                if (!part.num_triangles) continue;
                uint target = target_slot(&clip, &target_count, child++);
                clip.tracks[track_slot++] = morph_track(
                    allocator: allocator,
                    target:    target,
                    baked:     baked,
                    mesh:      mesh,
                );
            }
        }
    }

    clip.targets = clip.targets[:target_count];
    foreach (&track : clip.tracks) {
        foreach (time : track.times) clip.duration = math::max(clip.duration, time);
    }
    return clip;
}

fn usz node_track_count(ufbx::BakedNode* node) @private {
    usz count;
    if (node.translation_keys.len) count++;
    if (node.rotation_keys.len) count++;
    if (node.scale_keys.len) count++;
    return count;
}

fn uint target_slot(AnimationClip* clip, usz* target_count, uint template_index) @private {
    for (usz slot = 0; slot < *target_count; slot++) {
        if (clip.targets[slot] == template_index) return (uint)slot;
    }
    uint slot = (uint)*target_count;
    clip.targets[slot] = template_index;
    *target_count += 1;
    return slot;
}

fn Track vec3_track(
    alloc::Allocator allocator,
    uint target,
    TargetPath path,
    ufbx::BakedVec3[] keys,
) @private {
    Track track = {
        .target        = target,
        .path          = path,
        .interpolation = anim::Interpolation.LINEAR,
        .times         = alloc::new_array(allocator, float, keys.len),
        .values        = alloc::new_array(allocator, float, keys.len * VEC3_COMPONENTS),
    };
    foreach (usz index, key : keys) {
        track.times[index] = (float)key.time;
        track.values[index * VEC3_COMPONENTS] = (float)key.value.x;
        track.values[index * VEC3_COMPONENTS + 1] = (float)key.value.y;
        track.values[index * VEC3_COMPONENTS + 2] = (float)key.value.z;
    }
    return track;
}

fn Track rotation_track(alloc::Allocator allocator, uint target, ufbx::BakedQuat[] keys) @private {
    Track track = {
        .target        = target,
        .path          = TargetPath.ROTATION,
        .interpolation = anim::Interpolation.LINEAR,
        .times         = alloc::new_array(allocator, float, keys.len),
        .values        = alloc::new_array(allocator, float, keys.len * QUAT_COMPONENTS),
    };
    foreach (usz index, key : keys) {
        track.times[index] = (float)key.time;
        track.values[index * QUAT_COMPONENTS] = (float)key.value.x;
        track.values[index * QUAT_COMPONENTS + 1] = (float)key.value.y;
        track.values[index * QUAT_COMPONENTS + 2] = (float)key.value.z;
        track.values[index * QUAT_COMPONENTS + 3] = (float)key.value.w;
    }
    return track;
}

fn ufbx::BakedVec3[] channel_keys(ufbx::BakedAnim* baked, ufbx::BlendChannel* channel) @private {
    foreach (&element : baked.elements) {
        if (element.element_id != channel.element_id) continue;
        foreach (&prop : element.props) {
            if (prop.name == DEFORM_PERCENT) return prop.keys;
        }
    }
    return {};
}

fn bool has_animated_channel(ufbx::BakedAnim* baked, ufbx::Mesh* mesh) @private {
    @each_channel(mesh; ufbx::BlendChannel* channel) {
        if (channel_keys(baked, channel).len) return true;
    };
    return false;
}

fn Track morph_track(
    alloc::Allocator allocator,
    uint target,
    ufbx::BakedAnim* baked,
    ufbx::Mesh* mesh,
) @private {
    usz key_total;
    @each_channel(mesh; ufbx::BlendChannel* channel) {
        key_total += channel_keys(baked, channel).len;
    };
    double[] times = alloc::new_array(tmem, double, (sz)key_total);
    usz filled;
    @each_channel(mesh; ufbx::BlendChannel* channel) {
        foreach (key : channel_keys(baked, channel)) times[filled++] = key.time;
    };
    sort::quicksort(times);
    usz unique;
    foreach (time : times) {
        if (unique && time - times[unique - 1] <= KEY_TIME_EPSILON) continue;
        times[unique++] = time;
    }

    usz channels = channel_count(mesh);
    Track track = {
        .target        = target,
        .path          = TargetPath.MORPH_WEIGHTS,
        .interpolation = anim::Interpolation.LINEAR,
        .times         = alloc::new_array(allocator, float, (sz)unique),
        .values        = alloc::new_array(allocator, float, (sz)(unique * channels)),
    };
    foreach (usz key_index, time : times[:unique]) {
        track.times[key_index] = (float)time;
        usz channel_index;
        @each_channel(mesh; ufbx::BlendChannel* channel) {
            ufbx::BakedVec3[] keys = channel_keys(baked, channel);
            float weight = keys.len ? sample_percent(keys, time) / DEFORM_PERCENT_SCALE : (float)channel.weight;
            track.values[key_index * channels + channel_index++] = weight;
        };
    }
    return track;
}

fn float sample_percent(ufbx::BakedVec3[] keys, double time) @private {
    if (time <= keys[0].time) return (float)keys[0].value.x;
    for (usz index = 1; index < keys.len; index++) {
        if (time > keys[index].time) continue;
        ufbx::BakedVec3 previous = keys[index - 1];
        ufbx::BakedVec3 next = keys[index];
        double span = next.time - previous.time;
        double along = span > 0 ? (time - previous.time) / span : 1;
        return (float)(previous.value.x + (next.value.x - previous.value.x) * along);
    }
    return (float)keys[^1].value.x;
}
