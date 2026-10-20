#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 64) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer DisplaceRoot {
    uint64_t positions;
    uint     count;
    float    offset_x;
    float    offset_y;
    float    offset_z;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer PackedPositions {
    float values[];
};

void main() {
    DisplaceRoot root = DisplaceRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    PackedPositions positions = PackedPositions(root.positions);
    positions.values[3 * index] += root.offset_x;
    positions.values[3 * index + 1] += root.offset_y;
    positions.values[3 * index + 2] += root.offset_z;
}
