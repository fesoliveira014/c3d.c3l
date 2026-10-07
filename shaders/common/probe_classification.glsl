#ifndef C3D_PROBE_CLASSIFICATION_GLSL
#define C3D_PROBE_CLASSIFICATION_GLSL

#include "descriptor_heap.glsl"
#include "probe_atlas.glsl"

// Probe indices lie within the grid; the private history-reset state reads as measured eligibility.
uint probe_classification(ProbeVolumeGpu volume, uvec3 probe) {
    uvec3 counts = uvec3(volume.count_x, volume.count_y, volume.count_z);
    uvec2 cell = probe_cell(counts, volume.slices_per_row, probe);
    ivec2 texel = ivec2(cell * PROBE_IRRADIANCE_CELL + 1u);
    float stored = texelFetch(
        gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(volume.irradiance))], texel, 0).a;
    return min(uint(stored), PROBE_CLASS_ELIGIBLE);
}

#endif
