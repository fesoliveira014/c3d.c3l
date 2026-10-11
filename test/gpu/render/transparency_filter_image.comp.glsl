#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_snapshot.glsl"
#include "fog.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
layout(push_constant) uniform Push { uint64_t root; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ImageRoot {
    uint64_t output_address;
    uint64_t frame;
    uint width;
    uint height;
    uint source_width;
    uint source_height;
    uint source;
    uint destination;
    uint sampler_index;
    uint mode;
    uint pattern;
    uint level_count;
    float roughness;
    float ior;
    uint levels[16];
};
layout(buffer_reference, std430, buffer_reference_align = 16) buffer ImageOutput {
    vec4 values[];
};

vec4 backdrop(uint pattern, uvec2 pixel, uvec2 extent) {
    if (pattern == 0u) return vec4(0.0, 0.0, 0.0, 1.0);
    if (pattern == 1u) return vec4(0.25, 0.5, 1.0, 1.0);
    if (pattern == 2u) return vec4(4.0, 2.0, 1.0, 1.0);
    if (pattern == 3u) {
        float impulse = all(equal(pixel, extent / 2u)) ? 4.0 : 0.0;
        return vec4(vec3(impulse), 1.0);
    }
    if (pattern == 4u) return vec4(vec3(float((pixel.x + pixel.y) % 2u)), 1.0);
    if (pattern == 6u) return vec4(pixel.x < extent.x / 2u ? 1.0 : 2.0, 0.0, 0.0, 1.0);
    return vec4(vec3(pixel.x < extent.x / 2u ? 0.0 : 1.0), 1.0);
}

void main() {
    ImageRoot root = ImageRoot(pc.root);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    if (root.mode == 0u) {
        store_storage_texture(root.destination, ivec2(pixel), backdrop(root.pattern, pixel, uvec2(root.width, root.height)));
        return;
    }
    if (root.mode == 1u) {
        vec2 scale = vec2(root.source_width, root.source_height) / vec2(root.width, root.height);
        vec2 low = vec2(pixel) * scale;
        vec2 high = vec2(pixel + 1u) * scale;
        ivec2 begin = ivec2(floor(low));
        ivec2 end = min(ivec2(ceil(high)), ivec2(root.source_width, root.source_height));
        vec4 sum = vec4(0.0);
        for (int y = begin.y; y < end.y; y++) {
            float vertical = min(high.y, float(y + 1)) - max(low.y, float(y));
            for (int x = begin.x; x < end.x; x++) {
                float horizontal = min(high.x, float(x + 1)) - max(low.x, float(x));
                vec4 value = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.source))], ivec2(x, y), 0);
                sum += value * (horizontal * vertical);
            }
        }
        store_storage_texture(root.destination, ivec2(pixel), sum / (scale.x * scale.y));
        return;
    }

    vec2 uv = (vec2(pixel) + 0.5) / vec2(root.width, root.height);
    float lod = min(float(root.level_count - 1u),
        log2(float(max(root.width, root.height))) * root.roughness * clamp(2.0 * root.ior - 2.0, 0.0, 1.0));
    vec3 filtered;
    if (root.roughness == 0.0) {
        filtered = scene_color_at(FrameRoot(root.frame), uv);
    } else {
        uint low = uint(floor(lod));
        uint high = min(low + 1u, root.level_count - 1u);
        vec3 first = sample_texture_2d(root.levels[low], root.sampler_index, uv).rgb;
        vec3 second = sample_texture_2d(root.levels[high], root.sampler_index, uv).rgb;
        filtered = mix(first, second, fract(lod));
    }
    ImageOutput output_value = ImageOutput(root.output_address);
    uint offset = pixel.y * root.width + pixel.x;
    if (root.mode == 2u) {
        output_value.values[offset] = vec4(filtered, lod);
    } else if (root.mode == 3u || root.mode == 5u) {
        float anchor = scene_depth_at(FrameRoot(root.frame), uv);
        if (root.mode == 5u) {
            output_value.values[offset] = vec4(fog_behind(
                FrameRoot(root.frame), vec3(0.0, 0.0, -0.5), filtered, anchor), anchor);
            return;
        }
        FogTerms near_terms = FogTerms(vec3(exp(-0.5)), vec3(0.0));
        FogTerms far_terms = FogTerms(vec3(exp(-max(anchor, 0.5))), vec3(0.0));
        FogTerms connecting = fog_between(near_terms, far_terms);
        output_value.values[offset] = vec4(connecting.transmittance * filtered + connecting.inscatter, anchor);
    } else {
        output_value.values[offset] = vec4(scene_color_at(FrameRoot(root.frame), uv), lod);
    }
}
