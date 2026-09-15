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
 Palette and morph block addresses written this frame, by mesh entity index.
*>
struct DeformationCache {
    HashMap{uint, gpu::GpuAddress} palettes;
    HashMap{uint, gpu::GpuAddress} morph_blocks;
}

<*
 Vertex stage for the geometry's deformation streams.
 @param morphed : "The mesh carries morph weights."
 @param base_flags : "Variant flags of the pass, such as depth only."
 @pure
*>
fn ShaderVariant mesh_vertex_variant(GeometryFlags flags, bool morphed, uint base_flags = 0) {
    uint variant_flags = base_flags;
    if (flags.skinned) {
        variant_flags |= flags.joints_u16 ? shader::SHADER_FLAG_SKINNED_U16 : shader::SHADER_FLAG_SKINNED;
    }
    if (flags.has_morphs && morphed) variant_flags |= shader::SHADER_FLAG_MORPH;
    return { .shader = MESH, .flags = variant_flags };
}

<*
 The largest active targets by weight magnitude, with their original indices.
 @param channels : "Empty maps one weight to each target."
 @param weights : "One per channel, or per target when channels is empty."
 @pure
 @require channels.len == 0 || channels.len == weights.len
*>
fn MorphWeightsGpu select_morph_targets(MorphChannel[] channels, float[] weights) {
    MorphWeightsGpu block;
    if (!channels.len) {
        foreach (uint index, weight : weights) insert_morph_target(&block, index, weight);
        return block;
    }
    foreach (usz index, &channel : channels) {
        ChannelBlend blend = channel.blend(weights[index]);
        insert_morph_target(&block, blend.targets[0], blend.weights[0]);
        insert_morph_target(&block, blend.targets[1], blend.weights[1]);
    }
    return block;
}

<*
 @pure
*>
fn void insert_morph_target(MorphWeightsGpu* block, uint index, float weight) @local {
    if (weight == 0) return;
    float magnitude = math::abs(weight);
    uint slot = block.count;
    while (slot > 0 && math::abs(block.weights[slot - 1]) < magnitude) slot--;
    if (slot >= shader::MAX_ACTIVE_MORPH_TARGETS) return;
    uint last = math::min(block.count, shader::MAX_ACTIVE_MORPH_TARGETS - 1);
    for (uint move = last; move > slot; move--) {
        block.indices[move] = block.indices[move - 1];
        block.weights[move] = block.weights[move - 1];
    }
    block.indices[slot] = index;
    block.weights[slot] = weight;
    if (block.count < shader::MAX_ACTIVE_MORPH_TARGETS) block.count++;
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
    if (try existing = renderer.deformation.palettes.get(mesh_node.id.index)) return existing;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, binding.joints.len * Mat4f::size, STREAM_ALIGNMENT)!;
    Mat4f* palette = (Mat4f*)span.bytes.ptr;
    Mat4[] inverse_bind = renderer.assets.skeleton(binding.skeleton).data.inverse_bind;
    Mat4 inverse_mesh = maths::inverse_affine(mesh_node.world);
    foreach (index, joint : binding.joints) {
        palette[index] = bitcast(inverse_mesh.mul(joint.world).mul(inverse_bind[index]), Mat4f);
    }
    renderer.deformation.palettes.set(mesh_node.id.index, span.address);
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
    if (try existing = renderer.deformation.morph_blocks.get(mesh_node.id.index)) return existing;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, MorphWeightsGpu::size, STREAM_ALIGNMENT)!;
    *(MorphWeightsGpu*)span.bytes.ptr = select_morph_targets(candidate.morph_channels, candidate.morph_weights);
    renderer.deformation.morph_blocks.set(mesh_node.id.index, span.address);
    return span.address;
}
