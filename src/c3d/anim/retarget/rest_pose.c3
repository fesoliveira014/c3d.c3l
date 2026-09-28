module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;
import std::collections::map;
import std::math;

const float KEY_SNAP @private = 1e-3f; // in keys; a duration a few ulps over a whole key count gains no key
const usz QUAT_COMPONENTS @private = 4;
const Quat IDENTITY_ROTATION @private = { .v = { 0, 0, 0, 1 } };

fn float[] bake_times(Allocator allocator, float duration, float bake_rate) @private {
    uint intervals = (uint)math::max(0.0f, math::ceil(duration * bake_rate - KEY_SNAP));
    float[] times = alloc::new_array(allocator, float, (sz)intervals + 1);
    for (uint key = 0; key < intervals; key++) times[key] = key / bake_rate;
    times[intervals] = duration;
    return times;
}

fn AnimationClip? bake_corrected(
    Allocator allocator,
    AnimationClip* source,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetOptions* options,
) @private {
    bool extract = options.root_motion == RootMotion.EXTRACT;
    AnimationClip clip;
    @pool() {
        Track*[] rotation_tracks = alloc::new_array(tmem, Track*, source_nodes.len);
        Track*[] translation_tracks = alloc::new_array(tmem, Track*, source_nodes.len);
        bool[] tracked = alloc::new_array(tmem, bool, source_nodes.len);
        foreach (&track : source.tracks) {
            uint node = source.targets[track.target];
            tracked[node] = true;
            if (track.path == TargetPath.ROTATION) rotation_tracks[node] = track;
            if (track.path == TargetPath.TRANSLATION) translation_tracks[node] = track;
        }

        HashMap{String, uint} destinations = destination_table(target);
        uint[] mapped = alloc::new_array(tmem, uint, target.nodes.len);
        mapped[..] = NOT_MATCHED;
        uint[] destination_of = alloc::new_array(tmem, uint, source_nodes.len);
        destination_of[..] = NOT_MATCHED;
        uint root_source = NOT_MATCHED;
        usz root_count;
        foreach (uint index, &node : source_nodes) {
            uint destination = resolve(node.name, &destinations, target, options)!;
            if (destination == NOT_MATCHED) {
                if (tracked[index] && !options.allow_partial) return c3d::ASSET_FORMAT_ERROR~;
                continue;
            }
            mapped[destination] = index;
            destination_of[index] = destination;
            if (node.parent == SOURCE_ROOT_PARENT && translation_tracks[index]) {
                root_source = index;
                root_count++;
            }
        }
        if (root_count > 1) return c3d::ASSET_FORMAT_ERROR~;
        bool root_track = root_count == 1;

        Quat[] source_rest = alloc::new_array(tmem, Quat, source_nodes.len);
        foreach (uint index, &node : source_nodes) source_rest[index] = rest_world_rotation(source_nodes, index);
        Quat[] target_rest = alloc::new_array(tmem, Quat, target.nodes.len);
        foreach (uint index, &node : target.nodes) target_rest[index] = rest_world_rotation(target.nodes, index);

        usz rotation_count;
        foreach (source_index : mapped) {
            if (source_index != NOT_MATCHED) rotation_count++;
        }
        usz copied_count;
        foreach (&track : source.tracks) {
            if (track.path != TargetPath.SCALE && track.path != TargetPath.MORPH_WEIGHTS) continue;
            if (destination_of[source.targets[track.target]] != NOT_MATCHED) copied_count++;
        }
        usz slot_count = rotation_count + copied_count;
        if (root_track) slot_count++;
        if (root_track && extract) slot_count++;

        float[] times = bake_times(tmem, source.duration, options.bake_rate);
        clip = {
            .name     = source.name.copy(allocator),
            .duration = source.duration,
            .tracks   = alloc::new_array(allocator, Track, (sz)slot_count),
            .targets  = alloc::new_array(allocator, uint, (sz)slot_count),
        };
        usz track_slot;
        usz target_count;
        Track*[] baked_rotations = alloc::new_array(tmem, Track*, target.nodes.len);
        foreach (uint destination, source_index : mapped) {
            if (source_index == NOT_MATCHED) continue;
            Track* track = &clip.tracks[track_slot++];
            *track = baked_track(
                allocator: allocator,
                times:     times,
                path:      TargetPath.ROTATION,
                target:    target_slot(&clip, &target_count, destination),
            );
            baked_rotations[destination] = track;
        }
        Track* hips_track;
        Track* root_node_track;
        if (root_track) {
            hips_track = &clip.tracks[track_slot++];
            *hips_track = baked_track(
                allocator: allocator,
                times:     times,
                path:      TargetPath.TRANSLATION,
                target:    target_slot(&clip, &target_count, destination_of[root_source]),
            );
            if (extract) {
                root_node_track = &clip.tracks[track_slot++];
                *root_node_track = baked_track(
                    allocator: allocator,
                    times:     times,
                    path:      TargetPath.TRANSLATION,
                    target:    target_slot(&clip, &target_count, options.root_node),
                );
            }
        }
        foreach (&track : source.tracks) {
            if (track.path != TargetPath.SCALE && track.path != TargetPath.MORPH_WEIGHTS) continue;
            uint destination = destination_of[source.targets[track.target]];
            if (destination == NOT_MATCHED) continue;
            clip.tracks[track_slot++] = copy_track(allocator, track, target_slot(&clip, &target_count, destination));
        }
        clip.targets = clip.targets[:target_count];

        uint[] cursors = alloc::new_array(tmem, uint, source.tracks.len);
        Quat[] source_world = alloc::new_array(tmem, Quat, source_nodes.len);
        Quat[] target_world = alloc::new_array(tmem, Quat, target.nodes.len);
        Vec3 root_rest = root_track ? rest_world_position(source_nodes, root_source) : (Vec3){};
        Vec3 first_displacement;
        float[QUAT_COMPONENTS] sample;
        foreach (usz key, time : times) {
            Vec3 root_position;
            foreach (uint index, &node : source_nodes) {
                Quat local = node.local.rotation;
                if (Track* rotation = rotation_tracks[index]) {
                    anim::sample_track(rotation, time, &cursors[track_index(source, rotation)], sample[..]);
                    local = { .v = { sample[0], sample[1], sample[2], sample[3] } };
                }
                if (index == root_source) {
                    Track* translation = translation_tracks[index];
                    anim::sample_track(translation, time, &cursors[track_index(source, translation)], sample[:3]);
                    root_position = { sample[0], sample[1], sample[2] };
                }
                source_world[index] = node.parent < 0 ? local : source_world[node.parent].mul(local);
            }

            foreach (uint destination, &node : target.nodes) {
                Quat parent_world = node.parent < 0 ? IDENTITY_ROTATION : target_world[node.parent];
                Quat local = node.local.rotation;
                uint source_index = mapped[destination];
                if (source_index != NOT_MATCHED) {
                    Quat delta = source_world[source_index].mul(source_rest[source_index].conjugate());
                    Quat world = delta.mul(target_rest[destination]);
                    local = parent_world.conjugate().mul(world).normalize();
                    write_rotation_key(baked_rotations[destination], key, local);
                }
                target_world[destination] = parent_world.mul(local);
            }

            if (!root_track) continue;
            Vec3 displacement = (root_position - root_rest) * options.root_translation_scale;
            if (key == 0) first_displacement = displacement;
            Vec3 horizontal = { displacement.x - first_displacement.x, 0, displacement.z - first_displacement.z };
            Vec3 hips_vector = options.root_motion == RootMotion.KEEP ? displacement : displacement - horizontal;
            Vec3 hips_local = place(target.nodes, target_rest, destination_of[root_source], hips_vector);
            write_translation_key(hips_track, key, hips_local);
            if (!extract) continue;
            Vec3 root_local = place(target.nodes, target_rest, options.root_node, horizontal);
            write_translation_key(root_node_track, key, root_local);
        }
    };
    return clip;
}

