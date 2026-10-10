module c3d::render;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::map;
import std::math;

<*
 Palette and morph block addresses written this frame, keyed by the stable mesh node.
*>
struct DeformationCache {
    HashMap{ulong, gpu::GpuAddress} palettes;
    HashMap{ulong, gpu::GpuAddress} morph_blocks;
    HashMap{ulong, gpu::GpuAddress} crowd_palettes;
    HashMap{ulong, gpu::GpuAddress} crowd_morphs;
    HashMap{ulong, gpu::GpuAddress} crowd_bounds;
}

$assert geometry::MAX_ACTIVE_MORPH_TARGETS == shader::MAX_ACTIVE_MORPH_TARGETS;

<*
 Vertex stage for the geometry's deformation streams.
 @param morphed : "The mesh carries morph weights."
 @param skinned : "The mesh node carries a live skin binding."
 @param base_flags : "Variant flags of the pass, such as depth only."
 @pure
*>
fn ShaderVariant mesh_vertex_variant(
    GeometryFlags flags,
    bool morphed,
    bool skinned,
    uint base_flags = 0,
) {
    uint variant_flags = base_flags;
    if (flags.skinned && skinned) {
        variant_flags |= flags.joints_u16 ? shader::SHADER_FLAG_SKINNED_U16 : shader::SHADER_FLAG_SKINNED;
    }
    if (flags.has_morphs && morphed) variant_flags |= shader::SHADER_FLAG_MORPH;
    return { .shader = MESH, .flags = variant_flags };
}

fn ShaderVariant candidate_vertex_variant(GeometryFlags flags, MeshCandidate* candidate, uint base_flags = 0) @private {
    if (candidate.impostor) return { .shader = IMPOSTOR_VERTEX };
    if (candidate.billboards) return { .shader = BILLBOARD_VERTEX };
    if (candidate_instanced(candidate)) {
        AnimatedCrowd* crowd = candidate.crowd;
        return mesh_vertex_variant(
            flags:      flags,
            morphed:    crowd != null && crowd.parts[candidate.crowd_part].weight_count > 0,
            skinned:    crowd != null && crowd.parts[candidate.crowd_part].skinned,
            base_flags: base_flags | shader::SHADER_FLAG_INSTANCED,
        );
    }
    return mesh_vertex_variant(
        flags:      flags,
        morphed:    candidate.morph_weights.len > 0,
        skinned:    candidate.skin != null,
        base_flags: base_flags,
    );
}

<*
 Pack a morph selection into the block the vertex stage reads.
 @pure
*>
fn MorphWeightsGpu pack_morph_selection(MorphSelection selection) {
    MorphWeightsGpu block = { .count = selection.count };
    block.indices[..] = selection.targets[..];
    block.weights[..] = selection.weights[..];
    return block;
}

fn DeformationCache create_deformation_cache(Allocator allocator) @private {
    DeformationCache cache;
    cache.palettes.init(allocator);
    cache.morph_blocks.init(allocator);
    cache.crowd_palettes.init(allocator);
    cache.crowd_morphs.init(allocator);
    cache.crowd_bounds.init(allocator);
    return cache;
}

fn void destroy_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.free();
    cache.morph_blocks.free();
    cache.crowd_palettes.free();
    cache.crowd_morphs.free();
    cache.crowd_bounds.free();
}

fn void reset_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.clear();
    cache.morph_blocks.clear();
    cache.crowd_palettes.clear();
    cache.crowd_morphs.clear();
    cache.crowd_bounds.clear();
}

fn gpu::GpuAddress? resolve_crowd_bounds(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedCrowd* crowd = candidate.crowd;
    if (!crowd || crowd.parts[candidate.crowd_part].skinned) return (gpu::GpuAddress)0;

    ulong key = (ulong)(uptr)candidate.node;
    if (try existing = renderer.deformation.crowd_bounds.get(key)) return existing;

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(
        device: &renderer.device,
        size: (usz)crowd.count * Mat4f::size,
        alignment: STREAM_ALIGNMENT,
    )!;
    Mat4f[] bounds = ((Mat4f*)span.bytes.ptr)[:crowd.count];
    Mat4 world = maths::rebase(candidate.node.world, renderer.frame_origin);

    uint written;
    for (uint parity = 0; parity < 2; parity++) {
        for (uint instance = 0; instance < crowd.count; instance++) {
            if (crowd.part_mirrored(instance, candidate.crowd_part) != (parity == 1)) continue;

            bounds[written++] = bitcast(world.mul(crowd.placements[instance].to_mat4()), Mat4f);
        }
    }

    renderer.deformation.crowd_bounds.set(key, span.address);

    return span.address;
}

