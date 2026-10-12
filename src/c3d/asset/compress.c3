module c3d::asset;

import c3d;
import c3d::anim;
import std::math;

const double CUBIC_TANGENT_WEIGHT @local = 4.0 / 27; // largest |h10| and |h11| of the Hermite basis

<*
 Largest deviation per animated property: metres, radians, scale ratio and weight units.
*>
struct ClipTolerance {
    float translation;
    float rotation;
    float scale;
    float weight;
}

<*
 Measured result of compressing a clip.
*>
struct CompressionReport {
    ClipTolerance error;
    usz           bytes_before;
    usz           bytes_after;
}

struct Measurement @local {
    Track*  source;
    Track*  candidate;
    float[] reference;
    float[] value;
    uint    source_cursor;
    uint    candidate_cursor;
}

fn float* path_value(ClipTolerance* tolerance, TargetPath path) @local {
    switch (path) {
        case TRANSLATION: return &tolerance.translation;
        case ROTATION: return &tolerance.rotation;
        case SCALE: return &tolerance.scale;
        case MORPH_WEIGHTS: return &tolerance.weight;
    }
}

<*
 Quantize the key data of a clip and measure the error.
 Error is bounded per key, so a looping root-motion clip's displacement per cycle can drift by twice the tolerance.
 Cubic rotation and empty tracks stay raw; the clip is unchanged on every fault.
 @return? c3d::INVALID_ARGUMENT, c3d::TOLERANCE_EXCEEDED, c3d::CAPACITY_EXCEEDED
 @require self.clips.is_live(clip)
 @require !self.clip(clip).data.is_compressed()
*>
fn CompressionReport? AssetStore.compress_clip(&self, ClipId clip, ClipTolerance tolerance) {
    ClipAsset* record = self.clip(clip);
    AnimationClip* data = &record.data;
    usz bytes = key_bytes(data);
    CompressionReport report = { .bytes_before = bytes, .bytes_after = bytes };
    @pool() {
        Track[] staged = alloc::new_array(tmem, Track, data.tracks.len);
        uint[] owners = alloc::new_array(tmem, uint, data.tracks.len);
        usz words;
        foreach (index, &source : data.tracks) {
            staged[index] = *source;
            if (!is_packable(source)) continue;

            validate_track(source)!;
            Track* candidate = &staged[index];
            *candidate = pack_track(source);
            owners[index] = shared_times(staged, owners, (uint)index);
            words += range_count(candidate) + (code_count(candidate) + 1) / 2;
            if (owners[index] == index) {
                words += candidate.times.len;
            } else {
                candidate.times = staged[owners[index]].times;
            }
        }
        if (!words) return report;

        foreach (index, &candidate : staged) {
            if (!candidate.is_packed()) continue;
            double error = measure_error(&data.tracks[index], candidate);
            if (candidate.interpolation == Interpolation.CUBIC_SPLINE) error = math::max(error, cubic_error(candidate));
            float* worst = path_value(&report.error, candidate.path);
            *worst = math::max(*worst, (float)error);
        }

        foreach (path : TargetPath::values) {
            if (!(*path_value(&report.error, path) <= *path_value(&tolerance, path))) return c3d::TOLERANCE_EXCEEDED~;
        }

        float[] block = alloc::new_array_try(self.allocator, float, (sz)words) ?? c3d::CAPACITY_EXCEEDED~!;
        usz used;
        foreach (index, &candidate : staged) {
            if (!candidate.is_packed()) continue;
            bool owns_times = owners[index] == index;
            place_track(
                block:      block,
                used:       &used,
                track:      candidate,
                owns_times: owns_times,
            );
            if (!owns_times) candidate.times = staged[owners[index]].times;
            free_track_keys(self.allocator, &data.tracks[index]);
            data.tracks[index] = *candidate;
        }
        data.packed_keys = block;
        record.header.revision++;
    };
    report.bytes_after = key_bytes(data);
    return report;
}

fn bool is_packable(Track* track) @local {
    bool cubic_rotation = track.path == TargetPath.ROTATION && track.interpolation == Interpolation.CUBIC_SPLINE;
    return track.key_count() > 0 && !cubic_rotation;
}

