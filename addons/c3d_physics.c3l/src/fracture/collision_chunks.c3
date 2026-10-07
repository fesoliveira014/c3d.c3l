module c3d::physics::fracture;

import c3d;
import std::sort;
import std::math;
import std::time;

const uint COLLISION_PLANE_DISTANCE_BITS @private = 5024;
$assert COLLISION_PLANE_DISTANCE_BITS <= EXACT_LIMBS * INTEGER_LIMB_BITS;

struct CollisionChunkPatch @private {
    BoundaryPatch boundary;
    bool flip;
    bool cut;
}

struct CollisionChunk @private {
    CollisionChunkPatch[] patches;
    CollisionChunk* next;
    uint component;
}

struct CollisionChunks @private {
    CollisionChunk* first;
    ExactPlane*[] cuts;
    uint count;
}

struct CollisionReflexEdge @local {
    uint[2] vertices;
    uint[2] faces;
    uint component;
}

struct CollisionReflexCuts @local {
    CollisionReflexEdge[] edges;
    uint[] vertices;
    uint[] face_components;
}

struct CollisionChunkConstraint @local {
    ExactPlane* plane;
    bool reversed;
}

struct CollisionChunkCut @local {
    ExactPlane* plane;
    CollisionChunkCut* next;
}
fn bool? within_collision_plane_distance(
    ExactScratch* scratch,
    ExactPlane* plane,
    PlaneTriple vertex,
    float resolution,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger*[HOMOGENEOUS_COMPONENTS] point;
    foreach (&component : point) *component = scratch.take()!;
    construct_point(scratch, point, vertex)!;

    WideInteger* distance = scratch.take()!;
    WideInteger* product = scratch.take()!;
    WideInteger* normal_squared = scratch.take()!;

    for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
        multiply_integer(product, point[axis].view(), plane.coefficients[axis].view())!;
        add_integer(distance, distance.view(), product.view())!;
        if (axis < SPACE_AXES) {
            multiply_integer(product, plane.coefficients[axis].view(), plane.coefficients[axis].view())!;
            add_integer(normal_squared, normal_squared.view(), product.view())!;
        }
    }

    WideInteger* epsilon = scratch.take()!;
    integer_from_float(epsilon, resolution);
    WideInteger* scale = scratch.take()!;
    multiply_integer(scale, epsilon.view(), point[SPACE_AXES].view())!;
    multiply_integer(product, scale.view(), scale.view())!;
    multiply_integer(scale, product.view(), normal_squared.view())!;
    multiply_integer(product, distance.view(), distance.view())!;
    return compare_magnitude(product.view(), scale.view()) <= 0;
}

fn int compare_collision_chunk_planes(ExactPlane* first, ExactPlane* second) @local {
    return compare_exact_planes(first, second);
}

fn ExactPlane*[]? collision_chunk_planes(SolidScratch* scratch, SourceConstructions* source) @local {
    ExactPlane*[] planes = reserve_elements(scratch, ExactPlane*, source.faces.len)!;
    foreach (index, &plane : source.faces) planes[index] = plane;
    sort::quicksort(planes, &compare_collision_chunk_planes);

    uint count;
    foreach (plane : planes) {
        if (!count || compare_exact_planes(planes[count - 1], plane)) planes[count++] = plane;
    }

    return planes[:count];
}

fn CollisionChunkPatch[]? collision_source_patches(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
) @private {
    CollisionChunkPatch[] patches = reserve_elements(scratch, CollisionChunkPatch, source.faces.len)!;

    foreach (uint face, &plane : source.faces) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        PlanarSegment[TRIANGLE_CORNERS] segments;
        foreach (uint corner, vertex : triangle) {
            SourceEdge* edge = &source.edges[source.corner_edges[face * TRIANGLE_CORNERS + corner]];
            segments[corner] = {
                .first = source.vertices[vertex], .second = source.vertices[triangle[(corner + 1) % TRIANGLE_CORNERS]],
                .line = { &source.faces[edge.owner_corner / TRIANGLE_CORNERS], &edge.plane },
            };
        }

        patches[face] = { .boundary = create_boundary_patch(
            scratch: scratch, plane: plane, segments: segments[..], reversed: source.reversed[face],
        )! };
    }

    return patches;
}

fn ExactPlane*[2] collision_patch_edge(BoundaryPatch* patch, uint first, uint second) @local {
    foreach (edge : patch.boundary.edges) {
        if ((edge.first == first && edge.second == second) || (edge.first == second && edge.second == first)) return edge.line;
    }
    unreachable();
}

