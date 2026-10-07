module c3d::physics::fracture;

import c3d;
import std::math;

fn ValidatedSolid collision_bound_solid(SolidScratch* scratch, CollisionHullSurface* hull) @local {
    SolidDiagnostic diagnostic;
    SolidMeshView mesh = collision_indexed_mesh(scratch, hull.points, hull.indices)!!;

    return validate_solid(scratch: scratch, source: mesh, grid: null, diagnostic: &diagnostic)!!;
}

fn void test_collision_coverage_bound_matches_exact_cube_expansion_volume() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);

    Vec3[5][3] inputs = {
        { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 2, 0 }, { 0, 0, 2 }, { 0.5f, 0.5f, 0.5f } },
        { { -2, -1, -1 }, { 3, -1, -1 }, { 0, 3, -1 }, { 0, 0, 4 }, { 0, 0, -3 } },
        { { -2, 0, 0 }, { 2, 0, 0 }, { 0, 1, 0 }, { 0, 0, 3 }, { 0, -2, -1 } },
    };
    float epsilon = 0.125f;

    foreach (input : inputs) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        CollisionHullSurface hull = build_collision_hull(&scratch, input[..])!!;
        ValidatedSolid base = collision_bound_solid(&scratch, &hull);
        PlaneInteger base_volume = collision_solid_volume(scratch.exact, &base.nesting)!!;
        PlaneInteger bound = collision_coverage_bound(&base.surface, epsilon)!!;

        Vec3[40] expanded;
        uint count;
        foreach (point : input) {
            for (uint corner = 0; corner < 8; corner++) {
                expanded[count++] = point + (Vec3){
                    corner & 4 ? epsilon : -epsilon,
                    corner & 2 ? epsilon : -epsilon,
                    corner & 1 ? epsilon : -epsilon,
                };
            }
        }

        CollisionHullSurface expansion = build_collision_hull(&scratch, expanded[..])!!;
        ValidatedSolid expanded_solid = collision_bound_solid(&scratch, &expansion);
        PlaneInteger difference = collision_solid_volume(scratch.exact, &expanded_solid.nesting)!!;
        base_volume.negative = true;
        add_collision_volume(scratch.exact, &difference, base_volume)!!;

        assert(!difference.negative && !compare_magnitude(difference.view(), bound.view()));
        assert(!scratch.exact.count && !scratch.exact.measurement_depth);
    }
}

fn PlaneInteger collision_bound_value(ulong value) @local {
    PlaneInteger result = { .used = value ? 1 : 0 };
    result.limbs[0] = value;
    return result;
}

fn void test_collision_coverage_checks_both_signed_volume_limits() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);

    PlaneInteger source = collision_bound_value(100);
    PlaneInteger missing = collision_bound_value(3);
    PlaneInteger excess = collision_bound_value(2);

    foreach (value : (ulong[3]){ 97, 100, 102 }) {
        check_collision_cover(
            scratch: scratch.exact, hull_volume: collision_bound_value(value), source_volume: source,
            missing_bound: missing, excess_bound: excess,
        )!!;
    }

    foreach (value : (ulong[2]){ 96, 103 }) {
        assert(@catch(check_collision_cover(
            scratch: scratch.exact, hull_volume: collision_bound_value(value), source_volume: source,
            missing_bound: missing, excess_bound: excess,
        )) == NUMERICAL_FAILURE);
        assert(!scratch.exact.count);
    }
}
