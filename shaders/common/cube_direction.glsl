#ifndef C3D_CUBE_DIRECTION_GLSL
#define C3D_CUBE_DIRECTION_GLSL

vec3 environment_cube_direction(uint face, vec2 uv) {
    float s = uv.x * 2.0 - 1.0;
    float t = uv.y * 2.0 - 1.0;
    vec3 direction;
    switch (face) {
        case ENVIRONMENT_FACE_POSITIVE_X: direction = vec3(1.0, -t, -s); break;
        case ENVIRONMENT_FACE_NEGATIVE_X: direction = vec3(-1.0, -t, s); break;
        case ENVIRONMENT_FACE_POSITIVE_Y: direction = vec3(s, 1.0, t); break;
        case ENVIRONMENT_FACE_NEGATIVE_Y: direction = vec3(s, -1.0, -t); break;
        case ENVIRONMENT_FACE_POSITIVE_Z: direction = vec3(s, -t, 1.0); break;
        case ENVIRONMENT_FACE_NEGATIVE_Z: direction = vec3(-s, -t, -1.0); break;
    }
    return normalize(direction);
}

#endif