fn CollisionChunkPatch? clip_collision_chunk_patch(
    SolidScratch* scratch,
    CollisionChunkPatch face,
    ExactPlane* cut,
    bool positive,
) @private {
    BoundaryPatch* patch = &face.boundary;
    bool negative;
    bool above;

    foreach (vertex : patch.boundary.vertices) {
        int side = plane_side(scratch.exact, cut, vertex)!;
        negative |= side < 0;
        above |= side > 0;
    }

    if (!negative && !above) {
        return (patch.reversed != face.flip) == positive ? face : (CollisionChunkPatch){};
    }
    if (!(positive ? negative : above)) return face;
    if (!(positive ? above : negative)) return {};

    FaceClipVertex[] input = reserve_elements(scratch, FaceClipVertex, patch.corners.len)!;
    FaceClipVertex[] output = reserve_elements(scratch, FaceClipVertex, 2 * patch.corners.len)!;
    PlanarSegment[] segments = reserve_elements(scratch, PlanarSegment, 2 * patch.corners.len)!;
    uint written;

    foreach (contour : patch.contours) {
        for (uint corner = 0; corner < contour.count; corner++) {
            uint order = face.flip && corner ? contour.count - corner : corner;
            uint prior = face.flip ? (order + 1) % contour.count : (order + contour.count - 1) % contour.count;
            uint vertex = patch.corners[contour.first + order];
            uint previous = patch.corners[contour.first + prior];
            input[corner] = {
                .point = patch.boundary.vertices[vertex], .incoming = collision_patch_edge(patch, previous, vertex),
            };
        }

        usz count = clip_face_polygon(
            scratch: scratch.exact, input: input[:contour.count], output: output,
            source: patch.plane, boundary: { .plane = cut, .reversed = positive },
        )!;
        if (count < TRIANGLE_CORNERS) continue;

        bool area;
        for (usz corner = 2; corner < count; corner++) {
            area |= planar_orientation(
                scratch: scratch.exact, vertices: { output[0].point, output[corner - 1].point, output[corner].point },
                dropped_axis: patch_projection(patch.plane),
            )! != 0;
        }
        if (!area) continue;

        for (usz corner = 0; corner < count; corner++) {
            FaceClipVertex next = output[(corner + 1) % count];
            segments[written++] = { .first = output[corner].point, .second = next.point, .line = next.incoming };
        }
    }

    if (!written) return {};

    return { .boundary = create_boundary_patch(
        scratch: scratch, plane: patch.plane, segments: segments[:written], reversed: patch.reversed != face.flip,
    )!, .cut = face.cut };
}

fn BoundaryPatch? collision_chunk_cap(
    SolidScratch* scratch,
    CollisionChunkPatch[] patches,
    ExactPlane* cut,
) @private {
    usz capacity;
    foreach (patch : patches) capacity += patch.boundary.boundary.edges.len;
    PlanarSegment[] segments = reserve_elements(scratch, PlanarSegment, capacity)!;
    uint count;

    foreach (face : patches) {
        foreach (edge : face.boundary.boundary.edges) {
            PlaneTriple first = face.boundary.boundary.vertices[edge.first];
            PlaneTriple second = face.boundary.boundary.vertices[edge.second];
            if (plane_side(scratch.exact, cut, first)! || plane_side(scratch.exact, cut, second)!) continue;

            bool reversed = (edge.weight < 0) != face.flip;
            segments[count++] = {
                .first = reversed ? first : second,
                .second = reversed ? second : first,
                .line = edge.line,
            };
        }
    }

    return create_boundary_patch(scratch: scratch, plane: cut, segments: segments[:count], reversed: false);
}
fn CollisionChunk*? split_collision_chunk(
    SolidScratch* scratch,
    CollisionChunk* chunk,
    ExactPlane* cut,
) @private {
    CollisionChunkPatch[] negative = reserve_elements(scratch, CollisionChunkPatch, chunk.patches.len + 1)!;
    CollisionChunkPatch[] positive = reserve_elements(scratch, CollisionChunkPatch, chunk.patches.len + 1)!;
    uint negative_count;
    uint positive_count;

    foreach (patch : chunk.patches) {
        CollisionChunkPatch clipped = clip_collision_chunk_patch(
            scratch: scratch, face: patch, cut: cut, positive: false,
        )!;
        if (clipped.boundary.corners.len) negative[negative_count++] = clipped;
        clipped = clip_collision_chunk_patch(scratch: scratch, face: patch, cut: cut, positive: true)!;
        if (clipped.boundary.corners.len) positive[positive_count++] = clipped;
    }

    if (!negative_count || !positive_count) return NUMERICAL_FAILURE~;

    BoundaryPatch cap = collision_chunk_cap(scratch, negative[:negative_count], cut)!;
    if (cap.corners.len) {
        negative[negative_count++] = { .boundary = cap, .cut = true };
        positive[positive_count++] = { .boundary = cap, .flip = true, .cut = true };
    }

    CollisionChunk* next = &reserve_elements(scratch, CollisionChunk, 1)![0];
    *next = { .patches = positive[:positive_count], .next = chunk.next, .component = chunk.component };
    *chunk = { .patches = negative[:negative_count], .next = next, .component = chunk.component };
    scratch.exact.statistics.cell_split_count++;

    return next;
}

