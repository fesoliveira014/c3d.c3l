#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "grade.glsl"
#include "exposure.glsl"

layout(local_size_x = EXPOSURE_HISTOGRAM_BINS) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared uint cumulative[EXPOSURE_HISTOGRAM_BINS];
shared float weighted_log2[EXPOSURE_HISTOGRAM_BINS];
shared float weights[EXPOSURE_HISTOGRAM_BINS];

// Twin of post::adapt_exposure_ev in exposure.c3.
float adapt_ev(
    ExposureAdaptRoot root,
    float current_ev,
    uint current_samples,
    float metered_log2,
    uint samples
) {
    bool snapping = root.snap != 0u || current_samples == 0u;
    float held = clamp(snapping ? 0.0 : current_ev, root.min_ev, root.max_ev);
    if (samples == 0u) return held;
    float target = clamp(log2(MID_GRAY) - metered_log2 + root.compensation_ev, root.min_ev, root.max_ev);
    if (snapping) return target;
    float time = target < current_ev ? root.brightening_time : root.darkening_time;
    if (time == 0.0) return target;
    if (!(root.elapsed > 0.0)) return held;
    return clamp(target + (current_ev - target) * exp(-root.elapsed / time), root.min_ev, root.max_ev);
}

void main() {
    ExposureAdaptRoot root = ExposureAdaptRoot(pc.root_gpu);
    uint bin = gl_LocalInvocationIndex;
    uint count = ExposureHistogramGpu(root.histogram).bins[bin];
    cumulative[bin] = count;
    barrier();
    for (uint offset = 1u; offset < EXPOSURE_HISTOGRAM_BINS; offset <<= 1u) {
        uint addend = bin >= offset ? cumulative[bin - offset] : 0u;
        barrier();
        cumulative[bin] += addend;
        barrier();
    }

    // The metered window is [low, high) of the sorted samples; each bin weighs its overlap with it.
    uint samples = cumulative[EXPOSURE_HISTOGRAM_BINS - 1u];
    float low = root.low_percentile * float(samples);
    float high = root.high_percentile * float(samples);
    float above = float(cumulative[bin]);
    float below = float(cumulative[bin] - count);
    float weight = max(min(above, high) - max(below, low), 0.0);
    weighted_log2[bin] = weight * exposure_bin_log2(bin);
    weights[bin] = weight;
    barrier();
    for (uint half_span = EXPOSURE_HISTOGRAM_BINS / 2u; half_span > 0u; half_span >>= 1u) {
        if (bin < half_span) {
            weighted_log2[bin] += weighted_log2[bin + half_span];
            weights[bin] += weights[bin + half_span];
        }
        barrier();
    }
    if (bin != 0u) return;

    float metered_log2 = samples != 0u ? weighted_log2[0] / weights[0] : 0.0;
    float current_ev = root.snap != 0u ? 0.0 : ExposureGpu(root.previous).ev;
    uint current_samples = root.snap != 0u ? 0u : ExposureGpu(root.previous).samples;
    float ev = adapt_ev(root, current_ev, current_samples, metered_log2, samples);
    // A hold keeps the last metering, so zero samples means nothing metered since the snap.
    bool held = samples == 0u && current_samples != 0u;
    ExposureGpu written = ExposureGpu(root.current);
    written.ev = ev;
    written.scale = exp2(ev);
    written.metered_log2 = held ? ExposureGpu(root.previous).metered_log2 : metered_log2;
    written.samples = held ? current_samples : samples;
}
