#ifndef PARTICLE_DEPTH_GLSL
#define PARTICLE_DEPTH_GLSL

#include "descriptor_heap.glsl"
#include "particle/particle_step.glsl"

const float PARTICLE_DEPTH_NO_NEIGHBOUR = 3.0e38; // a neighbour step that loses to any real one
const float PARTICLE_DEPTH_DEGENERATE_NORMAL = 1.0e-30; // squared length of a cross product too small to normalize

// One contact of a particle's move with a surface; mirrors ParticleHit in particle.c3.
struct ParticleHit {
    bool found;
    vec3 point;
    vec3 normal;
    float fraction;
};

// Reverse-Z depth of the view's previous rendering at one texel; zero is background.
float depth_at(uint depth_texture, ivec2 texel) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(depth_texture))], texel, 0).r;
}

float depth_view_distance(StepRoot root, vec3 point) {
    return dot(root.depth_distance.xyz, point) + root.depth_distance.w;
}

// Mirrors reconstruct_world_position in gbuffer.c3; the point is in the depth rendering's render space.
vec3 depth_surface_point(StepRoot root, ivec2 texel, float depth) {
    vec2 uv = (vec2(texel) + 0.5) / vec2(float(root.depth_width), float(root.depth_height));
    vec4 point = root.depth_inv_view_proj * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    return point.xyz / point.w;
}

// One tangent of the surface along a screen axis, taken from the neighbour whose distance differs least. A background
// or missing neighbour yields to the opposite side; a texel with neither has no tangent.
vec3 depth_tangent(StepRoot root, uint depth_texture, ivec2 texel, ivec2 axis, vec3 centre) {
    ivec2 extent = ivec2(int(root.depth_width), int(root.depth_height));
    float centre_distance = depth_view_distance(root, centre);
    vec3 ahead = vec3(0.0);
    vec3 behind = vec3(0.0);
    float ahead_step = PARTICLE_DEPTH_NO_NEIGHBOUR;
    float behind_step = PARTICLE_DEPTH_NO_NEIGHBOUR;

    ivec2 ahead_texel = texel + axis;
    if (all(greaterThanEqual(ahead_texel, ivec2(0))) && all(lessThan(ahead_texel, extent))) {
        float depth = depth_at(depth_texture, ahead_texel);
        if (depth > 0.0) {
            vec3 neighbour = depth_surface_point(root, ahead_texel, depth);
            ahead = neighbour - centre;
            ahead_step = abs(depth_view_distance(root, neighbour) - centre_distance);
        }
    }

    ivec2 behind_texel = texel - axis;
    if (all(greaterThanEqual(behind_texel, ivec2(0))) && all(lessThan(behind_texel, extent))) {
        float depth = depth_at(depth_texture, behind_texel);
        if (depth > 0.0) {
            vec3 neighbour = depth_surface_point(root, behind_texel, depth);
            behind = centre - neighbour;
            behind_step = abs(depth_view_distance(root, neighbour) - centre_distance);
        }
    }
    return ahead_step <= behind_step ? ahead : behind;
}

// Unit normal of the surface at a texel, facing the camera; the camera's direction when the texel has no tangent.
vec3 depth_surface_normal(StepRoot root, uint depth_texture, ivec2 texel, vec3 centre, vec3 toward_camera) {
    vec3 across = depth_tangent(root, depth_texture, texel, ivec2(1, 0), centre);
    vec3 down = depth_tangent(root, depth_texture, texel, ivec2(0, 1), centre);
    vec3 normal = cross(down, across);
    float length_squared = dot(normal, normal);
    if (length_squared <= PARTICLE_DEPTH_DEGENERATE_NORMAL) return normalize(toward_camera);

    normal *= inversesqrt(length_squared);
    return dot(normal, toward_camera) < 0.0 ? -normal : normal;
}

// The move from..to meets the view's previous rendering when its end lies behind the surface at that texel, its start
// in front of it, and the end no deeper behind than the move's length plus the radius. Deeper points count as occluded.
ParticleHit depth_hit(StepRoot root, uint depth_texture, vec3 from, vec3 to, float radius) {
    ParticleHit none = ParticleHit(false, vec3(0.0), vec3(0.0), 0.0);
    vec3 render_to = to - root.depth_origin.xyz;
    vec4 clip = root.depth_view_proj * vec4(render_to, 1.0);
    if (clip.w <= 0.0) return none;

    vec3 ndc = clip.xyz / clip.w;
    if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0) return none;

    ivec2 extent = ivec2(int(root.depth_width), int(root.depth_height));
    vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    ivec2 texel = clamp(ivec2(floor(uv * vec2(extent))), ivec2(0), extent - 1);
    float depth = depth_at(depth_texture, texel);
    if (depth <= 0.0) return none;

    vec3 surface = depth_surface_point(root, texel, depth);
    vec3 render_from = from - root.depth_origin.xyz;
    float surface_distance = depth_view_distance(root, surface);
    float to_distance = depth_view_distance(root, render_to);
    bool end_behind = to_distance > surface_distance;
    bool start_in_front = depth_view_distance(root, render_from) <= surface_distance;
    bool shallow = to_distance - surface_distance <= length(to - from) + radius;
    if (!end_behind || !start_in_front || !shallow) return none;

    vec3 toward_camera = root.depth_camera.w != 0.0 ? -root.depth_distance.xyz : root.depth_camera.xyz - surface;
    vec3 normal = depth_surface_normal(root, depth_texture, texel, surface, toward_camera);
    float clearance_from = dot(render_from - surface, normal) - radius;
    float clearance_to = dot(render_to - surface, normal) - radius;
    float fraction = 0.0;
    if (clearance_from > 0.0 && clearance_from > clearance_to) {
        fraction = clamp(clearance_from / (clearance_from - clearance_to), 0.0, 1.0);
    }

    vec3 centre = from + (to - from) * fraction;
    float height = dot(render_from + (render_to - render_from) * fraction - surface, normal);
    return ParticleHit(true, centre - normal * height, normal, fraction);
}

#endif
