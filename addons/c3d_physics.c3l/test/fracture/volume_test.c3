module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_shell_volume_is_exact_across_translation_extremes_and_winding() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    for (uint variant = 0; variant < 4; variant++) {
        tetra_fixture(&fixture);
        if (variant == 1) {
            foreach (&point : fixture.mesh.geometry.positions) *point = *point * 0x1p80f + (Vec3){ 0x1p100f, -0x1p100f, 0x1p100f };
        } else if (variant == 2) {
            float magnitude = bitcast((uint)0x7f7fffff, float);
            Vec3[4] positions = {
                { -magnitude, -magnitude, -magnitude }, { magnitude, -magnitude, -magnitude },
                { -magnitude, magnitude, -magnitude }, { -magnitude, -magnitude, magnitude },
            };
            fixture.positions[:4] = positions[..];
        } else if (variant == 3) {
            float subnormal = bitcast((uint)1, float);
            fixture.positions[1].x = subnormal;
            fixture.positions[2].y = subnormal;
            fixture.positions[3].z = subnormal;
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        SolidNesting nesting = build_solid_nesting(&scratch, &surface, &diagnostic)!!;
        assert(nesting.shells.len == 1 && nesting.shells[0].depth == 0);
        assert(nesting.shells[0].parent == NO_SOLID_INDEX);
        assert(integer_sign(nesting.shells[0].six_volume.view()) == 1);
        uint bits = integer_bits(nesting.shells[0].six_volume.view());
        if (variant == 0) assert(bits == 448);
        if (variant == 1) assert(bits == 688);
        if (variant == 2) assert(bits > 830 && bits <= RAW_SHELL_VOLUME_BITS);
        if (variant == 3) assert(bits == 1);
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
        for (uint face = 0; face < 4; face++) {
            uint saved = fixture.indices[face * 3 + 1];
            fixture.indices[face * 3 + 1] = fixture.indices[face * 3 + 2];
            fixture.indices[face * 3 + 2] = saved;
        }
        scratch = begin_solid_scratch(&workspace);
        surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        usz saved = scratch.used;
        assert(@catch(build_solid_nesting(&scratch, &surface, &diagnostic)) == INVALID_SOLID);
        assert(diagnostic.reason == SolidFailure.WRONG_ORIENTATION && diagnostic.shell_index == 0);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
}

fn void test_shell_zero_volume_has_a_specific_diagnostic() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    fixture.positions[3] = { 1, 1, 0 };
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidBounds[4] bounds;
    SolidSurface surface = {
        .source = fixture.mesh,
        .topology = build_solid_topology(&scratch, fixture.mesh)!!,
        .exact = scratch.exact,
        .bounds = bounds[..],
    };
    SolidShell[1] shells;
    uint[4] roots;
    SolidNesting nesting = { .shells = shells[..], .root_to_shell = roots[..] };
    SolidDiagnostic diagnostic;
    assert(@catch(measure_shell_volumes(&surface, &nesting, &diagnostic)) == INVALID_SOLID);
    assert(diagnostic.reason == SolidFailure.DEGENERATE_SHELL && diagnostic.shell_index == 0);
    assert(diagnostic.first_face == 0 && diagnostic.second_face == NO_SOLID_INDEX);
    assert(scratch.exact.count == 0 && scratch.exact.peak == 14);
}

fn void test_solid_quantization_rechecks_geometry_and_restores_scratch_on_failure() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    QuantizationGrid grid = { .step_exponent = -4 };
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: &grid,
        diagnostic: &diagnostic,
    )!!;
    assert(solid.surface.grid.len == 4);
    assert(solid.nesting.shells[0].six_volume.used == 1 && solid.nesting.shells[0].six_volume.limbs[0] == 4096);
    assert(solid.raw_counts.triangle_pairs == 6 && solid.grid_counts.triangle_pairs == 6);
    assert(diagnostic.reason == SolidFailure.NONE && diagnostic.shell_index == NO_SOLID_INDEX);
    fixture.positions[3].z = 0.000000001f;
    for (uint repeat = 0; repeat < 2; repeat++) {
        scratch = begin_solid_scratch(&workspace);
        scratch.reserve(1, ulong::size, ulong::alignment)!!;
        usz saved = scratch.used;
        assert(@catch(validate_solid(
            scratch: &scratch,
            source: fixture.mesh,
            grid: &grid,
            diagnostic: &diagnostic,
        )) == NUMERICAL_FAILURE);
        assert(diagnostic.reason == SolidFailure.DEGENERATE_TRIANGLE);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
    fixture.positions[3].z = 0;
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: &grid,
        diagnostic: &diagnostic,
    )) == INVALID_SOLID);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES);
    tetra_fixture(&fixture);
    Vec3[4] reversed_after_rounding = {
        { -1.25, -0.1875, -1.375 }, { 0.5, 0.75, 1.125 },
        { -0.375, 1.375, -0.0625 }, { -1, -1.4375, 0.9375 },
    };
    fixture.positions[:4] = reversed_after_rounding[..];
    grid.step_exponent = 0;
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: &grid,
        diagnostic: &diagnostic,
    )) == NUMERICAL_FAILURE);
    assert(diagnostic.reason == SolidFailure.WRONG_ORIENTATION);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES);
    tetra_fixture(&fixture);
    grid.step_exponent = -4;
    fixture.positions[4] = { float::max, float::max, float::max };
    fixture.identities[4] = 4;
    fixture.mesh.geometry.positions = fixture.positions[:5];
    fixture.mesh.topology_vertices = fixture.identities[:5];
    scratch = begin_solid_scratch(&workspace);
    solid = validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: &grid,
        diagnostic: &diagnostic,
    )!!;
    assert(solid.surface.grid.len == 5 && solid.surface.topology.vertices[4].degree == 0);
}
