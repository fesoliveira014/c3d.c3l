module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::sort;

<* Default half-space projection passes per opening attempt. *>
const uint DEFAULT_OPENING_ITERATIONS = 32; // projection passes before OPENING_UNRESOLVED; cost linear in opening pairs per cut

<* Last execution status of an authored cut path. *>
enum ClothCutOutcome : uint {
    NONE,
    APPLIED,
    ALREADY_CUT,
    REFUSED,
}

<* Authored interior physical vertex sequence for cloth tearing. *>
struct ClothCutPath {
    uint   id;
    uint[] vertices;
    bool   strain_trigger;
    float  strain_threshold;
}

<* Prepared command and solver bounds for cloth tearing. *>
struct ClothTearLimits {
    uint max_requests;
    uint opening_iterations;
}

<* Last-result observation for one authored cut path. *>
struct ClothCutResult {
    uint              path_id;
    uint              attempts;
    ClothCutOutcome   outcome;
    bool              is_cut;
    fault             failure;
    ClothContactStage stage;
}

struct ClothInteriorEdge @private {
    uint            low_base;
    uint            high_base;
    uint            face0;
    uint            face1;
    uint            low_corner0;
    uint            high_corner0;
    uint            opposite_corner0;
    uint            low_corner1;
    uint            high_corner1;
    uint            opposite_corner1;
    uint            low_sector0;
    uint            high_sector0;
    uint            low_sector1;
    uint            high_sector1;
    bool            in_authored_cut;
    ClothConstraint base_edge;
    ClothConstraint base_bend;
    ClothHinge      base_hinge;
}

struct ClothCutPathMeta @private {
    uint  id;
    uint  edge_start;
    uint  edge_count;
    bool  strain_trigger;
    float strain_threshold;
}

struct ClothSectorPlan @private {
    uint                base_particle_count;
    uint                sector_count;
    uint                max_particles;
    uint                max_edges;
    uint                max_pins;
    uint                max_soft;
    uint                max_requests;
    uint                opening_iterations;
    uint[]              corner_sectors;
    uint[]              sector_bases;
    double[]            sector_shares;
    ClothConstraint[]   base_edges;
    ClothConstraint[]   initial_bends;
    ClothHinge[]        initial_hinges;
    ClothInteriorEdge[] interior_edges;
    ClothCutPathMeta[]  cut_paths;
    uint[]              cut_path_edges;
}

struct TearEdgeRecord @local {
    uint low;
    uint high;
    uint opposite;
    uint face;
    uint low_corner;
    uint high_corner;
    uint opposite_corner;
    bool forward;
}

<*
 Queue an explicit cut request for the next performed substep.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? Cloth.request_cut(&self, uint path) {
    if (!self.state) return c3d::INVALID_ARGUMENT~;
    return enqueue_state_cut(self.state, path);
}

<*
 Read the last execution result for an authored cut path.
 @return? c3d::INVALID_ARGUMENT
*>
fn ClothCutResult? Cloth.cut_result(&self, uint path) {
    if (!self.state) return c3d::INVALID_ARGUMENT~;
    return lookup_state_cut_result(self.state, path);
}

<*
 Queue an explicit cut request on one live crowd cloth placement.
 @return? NOT_FOUND, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? CrowdCloth.request_cut(
    &self,
    uint part,
    CrowdInstanceId instance,
    uint path,
) {
    ClothState* state = resolve_crowd_cut_state(self, part, instance)!;
    return enqueue_state_cut(state, path);
}

<*
 Read the last execution result for an authored cut path on one live crowd cloth placement.
 @return? NOT_FOUND, c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn ClothCutResult? CrowdCloth.cut_result(
    &self,
    uint part,
    CrowdInstanceId instance,
    uint path,
) {
    ClothState* state = resolve_crowd_cut_state(self, part, instance)!;
    return lookup_state_cut_result(state, path);
}

<* Default cloth tearing request capacity and opening iteration settings. *>
fn ClothTearLimits default_cloth_tear_limits() {
    return {
        .opening_iterations = DEFAULT_OPENING_ITERATIONS,
    };
}

fn ClothState*? resolve_crowd_cut_state(
    CrowdCloth* component,
    uint part,
    CrowdInstanceId instance,
) @local {
    if (!component.state) return c3d::INVALID_ARGUMENT~;
    CrowdClothPart* found = component.find_part(part)!;
    if (!found.prepared || !found.states.len) return c3d::INVALID_ARGUMENT~;
    if (!instance.generation || instance.index >= found.capacity) return c3d::INVALID_ID~;
    if (found.slot_generations[instance.index] != instance.generation) return c3d::INVALID_ID~;
    return found.states[instance.index];
}

fn void? enqueue_state_cut(ClothState* state, uint path) @local {
    if (path == 0 || !state.cut_paths.len) return c3d::INVALID_ARGUMENT~;
    uint found_index = uint::max;
    foreach (index, entry : state.cut_paths) {
        if (entry.id == path) {
            found_index = (uint)index;
            break;
        }
    }
    if (found_index == uint::max) return c3d::INVALID_ARGUMENT~;

    foreach (queued : state.pending_requests[:state.pending_request_count]) {
        if (queued == found_index) return;
    }
    if (state.pending_request_count == state.pending_requests.len) return c3d::CAPACITY_EXCEEDED~;
    state.pending_requests[state.pending_request_count++] = found_index;
}

