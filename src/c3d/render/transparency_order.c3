module c3d::render;

import c3d;
import c3d::maths;
import c3d::scene;
import gpu;
import std::sort;

const usz TRANSPARENCY_ORDER_COMMAND_STRIDE @private = 32; // One aligned indexed or non-indexed command per source.

enum TransparencySourceKind @private {
    MESH,
    INSTANCED_MESH,
    BILLBOARD,
    LOD_GROUP,
}

struct TransparencyOrderKey @private {
    Entity node;
    TransparencySourceKind kind;
    uint part;
    uint logical_instance;
    uint source;
    uint input;
}

struct TransparencyOrderPlan @private {
    DrawItem[] items;
    TransparencyOrderRoot[] roots;
}

struct TransparencyCommandRange @private {
    gpu::MappedGpuSpan commands;
    uint first;
    uint count;
}

<*
 @require renderer.frame_open, inputs.len <= uint::max
*>
fn TransparencyOrderPlan? prepare_transparency_order(Renderer* renderer, DrawItem[] inputs) @private {
    usz count;
    usz root_count;
    foreach (&item : inputs) {
        count += candidate_instanced(item.candidate) ? item.candidate.instance_count : 1;
        if (item.range.culled) root_count++;
    }

    TransparencyOrderPlan plan = {
        .items = alloc::new_array(tmem, DrawItem, (sz)count),
        .roots = alloc::new_array(tmem, TransparencyOrderRoot, (sz)root_count),
    };
    if (!count) return plan;

    TransparencyOrderKey[] keys = alloc::new_array(tmem, TransparencyOrderKey, (sz)count);
    TransparencyCommandRange[] ranges = alloc::new_array(tmem, TransparencyCommandRange, (sz)inputs.len);
    usz written;
    usz root_written;
    foreach (uint input_index, &item : inputs) {
        MeshCandidate* candidate = item.candidate;
        TransparencyOrderKey key = {
            .node = candidate.node.id,
            .kind = transparency_source_kind(candidate),
            .part = candidate.lod ? candidate.lod_part : candidate.crowd_part,
            .input = input_index,
        };
        if (!candidate_instanced(candidate)) {
            keys[written++] = key;
            continue;
        }

        TransparencyCommandRange commands = prepare_transparency_commands(renderer, item)!;
        ranges[input_index] = commands;
        if (item.range.culled) {
            plan.roots[root_written++] = {
                .source_args = gpu::get_span_address(&renderer.device, item.range.args)!,
                .source_indices = item.range.visible,
                .output_args = commands.commands.address,
                .first = commands.first,
                .count = commands.count,
                .stride = (uint)TRANSPARENCY_ORDER_COMMAND_STRIDE,
            };
        }

        if (candidate.lod) {
            LodGroupState* state = candidate.lod.state;
            for (uint source = 0; source < state.count; source++) {
                bool mirrored = candidate.animated_lod
                  ? candidate.lod.part_mirrored[candidate.lod_part][source]
                  : scene::transform_mirrored(state.transforms[source]);
                if (mirrored != candidate.mirrored) continue;

                key.logical_instance = source;
                key.source = source;
                keys[written++] = key;
            }
            continue;
        }

        if (candidate.billboards) {
            for (uint source = candidate.instance_first;
              source < candidate.instance_first + candidate.instance_count;
              source++) {
                key.logical_instance = source;
                key.source = source;
                keys[written++] = key;
            }
            continue;
        }

        uint[] packed = alloc::new_array(tmem, uint, candidate.batch.count);
        crowd_packed_order(
            packed: packed,
            placements: candidate.batch.transforms[:candidate.batch.count],
            crowd: candidate.crowd,
            part: candidate.crowd_part,
        );
        uint end = candidate.instance_first + candidate.instance_count;
        foreach (uint logical, source : packed) {
            if (source < candidate.instance_first || source >= end) continue;

            key.logical_instance = logical;
            key.source = source;
            keys[written++] = key;
        }
    }

    sort_transparency_order(
        keys: keys,
        written: written,
        root_count: plan.roots.len,
        root_written: root_written,
    );

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan sources = frame.upload.take(&renderer.device, count * uint::size, STREAM_ALIGNMENT)!;
    uint* source_values = (uint*)sources.bytes.ptr;
    foreach (index, key : keys) {
        DrawItem* item = &plan.items[index];
        *item = inputs[key.input];
        if (!candidate_instanced(item.candidate)) continue;

        source_values[index] = key.source;
        gpu::GpuAddress source_address = (gpu::GpuAddress)((ulong)sources.address + (ulong)index * uint::size);
        TransparencyCommandRange commands = ranges[key.input];
        usz command_offset = (usz)(key.source - commands.first) * TRANSPARENCY_ORDER_COMMAND_STRIDE;
        gpu::GpuSpan arguments = commands.commands.span.checked_subspan(
            command_offset,
            indirect_args_bytes(&item.geometry.layout),
        )!;
        item.range = {
            .args = arguments,
            .count = 1,
            .visible = source_address,
            .culled = item.range.culled,
            .indexed = true,
        };

        DrawRoot draw = *item.draw;
        draw.skin = item.skin;
        draw.morph = item.morph;
        draw.instance_data = item.instance_data;
        draw.instance_indices = source_address;
        gpu::MappedGpuSpan root = frame.upload.take(&renderer.device, DrawRoot::size, STREAM_ALIGNMENT)!;
        item.draw = (DrawRoot*)root.bytes.ptr;
        *item.draw = draw;
        item.root = root.address;
    }

    return plan;
}

