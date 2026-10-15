#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

const uint TILE_VALUES_PER_LANE = 4u;
const uint TILE_THREADS = POST_TILE_SIZE * POST_TILE_SIZE / TILE_VALUES_PER_LANE;

layout(local_size_x = TILE_THREADS) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

struct TileSample {
    vec2 value;
    float metric;
};

shared vec2 group_values[TILE_THREADS];
shared float group_metrics[TILE_THREADS];

TileSample read_sample(TileRoot root, ivec2 texel) {
    vec4 value = load_storage_texture(root.input_texture, texel);
    if (root.mode == TILE_MODE_ALPHA) return TileSample(vec2(value.a, 0.0), value.a);
    return TileSample(value.rg, dot(value.rg, value.rg));
}

TileSample select_pair(TileSample first, TileSample second) {
    if (second.metric > first.metric) return second;
    return first;
}

void main() {
    TileRoot root = TileRoot(pc.root_gpu);
    uvec2 tile = gl_WorkGroupID.xy;
    uint lane = gl_LocalInvocationIndex;
    uint first = lane * TILE_VALUES_PER_LANE;
    ivec2 origin = ivec2(tile * POST_TILE_SIZE);
    ivec2 texel = origin + ivec2(first % POST_TILE_SIZE, first / POST_TILE_SIZE);

    TileSample left = select_pair(read_sample(root, texel), read_sample(root, texel + ivec2(1, 0)));
    TileSample right = select_pair(read_sample(root, texel + ivec2(2, 0)), read_sample(root, texel + ivec2(3, 0)));
    TileSample selected = select_pair(left, right);
    group_values[lane] = selected.value;
    group_metrics[lane] = selected.metric;
    barrier();

    for (uint stride = 1u; stride < TILE_THREADS; stride <<= 1u) {
        uint index = lane * stride * 2u;
        if (index < TILE_THREADS && group_metrics[index + stride] > group_metrics[index]) {
            group_metrics[index] = group_metrics[index + stride];
            group_values[index] = group_values[index + stride];
        }
        barrier();
    }

    if (lane == 0u) {
        store_storage_texture(root.output_texture, ivec2(tile), vec4(group_values[0], 0.0, 0.0));
    }
}
