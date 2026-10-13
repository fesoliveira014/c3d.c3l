#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "focus.glsl"

layout(local_size_x = FOCUS_HISTOGRAM_BINS) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared uint cumulative[FOCUS_HISTOGRAM_BINS];
shared float median_log2;

void main() {
    FocusAdaptRoot root = FocusAdaptRoot(pc.root_gpu);
    uint bin = gl_LocalInvocationIndex;
    uint count = FocusHistogramGpu(root.histogram).bins[bin];
    cumulative[bin] = count;
    barrier();
    for (uint offset = 1u; offset < FOCUS_HISTOGRAM_BINS; offset <<= 1u) {
        uint addend = bin >= offset ? cumulative[bin - offset] : 0u;
        barrier();
        cumulative[bin] += addend;
        barrier();
    }

    // The median is the sample of rank samples / 2, placed at the mean position of the samples in its bin.
    uint samples = cumulative[FOCUS_HISTOGRAM_BINS - 1u];
    float rank = 0.5 * float(samples);
    float above = float(cumulative[bin]);
    float below = float(cumulative[bin] - count);
    if (count != 0u && below <= rank && rank < above) {
        float mean_steps = float(FocusHistogramGpu(root.histogram).fractions[bin]) / float(count);
        float position = float(bin) + (mean_steps + 0.5) / FOCUS_FRACTION_STEPS;
        median_log2 = FOCUS_LOG2_MIN + position / FOCUS_BINS_PER_STOP;
    }

    barrier();
    if (bin != 0u) return;

    FocusGpu previous = FocusGpu(root.previous);
    bool adapting = root.snap == 0u && previous.samples != 0u;
    float target = max(exp2(median_log2), root.focal_length * FOCUS_MIN_FOCAL_RATIO);
    float distance = adapting ? previous.distance : root.fallback_distance;
    if (samples != 0u) {
        if (!adapting || root.focus_time == 0.0) {
            distance = target;
        } else if (root.elapsed > 0.0) {
            float remaining = exp(-root.elapsed / root.focus_time);
            distance = exp2(log2(target) + (log2(previous.distance) - log2(target)) * remaining);
        }
    }

    // A hold keeps the last metering, so zero samples means nothing metered since the snap.
    FocusGpu written = FocusGpu(root.current);
    written.distance = distance;
    written.aperture_scale = root.lens_scale / (distance - root.focal_length);
    written.samples = samples != 0u || !adapting ? samples : previous.samples;
}