fn int compare_collision_chunk_constraints(CollisionChunkConstraint first, CollisionChunkConstraint second) @local {
    int order = compare_exact_planes(first.plane, second.plane);
    if (order) return order;
    return first.reversed == second.reversed ? 0 : first.reversed ? 1 : -1;
}

fn bool? collision_chunk_convex(SolidScratch* scratch, CollisionChunk* chunk, float resolution) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    CollisionChunkConstraint[] constraints = reserve_elements(scratch, CollisionChunkConstraint, chunk.patches.len)!;
    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, chunk.patches.len)!;
    foreach (uint index, patch : chunk.patches) {
        constraints[index] = { .plane = patch.boundary.plane, .reversed = patch.boundary.reversed != patch.flip };
        patches[index] = patch.boundary;
    }
    sort::quicksort(constraints, &compare_collision_chunk_constraints);
    uint constraint_count;
    foreach (constraint : constraints) {
        if (!constraint_count || compare_collision_chunk_constraints(constraints[constraint_count - 1], constraint)) {
            constraints[constraint_count++] = constraint;
        }
    }

    BoundaryPointIndex points = index_boundary_points(scratch, patches)!;
    uint point_count;
    foreach (point : points.order) {
        bool same = point_count != 0;
        if (same) for (uint axis = 0; axis < SPACE_AXES; axis++) {
            if (compare_boundary_coordinate(
                scratch: scratch.exact,
                first: &points.points[points.order[point_count - 1]],
                second: &points.points[point],
                axis: axis,
            )!) {
                same = false;
                break;
            }
        }
        if (!same) points.order[point_count++] = point;
    }

    foreach (constraint : constraints[:constraint_count]) {
        foreach (point : points.order[:point_count]) {
            PlaneTriple vertex = points.points[point].vertex;
            int side = plane_side(scratch.exact, constraint.plane, vertex)!;
            if (!side || (side > 0) == constraint.reversed) continue;

            if (!within_collision_plane_distance(
                scratch: scratch.exact,
                plane: constraint.plane,
                vertex: vertex,
                resolution: resolution,
            )!) return false;
        }
    }
    return true;
}

fn ExactPlane*? choose_collision_chunk_split(
    SolidScratch* scratch,
    CollisionChunk* chunk,
    ExactPlane*[] planes,
    float resolution,
) @local {
    foreach (plane : planes) {
        bool negative;
        bool positive;

        foreach (patch : chunk.patches) {
            foreach (point : patch.boundary.boundary.vertices) {
                int side = plane_side(scratch.exact, plane, point)!;
                if (!side || (side < 0 ? negative : positive)) continue;
                if (within_collision_plane_distance(
                    scratch: scratch.exact,
                    plane: plane,
                    vertex: point,
                    resolution: resolution,
                )!) continue;

                negative |= side < 0;
                positive |= side > 0;
                if (negative && positive) return plane;
            }
        }
    }

    return null;
}
fn int compare_collision_source_vertices(uint first, uint second, SolidSurface* surface) @local {
    Vec3 left = surface_position(surface, first);
    Vec3 right = surface_position(surface, second);

    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint left_bits = bitcast(left[axis], uint);
        uint right_bits = bitcast(right[axis], uint);
        long left_key = left_bits & (uint::max >> 1);
        long right_key = right_bits & (uint::max >> 1);
        if (left_bits >> FLOAT_SIGN_BIT) left_key = -left_key;
        if (right_bits >> FLOAT_SIGN_BIT) right_key = -right_key;
        if (left_key != right_key) return left_key < right_key ? -1 : 1;
    }

    return first < second ? -1 : first > second ? 1 : 0;
}

fn int compare_collision_reflex_edges(CollisionReflexEdge first, CollisionReflexEdge second, SolidSurface* surface) @local {
    int order = compare_collision_source_vertices(first.vertices[0], second.vertices[0], surface);
    return order ? order : compare_collision_source_vertices(first.vertices[1], second.vertices[1], surface);
}

