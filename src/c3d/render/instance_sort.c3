module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::math;

<*
 Instances a blended batch range may hold and still draw sorted.
*>
const uint MAX_SORTED_INSTANCES = 1 << 21; // cull dispatch within the 65,535-group core minimum; the default arena overflows first

struct SortStep @private {
    uint mode;
    uint stage;
    uint distance;
}

fn uint sort_capacity(uint count) @private {
    uint capacity = 1;
    while (capacity < count) capacity <<= 1;
    return capacity;
}

fn SortStep[] sort_plan(Allocator allocator, uint capacity) @private {
    uint block = shader::INSTANCE_SORT_BLOCK;
    if (capacity <= block) {
        SortStep[] single = alloc::new_array(allocator, SortStep, 1);
        single[0] = { .mode = shader::INSTANCE_SORT_BLOCKS | shader::INSTANCE_SORT_WRITE_LIST, .stage = capacity };
        return single;
    }
    usz count = 1;
    for (uint stage = block * 2; stage <= capacity; stage <<= 1) {
        for (uint distance = stage / 2; distance >= block; distance >>= 1) count++;
        count++;
    }
    SortStep[] plan = alloc::new_array(allocator, SortStep, (sz)count);
    usz written;
    plan[written++] = { .mode = shader::INSTANCE_SORT_BLOCKS, .stage = block };
    for (uint stage = block * 2; stage <= capacity; stage <<= 1) {
        for (uint distance = stage / 2; distance >= block; distance >>= 1) {
            plan[written++] = { .mode = shader::INSTANCE_SORT_GLOBAL, .stage = stage, .distance = distance };
        }
        plan[written++] = { .mode = shader::INSTANCE_SORT_MERGE, .stage = stage, .distance = block / 2 };
    }
    plan[^1].mode |= shader::INSTANCE_SORT_WRITE_LIST;
    return plan;
}

fn uint sort_groups(SortStep step, uint capacity) @private {
    if (step.mode & shader::INSTANCE_SORT_GLOBAL) return capacity / (2 * shader::INSTANCE_SORT_GROUP_SIZE);
    return math::max(capacity / shader::INSTANCE_SORT_BLOCK, 1u);
}

// Mirrored as sort_key in instance_cull.comp.glsl.
fn ulong instance_sort_key(float view_depth, uint source) @private {
    uint bits = bitcast(view_depth, uint);
    bits ^= bits >> 31 ? uint::max : 1u << 31;
    return (ulong)bits << 32 | (ulong)~source;
}

fn Vec4 view_depth_axis(Mat4 view) @private {
    return { -view.m20, -view.m21, -view.m22, -view.m23 };
}

fn usz sorted_list_bytes(uint count) @private => align_up((usz)count * uint::size, ulong::size);

fn usz? arena_place_sorted(CullArena* arena, uint count) @private {
    if (count > MAX_SORTED_INSTANCES) return c3d::CAPACITY_EXCEEDED~;
    return arena_place(arena, sorted_list_bytes(count) + (usz)sort_capacity(count) * ulong::size);
}

fn void? record_instance_sort(Renderer* renderer, CullItem[] items) @private {
    SortStep[][] plans = alloc::new_array(tmem, SortStep[], (sz)items.len);
    usz rounds;
    foreach (index, &item : items) {
        if (item.keys_address == (gpu::GpuAddress)0) continue;
        plans[index] = sort_plan(tmem, sort_capacity(item.candidate.instance_count));
        if (plans[index].len > rounds) rounds = plans[index].len;
    }
    if (!rounds) return;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @profile_pass(renderer, Pass.INSTANCE_SORT) {
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.instance_sort_pipeline)!;
        for (usz round = 0; round < rounds; round++) {
            foreach (index, &item : items) {
                if (round >= plans[index].len) continue;
                SortStep step = plans[index][round];
                uint capacity = sort_capacity(item.candidate.instance_count);
                gpu::MappedGpuSpan root_span = slot.upload.take(
                    &renderer.device,
                    InstanceSortRoot::size,
                    STREAM_ALIGNMENT,
                )!;
                *(InstanceSortRoot*)root_span.bytes.ptr = {
                    .keys     = item.keys_address,
                    .visible  = item.range.visible,
                    .args     = item.args_address,
                    .capacity = capacity,
                    .stage    = step.stage,
                    .distance = step.distance,
                    .mode     = step.mode,
                };
                gpu::cmd_dispatch(&renderer.commands, root_span.address, { sort_groups(step, capacity), 1, 1 })!;
                renderer.stats.sort_dispatches++;
            }
            gpu::Barrier sorted_step = { .before = { .compute }, .after = { .compute } };
            if (round + 1 == rounds) sorted_step.after = { .vertex_shader };
            gpu::cmd_barrier(&renderer.commands, &sorted_step)!;
        }
    }!;
}
