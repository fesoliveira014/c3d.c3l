#ifndef C3D_SHADOWS_GLSL
#define C3D_SHADOWS_GLSL

#include "buffer_reference.glsl"
#include "descriptor_heap.glsl"
#include "lights.glsl"
#include "texture_fetch.glsl"
#ifdef RT_SHADOWS
#if !defined(SCENE_TRACE_BVH) && !defined(SCENE_TRACE_RAY_QUERY)
#define SCENE_TRACE_RAY_QUERY
#endif
#ifndef RT_SHADOWS_HARD
#include "noise.glsl"
#include "sampling.glsl"
#endif
#include "scene_trace.glsl"
#endif

GPU_DECLARE_READONLY_ARRAY_REF(ShadowArray, ShadowGpu);

// Atlas UV and depth of the point; false where the layer's map or depth range does not hold it.
bool shadow_layer_coordinates(ShadowGpu shadow, vec3 sample_position, out vec3 coordinates) {
    vec4 projected = shadow.view_proj * vec4(sample_position, 1.0);
    if (projected.w <= 0.0) return false;

    vec3 ndc = projected.xyz / projected.w;
    // The atlas uses a negative-height viewport, so NDC +Y maps to texture V=0.
    vec2 uv = vec2(ndc.x + 1.0, 1.0 - ndc.y) * 0.5;
    coordinates = vec3(uv, ndc.z);
    return !(any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))
        || ndc.z < 0.0 || ndc.z > 1.0);
}

// Fraction of the 3x3 taps whose receiver depth is at or in front of the stored depth.
float filter_shadow_compare(uint texture_index, ShadowGpu shadow, vec3 coordinates) {
    float visibility = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            visibility += sample_shadow_2d(texture_index, shadow.sampler_index,
                vec3(coordinates.xy + vec2(x, y) * shadow.texel_size, coordinates.z));
        }
    }
    return visibility / 9.0;
}

float filter_shadow_visibility(ShadowGpu shadow, vec3 coordinates) {
    return filter_shadow_compare(shadow.texture_index, shadow, coordinates);
}

// Share of the light the translucent casters in front of the point let through; one where the layer holds none.
vec3 filter_shadow_tint(ShadowGpu shadow, vec3 coordinates) {
    if (shadow.colored_depth == 0u) return vec3(1.0);

    float behind = 1.0 - filter_shadow_compare(shadow.colored_depth, shadow, coordinates);
    vec3 tint = sample_texture_2d_lod(shadow.colored_transmittance, shadow.colored_sampler, coordinates.xy, 0.0).rgb;
    return mix(vec3(1.0), tint, behind);
}

vec3 filter_shadow_transmittance(ShadowGpu shadow, vec3 coordinates, bool colored) {
    float visibility = filter_shadow_visibility(shadow, coordinates);
    return colored ? visibility * filter_shadow_tint(shadow, coordinates) : vec3(visibility);
}

vec3 sample_shadow_transmittance(ShadowGpu shadow, vec3 sample_position, bool colored) {
    vec3 coordinates;
    if (!shadow_layer_coordinates(shadow, sample_position, coordinates)) return vec3(1.0);
    return filter_shadow_transmittance(shadow, coordinates, colored);
}

uint point_shadow_face(vec3 direction) {
    vec3 magnitude = abs(direction);
    if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
        return direction.x >= 0.0 ? SHADOW_FACE_POSITIVE_X : SHADOW_FACE_NEGATIVE_X;
    }
    if (magnitude.y >= magnitude.z) {
        return direction.y >= 0.0 ? SHADOW_FACE_POSITIVE_Y : SHADOW_FACE_NEGATIVE_Y;
    }
    return direction.z >= 0.0 ? SHADOW_FACE_POSITIVE_Z : SHADOW_FACE_NEGATIVE_Z;
}

#ifdef RT_SHADOWS
const float RT_SHADOW_FAR = 1.0e4; // world units; directional rays stop here

#ifdef RT_SHADOWS_HARD
// One ray toward the light's centre or the sun's direction; a source extent is ignored. The built-in fragment stages
// compile this form for views that trace no light with an extent, and it adds none of the soft path's code.
float ray_shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal) {
    vec3 origin = world_position + normal * TRACE_SURFACE_OFFSET;
    vec3 direction = -light.direction_cos_outer.xyz;
    float t_max = RT_SHADOW_FAR;
    if (light.kind != LIGHT_DIRECTIONAL) {
        vec3 to_light = light.position_range.xyz - origin;
        t_max = length(to_light);
        if (t_max == 0.0) return 1.0;
        direction = to_light / t_max;
    }

    bool occluded = trace_scene_any(
        SceneTraceRoot(frame.trace),
        origin,
        direction,
        t_max,
        TRACE_MASK_SHADOW_CASTER
    );
    return occluded ? 0.0 : 1.0;
}
#else
const uint RT_SHADOW_NOISE_FRAMES = 64u; // frames until a TAA view repeats its noise; keeps the pixel phase small

