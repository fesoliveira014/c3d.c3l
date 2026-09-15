#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "grade.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    GradeRoot root = GradeRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec3 scene = sample_texture_2d(root.input_texture, root.sampler_index, uv).rgb;
    vec3 graded = grade_color(scene, root.grade);
    store_storage_texture(root.output_texture, ivec2(texel), vec4(graded, display_luma(graded)));
}
