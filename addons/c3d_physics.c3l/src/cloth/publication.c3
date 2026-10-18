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

fn ClothState staged_cloth(ClothState* state) @private {
    ClothState staged = *state;
    rebind_active_slices(
        state:     &staged,
        is_staged: true,
        particles: state.committed_particle_count,
        pins:      state.committed_pin_count,
        soft:      state.committed_soft_count,
        edges:     state.committed_edge_count,
        bends:     state.committed_bend_count,
        hinges:    state.committed_hinge_count,
    );
    staged.bodies = state.staged_bodies;
    staged.shape_storage = state.staged_shapes;
    staged.shape_starts = state.staged_shape_starts;
    staged.shape_ends = state.staged_shape_ends;
    staged.contact_result = {};
    staged.topology_dirty = false;
    staged.cut_applied_this_update = false;

    staged.solved_reference[..] = state.solved_reference[..];
    staged.current_reference[..] = state.current_reference[..];
    staged.positions[..] = state.positions[..];
    staged.velocities[..] = state.velocities[..];
    staged.predicted[..] = state.predicted[..];
    staged.accelerations[..] = state.accelerations[..];
    staged.published[..] = state.published[..];
    staged.pin_anchors[..] = state.pin_anchors[..];
    staged.pin_targets[..] = state.pin_targets[..];
    staged.soft_anchors[..] = state.soft_anchors[..];
    staged.soft_targets[..] = state.soft_targets[..];
    staged.hinges[..] = state.hinges[..];
    staged.bodies[..] = state.bodies[..];
    staged.shape_starts[..] = state.shape_starts[..];
    staged.shape_ends[..] = state.shape_ends[..];
    if (state.cut_paths.len) {
        staged.staged_edge_cut[..] = state.committed_edge_cut[..];
        staged.staged_sector_to_particle[..] = state.committed_sector_to_particle[..];
        staged.staged_cut_results[..] = state.cut_results[..];
    }
    return staged;
}

fn void commit_cloth(ClothState* state, ClothState* staged) @private {
    commit_staged_topology(state, staged);
    state.solved_reference[..] = staged.solved_reference[..];
    state.current_reference[..] = staged.current_reference[..];
    state.positions[..] = staged.positions[..];
    state.velocities[..] = staged.velocities[..];
    state.predicted[..] = staged.predicted[..];
    state.accelerations[..] = staged.accelerations[..];
    state.published[..] = staged.publication_roundtrip[..];
    state.pin_anchors[..] = staged.pin_anchors[..];
    state.pin_targets[..] = staged.pin_targets[..];
    state.soft_anchors[..] = staged.soft_anchors[..];
    state.soft_targets[..] = staged.soft_targets[..];
    state.hinges[..] = staged.hinges[..];
    state.bodies[..] = staged.bodies[..];
    state.shapes = state.shape_storage[:staged.shapes.len];
    state.shapes[..] = staged.shapes[..];
    state.shape_starts[..] = staged.shape_starts[..];
    state.shape_ends[..] = staged.shape_ends[..];
    state.settle = staged.settle;
}

fn bool? stage_local_positions(ClothState* state, Mat4 world, bool force_changed = false) @private {
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
        if (!math::is_finite(row_x[axis]) || !math::is_finite(row_y[axis]) || !math::is_finite(row_z[axis])) {
            return CONTACT_PRECISION_EXCEEDED~;
        }
    }

    GeometryAsset* geometry = state.assets.geometry(state.geometry);
    ContactVector translation = { world.m03, world.m13, world.m23 };
    foreach (index, position : state.published) {
        ContactVector relative = (ContactVector)position - translation;
        Vec3 local = { (float)row_x.dot(relative), (float)row_y.dot(relative), (float)row_z.dot(relative) };
        if (!finite_vector(local)) return CONTACT_PRECISION_EXCEEDED~;

        Vec3 restored = maths::transform_point(world, local);
        if (!finite_vector(restored)) return CONTACT_PRECISION_EXCEEDED~;

        ContactInterval error = physics::contact_length(
            physics::contact_vector_subtract(
                physics::contact_vector((ContactVector)restored),
                physics::contact_vector((ContactVector)position),
            )!,
        )!;
        if (error.max > state.desc.collisions.contact_tolerance) return CONTACT_PRECISION_EXCEEDED~;

        state.particle_local[index] = local;
        state.publication_roundtrip[index] = restored;
    }

    state.spans = {};
    foreach (material_vertex, particle : state.material_particles) {
        Vec3 local = state.particle_local[particle];
        state.local_output[material_vertex] = local;
        if (local != geometry.data.positions[material_vertex]) {
            include_vertex(&state.spans.positions, (usz)material_vertex);
        }
    }

    state.local_bounds = geometry.data.bounds;
    return force_changed || !state.spans.positions.is_empty();
}