<*
 Palette slot of each placement in the parity-packed draw order: unmirrored instances first.
 @param [out] packed : "One entry per placement."
 @param [in] crowd : "Null selects placement-only parity."
 @param part : "Logical crowd mesh; ignored without a crowd."
 @require packed.len == placements.len
*>
fn void crowd_packed_order(
    uint[] packed,
    Transform[] placements,
    AnimatedCrowd* crowd = null,
    uint part = 0,
) {
    uint unmirrored;
    foreach (uint index, placement : placements) {
        bool mirrored = crowd ? crowd.part_mirrored(index, part) : scene::transform_mirrored(placement);
        if (!mirrored) unmirrored++;
    }

    uint[2] next = { 0, unmirrored };
    foreach (uint instance, placement : placements) {
        bool mirrored = crowd ? crowd.part_mirrored(instance, part) : scene::transform_mirrored(placement);
        usz parity = mirrored ? 1 : 0;
        packed[instance] = next[parity]++;
    }
}

<*
 Write a crowd's palettes in the batch's packed draw order: unmirrored instances first.
 @param [out] palettes : "joint_count * crowd.count entries."
 @param [&in] crowd : "Palettes written by crowd_update."
*>
fn void pack_crowd_palettes(Mat4f[] palettes, AnimatedCrowd* crowd) {
    uint written;
    for (uint pass = 0; pass < 2; pass++) {
        foreach (uint instance, placement : crowd.placements[:crowd.count]) {
            if (scene::transform_mirrored(placement) != (pass == 1)) continue;
            Mat4[] source = crowd.palettes[instance * crowd.joint_count:crowd.joint_count];
            usz target = (usz)written * crowd.joint_count;
            foreach (usz joint, matrix : source) palettes[target + joint] = bitcast(matrix, Mat4f);
            written++;
        }
    }
}

<*
 Write one part's morph blocks in the batch's packed draw order: unmirrored instances first.
 @param [out] blocks : "crowd.count entries."
 @param [&in] crowd : "Morph weights written by crowd_update."
 @param channels : "Channels of the part's geometry."
*>
fn void pack_crowd_morphs(
    MorphWeightsGpu[] blocks,
    AnimatedCrowd* crowd,
    uint part,
    MorphChannel[] channels,
) {
    CrowdPart* target = &crowd.parts[part];
    uint written;
    for (uint pass = 0; pass < 2; pass++) {
        foreach (uint instance, placement : crowd.placements[:crowd.count]) {
            if (crowd.part_mirrored(instance, part) != (pass == 1)) continue;
            usz first = (usz)instance * crowd.morph_stride + target.weight_offset;
            float[] weights = crowd.morph_weights[first:target.weight_count];
            blocks[written++] = pack_morph_selection(geometry::select_morph_targets(channels, weights));
        }
    }
}

fn gpu::GpuAddress? resolve_crowd_palettes(Renderer* renderer, Node* crowd_node, AnimatedCrowd* crowd) @private {
    ulong key = (ulong)(uptr)crowd_node;
    gpu::GpuAddress base;
    if (try existing = renderer.deformation.crowd_palettes.get(key)) {
        base = existing;
    } else {
        Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
        usz count = (usz)crowd.joint_count * crowd.count;
        gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, count * Mat4f::size, STREAM_ALIGNMENT)!;
        pack_crowd_palettes(((Mat4f*)span.bytes.ptr)[:count], crowd);
        renderer.deformation.crowd_palettes.set(key, span.address);
        base = span.address;
    }
    return base;
}

fn gpu::GpuAddress? resolve_crowd_morphs(
    Renderer* renderer,
    Node* batch_node,
    AnimatedCrowd* crowd,
    uint part,
    MorphChannel[] channels,
) @private {
    ulong key = (ulong)(uptr)batch_node;
    gpu::GpuAddress base;
    if (try existing = renderer.deformation.crowd_morphs.get(key)) {
        base = existing;
    } else {
        Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan span = slot.upload.take(
            device:    &renderer.device,
            size:      crowd.count * MorphWeightsGpu::size,
            alignment: STREAM_ALIGNMENT,
        )!;
        pack_crowd_morphs(
            blocks:   ((MorphWeightsGpu*)span.bytes.ptr)[:crowd.count],
            crowd:    crowd,
            part:     part,
            channels: channels,
        );
        renderer.deformation.crowd_morphs.set(key, span.address);
        base = span.address;
    }
    return base;
}

