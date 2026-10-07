module c3d::physics::fracture;

import c3d;
import std::math;

fn PlaneInteger? collision_solid_volume(ExactScratch* scratch, SolidNesting* nesting) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger* sum = scratch.take()!;
    foreach (&shell : nesting.shells) add_integer(sum, sum.view(), shell.six_volume.view())!;

    PlaneInteger result = { .used = sum.used, .negative = sum.negative };
    result.limbs[:sum.used] = sum.limbs[:sum.used];

    return result;
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
