module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

const uint COLLISION_TETRAHEDRON_VERTICES @private = 4;
const uint COLLISION_FLOAT_MAGNITUDE_MASK @local = uint::max >> 1;

<* Borrow one convex point set in its piece frame. *>
struct FractureHullView {
    uint piece_index;
    Vec3[] points;
}

<* Own convex hull input geometry grouped by physical piece. *>
struct FractureCollision {
    Allocator allocator;
    FractureHullView[] hulls;
    char[] storage;
}

struct CollisionHullLink @private {
    FractureHullView hull;
    CollisionHullLink* next;
}

struct CollisionBuild @private {
    FractureLimits limits;
    CollisionHullLink* first;
    CollisionHullLink* last;
    uint hull_count;
    uint vertex_count;
}

$assert FractureHullView::alignment >= Vec3::alignment;

<*
 Partition fragments into bounded convex collision hulls.
 @param [&inout] workspace : "Exclusively borrowed for this call."
 @param [&in] fragments : "Live result; geometry remains unchanged."
 @param max_hull_vertices : "At least four; matches the consumer limit."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, NUMERICAL_FAILURE
*>
fn FractureCollision? create_fracture_collision(
    Allocator allocator,
    FractureWorkspace* workspace,
    FractureResult* fragments,
    uint max_hull_vertices,
) {
    if (max_hull_vertices < COLLISION_TETRAHEDRON_VERTICES) return c3d::INVALID_ARGUMENT~;
    if (fragments.pieces.len > workspace.limits.max_pieces) return c3d::CAPACITY_EXCEEDED~;
    SolidScratch scratch = begin_solid_scratch(workspace);
    CollisionBuild build = { .limits = workspace.limits };
    foreach (uint piece, source : fragments.pieces) {
        if (catch failure = build_collision_piece(
            scratch: &scratch, build: &build, piece: piece,
            source: source.mesh, max_hull_vertices: max_hull_vertices,
        )) {
            if (failure == c3d::CAPACITY_EXCEEDED) return failure~;
            return NUMERICAL_FAILURE~;
        }
    }
    return copy_collision_hulls(allocator, &build);
}

<*
 Release collision storage and invalidate every hull view.
 @param [&inout] collision : "Sole owning result."
*>
fn void destroy_fracture_collision(FractureCollision* collision) {
    alloc::free_aligned(collision.allocator, collision.storage.ptr);
    *collision = {};
}

fn FractureCollision? copy_collision_hulls(Allocator allocator, CollisionBuild* build) @private {
    if (build.hull_count > (usz)sz::max / FractureHullView::size) return c3d::CAPACITY_EXCEEDED~;
    usz header_bytes = (usz)build.hull_count * FractureHullView::size;
    usz padding = (Vec3::alignment - header_bytes % Vec3::alignment) % Vec3::alignment;
    if (padding > (usz)sz::max - header_bytes) return c3d::CAPACITY_EXCEEDED~;
    usz points_offset = header_bytes + padding;
    if (build.vertex_count > ((usz)sz::max - points_offset) / Vec3::size) return c3d::CAPACITY_EXCEEDED~;
    usz bytes = math::max(points_offset + (usz)build.vertex_count * Vec3::size, (usz)1);
    char*? storage = alloc::calloc_aligned(allocator, (sz)bytes, FractureHullView::alignment);
    if (catch storage) return c3d::CAPACITY_EXCEEDED~;
    FractureCollision result = { .allocator = allocator, .storage = storage[:bytes] };
    if (!build.hull_count) return result;
    result.hulls = ((FractureHullView*)result.storage.ptr)[:build.hull_count];
    Vec3* positions = (Vec3*)(result.storage.ptr + points_offset);
    uint index;
    for (CollisionHullLink* link = build.first; link; link = link.next) {
        result.hulls[index] = { .piece_index = link.hull.piece_index, .points = positions[:link.hull.points.len] };
        result.hulls[index].points[..] = link.hull.points[..];
        positions += link.hull.points.len;
        index++;
    }
    sort::quicksort(result.hulls, &compare_collision_hulls);
    return result;
}

fn int compare_collision_positions(Vec3 first, Vec3 second) @private {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint left_bits = bitcast(first[axis], uint);
        uint right_bits = bitcast(second[axis], uint);
        long left = left_bits >> FLOAT_SIGN_BIT ? -(long)(left_bits & COLLISION_FLOAT_MAGNITUDE_MASK) : (long)left_bits;
        long right = right_bits >> FLOAT_SIGN_BIT ? -(long)(right_bits & COLLISION_FLOAT_MAGNITUDE_MASK) : (long)right_bits;
        if (left != right) return left < right ? -1 : 1;
    }
    return 0;
}

fn int compare_collision_hulls(FractureHullView first, FractureHullView second) @private {
    if (first.piece_index != second.piece_index) return first.piece_index < second.piece_index ? -1 : 1;
    usz count = (usz)math::min(first.points.len, second.points.len);
    for (usz index = 0; index < count; index++) {
        int order = compare_collision_positions(first.points[index], second.points[index]);
        if (order) return order;
    }
    return first.points.len < second.points.len ? -1 : first.points.len > second.points.len ? 1 : 0;
}

