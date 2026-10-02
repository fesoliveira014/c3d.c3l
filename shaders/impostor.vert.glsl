#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "impostor.glsl"
#include "view_clip.glsl"

layout(location = 0) flat out uint v_source;
layout(push_constant) uniform Push { uint64_t vertex_root_gpu; uint64_t fragment_root_gpu; } pc;

const vec2 IMPOSTOR_CORNERS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0)
);

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    ImpostorGpu impostor = ImpostorGpu(LodPartGpu(draw.lod_part).impostor);
    v_source = draw.instance_indices != 0ul ? ImpostorIndices(draw.instance_indices).values[gl_InstanceIndex] : uint(gl_InstanceIndex);
    InstanceGpu instance = impostor_instance(draw, v_source);
    vec2 minimum = vec2(1.0);
    vec2 maximum = vec2(-1.0);
    vec3 reach = vec3(0.0);
    if ((draw.flags & DRAW_SWAY) != 0u) {
        vec4 sway = InstanceEffectsGpu(draw.instance_effects).sway.direction_amplitude;
        reach = abs(sway.xyz) * sway.w;
    }
    for (uint corner = 0u; corner < 8u; corner++) {
        vec3 sign_corner = vec3((corner & 1u) != 0u ? 1.0 : -1.0, (corner & 2u) != 0u ? 1.0 : -1.0, (corner & 4u) != 0u ? 1.0 : -1.0);
        vec3 local = impostor.bounds.xyz + sign_corner * impostor.bounds.w;
        vec3 world = (instance.model * vec4(local, 1.0)).xyz + sign_corner * reach;
        if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
            InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
            vec3 anchor = instance_anchor(effects, instance.model);
            world = mix(anchor, world, instance_fade_scale(effects, anchor, instance.normal_0.w));
        }
        vec4 clip = frame.view_proj * vec4(world, 1.0);
        if (clip.w <= 0.0) { minimum = vec2(-1.0); maximum = vec2(1.0); break; }
        minimum = min(minimum, clip.xy / clip.w);
        maximum = max(maximum, clip.xy / clip.w);
    }
    gl_Position = vec4(mix(minimum, maximum, IMPOSTOR_CORNERS[gl_VertexIndex]), 0.5, 1.0);
    gl_ClipDistance[0] = 1.0;
}