fn void? stage_material_frames(ClothState* state, bool changed) @private {
    if (!changed) return;

    compute_material_frames(
        corners:                  state.corners,
        triangle_uvs:             state.triangle_uvs,
        material_normal_domains:  state.material_normal_domains,
        material_reference_faces: state.material_reference_faces,
        tangent_signs:            state.tangent_signs,
        rest_tangents:            state.rest_tangents,
        rest_positions:           state.rest,
        current_positions:        state.particle_local,
        committed_tangents:       state.committed_tangents,
        normal_accum:             state.normal_accum,
        tangent_accum:            state.tangent_accum,
        out_normals:              state.local_normals,
        out_tangents:             state.local_tangents,
    )!;

    GeometryAsset* geometry = state.assets.geometry(state.geometry);
    Geometry staged = geometry.data;
    staged.positions = state.local_output;
    staged.finalize();
    state.local_bounds = staged.bounds;

    state.spans.normals = differing_range(geometry.data.normals, state.local_normals);
    if (state.desc.tangent_frame) {
        state.spans.tangents = differing_range(geometry.data.tangents, state.local_tangents);
    }
}

fn void commit_local_publication(
    ClothState* state,
    Mat4 world,
    bool changed,
    bool colors_changed = false,
) @private {
    if (changed) {
        GeometryAsset* geometry = state.assets.geometry(state.geometry);
        ClothSpans spans = state.spans;
        copy_vertices(geometry.data.positions, state.local_output, spans.positions);
        copy_vertices(geometry.data.normals, state.local_normals, spans.normals);
        if (state.desc.tangent_frame) {
            copy_vertices(geometry.data.tangents, state.local_tangents, spans.tangents);
            state.committed_tangents[..] = state.local_tangents[..];
        }
        geometry.data.bounds = state.local_bounds;

        mark_vertices(state, { .positions = true }, spans.positions);
        mark_vertices(state, { .normals = true }, spans.normals);
        mark_vertices(state, { .tangents = true }, spans.tangents);
    }
    if (colors_changed && state.staged_colors.len) commit_color_publication(state);
    state.published_frame = world;
}

fn void commit_color_publication(ClothState* state) @private {
    GeometryAsset* geometry = state.assets.geometry(state.geometry);
    VertexRange span = differing_range(geometry.data.colors, state.staged_colors);
    copy_vertices(geometry.data.colors, state.staged_colors, span);
    mark_vertices(state, { .colors = true }, span);
}

macro void copy_vertices(target, source, VertexRange span) @local {
    usz count = (usz)(span.end - span.first);
    target[span.first:count] = source[span.first:count];
}

fn void mark_vertices(ClothState* state, GeometryStreams stream, VertexRange span) @local {
    if (span.is_empty()) return;

    state.assets.mark_geometry_range_dirty(state.geometry, stream, span.first, span.end - span.first);
}

fn void collect_held_cloth(PhysicsWorld* world, ClothState* state, Node* node) @private {
    state.contact_result = { .stage = ClothContactStage.PUBLICATION };
    if (catch excuse = check_ordinary_output_ownership(world.scene, state, node)) {
        deactivate_output_node(world.scene, state.output_node);
        state.contact_result.failure = excuse;
        world.cloth_stats.failed++;
        tally_cloth(
            stats:               &world.cloth_stats,
            state:               state,
            kind:                ClothUpdateKind.SIMULATED,
            total_seconds:       0,
            publication_seconds: 0,
        );
        return;
    }

    sync_skinned_output(world.scene, state, node);
    state.contact_result = {};
    tally_cloth(
        stats:               &world.cloth_stats,
        state:               state,
        kind:                ClothUpdateKind.HELD,
        total_seconds:       0,
        publication_seconds: 0,
    );
}

