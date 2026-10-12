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
    HashMap{ulong, gpu::GpuAddress} crowd_bounds;
    AnimatedLodAddresses animated;
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

fn ShaderVariant candidate_vertex_variant(
    GeometryFlags flags,
    MeshCandidate* candidate,
    uint base_flags = 0,
    bool posed = false,
) @private {
    if (candidate.impostor) return { .shader = IMPOSTOR_VERTEX };
    if (candidate.animated_lod) {
        return mesh_vertex_variant(
            flags: flags,
            morphed: candidate.animated_lod.weight_count > 0,
            skinned: candidate.animated_lod.skinned,
            base_flags: base_flags | (candidate.crowd ? shader::SHADER_FLAG_INSTANCED : 0),
        );
    }

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
        morphed:    !posed && candidate.morph_weights.len > 0,
        skinned:    !posed && candidate.skin != null,
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
    cache.crowd_bounds.init(allocator);
    cache.animated = create_animated_lod_addresses(allocator);
    return cache;
}

fn void destroy_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.free();
    cache.morph_blocks.free();
    cache.crowd_bounds.free();
    destroy_animated_lod_addresses(&cache.animated);
}

fn void reset_deformation_cache(DeformationCache* cache) @private {
    cache.palettes.clear();
    cache.morph_blocks.clear();
    cache.crowd_bounds.clear();
    cache.animated.reset();
}

fn gpu::GpuAddress? resolve_crowd_bounds(Renderer* renderer, MeshCandidate* candidate) @private {
    AnimatedCrowd* crowd = candidate.crowd;
    if (!crowd || candidate.animated_lod || crowd.parts[candidate.crowd_part].skinned) return (gpu::GpuAddress)0;

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
 Packed draw slot of each live instance of one part: unmirrored instances first.
 @param [out] packed : "One entry per live instance."
 @param [&in] crowd : "Prepared crowd."
 @param part : "Logical crowd mesh."
 @require packed.len == crowd.count
*>
fn void crowd_packed_order(uint[] packed, AnimatedCrowd* crowd, uint part) {
    uint[2] next = { 0, crowd.count - crowd.part_mirrored_count(part) };
    foreach (uint instance, &slot : packed) *slot = next[crowd.part_mirrored(instance, part) ? 1 : 0]++;
}

<*
 Morph block of one crowd instance for a part's geometry channels.
 @param [&in] crowd : "Morph weights written by crowd_update."
 @param part : "Logical crowd mesh."
 @param instance : "Logical source slot."
 @param channels : "Channels of the part's geometry."
*>
fn MorphWeightsGpu crowd_part_morph(
    AnimatedCrowd* crowd,
    uint part,
    uint instance,
    MorphChannel[] channels,
) {
    CrowdPart* target = &crowd.parts[part];
    usz first = (usz)instance * crowd.morph_stride + target.weight_offset;
    float[] weights = crowd.morph_weights[first:target.weight_count];
    return pack_morph_selection(geometry::select_morph_targets(channels, weights));
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
    if (candidate.animated_lod) return resolve_animated_lod_palette(renderer, candidate);

    if (candidate.skin) return resolve_palette(renderer, candidate.node, candidate.skin);
    if (candidate.crowd && candidate.crowd.parts[candidate.crowd_part].skinned) {
        return resolve_crowd_palette(renderer, candidate)!.current;
    }

    return (gpu::GpuAddress)0;
}

fn gpu::GpuAddress? resolve_candidate_morph(
    Renderer* renderer,
    MeshCandidate* candidate,
    ShaderVariant vertex,
) @private {
    if (!(vertex.flags & shader::SHADER_FLAG_MORPH)) return (gpu::GpuAddress)0;
    if (candidate.animated_lod) return resolve_animated_lod_morph(renderer, candidate);

    if (candidate.crowd) return resolve_crowd_morph(renderer, candidate)!.current;
    return resolve_morph_block(
        renderer:  renderer,
        mesh_node: candidate.node,
        channels:  candidate.morph_channels,
        weights:   candidate.morph_weights,
    );
}

fn uint candidate_skin_stride(MeshCandidate* candidate) @private {
    if (candidate.animated_lod) {
        return candidate.crowd && candidate.animated_lod.skinned ? candidate.crowd.joint_count : 0;
    }

    return candidate.crowd && candidate.crowd.parts[candidate.crowd_part].skinned ? candidate.crowd.joint_count : 0;
}
