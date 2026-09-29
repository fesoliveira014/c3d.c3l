#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "material_alpha.glsl"
#include "scene_snapshot.glsl"

const float RIPPLE_UV = 0.012;          // largest refraction offset in screen uv
const float RIPPLE_WAVENUMBER = 9.0;    // radians per metre
const float RIPPLE_SPEED = 1.7;         // radians per second
const float RIPPLE_CROSS_RATE = 0.8;    // the second axis runs slower, so the crests never line up
const vec3 ABSORPTION = vec3(2.2, 0.9, 0.35); // per metre: red is absorbed first
const float BACKGROUND_PATH = 4.0;      // metres assumed where the refracted ray finds no surface
const float FOAM_DISTANCE = 0.06;       // forward metres of gap that still show foam
const vec3 FOAM_COLOR = vec3(0.85, 0.9, 0.95);

layout(location = 0) in vec3 v_world_pos;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);

    float phase = frame.jitter_time.z * RIPPLE_SPEED;
    vec2 ripple = vec2(
        sin(v_world_pos.x * RIPPLE_WAVENUMBER + phase),
        cos(v_world_pos.z * RIPPLE_WAVENUMBER + phase * RIPPLE_CROSS_RATE));
    vec2 direct_uv = scene_uv(frame, gl_FragCoord.xy);
    vec2 refracted_uv = direct_uv + ripple * RIPPLE_UV;
    // Reverse-Z: a larger depth is nearer, so the offset sample landed on something in front of the water.
    if (scene_depth_at(frame, refracted_uv) > gl_FragCoord.z) refracted_uv = direct_uv;

    float floor_depth = scene_depth_at(frame, refracted_uv);
    float path = floor_depth > 0.0
        ? distance(v_world_pos, scene_position_at(frame, refracted_uv)) : BACKGROUND_PATH;
    vec3 color = scene_color_at(frame, refracted_uv) * exp(-ABSORPTION * path);
    float foam = 1.0 - clamp(scene_depth_gap(frame, gl_FragCoord) / FOAM_DISTANCE, 0.0, 1.0);
    out_color = material_output(mix(color, FOAM_COLOR, foam), 1.0, material.flags);
}
