#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"
#include "transparency.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;
layout(location = 1) out float out_continuation_depth;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

FogTerms transparency_camera_terms(FrameRoot frame, vec2 uv, float depth) {
    if (frame.sky_fog == 0ul) return fog_none();

    return depth == 0.0 ? fog_background_terms(frame, uv)
        : fog_terms(frame, uv, reconstruct_world_position(frame, uv, depth));
}

void main() {
    FrameRoot frame = FrameRoot(pc.fragment_root_gpu);
    TransparencyGpu transparency = TransparencyGpu(frame.transparency);
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec4 color = fetch_texture_2d(frame.scene_color, pixel);
    float anchor = 0.0;
    if (transparency.phase != TRANSPARENCY_INITIAL && transparency.phase != TRANSPARENCY_SEED
        && transparency.phase != TRANSPARENCY_UNFOG) {
        anchor = fetch_texture_2d(transparency.continuation_depth, pixel).r;
    }

    if (transparency.phase == TRANSPARENCY_INITIAL) {
        anchor = fetch_texture_2d(transparency.opaque_depth, pixel).r;
        FogTerms camera = transparency_camera_terms(frame, v_uv, anchor);
        color.rgb = color.rgb * camera.transmittance + camera.inscatter;
    } else if (transparency.phase == TRANSPARENCY_SEED) {
        float tail_depth = fetch_texture_2d(transparency.selected_depth, pixel).r;
        if (tail_depth != 0.0) {
            FogTerms camera = transparency_camera_terms(frame, v_uv, tail_depth);
            color.rgb = (color.rgb - camera.inscatter)
                / max(camera.transmittance, vec3(FOG_TRANSMITTANCE_FLOOR));
            anchor = tail_depth;
        } else {
            color = fetch_texture_2d(transparency.opaque_color, pixel);
            anchor = fetch_texture_2d(transparency.opaque_depth, pixel).r;
        }
    } else if (transparency.phase == TRANSPARENCY_CONNECT) {
        float near_depth = fetch_texture_2d(transparency.selected_depth, pixel).r;
        if (near_depth != 0.0) {
            vec3 position = reconstruct_world_position(frame, v_uv, near_depth);
            color.rgb = layered_transparency_transfer(frame, position, color.rgb, anchor);
            anchor = near_depth;
        }
    } else if (transparency.phase == TRANSPARENCY_UNFOG) {
        anchor = fetch_texture_2d(transparency.opaque_depth, pixel).r;
        FogTerms camera = transparency_camera_terms(frame, v_uv, anchor);
        color.rgb = (color.rgb - camera.inscatter)
            / max(camera.transmittance, vec3(FOG_TRANSMITTANCE_FLOOR));
    } else if (transparency.phase == TRANSPARENCY_COMPOSITE) {
        FogTerms camera = transparency_camera_terms(frame, v_uv, anchor);
        color.rgb = color.rgb * camera.transmittance + camera.inscatter;
    }

    out_color = color;
    out_continuation_depth = anchor;
}
