#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"
#include "grade.glsl"
#include "exposure.glsl"

layout(local_size_x = EXPOSURE_GROUP_SIZE, local_size_y = EXPOSURE_GROUP_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared uint group_bins[EXPOSURE_HISTOGRAM_BINS];

void main() {
    ExposureMeterRoot root = ExposureMeterRoot(pc.root_gpu);
    uint bin = gl_LocalInvocationIndex;
    group_bins[bin] = 0u;
    barrier();

    uvec2 texel = gl_GlobalInvocationID.xy * EXPOSURE_METER_STRIDE;
    if (texel.x < root.width && texel.y < root.height) {
        float luminance = dot(fetch_texture_2d(root.input_texture, ivec2(texel)).rgb, REC709_LUMA);
        if (exposure_metered(luminance)) atomicAdd(group_bins[exposure_bin(luminance)], 1u);
    }
    barrier();

    uint count = group_bins[bin];
    if (count != 0u) atomicAdd(ExposureHistogramGpu(root.histogram).bins[bin], count);
}
