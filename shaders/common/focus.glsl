#ifndef C3D_FOCUS_GLSL
#define C3D_FOCUS_GLSL

// Metered view distances in meters on a log2 axis; texels beyond the range are not targets.
const float FOCUS_LOG2_MIN = -6.0;
const float FOCUS_LOG2_MAX = 14.0;
// Nearest adapted focus in focal lengths: unit magnification, where the aperture scale stays finite.
const float FOCUS_MIN_FOCAL_RATIO = 2.0;
const float FOCUS_BINS_PER_STOP = float(FOCUS_HISTOGRAM_BINS) / (FOCUS_LOG2_MAX - FOCUS_LOG2_MIN);

// A bin's samples keep their position inside it in this many steps, so a flat target meters exactly.
const float FOCUS_FRACTION_STEPS = 64.0; // a 32-bit sum holds 67 million samples at this step count

// Position of a view distance in meters along the bins; nearer distances sit at the first bin's start.
float focus_position(float distance) {
    return max((log2(distance) - FOCUS_LOG2_MIN) * FOCUS_BINS_PER_STOP, 0.0);
}

#endif
