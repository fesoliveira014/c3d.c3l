module c3d::physics::fracture;

import c3d;
import std::math;

struct CollisionMeshValidation @private {
    PlaneInteger six_volume;
    PlaneInteger rounding_bound;
    Vec3 centroid;
    bool convex;
}

fn PlaneInteger? collision_solid_volume(ExactScratch* scratch, SolidNesting* nesting) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* sum = scratch.take()!;
    foreach (&shell : nesting.shells) add_integer(sum, sum.view(), shell.six_volume.view())!;
    PlaneInteger result = { .used = sum.used, .negative = sum.negative };
    result.limbs[:sum.used] = sum.limbs[:sum.used];
    return result;
}

fn bool? collision_surface_convex(SolidSurface* surface) @private {
    for (uint face = 0; face < surface.topology.shell_roots.len; face++) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        Vec3[HOMOGENEOUS_COMPONENTS] points;
        foreach (uint corner, identity : triangle) points[corner] = surface_position(surface, identity);
        foreach (uint identity, vertex : surface.topology.vertices) {
            if (!vertex.degree) continue;
            points[TRIANGLE_CORNERS] = surface_position(surface, identity);
            if (float_orientation(surface.exact, points)! > 0) return false;
        }
    }
    return true;
}

fn CollisionMeshValidation? validate_collision_mesh(
    SolidScratch* scratch,
    SolidMeshView mesh,
    bool single_shell,
    float resolution,
) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: scratch, source: mesh, grid: null, diagnostic: &diagnostic,
    )!;
    if (single_shell && solid.nesting.shells.len != 1) return NUMERICAL_FAILURE~;
    return {
        .six_volume = collision_solid_volume(scratch.exact, &solid.nesting)!,
        .rounding_bound = float_rounding_volume_bound(&solid.surface, resolution)!,
        .centroid = single_shell ? rounded_surface_centroid(&solid.surface, resolution)! : (Vec3){},
        .convex = single_shell && collision_surface_convex(&solid.surface)!,
    };
}

fn void? check_collision_volume(
    ExactScratch* scratch,
    PlaneInteger first,
    PlaneInteger second,
    PlaneInteger bound,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* difference = scratch.take()!;
    add_integer(difference, first.view(), negate_integer(second.view()))!;
    if (compare_magnitude(difference.view(), bound.view()) > 0) return NUMERICAL_FAILURE~;
    return;
}

fn void? check_collision_cone(
    ExactScratch* scratch,
    PlaneTriple[HOMOGENEOUS_COMPONENTS] exact,
    Vec3[HOMOGENEOUS_COMPONENTS] positions,
) @private {
    int before = vertex_orientation(scratch, exact)!;
    int after = float_orientation(scratch, positions)!;
    if (before > 0 || after != before) return NUMERICAL_FAILURE~;
    return;
}

fn uint? collision_point_index(
    ExactScratch* scratch,
    SurfacePointMap* points,
    PlaneTriple vertex,
) @private {
    uint first;
    uint end = (uint)points.exact.len;
    while (first < end) {
        uint middle = first + (end - first) / 2;
        int order = compare_collision_vertices(scratch, points.exact[middle], vertex)!;
        if (!order) return middle;
        if (order < 0) {
            first = middle + 1;
        } else {
            end = middle;
        }
    }
    return NUMERICAL_FAILURE~;
}

fn SolidMeshView? collision_indexed_mesh(
    SolidScratch* scratch,
    Vec3[] positions,
    uint[] indices,
) @private {
    uint[] identities = reserve_elements(scratch, uint, positions.len)!;
    foreach (uint index, &identity : identities) *identity = index;
    uint[] materials = reserve_elements(scratch, uint, indices.len / TRIANGLE_CORNERS)!;
    materials[..] = 0;
    return {
        .geometry = { .positions = positions, .indices = indices },
        .topology_vertices = identities,
        .triangle_materials = materials,
    };
}