fn ClothCutResult? lookup_state_cut_result(ClothState* state, uint path) @local {
    if (path == 0 || !state.cut_results.len) return c3d::INVALID_ARGUMENT~;
    foreach (result : state.cut_results) {
        if (result.path_id == path) return result;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn void? check_tear_desc(ClothDesc desc) @private {
    foreach (index, cut : desc.cuts) {
        if (cut.id == 0 || cut.vertices.len < 2) return c3d::INVALID_ARGUMENT~;
        if (cut.strain_trigger && (!math::is_finite(cut.strain_threshold) || !(cut.strain_threshold > 0))) {
            return c3d::INVALID_ARGUMENT~;
        }
        foreach (earlier : desc.cuts[:index]) {
            if (earlier.id == cut.id) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn uint union_find_root(uint[] parents, uint element) @local {
    uint root = element;
    while (parents[root] != root) root = parents[root];
    while (parents[element] != root) {
        uint next = parents[element];
        parents[element] = root;
        element = next;
    }
    return root;
}

fn void union_find_merge(uint[] parents, uint first_element, uint second_element) @local {
    uint first_root = union_find_root(parents, first_element);
    uint second_root = union_find_root(parents, second_element);
    if (first_root != second_root) {
        parents[math::max(first_root, second_root)] = math::min(first_root, second_root);
    }
}

fn bool same_tear_edge(TearEdgeRecord first, TearEdgeRecord second) @local {
    return first.low == second.low && first.high == second.high;
}

fn int by_tear_edge(TearEdgeRecord first, TearEdgeRecord second) @local {
    if (first.low != second.low) return first.low < second.low ? -1 : 1;
    if (first.high != second.high) return first.high < second.high ? -1 : 1;
    if (first.forward != second.forward) return first.forward ? -1 : 1;
    return 0;
}

fn int by_constraint_edge(ClothConstraint first, ClothConstraint second) @local {
    if (first.first != second.first) return first.first < second.first ? -1 : 1;
    if (first.second != second.second) return first.second < second.second ? -1 : 1;
    return 0;
}

fn int by_cut_path_id(ClothCutPathMeta first, ClothCutPathMeta second) @local {
    if (first.id != second.id) return first.id < second.id ? -1 : 1;
    return 0;
}

fn ClothSectorPlan? build_sector_plan(
    Geometry* data,
    uint[] render_to_particle,
    uint base_particle_count,
    uint pin_count,
    uint soft_count,
    Vec3[] rest_positions,
    Vec3[] edge_positions,
    Vec3[] world_positions,
    ClothDesc desc,
) @private {
    usz triangle_count = data.indices.len / 3;
    usz corner_count = data.indices.len;
    TearEdgeRecord[] records = alloc::new_array(tmem, TearEdgeRecord, (sz)corner_count);

    for (usz triangle = 0; triangle < triangle_count; triangle++) {
        uint corner0 = (uint)(3 * triangle);
        uint corner1 = (uint)(3 * triangle + 1);
        uint corner2 = (uint)(3 * triangle + 2);
        uint[3] corners = {
            render_to_particle[data.indices[corner0]],
            render_to_particle[data.indices[corner1]],
            render_to_particle[data.indices[corner2]],
        };
        if (corners[0] == corners[1] || corners[1] == corners[2] || corners[2] == corners[0]) {
            return c3d::INVALID_ARGUMENT~;
        }

        Vec3 rest_normal = (rest_positions[corners[1]] - rest_positions[corners[0]])
          .cross(rest_positions[corners[2]] - rest_positions[corners[0]]);
        if (rest_normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;

        if (edge_positions.len) {
            Vec3 edge_normal = (edge_positions[corners[1]] - edge_positions[corners[0]])
              .cross(edge_positions[corners[2]] - edge_positions[corners[0]]);
            if (edge_normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;
        }

        if (world_positions.len) {
            Vec3 world_normal = (world_positions[corners[1]] - world_positions[corners[0]])
              .cross(world_positions[corners[2]] - world_positions[corners[0]]);
            if (world_normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;
        }

        uint[3] raw_corners = { corner0, corner1, corner2 };
        for (uint side = 0; side < 3; side++) {
            uint first = corners[side];
            uint second = corners[(side + 1) % 3];
            uint first_corner = raw_corners[side];
            uint second_corner = raw_corners[(side + 1) % 3];
            uint opposite_corner = raw_corners[(side + 2) % 3];
            bool forward = first < second;
            records[3 * triangle + side] = {
                .low             = forward ? first : second,
                .high            = forward ? second : first,
                .opposite        = corners[(side + 2) % 3],
                .face            = (uint)triangle,
                .low_corner      = forward ? first_corner : second_corner,
                .high_corner     = forward ? second_corner : first_corner,
                .opposite_corner = opposite_corner,
                .forward         = forward,
            };
        }
    }

    sort::quicksort(records, &by_tear_edge);

    bool dihedral = desc.bend_mode == DIHEDRAL;
    bool has_cuts = desc.cuts.len > 0;
    usz edge_count;
    usz interior_count;
    for (usz start = 0; start < records.len;) {
        usz end = start + 1;
        while (end < records.len && same_tear_edge(records[start], records[end])) end++;
        if (end - start > 2) return c3d::INVALID_ARGUMENT~;
        if (end - start == 2) {
            if (((dihedral || has_cuts) && records[start].forward == records[start + 1].forward)
                || records[start].opposite == records[start + 1].opposite) {
                return c3d::INVALID_ARGUMENT~;
            }
            interior_count++;
        }
        edge_count++;
        start = end;
    }

    bool[] matched_overrides = alloc::new_array(tmem, bool, (sz)desc.rest_angles.len);
    foreach (override : desc.rest_angles) {
        if (override.second >= rest_positions.len) return c3d::INVALID_ARGUMENT~;
    }

    Vec3[] constraint_positions = edge_positions.len
      ? edge_positions
      : (world_positions.len ? world_positions : rest_positions);

    ClothConstraint[] base_edges = alloc::new_array(tmem, ClothConstraint, (sz)edge_count);
    ClothConstraint[] initial_bends = alloc::new_array(tmem, ClothConstraint, dihedral ? 0 : (sz)interior_count);
    ClothHinge[] initial_hinges = alloc::new_array(tmem, ClothHinge, dihedral ? (sz)interior_count : 0);
    ClothInteriorEdge[] interior_edges = alloc::new_array(
        tmem,
        ClothInteriorEdge,
        has_cuts ? (sz)interior_count : 0,
    );

    usz edge_index;
    usz interior_index;
    for (usz start = 0; start < records.len;) {
        usz end = start + 1;
        while (end < records.len && same_tear_edge(records[start], records[end])) end++;

        uint low = records[start].low;
        uint high = records[start].high;
        Vec3 delta = constraint_positions[high] - constraint_positions[low];
        float length = delta.length();
        ClothConstraint edge_constraint = {
            .first          = low,
            .second         = high,
            .rest_length    = length,
            .rest_direction = length > 0 ? delta / length : COLLAPSED_AXIS,
        };
        base_edges[edge_index++] = edge_constraint;

        if (end - start == 2) {
            uint p0 = low;
            uint p1 = high;
            uint p2 = records[start].opposite;
            uint p3 = records[start + 1].opposite;

            ClothConstraint bend_constraint;
            ClothHinge hinge_constraint;
            if (!dihedral) {
                if (has_cuts) {
                    uint bend_low = math::min(p2, p3);
                    uint bend_high = math::max(p2, p3);
                    Vec3 bend_delta = constraint_positions[bend_high] - constraint_positions[bend_low];
                    float bend_length = bend_delta.length();
                    bend_constraint = {
                        .first          = bend_low,
                        .second         = bend_high,
                        .rest_length    = bend_length,
                        .rest_direction = bend_length > 0 ? bend_delta / bend_length : COLLAPSED_AXIS,
                    };
                } else {
                    Vec3 bend_delta = constraint_positions[p3] - constraint_positions[p2];
                    float bend_length = bend_delta.length();
                    bend_constraint = {
                        .first          = p2,
                        .second         = p3,
                        .rest_length    = bend_length,
                        .rest_direction = bend_length > 0 ? bend_delta / bend_length : COLLAPSED_AXIS,
                    };
                }
                initial_bends[interior_index] = bend_constraint;
            } else {
                Vec3[4] rest_points = { rest_positions[p0], rest_positions[p1], rest_positions[p2], rest_positions[p3] };
                double? evaluated_rest = evaluate_hinge_angle(rest_points);
                if (catch evaluated_rest) return c3d::INVALID_ARGUMENT~;

                float rest_angle = (float)evaluated_rest;
                foreach (override_index, override : desc.rest_angles) {
                    if (override.first == p0 && override.second == p1) {
                        matched_overrides[override_index] = true;
                        rest_angle = override.angle;
                        break;
                    }
                }

                float last_angle = (float)evaluated_rest;
                Vec3[] initial_positions = world_positions.len ? world_positions : edge_positions;
                if (initial_positions.len) {
                    Vec3[4] world_points = {
                        initial_positions[p0],
                        initial_positions[p1],
                        initial_positions[p2],
                        initial_positions[p3],
                    };
                    double? evaluated_world = evaluate_hinge_angle(world_points);
                    if (catch evaluated_world) return c3d::INVALID_ARGUMENT~;
                    last_angle = (float)evaluated_world;
                }

                hinge_constraint = {
                    .p0         = p0,
                    .p1         = p1,
                    .p2         = p2,
                    .p3         = p3,
                    .rest_angle = rest_angle,
                    .last_angle = last_angle,
                    .lambda     = 0,
                };
                initial_hinges[interior_index] = hinge_constraint;
            }

            if (has_cuts) {
                interior_edges[interior_index] = {
                    .low_base         = p0,
                    .high_base        = p1,
                    .face0            = records[start].face,
                    .face1            = records[start + 1].face,
                    .low_corner0      = records[start].low_corner,
                    .high_corner0     = records[start].high_corner,
                    .opposite_corner0 = records[start].opposite_corner,
                    .low_corner1      = records[start + 1].low_corner,
                    .high_corner1     = records[start + 1].high_corner,
                    .opposite_corner1 = records[start + 1].opposite_corner,
                    .base_edge        = edge_constraint,
                    .base_bend        = bend_constraint,
                    .base_hinge       = hinge_constraint,
                };
            }
            interior_index++;
        }
        start = end;
    }

    foreach (matched : matched_overrides) {
        if (!matched) return c3d::INVALID_ARGUMENT~;
    }

    uint opening_iterations = desc.tears.opening_iterations > 0
      ? desc.tears.opening_iterations
      : DEFAULT_OPENING_ITERATIONS;

    if (!has_cuts) {
        return {
            .base_particle_count = base_particle_count,
            .sector_count        = 0,
            .max_particles       = base_particle_count,
            .max_edges           = (uint)edge_count,
            .max_pins            = pin_count,
            .max_soft            = soft_count,
            .max_requests        = 0,
            .opening_iterations  = opening_iterations,
            .base_edges          = base_edges,
            .initial_bends       = initial_bends,
            .initial_hinges      = initial_hinges,
        };
    }

    usz total_path_edges;
    foreach (cut : desc.cuts) {
        total_path_edges += cut.vertices.len - 1;
    }

    ClothCutPathMeta[] cut_paths = alloc::new_array(tmem, ClothCutPathMeta, (sz)desc.cuts.len);
    uint[] cut_path_edges = alloc::new_array(tmem, uint, (sz)total_path_edges);
    bool[] base_vertex_in_cut = alloc::new_array(tmem, bool, (sz)base_particle_count);

    usz path_edge_cursor;
    foreach (path_index, cut : desc.cuts) {
        bool closed = cut.vertices.len >= 4 && cut.vertices[cut.vertices.len - 1] == cut.vertices[0];
        if (!closed && cut.vertices[cut.vertices.len - 1] == cut.vertices[0]) {
            return c3d::INVALID_ARGUMENT~;
        }
        for (usz vertex_slot = 0; vertex_slot < cut.vertices.len; vertex_slot++) {
            uint vertex = cut.vertices[vertex_slot];
            if (vertex >= base_particle_count) return c3d::INVALID_ARGUMENT~;
            base_vertex_in_cut[vertex] = true;
            usz limit = (closed && vertex_slot == cut.vertices.len - 1) ? 0 : vertex_slot;
            for (usz earlier = (closed && vertex_slot == cut.vertices.len - 1) ? 1 : 0; earlier < limit; earlier++) {
                if (cut.vertices[earlier] == vertex) return c3d::INVALID_ARGUMENT~;
            }
        }

        uint edge_start = (uint)path_edge_cursor;
        uint segment_count = (uint)(cut.vertices.len - 1);
        for (uint segment = 0; segment < segment_count; segment++) {
            uint first_vertex = cut.vertices[segment];
            uint second_vertex = cut.vertices[segment + 1];
            if (first_vertex == second_vertex) return c3d::INVALID_ARGUMENT~;
            uint low = math::min(first_vertex, second_vertex);
            uint high = math::max(first_vertex, second_vertex);

            uint found_interior = uint::max;
            foreach (interior_slot, &interior_edge : interior_edges) {
                if (interior_edge.low_base == low && interior_edge.high_base == high) {
                    found_interior = (uint)interior_slot;
                    break;
                }
            }
            if (found_interior == uint::max) return c3d::INVALID_ARGUMENT~;

            for (uint previous = 0; previous < segment; previous++) {
                if (cut_path_edges[edge_start + previous] == found_interior) return c3d::INVALID_ARGUMENT~;
            }
            interior_edges[found_interior].in_authored_cut = true;
            cut_path_edges[path_edge_cursor++] = found_interior;
        }

        cut_paths[path_index] = {
            .id               = cut.id,
            .edge_start       = edge_start,
            .edge_count       = segment_count,
            .strain_trigger   = cut.strain_trigger,
            .strain_threshold = cut.strain_threshold,
        };
    }

    sort::quicksort(cut_paths, &by_cut_path_id);

    uint[] corner_sectors = alloc::new_array(tmem, uint, (sz)corner_count);
    uint sector_count = base_particle_count;

    uint[] union_parents = alloc::new_array(tmem, uint, (sz)corner_count);
    foreach (corner_index, &parent : union_parents) *parent = (uint)corner_index;

    foreach (&interior_edge : interior_edges) {
        if (!interior_edge.in_authored_cut) {
            union_find_merge(union_parents, interior_edge.low_corner0, interior_edge.low_corner1);
            union_find_merge(union_parents, interior_edge.high_corner0, interior_edge.high_corner1);
        }
    }

    uint[] root_sector = alloc::new_array(tmem, uint, (sz)corner_count);
    root_sector[..] = uint::max;
    bool[] base_assigned = alloc::new_array(tmem, bool, (sz)base_particle_count);

    for (usz corner_index = 0; corner_index < corner_count; corner_index++) {
        uint base_particle = render_to_particle[data.indices[corner_index]];
        if (!base_vertex_in_cut[base_particle]) {
            corner_sectors[corner_index] = base_particle;
            continue;
        }
        uint root = union_find_root(union_parents, (uint)corner_index);
        if (root_sector[root] == uint::max) {
            if (!base_assigned[base_particle]) {
                base_assigned[base_particle] = true;
                root_sector[root] = base_particle;
            } else {
                root_sector[root] = sector_count++;
            }
        }
        corner_sectors[corner_index] = root_sector[root];
    }

    uint[] sector_bases = alloc::new_array(tmem, uint, (sz)sector_count);
    double[] sector_shares = alloc::new_array(tmem, double, (sz)sector_count);
    for (uint particle = 0; particle < base_particle_count; particle++) {
        sector_bases[particle] = particle;
        sector_shares[particle] = 1.0;
    }
    foreach (corner_index, sector : corner_sectors) {
        sector_bases[sector] = render_to_particle[data.indices[corner_index]];
    }

    double[] sector_area = alloc::new_array(tmem, double, (sz)sector_count);
    double[] base_area = alloc::new_array(tmem, double, (sz)base_particle_count);
    for (usz face = 0; face < triangle_count; face++) {
        uint corner0 = (uint)(3 * face);
        uint corner1 = (uint)(3 * face + 1);
        uint corner2 = (uint)(3 * face + 2);
        uint p0 = render_to_particle[data.indices[corner0]];
        uint p1 = render_to_particle[data.indices[corner1]];
        uint p2 = render_to_particle[data.indices[corner2]];

        ContactVector rest0 = (ContactVector)rest_positions[p0];
        ContactVector rest1 = (ContactVector)rest_positions[p1];
        ContactVector rest2 = (ContactVector)rest_positions[p2];
        double area = 0.5 * (rest1 - rest0).cross(rest2 - rest0).length();
        if (!math::is_finite(area) || !(area > 0)) return c3d::INVALID_ARGUMENT~;

        uint[3] face_corners = { corner0, corner1, corner2 };
        uint[3] face_particles = { p0, p1, p2 };
        for (uint side = 0; side < 3; side++) {
            sector_area[corner_sectors[face_corners[side]]] += area;
            base_area[face_particles[side]] += area;
        }
    }

    for (uint sector = 0; sector < sector_count; sector++) {
        uint base_particle = sector_bases[sector];
        if (!(sector_area[sector] > 0) || !(base_area[base_particle] > 0)) return c3d::INVALID_ARGUMENT~;
        sector_shares[sector] = sector_area[sector] / base_area[base_particle];
        if (!math::is_finite(sector_shares[sector]) || !(sector_shares[sector] > 0)) return c3d::INVALID_ARGUMENT~;
    }

    foreach (&interior_edge : interior_edges) {
        interior_edge.low_sector0 = corner_sectors[interior_edge.low_corner0];
        interior_edge.high_sector0 = corner_sectors[interior_edge.high_corner0];
        interior_edge.low_sector1 = corner_sectors[interior_edge.low_corner1];
        interior_edge.high_sector1 = corner_sectors[interior_edge.high_corner1];
    }

    if (desc.collisions.self_collision && desc.seams.len > 0) {
        bool[] cut_adjacent = alloc::new_array(tmem, bool, (sz)base_particle_count);
        for (usz face = 0; face < triangle_count; face++) {
            uint p0 = render_to_particle[data.indices[3 * face]];
            uint p1 = render_to_particle[data.indices[3 * face + 1]];
            uint p2 = render_to_particle[data.indices[3 * face + 2]];
            if (base_vertex_in_cut[p0] || base_vertex_in_cut[p1] || base_vertex_in_cut[p2]) {
                cut_adjacent[p0] = true;
                cut_adjacent[p1] = true;
                cut_adjacent[p2] = true;
            }
        }

        foreach (seam : desc.seams) {
            uint first_particle = render_to_particle[seam.first];
            uint second_particle = render_to_particle[seam.second];
            if (cut_adjacent[first_particle] || cut_adjacent[second_particle]) return c3d::INVALID_ARGUMENT~;
        }
    }

    uint max_requests = desc.tears.max_requests > 0 ? desc.tears.max_requests : (uint)desc.cuts.len;

    return {
        .base_particle_count = base_particle_count,
        .sector_count        = sector_count,
        .max_particles       = sector_count,
        .max_edges           = (uint)corner_count,
        .max_pins            = pin_count ? sector_count : 0,
        .max_soft            = soft_count ? sector_count : 0,
        .max_requests        = max_requests,
        .opening_iterations  = opening_iterations,
        .corner_sectors      = corner_sectors,
        .sector_bases        = sector_bases,
        .sector_shares       = sector_shares,
        .base_edges          = base_edges,
        .initial_bends       = initial_bends,
        .initial_hinges      = initial_hinges,
        .interior_edges      = interior_edges,
        .cut_paths           = cut_paths,
        .cut_path_edges      = cut_path_edges,
    };
}

fn void seed_cloth_topology(
    ClothState* state,
    ClothSectorPlan* sector_plan,
    ClothMaterialPlan* material_plan,
    ClothAttachmentPlan* attachment_plan,
    Vec3[] rest,
    Vec3[] initial_positions,
) @private {
    uint particle_count = (uint)rest.len;
    state.render_to_particle[..] = material_plan.render_to_particle[..];
    state.particle_source_storage[:particle_count] = material_plan.particle_sources[..];
    if (state.desc.transport.len) {
        state.transport_storage[:particle_count] = state.desc.transport[..];
    } else {
        state.transport_storage[..] = 0;
    }

    state.rest_storage[:particle_count] = rest[..];
    state.solved_reference_storage[:particle_count] = initial_positions[..];
    state.current_reference_storage[:particle_count] = initial_positions[..];
    if (state.staged_current_reference.len) {
        state.staged_current_reference[:particle_count] = initial_positions[..];
    }
    state.position_storage[:particle_count] = initial_positions[..];
    state.predicted_storage[:particle_count] = initial_positions[..];
    state.acceleration_storage[..] = (Vec3){};
    state.published_storage[:particle_count] = initial_positions[..];
    if (state.desc.collisions.continuous) {
        state.sweep_start_storage[:particle_count] = initial_positions[..];
        foreach (index, point : initial_positions) {
            state.sweep_bounds_storage[index] = { .min = point, .max = point };
        }
    }

    state.corners[..] = material_plan.corners[..];
    state.triangle_uvs[..] = material_plan.triangle_uvs[..];
    state.material_particles[..] = material_plan.material_particles[..];
    state.material_normal_domains[..] = material_plan.material_normal_domains[..];
    state.material_reference_faces[..] = material_plan.material_reference_faces[..];
    if (state.desc.tangent_frame) {
        state.tangent_signs[..] = material_plan.tangent_signs[..];
        state.rest_tangents[..] = material_plan.rest_tangents[..];
        state.committed_tangents[..] = material_plan.initial_tangents[..];
        state.local_tangents[..] = material_plan.initial_tangents[..];
    }

    if (sector_plan.cut_paths.len) {
        foreach (pin : attachment_plan.pins) state.base_pinned[pin] = true;
        foreach (soft : attachment_plan.soft) {
            state.base_has_soft[soft.particle] = true;
            state.base_soft_compliance[soft.particle] = soft.effective_compliance;
        }

        state.corner_sectors[..] = sector_plan.corner_sectors[..];
        state.sector_bases[..] = sector_plan.sector_bases[..];
        state.sector_shares[..] = sector_plan.sector_shares[..];
        state.base_edges[..] = sector_plan.base_edges[..];
        state.interior_edges[..] = sector_plan.interior_edges[..];
        state.cut_paths[..] = sector_plan.cut_paths[..];
        state.cut_path_edges[..] = sector_plan.cut_path_edges[..];
        state.material_sectors[..] = material_plan.material_sectors[..];
        state.material_base_normal_domains[..] = material_plan.material_normal_domains[..];

        foreach (index, &cut_path : sector_plan.cut_paths) {
            state.cut_results[index] = { .path_id = cut_path.id };
            state.staged_cut_results[index] = { .path_id = cut_path.id };
        }
        foreach (sector, base_particle : sector_plan.sector_bases) {
            state.committed_sector_to_particle[sector] = base_particle;
            state.staged_sector_to_particle[sector] = base_particle;
        }

        apply_topology_mapping(
            state:              state,
            edge_cut:           state.committed_edge_cut,
            sector_to_particle: state.committed_sector_to_particle,
            is_staged:          false,
        );
    } else {
        state.inverse_mass_storage[:particle_count] = 1;
        state.pin_storage[..] = attachment_plan.pins[..];
        foreach (slot, pin : attachment_plan.pins) {
            state.inverse_mass_storage[pin] = 0;
            state.pin_anchor_storage[slot] = initial_positions[pin];
            state.pin_target_storage[slot] = initial_positions[pin];
        }

        state.soft_attachment_storage[..] = attachment_plan.soft[..];
        foreach (slot, attachment : attachment_plan.soft) {
            state.soft_anchor_storage[slot] = initial_positions[attachment.particle];
            state.soft_target_storage[slot] = initial_positions[attachment.particle];
            state.soft_lambda_storage[slot] = {};
        }

        state.edge_storage[..] = sector_plan.base_edges[..];
        state.bend_storage[..] = sector_plan.initial_bends[..];
        state.hinge_storage[..] = sector_plan.initial_hinges[..];
        rebind_active_slices(
            state:     state,
            is_staged: false,
            particles: particle_count,
            pins:      (uint)attachment_plan.pins.len,
            soft:      (uint)attachment_plan.soft.len,
            edges:     (uint)sector_plan.base_edges.len,
            bends:     (uint)sector_plan.initial_bends.len,
            hinges:    (uint)sector_plan.initial_hinges.len,
        );
        if (state.canonical_vertex_storage.len) build_self_topology(state);
        colour_edges(state);
    }

    state.committed_particle_count = state.active_particle_count;
    state.committed_pin_count = (uint)state.pins.len;
    state.committed_soft_count = (uint)state.soft_attachments.len;
    state.committed_edge_count = (uint)state.edges.len;
    state.committed_bend_count = (uint)state.bends.len;
    state.committed_hinge_count = (uint)state.hinges.len;
    state.staged_hinges[:state.committed_hinge_count] = state.hinges[..];
}

fn void rebind_active_slices(
    ClothState* state,
    bool is_staged,
    uint particles,
    uint pins,
    uint soft,
    uint edges,
    uint bends,
    uint hinges,
) @private {
    state.active_particle_count = particles;
    state.particle_sources = state.particle_source_storage[:particles];
    state.transport = state.transport_storage[:particles];
    state.rest = state.rest_storage[:particles];
    state.inverse_masses = state.inverse_mass_storage[:particles];
    if (state.particle_mass_storage.len) {
        state.particle_masses = state.particle_mass_storage[:particles];
    }
    state.pins = state.pin_storage[:pins];
    state.soft_attachments = state.soft_attachment_storage[:soft];
    state.edges = state.edge_storage[:edges];
    state.bends = state.bend_storage[:bends];
    state.particle_local = state.particle_local_storage[:particles];
    state.publication_roundtrip = state.publication_roundtrip_storage[:particles];

    if (state.canonical_vertex_storage.len) {
        state.canonical_vertices = state.canonical_vertex_storage[:particles];
    }
    if (state.sweep_start_storage.len) {
        state.sweep_start = state.sweep_start_storage[:particles];
        state.sweep_bounds = state.sweep_bounds_storage[:particles];
        state.path_heads = state.path_head_storage[:particles];
    }

    if (!is_staged) {
        state.solved_reference = state.solved_reference_storage[:particles];
        state.current_reference = state.current_reference_storage[:particles];
        state.positions = state.position_storage[:particles];
        state.velocities = state.velocity_storage[:particles];
        state.predicted = state.predicted_storage[:particles];
        state.accelerations = state.acceleration_storage[:particles];
        state.published = state.published_storage[:particles];
        state.pin_anchors = state.pin_anchor_storage[:pins];
        state.pin_targets = state.pin_target_storage[:pins];
        state.soft_anchors = state.soft_anchor_storage[:soft];
        state.soft_targets = state.soft_target_storage[:soft];
        state.soft_lambdas = state.soft_lambda_storage[:soft];
        state.hinges = state.hinge_storage[:hinges];
    } else {
        state.solved_reference = state.staged_solved_reference[:particles];
        state.current_reference = state.staged_current_reference.len
          ? state.staged_current_reference[:particles]
          : state.current_reference_storage[:particles];
        state.positions = state.staged_positions[:particles];
        state.velocities = state.staged_velocities[:particles];
        state.predicted = state.staged_predicted[:particles];
        state.accelerations = state.staged_accelerations[:particles];
        state.published = state.staged_published[:particles];
        state.pin_anchors = state.staged_pin_anchors[:pins];
        state.pin_targets = state.staged_pin_targets[:pins];
        state.soft_anchors = state.staged_soft_anchors[:soft];
        state.soft_targets = state.staged_soft_targets[:soft];
        state.soft_lambdas = state.soft_lambda_storage[:soft];
        state.hinges = state.staged_hinges[:hinges];
    }

    state.desc.pins = state.pins;
    state.desc.transport = state.transport;
}

fn ClothConstraint lookup_base_edge_constraint(
    ClothConstraint[] base_edges,
    uint base_first,
    uint base_second,
    uint active_low,
    uint active_high,
    uint low_base,
) @local {
    uint base_low = math::min(base_first, base_second);
    uint base_high = math::max(base_first, base_second);
    usz low;
    usz high = base_edges.len;
    while (low < high) {
        usz middle = low + (high - low) / 2;
        ClothConstraint constraint = base_edges[middle];
        if (constraint.first == base_low && constraint.second == base_high) {
            Vec3 direction = low_base == base_low ? constraint.rest_direction : -constraint.rest_direction;
            return {
                .first          = active_low,
                .second         = active_high,
                .rest_length    = constraint.rest_length,
                .rest_direction = direction,
            };
        }
        if (constraint.first < base_low || (constraint.first == base_low && constraint.second < base_high)) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return {
        .first          = active_low,
        .second         = active_high,
        .rest_length    = 0,
        .rest_direction = COLLAPSED_AXIS,
    };
}

fn void apply_topology_mapping(
    ClothState* state,
    bool[] edge_cut,
    uint[] sector_to_particle,
    bool is_staged,
    bool preserve_committed_hinges = false,
) @private {
    if (!state.cut_paths.len) return;

    uint max_particle;
    foreach (particle : sector_to_particle) {
        if (particle > max_particle) max_particle = particle;
    }
    uint particle_count = sector_to_particle.len ? max_particle + 1 : state.base_particle_count;

    state.particle_mass_storage[:particle_count] = 0;
    foreach (sector, active_particle : sector_to_particle) {
        uint base_particle = state.sector_bases[sector];
        state.particle_mass_storage[active_particle] += state.sector_shares[sector];
        state.particle_bases[active_particle] = base_particle;
        state.particle_source_storage[active_particle] = state.particle_source_storage[base_particle];
        state.rest_storage[active_particle] = state.rest_storage[base_particle];
        state.transport_storage[active_particle] = state.transport_storage[base_particle];
    }

    uint pin_count;
    uint soft_count;
    for (uint active_particle = 0; active_particle < particle_count; active_particle++) {
        uint base_particle = state.particle_bases[active_particle];
        if (state.base_pinned[base_particle]) {
            state.inverse_mass_storage[active_particle] = 0;
            uint slot = pin_count++;
            state.pin_storage[slot] = active_particle;
            if (is_staged) {
                state.staged_pin_anchors[slot] = state.staged_solved_reference[active_particle];
                state.staged_pin_targets[slot] = state.staged_current_reference[active_particle];
            } else {
                state.pin_anchor_storage[slot] = state.solved_reference_storage[active_particle];
                state.pin_target_storage[slot] = state.current_reference_storage[active_particle];
            }
        } else {
            state.inverse_mass_storage[active_particle] = (float)(1.0 / state.particle_mass_storage[active_particle]);
        }

        if (state.base_has_soft[base_particle]) {
            uint slot = soft_count++;
            float effective_compliance = (float)(
                (double)state.base_soft_compliance[base_particle] / state.particle_mass_storage[active_particle]
            );
            state.soft_attachment_storage[slot] = {
                .particle             = active_particle,
                .effective_compliance = effective_compliance,
            };
            if (is_staged) {
                state.staged_soft_anchors[slot] = state.staged_solved_reference[active_particle];
                state.staged_soft_targets[slot] = state.staged_current_reference[active_particle];
            } else {
                state.soft_anchor_storage[slot] = state.solved_reference_storage[active_particle];
                state.soft_target_storage[slot] = state.current_reference_storage[active_particle];
            }
            state.soft_lambda_storage[slot] = {};
        }
    }

    foreach (corner_index, &corner : state.corners) {
        corner.particle = sector_to_particle[state.corner_sectors[corner_index]];
    }
    foreach (material_vertex, &mapped_particle : state.material_particles) {
        *mapped_particle = sector_to_particle[state.material_sectors[material_vertex]];
    }

    reassign_normal_domains(state, particle_count);

    uint edge_count;
    usz raw_count;
    usz triangle_count = state.corners.len / 3;
    for (usz face = 0; face < triangle_count; face++) {
        for (usz side = 0; side < 3; side++) {
            uint first_particle = state.corners[3 * face + side].particle;
            uint second_particle = state.corners[3 * face + (side + 1) % 3].particle;
            uint low = math::min(first_particle, second_particle);
            uint high = math::max(first_particle, second_particle);
            state.edge_storage[raw_count++] = lookup_base_edge_constraint(
                base_edges:  state.base_edges,
                base_first:  state.particle_bases[first_particle],
                base_second: state.particle_bases[second_particle],
                active_low:  low,
                active_high: high,
                low_base:    state.particle_bases[low],
            );
        }
    }

    sort::quicksort(state.edge_storage[:raw_count], &by_constraint_edge);

    for (usz index = 0; index < raw_count; index++) {
        if (!edge_count
            || state.edge_storage[edge_count - 1].first != state.edge_storage[index].first
            || state.edge_storage[edge_count - 1].second != state.edge_storage[index].second) {
            state.edge_storage[edge_count++] = state.edge_storage[index];
        }
    }

    uint bend_count;
    uint hinge_count;
    bool dihedral = state.desc.bend_mode == DIHEDRAL;
    if (dihedral && preserve_committed_hinges) {
        hinge_count = state.committed_hinge_count;
    } else {
        usz old_hinge_index;
        foreach (interior_index, &interior_edge : state.interior_edges) {
            uint p0 = sector_to_particle[interior_edge.low_sector0];
            uint p1 = sector_to_particle[interior_edge.high_sector0];
            uint p2 = sector_to_particle[state.corner_sectors[interior_edge.opposite_corner0]];
            uint p3 = sector_to_particle[state.corner_sectors[interior_edge.opposite_corner1]];
            if (!dihedral) {
                if (edge_cut[interior_index]) continue;
                ClothConstraint bend = interior_edge.base_bend;
                uint low = math::min(p2, p3);
                uint high = math::max(p2, p3);
                if (state.particle_bases[low] != interior_edge.base_bend.first) {
                    bend.rest_direction = -bend.rest_direction;
                }
                bend.first = low;
                bend.second = high;
                state.bend_storage[bend_count++] = bend;
            } else {
                ClothHinge hinge = interior_edge.base_hinge;

                if (is_staged && old_hinge_index < state.hinges.len) {
                    ClothHinge existing = state.hinges[old_hinge_index];
                    if (state.particle_bases[existing.p0] == interior_edge.low_base
                        && state.particle_bases[existing.p1] == interior_edge.high_base
                        && state.particle_bases[existing.p2] == interior_edge.base_hinge.p2
                        && state.particle_bases[existing.p3] == interior_edge.base_hinge.p3) {
                        hinge.last_angle = existing.last_angle;
                        hinge.lambda = existing.lambda;
                        old_hinge_index++;
                    }
                }

                if (edge_cut[interior_index]) continue;

                hinge.p0 = p0;
                hinge.p1 = p1;
                hinge.p2 = p2;
                hinge.p3 = p3;

                if (is_staged) {
                    state.staged_hinges[hinge_count++] = hinge;
                } else {
                    state.hinge_storage[hinge_count++] = hinge;
                }
            }
        }
    }

    rebind_active_slices(
        state:     state,
        is_staged: is_staged,
        particles: particle_count,
        pins:      pin_count,
        soft:      soft_count,
        edges:     edge_count,
        bends:     bend_count,
        hinges:    hinge_count,
    );

    if (state.canonical_vertex_storage.len) {
        build_self_topology(state);
    }
}

fn void reassign_normal_domains(ClothState* state, uint particle_count) @local {
    uint base_count = state.base_particle_count;
    uint max_base_domain;
    foreach (base_domain : state.material_base_normal_domains) {
        if (base_domain > max_base_domain) max_base_domain = base_domain;
    }
    uint next_domain = max_base_domain + 1;

    uint[] first_split_vertex = state.sector_scratch;
    uint[] next_split_vertex = state.sector_root_scratch;
    first_split_vertex[:particle_count] = uint::max;

    foreach (material_vertex, active_particle : state.material_particles) {
        uint base_domain = state.material_base_normal_domains[material_vertex];
        if (active_particle < base_count) {
            state.material_normal_domains[material_vertex] = base_domain;
            continue;
        }
        uint assigned = uint::max;
        for (uint earlier = first_split_vertex[active_particle];
             earlier != uint::max;
             earlier = next_split_vertex[earlier]) {
            if (state.material_base_normal_domains[earlier] == base_domain) {
                assigned = state.material_normal_domains[earlier];
                break;
            }
        }
        if (assigned == uint::max) {
            assigned = next_domain++;
            next_split_vertex[material_vertex] = first_split_vertex[active_particle];
            first_split_vertex[active_particle] = (uint)material_vertex;
        }
        state.material_normal_domains[material_vertex] = assigned;
    }

    foreach (&corner : state.corners) {
        corner.normal_domain = state.material_normal_domains[corner.material_vertex];
    }
}

fn void restore_committed_topology(ClothState* state) @private {
    if (!state.topology_dirty) return;
    apply_topology_mapping(
        state:                     state,
        edge_cut:                  state.committed_edge_cut,
        sector_to_particle:        state.committed_sector_to_particle,
        is_staged:                 false,
        preserve_committed_hinges: true,
    );
    state.topology_dirty = false;
}

fn void commit_staged_topology(ClothState* state, ClothState* staged) @private {
    if (state.cut_paths.len) {
        state.committed_edge_cut[..] = staged.staged_edge_cut[..];
        state.committed_sector_to_particle[..] = staged.staged_sector_to_particle[..];
        state.cut_results[..] = staged.staged_cut_results[..];
        state.pending_request_count = staged.pending_request_count;

        if (staged.desc.bend_mode == DIHEDRAL && staged.hinges.len) {
            usz hinge_index;
            foreach (interior_index, &interior_edge : state.interior_edges) {
                if (state.committed_edge_cut[interior_index]) continue;
                if (hinge_index < staged.hinges.len) {
                    interior_edge.base_hinge.last_angle = staged.hinges[hinge_index].last_angle;
                    interior_edge.base_hinge.lambda = 0;
                    hinge_index++;
                }
            }
        }
    }

    state.committed_particle_count = staged.active_particle_count;
    state.committed_pin_count = (uint)staged.pins.len;
    state.committed_soft_count = (uint)staged.soft_attachments.len;
    state.committed_edge_count = (uint)staged.edges.len;
    state.committed_bend_count = (uint)staged.bends.len;
    state.committed_hinge_count = (uint)staged.hinges.len;
    state.topology_dirty = false;

    rebind_active_slices(
        state:     state,
        is_staged: false,
        particles: state.committed_particle_count,
        pins:      state.committed_pin_count,
        soft:      state.committed_soft_count,
        edges:     state.committed_edge_count,
        bends:     state.committed_bend_count,
        hinges:    state.committed_hinge_count,
    );
}

fn void record_refused_cuts(
    ClothState* state,
    ClothState* staged,
    fault excuse,
) @private {
    if (!state.cut_paths.len) return;

    if (staged.pending_request_count > 0) {
        foreach (request_index : staged.pending_requests[:staged.pending_request_count]) {
            ClothCutResult* staged_result = &staged.staged_cut_results[request_index];
            if (staged_result.attempts == state.cut_results[request_index].attempts) {
                staged_result.attempts++;
            }
            staged_result.outcome = ClothCutOutcome.REFUSED;
            staged_result.failure = excuse;
            staged_result.stage = staged.contact_result.stage;
            staged_result.is_cut = state.cut_results[request_index].is_cut;
        }
        staged.pending_request_count = 0;
    }

    foreach (path_index, &committed : state.cut_results) {
        ClothCutResult staged_result = staged.staged_cut_results[path_index];
        if (staged_result.attempts > committed.attempts) {
            committed.attempts = staged_result.attempts;
            committed.outcome = ClothCutOutcome.REFUSED;
            committed.failure = excuse;
            committed.stage = staged.contact_result.stage;
        }
    }
    state.pending_request_count = staged.pending_request_count;
}

fn bool split_topology_sectors(ClothState* state) @private {
    uint sector_count = (uint)state.sector_bases.len;
    uint old_particle_count = state.active_particle_count;

    for (uint particle = 0; particle < old_particle_count; particle++) {
        state.split_parents[particle] = particle;
    }

    uint[] union_parents = state.sector_scratch[:sector_count];
    for (uint sector = 0; sector < sector_count; sector++) union_parents[sector] = sector;

    foreach (interior_index, &interior_edge : state.interior_edges) {
        if (!state.staged_edge_cut[interior_index]) {
            if (interior_edge.low_sector0 != interior_edge.low_sector1) {
                union_find_merge(union_parents, interior_edge.low_sector0, interior_edge.low_sector1);
            }
            if (interior_edge.high_sector0 != interior_edge.high_sector1) {
                union_find_merge(union_parents, interior_edge.high_sector0, interior_edge.high_sector1);
            }
        }
    }

    uint[] first_root = state.sector_root_scratch[:old_particle_count];
    first_root[..] = uint::max;
    uint[] root_particle = state.split_group_members[:sector_count];
    root_particle[..] = uint::max;

    uint next_particle = old_particle_count;
    for (uint sector = 0; sector < sector_count; sector++) {
        uint old_particle = state.staged_sector_to_particle[sector];
        uint root = union_find_root(union_parents, sector);
        if (first_root[old_particle] == uint::max) {
            first_root[old_particle] = root;
            root_particle[root] = old_particle;
            continue;
        }
        if (root == first_root[old_particle]) continue;

        uint assigned = root_particle[root];
        if (assigned == uint::max) {
            assigned = next_particle++;
            root_particle[root] = assigned;
            state.split_parents[assigned] = old_particle;
            state.staged_solved_reference[assigned] = state.staged_solved_reference[old_particle];
            state.staged_current_reference[assigned] = state.staged_current_reference[old_particle];
            state.staged_positions[assigned] = state.staged_positions[old_particle];
            state.staged_velocities[assigned] = state.staged_velocities[old_particle];
            state.staged_predicted[assigned] = state.staged_predicted[old_particle];
            state.staged_accelerations[assigned] = state.staged_accelerations[old_particle];
            state.staged_published[assigned] = state.staged_published[old_particle];
            if (state.sweep_start_storage.len) {
                state.sweep_start_storage[assigned] = state.sweep_start_storage[old_particle];
                state.sweep_bounds_storage[assigned] = state.sweep_bounds_storage[old_particle];
            }
        }
        state.staged_sector_to_particle[sector] = assigned;
    }

    state.topology_dirty = true;
    apply_topology_mapping(
        state:              state,
        edge_cut:           state.staged_edge_cut,
        sector_to_particle: state.staged_sector_to_particle,
        is_staged:          true,
    );

    return next_particle > old_particle_count;
}
