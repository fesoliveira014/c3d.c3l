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
        return mesh_vertex_variant(
            flags:      flags,
            morphed:    false,
            skinned:    false,
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
    return cache;
}

fn void destroy_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.free();
    cache.morph_blocks.free();
}

fn void reset_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.clear();
    cache.morph_blocks.clear();
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
    Mat4f* palette = (Mat4f*)span.bytes.ptr;
    Mat4[] inverse_bind = renderer.assets.skeleton(binding.skeleton).data.inverse_bind;
    Mat4 inverse_mesh = maths::inverse_affine(mesh_node.world);
    foreach (index, joint : binding.joints) {
        palette[index] = bitcast(inverse_mesh.mul(joint.world).mul(inverse_bind[index]), Mat4f);
    }
    renderer.deformation.palettes.set((ulong)(uptr)mesh_node, span.address);
    return span.address;
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
