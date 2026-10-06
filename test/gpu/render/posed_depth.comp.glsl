#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_trace.glsl"

layout(local_size_x = 8, local_size_y = 8) in; // mirrored as POSED_GROUP_SIZE in test_posed_trace.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PosedDepthRoot {
    mat4 inv_view_proj;
    vec4 camera;
    uint64_t scene;
    uint64_t output_address;
    uint size;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct PosedDepthResult {
    float raster;
    float traced;
    uint geometry_low;
    uint flags;
    uint primitive;
    uint padding;
    vec2 barycentrics;
    vec4 normal;
    vec4 geometric_normal;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(PosedDepthOutput, PosedDepthResult);

const float POSED_TRACE_FAR = 1.0e30;
const uint POSED_RASTER_HIT = 1u; // mirrored as POSED_RASTER_HIT in test_posed_trace.c3
const uint POSED_TRACE_HIT = 2u;  // mirrored as POSED_TRACE_HIT in test_posed_trace.c3

// Raster distance from the view's reverse-Z depth; traced distance and normals along the same pixel-centre ray.
void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    PosedDepthRoot root = PosedDepthRoot(dispatch.parameters);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.size || pixel.y >= root.size) return;

    vec2 uv = (vec2(pixel) + 0.5) / float(root.size);
    DispatchTextureGpu depth_texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    float depth = sample_texture_2d(depth_texture.texture_index, depth_texture.sampler_index, uv).r;
    vec2 ndc = (uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 far_point = root.inv_view_proj * vec4(ndc, 0.5, 1.0);
    vec3 direction = normalize(far_point.xyz / far_point.w - root.camera.xyz);

    PosedDepthResult result = PosedDepthResult(0.0, 0.0, 0u, 0u, 0u, 0u, vec2(0.0), vec4(0.0), vec4(0.0));
    if (depth > 0.0) {
        vec4 surface = root.inv_view_proj * vec4(ndc, depth, 1.0);
        result.raster = length(surface.xyz / surface.w - root.camera.xyz);
        result.flags |= POSED_RASTER_HIT;
    }
    SceneTraceRoot scene = SceneTraceRoot(root.scene);
    SceneHit hit;
    if (trace_scene(scene, root.camera.xyz, direction, POSED_TRACE_FAR, TRACE_MASK_ALL, hit)) {
        result.traced = hit.t;
        result.geometry_low = uint(TraceInstanceArray(scene.instances).values[hit.instance].geometry);
        result.primitive = hit.primitive;
        result.barycentrics = hit.barycentrics;
        TraceSurface surface = surface_from_hit(scene, hit, direction, 0.0);
        result.normal = vec4(normalize(surface.normal), 0.0);
        result.geometric_normal = vec4(normalize(surface.geometric_normal), 0.0);
        result.flags |= POSED_TRACE_HIT;
    }
    PosedDepthOutput(root.output_address).values[pixel.y * root.size + pixel.x] = result;
}
