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
    if (candidate.batch) {
        AnimatedCrowd* crowd = candidate.crowd;
        return mesh_vertex_variant(
            flags:      flags,
            morphed:    crowd != null && crowd.parts[candidate.crowd_part].target_count > 0,
            skinned:    crowd != null,
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
    return cache;
}

fn void destroy_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.free();
    cache.morph_blocks.free();
    cache.crowd_palettes.free();
    cache.crowd_morphs.free();
}

fn void reset_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.clear();
    cache.morph_blocks.clear();
    cache.crowd_palettes.clear();
    cache.crowd_morphs.clear();
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
            if (scene::transform_mirrored(placement) != (pass == 1)) continue;
            usz first = (usz)instance * crowd.morph_stride + target.target_offset;
            float[] weights = crowd.morph_weights[first:target.target_count];
            blocks[written++] = pack_morph_selection(geometry::select_morph_targets(channels, weights));
        }
    }
}

fn gpu::GpuAddress? resolve_crowd_palettes(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedCrowd* crowd = candidate.crowd;
    ulong key = (ulong)(uptr)candidate.node.parent;
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
    ulong offset = (ulong)candidate.instance_first * crowd.joint_count * Mat4f::size;
    return (gpu::GpuAddress)((ulong)base + offset);
}

fn gpu::GpuAddress? resolve_crowd_morphs(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedCrowd* crowd = candidate.crowd;
    ulong key = (ulong)(uptr)candidate.node;
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
            part:     candidate.crowd_part,
            channels: renderer.assets.geometry(candidate.geometry).data.channels,
        );
        renderer.deformation.crowd_morphs.set(key, span.address);
        base = span.address;
    }
    return (gpu::GpuAddress)((ulong)base + (ulong)candidate.instance_first * MorphWeightsGpu::size);
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
    );
    renderer.deformation.palettes.set((ulong)(uptr)mesh_node, span.address);
    return span.address;
}

<*
 Mesh-space joint matrices of the binding under the current joint poses.
 @param [out] palette : "One entry per joint; written only."
 @param [&in] mesh_node : "World matrix as left by the last update."
 @param [&in] binding : "Live joints."
*>
fn void evaluate_palette(
    Mat4f[] palette,
    Node* mesh_node,
    SkinBinding* binding,
    Mat4[] inverse_bind,
) {
    Mat4 inverse_mesh = maths::inverse_affine(mesh_node.world);
    foreach (index, joint : binding.joints) {
        palette[index] = bitcast(inverse_mesh.mul(joint.world).mul(inverse_bind[index]), Mat4f);
    }
}

<*
 Morph block of the candidate's mesh for this frame, uploaded on first use.
 @param [&in] candidate : "Channels and live weights as extracted."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn gpu::GpuAddress? resolve_morph_block(Renderer* renderer, MeshCandidate* candidate) @private {
    Node* mesh_node = candidate.node;
    if (try existing = renderer.deformation.morph_blocks.get((ulong)(uptr)mesh_node)) return existing;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, MorphWeightsGpu::size, STREAM_ALIGNMENT)!;
    *(MorphWeightsGpu*)span.bytes.ptr = pack_morph_selection(
        geometry::select_morph_targets(candidate.morph_channels, candidate.morph_weights),
    );
    renderer.deformation.morph_blocks.set((ulong)(uptr)mesh_node, span.address);
    return span.address;
}

fn gpu::GpuAddress? resolve_candidate_skin(Renderer* renderer, MeshCandidate* candidate) @private {
    if (candidate.skin) return resolve_palette(renderer, candidate.node, candidate.skin);
    if (candidate.crowd) return resolve_crowd_palettes(renderer, candidate);
    return (gpu::GpuAddress)0;
}

fn gpu::GpuAddress? resolve_candidate_morph(
    Renderer* renderer,
    MeshCandidate* candidate,
    ShaderVariant vertex,
) @private {
    if (!(vertex.flags & shader::SHADER_FLAG_MORPH)) return (gpu::GpuAddress)0;
    if (candidate.crowd) return resolve_crowd_morphs(renderer, candidate);
    return resolve_morph_block(renderer, candidate);
}

fn uint candidate_skin_stride(MeshCandidate* candidate) @private {
    return candidate.crowd ? candidate.crowd.joint_count : 0;
}
