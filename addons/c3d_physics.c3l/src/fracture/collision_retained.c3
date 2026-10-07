module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

struct CollisionReferenceVertices @private {
    uint[] references;
    Vec3[] positions;
    bool[] authored;
}

fn bool authored_collision_position(SolidSurface* source, Vec3 position) @private {
    foreach (uint vertex, unused : source.topology.vertices) {
        if (same_position(position, surface_position(source, vertex))) return true;
    }

    return false;
}

fn CollisionReferenceVertices? collision_reference_vertices(
    SolidScratch* scratch,
    SurfacePointMap* points,
    uint first_patch,
    uint patch_count,
    SolidSurface* source,
) @private {
    uint first = points.patch_offsets[first_patch];
    uint end = points.patch_offsets[first_patch + patch_count];
    uint[] references = reserve_elements(scratch, uint, (usz)(end - first))!;
    references[..] = points.vertices[first:end - first];
    sort::quicksort(references);

    uint count;
    foreach (reference : references) {
        if (!count || references[count - 1] != reference) references[count++] = reference;
    }
    references = references[:count];

    CollisionReferenceVertices vertices = {
        .references = references,
        .positions = reserve_elements(scratch, Vec3, count)!,
        .authored = reserve_elements(scratch, bool, count)!,
    };

    foreach (uint index, reference : references) {
        Vec3 position = points.positions[reference];
        vertices.positions[index] = position;
        vertices.authored[index] = authored_collision_position(source, position);
    }

    return vertices;
}

fn bool? collision_vertex_near_retained_point(
    ExactScratch* scratch,
    PlaneTriple reference,
    Vec3[] positions,
    bool[] retained,
    uint omitted,
    float resolution,
) @private {
    for (uint index = 0; index < omitted; index++) {
        if (!retained[index]) continue;

        if (catch failure = check_frame_point_error(
            scratch: scratch, vertex: reference, grid: null, origin: {},
            local: positions[index], resolution: resolution,
        )) {
            if (failure != NUMERICAL_FAILURE) return failure~;
        } else {
            return true;
        }
    }

    return false;
}

fn Vec3[]? retained_collision_positions(
    SolidScratch* scratch,
    CollisionReferenceVertices* vertices,
    bool[] retained,
    uint omitted = NO_SOLID_INDEX,
) @private {
    uint count;
    foreach (uint index, keep : retained) count += keep && index != omitted ? 1 : 0;

    Vec3[] positions = reserve_elements(scratch, Vec3, count)!;
    count = 0;
    foreach (uint index, keep : retained) {
        if (keep && index != omitted) positions[count++] = vertices.positions[index];
    }

    return positions;
}

fn void? certify_collision_reference_vertices(
    ExactScratch* scratch,
    SurfacePointMap* points,
    uint[] references,
    CollisionHullSurface* hull,
    float resolution,
) @private {
    foreach (reference : references) {
        if (!collision_vertex_has_witness(
            scratch: scratch, vertex: points.exact[reference], hull: hull, resolution: resolution,
        )!) return NUMERICAL_FAILURE~;
    }

    return;
}

fn CollisionHullSurface? retain_collision_hull(
    SolidScratch* scratch,
    SurfacePointMap* points,
    CollisionReferenceVertices* vertices,
    float resolution,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;

    bool[] retained = reserve_elements(scratch, bool, vertices.references.len)!;
    retained[..] = true;
    uint count = (uint)retained.len;

    foreach (uint index, reference : vertices.references) {
        if (vertices.authored[index] || count == COLLISION_TETRAHEDRON_VERTICES) continue;

        if (collision_vertex_near_retained_point(
            scratch: scratch.exact, reference: points.exact[reference], positions: vertices.positions,
            retained: retained, omitted: index, resolution: resolution,
        )!) {
            retained[index] = false;
            count--;
        }
    }

    foreach (uint index, reference : vertices.references) {
        if (vertices.authored[index] || !retained[index] || count == COLLISION_TETRAHEDRON_VERTICES) continue;

        usz trial_start = scratch.used;
        defer scratch.used = trial_start;
        Vec3[] positions = retained_collision_positions(
            scratch: scratch, vertices: vertices, retained: retained, omitted: index,
        )!;
        CollisionHullSurface? candidate = build_collision_hull(scratch, positions);

        if (catch failure = candidate) {
            if (failure != NUMERICAL_FAILURE) return failure~;
            continue;
        }

        if (collision_vertex_has_witness(
            scratch: scratch.exact, vertex: points.exact[reference], hull: &candidate, resolution: resolution,
        )!) {
            retained[index] = false;
            count--;
        }
    }

    Vec3[] positions = retained_collision_positions(scratch, vertices, retained)!;
    CollisionHullSurface hull = build_collision_hull(scratch, positions)!;

    certify_collision_reference_vertices(
        scratch: scratch.exact, points: points, references: vertices.references, hull: &hull, resolution: resolution,
    )!;

    return hull;
}