fn bool? resolvable_collision_reflex(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
    uint corner,
    float resolution,
) @local {
    uint twin = surface.topology.twins[corner];
    uint[2] corners = { corner, twin };

    foreach (uint index, first : corners) {
        uint opposite = corners[1 - index];
        uint face = first / TRIANGLE_CORNERS;
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, opposite / TRIANGLE_CORNERS);
        PlaneTriple point = source.vertices[triangle[(opposite + 2) % TRIANGLE_CORNERS]];
        int side = plane_side(scratch.exact, &source.faces[face], point)!;
        if (!side || (side > 0) == source.reversed[face]) continue;

        if (!within_collision_plane_distance(
            scratch: scratch.exact,
            plane: &source.faces[face],
            vertex: point,
            resolution: resolution,
        )!) return true;
    }

    return false;
}

fn CollisionReflexCuts? collision_reflex_candidates(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
    uint[] face_components,
    float resolution,
) @local {
    CollisionReflexCuts candidates = {
        .edges = reserve_elements(scratch, CollisionReflexEdge, source.edges.len)!,
        .vertices = reserve_elements(scratch, uint, surface.topology.vertices.len)!,
        .face_components = face_components,
    };
    uint count;

    foreach (edge : source.edges) {
        if (!resolvable_collision_reflex(
            scratch: scratch,
            surface: surface,
            source: source,
            corner: edge.owner_corner,
            resolution: resolution,
        )!) continue;

        uint[2] vertices = edge.vertices;
        if (compare_collision_source_vertices(vertices[0], vertices[1], surface) > 0) {
            vertices = { vertices[1], vertices[0] };
        }
        candidates.edges[count++] = {
            .vertices = vertices,
            .faces = { edge.owner_corner / TRIANGLE_CORNERS, surface.topology.twins[edge.owner_corner] / TRIANGLE_CORNERS },
            .component = face_components[edge.owner_corner / TRIANGLE_CORNERS],
        };
    }
    candidates.edges = candidates.edges[:count];
    sort::quicksort(candidates.edges, &compare_collision_reflex_edges, surface);

    count = 0;
    foreach (uint vertex, entry : surface.topology.vertices) {
        if (entry.degree) candidates.vertices[count++] = vertex;
    }
    candidates.vertices = candidates.vertices[:count];
    sort::quicksort(candidates.vertices, &compare_collision_source_vertices, surface);

    return candidates;
}

fn bool? collision_reflex_interior_vertex(
    ExactScratch* scratch,
    SourceConstructions* source,
    CollisionReflexEdge edge,
    uint vertex,
    float resolution,
) @local {
    foreach (face : edge.faces) {
        ExactPlane* plane = &source.faces[face];
        int side = plane_side(scratch, plane, source.vertices[vertex])!;
        if (!side || (side > 0) != source.reversed[face]) return false;

        if (within_collision_plane_distance(
            scratch: scratch,
            plane: plane,
            vertex: source.vertices[vertex],
            resolution: resolution,
        )!) return false;
    }

    return true;
}

fn ExactPlane*? try_collision_reflex_split(
    SolidScratch* scratch,
    CollisionChunk* chunk,
    SolidSurface* surface,
    SourceConstructions* source,
    CollisionReflexCuts candidates,
    float resolution,
) @local {
    foreach (edge : candidates.edges) {
        if (edge.component != chunk.component) continue;

        foreach (vertex : candidates.vertices) {
            uint face = surface.topology.vertices[vertex].corner / TRIANGLE_CORNERS;
            if (candidates.face_components[face] != chunk.component) continue;

            if (!collision_reflex_interior_vertex(
                scratch: scratch.exact,
                source: source,
                edge: edge,
                vertex: vertex,
                resolution: resolution,
            )!) continue;

            usz saved = scratch.used;
            ExactPlane* cut = &reserve_elements(scratch, ExactPlane, 1)![0];
            // Original float triples keep the exact coefficient bounds unchanged.
            (void)plane_from_float(scratch.exact, cut, {
                surface_position(surface, edge.vertices[0]),
                surface_position(surface, edge.vertices[1]),
                surface_position(surface, vertex),
            })!;

            ExactPlane* selected = choose_collision_chunk_split(
                scratch: scratch, chunk: chunk, planes: { cut }, resolution: resolution,
            )!;
            if (!selected) {
                scratch.used = saved;
                continue;
            }
            if (catch failure = split_collision_chunk(scratch, chunk, cut)) {
                scratch.used = saved;
                if (failure == c3d::CAPACITY_EXCEEDED) return failure~;
                continue;
            }

            return cut;
        }
    }

    return null;
}

