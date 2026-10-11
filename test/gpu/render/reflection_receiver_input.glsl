#ifndef REFLECTION_RECEIVER_INPUT_GLSL
#define REFLECTION_RECEIVER_INPUT_GLSL

#include "buffer_reference.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "brdf.glsl"
#include "ibl.glsl"

const uint RECEIVER_WORD_COUNT = 7u; // Mirrors RECEIVER_WORD_COUNT in test_reflection_receiver.c3.
const uint RECEIVER_CAPTURE = 0u;
const uint RECEIVER_CONSUMED_WORDS = 1u;
const uint RECEIVER_COMPOSED_COLOR = 2u;
const uint RECEIVER_FLOAT_COLOR = 3u;
const uint RECEIVER_DIRECTIONAL_ENVIRONMENT = 1u;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ReceiverRoot {
    uint64_t draw;
    uint words[7];
    uint source_depth;
    uint consumer_keys[2];
    uint consumer_depth;
    uint ordinal_base;
    uint phase;
    uint material_kind;
    float fade;
    float ambient_occlusion;
    uint flags;
    uint padding;
    vec4 other_lobes;
    vec4 reflected_radiance;
    vec4 original_radiance;
};

struct ReceiverInput {
    StandardSurface surface;
    vec3 tangent;
    float roughness;
    float strength;
};

void receiver_pack(ReceiverInput input, uvec2 key, out uint words[7]) {
    words[0] = packUnorm2x16(encode_octahedral(input.surface.normal) * 0.5 + 0.5);
    words[1] = packUnorm2x16(encode_octahedral(input.tangent) * 0.5 + 0.5);
    words[2] = packUnorm2x16(input.surface.reflectance.rg);
    words[3] = packUnorm2x16(vec2(input.surface.reflectance.b, input.surface.grazing_reflectance.r));
    words[4] = packUnorm2x16(vec2(input.roughness, input.strength));
    words[5] = key.x;
    words[6] = key.y;
}

void receiver_load(ReceiverRoot root, ivec2 pixel, out uint words[7]) {
    for (uint word = 0u; word < RECEIVER_WORD_COUNT; word++) {
        words[word] = gpu_fetch_uint(root.words[word], pixel, 0);
    }
}

ReceiverInput receiver_decode(uint words[7], vec3 view_direction) {
    ReceiverInput input;
    vec3 normal = decode_octahedral(unpackUnorm2x16(words[0]) * 2.0 - 1.0);
    input.tangent = decode_octahedral(unpackUnorm2x16(words[1]) * 2.0 - 1.0);
    vec2 reflectance = unpackUnorm2x16(words[2]);
    vec2 blue_grazing = unpackUnorm2x16(words[3]);
    vec2 roughness_strength = unpackUnorm2x16(words[4]);
    input.roughness = roughness_strength.x;
    input.strength = roughness_strength.y;
    input.surface = prepare_surface(
        vec3(0.0), 0.0, input.roughness, normal, view_direction,
        vec3(reflectance, blue_grazing.x), vec3(blue_grazing.y)
    );
    if (input.strength > 0.0) {
        apply_anisotropy(input.surface, input.tangent, cross(normal, input.tangent), input.strength);
    }
    return input;
}

vec3 receiver_base(FrameRoot frame, ReceiverRoot root, ReceiverInput input, vec3 position) {
    vec3 diffuse;
    vec3 specular;
    ReflectionSelection selection;
    selection.count = 0u;
    evaluate_environment_lobes(
        frame, selection, position, input.surface, input.roughness,
        1.0, root.ambient_occlusion, vec4(0.0), diffuse, specular
    );
    return specular;
}

vec3 receiver_compose(FrameRoot frame, ReceiverRoot root, ReceiverInput input, vec3 position, bool matches) {
    vec3 base = receiver_base(frame, root, input, position);
    uint lut;
    uint sampler_index;
    environment_tables(frame, lut, sampler_index);
    float perceptual = max(input.roughness, MIN_PERCEPTUAL_ROUGHNESS);
    vec3 reflected = root.reflected_radiance.rgb
        * environment_brdf_weight(lut, sampler_index, input.surface, perceptual)
        * specular_occlusion(input.surface.normal_view, root.ambient_occlusion, perceptual);
    return root.other_lobes.rgb + (matches ? mix(base, reflected, root.fade) : base);
}

