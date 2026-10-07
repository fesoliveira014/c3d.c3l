module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

fn void test_surface_attributes_tangents_preserve_reflected_handedness_and_authored_normals() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint reflected = 0; reflected < 2; reflected++) {
        Vec3[4] positions = { {}, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 } };
        if (reflected) foreach (&position : positions) position.x = -position.x;
        Vec3[4] normals = { { 0, 0, 2 }, { 0, 0, 2 }, { 0, 0, 2 }, { 0, 0, 2 } };
        Vec2[4] coordinates = { {}, { 1, 0 }, { 1, 1 }, { 0, 1 } };
        uint[6] indices = { 0, 1, 2, 0, 2, 3 };
        Vec4[4] tangents;
        Geometry geometry = {
            .positions = positions[..],
            .normals = normals[..],
            .uv0 = coordinates[..],
            .tangents = tangents[..],
            .indices = indices[..],
        };
        for (uint repeat = 0; repeat < 2; repeat++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            usz saved = scratch.used;
            regenerate_surface_tangents(&scratch, &geometry)!!;
            float orientation = reflected ? -1.0f : 1.0f;
            foreach (tangent : tangents) assert(tangent == (Vec4){ orientation, 0, 0, orientation });
            foreach (normal : normals) assert(normal == (Vec3){ 0, 0, 2 });
            assert(scratch.used == saved && scratch.exact.count == 0);
            uint[3] first;
            first[..] = indices[:3];
            indices[:3] = indices[3:3];
            indices[3:3] = first[..];
        }
    }
}

fn void test_surface_attributes_tangents_scale_extreme_and_subnormal_geometry_and_uvs() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 2; variant++) {
        float position_scale = variant ? bitcast((uint)1, float) : float::max;
        float uv_scale = variant ? float::max : bitcast((uint)1, float);
        Vec3[3] positions = { {}, { position_scale, 0, 0 }, { 0, position_scale, 0 } };
        Vec3[3] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
        Vec2[3] coordinates = { {}, { uv_scale, 0 }, { 0, uv_scale } };
        Vec4[3] tangents;
        Geometry geometry = {
            .positions = positions[..],
            .normals = normals[..],
            .uv0 = coordinates[..],
            .tangents = tangents[..],
        };
        SolidScratch scratch = begin_solid_scratch(&workspace);
        usz saved = scratch.used;
        regenerate_surface_tangents(&scratch, &geometry)!!;
        foreach (tangent : tangents) assert(tangent == (Vec4){ 1, 0, 0, 1 });
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
}

fn void test_surface_attributes_tangents_keep_zero_uv_behavior() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    Vec3[3] positions = { {}, { 1, 0, 0 }, { 0, 1, 0 } };
    Vec3[3] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    Vec2[3] coordinates;
    Vec4[3] tangents;
    Geometry geometry = {
        .positions = positions[..],
        .normals = normals[..],
        .uv0 = coordinates[..],
        .tangents = tangents[..],
    };
    SolidScratch scratch = begin_solid_scratch(&workspace);
    regenerate_surface_tangents(&scratch, &geometry)!!;
    foreach (tangent : tangents) assert(tangent == (Vec4){ 0, 0, 0, 1 });
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES && scratch.exact.count == 0);
}

fn void test_surface_attributes_tangent_capacity_failure_leaves_output_and_workspace_reusable() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    Vec3[3] positions = { {}, { 1, 0, 0 }, { 0, 1, 0 } };
    Vec3[3] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    Vec2[3] coordinates = { {}, { 1, 0 }, { 0, 1 } };
    Vec4[3] tangents;
    Geometry geometry = {
        .positions = positions[..],
        .normals = normals[..],
        .uv0 = coordinates[..],
        .tangents = tangents[..],
    };
    SolidScratch scratch = begin_solid_scratch(&workspace);
    regenerate_surface_tangents(&scratch, &geometry)!!;
    usz required = scratch.peak;
    for (uint failure = 0; failure < 2; failure++) {
        tangents[..] = (Vec4){ 7, 8, 9, 10 };
        scratch = begin_solid_scratch(&workspace);
        if (failure) {
            scratch.exact.count = EXACT_TEMPORARIES - 2;
            set_integer(&scratch.exact.values[scratch.exact.count - 1], 913);
        } else {
            scratch.storage = scratch.storage[:required - 1];
        }
        uint held = scratch.exact.count;
        assert(@catch(regenerate_surface_tangents(&scratch, &geometry)) == c3d::CAPACITY_EXCEEDED);
        foreach (tangent : tangents) assert(tangent == (Vec4){ 7, 8, 9, 10 });
        assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES && scratch.exact.count == held);
        if (failure) assert(scratch.exact.values[held - 1].limbs[0] == 913);
        scratch.exact.count = 0;
    }
    scratch = begin_solid_scratch(&workspace);
    regenerate_surface_tangents(&scratch, &geometry)!!;
    foreach (tangent : tangents) assert(tangent == (Vec4){ 1, 0, 0, 1 });
}
