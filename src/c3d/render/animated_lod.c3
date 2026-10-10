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

struct AnimatedLodKey @private {
    ulong scene;
    Entity owner;
    ulong identity;
    uint part;
    uint padding;
}

<*
 Hash the complete initialized deformation identity.
*>
fn uint AnimatedLodKey.hash(self) => fnv32a::hash(@as_char_view(self));

<*
 Compare retained deformation source and logical part.
 @pure
*>
fn bool AnimatedLodKey.equals(self, AnimatedLodKey other) @operator(==) {
    return self.scene == other.scene && c3d::same_id(self.owner, other.owner)
      && self.identity == other.identity && self.part == other.part;
}

$assert AnimatedLodKey::size == 32;

fn AnimatedLodKey animated_lod_key(MeshCandidate* candidate, uint part) @private {
    return {
        .scene = candidate.scene_identity,
        .owner = candidate.node.id,
        .identity = candidate.lod.state.identity,
        .part = part,
    };
}

fn bool animated_lod_owns_source(Scene* scene, Node* node) @private {
    for (Node* ancestor = node.parent; ancestor; ancestor = ancestor.parent) {
        LodGroup* group = scene.get(ancestor, LodGroup);
        if (!group || !group.state.animated) continue;

        if (ModelInstance* instance = scene.get(ancestor, ModelInstance)) {
            LodLevel base = group.state.desc.levels[0];
            foreach (part : group.state.animated.parts[base.first_part:base.part_count]) {
                if (instance.present_node(part.template_node) == node) return true;
            }
        } else if (AnimatedCrowd* crowd = scene.get(ancestor, AnimatedCrowd)) {
            foreach (part : crowd.parts) {
                if (c3d::same_id(part.batch, node.id)) return true;
            }
        }
    }

    return false;
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

fn Mat4 animated_lod_part_local(MeshCandidate* candidate, uint source = 0) @private {
    AnimatedLodPartBinding* part = candidate.animated_lod;
    if (part.skinned) return matrix::IDENTITY4;

    Mat4 authored = candidate.lod.state.desc.parts[candidate.lod_part].local;
    if (candidate.crowd) {
        AnimatedCrowd* crowd = candidate.crowd;
        return crowd.part_local_transform(source, part.mesh_index).mul(authored);
    }

    Vec4 position = candidate.node.world.apply({ 0, 0, 0, 1 });
    Vec3 origin = { position.x, position.y, position.z };
    Mat4 inverse_owner = maths::inverse_affine(maths::rebase(candidate.node.world, origin));
    return inverse_owner.mul(maths::rebase(candidate.source_node.world, origin)).mul(authored);
}

fn MorphWeightsGpu animated_lod_morph(
    AssetStore* assets,
    MeshCandidate* candidate,
    uint source = 0,
) @private {
    AnimatedLodPartBinding* part = candidate.animated_lod;
    AnimatedLodBinding* binding = candidate.lod.state.animated;
    float[] weights;
    if (candidate.crowd) {
        CrowdPart* base = &candidate.crowd.parts[part.mesh_index];
        usz first = (usz)source * candidate.crowd.morph_stride + base.weight_offset;
        weights = candidate.crowd.morph_weights[first:base.weight_count];
    } else {
        weights = candidate.source_mesh.morph_weights;
    }

    return pack_morph_selection(geometry::select_morph_targets(
        channels: assets.geometry(candidate.geometry).data.channels,
        weights: weights,
        weight_indices: binding.weight_indices[part.weight_offset:part.weight_count],
    ));
}

fn void write_animated_lod_palette(
    Mat4f[] palette,
    MeshCandidate* candidate,
    Vec3 origin = {},
) @private {
    if (candidate.crowd) {
        foreach (index, value : candidate.crowd.palettes[:palette.len]) palette[index] = bitcast(value, Mat4f);
        return;
    }

    AnimatedLodBinding* binding = candidate.lod.state.animated;
    Mat4 inverse_owner = maths::inverse_affine(maths::rebase(candidate.node.world, origin));

    foreach (index, joint : binding.joint_nodes) {
        Node* joint_node = candidate.model_instance.present_node(joint);
        palette[index] = bitcast(
            inverse_owner.mul(maths::rebase(joint_node.world, origin)).mul(binding.inverse_bind[index]),
            Mat4f,
        );
    }
}

fn gpu::GpuAddress? resolve_animated_lod_palette(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.animated_lod.skinned) return (gpu::GpuAddress)0;

    AnimatedLodKey key = animated_lod_key(candidate, uint::max);
    if (try existing = renderer.deformation.animated_palettes.get(key)) return existing;

    uint count = animated_lod_source_count(candidate);
    usz matrices = (usz)count * candidate.lod.state.animated.joint_nodes.len;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(&renderer.device, matrices * Mat4f::size, STREAM_ALIGNMENT)!;
    write_animated_lod_palette(
        palette: ((Mat4f*)span.bytes.ptr)[:matrices],
        candidate: candidate,
        origin: renderer.frame_origin,
    );
    renderer.deformation.animated_palettes.set(key, span.address);

    return span.address;
}

