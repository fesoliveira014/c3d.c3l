module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;
import std::math::vector;
import std::sort;

const double PARALLEL_EDGE_DENOMINATOR_TOLERANCE @local = 1e-12; // relative Gram determinant below which two segments are treated as parallel

enum ClothSelfKind @private {
    VERTEX,
    EDGE,
    FACE,
}

struct ClothFace @private {
    uint[3] vertices;
}

struct ClothSelfPrimitive @private {
    Aabb bounds;
    uint index;
    ClothSelfKind kind;
}

struct ClothSelfContact @local {
    uint[4] vertices;
    double[4] coefficients;
    ContactVector normal;
    double residual;
}

fn void? check_seams(ClothSeam[] seams, uint vertex_count) @private {
    foreach (seam : seams) {
        if (seam.first >= vertex_count || seam.second >= vertex_count) return c3d::INVALID_ARGUMENT~;
    }
}

fn void build_self_topology(ClothState* state) @private {
    foreach (index, &canonical : state.canonical_vertices) *canonical = (uint)index;
    foreach (seam : state.desc.seams) {
        uint first = canonical_vertex(
            state.canonical_vertices,
            map_render_vertex(state.desc.render_particles, seam.first),
        );
        uint second = canonical_vertex(
            state.canonical_vertices,
            map_render_vertex(state.desc.render_particles, seam.second),
        );
        state.canonical_vertices[math::max(first, second)] = math::min(first, second);
    }
    foreach (index, &canonical : state.canonical_vertices) *canonical = canonical_vertex(state.canonical_vertices, (uint)index);

    usz adjacent_count;
    foreach (edge : state.edges) {
        uint first = state.canonical_vertices[edge.first];
        uint second = state.canonical_vertices[edge.second];
        if (first != second) state.adjacent_vertex_storage[adjacent_count++] = self_edge_key(first, second);
    }
    sort::quicksort(state.adjacent_vertex_storage[:adjacent_count]);
    usz unique_count;
    foreach (key : state.adjacent_vertex_storage[:adjacent_count]) {
        if (!unique_count || state.adjacent_vertex_storage[unique_count - 1] != key) {
            state.adjacent_vertex_storage[unique_count++] = key;
        }
    }
    state.adjacent_vertices = state.adjacent_vertex_storage[:unique_count];
    foreach (index, &face : state.faces) {
        face.vertices = {
            state.corners[3 * index].particle,
            state.corners[3 * index + 1].particle,
            state.corners[3 * index + 2].particle,
        };
    }
}

fn uint canonical_vertex(uint[] parents, uint vertex) @local {
    uint root = vertex;
    while (parents[root] != root) root = parents[root];
    while (parents[vertex] != root) {
        uint next = parents[vertex];
        parents[vertex] = root;
        vertex = next;
    }
    return root;
}

fn ulong self_edge_key(uint first, uint second) @private {
    return (ulong)math::min(first, second) << 32 | (ulong)math::max(first, second);
}

