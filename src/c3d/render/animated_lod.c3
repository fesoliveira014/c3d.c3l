module c3d::render;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::hash::fnv32a;
import std::math;

const usz ANIMATED_LOD_MIN_ADDRESSES @private = 64; // 3 KiB at creation; doubles past half load and is never shrunk

enum AnimatedLodStream : uint @private {
    PALETTE,
    MORPHS,
    PARTS,
    VISIBLE_SOURCES,
}

struct AnimatedLodKey @private {
    ulong scene;
    Entity owner;
    ulong identity;
    uint part;
    AnimatedLodStream stream;
}

struct AnimatedLodAddress @private {
    AnimatedLodKey key;
    ulong epoch;
    gpu::GpuAddress address;
}

struct AnimatedLodAddresses @private {
    Allocator allocator;
    AnimatedLodAddress[] slots;
    ulong epoch; // slots stamped by an earlier epoch are empty, so a reset frees nothing
    usz count;
}

<*
 Hash the complete initialized deformation identity.
*>
fn uint AnimatedLodKey.hash(self) => fnv32a::hash(@as_char_view(self));

<*
 Compare retained deformation source, logical part and stream.
 @pure
*>
fn bool AnimatedLodKey.equals(self, AnimatedLodKey other) @operator(==) {
    return self.scene == other.scene && c3d::same_id(self.owner, other.owner)
      && self.identity == other.identity && self.part == other.part && self.stream == other.stream;
}

$assert AnimatedLodKey::size == 32;

fn gpu::GpuAddress? AnimatedLodAddresses.get(&self, AnimatedLodKey key) {
    usz mask = self.slots.len - 1;
    for (usz index = key.hash() & mask; self.slots[index].epoch == self.epoch; index = (index + 1) & mask) {
        if (self.slots[index].key == key) return self.slots[index].address;
    }

    return NOT_FOUND~;
}

<* @require !@ok(self.get(key)) *>
fn void AnimatedLodAddresses.set(&self, AnimatedLodKey key, gpu::GpuAddress address) {
    if (2 * (self.count + 1) > self.slots.len) {
        AnimatedLodAddress[] previous = self.slots;
        self.slots = alloc::new_array(self.allocator, AnimatedLodAddress, previous.len * 2);
        self.count = 0;

        foreach (slot : previous) {
            if (slot.epoch == self.epoch) self.set(slot.key, slot.address);
        }

        alloc::free(self.allocator, previous.ptr);
    }

    usz mask = self.slots.len - 1;
    usz index = key.hash() & mask;
    while (self.slots[index].epoch == self.epoch) index = (index + 1) & mask;
    self.slots[index] = { .key = key, .epoch = self.epoch, .address = address };
    self.count++;
}

fn void AnimatedLodAddresses.reset(&self) {
    self.epoch++;
    self.count = 0;
}

fn AnimatedLodAddresses create_animated_lod_addresses(Allocator allocator) @private {
    return {
        .allocator = allocator,
        .slots = alloc::new_array(allocator, AnimatedLodAddress, ANIMATED_LOD_MIN_ADDRESSES),
        .epoch = 1,
    };
}

fn void destroy_animated_lod_addresses(AnimatedLodAddresses* addresses) @private {
    alloc::free(addresses.allocator, addresses.slots.ptr);
}

fn AnimatedLodKey animated_lod_key(MeshCandidate* candidate, AnimatedLodStream stream, uint part = 0) @private {
    return {
        .scene = candidate.scene_identity,
        .owner = candidate.node.id,
        .identity = candidate.lod.state.identity,
        .part = part,
        .stream = stream,
    };
}

fn bool bind_animated_lod_candidate(LodSelection* selection, MeshCandidate* candidate) @private {
    AnimatedLodPartBinding* part = &selection.state.animated.parts[candidate.lod_part];
    candidate.animated_lod = part;
    candidate.crowd_part = part.mesh_index;
    candidate.crowd = selection.scene.get(selection.node, AnimatedCrowd);
    candidate.model_instance = selection.scene.get(selection.node, ModelInstance);

    if (candidate.model_instance) {
        candidate.source_node = candidate.model_instance.present_node(part.template_node);
        if (!candidate.source_node) return false;

        candidate.source_mesh = selection.scene.get(candidate.source_node, Mesh);
        if (!candidate.source_mesh) return false;
    }

    return true;
}

