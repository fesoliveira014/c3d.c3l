#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"
#include "fog.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Fogs every pixel in place at the depth it holds; cleared depth is the background.
void main() {
    FogPassRoot root = FogPassRoot(pc.root_gpu);
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(root.width) || pixel.y >= int(root.height)) return;

    FrameRoot frame = FrameRoot(root.frame);
    vec2 uv = (vec2(pixel) + 0.5) / vec2(root.width, root.height);
    float depth = fetch_texture_2d(root.depth, pixel).r;
    FogTerms fog = depth == 0.0
        ? fog_background_terms(frame, uv)
        : fog_terms(frame, uv, reconstruct_world_position(frame, uv, depth));
    vec4 color = load_storage_texture(root.color, pixel);
    store_storage_texture(root.color, pixel, vec4(color.rgb * fog.transmittance + fog.inscatter, color.a));
}
