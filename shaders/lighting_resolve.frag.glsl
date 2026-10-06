#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#include "shadows.glsl"
#include "standard_shading.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const float RT_REFLECTION_FADE = 0.2; // share of the threshold over which traced and prefiltered radiance blend; hides the seam
const float FACE_SIDE_MISSING = 1e30; // error of a side that leaves the image or meets the background

vec3 texel_world_position(
    FrameRoot frame,
    ivec2 texel,
    ivec2 extent,
    float depth
) {
    return reconstruct_world_position(frame, (vec2(texel) + 0.5) / vec2(extent), depth);
}

// Depth is linear in screen space across a plane, so a side whose two texels extrapolate to the
// centre's depth lies on the centre's face; a crease or a silhouette breaks the line.
float face_side_error(
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    ivec2 side,
    float depth,
    out float side_depth
) {
    side_depth = 0.0;
    ivec2 far_texel = texel + 2 * side;
    if (any(lessThan(far_texel, ivec2(0))) || any(greaterThanEqual(far_texel, extent))) return FACE_SIDE_MISSING;
    side_depth = fetch_texture_2d(depth_texture, texel + side).r;
    float far_depth = fetch_texture_2d(depth_texture, far_texel).r;
    if (side_depth == 0.0 || far_depth == 0.0) return FACE_SIDE_MISSING;
    return abs(2.0 * side_depth - far_depth - depth);
}

vec3 face_axis_step(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    ivec2 axis,
    float depth,
    vec3 centre
) {
    float forward_depth;
    float backward_depth;
    float forward_error = face_side_error(depth_texture, texel, extent, axis, depth, forward_depth);
    float backward_error = face_side_error(depth_texture, texel, extent, -axis, depth, backward_depth);
    if (min(forward_error, backward_error) == FACE_SIDE_MISSING) return vec3(0.0);
    if (forward_error <= backward_error) {
        return texel_world_position(frame, texel + axis, extent, forward_depth) - centre;
    }
    return centre - texel_world_position(frame, texel - axis, extent, backward_depth);
}

// The face under the texel from depth alone, turned toward the camera; the normal map never reaches it.
vec3 depth_face_normal(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    float depth,
    vec3 toward_camera
) {
    ivec2 extent = texture_extent(depth_texture);
    vec3 centre = texel_world_position(frame, texel, extent, depth);
    vec3 across = face_axis_step(frame, depth_texture, texel, extent, ivec2(1, 0), depth, centre);
    vec3 down = face_axis_step(frame, depth_texture, texel, extent, ivec2(0, 1), depth, centre);
    vec3 normal = cross(down, across);
    float normal_length = length(normal);
    if (normal_length == 0.0) return toward_camera;
    normal /= normal_length;
    return dot(normal, toward_camera) < 0.0 ? -normal : normal;
}

void main() {
    LightingResolveRoot root = LightingResolveRoot(pc.fragment_root_gpu);
    float depth = sample_texture_2d(root.depth, root.sampler_index, v_uv).r;
    // No geometry keeps the pass clear color for the sky.
    if (depth == 0.0) discard;

    FrameRoot frame = FrameRoot(root.frame);
    vec3 world_position = reconstruct_world_position(frame, v_uv, depth);
    vec4 base_color_metallic = sample_texture_2d(root.base_color_metallic, root.sampler_index, v_uv);
    vec4 normal_roughness = sample_texture_2d(root.normal_roughness, root.sampler_index, v_uv);
    vec4 emissive_specular = sample_texture_2d(root.emissive_specular, root.sampler_index, v_uv);
    ivec2 texel = ivec2(gl_FragCoord.xy);
    uint layers = gpu_fetch_uint(root.layers, texel, 0);
    uint flags = gpu_fetch_uint(root.flags, texel, 0);

    vec3 base_color = base_color_metallic.rgb;
    float metallic = base_color_metallic.a;
    vec3 normal = decode_octahedral(normal_roughness.rg);
    float roughness = normal_roughness.b;
    float occlusion = normal_roughness.a;
    float specular_weight = emissive_specular.a;
    vec3 view_direction = standard_view_direction(frame, world_position);
    StandardSurface surface = prepare_surface(
        base_color,
        metallic,
        roughness,
        normal,
        view_direction,
        STANDARD_DIELECTRIC_REFLECTANCE * specular_weight,
        vec3(specular_weight)
    );

    float ambient_occlusion = frame_ambient_occlusion(frame, texel);
    vec4 screen_indirect = frame_screen_space_indirect(frame, texel);
    vec3 color = standard_ambient_fill(frame, base_color, metallic, occlusion, ambient_occlusion, screen_indirect)
        + emissive_specular.rgb;
    vec3 diffuse = vec3(0.0);
    vec3 specular = vec3(0.0);
    if (frame_has_indirect(frame)) {
        evaluate_environment_lobes(
            frame,
            world_position,
            surface,
            roughness,
            occlusion,
            ambient_occlusion,
            screen_indirect,
            diffuse,
            specular
        );
    }
    if (root.reflection_texture != 0u) {
        // Texel fetch: a filtered read would blend traced and untraced texels at the region's edge.
        vec4 traced = fetch_texture_2d(root.reflection_texture, texel);
        if (traced.a > 0.0) {
            float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
            vec3 traced_specular = traced.rgb
                * environment_brdf_weight(root.brdf_lut, root.sampler_index, surface, perceptual);
            float threshold = root.max_reflection_roughness;
            specular = mix(specular, traced_specular, clamp((threshold - roughness) / (RT_REFLECTION_FADE * threshold), 0.0, 1.0));
        }
    }
    color += diffuse + specular;
    color += evaluate_standard_lights(
        frame,
        surface,
        world_position,
        depth_face_normal(frame, root.depth, texel, depth, view_direction),
        layers,
        (flags & GBUFFER_FLAG_RECEIVE_SHADOW) != 0u
    );
    out_color = vec4(color, 1.0);
}