fn bool self_vertices_adjacent(ClothState* state, uint first, uint second) @private {
    first = state.canonical_vertices[first];
    second = state.canonical_vertices[second];
    if (first == second) return true;
    ulong key = self_edge_key(first, second);
    usz low;
    usz high = state.adjacent_vertices.len;
    while (low < high) {
        usz middle = low + (high - low) / 2;
        ulong found = state.adjacent_vertices[middle];
        if (found == key) return true;
        if (found < key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return false;
}

fn bool self_pair_excluded(ClothState* state, ClothCandidate candidate) @private {
    if (candidate.kind == SELF_VERTEX_FACE) {
        foreach (corner : state.faces[candidate.self_pair[1]].vertices) {
            if (self_vertices_adjacent(state, candidate.self_pair[0], corner)) return true;
        }
        return false;
    }
    ClothConstraint first = state.edges[candidate.self_pair[0]];
    ClothConstraint second = state.edges[candidate.self_pair[1]];
    return self_vertices_adjacent(state, first.first, second.first)
      || self_vertices_adjacent(state, first.first, second.second)
      || self_vertices_adjacent(state, first.second, second.first)
      || self_vertices_adjacent(state, first.second, second.second);
}

fn Aabb? self_bounds(
    ClothState* state,
    Vec3[] positions,
    uint[] vertices,
    float thickness,
) @private {
    Vec3 low = positions[vertices[0]];
    Vec3 high = low;
    foreach (vertex : vertices) {
        Vec3 position = positions[vertex];
        if (!finite_vector(position)) return CONTACT_PRECISION_EXCEEDED~;
        low = math::min(low, position);
        high = math::max(high, position);
        if (state.sweep_active) {
            low = math::min(low, state.sweep_bounds[vertex].min);
            high = math::max(high, state.sweep_bounds[vertex].max);
        }
    }
    Aabb result;
    for (uint axis = 0; axis < 3; axis++) {
        result.min[axis] = physics::contact_float_bound(physics::contact_subtract(
            physics::contact_value(low[axis]), physics::contact_value(thickness))!.min, false)!;
        result.max[axis] = physics::contact_float_bound(physics::contact_add(
            physics::contact_value(high[axis]), physics::contact_value(thickness))!.max, true)!;
    }
    return result;
}

fn usz? gather_self_candidates(ClothState* state, Vec3[] positions, usz count) @private {
    if (!state.desc.collisions.self_collision) return count;
    usz previous_count = count;
    defer {
        state.contact_result.candidates += (uint)(count - previous_count);
        state.contact_result.peak_candidates = math::max(state.contact_result.peak_candidates, (uint)count);
    }

    usz primitive_count;
    float thickness = state.desc.thickness;
    foreach (index, position : positions) {
        uint[1] vertices = { (uint)index };
        state.self_primitive_storage[primitive_count++] = {
            .bounds = self_bounds(
                state: state,
                positions: positions,
                vertices: vertices[..],
                thickness: thickness,
            )!,
            .index = (uint)index,
            .kind = VERTEX,
        };
    }
    foreach (index, edge : state.edges) {
        uint[2] vertices = { edge.first, edge.second };
        state.self_primitive_storage[primitive_count++] = {
            .bounds = self_bounds(
                state: state,
                positions: positions,
                vertices: vertices[..],
                thickness: thickness,
            )!,
            .index = (uint)index,
            .kind = EDGE,
        };
    }
    foreach (index, face : state.faces) {
        state.self_primitive_storage[primitive_count++] = {
            .bounds = self_bounds(
                state: state,
                positions: positions,
                vertices: face.vertices[..],
                thickness: thickness,
            )!,
            .index = (uint)index,
            .kind = FACE,
        };
    }

    state.self_primitives = state.self_primitive_storage[:primitive_count];
    sort::quicksort(state.self_primitives, &by_self_bound);
    foreach (index, first : state.self_primitives) {
        for (usz other = (usz)index + 1; other < state.self_primitives.len; other++) {
            ClothSelfPrimitive second = state.self_primitives[other];
            if (second.bounds.min.x > first.bounds.max.x) break;
            if (second.bounds.min.y > first.bounds.max.y || first.bounds.min.y > second.bounds.max.y
                || second.bounds.min.z > first.bounds.max.z || first.bounds.min.z > second.bounds.max.z) continue;

            ClothCandidate candidate;
            if (first.kind == VERTEX && second.kind == FACE) {
                candidate = { .kind = SELF_VERTEX_FACE, .self_pair = { first.index, second.index } };
            } else if (first.kind == FACE && second.kind == VERTEX) {
                candidate = { .kind = SELF_VERTEX_FACE, .self_pair = { second.index, first.index } };
            } else if (first.kind == EDGE && second.kind == EDGE) {
                candidate = { .kind = SELF_EDGE_EDGE, .self_pair = { math::min(first.index, second.index), math::max(first.index, second.index) } };
            } else {
                continue;
            }
            if (self_pair_excluded(state, candidate)) continue;
            if (count == state.candidates.len) return c3d::CAPACITY_EXCEEDED~;
            state.candidates[count++] = candidate;
        }
    }
    return count;
}

fn int by_self_bound(ClothSelfPrimitive first, ClothSelfPrimitive second) @private {
    if (first.bounds.min.x != second.bounds.min.x) return first.bounds.min.x < second.bounds.min.x ? -1 : 1;
    if (first.kind != second.kind) return first.kind < second.kind ? -1 : 1;
    if (first.index != second.index) return first.index < second.index ? -1 : 1;
    return 0;
}

fn double[2] self_edge_weights(
    ContactVector first_start,
    ContactVector first_end,
    ContactVector second_start,
    ContactVector second_end,
) @private {
    ContactVector first = first_end - first_start;
    ContactVector second = second_end - second_start;
    ContactVector relative = first_start - second_start;
    double first_squared = first.dot(first);
    double second_squared = second.dot(second);
    double mixed = first.dot(second);
    double first_offset = first.dot(relative);
    double second_offset = second.dot(relative);
    double denominator = first_squared * second_squared - mixed * mixed;
    if (denominator <= PARALLEL_EDGE_DENOMINATOR_TOLERANCE * first_squared * second_squared
        && first_squared > 0 && second_squared > 0) {
        double s0 = -first_offset / first_squared;
        double s1 = (mixed - first_offset) / first_squared;
        double low = math::max(0.0, math::min(s0, s1));
        double high = math::min(1.0, math::max(s0, s1));
        double along_first = low <= high ? 0.5 * (low + high) : math::clamp(0.5 * (s0 + s1), 0.0, 1.0);
        double along_second = math::clamp((mixed * along_first + second_offset) / second_squared, 0.0, 1.0);
        return { along_first, along_second };
    }
    double along_first = denominator > 0
      ? math::clamp((mixed * second_offset - first_offset * second_squared) / denominator, 0.0, 1.0) : 0;
    double along_second = second_squared > 0
      ? math::clamp((mixed * along_first + second_offset) / second_squared, 0.0, 1.0) : 0;
    if (first_squared > 0) along_first = math::clamp((mixed * along_second - first_offset) / first_squared, 0.0, 1.0);
    return { along_first, along_second };
}

fn ClothSelfContact? evaluate_self_contact(ClothState* state, ClothCandidate* candidate, Vec3[] positions) @local {
    ClothSelfContact result;
    double reach = 2.0 * state.desc.thickness;
    if (reach <= state.desc.collisions.contact_tolerance) return result;

    bool vertex_face = candidate.kind == SELF_VERTEX_FACE;
    if (vertex_face) {
        uint[3] corners = state.faces[candidate.self_pair[1]].vertices;
        result.vertices = { candidate.self_pair[0], corners[0], corners[1], corners[2] };
    } else {
        ClothConstraint first = state.edges[candidate.self_pair[0]];
        ClothConstraint second = state.edges[candidate.self_pair[1]];
        result.vertices = { first.first, first.second, second.first, second.second };
    }

    ContactVector[4] points;
    foreach (index, vertex : result.vertices) points[index] = (ContactVector)positions[vertex];
    ContactVector normal;
    if (vertex_face) {
        ContactVector weights = physics::contact_triangle_weights(
            point: points[0], first: points[1], second: points[2], third: points[3],
        );
        double sum = weights.x + weights.y + weights.z;
        if (!(sum > 0) || !math::is_finite(sum)) return CONTACT_PRECISION_EXCEEDED~;
        weights /= sum;
        result.coefficients = { 1, -weights.x, -weights.y, -weights.z };
        normal = points[0] - (points[1] * weights.x + points[2] * weights.y + points[3] * weights.z);
        if (normal.dot(normal) == 0) normal = (points[2] - points[1]).cross(points[3] - points[1]);
    } else {
        double[2] along = self_edge_weights(
            first_start: points[0], first_end: points[1], second_start: points[2], second_end: points[3],
        );
        result.coefficients = { 1 - along[0], along[0], -(1 - along[1]), -along[1] };
        normal = points[0] * (1 - along[0]) + points[1] * along[0] - points[2] * (1 - along[1]) - points[3] * along[1];
        if (normal.dot(normal) == 0) {
            ContactVector first_edge = points[1] - points[0];
            ContactVector second_edge = points[3] - points[2];
            normal = first_edge.cross(second_edge);
            if (normal.dot(normal) == 0) {
                ContactVector axis = first_edge.dot(first_edge) > 0 ? first_edge : second_edge;
                if (axis.dot(axis) > 0) {
                    axis /= axis.length();
                    ContactVector reference = math::abs(axis.y) < 0.9 ? (ContactVector){ 0, 1, 0 } : (ContactVector){ 1, 0, 0 };
                    normal = axis.cross(reference);
                }
            }
        }
    }

    ContactInterval length = physics::contact_length(physics::contact_vector(normal))!;
    if (!(length.min > 0)) return CONTACT_PRECISION_EXCEEDED~;
    result.normal = normal / math::sqrt(normal.dot(normal));

    double separation = double::max;
    uint first_count = vertex_face ? 1 : 2;
    for (uint first = 0; first < first_count; first++) {
        for (uint second = first_count; second < 4; second++) {
            ContactIntervals delta = physics::contact_vector_subtract(physics::contact_vector(points[first]), physics::contact_vector(points[second]))!;
            double lower = physics::contact_divide(physics::contact_dot(physics::contact_vector(normal), delta)!, length)!.min;
            separation = math::min(separation, lower);
        }
    }
    result.residual = math::max(0.0, reach - math::max(0.0, separation));
    return result;
}

fn double? self_contact_residual(ClothState* state, ClothCandidate* candidate, Vec3[] positions) @private {
    return evaluate_self_contact(state, candidate, positions)!.residual;
}

fn void? apply_self_contact(ClothState* state, ClothCandidate* candidate, Vec3[] positions) @private {
    ClothSelfContact contact = evaluate_self_contact(state, candidate, positions)!;
    float tolerance = state.desc.collisions.contact_tolerance;
    if (contact.residual <= tolerance) return;

    double denominator;
    foreach (index, vertex : contact.vertices) {
        double coefficient = contact.coefficients[index];
        denominator += state.inverse_masses[vertex] * coefficient * coefficient;
    }
    if (!(denominator > 0)) {
        state.contact_result.stage = ClothContactStage.RESOLVE;
        return CONTACT_UNRESOLVED~;
    }

    double displacement = (contact.residual + (double)tolerance / 4) / denominator;
    bool changed;
    foreach (index, vertex : contact.vertices) {
        double weight = state.inverse_masses[vertex];
        if (weight == 0) continue;
        ContactVector corrected = (ContactVector)positions[vertex] + contact.normal * (displacement * weight * contact.coefficients[index]);
        Vec3 rounded = (Vec3)corrected;
        if (!finite_vector(rounded) || ((ContactVector)rounded - corrected).length() > (double)tolerance / 8) return CONTACT_PRECISION_EXCEEDED~;
        changed |= rounded != positions[vertex];
        positions[vertex] = rounded;
    }
    if (!changed) return CONTACT_PRECISION_EXCEEDED~;
}
