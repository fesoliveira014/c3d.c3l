module c3d::asset::gltf;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import gltf;
import std::math;

const int NO_JOINT_PARENT @private = -1;
const usz MAT4_COMPONENTS @private = 16;
const usz SCALAR_COMPONENTS @private = 1;

fn void? convert_skins(Importer* importer) @private {
    gltf::Data* data = importer.data;
    Allocator allocator = importer.assets.allocator;
    foreach (skin_index, &skin : data.skins) {
        Skeleton skeleton = convert_skeleton(importer, skin)!;
        defer catch asset::free_skeleton(allocator, &skeleton);
        String key = string::tformat("%s#skeleton/%d", importer.key, skin_index);
        importer.skeletons[skin_index] = importer.assets.add_skeleton_owned(&skeleton, key)!;
    }

    usz skin_count;
    foreach (node_index, &node : data.nodes) {
        if (node.skin && node.mesh && importer.node_remap[node_index] != usz::max) {
            skin_count += node.mesh.primitives.len;
        }
    }
    if (!skin_count) return;
    ModelSkin[] skins = alloc::new_array(allocator, ModelSkin, (sz)skin_count);
    importer.template.skins = skins;
    usz slot;
    foreach (node_index, &node : data.nodes) {
        if (!node.skin || !node.mesh || importer.node_remap[node_index] == usz::max) continue;
        usz mesh_node = importer.node_remap[node_index];
        SkeletonId skeleton = importer.skeletons[gltf::skin_index(data, node.skin)];
        for (usz primitive = 0; primitive < node.mesh.primitives.len; primitive++) {
            skins[slot++] = {
                .mesh_node   = (uint)(mesh_node + 1 + primitive),
                .skeleton    = skeleton,
                .joint_nodes = joint_template_indices(importer, node.skin)!,
            };
        }
    }
    return;
}

fn Skeleton? convert_skeleton(Importer* importer, gltf::Skin* skin) @private {
    gltf::Data* data = importer.data;
    Allocator allocator = importer.assets.allocator;
    usz joint_count = skin.joints.len;
    uint[] joint_nodes = joint_template_indices(importer, skin)!;
    defer alloc::free(allocator, joint_nodes.ptr);

    Skeleton skeleton = {
        .joint_names  = alloc::new_array(allocator, String, (sz)joint_count),
        .parents      = alloc::new_array(allocator, int, (sz)joint_count),
        .rest_pose    = alloc::new_array(allocator, Transform, (sz)joint_count),
        .inverse_bind = alloc::new_array(allocator, Mat4, (sz)joint_count),
    };
    defer catch asset::free_skeleton(allocator, &skeleton);

    foreach (index, joint : skin.joints) {
        skeleton.joint_names[index] = copy_name(allocator, joint.name);
        skeleton.rest_pose[index] = importer.template.nodes[joint_nodes[index]].local;
        skeleton.parents[index] = NO_JOINT_PARENT;
        if (!joint.parent) continue;
        foreach (candidate, other : skin.joints) {
            if (other == joint.parent) {
                skeleton.parents[index] = (int)candidate;
                break;
            }
        }
    }

    if (skin.inverse_bind_matrices) {
        float[] floats = read_floats(importer, skin.inverse_bind_matrices, MAT4_COMPONENTS, joint_count)!;
        defer alloc::free(allocator, floats.ptr);
        skeleton.inverse_bind[..] = ((Mat4*)floats.ptr)[:joint_count];
    } else {
        Mat4 identity = matrix::IDENTITY4;
        skeleton.inverse_bind[..] = identity;
    }
    return skeleton;
}

fn uint[]? joint_template_indices(Importer* importer, gltf::Skin* skin) @private {
    gltf::Data* data = importer.data;
    uint[] joints = alloc::new_array(importer.assets.allocator, uint, (sz)skin.joints.len);
    defer catch alloc::free(importer.assets.allocator, joints.ptr);
    foreach (index, joint : skin.joints) {
        usz template_index = importer.node_remap[gltf::node_index(data, joint)];
        if (template_index == usz::max) return c3d::ASSET_FORMAT_ERROR~;
        joints[index] = (uint)template_index;
    }
    return joints;
}

