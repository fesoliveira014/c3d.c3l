module c3d::gui @feat(C3D_PROFILE_GUI & C3D_PROFILE_CPU);

import c3d::profile;
import std::core::array;

struct CpuIntervalSpan @private {
    ulong origin_ns;
    double duration_ns;
    bool available;
}

<* @require rows.len >= samples.len *>
fn usz aggregate_cpu(profile::CpuSample[] samples, ScopeAggregate[] rows) @private {
    usz row_count;
    foreach (sample_index, sample : samples) {
        usz matching_row = row_count;
        for (usz row_index = 0; row_index < row_count; row_index++) {
            profile::CpuSample representative = samples[rows[row_index].sample_index];
            if (sample.origin != representative.origin || sample.label != representative.label) continue;
            matching_row = row_index;
            break;
        }
        if (matching_row == row_count) {
            rows[row_count] = {
                .sample_index = (uint)sample_index,
                .call_count = 1,
                .inclusive_ns = (double)sample.duration_ns,
                .self_ns = (double)sample.self_ns,
                .self_complete = sample.self_complete,
            };
            row_count++;
            continue;
        }
        ScopeAggregate* row = &rows[matching_row];
        row.call_count++;
        row.inclusive_ns += (double)sample.duration_ns;
        row.self_ns += (double)sample.self_ns;
        row.self_complete = row.self_complete && sample.self_complete;
    }
    return row_count;
}

<*
 @require depths.len >= samples.len
 @require array::@all(samples, fn (sample, index) => !sample.has_parent || sample.parent_index < index)
*>
fn void cpu_scope_depths(profile::CpuSample[] samples, uint[] depths) @private {
    foreach (sample_index, sample : samples) {
        depths[sample_index] = sample.has_parent ? depths[sample.parent_index] + 1 : 0;
    }
}

fn CpuIntervalSpan cpu_interval_span(profile::CpuSample[] samples) @private {
    if (!samples.len) return {};
    ulong origin_ns = samples[0].start_ns;
    foreach (sample : samples) if (sample.start_ns < origin_ns) origin_ns = sample.start_ns;
    double duration_ns;
    foreach (sample : samples) {
        double end_ns = (double)(sample.start_ns - origin_ns) + (double)sample.duration_ns;
        if (end_ns > duration_ns) duration_ns = end_ns;
    }
    return {
        .origin_ns = origin_ns,
        .duration_ns = duration_ns,
        .available = true,
    };
}

module c3d::gui @feat(C3D_PROFILE_GUI & C3D_PROFILE_GPU);

import c3d::profile;
import std::core::array;

struct GpuIntervalSpan @private {
    double origin_ns;
    double duration_ns;
    bool available;
}

<* @require rows.len >= samples.len *>
fn usz aggregate_gpu(profile::GpuSample[] samples, ScopeAggregate[] rows) @private {
    usz row_count;
    foreach (sample_index, sample : samples) {
        usz matching_row = row_count;
        for (usz row_index = 0; row_index < row_count; row_index++) {
            profile::GpuSample representative = samples[rows[row_index].sample_index];
            if (!same_gpu_aggregate_key(sample, representative)) continue;
            matching_row = row_index;
            break;
        }
        if (matching_row == row_count) {
            rows[row_count] = {
                .sample_index = (uint)sample_index,
                .call_count = 1,
                .inclusive_ns = sample.duration_ns,
            };
            row_count++;
            continue;
        }
        ScopeAggregate* row = &rows[matching_row];
        row.call_count++;
        row.inclusive_ns += sample.duration_ns;
    }
    return row_count;
}

<*
 @require depths.len >= samples.len
 @require array::@all(samples, fn (sample, index) => !sample.has_parent || sample.parent_index < index)
*>
fn void gpu_scope_depths(profile::GpuSample[] samples, uint[] depths) @private {
    foreach (sample_index, sample : samples) {
        depths[sample_index] = sample.has_parent ? depths[sample.parent_index] + 1 : 0;
    }
}

fn GpuIntervalSpan gpu_interval_span(
    profile::GpuSample[] samples,
    uint source,
    ulong renderer_frame,
) @private {
    GpuIntervalSpan span;
    foreach (sample : samples) {
        if (sample.source != source || sample.renderer_frame != renderer_frame) continue;
        if (!span.available || sample.start_ns < span.origin_ns) span.origin_ns = sample.start_ns;
        span.available = true;
    }
    if (!span.available) return span;
    foreach (sample : samples) {
        if (sample.source != source || sample.renderer_frame != renderer_frame) continue;
        double end_ns = sample.start_ns - span.origin_ns + sample.duration_ns;
        if (end_ns > span.duration_ns) span.duration_ns = end_ns;
    }
    return span;
}

fn bool same_gpu_aggregate_key(profile::GpuSample left, profile::GpuSample right) @private {
    return left.source == right.source
        && left.renderer_frame == right.renderer_frame
        && left.label == right.label
        && left.info.origin == right.info.origin
        && left.info.kind == right.info.kind
        && left.info.has_view == right.info.has_view
        && left.info.view_index == right.info.view_index
        && left.info.view_generation == right.info.view_generation
        && left.info.pass_ordinal == right.info.pass_ordinal
        && left.info.light_index == right.info.light_index
        && left.info.light_generation == right.info.light_generation
        && left.info.light_kind == right.info.light_kind
        && left.info.layer_index == right.info.layer_index
        && left.info.shader_index == right.info.shader_index
        && left.info.shader_generation == right.info.shader_generation
        && left.info.shader_revision == right.info.shader_revision;
}
