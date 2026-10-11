#ifndef C3D_OPTICAL_LIGHT_GLSL
#define C3D_OPTICAL_LIGHT_GLSL
const uint OPTICAL_LIGHT_DIRECTIONAL = 0u;
const uint OPTICAL_LIGHT_POINT = 1u;
const uint OPTICAL_LIGHT_SPOT = 2u;
const uint OPTICAL_LIGHT_LAYER_ONE = 512u;
const uint OPTICAL_LIGHT_LAYER_TWO = 1024u;
const float OPTICAL_SPOT_TANGENT = 0.5773502691896258;
const float OPTICAL_SPOT_COSINE = 0.8660254037844386;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OpticalLightDraw {
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
    uint kind;
    uint layers;
    uint padding2;
    uint padding3;
};

bool optical_light_layer(OpticalSurface surface, uint layers) {
    uint authored = surface.flags & (OPTICAL_LIGHT_LAYER_ONE | OPTICAL_LIGHT_LAYER_TWO);
    return authored == 0u || (authored & layers) != 0u;
}

vec3 optical_light_throughput(OpticalSurface surface, vec3 direction) {
    if ((surface.flags & OPTICAL_CAST_OFF) != 0u) return vec3(1.0);
    if ((surface.flags & OPTICAL_ALPHA_MASK) != 0u && surface.base_coverage.a < surface.plane.z) return vec3(1.0);
    if ((surface.flags & OPTICAL_ALPHA_BLEND) != 0u && surface.factors.x == 0.0) return vec3(1.0);

    vec3 normal = normalize(surface.normal_thickness.xyz);
    float cosine = max(dot(normal, -direction), 0.0);
    float ratio = (surface.factors.z - 1.0) / (surface.factors.z + 1.0);
    vec3 reflectance = min(vec3(ratio * ratio) * surface.specular_cosine.rgb, vec3(1.0)) * surface.factors.w;
    float complement = 1.0 - cosine;
    float square = complement * complement;
    vec3 fresnel = reflectance + (vec3(surface.factors.w) - reflectance) * square * square * complement;
    vec3 ray = normalize(refract(direction, normal, 1.0 / surface.factors.z))
        * surface.normal_thickness.w * surface.model_scale.xyz;
    vec3 attenuation = surface.attenuation_distance.w == 0.0 || surface.normal_thickness.w == 0.0
        ? vec3(1.0)
        : pow(surface.attenuation_distance.rgb, vec3(length(ray) / surface.attenuation_distance.w));
    vec3 transmitted = surface.factors.x * (1.0 - surface.factors.y) * surface.base_coverage.rgb
        * (1.0 - fresnel) * attenuation;
    float coverage = (surface.flags & OPTICAL_ALPHA_BLEND) != 0u ? surface.base_coverage.a : 1.0;
    return vec3(1.0 - coverage) + coverage * transmitted;
}
#endif
