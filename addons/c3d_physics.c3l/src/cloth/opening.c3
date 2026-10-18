module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;
import std::sort;

const double OPENING_RELAXATION @local = 0.5; // half-step Gauss-Seidel damping; prevents oscillation between coupled opening pairs
const double OPENING_AXIS_EPSILON @local = 1e-8; // minimum candidate axis length and centroid separation along the axis
const double OPENING_DENOMINATOR_EPSILON @local = 1e-12; // minimum effective inverse-mass sum for a two-vertex opening projection
const double OPENING_ZERO_GAP_EPSILON @local = 1e-12; // maximum start gap along an orthogonal cut-edge normal for duplicated endpoints
const double OPENING_MIN_PADDING @local = 1e-4; // metres; minimum solver margin above target_gap so float rounding keeps end_gap.min >= target_gap
const double OPENING_TILT_FACTOR @local = 0.25; // tangent-direction blend added when a pure in-plane normal is blocked

struct ClothOpeningPair @private {
    ClothCandidate   candidate;
    uint[4]          vertices;
    ContactVector[4] centroids;
    uint             first_count;
    uint             second_count;
    ContactVector    axis;
    bool             cut_edge_orthogonal;
    uint             cut_edge_low_parent;
    uint             cut_edge_high_parent;
}

struct ClothPreSplitAdjacency @local {
    uint[]  canonical;
    ulong[] adjacent;
}

struct ClothSplitGroup @local {
    bool   movable;
    uint   start;
    uint   count;
    double mass;
}

