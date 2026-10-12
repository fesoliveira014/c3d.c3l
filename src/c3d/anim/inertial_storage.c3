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
    uint model_revision;
    bool history_valid;
    bool active;
    bool onset_pending;
    double duration;
    double elapsed;
}

struct RootInertialState @private {
    double[<3>] published_translation;
    double[<3>] translation_rate;
    double twist_rate;
    double[<3>] latest_up;
    double[<3>] source_up;
    double[<3>] source_translation_rate;
    double source_twist_rate;
    double[<3>] residual_translation_rate;
    double residual_twist_rate;
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
    bool[] consumed_scale;
    InertialControl control;
    RootInertialState root;
}

struct InertialStorage @private {
    Allocator allocator;
    InertialRow[] rows;
}

// Regions follow in this order, so each one starts aligned without padding.
$assert InertialStorage::size % InertialRow::alignment == 0;
$assert InertialRow::size % PoseVelocity::alignment == 0;
$assert PoseVelocity::size % double::alignment == 0;
$assert double::size % Transform::alignment == 0;
$assert Transform::size % float::alignment == 0;
$assert InertialRow::alignment >= InertialStorage::alignment && InertialRow::alignment >= PoseVelocity::alignment;

<* @require capacity > 0 *>
fn InertialStorage*? create_inertial_storage(
    Allocator allocator,
    uint nodes,
    uint morphs,
    uint capacity,
) @private {
    usz bytes = inertial_storage_bytes(nodes, morphs, capacity);
    char* block = (char*)(allocator.acquire((sz)bytes, AllocInitType.ZERO, InertialRow::alignment)
      ?? c3d::CAPACITY_EXCEEDED~!);

    InertialStorage* storage = (InertialStorage*)block;
    storage.allocator = allocator;
    storage.rows = ((InertialRow*)(storage + 1))[:capacity];

    usz node_count = (usz)capacity * nodes;
    usz morph_count = (usz)capacity * morphs;
    PoseVelocity* velocities = (PoseVelocity*)(storage.rows.ptr + capacity);
    double* morph_rates = (double*)(velocities + 3 * node_count);
    Transform* poses = (Transform*)(morph_rates + 3 * morph_count);
    float* morph_values = (float*)(poses + node_count);
    bool* consumed = (bool*)(morph_values + morph_count);

    foreach (usz index, &row : storage.rows) {
        usz node = index * nodes;
        usz morph = index * morphs;
        row.velocity = velocities[node:nodes];
        row.offset = velocities[node_count + node:nodes];
        row.offset_velocity = velocities[2 * node_count + node:nodes];
        row.morph_velocity = morph_rates[morph:morphs];
        row.morph_offset = morph_rates[morph_count + morph:morphs];
        row.morph_offset_velocity = morph_rates[2 * morph_count + morph:morphs];
        row.previous_pose = poses[node:nodes];
        row.previous_morph = morph_values[morph:morphs];
        row.consumed_scale = consumed[node:nodes];

        reset_inertial_row(storage, (uint)index);
    }

    return storage;
}

fn usz inertial_storage_bytes(usz nodes, usz morphs, usz capacity) @private {
    usz node_bytes = 3 * PoseVelocity::size + Transform::size + bool::size;
    usz morph_bytes = 3 * double::size + float::size;

    return InertialStorage::size + capacity * (InertialRow::size + nodes * node_bytes + morphs * morph_bytes);
}

fn void destroy_inertial_storage(InertialStorage* storage) @private {
    Allocator allocator = storage.allocator;
    allocator.release(storage, true);
}

<* @require index < storage.rows.len *>
fn void reset_inertial_row(InertialStorage* storage, uint index) @private {
    InertialRow* row = &storage.rows[index];
    row.previous_pose[..] = maths::TRANSFORM_IDENTITY;
    row.velocity[..] = (PoseVelocity){};
    row.offset[..] = (PoseVelocity){};
    row.offset_velocity[..] = (PoseVelocity){};
    row.previous_morph[..] = 0;
    row.morph_velocity[..] = 0;
    row.morph_offset[..] = 0;
    row.morph_offset_velocity[..] = 0;
    row.consumed_scale[..] = false;

    row.control = {};
    row.root = {
        .latest_up = { 0, 1, 0 },
        .source_up = { 0, 1, 0 },
    };
}
