module c3d::anim::retarget;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::collections::map;
import std::math;

<*
 Keys per second of a corrected clip.
*>
const float BAKE_RATE_DEFAULT = 30; // the Mixamo export rate; a 10 s clip is 301 keys per track

<*
 How source rotation keys reach the destination rig.
*>
enum RestPose {
    COPY,
    CORRECT,
}

<*
 Explicit source-to-destination node name pair; exact names.
*>
struct NameMapping {
    String source;
    String target;
}

<*
 Retarget switches; root_node receives the extracted root track.
 root_translation_scale scales keys under COPY, rest displacement under CORRECT.
*>
struct RetargetOptions {
    RootMotion    root_motion;
    bool          allow_partial;
    bool          copy_translations;
    uint          root_node;
    NameMapping[] name_map;
    RestPose      rest_pose;
    float         bake_rate;
    float         root_translation_scale;
}

<*
 Keep root motion, fault on unmatched nodes, root translations only, no root track, keys copied.
*>
const RetargetOptions RETARGET_OPTIONS_DEFAULT = {
    .root_motion            = RootMotion.KEEP,
    .root_node              = anim::NO_ROOT_NODE,
    .rest_pose              = RestPose.COPY,
    .bake_rate              = BAKE_RATE_DEFAULT,
    .root_translation_scale = 1,
};

const uint NOT_MATCHED @private = uint::max;
const uint AMBIGUOUS @private = uint::max - 1;
const int SOURCE_ROOT_PARENT @private = -1;
const usz VEC3_COMPONENTS @private = 3;
const char NAMESPACE_SEPARATOR @private = ':';

struct Binding @private {
    uint destination;
    bool root;
}

<*
 Rebind a clip from source node names onto the target's template nodes.
 @param allocator : "Owns every array of the returned clip."
 @param [&in] source : "Targets index source_nodes."
 @param source_nodes : "Names and parents of the source file's nodes."
 @param [&in] target : "Destination template."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ARGUMENT
 @require options.root_node == anim::NO_ROOT_NODE || options.root_node < target.nodes.len
 @require options.bake_rate >= 0 && options.root_translation_scale >= 0
*>
fn AnimationClip? retarget_by_name(
    Allocator allocator,
    AnimationClip* source,
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    RetargetOptions options = RETARGET_OPTIONS_DEFAULT,
) {
    bool extract = options.root_motion == RootMotion.EXTRACT;
    if (extract && options.root_node == anim::NO_ROOT_NODE) return c3d::INVALID_ARGUMENT~;
    // A literal that omits these fields leaves them zero; zero selects the default.
    if (options.bake_rate == 0) options.bake_rate = BAKE_RATE_DEFAULT;
    if (options.root_translation_scale == 0) options.root_translation_scale = 1;
    if (options.rest_pose == RestPose.CORRECT) {
        return bake_corrected(
            allocator:    allocator,
            source:       source,
            source_nodes: source_nodes,
            target:       target,
            options:      &options,
        );
    }
    AnimationClip clip;
    @pool() {
        HashMap{String, uint} destinations = destination_table(target);
        Binding[] bindings = alloc::new_array(tmem, Binding, source.targets.len);
        bindings[..] = (Binding){ .destination = NOT_MATCHED };
        foreach (index, template_index : source.targets) {
            if (!has_tracks(source, (uint)index)) continue;
            NodeTemplate* node = &source_nodes[template_index];
            uint destination = resolve(node.name, &destinations, target, &options)!;
            if (destination == NOT_MATCHED && !options.allow_partial) return c3d::ASSET_FORMAT_ERROR~;
            bindings[index] = { .destination = destination, .root = node.parent == SOURCE_ROOT_PARENT };
        }

        usz track_count;
        usz root_tracks;
        foreach (&track : source.tracks) {
            Binding binding = bindings[track.target];
            if (!copies(track, binding, &options)) continue;
            track_count++;
            if (track.path == TargetPath.TRANSLATION && binding.root) root_tracks++;
        }
        if (extract && root_tracks > 1) return c3d::ASSET_FORMAT_ERROR~;
        bool root_track = extract && root_tracks == 1;

        usz slot_count = track_count;
        if (root_track) slot_count++;
        clip = {
            .name     = source.name.copy(allocator),
            .duration = source.duration,
            .tracks   = alloc::new_array(allocator, Track, (sz)slot_count),
            .targets  = alloc::new_array(allocator, uint, (sz)slot_count),
            .events   = copy_events(allocator, source.events),
        };
        usz track_slot;
        usz target_count;
        foreach (&track : source.tracks) {
            Binding binding = bindings[track.target];
            if (!copies(track, binding, &options)) continue;
            Track* copy = &clip.tracks[track_slot++];
            *copy = copy_track(allocator, track, target_slot(&clip, &target_count, binding.destination));
            if (track.path != TargetPath.TRANSLATION || !binding.root) continue;
            if (options.root_translation_scale != 1) {
                foreach (&value : copy.values) *value *= options.root_translation_scale;
            }
            if (options.root_motion == RootMotion.KEEP) continue;
            if (root_track) {
                clip.tracks[track_slot++] = root_track_of(
                    allocator:     allocator,
                    hips:          copy,
                    target:        target_slot(&clip, &target_count, options.root_node),
                    rest_position: target.nodes[options.root_node].local.position,
                );
            }
            strip_xz(copy);
        }
        clip.targets = clip.targets[:target_count];
    };
    return clip;
}

