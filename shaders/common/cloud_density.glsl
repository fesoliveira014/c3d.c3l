#ifndef C3D_CLOUD_DENSITY_GLSL
#define C3D_CLOUD_DENSITY_GLSL

#include "descriptor_heap.glsl"

const float CLOUD_DETAIL_FREQUENCY = 8.0;    // erosion repeats this many times per base repeat
const float CLOUD_EROSION_REACH = 0.5;       // share of a cloud's body the strongest erosion can carve away
const float CLOUD_BASE_RAMP = 0.1;           // share of the layer over which density rises from its bottom
const float CLOUD_TOP_ROUNDING = 0.4;        // share of a cloud's height over which it thins toward its top

// Extinction per metre at a point of the layer; the light march skips the detail octave.
float cloud_density(CloudsRoot root, vec2 horizontal, float altitude, bool detailed) {
    float fraction = (altitude - root.bottom) / (root.top - root.bottom);
    if (fraction <= 0.0 || fraction >= 1.0) return 0.0;

    vec2 weather = vec2(1.0);
    if (root.coverage != 0u) {
        weather = sample_texture_2d(
            root.coverage,
            root.coverage_sampler,
            (horizontal - root.wind_offset.xz) / root.coverage_extent
        ).rg;
    }
    float cover = weather.x;
    float profile = clamp(fraction / CLOUD_BASE_RAMP, 0.0, 1.0)
        * clamp((weather.y - fraction) / (CLOUD_TOP_ROUNDING * weather.y + 1e-4), 0.0, 1.0);
    if (cover <= 0.0 || profile <= 0.0) return 0.0;

    vec3 coordinate = vec3(
        horizontal.x - root.wind_offset.x,
        altitude - root.wind_offset.y,
        horizontal.y - root.wind_offset.z
    ) / root.noise_scale;
    vec4 shape = sample_texture_3d(root.noise, root.noise_sampler, coordinate);
    float low_frequency = dot(shape.gba, vec3(0.625, 0.25, 0.125));
    float base = clamp((shape.r - (low_frequency - 1.0)) / (2.0 - low_frequency), 0.0, 1.0);
    float body = clamp((base * profile - (1.0 - cover)) / cover, 0.0, 1.0) * cover;
    if (detailed && body > 0.0) {
        vec4 detail = sample_texture_3d(root.noise, root.noise_sampler, coordinate * CLOUD_DETAIL_FREQUENCY);
        float threshold = root.erosion * CLOUD_EROSION_REACH * dot(detail.gba, vec3(0.625, 0.25, 0.125));
        body = clamp((body - threshold) / (1.0 - threshold), 0.0, 1.0);
    }
    return root.density * body;
}

#endif