fn Track baked_track(
    Allocator allocator,
    float[] times,
    TargetPath path,
    uint target,
) @private {
    usz stride = path == TargetPath.ROTATION ? QUAT_COMPONENTS : VEC3_COMPONENTS;
    Track track = {
        .target        = target,
        .path          = path,
        .interpolation = anim::Interpolation.LINEAR,
        .times         = alloc::new_array(allocator, float, times.len),
        .values        = alloc::new_array(allocator, float, (sz)(times.len * stride)),
    };
    track.times[..] = times[..];
    return track;
}

fn void write_rotation_key(Track* track, usz key, Quat rotation) @private {
    Vec4 value = rotation.v;
    if (key > 0) {
        float[] previous = track.values[(key - 1) * QUAT_COMPONENTS:QUAT_COMPONENTS];
        Vec4 before = { previous[0], previous[1], previous[2], previous[3] };
        if (value.dot(before) < 0) value = -value;
    }
    float[] slot = track.values[key * QUAT_COMPONENTS:QUAT_COMPONENTS];
    slot[0] = value.x;
    slot[1] = value.y;
    slot[2] = value.z;
    slot[3] = value.w;
}

fn void write_translation_key(Track* track, usz key, Vec3 position) @private {
    float[] slot = track.values[key * VEC3_COMPONENTS:VEC3_COMPONENTS];
    slot[0] = position.x;
    slot[1] = position.y;
    slot[2] = position.z;
}

fn Vec3 place(
    NodeTemplate[] nodes,
    Quat[] rest_rotations,
    uint index,
    Vec3 model_vector,
) @private {
    int parent = nodes[index].parent;
    if (parent < 0) return model_vector + nodes[index].local.position;
    return rest_rotations[parent].conjugate().rotate_vec3(model_vector) + nodes[index].local.position;
}

fn usz track_index(AnimationClip* clip, Track* track) @private => (usz)(track - clip.tracks.ptr);
