#version 460
#include "ray_tracing.glsl"
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define SCENE_TRACE_RAY_QUERY
#define RT_SHADOWS
#include "constants.glsl"
#include "noise.glsl"
#include "sampling.glsl"
#include "hit_shading.glsl"
#include "path_trace.glsl"

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(location = 0) rayPayloadEXT SceneHit path_hit;

struct PathRay {
    vec3 origin;
    vec3 direction;
    float width;
    float spread;
};

vec3 path_unproject(FrameRoot frame, vec2 ndc, float depth) {
    vec4 homogeneous = frame.inv_view_proj * vec4(ndc, depth, 1.0);
    return homogeneous.xyz / homogeneous.w;
}

// As sky.frag: an orthographic camera has no single eye point, so its rays start on the near plane.
PathRay primary_ray(FrameRoot frame, vec2 uv, float pixel_spread) {
    vec2 ndc = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    PathRay ray;
    if (frame.proj[3][3] != 0.0) {
        ray.origin = path_unproject(frame, ndc, 1.0);
        ray.direction = normalize(path_unproject(frame, ndc, 0.25) - path_unproject(frame, ndc, 0.75));
        ray.width = pixel_spread;
        ray.spread = 0.0;
    } else {
        ray.origin = frame.camera_position.xyz;
        ray.direction = normalize(path_unproject(frame, ndc, 0.5) - ray.origin);
        ray.width = 0.0;
        ray.spread = pixel_spread;
    }
    return ray;
}

vec3 primary_miss_radiance(PathTraceRoot root, vec3 direction) {
    if (root.sky == 0ul) return root.background_color.rgb;
    return sky_radiance(SkyRoot(root.sky), direction);
}

bool lambert_surface(TraceSurface surface) {
    return surface.material_kind != MATERIAL_KIND_STANDARD && surface.material_kind != MATERIAL_KIND_PHYSICAL;
}

vec3 surface_bsdf(TraceSurface surface, StandardSurface standard, vec3 direction) {
    if (lambert_surface(surface)) return surface.albedo / PI * max(dot(surface.normal, direction), 0.0);
    return evaluate_standard_brdf(standard, direction);
}

float surface_pdf(TraceSurface surface, StandardSurface standard, float specular_probability, vec3 direction) {
    float diffuse = cosine_hemisphere_pdf(dot(surface.normal, direction));
    if (lambert_surface(surface)) return diffuse;
    vec3 half_direction = normalize(standard.view_direction + direction);
    float normal_half = clamp(dot(surface.normal, half_direction), 0.0, 1.0);
    float specular = ggx_vndf_pdf(standard.normal_view, normal_half, standard.alpha_squared);
    return mix(diffuse, specular, specular_probability);
}

vec3 direct_light(FrameRoot frame, TraceSurface surface, StandardSurface standard) {
    vec3 radiance = vec3(0.0);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        LightSample light_sample = sample_light(light, surface.position);
        if (light_sample.radiance == vec3(0.0) || dot(surface.geometric_normal, light_sample.direction) <= 0.0) {
            continue;
        }
        vec3 bsdf = surface_bsdf(surface, standard, light_sample.direction);
        if (bsdf == vec3(0.0)) continue;
        radiance += bsdf * light_sample.radiance * hit_light_visibility(frame, light, surface);
    }
    return radiance;
}