#ifndef RECEIVER_COMPUTE
#include "standard_surface.glsl"
#include "physical.glsl"

ReceiverInput receiver_mapped_input(
    ReceiverRoot root,
    FrameRoot frame,
    DrawRoot draw,
    GeometryRoot geometry,
    vec3 position,
    vec3 vertex_normal,
    vec4 tangent,
    vec2 uv0,
    vec2 uv1,
    vec4 vertex_color,
    bool back_face,
    out float coverage
) {
    StandardMaterialGpu standard = StandardMaterialRoot(draw.material).material;
    PhysicalMaterialGpu physical = PhysicalMaterialGpu(draw.material);
    StandardMaterialSample material_sample = sample_standard_material(
        standard, geometry, position, vertex_normal, tangent, uv0, uv1,
        standard_view_direction(frame, position), back_face
    );
    material_sample.base_color *= vertex_color;
    coverage = material_sample.base_color.a;
    float weight = 1.0;
    vec3 dielectric = STANDARD_DIELECTRIC_REFLECTANCE;
    float strength = 0.0;
    vec2 rotation = vec2(1.0, 0.0);
    if (root.material_kind != 0u) {
        weight = physical.specular_color_weight.w;
        vec3 color = physical.specular_color_weight.rgb;
        if (weight > 0.0) {
            if ((physical.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR) != 0u) {
                weight = clamp(weight * sample_map(
                    physical.specular_map, physical.extension_map_flags,
                    PHYSICAL_EXTENSION_MAP_SPECULAR, uv0, uv1
                ).a, 0.0, 1.0);
            }
            if ((physical.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR) != 0u) {
                color *= sample_map(
                    physical.specular_color_map, physical.extension_map_flags,
                    PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR, uv0, uv1
                ).rgb;
            }
        }
        dielectric = min(dielectric_normal_reflectance(physical.ior) * color, vec3(1.0)) * weight;
        strength = physical.anisotropy;
        rotation = vec2(cos(physical.anisotropy_rotation), sin(physical.anisotropy_rotation));
        if ((physical.extension_map_flags & PHYSICAL_EXTENSION_MAP_ANISOTROPY) != 0u && strength > 0.0) {
            vec3 mapped = sample_map(
                physical.anisotropy_map, physical.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_ANISOTROPY, uv0, uv1
            ).rgb;
            rotation = mat2(rotation.x, rotation.y, -rotation.y, rotation.x) * (mapped.rg * 2.0 - 1.0);
            strength *= mapped.b;
        }
    }
    ReceiverInput input;
    input.roughness = material_sample.roughness;
    input.strength = strength;
    input.surface = prepare_surface(
        material_sample.base_color.rgb, material_sample.metallic, input.roughness,
        material_sample.normal, material_sample.view_direction, dielectric, vec3(weight)
    );
    vec3 frame_tangent;
    vec3 frame_bitangent;
    vec4 authored_tangent = tangent;
    if ((geometry.flags & GEOMETRY_HAS_TANGENTS) == 0u) {
        authored_tangent = derivative_tangent(
            normalize(vertex_normal), dFdx(position), dFdy(position), dFdx(uv0), dFdy(uv0)
        );
    }
    if (!surface_tangent_frame(normalize(vertex_normal), authored_tangent, frame_tangent, frame_bitangent)) {
        input.strength = 0.0;
        strength = 0.0;
        frame_tangent = normalize(cross(abs(input.surface.normal.z) < 0.9 ? vec3(0,0,1) : vec3(0,1,0), input.surface.normal));
        frame_bitangent = cross(input.surface.normal, frame_tangent);
    }
    vec3 direction = frame_tangent * rotation.x + frame_bitangent * rotation.y;
    direction -= input.surface.normal * dot(input.surface.normal, direction);
    input.tangent = normalize(direction);
    if (strength > 0.0) {
        apply_anisotropy(input.surface, input.tangent, cross(input.surface.normal, input.tangent), strength);
    }
    return input;
}
#endif

#endif