// Rays a pixel casts toward a source with extent: the view's count in a fragment stage, one in the others.
uint ray_shadow_samples(FrameRoot frame) {
#ifdef GL_FRAGMENT_SHADER
    return ((frame.flags >> FRAME_SHADOW_SAMPLES_SHIFT) & FRAME_SHADOW_SAMPLES_MASK) + 1u;
#else
    return 1u;
#endif
}

// Two noise values in [0, 1) that differ between neighbouring pixels. A fragment stage takes them from its pixel and,
// on a TAA view, from the frame too; the other stages have no pixel, so they hash the point and the frame.
vec2 ray_shadow_noise(FrameRoot frame, vec3 world_position) {
#ifdef GL_FRAGMENT_SHADER
    uint sequence = frame.jitter_time.xy == vec2(0.0) ? 0u : frame.frame_index % RT_SHADOW_NOISE_FRAMES;
    return vec2(
        interleaved_gradient_noise(gl_FragCoord.xy, sequence),
        interleaved_gradient_noise(gl_FragCoord.yx, sequence)
    );
#else
    uvec3 bits = floatBitsToUint(world_position);
    uint seed = pcg_hash(bits.x + pcg_hash(bits.y + pcg_hash(bits.z + frame.frame_index)));
    return vec2(hash_unit(seed), hash_unit(seed + 1u));
#endif
}

// Share of the rays toward the light that arrive. A light without an extent casts one ray toward its centre. With an
// extent the rays go to points of the source: the cone of half-angle source_extent around the sun's direction, or the
// disc of radius source_extent facing the surface at a punctual light. Ray i draws its radius or cone coordinate from
// the i-th of `samples` equal strata and steps its angle by the golden ratio from a per-pixel start, so the rays
// spread over the source at any count. One loop and one trace site serve both, so the soft path adds no second copy
// of the query to a stage.
float ray_shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal) {
    vec3 origin = world_position + normal * TRACE_SURFACE_OFFSET;
    bool directional = light.kind == LIGHT_DIRECTIONAL;
    vec3 to_light = directional ? -light.direction_cos_outer.xyz : light.position_range.xyz - origin;
    float to_light_length = directional ? 1.0 : length(to_light);
    if (to_light_length == 0.0) return 1.0;

    bool soft = light.source_extent > 0.0;
    uint samples = soft ? ray_shadow_samples(frame) : 1u;
    vec2 noise = soft ? ray_shadow_noise(frame, world_position) : vec2(0.0);
    vec3 centre = to_light / to_light_length;
    // From the half-angle's sine: the cosine itself rounds to one for a thin sun.
    float half_sine = sin(0.5 * light.source_extent);
    float cone_versine = 2.0 * half_sine * half_sine;
    float visible = 0.0;
    for (uint index = 0u; index < samples; index++) {
        vec3 direction = centre;
        float t_max = directional ? RT_SHADOW_FAR : to_light_length;
        if (soft) {
            mat3 basis = tangent_frame(centre);
            float radial = (float(index) + noise.x) / float(samples);
            float angle = 2.0 * PI * fract(noise.y + float(index) * GOLDEN_RATIO_CONJUGATE);
            if (directional) {
                float versine = radial * cone_versine;
                float sine = sqrt(versine * (2.0 - versine));
                direction = basis * vec3(sine * cos(angle), sine * sin(angle), 1.0 - versine);
            } else {
                vec2 offset = light.source_extent * sqrt(radial) * vec2(cos(angle), sin(angle));
                vec3 to_point = to_light + basis * vec3(offset, 0.0);
                t_max = length(to_point);
                direction = to_point / t_max;
            }
        }

        bool occluded = trace_scene_any(
            SceneTraceRoot(frame.trace),
            origin,
            direction,
            t_max,
            TRACE_MASK_SHADOW_CASTER
        );
        visible += occluded ? 0.0 : 1.0;
    }

    return visible / float(samples);
}
#endif
#endif