fn uint animated_lod_source_count(MeshCandidate* candidate) @private {
    return candidate.crowd ? candidate.crowd.count : 1;
}

fn usz animated_lod_source_capacity(MeshCandidate* candidate) @private {
    return candidate.crowd ? candidate.crowd.placements.len : 1;
}

// Level-zero parts list the logical meshes in template order.
fn uint animated_lod_rigid_index(AnimatedLodBinding* binding, uint mesh) @private {
    uint rigid;
    foreach (part : binding.parts[:mesh]) {
        if (!part.skinned) rigid++;
    }

    return rigid;
}

fn Node* animated_lod_source_node(MeshCandidate* candidate, uint mesh) @private {
    return candidate.model_instance.present_node(candidate.lod.state.animated.parts[mesh].template_node);
}

fn Mat4 animated_lod_mesh_local(MeshCandidate* candidate, uint mesh, uint source = 0) @private {
    if (candidate.crowd) return candidate.crowd.part_local_transform(source, mesh);

    Vec4 position = candidate.node.world.apply({ 0, 0, 0, 1 });
    Vec3 origin = { position.x, position.y, position.z };
    Mat4 inverse_owner = maths::inverse_affine(maths::rebase(candidate.node.world, origin));
    return inverse_owner.mul(maths::rebase(animated_lod_source_node(candidate, mesh).world, origin));
}

fn Mat4 animated_lod_part_local(MeshCandidate* candidate, uint source = 0) @private {
    AnimatedLodPartBinding* part = candidate.animated_lod;
    if (part.skinned) return matrix::IDENTITY4;

    Mat4 authored = candidate.lod.state.desc.parts[candidate.lod_part].local;
    return animated_lod_mesh_local(candidate, part.mesh_index, source).mul(authored);
}

fn float[] animated_lod_weights(MeshCandidate* candidate, uint mesh, uint source = 0) @private {
    if (candidate.crowd) {
        CrowdPart* part = &candidate.crowd.parts[mesh];
        usz first = (usz)source * candidate.crowd.morph_stride + part.weight_offset;
        return candidate.crowd.morph_weights[first:part.weight_count];
    }

    return candidate.lod.scene.get(animated_lod_source_node(candidate, mesh), Mesh).morph_weights;
}

fn MorphWeightsGpu animated_lod_morph(AssetStore* assets, MeshCandidate* candidate, float[] weights) @private {
    AnimatedLodPartBinding* part = candidate.animated_lod;
    AnimatedLodBinding* binding = candidate.lod.state.animated;

    return pack_morph_selection(geometry::select_morph_targets(
        channels: assets.geometry(candidate.geometry).data.channels,
        weights: weights,
        weight_indices: binding.weight_indices[part.weight_offset:part.weight_count],
    ));
}

fn void write_animated_lod_palette(
    Mat4f[] palette,
    AssetStore* assets,
    MeshCandidate* candidate,
    Vec3 origin = {},
) @private {
    AnimatedLodBinding* binding = candidate.lod.state.animated;
    Mat4[] inverse_bind = assets.skeleton(binding.skeleton).data.inverse_bind;
    Mat4 inverse_owner = maths::inverse_affine(maths::rebase(candidate.node.world, origin));

    foreach (index, joint : binding.joint_nodes) {
        Node* joint_node = candidate.model_instance.present_node(joint);
        palette[index] = bitcast(
            inverse_owner.mul(maths::rebase(joint_node.world, origin)).mul(inverse_bind[index]),
            Mat4f,
        );
    }
}

