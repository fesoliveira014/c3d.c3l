module c3d::anim;

import c3d;
import c3d::maths;
import std::math;

struct PoseVelocity @private {
    double[<3>] translation;
    double[<3>] angular;
    double[<3>] scale;
}

struct InertialControl @private {
    uint generation;
    bool history_valid;
    bool active;
    double previous_dt;
    double duration;
    double elapsed;
}

struct RootInertialState @private {
    double[<3>] published_translation;
    double published_twist;
    double[<3>] translation_rate;
    double twist_rate;
    double[<3>] source_translation_rate;
    double source_twist_rate;
    double[<3>] residual_translation_rate;
    double residual_twist_rate;
    double[<3>] anchor_translation;
    Quaternion anchor_rotation;
    double[<3>] pivot;
    bool target_rate_pending;
}

struct InertialRow @private {
    Transform[] previous_pose;
    PoseVelocity[] velocity;
    PoseVelocity[] offset;
    PoseVelocity[] offset_velocity;
    float[] previous_morph;
    double[] morph_velocity;
    double[] morph_offset;
    double[] morph_offset_velocity;
    InertialControl control;
    RootInertialState root;
}

struct InertialStorage @private {
    Allocator allocator;
    InertialRow[] rows;
    usz bytes;
    usz row_bytes;
    uint nodes;
    uint morphs;
}

struct InertialStorageCursor @local {
    char* base;
    usz offset;
}

$assert InertialRow::alignment >= InertialStorage::alignment;
$assert InertialRow::alignment >= Transform::alignment;
$assert InertialRow::alignment >= PoseVelocity::alignment;
$assert InertialRow::alignment >= double::alignment;

<* @require capacity > 0 *>
fn InertialStorage*? create_inertial_storage(
    Allocator allocator,
    uint nodes,
    uint morphs,
    uint capacity,
) @private {
    usz row_bytes = inertial_row_storage_bytes(nodes, morphs)!;
    usz rows_offset = inertial_aligned_offset(InertialStorage::size, InertialRow::alignment)!;
    usz payload_offset = inertial_region_end(
        offset: rows_offset,
        count: capacity,
        element_size: InertialRow::size,
        alignment: InertialRow::alignment,
    )!;
    usz bytes = inertial_region_end(
        offset: payload_offset,
        count: capacity,
        element_size: row_bytes,
        alignment: InertialRow::alignment,
    )!;
    char* block = (char*)(allocator.acquire((sz)bytes, AllocInitType.ZERO, InertialRow::alignment)
      ?? c3d::CAPACITY_EXCEEDED~!);

    InertialStorage* storage = (InertialStorage*)block;
    *storage = {
        .allocator = allocator,
        .rows = ((InertialRow*)(block + rows_offset))[:capacity],
        .bytes = bytes,
        .row_bytes = row_bytes,
        .nodes = nodes,
        .morphs = morphs,
    };

    foreach (index, &row : storage.rows) {
        InertialStorageCursor cursor = { .base = block + payload_offset + (usz)index * row_bytes };
        row.previous_pose = carve_inertial_array(&cursor, Transform, nodes);
        row.velocity = carve_inertial_array(&cursor, PoseVelocity, nodes);
        row.offset = carve_inertial_array(&cursor, PoseVelocity, nodes);
        row.offset_velocity = carve_inertial_array(&cursor, PoseVelocity, nodes);
        row.previous_morph = carve_inertial_array(&cursor, float, morphs);
        row.morph_velocity = carve_inertial_array(&cursor, double, morphs);
        row.morph_offset = carve_inertial_array(&cursor, double, morphs);
        row.morph_offset_velocity = carve_inertial_array(&cursor, double, morphs);

        reset_inertial_row(storage, (uint)index, 0);
    }

    return storage;
}

fn void destroy_inertial_storage(InertialStorage* storage) @private {
    Allocator allocator = storage.allocator;
    allocator.release(storage, true);
}

<* @require index < storage.rows.len *>
fn void reset_inertial_row(InertialStorage* storage, uint index, uint generation) @private {
    InertialRow* row = &storage.rows[index];
    row.previous_pose[..] = maths::TRANSFORM_IDENTITY;
    row.velocity[..] = (PoseVelocity){};
    row.offset[..] = (PoseVelocity){};
    row.offset_velocity[..] = (PoseVelocity){};
    row.previous_morph[..] = 0;
    row.morph_velocity[..] = 0;
    row.morph_offset[..] = 0;
    row.morph_offset_velocity[..] = 0;

    row.control = { .generation = generation };
    row.root = { .anchor_rotation = { .l = 1 } };
}

fn usz? inertial_row_storage_bytes(uint nodes, uint morphs) @local {
    usz offset = inertial_region_end(
        offset: 0,
        count: nodes,
        element_size: Transform::size,
        alignment: Transform::alignment,
    )!;
    for (uint field = 0; field < 3; field++) {
        offset = inertial_region_end(
            offset: offset,
            count: nodes,
            element_size: PoseVelocity::size,
            alignment: PoseVelocity::alignment,
        )!;
    }
    offset = inertial_region_end(
        offset: offset,
        count: morphs,
        element_size: float::size,
        alignment: float::alignment,
    )!;
    for (uint field = 0; field < 3; field++) {
        offset = inertial_region_end(
            offset: offset,
            count: morphs,
            element_size: double::size,
            alignment: double::alignment,
        )!;
    }

    return inertial_aligned_offset(offset, InertialRow::alignment);
}

fn usz? inertial_region_end(
    usz offset,
    usz count,
    usz element_size,
    usz alignment,
) @local {
    usz aligned = inertial_aligned_offset(offset, alignment)!;
    usz limit = (usz)sz::max;
    if (count && element_size > (limit - aligned) / count) return c3d::CAPACITY_EXCEEDED~;

    return aligned + count * element_size;
}

fn usz? inertial_aligned_offset(usz offset, usz alignment) @local {
    usz padding = (alignment - offset % alignment) % alignment;
    if (offset > (usz)sz::max || padding > (usz)sz::max - offset) return c3d::CAPACITY_EXCEEDED~;

    return offset + padding;
}

macro carve_inertial_array(InertialStorageCursor* cursor, $Type, usz count) @local {
    cursor.offset = (usz)mem::aligned_offset((sz)cursor.offset, $Type::alignment);
    $Type[] result = (($Type*)(cursor.base + cursor.offset))[:count];
    cursor.offset += count * $Type::size;

    return result;
}
