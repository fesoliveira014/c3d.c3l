module c3d::physics::fracture;

fn bool enclosed_solid_bounds(SolidBounds source, SolidBounds target) @private {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (source.lower[axis] < target.lower[axis] || source.upper[axis] > target.upper[axis]) return false;
    }
    return true;
}

fn void? check_solid_nesting(SolidSurface* surface, SolidNesting* nesting, SolidDiagnostic* diagnostic) @private {
    nesting.pairs = 0;
    nesting.queries = 0;
    nesting.candidate_faces = 0;
    measure_shell_volumes(surface, nesting, diagnostic)!;
    foreach (uint source_index, &source : nesting.shells) {
        foreach (uint target_index, &target : nesting.shells) {
            if (source_index == target_index) continue;
            nesting.pairs++;
            if (!enclosed_solid_bounds(source.bounds, target.bounds)) continue;
            nesting.queries++;
            if (!shell_contains(
                surface: surface,
                source_root: source.root,
                target_root: target.root,
                candidate_faces: &nesting.candidate_faces,
            )!) continue;
            if (source.parent == NO_SOLID_INDEX
                || compare_magnitude(target.six_volume.view(), nesting.shells[source.parent].six_volume.view()) < 0) {
                source.parent = target_index;
            }
        }
    }
    foreach (uint index, &shell : nesting.shells) {
        uint parent = shell.parent;
        while (parent != NO_SOLID_INDEX) {
            shell.depth++;
            parent = nesting.shells[parent].parent;
        }
        bool negative = (shell.depth & 1) != 0;
        if (shell.six_volume.negative != negative) {
            *diagnostic = {
                .reason = SolidFailure.WRONG_ORIENTATION,
                .first_face = shell.root,
                .second_face = NO_SOLID_INDEX,
                .shell_index = index,
            };
            return INVALID_SOLID~;
        }
    }
    return;
}

fn SolidNesting? build_solid_nesting(
    SolidScratch* scratch,
    SolidSurface* surface,
    SolidDiagnostic* diagnostic,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SolidNesting nesting = {
        .shells = reserve_elements(scratch, SolidShell, surface.topology.shell_count)!,
        .root_to_shell = reserve_elements(scratch, uint, surface.topology.shell_roots.len)!,
    };
    check_solid_nesting(surface, &nesting, diagnostic)!;
    return nesting;
}