fn gpu::GpuAddress? resolve_animated_lod_palette(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.animated_lod.skinned) return (gpu::GpuAddress)0;
    if (candidate.crowd) return resolve_crowd_palette(renderer, candidate)!.current;

    AnimatedLodKey key = animated_lod_key(candidate, PALETTE);
    if (try existing = renderer.deformation.animated.get(key)) return existing;

    usz matrices = candidate.lod.state.animated.joint_nodes.len;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(&renderer.device, matrices * Mat4f::size, STREAM_ALIGNMENT)!;

    write_animated_lod_palette(
        palette: ((Mat4f*)span.bytes.ptr)[:matrices],
        assets: renderer.assets,
        candidate: candidate,
        origin: renderer.frame_origin,
    );

    renderer.deformation.animated.set(key, span.address);

    return span.address;
}

fn gpu::GpuAddress? resolve_animated_lod_morph(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.animated_lod.weight_count) return (gpu::GpuAddress)0;
    if (candidate.crowd) return resolve_crowd_morph(renderer, candidate)!.current;

    AnimatedLodKey key = animated_lod_key(candidate, MORPHS, candidate.lod_part);
    if (try existing = renderer.deformation.animated.get(key)) return existing;

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(&renderer.device, MorphWeightsGpu::size, STREAM_ALIGNMENT)!;
    float[] weights = animated_lod_weights(candidate, candidate.animated_lod.mesh_index);
    *(MorphWeightsGpu*)span.bytes.ptr = animated_lod_morph(renderer.assets, candidate, weights);

    renderer.deformation.animated.set(key, span.address);

    return span.address;
}

fn gpu::GpuAddress? resolve_animated_lod_parts(Renderer* renderer, MeshCandidate* candidate) @private {
    if (candidate.animated_lod.skinned) return (gpu::GpuAddress)0;

    AnimatedLodKey key = animated_lod_key(candidate, PARTS, candidate.lod_part);
    if (try existing = renderer.deformation.animated.get(key)) return existing;

    uint count = animated_lod_source_count(candidate);
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(&renderer.device, (usz)count * InstanceGpu::size, STREAM_ALIGNMENT)!;
    InstanceGpu[] records = ((InstanceGpu*)span.bytes.ptr)[:count];

    for (uint source = 0; source < count; source++) {
        write_instance(
            record: &records[source],
            model: animated_lod_part_local(candidate, source),
            color: { 1, 1, 1, 1 },
            seed: 0,
        );
        records[source].normal_1.w = candidate.crowd
          && candidate.lod.part_mirrored[candidate.lod_part][source] ? 1 : 0;
    }

    renderer.deformation.animated.set(key, span.address);

    return span.address;
}

fn gpu::GpuAddress? resolve_animated_lod_indices(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedLodKey key = animated_lod_key(
        candidate: candidate,
        stream: VISIBLE_SOURCES,
        part: candidate.lod_part * 2 + (candidate.mirrored ? 1 : 0),
    );
    if (try existing = renderer.deformation.animated.get(key)) return existing;

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(
        device: &renderer.device,
        size: (usz)candidate.instance_count * uint::size,
        alignment: STREAM_ALIGNMENT,
    )!;
    uint[] indices = ((uint*)span.bytes.ptr)[:candidate.instance_count];
    uint written;

    for (uint source = 0; source < candidate.crowd.count; source++) {
        if (candidate.lod.part_mirrored[candidate.lod_part][source] != candidate.mirrored) continue;

        indices[written++] = source;
    }

    renderer.deformation.animated.set(key, span.address);

    return span.address;
}

fn bool animated_lod_representations_match(LodGroupState* state, uint first, uint second) @private {
    AnimatedLodBinding* binding = state.animated;
    AnimatedLodPartBinding* previous = &binding.parts[first];
    AnimatedLodPartBinding* current = &binding.parts[second];
    LodPart* previous_draw = &state.desc.parts[first];
    LodPart* current_draw = &state.desc.parts[second];
    if (previous.mesh_index != current.mesh_index || previous.template_node != current.template_node
      || previous.skinned != current.skinned || previous.weight_count != current.weight_count
      || !c3d::same_id(previous_draw.geometry, current_draw.geometry)
      || previous.geometry_revision != current.geometry_revision
      || !mem::equals(&previous_draw.local, &current_draw.local, Mat4::size)) return false;

    uint[] previous_weights = binding.weight_indices[previous.weight_offset:previous.weight_count];
    uint[] current_weights = binding.weight_indices[current.weight_offset:current.weight_count];
    foreach (index, weight : previous_weights) {
        if (weight != current_weights[index]) return false;
    }

    return true;
}

