#ifndef C3D_NOISE_GLSL
#define C3D_NOISE_GLSL

// Jimenez 2014 interleaved gradient noise in [0, 1).
float interleaved_gradient_noise(vec2 pixel, uint frame) {
    vec2 offset = pixel + 5.588238 * float(frame);
    return fract(52.9829189 * fract(dot(offset, vec2(0.06711056, 0.00583715))));
}

#endif