fn gpu::GpuAddress? resolve_animated_lod_morph(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.animated_lod.weight_count) return (gpu::GpuAddress)0;

    AnimatedLodKey key = animated_lod_key(candidate, candidate.lod_part);
    if (try existing = renderer.deformation.animated_morphs.get(key)) return existing;

    uint count = animated_lod_source_count(candidate);
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(
        device: &renderer.device,
        size: (usz)count * MorphWeightsGpu::size,
        alignment: STREAM_ALIGNMENT,
    )!;
    MorphWeightsGpu[] blocks = ((MorphWeightsGpu*)span.bytes.ptr)[:count];

    for (uint source = 0; source < count; source++) {
        blocks[source] = animated_lod_morph(renderer.assets, candidate, source);
    }

    renderer.deformation.animated_morphs.set(key, span.address);

    return span.address;
}

fn gpu::GpuAddress? resolve_animated_lod_parts(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedLodKey key = animated_lod_key(candidate, candidate.lod_part);
    if (try existing = renderer.deformation.animated_parts.get(key)) return existing;

    uint count = animated_lod_source_count(candidate);
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(&renderer.device, (usz)count * InstanceGpu::size, STREAM_ALIGNMENT)!;
    InstanceGpu[] records = ((InstanceGpu*)span.bytes.ptr)[:count];

    for (uint source = 0; source < count; source++) {
        write_instance(
            record: &records[source],
            world: animated_lod_part_local(candidate, source),
            color: { 1, 1, 1, 1 },
            seed: 0,
        );
        records[source].normal_1.w = candidate.lod.part_mirrored[candidate.lod_part][source] ? 1 : 0;
    }

    renderer.deformation.animated_parts.set(key, span.address);

    return span.address;
}

fn gpu::GpuAddress? resolve_animated_lod_indices(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedLodKey key = animated_lod_key(candidate, candidate.lod_part * 2 + (candidate.mirrored ? 1 : 0));
    if (try existing = renderer.deformation.animated_indices.get(key)) return existing;

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

    renderer.deformation.animated_indices.set(key, span.address);

    return span.address;
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

fn gpu::GpuAddress? upload_animated_lod_previous(
    Renderer* renderer,
    DrawItem* item,
    PoseRecord* pose,
    PoseRecord* owner,
) @private {
    MeshCandidate* candidate = item.candidate;
    LodSelection* selection = candidate.lod;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    uint count = animated_lod_source_count(candidate);
    usz joints = selection.state.animated.joint_nodes.len;
    PreviousPoseGpu previous = { .skin = item.skin, .morph = item.morph };

    if (item.skin != (gpu::GpuAddress)0) {
        if (selection.previous_palette == (gpu::GpuAddress)0) {
            usz matrices = (usz)count * joints;
            gpu::MappedGpuSpan palette_span = frame.upload.take(
                device: &renderer.device,
                size: matrices * Mat4f::size,
                alignment: STREAM_ALIGNMENT,
            )!;
            Mat4f[] palette = ((Mat4f*)palette_span.bytes.ptr)[:matrices];
            write_animated_lod_palette(palette, candidate, renderer.frame_origin);

            for (uint source = 0; source < count; source++) {
                if (!animated_lod_previous_valid(owner, candidate, source)) continue;

                usz first = (usz)source * joints;
                palette[first:joints] = owner.palette[first:joints];
            }

            selection.previous_palette = palette_span.address;
        }
        previous.skin = selection.previous_palette;
    }

    gpu::MappedGpuSpan local_span = frame.upload.take(
        device: &renderer.device,
        size: (usz)count * Mat4f::size,
        alignment: STREAM_ALIGNMENT,
    )!;
    Mat4f[] locals = ((Mat4f*)local_span.bytes.ptr)[:count];

    for (uint source = 0; source < count; source++) {
        locals[source] = animated_lod_previous_valid(pose, candidate, source) ? pose.instances[source]
          : bitcast(animated_lod_part_local(candidate, source), Mat4f);
    }

    previous.instances = local_span.address;

    if (item.morph != (gpu::GpuAddress)0) {
        gpu::MappedGpuSpan morph_span = frame.upload.take(
            device: &renderer.device,
            size: (usz)count * MorphWeightsGpu::size,
            alignment: STREAM_ALIGNMENT,
        )!;
        MorphWeightsGpu[] blocks = ((MorphWeightsGpu*)morph_span.bytes.ptr)[:count];

        for (uint source = 0; source < count; source++) {
            blocks[source] = animated_lod_previous_valid(pose, candidate, source) ? pose.morphs[source]
              : animated_lod_morph(renderer.assets, candidate, source);
        }

        previous.morph = morph_span.address;
    }

    return upload_bytes(renderer, &previous, PreviousPoseGpu::size);
}
