#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_trace.glsl"

layout(local_size_x = 8, local_size_y = 8) in; // mirrored as TRACE_GROUP_SIZE in terrain_trace_acceptance.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TraceProbeRoot {
    mat4 inv_view_proj;
    vec4 camera;
    uint64_t scene;
    uint64_t output_address;
    uint size;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct TraceProbeResult {
    float raster;
    float traced;
    uint flags;
    uint padding;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(TraceProbeOutput, TraceProbeResult);

const float TRACE_FAR = 1.0e30;
const uint RASTER_HIT = 1u; // mirrored as RASTER_HIT in terrain_trace_acceptance.c3
const uint TRACE_HIT = 2u;  // mirrored as TRACE_HIT in terrain_trace_acceptance.c3

// Raster distance from the view's reverse-Z depth and traced distance along the same pixel-centre ray.
void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    TraceProbeRoot root = TraceProbeRoot(dispatch.parameters);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.size || pixel.y >= root.size) return;

    vec2 uv = (vec2(pixel) + 0.5) / float(root.size);
    DispatchTextureGpu depth_texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    float depth = sample_texture_2d(depth_texture.texture_index, depth_texture.sampler_index, uv).r;
    vec2 ndc = (uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 far_point = root.inv_view_proj * vec4(ndc, 0.5, 1.0);
    vec3 direction = normalize(far_point.xyz / far_point.w - root.camera.xyz);

    TraceProbeResult result = TraceProbeResult(0.0, 0.0, 0u, 0u);
    if (depth > 0.0) {
        vec4 surface = root.inv_view_proj * vec4(ndc, depth, 1.0);
        result.raster = length(surface.xyz / surface.w - root.camera.xyz);
        result.flags |= RASTER_HIT;
    }
    SceneHit hit;
    if (trace_scene(SceneTraceRoot(root.scene), root.camera.xyz, direction, TRACE_FAR, TRACE_MASK_ALL, hit)) {
        result.traced = hit.t;
        result.flags |= TRACE_HIT;
    }
    TraceProbeOutput(root.output_address).values[pixel.y * root.size + pixel.x] = result;
}