fn uint animated_lod_history_levels(MeshCandidate* candidate) @private {
    LodGroupState* state = candidate.lod.state;
    uint mask;

    foreach (uint level_index, level : state.desc.levels) {
        foreach (uint offset, part : state.animated.parts[level.first_part:level.part_count]) {
            if (part.mesh_index != candidate.animated_lod.mesh_index) continue;
            if (animated_lod_representations_match(state, candidate.lod_part, level.first_part + offset)) {
                mask |= 1 << level_index;
            }
        }
    }

    return mask;
}

fn Mat4f[] animated_lod_previous_mesh_locals(PoseRecord* owner, MeshCandidate* candidate) @private {
    AnimatedLodBinding* binding = candidate.lod.state.animated;
    usz first = animated_lod_rigid_index(binding, candidate.animated_lod.mesh_index)
      * animated_lod_source_capacity(candidate);
    return owner.animated_lod.locals[first:owner.instance_count];
}

fn float[] animated_lod_previous_weights(PoseRecord* owner, MeshCandidate* candidate, uint source = 0) @private {
    uint[] offsets = candidate.lod.state.animated.channel_offsets;
    uint mesh = candidate.animated_lod.mesh_index;
    usz first = (usz)source * offsets[^1] + offsets[mesh];
    return owner.animated_lod.weights[first:offsets[mesh + 1] - offsets[mesh]];
}

// Callers check has_previous_representation, which also pins the source count of the history.
fn gpu::GpuAddress? upload_animated_lod_previous(Renderer* renderer, DrawItem* item, PoseRecord* owner) @private {
    MeshCandidate* candidate = item.candidate;
    LodSelection* selection = candidate.lod;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    uint count = animated_lod_source_count(candidate);
    PreviousPoseGpu previous = { .skin = item.skin, .morph = item.morph };

    if (item.skin != (gpu::GpuAddress)0) {
        if (candidate.crowd) {
            previous.skin = resolve_crowd_palette(renderer, candidate)!.previous;
        } else {
            if (selection.previous_palette == (gpu::GpuAddress)0) {
                usz matrices = selection.state.animated.joint_nodes.len;
                selection.previous_palette = upload_bytes(renderer, owner.palette.ptr, matrices * Mat4f::size)!;
            }

            previous.skin = selection.previous_palette;
        }
    }

    if (!candidate.animated_lod.skinned) {
        gpu::MappedGpuSpan local_span = frame.upload.take(
            device: &renderer.device,
            size: (usz)count * Mat4f::size,
            alignment: STREAM_ALIGNMENT,
        )!;
        Mat4f[] locals = ((Mat4f*)local_span.bytes.ptr)[:count];
        Mat4 authored = selection.state.desc.parts[candidate.lod_part].local;

        foreach (source, mesh_local : animated_lod_previous_mesh_locals(owner, candidate)) {
            locals[source] = bitcast(bitcast(mesh_local, Mat4).mul(authored), Mat4f);
        }

        previous.instances = local_span.address;
    }

    if (item.morph != (gpu::GpuAddress)0) {
        if (candidate.crowd) {
            previous.morph = resolve_crowd_morph(renderer, candidate)!.previous;
        } else {
            float[] weights = animated_lod_previous_weights(owner, candidate);
            MorphWeightsGpu block = animated_lod_morph(renderer.assets, candidate, weights);
            previous.morph = upload_bytes(renderer, &block, MorphWeightsGpu::size)!;
        }
    }

    return upload_bytes(renderer, &previous, PreviousPoseGpu::size);
}