fn uint[]? collision_source_components(SolidScratch* scratch, ValidatedSolid* solid) @local {
    SolidNesting* nesting = &solid.nesting;
    uint[] shells = reserve_elements(scratch, uint, nesting.shells.len)!;
    uint count;

    foreach (uint index, shell : nesting.shells) {
        if (!(shell.depth & 1)) shells[index] = count++;
    }
    foreach (uint index, shell : nesting.shells) {
        if (shell.depth & 1) shells[index] = shells[shell.parent];
    }

    uint[] faces = reserve_elements(scratch, uint, solid.surface.topology.shell_roots.len)!;
    foreach (uint face, root : solid.surface.topology.shell_roots) {
        faces[face] = shells[nesting.root_to_shell[root]];
    }

    return faces;
}

fn CollisionChunks? initial_collision_chunks(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
    uint[] face_components,
) @local {
    uint component_count;
    foreach (component : face_components) component_count = math::max(component_count, component + 1);
    CollisionChunk[] roots = reserve_elements(scratch, CollisionChunk, component_count)!;
    uint[] counts = reserve_elements(scratch, uint, component_count)!;
    counts[..] = 0;
    foreach (component : face_components) counts[component]++;

    foreach (uint component, &chunk : roots) {
        *chunk = {
            .patches = reserve_elements(scratch, CollisionChunkPatch, counts[component])!,
            .next = component + 1 < component_count ? &roots[component + 1] : null,
            .component = component,
        };
    }

    CollisionChunkPatch[] patches = collision_source_patches(scratch, surface, source)!;
    counts[..] = 0;
    foreach (uint face, patch : patches) {
        uint component = face_components[face];
        roots[component].patches[counts[component]++] = patch;
    }

    return { .first = &roots[0], .count = component_count };
}
fn CollisionChunks? partition_collision_chunks(
    SolidScratch* scratch,
    ValidatedSolid* solid,
    SourceConstructions* source,
    float resolution,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;

    SolidSurface* surface = &solid.surface;
    uint[] face_components = collision_source_components(scratch, solid)!;
    ExactPlane*[] planes = collision_chunk_planes(scratch, source)!;
    CollisionReflexCuts candidates = collision_reflex_candidates(
        scratch: scratch,
        surface: surface,
        source: source,
        face_components: face_components,
        resolution: resolution,
    )!;
    CollisionChunks chunks = initial_collision_chunks(
        scratch: scratch, surface: surface, source: source, face_components: face_components,
    )!;
    CollisionChunkCut* first_cut;
    uint cut_count;

    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
        while (!collision_chunk_convex(scratch, chunk, resolution)!) {
            ExactPlane* cut = try_collision_reflex_split(
                scratch: scratch,
                chunk: chunk,
                surface: surface,
                source: source,
                candidates: candidates,
                resolution: resolution,
            )!;

            uint next_plane;
            while (!cut && next_plane < planes.len) {
                cut = choose_collision_chunk_split(
                    scratch: scratch, chunk: chunk, planes: planes[next_plane..], resolution: resolution,
                )!;
                if (!cut) break;
                while (planes[next_plane++] != cut) {}

                usz retained = scratch.used;
                if (catch failure = split_collision_chunk(scratch, chunk, cut)) {
                    scratch.used = retained;
                    if (failure == c3d::CAPACITY_EXCEEDED) return failure~;
                    cut = null;
                }
            }
            if (!cut) break;
            if (chunks.count == uint::max) return c3d::CAPACITY_EXCEEDED~;
            chunks.count++;

            CollisionChunkCut* accepted = &reserve_elements(scratch, CollisionChunkCut, 1)![0];
            *accepted = { .plane = cut, .next = first_cut };
            first_cut = accepted;
            cut_count++;
        }
    }

    chunks.cuts = reserve_elements(scratch, ExactPlane*, cut_count)!;
    uint index;
    for (CollisionChunkCut* cut = first_cut; cut; cut = cut.next) chunks.cuts[index++] = cut.plane;
    sort::quicksort(chunks.cuts, &compare_collision_chunk_planes);

    cut_count = 0;
    foreach (plane : chunks.cuts) {
        if (!cut_count || compare_exact_planes(chunks.cuts[cut_count - 1], plane)) chunks.cuts[cut_count++] = plane;
    }
    chunks.cuts = chunks.cuts[:cut_count];

    return chunks;
}