fn void? append_collision_hull(
    SolidScratch* scratch,
    CollisionBuild* build,
    uint piece,
    Vec3[] points,
) @private {
    if (build.hull_count == build.limits.max_hulls
        || points.len > (usz)(build.limits.max_vertices - build.vertex_count)) return c3d::CAPACITY_EXCEEDED~;
    CollisionHullLink* link = &reserve_elements(scratch, CollisionHullLink, 1)![0];
    sort::quicksort(points, &compare_collision_positions);
    *link = { .hull = { .piece_index = piece, .points = points } };
    if (build.last) {
        build.last.next = link;
    } else {
        build.first = link;
    }
    build.last = link;
    build.hull_count++;
    build.vertex_count += (uint)points.len;
    return;
}

fn uint collision_patch_index(CollisionSurfaceSet* surfaces, OrientedPatchTriangles face) @private {
    return (uint)(((uptr)face.shared - (uptr)surfaces.triangles.ptr) / PatchTriangles::size);
}

fn uint[]? collision_surface_indices(
    SolidScratch* scratch,
    CollisionSurfaceSet* surfaces,
    SurfacePointMap* points,
    OrientedPatchTriangles[] faces,
) @private {
    usz count;
    foreach (face : faces) count += face.shared.triangles.len;
    if (count > uint::max / TRIANGLE_CORNERS) return c3d::CAPACITY_EXCEEDED~;
    uint[] indices = reserve_elements(scratch, uint, count * TRIANGLE_CORNERS)!;
    uint written;
    foreach (face : faces) {
        uint patch = collision_patch_index(surfaces, face);
        for (uint triangle = 0; triangle < face.shared.triangles.len; triangle++) {
            uint[TRIANGLE_CORNERS] corners = oriented_patch_triangle(face, triangle);
            foreach (corner : corners) indices[written++] = points.vertices[points.patch_offsets[patch] + corner];
        }
    }
    return indices;
}

fn OrientedPatchTriangles[]? collision_exterior_faces(
    SolidScratch* scratch,
    CollisionSurfaceSet* surfaces,
) @private {
    uint[] counts = reserve_elements(scratch, uint, surfaces.patches.len)!;
    bool[] reversed = reserve_elements(scratch, bool, surfaces.patches.len)!;
    counts[..] = 0;
    foreach (cell : surfaces.cells) {
        foreach (face : cell.faces) {
            uint patch = collision_patch_index(surfaces, face);
            if (counts[patch] == 2 || (counts[patch] == 1 && reversed[patch] == face.reversed)) {
                return NUMERICAL_FAILURE~;
            }
            reversed[patch] = face.reversed;
            counts[patch]++;
        }
    }
    uint count;
    foreach (uses : counts) count += uses == 1 ? 1 : 0;
    OrientedPatchTriangles[] faces = reserve_elements(scratch, OrientedPatchTriangles, count)!;
    count = 0;
    foreach (uint index, uses : counts) {
        if (!uses) return NUMERICAL_FAILURE~;
        if (uses == 1) faces[count++] = { .shared = &surfaces.triangles[index], .reversed = reversed[index] };
    }
    return faces;
}

fn Vec3[]? collision_hull_points(SolidScratch* scratch, Vec3[] positions, uint[] indices) @private {
    bool[] used = reserve_elements(scratch, bool, positions.len)!;
    used[..] = false;
    foreach (index : indices) used[index] = true;
    uint count;
    foreach (point : used) count += point ? 1 : 0;
    Vec3[] result = reserve_elements(scratch, Vec3, count)!;
    count = 0;
    foreach (uint index, point : used) if (point) result[count++] = positions[index];
    return result;
}

fn bool? collision_existing_cones(
    ExactScratch* scratch,
    SurfacePointMap* points,
    uint[] indices,
    uint anchor,
) @private {
    bool valid = true;
    for (usz first = 0; first < indices.len; first += TRIANGLE_CORNERS) {
        PlaneTriple[HOMOGENEOUS_COMPONENTS] exact;
        Vec3[HOMOGENEOUS_COMPONENTS] positions;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            exact[corner] = points.exact[indices[first + corner]];
            positions[corner] = points.positions[indices[first + corner]];
        }
        exact[TRIANGLE_CORNERS] = points.exact[anchor];
        positions[TRIANGLE_CORNERS] = points.positions[anchor];
        if (catch failure = check_collision_cone(scratch, exact, positions)) {
            if (failure != NUMERICAL_FAILURE) return failure~;
            valid = false;
        }
    }
    return valid;
}