fn void? convert_animations(Importer* importer) @private {
    gltf::Data* data = importer.data;
    Allocator allocator = importer.assets.allocator;
    foreach (animation_index, &animation : data.animations) {
        AnimationClip clip = convert_clip(importer, animation)!;
        defer catch asset::free_clip(allocator, &clip);
        String key = string::tformat("%s#anim/%d", importer.key, animation_index);
        importer.clips[animation_index] = importer.assets.add_clip_owned(&clip, key)!;
    }
    if (!data.animations.len) return;
    importer.template.clips = alloc::new_array(allocator, ClipId, data.animations.len);
    importer.template.clips[..] = importer.clips[..];
    return;
}

fn AnimationClip? convert_clip(Importer* importer, gltf::Animation* animation) @private {
    gltf::Data* data = importer.data;
    Allocator allocator = importer.assets.allocator;

    usz track_count;
    foreach (&channel : animation.channels) {
        if (!channel.target_node) continue;
        track_count += channel.target_path == gltf::AnimationPathType.WEIGHTS
            ? primitive_count_of(channel.target_node)
            : 1;
    }

    AnimationClip clip = {
        .name    = copy_name(allocator, animation.name),
        .tracks  = alloc::new_array(allocator, Track, (sz)track_count),
        .targets = alloc::new_array(allocator, uint, (sz)track_count),
    };
    defer catch asset::free_clip(allocator, &clip);

    usz track_slot;
    usz target_count;
    foreach (&channel : animation.channels) {
        if (!channel.target_node) continue;
        usz template_index = importer.node_remap[gltf::node_index(data, channel.target_node)];
        if (template_index == usz::max) return c3d::ASSET_FORMAT_ERROR~;
        TargetPath path = target_path(channel.target_path)!;
        Interpolation interpolation = interpolation_of(channel.sampler.interpolation);

        usz targets = path == TargetPath.MORPH_WEIGHTS ? primitive_count_of(channel.target_node) : 1;
        usz first_target = path == TargetPath.MORPH_WEIGHTS ? template_index + 1 : template_index;
        for (usz offset = 0; offset < targets; offset++) {
            Track* track = &clip.tracks[track_slot++];
            track.target = target_slot(&clip, &target_count, (uint)(first_target + offset));
            track.path = path;
            track.interpolation = interpolation;
            track.times = read_floats(importer, channel.sampler.input, SCALAR_COMPONENTS, channel.sampler.input.count)!;
            track.values = read_output(importer, channel.sampler.output)!;
            foreach (time : track.times) clip.duration = math::max(clip.duration, time);
        }
    }
    clip.targets = clip.targets[:target_count];
    return clip;
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

fn float[]? read_output(Importer* importer, gltf::Accessor* accessor) @private {
    return read_floats(importer, accessor, accessor.component_count(), accessor.count);
}

fn usz primitive_count_of(gltf::Node* node) @private {
    return node.mesh ? node.mesh.primitives.len : 0;
}

fn TargetPath? target_path(gltf::AnimationPathType path) @private {
    switch (path) {
        case TRANSLATION: return TargetPath.TRANSLATION;
        case ROTATION: return TargetPath.ROTATION;
        case SCALE: return TargetPath.SCALE;
        case WEIGHTS: return TargetPath.MORPH_WEIGHTS;
        case INVALID:
        case MAX_ENUM:
            return c3d::ASSET_FORMAT_ERROR~;
    }
}

fn Interpolation interpolation_of(gltf::InterpolationType interpolation) @private {
    switch (interpolation) {
        case LINEAR: return Interpolation.LINEAR;
        case STEP: return Interpolation.STEP;
        case CUBIC_SPLINE: return Interpolation.CUBIC_SPLINE;
        case MAX_ENUM: return Interpolation.LINEAR;
    }
}
