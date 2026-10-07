module c3d::physics::fracture;

import c3d;
import std::math;
import std::time;

const uint[12] COLLISION_TETRAHEDRON_FACES @private = { 0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3 };

struct CollisionHullMeasurement @private {
    PlaneInteger volume;
    PlaneInteger missing_bound;
}

fn void preserve_collision_source_bits(SurfacePointMap* points, SolidSurface* source) @private {
    foreach (&point : points.positions) {
        bool selected;
        foreach (uint vertex, unused : source.topology.vertices) {
            Vec3 candidate = surface_position(source, vertex);
            if (!same_position(*point, candidate)) continue;

            bool before = !selected;
            if (selected) {
                for (uint axis = 0; axis < SPACE_AXES; axis++) {
                    uint left = bitcast(candidate[axis], uint);
                    uint right = bitcast((*point)[axis], uint);
                    if (left == right) continue;

                    before = left < right;
                    break;
                }
            }

            if (before) *point = candidate;
            selected = true;
        }
    }
}

fn CollisionHullMeasurement? publish_collision_hull(
    SolidScratch* scratch,
    CollisionBuild* build,
    uint piece,
    CollisionHullSurface* hull,
    ValidatedSolid* solid,
    SolidSurface* original,
    SourceConstructions* source,
    uint max_hull_vertices,
) @private {
    PlaneInteger expected_volume = collision_solid_volume(scratch.exact, &solid.nesting)!;

    if (hull.points.len <= max_hull_vertices) {
        append_collision_hull(scratch: scratch, build: build, piece: piece, points: hull.points)!;
        return {
            .volume = expected_volume,
            .missing_bound = collision_coverage_bound(&solid.surface, build.limits.resolution_m)!,
        };
    }

    Vec3 anchor = collision_hull_anchor(
        hull: &solid.surface, original: original, source: source, resolution: build.limits.resolution_m,
    )!;
    CollisionHullMeasurement measured;

    for (uint first = 0; first < hull.indices.len; first += TRIANGLE_CORNERS) {
        Vec3[HOMOGENEOUS_COMPONENTS] tetrahedron = {
            anchor, hull.points[hull.indices[first]],
            hull.points[hull.indices[first + 1]], hull.points[hull.indices[first + 2]],
        };
        PlaneInteger volume = collision_tetrahedron_volume(scratch.exact, tetrahedron)!;
        add_collision_volume(scratch.exact, &measured.volume, volume)!;

        PlaneInteger bound = collision_point_coverage_bound(
            scratch: scratch.exact, positions: tetrahedron[..], indices: COLLISION_TETRAHEDRON_FACES[..],
            resolution: build.limits.resolution_m,
        )!;
        add_collision_volume(scratch.exact, &measured.missing_bound, bound)!;

        Vec3[] points = reserve_elements(scratch, Vec3, HOMOGENEOUS_COMPONENTS)!;
        points[..] = tetrahedron[..];
        append_collision_hull(scratch: scratch, build: build, piece: piece, points: points)!;
    }

    check_collision_volume(scratch: scratch.exact, first: measured.volume, second: expected_volume, bound: {})!;
    return measured;
}

fn void? build_collision_piece(
    SolidScratch* scratch,
    CollisionBuild* build,
    uint piece,
    SolidMeshView source,
    uint max_hull_vertices,
) @private {
    std::time::Clock partition_started = clock::now();
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: scratch, source: source, grid: null, diagnostic: &diagnostic,
    )!;

    PlaneInteger input_volume = collision_solid_volume(scratch.exact, &solid.nesting)!;
    PlaneInteger excess_bound = float_rounding_volume_bound(&solid.surface, build.limits.resolution_m)!;
    SourceConstructions constructions = build_source_constructions(scratch, &solid.surface)!;

    CollisionChunks chunks = partition_collision_chunks(
        scratch: scratch, solid: &solid, source: &constructions, resolution: build.limits.resolution_m,
    )!;
    scratch.exact.statistics.final_leaf_count += chunks.count;
    scratch.exact.statistics.occupied_leaf_count += chunks.count;
    scratch.exact.statistics.partition_nanoseconds += (ulong)partition_started.to_now();

    usz patch_count;
    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) patch_count += chunk.patches.len;
    if (patch_count > uint::max) return c3d::CAPACITY_EXCEEDED~;

    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, patch_count)!;
    uint written;
    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
        foreach (patch : chunk.patches) patches[written++] = patch.boundary;
    }

    SurfacePointMap points = map_surface_points(scratch, patches)!;
    preserve_collision_source_bits(&points, &solid.surface);
    foreach (uint index, vertex : points.exact) check_frame_point_error(
        scratch: scratch.exact, vertex: vertex, grid: null, origin: {},
        local: points.positions[index], resolution: build.limits.resolution_m,
    )!;

    PlaneInteger hull_volume;
    PlaneInteger missing_bound;
    uint first_patch;
    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
        CollisionReferenceVertices vertices = collision_reference_vertices(
            scratch: scratch, points: &points, first_patch: first_patch,
            patch_count: (uint)chunk.patches.len, source: &solid.surface,
        )!;
        first_patch += (uint)chunk.patches.len;

        CollisionHullSurface hull = retain_collision_hull(
            scratch: scratch, points: &points, vertices: &vertices, resolution: build.limits.resolution_m,
        )!;
        SolidMeshView mesh = collision_indexed_mesh(scratch, hull.points, hull.indices)!;
        ValidatedSolid checked = validate_solid(scratch: scratch, source: mesh, grid: null, diagnostic: &diagnostic)!;
        if (checked.nesting.shells.len != 1) return NUMERICAL_FAILURE~;
        validate_collision_hull(&checked.surface)!;

        CollisionHullMeasurement measured = publish_collision_hull(
            scratch: scratch, build: build, piece: piece, hull: &hull, solid: &checked,
            original: &solid.surface, source: &constructions, max_hull_vertices: max_hull_vertices,
        )!;
        add_collision_volume(scratch.exact, &hull_volume, measured.volume)!;
        add_collision_volume(scratch.exact, &missing_bound, measured.missing_bound)!;
    }

    check_collision_cover(
        scratch: scratch.exact, hull_volume: hull_volume, source_volume: input_volume,
        missing_bound: missing_bound, excess_bound: excess_bound,
    )!;
    return;
}