<*
 @require candidate_instanced(item.candidate), item.candidate.instance_count > 0
*>
fn TransparencyCommandRange? prepare_transparency_commands(Renderer* renderer, DrawItem* item) @private {
    MeshCandidate* candidate = item.candidate;
    uint first = candidate.lod ? 0 : candidate.instance_first;
    uint count = candidate.lod ? candidate.lod.state.count : candidate.instance_count;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan commands = frame.upload.take(
        device: &renderer.device,
        size: (usz)count * TRANSPARENCY_ORDER_COMMAND_STRIDE,
        alignment: STREAM_ALIGNMENT,
    )!;

    for (uint source = 0; source < count; source++) {
        usz offset = (usz)source * TRANSPARENCY_ORDER_COMMAND_STRIDE;
        char[] command = commands.bytes[offset:TRANSPARENCY_ORDER_COMMAND_STRIDE];
        command[..] = 0;
        write_indirect_args(command, &item.geometry.layout, item.range.culled ? 0 : 1);
    }

    return { .commands = commands, .first = first, .count = count };
}

<*
 @require written == keys.len, root_written == root_count
*>
fn void sort_transparency_order(
    TransparencyOrderKey[] keys,
    usz written,
    usz root_count,
    usz root_written,
) @private {
    sort::quicksort(keys, &compare_transparency_order);
}

fn TransparencySourceKind transparency_source_kind(MeshCandidate* candidate) @private {
    if (candidate.lod) return TransparencySourceKind.LOD_GROUP;
    if (candidate.billboards) return TransparencySourceKind.BILLBOARD;
    if (candidate.batch) return TransparencySourceKind.INSTANCED_MESH;

    return TransparencySourceKind.MESH;
}

fn int compare_transparency_order(TransparencyOrderKey first, TransparencyOrderKey second) @private {
    if (first.node.index != second.node.index) return first.node.index < second.node.index ? -1 : 1;
    if (first.node.generation != second.node.generation) {
        return first.node.generation < second.node.generation ? -1 : 1;
    }

    if (first.kind != second.kind) return first.kind.ordinal < second.kind.ordinal ? -1 : 1;
    if (first.part != second.part) return first.part < second.part ? -1 : 1;
    if (first.logical_instance != second.logical_instance) {
        return first.logical_instance < second.logical_instance ? -1 : 1;
    }

    return 0;
}
