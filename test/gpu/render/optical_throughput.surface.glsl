#ifndef C3D_OPTICAL_THROUGHPUT_SURFACE_GLSL
#define C3D_OPTICAL_THROUGHPUT_SURFACE_GLSL
struct OpticalSurface {
    vec4 bounds;
    vec4 base_coverage;
    vec4 factors;
    vec4 specular_cosine;
    vec4 attenuation_distance;
    vec4 normal_thickness;
    vec4 model_scale;
    vec4 plane;
    uint node_index;
    uint node_generation;
    uint part_index;
    uint range_index;
    uint instance_index;
    uint primitive_index;
    uint flags;
    uint map;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OpticalSurfaces { OpticalSurface values[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OpticalDraw {
    uint64_t surfaces;
    uint first;
    uint phase;
    uint previous;
    uint selected;
    uint source;
    uint sampler_index;
    uint enabled;
    float receiver_depth;
    uint padding0;
    uint padding1;
};
const uint OPTICAL_ALPHA_BLEND = 1u;
const uint OPTICAL_ALPHA_MASK = 2u;
const uint OPTICAL_ADDITIVE = 4u;
const uint OPTICAL_CAST_OFF = 8u;
const uint OPTICAL_OPAQUE = 16u;
const uint OPTICAL_FACE_POLICY = 32u;
const uint OPTICAL_DOUBLE_SIDED = 64u;
const uint OPTICAL_REVERSED = 128u;
const uint OPTICAL_MIRRORED = 256u;
const uint OPTICAL_PHASE_SURFACE = 0u;
const uint OPTICAL_PHASE_CAPTURE = 1u;
const uint OPTICAL_PHASE_PRODUCT = 2u;
const uint OPTICAL_PHASE_STORE = 3u;
const uint OPTICAL_PHASE_OPAQUE = 4u;
const uint OPTICAL_PHASE_LEGACY = 5u;

bool optical_surface_survives(OpticalSurface surface) {
    return (surface.flags & OPTICAL_CAST_OFF) == 0u
        && ((surface.flags & OPTICAL_ALPHA_MASK) == 0u || surface.base_coverage.a >= surface.plane.z);
}

bool optical_surface_participates(OpticalSurface surface) {
    return optical_surface_survives(surface) && (surface.flags & OPTICAL_OPAQUE) == 0u
        && surface.factors.x > 0.0;
}

bool optical_surface_blocks(OpticalSurface surface) {
    return optical_surface_survives(surface) && ((surface.flags & OPTICAL_OPAQUE) != 0u
        || ((surface.flags & OPTICAL_ALPHA_BLEND) == 0u && surface.factors.x == 0.0));
}
vec3 optical_surface_throughput(OpticalSurface surface) {
    if ((surface.flags & OPTICAL_CAST_OFF) != 0u) return vec3(1.0);
    float alpha = surface.base_coverage.a;
    if ((surface.flags & OPTICAL_ALPHA_MASK) != 0u && alpha < surface.plane.z) return vec3(1.0);
    if ((surface.flags & OPTICAL_ALPHA_BLEND) != 0u && surface.factors.x == 0.0) return vec3(1.0);
    vec3 normal = normalize(surface.normal_thickness.xyz);
    float cosine = max(normal.z, 0.0);
    float ratio = (surface.factors.z - 1.0) / (surface.factors.z + 1.0);
    vec3 reflectance = min(vec3(ratio * ratio) * surface.specular_cosine.rgb, vec3(1.0)) * surface.factors.w;
    float complement = 1.0 - cosine;
    float square = complement * complement;
    vec3 fresnel = reflectance + (vec3(surface.factors.w) - reflectance) * square * square * complement;
    vec3 ray = normalize(refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / surface.factors.z))
        * surface.normal_thickness.w * surface.model_scale.xyz;
    vec3 attenuation = surface.attenuation_distance.w == 0.0 || surface.normal_thickness.w == 0.0
        ? vec3(1.0)
        : pow(surface.attenuation_distance.rgb, vec3(length(ray) / surface.attenuation_distance.w));
    vec3 transmitted = surface.factors.x * (1.0 - surface.factors.y) * surface.base_coverage.rgb
        * (1.0 - fresnel) * attenuation;
    float coverage = (surface.flags & OPTICAL_ALPHA_BLEND) != 0u ? alpha : 1.0;
    return vec3(1.0 - coverage) + coverage * transmitted;
}
#endif
