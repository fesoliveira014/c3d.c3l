module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::time;
import std::time::clock;

fn ClothState staged_cloth(ClothState* state) @local {
    ClothState staged = *state;
    staged.positions = state.staged_positions;
    staged.velocities = state.staged_velocities;
    staged.predicted = state.staged_predicted;
    staged.accelerations = state.staged_accelerations;
    staged.published = state.staged_published;
    staged.pin_anchors = state.staged_pin_anchors;
    staged.pin_targets = state.staged_pin_targets;
    staged.bodies = state.staged_bodies;
    staged.shape_storage = state.staged_shapes;
    staged.shape_starts = state.staged_shape_starts;
    staged.shape_ends = state.staged_shape_ends;
    staged.contact_result = {};
    staged.positions[..] = state.positions[..];
    staged.velocities[..] = state.velocities[..];
    staged.predicted[..] = state.predicted[..];
    staged.accelerations[..] = state.accelerations[..];
    staged.published[..] = state.published[..];
    staged.pin_anchors[..] = state.pin_anchors[..];
    staged.pin_targets[..] = state.pin_targets[..];
    staged.bodies[..] = state.bodies[..];
    staged.shape_starts[..] = state.shape_starts[..];
    staged.shape_ends[..] = state.shape_ends[..];
    return staged;
}

fn void commit_cloth(ClothState* state, ClothState* staged) @local {
    state.positions[..] = staged.positions[..];
    state.velocities[..] = staged.velocities[..];
    state.predicted[..] = staged.predicted[..];
    state.accelerations[..] = staged.accelerations[..];
    state.published[..] = staged.publication_roundtrip[..];
    state.pin_anchors[..] = staged.pin_anchors[..];
    state.pin_targets[..] = staged.pin_targets[..];
    state.bodies[..] = staged.bodies[..];
    state.shapes = state.shape_storage[:staged.shapes.len];
    state.shapes[..] = staged.shapes[..];
    state.shape_starts[..] = staged.shape_starts[..];
    state.shape_ends[..] = staged.shape_ends[..];
}

fn bool? stage_local_publication(ClothState* state, Mat4 world) @local {
    foreach (value : world.m) if (!math::is_finite(value)) return CONTACT_PRECISION_EXCEEDED~;
    ContactVector column_x = { world.m00, world.m10, world.m20 };
    ContactVector column_y = { world.m01, world.m11, world.m21 };
    ContactVector column_z = { world.m02, world.m12, world.m22 };
    ContactVector row_x = column_y.cross(column_z);
    ContactVector row_y = column_z.cross(column_x);
    ContactVector row_z = column_x.cross(column_y);
    double determinant = column_x.dot(row_x);
    if (determinant == 0 || !math::is_finite(determinant)) return CONTACT_PRECISION_EXCEEDED~;
    row_x /= determinant;
    row_y /= determinant;
    row_z /= determinant;
    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(row_x[axis]) || !math::is_finite(row_y[axis]) || !math::is_finite(row_z[axis])) return CONTACT_PRECISION_EXCEEDED~;
    }

    GeometryAsset* geometry = state.assets.geometry(state.geometry);
    ContactVector translation = { world.m03, world.m13, world.m23 };
    bool changed;
    foreach (index, position : state.published) {
        ContactVector relative = (ContactVector)position - translation;
        Vec3 local = { (float)row_x.dot(relative), (float)row_y.dot(relative), (float)row_z.dot(relative) };
        if (!finite_vector(local)) return CONTACT_PRECISION_EXCEEDED~;
        Vec3 restored = maths::transform_point(world, local);
        if (!finite_vector(restored)) return CONTACT_PRECISION_EXCEEDED~;
        ContactInterval error = physics::contact_length(physics::contact_vector_subtract(physics::contact_vector((ContactVector)restored), physics::contact_vector((ContactVector)position))!)!;
        if (error.max > state.desc.collisions.contact_tolerance) return CONTACT_PRECISION_EXCEEDED~;
        state.local_output[index] = local;
        state.publication_roundtrip[index] = restored;
        changed |= local != geometry.data.positions[index];
    }
    state.local_bounds = geometry.data.bounds;
    if (!changed) return false;

    Geometry staged = geometry.data;
    staged.positions = state.local_output;
    staged.normals = state.local_normals;
    staged.compute_normals(state.assets.allocator);
    staged.finalize();
    foreach (normal : staged.normals) if (!finite_vector(normal)) return CONTACT_PRECISION_EXCEEDED~;
    state.local_bounds = staged.bounds;
    return true;
}

fn void commit_local_publication(ClothState* state, Mat4 world, bool changed) @local {
    if (changed) {
        GeometryAsset* geometry = state.assets.geometry(state.geometry);
        geometry.data.positions[..] = state.local_output[..];
        geometry.data.normals[..] = state.local_normals[..];
        geometry.data.bounds = state.local_bounds;
        state.assets.mark_geometry_streams_dirty(state.geometry, { .positions = true, .normals = true });
    }
    state.published_frame = world;
}

fn void? update_cloth(
    PhysicsWorld* world,
    ClothState* state,
    Node* node,
    uint steps,
    double* publication_seconds,
) @private {
    ClothState staged = staged_cloth(state);
    defer {
        state.contact_result = staged.contact_result;
        state.path_count = staged.path_count;
    }
    staged.contact_result.stage = ClothContactStage.ARITHMETIC;
    if (!physics::contact_arithmetic_supported()) return CONTACT_PRECISION_EXCEEDED~;
    staged.contact_result.stage = ClothContactStage.BINDINGS;
    refresh_colliders(world, &staged)!;
    foreach (slot, pin : staged.pins) staged.pin_targets[slot] = maths::transform_point(node.world, staged.rest[pin]);
    sample_bodies(world.scene, &staged);
    if (steps) {
        if (staged.desc.substeps > uint::max / steps) return c3d::CAPACITY_EXCEEDED~;
        solve_cloth(
            world: world,
            state: &staged,
            wind: world.scene.get(node, Wind),
            gravity: world.desc.tuning.gravity,
            step_dt: world.desc.tuning.fixed_dt,
            steps: steps,
        )!;
    }

    time::Clock publication_start = clock::now();
    defer *publication_seconds += (clock::now() - publication_start).to_sec();
    prepare_publication(world, &staged, steps != 0)!;
    staged.contact_result.stage = ClothContactStage.PUBLICATION;
    bool changed = stage_local_publication(&staged, node.world)!;
    if (contact_pass(world: world, state: &staged, positions: staged.publication_roundtrip, apply: false)! != 0) {
        staged.contact_result.stage = ClothContactStage.PUBLICATION;
        return CONTACT_PRECISION_EXCEEDED~;
    }
    commit_cloth(state, &staged);
    state.local_bounds = staged.local_bounds;
    commit_local_publication(state, node.world, changed);
    staged.contact_result.stage = ClothContactStage.NONE;
}

fn void? reexpress_cloth(ClothState* state, Mat4 world) @private {
    if (world == state.published_frame) return;
    if (!physics::contact_arithmetic_supported()) return CONTACT_PRECISION_EXCEEDED~;
    bool changed = stage_local_publication(state, world)!;
    commit_local_publication(state, world, changed);
}