// colored: lights with translucent maps also multiply in the tint of their translucent casters.
vec3 atlas_shadow(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal, float view_depth, bool colored) {
    if (light.shadow_count == 0u) return vec3(1.0);

    if (light.kind == LIGHT_DIRECTIONAL) {
        // A set fitted to another camera can miss a receiver in its selected cascade; coarser ones may hold it.
        bool fell_through = false;
        for (uint cascade = 0u; cascade < light.shadow_count; cascade++) {
            ShadowGpu shadow = ShadowArray(frame.shadows).values[light.shadow_first + cascade];
            if (view_depth > shadow.split_depth) continue;
            vec3 coordinates;
            if (!shadow_layer_coordinates(shadow, world_position + normal * shadow.normal_bias, coordinates)) {
                fell_through = true;
                continue;
            }
            vec3 visibility = filter_shadow_transmittance(shadow, coordinates, colored);
            if (fell_through || view_depth <= shadow.blend_depth) return visibility;
            ShadowGpu next = ShadowArray(frame.shadows).values[light.shadow_first + cascade + 1u];
            vec3 next_coordinates;
            if (!shadow_layer_coordinates(next, world_position + normal * next.normal_bias, next_coordinates)) {
                return visibility;
            }
            vec3 next_visibility = filter_shadow_transmittance(next, next_coordinates, colored);
            // Positive here: blend_depth < view_depth <= split_depth.
            float weight = (view_depth - shadow.blend_depth) / (shadow.split_depth - shadow.blend_depth);
            return mix(visibility, next_visibility, weight);
        }
        return vec3(1.0);
    }

    ShadowGpu first = ShadowArray(frame.shadows).values[light.shadow_first];
    vec3 receiver_direction = world_position - light.position_range.xyz;
    if (length(receiver_direction) > first.max_distance) return vec3(1.0);

    vec3 sample_position = world_position + normal * first.normal_bias;
    if (light.kind == LIGHT_SPOT) return sample_shadow_transmittance(first, sample_position, colored);

    if (light.kind == LIGHT_POINT) {
        vec3 sample_direction = sample_position - light.position_range.xyz;
        if (dot(sample_direction, sample_direction) == 0.0) return vec3(1.0);
        uint face = point_shadow_face(sample_direction);
        ShadowGpu shadow = ShadowArray(frame.shadows).values[light.shadow_first + face];
        return sample_shadow_transmittance(shadow, sample_position, colored);
    }
    return vec3(1.0);
}

// The layer's transmittance toward the sun, which the map holds on the layer's bottom plane; one for any other light.
// A point inside the layer keeps the share of the layer above it: the map's value raised to that share.
float cloud_shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position) {
    if ((light.flags & LIGHT_CLOUD_SHADOW) == 0u || frame.cloud_shadow == 0ul) return 1.0;

    CloudShadowRoot shadow = CloudShadowRoot(frame.cloud_shadow);
    float altitude = world_position.y + frame.origin.y;
    float layer_above = clamp((shadow.top - altitude) / (shadow.top - shadow.bottom), 0.0, 1.0);
    if (layer_above == 0.0) return 1.0;

    vec3 to_sun = shadow.to_sun.xyz;
    vec2 on_plane = world_position.xz + to_sun.xz * ((shadow.bottom - altitude) / max(to_sun.y, CLOUD_SUN_FLOOR));
    vec2 uv = (on_plane - shadow.map.xy) / CLOUD_SHADOW_EXTENT;
    vec2 from_centre = abs(uv * 2.0 - 1.0);
    float inside = clamp((1.0 - max(from_centre.x, from_centre.y)) / CLOUD_SHADOW_EDGE_BAND, 0.0, 1.0);
    if (inside == 0.0) return 1.0;

    float transmittance = sample_texture_2d_lod(shadow.texture, shadow.sampler_index, uv, 0.0).r;
    return mix(1.0, pow(transmittance, layer_above), inside);
}

float shadow_visibility(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal, float view_depth) {
    float clouds = cloud_shadow_visibility(frame, light, world_position);
#ifdef RT_SHADOWS
    if ((light.flags & LIGHT_RT_SHADOW) != 0u && (frame.flags & FRAME_TRACE_PRESENT) != 0u) {
        return clouds * ray_shadow_visibility(frame, light, world_position, normal);
    }
#endif
    return clouds * atlas_shadow(frame, light, world_position, normal, view_depth, false).x;
}

// Share of the light reaching the point per channel. Traced lights and the float form above ignore the tint.
vec3 shadow_transmittance(FrameRoot frame, LightGpu light, vec3 world_position, vec3 normal, float view_depth) {
    float clouds = cloud_shadow_visibility(frame, light, world_position);
#ifdef RT_SHADOWS
    if ((light.flags & LIGHT_RT_SHADOW) != 0u && (frame.flags & FRAME_TRACE_PRESENT) != 0u) {
        return vec3(clouds * ray_shadow_visibility(frame, light, world_position, normal));
    }
#endif
    return clouds * atlas_shadow(frame, light, world_position, normal, view_depth, true);
}

#endif