fn usz key_bytes(AnimationClip* clip) @local {
    usz floats = clip.packed_keys.len;
    foreach (&track : clip.tracks) {
        if (!track.is_packed()) floats += track.times.len + track.values.len;
    }
    return floats * float::size;
}

fn void? validate_track(Track* track) @local {
    usz keys = track.times.len;
    usz slots = track.slot_count();
    usz per_key = track.values.len / keys;
    usz fixed_stride = track.path == TargetPath.ROTATION ? 4 : 3;
    bool fixed_stride_mismatch = track.path != TargetPath.MORPH_WEIGHTS && per_key != slots * fixed_stride;
    bool stride_overflow = per_key / slots > ushort::max;
    if (!per_key || per_key * keys != track.values.len || per_key % slots || fixed_stride_mismatch || stride_overflow) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (index, time : track.times) {
        if (!math::is_finite(time) || (index && time <= track.times[index - 1])) return c3d::INVALID_ARGUMENT~;
    }
    foreach (value : track.values) {
        if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
    if (track.path != TargetPath.ROTATION) return;

    for (usz key = 0; key < keys; key++) {
        float[] rotation = track.values[key * 4:4];
        if (!(rotation[0] != 0 || rotation[1] != 0 || rotation[2] != 0 || rotation[3] != 0)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn Track pack_track(Track* source) @local {
    uint keys = source.key_count();
    uint stride = source.stride();
    uint slots = source.slot_count();
    Track result = {
        .target = source.target,
        .path = source.path,
        .interpolation = source.interpolation,
        .encoding = TrackEncoding.PACKED,
        .packed_stride = (ushort)stride,
        .times = source.times,
    };
    ushort[] codes = alloc::new_array(tmem, ushort, (sz)code_count(&result));
    float[] ranges = alloc::new_array(tmem, float, (sz)range_count(&result));
    result.packed.codes = codes.ptr;
    result.packed.ranges = ranges.ptr;
    float[] value = alloc::new_array(tmem, float, stride);

    if (source.path == TargetPath.ROTATION) {
        for (uint key = 0; key < keys; key++) {
            source.read_key(key, 0, value);
            anim::pack_rotation(value, codes[(usz)key * anim::ROTATION_WORDS:anim::ROTATION_WORDS]);
        }
        return result;
    }

    for (usz range = 0; range < ranges.len; range += 2) {
        ranges[range] = float::max;
        ranges[range + 1] = -float::max;
    }

    for (uint key = 0; key < keys; key++) {
        for (uint slot = 0; slot < slots; slot++) {
            source.read_key(key, slot, value);
            foreach (uint component, entry : value) {
                float* range = &ranges[((usz)slot * stride + component) * 2];
                range[0] = math::min(range[0], entry);
                range[1] = math::max(range[1], entry);
            }
        }
    }

    for (usz range = 0; range < ranges.len; range += 2) {
        ranges[range + 1] = (ranges[range + 1] - ranges[range]) / anim::QUANTIZED_CODE_MAX;
    }

    for (uint key = 0; key < keys; key++) {
        for (uint slot = 0; slot < slots; slot++) {
            source.read_key(key, slot, value);
            foreach (uint component, entry : value) {
                float* range = &ranges[((usz)slot * stride + component) * 2];
                usz code = ((usz)key * slots + slot) * stride + component;
                float scaled = range[1] > 0 ? math::round((entry - range[0]) / range[1]) : 0;
                codes[code] = (ushort)math::min(scaled, anim::QUANTIZED_CODE_MAX);
            }
        }
    }
    return result;
}

fn double error_at(Measurement* probe, float time) @local {
    anim::sample_track(
        track:  probe.source,
        time:   time,
        cursor: &probe.source_cursor,
        out:    probe.reference,
    );
    anim::sample_track(
        track:  probe.candidate,
        time:   time,
        cursor: &probe.candidate_cursor,
        out:    probe.value,
    );
    return value_error(probe.source.path, probe.reference, probe.value);
}

fn float midpoint(Track* track, uint key) @local {
    return (track.key_time(key) + track.key_time(key + 1)) / 2;
}

fn double measure_error(Track* source, Track* candidate) @local {
    uint keys = source.key_count();
    uint stride = source.stride();
    float[] scratch = alloc::new_array(tmem, float, (sz)(2 * stride));
    Measurement probe = {
        .source = source,
        .candidate = candidate,
        .reference = scratch[:stride],
        .value = scratch[stride:stride],
    };
    bool midpoints = source.path == TargetPath.ROTATION || source.interpolation == Interpolation.CUBIC_SPLINE;
    double worst;
    for (uint key = 0; key < keys; key++) {
        worst = math::max(worst, error_at(&probe, source.key_time(key)));
        if (midpoints && key + 1 < keys) worst = math::max(worst, error_at(&probe, midpoint(source, key)));
    }
    return worst;
}

fn double cubic_error(Track* track) @local {
    uint stride = track.stride();
    double longest;
    for (uint key = 1; key < track.key_count(); key++) {
        longest = math::max(longest, (double)track.key_time(key) - (double)track.key_time(key - 1));
    }

    double[anim::CUBIC_SLOTS_PER_KEY] widest_step;
    for (uint slot = 0; slot < anim::CUBIC_SLOTS_PER_KEY; slot++) {
        for (uint component = 0; component < stride; component++) {
            double step = track.packed.ranges[(slot * stride + component) * 2 + 1];
            widest_step[slot] = math::max(widest_step[slot], step);
        }
    }
    double tangent_steps = widest_step[anim::CUBIC_SLOT_IN_TANGENT] + widest_step[anim::CUBIC_SLOT_OUT_TANGENT];
    double bound = widest_step[anim::CUBIC_SLOT_VALUE] + CUBIC_TANGENT_WEIGHT * longest * tangent_steps;
    return track.path == TargetPath.TRANSLATION ? bound * math::sqrt((double)stride) : bound;
}

fn double value_error(TargetPath path, float[] reference, float[] value) @local {
    if (path == TargetPath.ROTATION) return rotation_angle(reference, value);
    double sum;
    double largest;
    foreach (index, component : reference) {
        double difference = math::abs((double)component - (double)value[index]);
        sum += difference * difference;
        largest = math::max(largest, difference);
    }
    return path == TargetPath.TRANSLATION ? math::sqrt(sum) : largest;
}

fn double rotation_angle(float[] first, float[] second) @local {
    double[<3>] left = { first[0], first[1], first[2] };
    double[<3>] right = { second[0], second[1], second[2] };
    double[<3>] cross = left.yzx * right.zxy - left.zxy * right.yzx;
    double[<3>] axis = (double)second[3] * left - (double)first[3] * right - cross;
    double scalar = left.dot(right) + (double)first[3] * second[3];
    return 2 * math::atan2(axis.length(), math::abs(scalar));
}

fn uint shared_times(Track[] staged, uint[] owners, uint index) @local {
    for (uint owner = 0; owner < index; owner++) {
        bool same = owners[owner] == owner && staged[owner].is_packed();
        if (same && mem::equals(staged[owner].times, staged[index].times)) return owner;
    }
    return index;
}

fn usz range_count(Track* track) @local {
    return track.path == TargetPath.ROTATION ? 0 : 2 * (usz)track.slot_count() * track.stride();
}

fn usz code_count(Track* track) @local {
    usz per_key = track.path == TargetPath.ROTATION ? anim::ROTATION_WORDS : (usz)track.slot_count() * track.stride();
    return track.key_count() * per_key;
}

fn void place_track(float[] block, usz* used, Track* track, bool owns_times) @local {
    usz ranges = range_count(track);
    usz codes = code_count(track);
    float[] range_slot = block[*used:ranges];
    range_slot[..] = track.packed.ranges[:ranges];
    track.packed.ranges = range_slot.ptr;
    *used += ranges;

    float[] code_slot = block[*used:(codes + 1) / 2];
    ((ushort*)code_slot.ptr)[:codes] = track.packed.codes[:codes];
    track.packed.codes = (ushort*)code_slot.ptr;
    *used += code_slot.len;

    if (!owns_times) return;
    float[] time_slot = block[*used:track.times.len];
    time_slot[..] = track.times[..];
    track.times = time_slot;
    *used += time_slot.len;
}
