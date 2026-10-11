#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "reflection_receiver_input.glsl"
#include "material_alpha.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;
layout(location = 7) flat in uint v_receiver_instance;

#ifdef RECEIVER_DEFERRED_IDENTITY
layout(location = 0) out vec4 out_base;
layout(location = 1) out vec4 out_normal;
layout(location = 2) out vec4 out_emissive;
layout(location = 3) out uint out_layers;
layout(location = 4) out uint out_flags;
layout(location = 5) out uint out_key0;
layout(location = 6) out uint out_key1;
#else
layout(location = 0) out uint out_word0;
layout(location = 1) out uint out_word1;
layout(location = 2) out uint out_word2;
layout(location = 3) out uint out_word3;
layout(location = 4) out uint out_word4;
layout(location = 5) out uint out_word5;
layout(location = 6) out uint out_word6;
#endif

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    ReceiverRoot root = ReceiverRoot(draw.instance_effects);
    material_mip_bias = frame.mip_bias;
    float coverage;
    ReceiverInput input = receiver_mapped_input(
        root, frame, draw, geometry, v_world_pos, v_normal, v_tangent,
        v_uv0, v_uv1, v_color, !gl_FrontFacing, coverage
    );
    StandardMaterialGpu material = StandardMaterialRoot(draw.material).material;
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && coverage < material.alpha_cutoff) discard;
    uvec2 key = uvec2(root.ordinal_base + v_receiver_instance + 1u, uint(gl_PrimitiveID));
#ifdef RECEIVER_DEFERRED_IDENTITY
    out_base = vec4(0.0);
    out_normal = vec4(encode_octahedral(input.surface.normal), input.roughness, 1.0);
    out_emissive = vec4(0.0);
    out_layers = draw.layers;
    out_flags = 0u;
    out_key0 = key.x;
    out_key1 = key.y;
#else
    uint words[7];
    receiver_pack(input, key, words);
    if (root.phase != RECEIVER_CAPTURE) {
        uint stored[7];
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        receiver_load(root, pixel, stored);
        float depth = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.source_depth))], pixel, 0).r;
        bool matches = stored[5] == key.x && stored[6] == key.y && depth == gl_FragCoord.z;
        if (root.phase == RECEIVER_CONSUMED_WORDS) {
            for (uint word = 0u; word < RECEIVER_WORD_COUNT; word++) words[word] = matches ? stored[word] : 0u;
        } else {
            ReceiverInput chosen = root.phase == RECEIVER_FLOAT_COLOR || !matches
                ? input : receiver_decode(stored, input.surface.view_direction);
            vec3 color = receiver_compose(frame, root, chosen, v_world_pos, matches);
            words[0] = floatBitsToUint(color.r);
            words[1] = floatBitsToUint(color.g);
            words[2] = floatBitsToUint(color.b);
            words[3] = matches ? 1u : 0u;
            words[4] = key.x;
            words[5] = key.y;
            words[6] = floatBitsToUint(gl_FragCoord.z);
        }
    }
    out_word0 = words[0];
    out_word1 = words[1];
    out_word2 = words[2];
    out_word3 = words[3];
    out_word4 = words[4];
    out_word5 = words[5];
    out_word6 = words[6];
#endif
}