fn void? publish_collision_cell(
    SolidScratch* scratch,
    CollisionBuild* build,
    uint piece,
    CollisionSurface* surface,
    SurfacePointMap* points,
    uint[] indices,
    CollisionMeshValidation checked,
    uint max_hull_vertices,
) @private {
    uint anchor = uint::max;
    foreach (index : indices) anchor = math::min(anchor, index);
    bool existing = collision_existing_cones(
        scratch: scratch.exact, points: points, indices: indices, anchor: anchor,
    )!;
    Vec3 origin = existing ? points.positions[anchor] : checked.centroid;
    if (!existing) {
        for (usz first = 0; first < indices.len; first += TRIANGLE_CORNERS) {
            if (float_orientation(scratch.exact, {
                points.positions[indices[first]], points.positions[indices[first + 1]],
                points.positions[indices[first + 2]], origin,
            })! >= 0) return NUMERICAL_FAILURE~;
        }
    }
    Vec3[] vertices = collision_hull_points(scratch, points.positions, indices)!;
    if (checked.convex && vertices.len <= max_hull_vertices) {
        return append_collision_hull(
            scratch: scratch, build: build, piece: piece, points: vertices,
        );
    }
    if (existing) {
        CollisionTetrahedra tetrahedra = tetrahedralize_collision_surface(scratch, surface)!;
        foreach (tetrahedron : tetrahedra.tetrahedra) {
            Vec3[] tetrahedron_points = reserve_elements(scratch, Vec3, COLLISION_TETRAHEDRON_VERTICES)!;
            foreach (uint corner, vertex : tetrahedron.vertices) {
                uint index = collision_point_index(scratch.exact, points, vertex)!;
                tetrahedron_points[corner] = points.positions[index];
            }
            append_collision_hull(
                scratch: scratch, build: build, piece: piece, points: tetrahedron_points,
            )!;
        }
        return;
    }
    for (usz first = 0; first < indices.len; first += TRIANGLE_CORNERS) {
        Vec3[HOMOGENEOUS_COMPONENTS] tetrahedron = {
            points.positions[indices[first]], points.positions[indices[first + 1]],
            points.positions[indices[first + 2]], origin,
        };
        if (!float_orientation(scratch.exact, tetrahedron)!) continue;
        Vec3[] tetrahedron_points = reserve_elements(scratch, Vec3, COLLISION_TETRAHEDRON_VERTICES)!;
        tetrahedron_points[..] = tetrahedron[..];
        append_collision_hull(
            scratch: scratch, build: build, piece: piece, points: tetrahedron_points,
        )!;
    }
    return;
}

fn void? build_collision_piece(
    SolidScratch* scratch,
    CollisionBuild* build,
    uint piece,
    SolidMeshView source,
    uint max_hull_vertices,
) @private {
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: scratch, source: source, grid: null, diagnostic: &diagnostic,
    )!;
    PlaneInteger input_volume = collision_solid_volume(scratch.exact, &solid.nesting)!;
    SourceConstructions constructions = build_source_constructions(scratch, &solid.surface)!;
    SolidPartition partition = partition_solid(scratch, &solid.surface, &constructions)!;
    CollisionCell[] cells = merge_collision_cells(scratch, &partition, max_hull_vertices)!;
    ConvexCell*[] inputs = reserve_elements(scratch, ConvexCell*, cells.len)!;
    foreach (index, &cell : cells) inputs[index] = &cell.cell;
    CollisionSurfaceSet surfaces = build_collision_surfaces(scratch, inputs)!;
    SurfacePointMap points = map_surface_points(scratch, surfaces.patches)!;
    foreach (uint index, point : points.exact) check_frame_point_error(
        scratch: scratch.exact, vertex: point, grid: null, origin: {},
        local: points.positions[index], resolution: build.limits.resolution_m,
    )!;
    PlaneInteger total_volume;
    foreach (&cell : surfaces.cells) {
        uint[] indices = collision_surface_indices(
            scratch: scratch, surfaces: &surfaces, points: &points, faces: cell.faces,
        )!;
        SolidMeshView mesh = collision_indexed_mesh(scratch, points.positions, indices)!;
        CollisionMeshValidation checked = validate_collision_mesh(
            scratch: scratch, mesh: mesh, single_shell: true, resolution: build.limits.resolution_m,
        )!;
        {
            uint saved = scratch.exact.count;
            defer scratch.exact.count = saved;
            WideInteger* sum = scratch.exact.take()!;
            add_integer(sum, total_volume.view(), checked.six_volume.view())!;
            total_volume = { .used = sum.used, .negative = sum.negative };
            total_volume.limbs[:sum.used] = sum.limbs[:sum.used];
        }
        publish_collision_cell(
            scratch: scratch, build: build, piece: piece, surface: cell, points: &points,
            indices: indices, checked: checked, max_hull_vertices: max_hull_vertices,
        )!;
    }
    OrientedPatchTriangles[] exterior = collision_exterior_faces(scratch, &surfaces)!;
    uint[] indices = collision_surface_indices(
        scratch: scratch, surfaces: &surfaces, points: &points, faces: exterior,
    )!;
    SolidMeshView mesh = collision_indexed_mesh(scratch, points.positions, indices)!;
    CollisionMeshValidation checked = validate_collision_mesh(
        scratch: scratch, mesh: mesh, single_shell: false, resolution: build.limits.resolution_m,
    )!;
    check_collision_volume(
        scratch: scratch.exact, first: total_volume, second: checked.six_volume, bound: {},
    )!;
    check_collision_volume(
        scratch: scratch.exact, first: checked.six_volume, second: input_volume, bound: checked.rounding_bound,
    )!;
    return;
}