vec3 trace_path(PathTraceRoot root, FrameRoot frame, SceneTraceRoot scene, PathRay ray, uint seed) {
    vec3 radiance = vec3(0.0);
    vec3 throughput = vec3(1.0);
    if (scene.instance_count == 0u) return primary_miss_radiance(root, ray.direction);

    for (uint bounce = 0u; bounce < root.max_bounces; bounce++) {
        path_hit.instance = PATH_TRACE_MISS;
        traceRayEXT(
            GPU_ACCELERATION_STRUCTURE(scene.tlas_index),
            gl_RayFlagsNoneEXT,
            TRACE_MASK_ALL,
            0,
            0,
            0,
            ray.origin,
            0.0,
            ray.direction,
            PATH_TRACE_FAR,
            0
        );
        if (path_hit.instance == PATH_TRACE_MISS) {
            vec3 sky = bounce == 0u
                ? primary_miss_radiance(root, ray.direction)
                : trace_miss_radiance(frame, ray.direction);
            return radiance + throughput * sky;
        }

        TraceSurface surface = surface_from_hit(scene, path_hit, ray.direction, ray.width + ray.spread * path_hit.t);
        if (surface.back_face) break;
        if (surface.material_kind == MATERIAL_KIND_BASIC) return radiance + throughput * surface.albedo;
        radiance += throughput * surface.emissive;

        vec3 outgoing = -ray.direction;
        StandardSurface standard = prepare_standard_surface(
            surface.albedo,
            surface.metallic,
            surface.roughness,
            surface.normal,
            outgoing
        );
        radiance += throughput * direct_light(frame, surface, standard);
        if (bounce + 1u == root.max_bounces) break;

        uint dimension = seed + bounce * PATH_TRACE_RANDOM_PER_BOUNCE;
        vec2 direction_random = vec2(hash_unit(dimension + 1u), hash_unit(dimension + 2u));
        float specular_probability = lambert_surface(surface)
            ? 0.0
            : standard_specular_probability(standard, surface.albedo, surface.metallic);
        mat3 basis = tangent_frame(surface.normal);
        bool specular = hash_unit(dimension) < specular_probability;
        float alpha = sqrt(standard.alpha_squared);
        vec3 direction;
        if (specular) {
            vec3 half_direction = basis * sample_ggx_vndf(direction_random, transpose(basis) * outgoing, alpha);
            direction = reflect(-outgoing, half_direction);
        } else {
            direction = basis * cosine_sample_hemisphere(direction_random);
        }
        if (dot(surface.geometric_normal, direction) <= 0.0) break;
        float pdf = surface_pdf(surface, standard, specular_probability, direction);
        vec3 bsdf = surface_bsdf(surface, standard, direction);
        if (pdf <= 0.0 || bsdf == vec3(0.0)) break;
        throughput *= bsdf / pdf;

        if (bounce + 1u >= PATH_TRACE_ROULETTE_START) {
            float survival = min(max(max(throughput.r, throughput.g), throughput.b), PATH_TRACE_SURVIVAL_MAX);
            if (hash_unit(dimension + 3u) >= survival) break;
            throughput /= survival;
        }

        ray.origin = surface.position + surface.geometric_normal * TRACE_SURFACE_OFFSET;
        ray.direction = direction;
        ray.width += ray.spread * path_hit.t;
        ray.spread += specular ? alpha : 1.0;
    }
    return radiance;
}

void main() {
    PathTraceRoot root = PathTraceRoot(pc.root_gpu);
    ivec2 texel = ivec2(gl_LaunchIDEXT.xy);
    if (root.sample_count == 0u) {
        vec3 held = load_storage_texture(root.accumulation, texel).rgb;
        store_storage_texture(root.output_texture, texel, vec4(min(held, vec3(HDR_OUTPUT_MAX)), 1.0));
        return;
    }

    FrameRoot frame = FrameRoot(root.frame);
    SceneTraceRoot scene = SceneTraceRoot(frame.trace);
    vec2 extent = vec2(root.width, root.height);
    float pixel_spread = 2.0 / (abs(frame.proj[1][1]) * extent.y);
    vec3 sum = vec3(0.0);
    for (uint index = 0u; index < root.sample_count; index++) {
        uint sample_number = root.sample_index + index;
        vec2 jitter = vec2(halton(sample_number + 1u, 2u), halton(sample_number + 1u, 3u));
        PathRay ray = primary_ray(frame, (vec2(texel) + jitter) / extent, pixel_spread);
        uint seed = pcg_hash(uint(texel.x) + pcg_hash(uint(texel.y) + pcg_hash(sample_number)));
        vec3 radiance = trace_path(root, frame, scene, ray, seed);
        // One NaN or infinity would stay in the running mean until the next reset.
        if (!any(isnan(radiance)) && !any(isinf(radiance))) sum += radiance;
    }

    vec3 mean = sum / float(root.sample_count);
    if (root.sample_index != 0u) {
        vec3 held = load_storage_texture(root.accumulation, texel).rgb;
        mean = (held * float(root.sample_index) + sum) / float(root.sample_index + root.sample_count);
    }
    store_storage_texture(root.accumulation, texel, vec4(mean, 1.0));
    store_storage_texture(root.output_texture, texel, vec4(min(mean, vec3(HDR_OUTPUT_MAX)), 1.0));
}
