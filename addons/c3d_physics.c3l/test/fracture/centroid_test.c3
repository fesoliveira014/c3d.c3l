module c3d::physics::fracture;

import c3d;
import std::math;

const uint CENTROID_PEAK_TEMPORARIES @local = 19;

fn void test_surface_centroid_is_exact_across_translation_and_float_extremes() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    for (uint variant = 0; variant < 3; variant++) {
        tetra_fixture(&fixture);
        Vec3 expected = { 0.25f, 0.25f, 0.25f };
        if (variant == 1) {
            Vec3 origin = { 0x1p100f, -0x1p100f, 0x1p100f };
            foreach (&point : fixture.mesh.geometry.positions) *point = *point * 0x1p80f + origin;
            expected = origin + (Vec3){ 0x1p78f, 0x1p78f, 0x1p78f };
        } else if (variant == 2) {
            float magnitude = bitcast((uint)0x7f7fffff, float);
            Vec3[4] points = {
                { -magnitude, -magnitude, -magnitude }, { magnitude, -magnitude, -magnitude },
                { -magnitude, magnitude, -magnitude }, { -magnitude, -magnitude, magnitude },
            };
            fixture.positions[:4] = points[..];
            float coordinate = bitcast((uint)0xfeffffff, float);
            expected = { coordinate, coordinate, coordinate };
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        ValidatedSolid solid = validate_solid(
            scratch: &scratch,
            source: fixture.mesh,
            grid: null,
            diagnostic: &diagnostic,
        )!!;
        Vec3 centroid = rounded_surface_centroid(&solid.surface, bitcast((uint)1, float))!!;
        for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(centroid[axis], uint) == bitcast(expected[axis], uint));
        assert(scratch.exact.count == 0 && scratch.exact.peak == CENTROID_PEAK_TEMPORARIES);
    }
}

fn void test_surface_centroid_signed_shell_moments_ignore_face_order() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 2; variant++) {
        ContainmentFixture fixture;
        Vec3 expected;
        if (variant == 0) {
            append_box_fixture(&fixture, {}, { 4, 4, 4 });
            append_box_fixture(
                fixture: &fixture,
                lower: { 1, 1, 1 },
                upper: { 2, 2, 2 },
                reversed: true,
            );
            float coordinate = bitcast((uint)0x40008208, float);
            expected = { coordinate, coordinate, coordinate };
        } else {
            append_box_fixture(&fixture, {}, { 1, 1, 1 });
            append_box_fixture(&fixture, { 2, 0, 0 }, { 4, 1, 1 });
            expected = { bitcast((uint)0x400aaaab, float), 0.5f, 0.5f };
        }
        for (uint repeat = 0; repeat < 3; repeat++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidDiagnostic diagnostic;
            ValidatedSolid solid = validate_solid(
                scratch: &scratch,
                source: fixture.mesh,
                grid: null,
                diagnostic: &diagnostic,
            )!!;
            Vec3 centroid = rounded_surface_centroid(&solid.surface, 0x1p-20f)!!;
            for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(centroid[axis], uint) == bitcast(expected[axis], uint));
            assert(scratch.exact.count == 0 && scratch.exact.peak == CENTROID_PEAK_TEMPORARIES);
            uint[TRIANGLE_CORNERS] first;
            first[..] = fixture.indices[:TRIANGLE_CORNERS];
            for (uint corner = TRIANGLE_CORNERS; corner < fixture.mesh.geometry.indices.len; corner++) {
                fixture.indices[corner - TRIANGLE_CORNERS] = fixture.indices[corner];
            }
            fixture.indices[fixture.mesh.geometry.indices.len - TRIANGLE_CORNERS:TRIANGLE_CORNERS] = first[..];
        }
    }
}

fn void test_surface_centroid_checks_the_exact_euclidean_rounding_error() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    float next = bitcast((uint)0x3f800001, float);
    Vec3[4] points = { { 1, 1, 1 }, { next, 1, 1 }, { 1, next, 1 }, { 1, 1, next } };
    fixture.positions[:4] = points[..];
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: null,
        diagnostic: &diagnostic,
    )!!;
    assert(@catch(rounded_surface_centroid(&solid.surface, 0x1p-25f)) == NUMERICAL_FAILURE);
    assert(@catch(rounded_surface_centroid(&solid.surface, bitcast((uint)0x335db3d7, float))) == NUMERICAL_FAILURE);
    Vec3 centroid = rounded_surface_centroid(&solid.surface, bitcast((uint)0x335db3d8, float))!!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(centroid[axis], uint) == 0x3f800000);
    assert(scratch.exact.count == 0);
}

fn void test_surface_centroid_rounds_subnormal_midpoints_to_even() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    for (uint variant = 0; variant < 4; variant++) {
        tetra_fixture(&fixture);
        uint base = variant == 3 ? 0x80000004 : 0;
        uint extent = variant == 3 ? 0x80000002 : variant + 1;
        float origin = bitcast(base, float);
        float upper = bitcast(extent, float);
        Vec3[4] points = {
            { origin, origin, origin }, { upper, origin, origin },
            { origin, upper, origin }, { origin, origin, upper },
        };
        fixture.positions[:4] = points[..];
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        ValidatedSolid solid = validate_solid(
            scratch: &scratch,
            source: fixture.mesh,
            grid: null,
            diagnostic: &diagnostic,
        )!!;
        Vec3 centroid = rounded_surface_centroid(&solid.surface, bitcast((uint)1, float))!!;
        uint expected = variant == 3 ? 0x80000004 : variant == 2 ? 1 : 0;
        for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(centroid[axis], uint) == expected);
        assert(scratch.exact.count == 0);
    }
}

fn void test_surface_centroid_capacity_failure_preserves_held_values() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch,
        source: fixture.mesh,
        grid: null,
        diagnostic: &diagnostic,
    )!!;
    for (uint available = 0; available < CENTROID_PEAK_TEMPORARIES; available++) {
        uint held = EXACT_TEMPORARIES - available;
        scratch.exact.count = held;
        set_integer(&scratch.exact.values[held - 1], 913);
        assert(@catch(rounded_surface_centroid(&solid.surface, 0x1p-20f)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.exact.count == held && scratch.exact.values[held - 1].limbs[0] == 913);
    }
    scratch.exact.count = EXACT_TEMPORARIES - CENTROID_PEAK_TEMPORARIES;
    Vec3 centroid = rounded_surface_centroid(&solid.surface, 0x1p-20f)!!;
    assert(centroid == (Vec3){ 0.25f, 0.25f, 0.25f });
    assert(scratch.exact.count == EXACT_TEMPORARIES - CENTROID_PEAK_TEMPORARIES);
    scratch.exact.count = 0;
}
