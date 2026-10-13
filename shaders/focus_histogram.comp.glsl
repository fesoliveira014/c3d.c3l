#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"
#include "focus.glsl"

layout(local_size_x = FOCUS_GROUP_SIZE, local_size_y = FOCUS_GROUP_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared uint group_bins[FOCUS_HISTOGRAM_BINS];
shared uint group_fractions[FOCUS_HISTOGRAM_BINS];

// Forward distance from reverse-Z depth, the formula of dof_linear_depth.
float linear_depth(FocusMeterRoot root, float depth) {
    if (root.orthographic != 0u) return (root.proj_23 - depth) / root.proj_22;
    float denominator = depth + root.proj_22;
    return denominator > 0.0 ? root.proj_23 / denominator : exp2(FOCUS_LOG2_MAX);
}

void main() {
    FocusMeterRoot root = FocusMeterRoot(pc.root_gpu);
    uint bin = gl_LocalInvocationIndex;
    group_bins[bin] = 0u;
    group_fractions[bin] = 0u;
    barrier();

    uvec2 texel = uvec2(root.origin_x, root.origin_y) + gl_GlobalInvocationID.xy;
    ivec2 offset = ivec2(texel) - ivec2(root.center_x, root.center_y);
    bool inside = texel.x < root.width && texel.y < root.height
        && float(offset.x * offset.x + offset.y * offset.y) <= root.radius * root.radius;
    if (inside) {
        // Depth 0 is no geometry; a target farther than the histogram reaches is no target either.
        float depth = fetch_texture_2d(root.depth_texture, ivec2(texel)).r;
        float distance = linear_depth(root, depth);
        if (depth > 0.0 && distance > 0.0 && distance < exp2(FOCUS_LOG2_MAX)) {
            float position = focus_position(distance);
            uint target_bin = min(uint(position), FOCUS_HISTOGRAM_BINS - 1u);
            atomicAdd(group_bins[target_bin], 1u);
            atomicAdd(group_fractions[target_bin], uint(fract(position) * FOCUS_FRACTION_STEPS));
        }
    }

    barrier();

    uint count = group_bins[bin];
    if (count != 0u) {
        atomicAdd(FocusHistogramGpu(root.histogram).bins[bin], count);
        atomicAdd(FocusHistogramGpu(root.histogram).fractions[bin], group_fractions[bin]);
    }
}
