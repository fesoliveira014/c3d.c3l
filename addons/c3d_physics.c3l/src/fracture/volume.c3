module c3d::physics::fracture;

import std::time;

const uint RAW_SHELL_VOLUME_BITS @private = 866;

$assert PLANE_LIMBS * INTEGER_LIMB_BITS >= RAW_SHELL_VOLUME_BITS;

struct SolidShell @private {
    PlaneInteger six_volume;
    SolidBounds bounds;
    uint root;
    uint parent;
    uint depth;
}

struct SolidNesting @private {
    SolidShell[] shells;
    uint[] root_to_shell;
    ulong pairs;
    ulong queries;
    ulong candidate_faces;
}

fn void? triangle_volume(
    SolidSurface* surface,
    WideInteger* output,
    uint face,
) @private {
    std::time::Clock started = begin_exact_measurement(surface.exact);
    defer finish_exact_measurement(surface.exact, started);
    uint saved = surface.exact.count;
    defer surface.exact.count = saved;
    uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
    IntegerView[TRIANGLE_CORNERS * SPACE_AXES] matrix;
    foreach (uint corner, identity : triangle) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            WideInteger* coordinate = surface.exact.take()!;
            if (surface.grid.len) {
                set_integer(coordinate, surface.grid[identity][axis]);
            } else {
                integer_from_float(coordinate, surface_position(surface, identity)[axis]);
            }
            matrix[corner * SPACE_AXES + axis] = coordinate.view();
        }
    }
    determinant(
        scratch: surface.exact,
        output: output,
        matrix: matrix[..],
        order: SPACE_AXES,
    )!;
    return;
}

fn void? measure_shell_volumes(SolidSurface* surface, SolidNesting* nesting, SolidDiagnostic* diagnostic) @private {
    uint saved = surface.exact.count;
    defer surface.exact.count = saved;
    WideInteger* sum = surface.exact.take()!;
    WideInteger* term = surface.exact.take()!;
    nesting.shells[..] = {};
    nesting.root_to_shell[..] = NO_SOLID_INDEX;
    uint shell_index;
    foreach (uint face, root : surface.topology.shell_roots) {
        if (face != root) continue;
        nesting.root_to_shell[root] = shell_index;
        nesting.shells[shell_index++] = { .root = root, .parent = NO_SOLID_INDEX, .bounds = surface.bounds[root] };
    }
    foreach (uint face, root : surface.topology.shell_roots) {
        SolidShell* shell = &nesting.shells[nesting.root_to_shell[root]];
        shell.bounds = joined_solid_bounds(shell.bounds, surface.bounds[face]);
        std::time::Clock started = begin_exact_measurement(surface.exact);
        defer finish_exact_measurement(surface.exact, started);
        triangle_volume(surface, term, face)!;
        add_integer(sum, shell.six_volume.view(), term.view())!;
        shell.six_volume.used = sum.used;
        shell.six_volume.negative = sum.negative;
        shell.six_volume.limbs[:sum.used] = sum.limbs[:sum.used];
    }
    foreach (uint index, &shell : nesting.shells) {
        if (shell.six_volume.used) continue;
        *diagnostic = {
            .reason = SolidFailure.DEGENERATE_SHELL,
            .first_face = shell.root,
            .second_face = NO_SOLID_INDEX,
            .shell_index = index,
        };
        return INVALID_SOLID~;
    }
    return;
}