fn ClothUpdateKind? stage_ordinary_cloth(PhysicsWorld* world, ClothState* state, uint steps) @private {
    ClothWork* work = &state.work;
    Node* node = work.node;

    Wind* wind = world.scene.get(node, Wind);
    if (is_quiescent(state)) {
        bool disturbed = probe_ordinary_rest(
            world: world,
            state: state,
            node:  node,
            wind:  wind,
        )!;
        if (!disturbed) return RESTED;
    }

    ClothState staged = staged_cloth(state);
    defer {
        state.contact_result = staged.contact_result;
        state.path_count = staged.path_count;
    }
    defer (catch excuse) {
        if (staged.topology_dirty) {
            state.topology_dirty = true;
            restore_committed_topology(state);
        }
        if (steps) record_refused_cuts(state, &staged, excuse);
    }

    staged.contact_result.stage = ClothContactStage.ARITHMETIC;
    if (!physics::contact_arithmetic_supported()) return CONTACT_PRECISION_EXCEEDED~;

    staged.contact_result.stage = ClothContactStage.PUBLICATION;
    check_ordinary_output_ownership(world.scene, &staged, node)!;

    staged.contact_result.stage = ClothContactStage.REFERENCE;
    sample_ordinary_reference(
        scene:  world.scene,
        assets: world.assets,
        owner:  node,
        state:  &staged,
    )!;

    staged.contact_result.stage = ClothContactStage.BINDINGS;
    refresh_colliders(world, &staged)!;
    carry_waking_cloth(&staged, staged.skinned ? null : &node.world);
    sample_bodies(world.scene, &staged);
    foreach (slot, pin : staged.pins) {
        staged.pin_anchors[slot] = staged.solved_reference[pin];
        staged.pin_targets[slot] = staged.current_reference[pin];
    }
    foreach (slot, attachment : staged.soft_attachments) {
        staged.soft_anchors[slot] = staged.solved_reference[attachment.particle];
        staged.soft_targets[slot] = staged.current_reference[attachment.particle];
    }

    if (steps) {
        if (staged.desc.substeps > uint::max / steps) return c3d::CAPACITY_EXCEEDED~;
        solve_cloth(
            world: world,
            state: &staged,
            wind: wind,
            gravity: world.desc.tuning.gravity,
            step_dt: world.desc.tuning.fixed_dt,
            steps: steps,
        )!;
    }

    time::Clock publication_start = clock::now();
    defer work.publication_seconds += (clock::now() - publication_start).to_sec();
    prepare_publication(world, &staged, steps != 0)!;

    staged.contact_result.stage = ClothContactStage.PUBLICATION;
    bool changed = stage_local_positions(&staged, node.world, staged.cut_applied_this_update)!;
    if (contact_pass(world: world, state: &staged, positions: staged.publication_roundtrip, apply: false)! != 0) {
        staged.contact_result.stage = ClothContactStage.PUBLICATION;
        return CONTACT_PRECISION_EXCEEDED~;
    }

    staged.contact_result.stage = ClothContactStage.MATERIAL;
    stage_material_frames(&staged, changed)!;
    note_settling(
        world: world,
        state: &staged,
        wind:  wind,
        steps: steps,
    );

    work.changed = changed;
    work.reset_history = staged.cut_applied_this_update;

    commit_cloth(state, &staged);
    state.local_bounds = staged.local_bounds;
    state.spans = staged.spans;

    staged.contact_result.stage = ClothContactStage.NONE;
    return SIMULATED;
}

fn void commit_ordinary_cloth(PhysicsWorld* world, ClothState* state) @private {
    ClothWork* work = &state.work;
    Node* node = work.node;

    if (work.failure) {
        state.contact_result.failure = work.failure;
        if (work.failure == OWNERSHIP_CHANGED) {
            deactivate_output_node(world.scene, state.output_node);
        } else if (!state.settle.resting) {
            if (catch reexpression_failure = reexpress_cloth(state, node.world)) {
                state.contact_result.failure = reexpression_failure;
                state.contact_result.stage = ClothContactStage.REEXPRESSION;
            }
        }
        world.cloth_stats.failed++;
        return;
    }

    if (work.kind == SIMULATED) {
        if (work.reset_history) {
            scene::Mesh* output_mesh = state.skinned
                ? world.scene.get(world.scene.node(state.output_node), scene::Mesh)
                : world.scene.get(node, scene::Mesh);
            output_mesh.reset_vertex_history();
        }
        commit_local_publication(state, node.world, work.changed);
    }

    sync_skinned_output(world.scene, state, node);
}

fn bool? probe_ordinary_rest(
    PhysicsWorld* world,
    ClothState* state,
    Node* node,
    Wind* wind,
) @local {
    ClothState probe = probe_cloth(state);
    defer state.contact_result = probe.contact_result;

    probe.contact_result.stage = ClothContactStage.PUBLICATION;
    check_ordinary_output_ownership(world.scene, &probe, node)!;

    probe.contact_result.stage = ClothContactStage.REFERENCE;
    sample_ordinary_reference(
        scene:  world.scene,
        assets: world.assets,
        owner:  node,
        state:  &probe,
    )!;

    probe.contact_result.stage = ClothContactStage.BINDINGS;
    refresh_colliders(world, &probe)!;
    sample_bodies(world.scene, &probe);
    if (rest_disturbed(world, &probe, wind)) return true;

    probe.contact_result = {};
    return false;
}

fn void sync_skinned_output(Scene* scene, ClothState* state, Node* node) @private {
    if (!state.skinned || !scene.world.is_alive(state.output_node)) return;

    Node* out_node = scene.node(state.output_node);
    out_node.layers = node.layers;
    out_node.world = node.world;
    out_node.visible_effective = node.visible_effective && out_node.visible;
}

fn void? reexpress_cloth(ClothState* state, Mat4 world) @private {
    if (world == state.published_frame) return;
    if (!physics::contact_arithmetic_supported()) return CONTACT_PRECISION_EXCEEDED~;
    bool changed = stage_local_positions(state, world)!;
    stage_material_frames(state, changed)!;
    commit_local_publication(state, world, changed);
}
