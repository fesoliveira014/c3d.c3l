#ifndef C3D_AO_ESTIMATE_GLSL
#define C3D_AO_ESTIMATE_GLSL

#include "gbuffer.glsl"
#include "depth_face.glsl"

const float AO_FALLOFF_FRACTION = 0.6; // outer share of the radius where occluders fade out; hides the cut-off ring

// Cleared texels are forward-shaded surfaces of a deferred view; written ones carry material occlusion in a.
bool ao_gbuffer_normal_written(vec4 normal_roughness) {
    return normal_roughness.a > 0.0;
}

// Weight of an occluder at a distance: full inside the inner share of the radius, zero at the radius.
float ao_falloff(float distance, float radius) {
    float falloff_range = radius * AO_FALLOFF_FRACTION;
    return clamp(1.0 - (distance - (radius - falloff_range)) / falloff_range, 0.0, 1.0);
}

vec3 ao_view_position(
    FrameRoot frame,
    ivec2 texel,
    ivec2 extent,
    float depth
) {
    vec2 uv = (vec2(texel) + 0.5) / vec2(extent);
    return (frame.view * vec4(reconstruct_world_position(frame, uv, depth), 1.0)).xyz;
}

// View-space normal from depth alone, facing the eye.
vec3 ao_reconstructed_normal(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    float depth,
    vec3 view_vector
) {
    mat3 view_rotation = mat3(frame.view);
    vec3 toward_camera = transpose(view_rotation) * view_vector;
    return view_rotation * depth_face_normal(frame, depth_texture, texel, depth, toward_camera);
}

#endif
