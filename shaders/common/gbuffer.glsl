#ifndef C3D_GBUFFER_GLSL
#define C3D_GBUFFER_GLSL

// Mirrored as encode_octahedral in gbuffer.c3.
vec2 encode_octahedral(vec3 normal) {
    vec3 projected = normal / (abs(normal.x) + abs(normal.y) + abs(normal.z));
    if (projected.z < 0.0) {
        vec2 sign_xy = vec2(projected.x >= 0.0 ? 1.0 : -1.0, projected.y >= 0.0 ? 1.0 : -1.0);
        return (1.0 - abs(projected.yx)) * sign_xy;
    }
    return projected.xy;
}

// Mirrored as decode_octahedral in gbuffer.c3.
vec3 decode_octahedral(vec2 encoded) {
    vec3 normal = vec3(encoded, 1.0 - abs(encoded.x) - abs(encoded.y));
    if (normal.z < 0.0) {
        vec2 sign_xy = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
        normal.xy = (1.0 - abs(normal.yx)) * sign_xy;
    }
    return normalize(normal);
}

// Mirrored as reconstruct_world_position in gbuffer.c3; uv has its origin at the top left.
vec3 reconstruct_world_position(FrameRoot frame, vec2 uv, float depth) {
    vec2 ndc = (uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 world = frame.inv_view_proj * vec4(ndc, depth, 1.0);
    return world.xyz / world.w;
}

#endif