<*
 Rest rotation of a template node in model space.
 @require index < nodes.len
*>
fn Quat rest_world_rotation(NodeTemplate[] nodes, uint index) {
    Quat rotation = nodes[index].local.rotation;
    for (int parent = nodes[index].parent; parent >= 0; parent = nodes[parent].parent) {
        rotation = nodes[parent].local.rotation.mul(rotation);
    }
    return rotation;
}

<*
 Rest position of a template node in model space.
 @require index < nodes.len
*>
fn Vec3 rest_world_position(NodeTemplate[] nodes, uint index) {
    Vec3 position = nodes[index].local.position;
    for (int parent = nodes[index].parent; parent >= 0; parent = nodes[parent].parent) {
        position = nodes[parent].local.rotation.rotate_vec3(position) + nodes[parent].local.position;
    }
    return position;
}

fn HashMap{String, uint} destination_table(ModelTemplate* target) @private {
    HashMap{String, uint} table;
    table.tinit(target.nodes.len);
    foreach (uint index, &node : target.nodes) {
        String key = canonical(node.name);
        if (table.has_key(key)) {
            table.set(key, AMBIGUOUS);
        } else {
            table.set(key, index);
        }
    }
    return table;
}

fn String canonical(String name) @private {
    if (try separator = name.rindex_of_char(NAMESPACE_SEPARATOR)) name = name[(usz)separator + 1..];
    return name.to_lower_tcopy();
}

fn uint? resolve(
    String source_name,
    HashMap{String, uint}* destinations,
    ModelTemplate* target,
    RetargetOptions* options,
) @private {
    foreach (&mapping : options.name_map) {
        if (mapping.source != source_name) continue;
        foreach (uint index, &node : target.nodes) {
            if (node.name == mapping.target) return index;
        }
        return c3d::ASSET_FORMAT_ERROR~;
    }
    uint destination = destinations.get(canonical(source_name)) ?? NOT_MATCHED;
    if (destination == AMBIGUOUS) return c3d::ASSET_FORMAT_ERROR~;
    return destination;
}

fn bool has_tracks(AnimationClip* clip, uint target) @private {
    foreach (&track : clip.tracks) if (track.target == target) return true;
    return false;
}

fn bool copies(Track* track, Binding binding, RetargetOptions* options) @private {
    if (binding.destination == NOT_MATCHED) return false;
    if (track.path != TargetPath.TRANSLATION) return true;
    return binding.root || options.copy_translations;
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

fn Track copy_track(Allocator allocator, Track* source, uint target) @private {
    Track copy = {
        .target        = target,
        .path          = source.path,
        .interpolation = source.interpolation,
        .times         = alloc::new_array(allocator, float, source.times.len),
        .values        = alloc::new_array(allocator, float, source.values.len),
    };
    copy.times[..] = source.times[..];
    copy.values[..] = source.values[..];
    return copy;
}

fn void strip_xz(Track* track) @private {
    bool cubic = track.interpolation == anim::Interpolation.CUBIC_SPLINE;
    float[] first = translation_key(track, 0, anim::CUBIC_SLOT_VALUE);
    float first_x = first[0];
    float first_z = first[2];
    foreach (usz key, time : track.times) {
        float[] value = translation_key(track, key, anim::CUBIC_SLOT_VALUE);
        value[0] = first_x;
        value[2] = first_z;
        if (!cubic) continue;
        float[] incoming = translation_key(track, key, anim::CUBIC_SLOT_IN_TANGENT);
        float[] outgoing = translation_key(track, key, anim::CUBIC_SLOT_OUT_TANGENT);
        incoming[0] = 0;
        incoming[2] = 0;
        outgoing[0] = 0;
        outgoing[2] = 0;
    }
}

fn Track root_track_of(
    Allocator allocator,
    Track* hips,
    uint target,
    Vec3 rest_position,
) @private {
    Track track = copy_track(allocator, hips, target);
    bool cubic = track.interpolation == anim::Interpolation.CUBIC_SPLINE;
    float[] first = translation_key(hips, 0, anim::CUBIC_SLOT_VALUE);
    float first_x = first[0];
    float first_z = first[2];
    foreach (usz key, time : track.times) {
        float[] source = translation_key(hips, key, anim::CUBIC_SLOT_VALUE);
        float[] value = translation_key(&track, key, anim::CUBIC_SLOT_VALUE);
        value[0] = rest_position.x + source[0] - first_x;
        value[1] = rest_position.y;
        value[2] = rest_position.z + source[2] - first_z;
        if (!cubic) continue;
        translation_key(&track, key, anim::CUBIC_SLOT_IN_TANGENT)[1] = 0;
        translation_key(&track, key, anim::CUBIC_SLOT_OUT_TANGENT)[1] = 0;
    }
    return track;
}

fn float[] translation_key(Track* track, usz key, uint slot) @private {
    usz offset = track.interpolation == anim::Interpolation.CUBIC_SPLINE
      ? (key * anim::CUBIC_SLOTS_PER_KEY + slot) * VEC3_COMPONENTS
      : key * VEC3_COMPONENTS;
    return track.values[offset:VEC3_COMPONENTS];
}

fn ClipEvent[] copy_events(Allocator allocator, ClipEvent[] events) @private {
    ClipEvent[] copy = alloc::new_array(allocator, ClipEvent, events.len);
    copy[..] = events[..];
    return copy;
}