fn bool pre_split_vertices_adjacent(ClothPreSplitAdjacency adjacency, uint first, uint second) @local {
    first = adjacency.canonical[first];
    second = adjacency.canonical[second];
    if (first == second) return true;

    ulong key = self_edge_key(first, second);
    usz low;
    usz high = adjacency.adjacent.len;
    while (low < high) {
        usz middle = low + (high - low) / 2;
        ulong found = adjacency.adjacent[middle];
        if (found == key) return true;
        if (found < key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return false;
}

fn bool pre_split_pair_excluded(
    ClothState* state,
    ClothCandidate candidate,
    ClothPreSplitAdjacency adjacency,
) @local {
    if (candidate.kind == SELF_VERTEX_FACE) {
        uint vertex_parent = state.split_parents[candidate.self_pair[0]];
        foreach (corner : state.faces[candidate.self_pair[1]].vertices) {
            uint corner_parent = state.split_parents[corner];
            if (pre_split_vertices_adjacent(adjacency, vertex_parent, corner_parent)) return true;
        }
        return false;
    }

    ClothConstraint first = state.edges[candidate.self_pair[0]];
    ClothConstraint second = state.edges[candidate.self_pair[1]];
    uint first_start = state.split_parents[first.first];
    uint first_end = state.split_parents[first.second];
    uint second_start = state.split_parents[second.first];
    uint second_end = state.split_parents[second.second];
    return pre_split_vertices_adjacent(adjacency, first_start, second_start)
      || pre_split_vertices_adjacent(adjacency, first_start, second_end)
      || pre_split_vertices_adjacent(adjacency, first_end, second_start)
      || pre_split_vertices_adjacent(adjacency, first_end, second_end);
}

fn ContactVector particle_sector_centroid(
    ClothState* state,
    Vec3[] positions,
    uint particle,
) @local {
    ContactVector sum;
    uint count;
    usz triangle_count = state.corners.len / 3;
    for (usz face = 0; face < triangle_count; face++) {
        uint p0 = state.corners[3 * face].particle;
        uint p1 = state.corners[3 * face + 1].particle;
        uint p2 = state.corners[3 * face + 2].particle;
        if (p0 == particle || p1 == particle || p2 == particle) {
            ContactVector face_centroid = ((ContactVector)positions[p0]
              + (ContactVector)positions[p1]
              + (ContactVector)positions[p2]) / 3.0;
            sum += face_centroid;
            count++;
        }
    }
    if (!count) return (ContactVector)positions[particle];
    return sum / (double)count;
}

fn bool is_duplicated_cut_edge_pair(
    ClothOpeningPair* pair,
    ClothState* state,
    uint first_vertex,
    uint second_vertex,
) @local {
    if (!pair.cut_edge_orthogonal) return false;
    uint first_parent = state.split_parents[first_vertex];
    uint second_parent = state.split_parents[second_vertex];
    if (first_parent == second_parent) return false;
    uint low = math::min(first_parent, second_parent);
    uint high = math::max(first_parent, second_parent);
    return low == pair.cut_edge_low_parent && high == pair.cut_edge_high_parent;
}

fn bool admit_opening_axis_at_zero(
    ClothState* state,
    Vec3[] start_positions,
    ClothOpeningPair* pair,
    ContactVector axis,
    bool cut_edge_orthogonal,
    uint cut_low,
    uint cut_high,
) @local {
    double length = axis.length();
    if (!math::is_finite(length) || !(length > OPENING_AXIS_EPSILON)) return false;
    ContactVector unit = axis / length;
    ContactIntervals unit_interval = physics::contact_vector(unit);

    ClothOpeningPair candidate_pair = *pair;
    candidate_pair.axis = unit;
    candidate_pair.cut_edge_orthogonal = cut_edge_orthogonal;
    candidate_pair.cut_edge_low_parent = cut_low;
    candidate_pair.cut_edge_high_parent = cut_high;

    for (uint first_slot = 0; first_slot < pair.first_count; first_slot++) {
        uint first_vertex = pair.vertices[first_slot];
        ContactVector first_centroid = pair.centroids[first_slot];
        for (uint second_slot = 0; second_slot < pair.second_count; second_slot++) {
            uint second_index = pair.first_count + second_slot;
            uint second_vertex = pair.vertices[second_index];
            ContactVector second_centroid = pair.centroids[second_index];
            if (state.split_parents[first_vertex] == state.split_parents[second_vertex]) {
                if (start_positions[first_vertex] != start_positions[second_vertex]) return false;
                if (!((first_centroid - second_centroid).dot(unit) > OPENING_AXIS_EPSILON)) return false;
                continue;
            }

            ContactIntervals? delta = physics::contact_vector_subtract(
                physics::contact_vector((ContactVector)start_positions[first_vertex]),
                physics::contact_vector((ContactVector)start_positions[second_vertex]),
            );
            if (catch delta) return false;
            ContactInterval? projection = physics::contact_dot(unit_interval, delta);
            if (catch projection) return false;

            if (is_duplicated_cut_edge_pair(
                pair:          &candidate_pair,
                state:         state,
                first_vertex:  first_vertex,
                second_vertex: second_vertex,
            )) {
                if (!(projection.min >= -OPENING_ZERO_GAP_EPSILON)
                    || !(projection.max <= OPENING_ZERO_GAP_EPSILON)) {
                    return false;
                }
                if (!((first_centroid - second_centroid).dot(unit) > OPENING_AXIS_EPSILON)) return false;
            } else {
                if (!(projection.min > 0)) return false;
            }
        }
    }

    pair.axis = unit;
    pair.cut_edge_orthogonal = cut_edge_orthogonal;
    pair.cut_edge_low_parent = cut_low;
    pair.cut_edge_high_parent = cut_high;
    return true;
}

fn void? select_opening_axis(
    ClothState* state,
    Vec3[] start_positions,
    ClothOpeningPair* pair,
) @local {
    ContactVector first_centroid;
    for (uint first_slot = 0; first_slot < pair.first_count; first_slot++) {
        first_centroid += pair.centroids[first_slot];
    }
    first_centroid /= (double)pair.first_count;

    ContactVector second_centroid;
    for (uint second_slot = 0; second_slot < pair.second_count; second_slot++) {
        second_centroid += pair.centroids[pair.first_count + second_slot];
    }
    second_centroid /= (double)pair.second_count;
    ContactVector centroid_direction = first_centroid - second_centroid;

    foreach (interior_index, &interior_edge : state.interior_edges) {
        if (!state.staged_edge_cut[interior_index]) continue;
        bool touches;
        for (uint slot = 0; slot < pair.first_count + pair.second_count; slot++) {
            uint base_vertex = state.particle_bases[pair.vertices[slot]];
            if (base_vertex == interior_edge.low_base || base_vertex == interior_edge.high_base) {
                touches = true;
                break;
            }
        }
        if (!touches) continue;

        uint low_particle = state.staged_sector_to_particle[interior_edge.low_sector0];
        uint high_particle = state.staged_sector_to_particle[interior_edge.high_sector0];
        ContactVector edge_vector = (ContactVector)start_positions[high_particle]
          - (ContactVector)start_positions[low_particle];
        double edge_length = edge_vector.length();
        if (!(edge_length > OPENING_AXIS_EPSILON)) continue;
        ContactVector cut_tangent = edge_vector / edge_length;

        uint face_corner0 = state.corners[3 * interior_edge.face0].particle;
        uint face_corner1 = state.corners[3 * interior_edge.face0 + 1].particle;
        uint face_corner2 = state.corners[3 * interior_edge.face0 + 2].particle;
        ContactVector face_normal = (
            (ContactVector)start_positions[face_corner1] - (ContactVector)start_positions[face_corner0]
        ).cross((ContactVector)start_positions[face_corner2] - (ContactVector)start_positions[face_corner0]);
        double face_length = face_normal.length();
        if (!(face_length > OPENING_AXIS_EPSILON)) continue;
        face_normal /= face_length;

        ContactVector in_plane = face_normal.cross(cut_tangent);
        double in_plane_length = in_plane.length();
        if (!(in_plane_length > OPENING_AXIS_EPSILON)) continue;
        in_plane /= in_plane_length;
        if (in_plane.dot(centroid_direction) < 0) in_plane = -in_plane;

        uint low_parent = uint::max;
        uint high_parent = uint::max;
        for (uint slot = 0; slot < pair.first_count + pair.second_count; slot++) {
            uint vertex = pair.vertices[slot];
            uint base_vertex = state.particle_bases[vertex];
            if (base_vertex == interior_edge.low_base) low_parent = state.split_parents[vertex];
            if (base_vertex == interior_edge.high_base) high_parent = state.split_parents[vertex];
        }
        uint cut_low = low_parent != uint::max && high_parent != uint::max
          ? math::min(low_parent, high_parent)
          : uint::max;
        uint cut_high = low_parent != uint::max && high_parent != uint::max
          ? math::max(low_parent, high_parent)
          : uint::max;

        ContactVector[2] signs = { in_plane, -in_plane };
        foreach (candidate_axis : signs) {
            if (admit_opening_axis_at_zero(
                state:               state,
                start_positions:     start_positions,
                pair:                pair,
                axis:                candidate_axis,
                cut_edge_orthogonal: cut_low != uint::max,
                cut_low:             cut_low,
                cut_high:            cut_high,
            )) {
                return;
            }
        }

        ContactVector[4] tilted = {
            in_plane + cut_tangent * OPENING_TILT_FACTOR,
            in_plane - cut_tangent * OPENING_TILT_FACTOR,
            -in_plane + cut_tangent * OPENING_TILT_FACTOR,
            -in_plane - cut_tangent * OPENING_TILT_FACTOR,
        };
        foreach (candidate_axis : tilted) {
            if (admit_opening_axis_at_zero(
                state:               state,
                start_positions:     start_positions,
                pair:                pair,
                axis:                candidate_axis,
                cut_edge_orthogonal: false,
                cut_low:             uint::max,
                cut_high:            uint::max,
            )) {
                return;
            }
        }
    }

    for (uint first_slot = 0; first_slot < pair.first_count; first_slot++) {
        uint first_vertex = pair.vertices[first_slot];
        for (uint second_slot = 0; second_slot < pair.second_count; second_slot++) {
            uint second_index = pair.first_count + second_slot;
            uint second_vertex = pair.vertices[second_index];
            if (state.split_parents[first_vertex] == state.split_parents[second_vertex]) {
                ContactVector difference = pair.centroids[first_slot] - pair.centroids[second_index];
                if (admit_opening_axis_at_zero(
                    state:               state,
                    start_positions:     start_positions,
                    pair:                pair,
                    axis:                difference,
                    cut_edge_orthogonal: false,
                    cut_low:             uint::max,
                    cut_high:            uint::max,
                )) {
                    return;
                }
            }
        }
    }

    if (admit_opening_axis_at_zero(
        state:               state,
        start_positions:     start_positions,
        pair:                pair,
        axis:                centroid_direction,
        cut_edge_orthogonal: false,
        cut_low:             uint::max,
        cut_high:            uint::max,
    )) {
        return;
    }

    return OPENING_UNRESOLVED~;
}

fn usz? gather_opening_pairs(
    ClothState* state,
    Vec3[] positions,
    ClothPreSplitAdjacency adjacency,
) @local {
    usz primitive_count;
    float thickness = state.desc.thickness;
    foreach (index, position : positions) {
        uint[1] vertices = { (uint)index };
        state.self_primitive_storage[primitive_count++] = {
            .bounds = self_bounds(
                state:     state,
                positions: positions,
                vertices:  vertices[..],
                thickness: thickness,
            )!,
            .index = (uint)index,
            .kind  = VERTEX,
        };
    }

    foreach (index, edge : state.edges) {
        uint[2] vertices = { edge.first, edge.second };
        state.self_primitive_storage[primitive_count++] = {
            .bounds = self_bounds(
                state:     state,
                positions: positions,
                vertices:  vertices[..],
                thickness: thickness,
            )!,
            .index = (uint)index,
            .kind  = EDGE,
        };
    }

    foreach (index, face : state.faces) {
        state.self_primitive_storage[primitive_count++] = {
            .bounds = self_bounds(
                state:     state,
                positions: positions,
                vertices:  face.vertices[..],
                thickness: thickness,
            )!,
            .index = (uint)index,
            .kind  = FACE,
        };
    }

    state.self_primitives = state.self_primitive_storage[:primitive_count];
    sort::quicksort(state.self_primitives, &by_self_bound);

    usz pair_count;
    foreach (index, first : state.self_primitives) {
        for (usz other = (usz)index + 1; other < state.self_primitives.len; other++) {
            ClothSelfPrimitive second = state.self_primitives[other];
            if (second.bounds.min.x > first.bounds.max.x) break;
            if (second.bounds.min.y > first.bounds.max.y || first.bounds.min.y > second.bounds.max.y
                || second.bounds.min.z > first.bounds.max.z || first.bounds.min.z > second.bounds.max.z) {
                continue;
            }

            ClothCandidate candidate;
            if (first.kind == VERTEX && second.kind == FACE) {
                candidate = { .kind = SELF_VERTEX_FACE, .self_pair = { first.index, second.index } };
            } else if (first.kind == FACE && second.kind == VERTEX) {
                candidate = { .kind = SELF_VERTEX_FACE, .self_pair = { second.index, first.index } };
            } else if (first.kind == EDGE && second.kind == EDGE) {
                candidate = {
                    .kind      = SELF_EDGE_EDGE,
                    .self_pair = { math::min(first.index, second.index), math::max(first.index, second.index) },
                };
            } else {
                continue;
            }

            if (self_pair_excluded(state, candidate)) continue;
            if (!pre_split_pair_excluded(state, candidate, adjacency)) continue;

            if (pair_count == state.opening_pairs.len
                || pair_count == state.candidates.len
                || pair_count == state.contacts.len) {
                return c3d::CAPACITY_EXCEEDED~;
            }

            ClothOpeningPair pair = { .candidate = candidate };
            if (candidate.kind == SELF_VERTEX_FACE) {
                uint[3] face_corners = state.faces[candidate.self_pair[1]].vertices;
                pair.vertices = { candidate.self_pair[0], face_corners[0], face_corners[1], face_corners[2] };
                pair.first_count = 1;
                pair.second_count = 3;
            } else {
                ClothConstraint first_edge = state.edges[candidate.self_pair[0]];
                ClothConstraint second_edge = state.edges[candidate.self_pair[1]];
                pair.vertices = { first_edge.first, first_edge.second, second_edge.first, second_edge.second };
                pair.first_count = 2;
                pair.second_count = 2;
            }
            for (uint slot = 0; slot < pair.first_count + pair.second_count; slot++) {
                pair.centroids[slot] = particle_sector_centroid(state, positions, pair.vertices[slot]);
            }
            select_opening_axis(state, positions, &pair)!;
            state.opening_pairs[pair_count++] = pair;
        }
    }
    return pair_count;
}

fn void build_split_groups(
    ClothState* state,
    uint pre_particle_count,
) @local {
    uint particle_count = state.active_particle_count;
    uint[] counts = state.sector_scratch[:pre_particle_count];
    counts[..] = 0;

    for (uint particle = 0; particle < particle_count; particle++) {
        counts[state.split_parents[particle]]++;
    }

    uint cursor;
    for (uint parent = 0; parent < pre_particle_count; parent++) {
        state.split_group_starts[parent] = cursor;
        cursor += counts[parent];
        state.split_group_counts[parent] = 0;
        state.split_group_masses[parent] = 0;
    }

    for (uint particle = 0; particle < particle_count; particle++) {
        uint parent = state.split_parents[particle];
        uint offset = state.split_group_starts[parent] + state.split_group_counts[parent]++;
        state.split_group_members[offset] = particle;
        if (state.inverse_masses[particle] == 0) {
            state.split_group_masses[parent] = -1;
        } else if (state.split_group_masses[parent] >= 0) {
            state.split_group_masses[parent] += state.particle_masses[particle];
        }
    }
}

fn ClothSplitGroup lookup_split_group(
    ClothState* state,
    uint parent_id,
) @local {
    uint count = state.split_group_counts[parent_id];
    double mass = state.split_group_masses[parent_id];
    bool movable = count >= 2 && mass > 0 && math::is_finite(mass);
    return {
        .movable = movable,
        .start   = state.split_group_starts[parent_id],
        .count   = count,
        .mass    = movable ? mass : 0,
    };
}

fn void? solve_opening_displacements(
    ClothState* state,
    Vec3[] start_positions,
    ClothOpeningPair[] pairs,
    uint pre_particle_count,
    double target_gap,
    uint max_iterations,
) @local {
    uint particle_count = state.active_particle_count;
    ContactVector[] work = state.opening_work_positions[:particle_count];
    for (uint particle = 0; particle < particle_count; particle++) {
        work[particle] = (ContactVector)start_positions[particle];
    }

    double padding = math::max((double)state.desc.collisions.contact_tolerance, OPENING_MIN_PADDING);
    double padded_gap = target_gap + padding;

    for (uint pass = 0; pass < max_iterations; pass++) {
        bool any_deficit;
        foreach (&pair : pairs) {
            for (uint first_slot = 0; first_slot < pair.first_count; first_slot++) {
                uint first_vertex = pair.vertices[first_slot];
                for (uint second_slot = 0; second_slot < pair.second_count; second_slot++) {
                    uint second_vertex = pair.vertices[pair.first_count + second_slot];
                    double gap = pair.axis.dot(work[first_vertex] - work[second_vertex]);
                    if (gap < padded_gap) {
                        any_deficit = true;
                        break;
                    }
                }
                if (any_deficit) break;
            }
            if (any_deficit) break;
        }
        if (!any_deficit) break;

        foreach (&pair : pairs) {
            ContactVector axis = pair.axis;
            for (uint first_slot = 0; first_slot < pair.first_count; first_slot++) {
                uint first_vertex = pair.vertices[first_slot];
                uint first_parent = state.split_parents[first_vertex];
                ClothSplitGroup first_group = lookup_split_group(state, first_parent);

                for (uint second_slot = 0; second_slot < pair.second_count; second_slot++) {
                    uint second_vertex = pair.vertices[pair.first_count + second_slot];
                    double gap = axis.dot(work[first_vertex] - work[second_vertex]);
                    if (gap >= padded_gap) continue;

                    uint second_parent = state.split_parents[second_vertex];
                    ClothSplitGroup second_group = lookup_split_group(state, second_parent);

                    if (!first_group.movable && !second_group.movable) {
                        return OPENING_UNRESOLVED~;
                    }

                    double deficit = (padded_gap - gap) * OPENING_RELAXATION;
                    if (first_parent == second_parent) {
                        if (!first_group.movable) return OPENING_UNRESOLVED~;
                        double first_mass = state.particle_masses[first_vertex];
                        double second_mass = state.particle_masses[second_vertex];
                        double denominator = 1.0 / first_mass + 1.0 / second_mass;
                        if (!math::is_finite(denominator) || !(denominator > OPENING_DENOMINATOR_EPSILON)) {
                            return OPENING_UNRESOLVED~;
                        }

                        double scale = deficit / denominator;
                        work[first_vertex] += axis * (scale / first_mass);
                        work[second_vertex] -= axis * (scale / second_mass);
                    } else {
                        double first_mass = state.particle_masses[first_vertex];
                        double second_mass = state.particle_masses[second_vertex];
                        double first_denominator = first_group.movable
                          ? (1.0 / first_mass - 1.0 / first_group.mass)
                          : 0.0;
                        double second_denominator = second_group.movable
                          ? (1.0 / second_mass - 1.0 / second_group.mass)
                          : 0.0;
                        double denominator = first_denominator + second_denominator;
                        if (!math::is_finite(denominator) || !(denominator > OPENING_DENOMINATOR_EPSILON)) {
                            return OPENING_UNRESOLVED~;
                        }

                        double scale = deficit / denominator;
                        if (first_group.movable) {
                            uint[] members = state.split_group_members[first_group.start:first_group.count];
                            foreach (member : members) {
                                double coefficient = (member == first_vertex ? 1.0 / first_mass : 0.0)
                                  - 1.0 / first_group.mass;
                                work[member] += axis * (scale * coefficient);
                            }
                        }

                        if (second_group.movable) {
                            uint[] members = state.split_group_members[second_group.start:second_group.count];
                            foreach (member : members) {
                                double coefficient = -(member == second_vertex ? 1.0 / second_mass : 0.0)
                                  + 1.0 / second_group.mass;
                                work[member] += axis * (scale * coefficient);
                            }
                        }
                    }
                }
            }
        }
    }

    for (uint parent_id = 0; parent_id < pre_particle_count; parent_id++) {
        ClothSplitGroup group = lookup_split_group(state, parent_id);
        if (!group.movable) continue;

        uint[] members = state.split_group_members[group.start:group.count];
        ContactVector weighted_sum;
        foreach (member : members) {
            weighted_sum += work[member] * state.particle_masses[member];
        }

        ContactVector drift = weighted_sum / group.mass - (ContactVector)start_positions[parent_id];
        foreach (member : members) {
            work[member] -= drift;
            Vec3 rounded = (Vec3)work[member];
            if (!finite_vector(rounded)) return OPENING_UNRESOLVED~;
            state.predicted[member] = rounded;
        }
    }
}

fn void? certify_opening_trajectory(
    ClothState* state,
    Vec3[] start_positions,
    Vec3[] end_positions,
    ClothOpeningPair[] pairs,
    double target_gap,
) @private {
    foreach (&pair : pairs) {
        ContactIntervals axis_interval = physics::contact_vector(pair.axis);

        for (uint first_slot = 0; first_slot < pair.first_count; first_slot++) {
            uint first_vertex = pair.vertices[first_slot];
            ContactVector first_centroid = pair.centroids[first_slot];

            for (uint second_slot = 0; second_slot < pair.second_count; second_slot++) {
                uint second_index = pair.first_count + second_slot;
                uint second_vertex = pair.vertices[second_index];

                if (state.split_parents[first_vertex] == state.split_parents[second_vertex]) {
                    ContactVector second_centroid = pair.centroids[second_index];
                    ContactVector relative_displacement = (
                        (ContactVector)end_positions[first_vertex] - (ContactVector)start_positions[first_vertex]
                    ) - ((ContactVector)end_positions[second_vertex] - (ContactVector)start_positions[second_vertex]);
                    if (!(relative_displacement.dot(first_centroid - second_centroid) > 0)) {
                        return OPENING_UNRESOLVED~;
                    }
                }

                ContactIntervals? end_delta = physics::contact_vector_subtract(
                    physics::contact_vector((ContactVector)end_positions[first_vertex]),
                    physics::contact_vector((ContactVector)end_positions[second_vertex]),
                );
                if (catch end_delta) return OPENING_UNRESOLVED~;
                ContactInterval? end_gap = physics::contact_dot(axis_interval, end_delta);
                if (catch end_gap) return OPENING_UNRESOLVED~;
                if (!(end_gap.min >= target_gap)) return OPENING_UNRESOLVED~;
            }
        }
    }
}

fn bool is_newly_enabled_candidate(ClothOpeningPair[] pairs, ClothCandidate candidate) @local {
    foreach (&pair : pairs) {
        if (pair.candidate.kind == candidate.kind
            && pair.candidate.self_pair[0] == candidate.self_pair[0]
            && pair.candidate.self_pair[1] == candidate.self_pair[1]) {
            return true;
        }
    }
    return false;
}

fn void? resweep_opening_path(
    PhysicsWorld* world,
    ClothState* state,
    Vec3[] start_positions,
    Vec3[] end_positions,
    ClothOpeningPair[] pairs,
    double substep_time,
) @local {
    if (!state.desc.collisions.continuous) return;

    start_paths(
        state:  state,
        start:  start_positions,
        end:    end_positions,
        begin:  substep_time,
        finish: substep_time,
    )!;
    state.sweep_active = true;
    defer state.sweep_active = false;

    path_bounds(state)!;
    usz candidates = physics::gather_cloth_candidates(world, state, end_positions)!;
    candidates = gather_self_candidates(state, end_positions, candidates)!;
    state.contact_result.stage = ClothContactStage.OPENING;

    foreach (&candidate : state.candidates[:candidates]) {
        if (!self_candidate(*candidate) && state.inverse_masses[candidate.particle] == 0) continue;
        if (self_candidate(*candidate) && is_newly_enabled_candidate(pairs, *candidate)) continue;

        ClothImpact? impact = sweep_candidate(world, state, candidate);
        state.contact_result.stage = ClothContactStage.OPENING;
        if (catch excuse = impact) {
            return excuse == c3d::CAPACITY_EXCEEDED ? c3d::CAPACITY_EXCEEDED~ : OPENING_UNRESOLVED~;
        }
        if (impact.hit) return OPENING_UNRESOLVED~;
    }
}

fn usz collect_strain_triggered_paths(
    ClothState* state,
    uint[] selected_paths,
) @local {
    usz selected_count;
    foreach (path_index, &path : state.cut_paths) {
        if (!path.strain_trigger
            || state.staged_cut_results[path_index].is_cut
            || state.cut_results[path_index].outcome == ClothCutOutcome.REFUSED) {
            continue;
        }

        bool triggered;
        for (uint edge_offset = 0; edge_offset < path.edge_count; edge_offset++) {
            uint interior_index = state.cut_path_edges[path.edge_start + edge_offset];
            if (state.staged_edge_cut[interior_index]) continue;
            ClothInteriorEdge* interior_edge = &state.interior_edges[interior_index];
            uint low_particle = state.staged_sector_to_particle[interior_edge.low_sector0];
            uint high_particle = state.staged_sector_to_particle[interior_edge.high_sector0];
            float rest_length = interior_edge.base_edge.rest_length;
            if (!(rest_length > 0)) continue;

            float current_length = (state.positions[high_particle] - state.positions[low_particle]).length();
            float strain = math::max(0.0f, (current_length - rest_length) / rest_length);
            if (strain >= path.strain_threshold) {
                triggered = true;
                break;
            }
        }

        if (triggered) {
            selected_paths[selected_count++] = (uint)path_index;
        }
    }
    return selected_count;
}

fn usz consume_pending_cut_requests(
    ClothState* state,
    uint[] selected_paths,
    usz selected_count,
) @local {
    foreach (request_index : state.pending_requests[:state.pending_request_count]) {
        bool exists;
        foreach (selected : selected_paths[:selected_count]) {
            if (selected == request_index) {
                exists = true;
                break;
            }
        }

        if (!exists) {
            selected_paths[selected_count++] = request_index;
        }
    }
    state.pending_request_count = 0;
    return selected_count;
}

fn void? evaluate_substep_cuts(
    PhysicsWorld* world,
    ClothState* state,
    uint substep,
    uint total,
) @private {
    if (!state.cut_paths.len) return;

    uint[] selected_paths = state.selected_paths_scratch;
    usz selected_count = collect_strain_triggered_paths(state, selected_paths);
    selected_count = consume_pending_cut_requests(state, selected_paths, selected_count);
    if (!selected_count) return;

    sort::quicksort(selected_paths[:selected_count]);

    bool any_new_edge;
    foreach (path_index : selected_paths[:selected_count]) {
        ClothCutPathMeta* path = &state.cut_paths[path_index];
        ClothCutResult* result = &state.staged_cut_results[path_index];
        result.attempts++;
        result.failure = {};
        result.stage = ClothContactStage.NONE;

        if (result.is_cut) {
            result.outcome = ClothCutOutcome.ALREADY_CUT;
            continue;
        }

        for (uint edge_offset = 0; edge_offset < path.edge_count; edge_offset++) {
            uint interior_index = state.cut_path_edges[path.edge_start + edge_offset];
            if (!state.staged_edge_cut[interior_index]) {
                state.staged_edge_cut[interior_index] = true;
                any_new_edge = true;
            }
        }
        result.outcome = ClothCutOutcome.APPLIED;
        result.is_cut = true;
    }

    if (!any_new_edge) return;

    uint pre_particle_count = state.active_particle_count;
    usz pre_adjacent_count = state.adjacent_vertices.len;
    if (state.canonical_vertex_storage.len) {
        state.pre_split_canonical[:pre_particle_count] = state.canonical_vertices[:pre_particle_count];
        state.pre_split_adjacent[:pre_adjacent_count] = state.adjacent_vertices[:pre_adjacent_count];
    }

    state.contact_result.stage = ClothContactStage.OPENING;
    bool particles_split = split_topology_sectors(state);
    state.cut_applied_this_update = true;

    if (!particles_split || !state.desc.collisions.self_collision) {
        return;
    }

    ClothPreSplitAdjacency adjacency = {
        .canonical = state.pre_split_canonical[:pre_particle_count],
        .adjacent  = state.pre_split_adjacent[:pre_adjacent_count],
    };
    usz pair_count = gather_opening_pairs(state, state.positions, adjacency)!;

    if (!pair_count) return;

    build_split_groups(state, pre_particle_count);

    ClothOpeningPair[] pairs = state.opening_pairs[:pair_count];
    double target_gap = math::max(
        2.0 * (double)state.desc.thickness,
        2.0 * (double)state.desc.collisions.contact_tolerance,
    );

    state.predicted[..] = state.positions[..];
    solve_opening_displacements(
        state:              state,
        start_positions:    state.positions,
        pairs:              pairs,
        pre_particle_count: pre_particle_count,
        target_gap:         target_gap,
        max_iterations:     state.opening_iterations,
    )!;

    certify_opening_trajectory(
        state:           state,
        start_positions: state.positions,
        end_positions:   state.predicted,
        pairs:           pairs,
        target_gap:      target_gap,
    )!;

    resweep_opening_path(
        world:           world,
        state:           state,
        start_positions: state.positions,
        end_positions:   state.predicted,
        pairs:           pairs,
        substep_time:    (double)substep / (double)total,
    )!;

    certify_hinge_step(state, state.positions, state.predicted)!;

    usz unresolved = contact_pass(
        world:     world,
        state:     state,
        positions: state.predicted,
        apply:     false,
    )!;
    if (unresolved != 0) {
        state.contact_result.stage = ClothContactStage.OPENING;
        return OPENING_UNRESOLVED~;
    }

    state.positions[..] = state.predicted[..];
    if (state.desc.collisions.continuous) {
        state.sweep_start[..] = state.positions[..];
        foreach (index, point : state.positions) {
            state.sweep_bounds[index] = { .min = point, .max = point };
        }
    }
}