<*
 Palette of the binding for this frame, uploaded on first use.
 @param [&in] mesh_node : "World matrix as left by the last update."
 @param [&in] binding : "Live skeleton; joints updated by the same update."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn gpu::GpuAddress? resolve_palette(Renderer* renderer, Node* mesh_node, SkinBinding* binding) @private {
    if (try existing = renderer.deformation.palettes.get((ulong)(uptr)mesh_node)) return existing;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, binding.joints.len * Mat4f::size, STREAM_ALIGNMENT)!;
    evaluate_palette(
        palette:      ((Mat4f*)span.bytes.ptr)[:binding.joints.len],
        mesh_node:    mesh_node,
        binding:      binding,
        inverse_bind: renderer.assets.skeleton(binding.skeleton).data.inverse_bind,
        origin:       renderer.frame_origin,
    );
    renderer.deformation.palettes.set((ulong)(uptr)mesh_node, span.address);
    return span.address;
}

<*
 Mesh-space joint matrices of the binding under the current joint poses.
 @param [out] palette : "One entry per joint; written only."
 @param [&in] mesh_node : "World matrix as left by the last update."
 @param [&in] binding : "Live joints."
 @param origin : "Shared absolute origin before mesh-local composition."
*>
fn void evaluate_palette(
    Mat4f[] palette,
    Node* mesh_node,
    SkinBinding* binding,
    Mat4[] inverse_bind,
    Vec3 origin = {},
) {
    Mat4 inverse_mesh = maths::inverse_affine(maths::rebase(mesh_node.world, origin));
    foreach (index, joint : binding.joints) {
        palette[index] = bitcast(inverse_mesh.mul(maths::rebase(joint.world, origin)).mul(inverse_bind[index]), Mat4f);
    }
}

<*
 Morph block of the mesh node for this frame, uploaded on first use.
 @param [&in] mesh_node : "Stable mesh node the block is cached under."
 @param weights : "Live weights of the mesh, one per channel or target."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn gpu::GpuAddress? resolve_morph_block(
    Renderer* renderer,
    Node* mesh_node,
    MorphChannel[] channels,
    float[] weights,
) @private {
    if (try existing = renderer.deformation.morph_blocks.get((ulong)(uptr)mesh_node)) return existing;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, MorphWeightsGpu::size, STREAM_ALIGNMENT)!;
    *(MorphWeightsGpu*)span.bytes.ptr = pack_morph_selection(geometry::select_morph_targets(channels, weights));
    renderer.deformation.morph_blocks.set((ulong)(uptr)mesh_node, span.address);
    return span.address;
}

fn gpu::GpuAddress? resolve_candidate_skin(Renderer* renderer, MeshCandidate* candidate) @private {
    if (candidate.skin) return resolve_palette(renderer, candidate.node, candidate.skin);
    if (candidate.crowd && candidate.crowd.parts[candidate.crowd_part].skinned) {
        return resolve_crowd_palettes(renderer, candidate.node.parent, candidate.crowd);
    }

    return (gpu::GpuAddress)0;
}

fn gpu::GpuAddress? resolve_candidate_morph(
    Renderer* renderer,
    MeshCandidate* candidate,
    ShaderVariant vertex,
) @private {
    if (!(vertex.flags & shader::SHADER_FLAG_MORPH)) return (gpu::GpuAddress)0;
    if (candidate.crowd) {
        return resolve_crowd_morphs(
            renderer:   renderer,
            batch_node: candidate.node,
            crowd:      candidate.crowd,
            part:       candidate.crowd_part,
            channels:   renderer.assets.geometry(candidate.geometry).data.channels,
        );
    }
    return resolve_morph_block(
        renderer:  renderer,
        mesh_node: candidate.node,
        channels:  candidate.morph_channels,
        weights:   candidate.morph_weights,
    );
}

fn uint candidate_skin_stride(MeshCandidate* candidate) @private {
    return candidate.crowd && candidate.crowd.parts[candidate.crowd_part].skinned ? candidate.crowd.joint_count : 0;
}
