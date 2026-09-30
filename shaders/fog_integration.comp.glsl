#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// One column front to back, in place: in-scatter and transmittance from the camera to each slice's far boundary.
void main() {
    FogVolumeRoot root = FogVolumeRoot(pc.root_gpu);
    ivec2 column = ivec2(gl_GlobalInvocationID.xy);
    if (column.x >= int(root.width) || column.y >= int(root.height)) return;

    vec3 inscatter = vec3(0.0);
    float transmittance = 1.0;
    for (int slice = 0; slice < int(FOG_VOLUME_SLICES); slice++) {
        ivec3 froxel = ivec3(column, slice);
        vec4 medium = load_storage_texture_3d(root.volume, froxel);
        float slice_transmittance = exp(-medium.a);
        inscatter += transmittance * medium.rgb * (1.0 - slice_transmittance);
        transmittance *= slice_transmittance;
        store_storage_texture_3d(root.volume, froxel, vec4(inscatter, transmittance));
    }
}
