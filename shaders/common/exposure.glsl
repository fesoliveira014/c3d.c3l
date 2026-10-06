#ifndef C3D_EXPOSURE_GLSL
#define C3D_EXPOSURE_GLSL

// Twins of post::exposure_metered, post::exposure_bin and post::exposure_bin_log2 in exposure.c3.
const float EXPOSURE_BINS_PER_STOP = float(EXPOSURE_HISTOGRAM_BINS) / (EXPOSURE_LOG2_MAX - EXPOSURE_LOG2_MIN); // mirrored as EXPOSURE_BINS_PER_STOP in exposure.c3

bool exposure_metered(float luminance) {
    return !isnan(luminance) && !isinf(luminance) && luminance >= EXPOSURE_LUMINANCE_EPSILON;
}

uint exposure_bin(float luminance) {
    float position = floor((log2(luminance) - EXPOSURE_LOG2_MIN) * EXPOSURE_BINS_PER_STOP);
    return uint(clamp(position, 0.0, float(EXPOSURE_HISTOGRAM_BINS - 1u)));
}

float exposure_bin_log2(uint bin) {
    return EXPOSURE_LOG2_MIN + (float(bin) + 0.5) / EXPOSURE_BINS_PER_STOP;
}

#endif
