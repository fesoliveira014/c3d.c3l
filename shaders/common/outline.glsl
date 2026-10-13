#ifndef C3D_OUTLINE_GLSL
#define C3D_OUTLINE_GLSL

// Vertex stages of the OUTLINE form, the inverted hull of a Toon mesh.

// A perspective view moves along the eye ray and an orthographic one along its axis: the screen position stays.
vec3 outline_push_back(FrameRoot frame, vec3 view_position, float depth_offset) {
    if (frame.proj[3][3] != 0.0) return vec3(view_position.xy, view_position.z - depth_offset);

    float depth = -view_position.z;
    return depth > 0.0 ? view_position * (1.0 + depth_offset / depth) : view_position;
}

// The NDC shift of a vertex that is the material's width in pixels; applied as shift * w.
vec2 outline_shift(FrameRoot frame, ToonMaterialGpu material, vec3 world_normal) {
    vec2 direction = (mat3(frame.view) * world_normal).xy;
    direction /= max(length(direction), 1e-4);
    return direction * 2.0 * material.outline_color_width.w / frame.camera_params.zw;
}

vec4 outline_clip(FrameRoot frame, ToonMaterialGpu material, vec4 world, vec2 shift) {
    vec3 view_position = (frame.view * world).xyz;
    vec4 clip = frame.proj * vec4(outline_push_back(frame, view_position, material.outline_depth_offset), 1.0);
    clip.xy += shift * clip.w;
    return clip;
}

#endif
