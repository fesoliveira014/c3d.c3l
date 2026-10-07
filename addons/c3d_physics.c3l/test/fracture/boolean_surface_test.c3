module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

const BooleanOperation[3] SURFACE_BOOLEAN_OPERATIONS @local = {
    BooleanOperation.UNION, BooleanOperation.INTERSECTION, BooleanOperation.DIFFERENCE,
};

fn FractureResult publish_boolean_fixture(
    SolidScratch* scratch,
    SolidMeshView first,
    SolidMeshView second,
    BooleanOperation operation,
    long volume_quarters,
    FractureLimits limits,
) @local {
    PreparedGeneration prepared = prepare_generation_sources(scratch, { first, second }, limits.resolution_m)!!;
    SolidPartition partition = partition_boolean_cells(
        scratch: scratch,
        first: &prepared.sources[0].solid.surface,
        first_source: &prepared.sources[0].constructions,
        second: &prepared.sources[1].solid.surface,
        second_source: &prepared.sources[1].constructions,
        operation: operation,
    )!!;
    SurfacePiece[] pieces = build_boolean_surface_pieces(
        scratch: scratch, prepared: &prepared, partition: &partition, operation: operation, max_pieces: limits.max_pieces,
    )!!;
    SurfaceVolumeReference reference = { .coordinate_exponent = -2 };
    if (volume_quarters) {
        reference.six_volume.used = 1;
        reference.six_volume.limbs[0] = (ulong)volume_quarters * 96;
    }
    FractureResult result = publish_surface_pieces(
        allocator: mem, scratch: scratch, limits: limits, pieces: pieces, grid: &prepared.grid,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &reference,
    )!!;
    assert_published_valid(scratch, result);
    return result;
}

fn void boolean_surface_box_pair(ContainmentFixture* first, ContainmentFixture* second, uint variant) @local {
    Vec3[2][6] first_bounds = {
        { { -2, -2, -2 }, { 2, 2, 2 } }, { { -3, -1, -1 }, { -1, 1, 1 } },
        { { -2, -2, -2 }, { 2, 2, 2 } }, { { -3, -3, -3 }, { 3, 3, 3 } },
        { { -1, -1, -1 }, { 1, 1, 1 } }, { { -2, -1, -1 }, { 0, 1, 1 } },
    };
    Vec3[2][6] second_bounds = {
        { { 0, -2, -2 }, { 4, 2, 2 } }, { { 1, -1, -1 }, { 3, 1, 1 } },
        { { -2, -2, -2 }, { 2, 2, 2 } }, { { -1, -1, -1 }, { 1, 1, 1 } },
        { { -3, -3, -3 }, { 3, 3, 3 } }, { { 0, -1, -1 }, { 2, 1, 1 } },
    };
    append_box_fixture(first, first_bounds[variant][0], first_bounds[variant][1]);
    append_box_fixture(second, second_bounds[variant][0], second_bounds[variant][1]);
    first.materials[..] = 11;
    second.materials[..] = 22;
}

fn void test_boolean_surface_box_operations_preserve_volume_and_first_source_provenance() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    long[3][6] volumes = {
        { 96, 32, 32 }, { 16, 0, 8 }, { 64, 64, 0 }, { 216, 8, 208 }, { 216, 8, 0 }, { 16, 0, 8 },
    };
    uint[3][6] expected = { { 1, 1, 1 }, { 2, 0, 1 }, { 1, 1, 0 }, { 1, 1, 1 }, { 1, 1, 0 }, { 1, 0, 1 } };
    for (uint variant = 0; variant < volumes.len; variant++) foreach (uint index, operation : SURFACE_BOOLEAN_OPERATIONS) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture first;
        ContainmentFixture second;
        boolean_surface_box_pair(&first, &second, variant);
        FractureResult result = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: operation,
            volume_quarters: volumes[variant][index] * 4, limits: limits,
        );
        defer destroy_fracture_result(&result);
        assert(result.pieces.len == expected[variant][index]);
        foreach (piece : result.pieces) foreach (material : piece.mesh.triangle_materials) {
            assert(material == 11 || material == (operation == BooleanOperation.UNION ? 22 : 17));
            if (variant == 2) assert(material == 11);
        }
        if (variant == 2 && result.pieces.len) assert(result.pieces[0].mesh.geometry.indices.len == first.mesh.geometry.indices.len);
        assert(scratch.exact.count == 0);
    }
}


fn void refine_boolean_box_faces(ContainmentFixture* fixture) @local {
    uint[36] original;
    original[..] = fixture.indices[:36];
    uint count;
    for (uint face = 0; face < BOX_PLANES; face++) {
        uint offset = face * 6;
        uint[4] boundary = { original[offset], original[offset + 4], original[offset + 1], original[offset + 2] };
        uint center = 8 + face;
        fixture.positions[center] = {};
        foreach (vertex : boundary) fixture.positions[center] += fixture.positions[vertex] * 0.25f;
        fixture.identities[center] = center;
        for (uint corner = 0; corner < 4; corner++) {
            fixture.indices[count++] = boundary[corner];
            fixture.indices[count++] = boundary[(corner + 1) % 4];
            fixture.indices[count++] = center;
        }
    }
    fixture.vertex_count = 14;
    fixture.triangle_count = 24;
    fixture.mesh.geometry.positions = fixture.positions[:fixture.vertex_count];
    fixture.mesh.geometry.indices = fixture.indices[:count];
    fixture.mesh.topology_vertices = fixture.identities[:fixture.vertex_count];
    fixture.mesh.triangle_materials = fixture.materials[:fixture.triangle_count];
}

fn void reverse_boolean_surface_faces(ContainmentFixture* fixture) @local {
    uint[108] indices;
    uint[36] materials;
    indices[..] = fixture.indices[..];
    materials[..] = fixture.materials[..];
    for (uint face = 0; face < fixture.triangle_count; face++) {
        uint source = fixture.triangle_count - face - 1;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            fixture.indices[face * TRIANGLE_CORNERS + corner] = indices[source * TRIANGLE_CORNERS + (corner + 1) % TRIANGLE_CORNERS];
        }
        fixture.materials[face] = materials[source];
    }
}

fn void test_boolean_surface_coplanar_precedence_survives_unequal_source_tessellation() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    Vec3[24] normals;
    Vec2[24] uv0;
    Vec4[24] colors;
    normals[..] = { 0, 1, 0 };
    uv0[..] = { 4, 7 };
    colors[..] = { 0.25f, 0.5f, 0.75f, 1 };
    for (uint variant = 0; variant < 3; variant++) foreach (uint index, operation : SURFACE_BOOLEAN_OPERATIONS) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture first;
        ContainmentFixture second;
        boolean_surface_box_pair(&first, &second, variant == 0 ? 2 : variant == 1 ? 0 : 3);
        refine_boolean_box_faces(&second);
        first.mesh.geometry.normals = normals[:first.vertex_count];
        first.mesh.geometry.uv0 = uv0[:first.vertex_count];
        first.mesh.geometry.colors = colors[:first.vertex_count];
        long[3][3] volumes = { { 64, 64, 0 }, { 96, 32, 32 }, { 216, 8, 208 } };
        FractureResult result = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: operation,
            volume_quarters: volumes[variant][index] * 4, limits: limits,
        );
        defer destroy_fracture_result(&result);
        uint generated_triangles;
        foreach (piece : result.pieces) foreach (uint face, material : piece.mesh.triangle_materials) {
            if (material == 17) generated_triangles++;
            if (!variant) assert(material == 11);
            if (material != 11) continue;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                uint vertex = piece.mesh.geometry.indices[face * TRIANGLE_CORNERS + corner];
                assert(piece.mesh.geometry.normals[vertex] == normals[0]);
                assert(piece.mesh.geometry.uv0[vertex] == uv0[0]);
                assert(piece.mesh.geometry.colors[vertex] == colors[0]);
            }
        }
        if (!variant && result.pieces.len) assert(result.pieces[0].mesh.geometry.indices.len == 36);
        if (variant == 2 && operation != BooleanOperation.UNION) assert(generated_triangles == 12);
        reverse_boolean_surface_faces(&first);
        reverse_boolean_surface_faces(&second);
        scratch = begin_solid_scratch(&workspace);
        FractureResult repeated = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: operation,
            volume_quarters: volumes[variant][index] * 4, limits: limits,
        );
        defer destroy_fracture_result(&repeated);
        assert_same_publication(result, repeated);
    }
}

fn void test_boolean_surface_complex_solids_keep_cavities_islands_and_concavity() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    long[3][4] volume_quarters = { { 864, 224, 608 }, { 716, 32, 608 }, { 13, 3, 9 }, { 96, 32, 32 } };
    uint[3][4] expected = { { 1, 1, 1 }, { 2, 1, 1 }, { 1, 1, 1 }, { 1, 2, 2 } };
    for (uint shape = 0; shape < volume_quarters.len; shape++) foreach (uint index, operation : SURFACE_BOOLEAN_OPERATIONS) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture first;
        ContainmentFixture second;
        partition_fixture(&first, shape == 0 ? 1 : shape == 1 ? 2 : shape == 2 ? 4 : 3);
        if (!shape) append_box_fixture(&second, { -2, -2, -2 }, { 2, 2, 2 });
        if (shape == 1) append_box_fixture(&second, { -1.5f, -1.5f, -1.5f }, { 1.5f, 1.5f, 1.5f });
        if (shape == 2) append_box_fixture(&second, { 0.5f, 0.5f, 0 }, { 1.5f, 1.5f, 1 });
        if (shape == 3) append_box_fixture(&second, { -2, -1, -1 }, { 2, 1, 1 });
        first.materials[..] = 11;
        second.materials[..] = 22;
        FractureResult result = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: operation,
            volume_quarters: volume_quarters[shape][index], limits: limits,
        );
        defer destroy_fracture_result(&result);
        assert(result.pieces.len == expected[shape][index]);
        reverse_boolean_surface_faces(&first);
        reverse_boolean_surface_faces(&second);
        scratch = begin_solid_scratch(&workspace);
        FractureResult repeated = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: operation,
            volume_quarters: volume_quarters[shape][index], limits: limits,
        );
        defer destroy_fracture_result(&repeated);
        assert_same_publication(result, repeated);
    }
}

fn void test_boolean_surface_coplanar_subtraction_retains_holes_and_second_authored_streams() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture first;
    ContainmentFixture second;
    append_box_fixture(&first, { -1.5f, 0, 0 }, { -1, 0.5f, 1 });
    append_box_fixture(&second, { -2, -2, 0 }, { 2, 2, 1 });
    first.materials[..] = 11;
    second.materials[..] = 22;
    Vec3[24] normals;
    Vec2[24] uv0;
    Vec2[24] uv1;
    Vec4[24] colors;
    normals[..] = { 1, 0, 0 };
    uv0[..] = { 5, 9 };
    uv1[..] = { 13, 19 };
    colors[..] = { 0.5f, 0.25f, 1, 1 };
    second.mesh.geometry.normals = normals[:second.vertex_count];
    second.mesh.geometry.uv0 = uv0[:second.vertex_count];
    second.mesh.geometry.uv1 = uv1[:second.vertex_count];
    second.mesh.geometry.colors = colors[:second.vertex_count];
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { first.mesh, second.mesh }, limits.resolution_m)!!;
    SolidPartition partition = partition_boolean_cells(
        scratch: &scratch,
        first: &prepared.sources[0].solid.surface,
        first_source: &prepared.sources[0].constructions,
        second: &prepared.sources[1].solid.surface,
        second_source: &prepared.sources[1].constructions,
        operation: BooleanOperation.UNION,
    )!!;
    SurfacePiece[] pieces = build_boolean_surface_pieces(
        scratch: &scratch, prepared: &prepared, partition: &partition, operation: BooleanOperation.UNION, max_pieces: limits.max_pieces,
    )!!;
    uint holes;
    foreach (piece : pieces) foreach (patch : piece.patches) {
        assert(!patch.cut && !patch.shared_cut && patch.source);
        if (patch.source_index == 1) foreach (contour : patch.boundary.contours) holes += contour.hole ? 1 : 0;
    }
    assert(holes == 2);
    FractureResult result = publish_surface_pieces(
        allocator: mem, scratch: &scratch, limits: limits, pieces: pieces, grid: &prepared.grid,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 },
    )!!;
    defer destroy_fracture_result(&result);
    assert(result.pieces.len == 1);
    assert_published_valid(&scratch, result);
    bool authored_second;
    foreach (piece : result.pieces) foreach (uint face, material : piece.mesh.triangle_materials) {
        if (material != 22) continue;
        authored_second = true;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint vertex = piece.mesh.geometry.indices[face * TRIANGLE_CORNERS + corner];
            assert(piece.mesh.geometry.normals[vertex] == normals[0]);
            assert(piece.mesh.geometry.uv0[vertex] == uv0[0] && piece.mesh.geometry.uv1[vertex] == uv1[0]);
            assert(piece.mesh.geometry.colors[vertex] == colors[0]);
        }
    }
    assert(authored_second);
    for (uint index = 1; index < SURFACE_BOOLEAN_OPERATIONS.len; index++) {
        scratch = begin_solid_scratch(&workspace);
        FractureResult other = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: SURFACE_BOOLEAN_OPERATIONS[index],
            volume_quarters: index == 1 ? 1 : 0, limits: limits,
        );
        defer destroy_fracture_result(&other);
        assert(other.pieces.len == (index == 1 ? 1 : 0));
        foreach (piece : other.pieces) foreach (material : piece.mesh.triangle_materials) assert(material == 11);
    }
}

fn void test_boolean_surface_capacity_failure_restores_workspace_and_preserves_sources() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture first;
    ContainmentFixture second;
    boolean_surface_box_pair(&first, &second, 1);
    ContainmentFixture first_copy = first;
    ContainmentFixture second_copy = second;
    PreparedGeneration prepared = prepare_generation_sources(&scratch, { first.mesh, second.mesh }, limits.resolution_m)!!;
    SolidPartition partition = partition_boolean_cells(
        scratch: &scratch,
        first: &prepared.sources[0].solid.surface,
        first_source: &prepared.sources[0].constructions,
        second: &prepared.sources[1].solid.surface,
        second_source: &prepared.sources[1].constructions,
        operation: BooleanOperation.UNION,
    )!!;
    PartitionCell* first_cell = partition.first;
    uint original_count = partition.occupied_count;
    usz saved = scratch.used;
    assert(@catch(build_boolean_surface_pieces(
        scratch: &scratch, prepared: &prepared, partition: &partition, operation: BooleanOperation.UNION, max_pieces: 1,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    SurfacePiece[] complete = build_boolean_surface_pieces(
        scratch: &scratch, prepared: &prepared, partition: &partition, operation: BooleanOperation.UNION, max_pieces: limits.max_pieces,
    )!!;
    assert(complete.len == 2);
    usz required = scratch.peak;
    for (usz capacity = saved; capacity < required; capacity += 8191) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(build_boolean_surface_pieces(
            scratch: &scratch, prepared: &prepared, partition: &partition, operation: BooleanOperation.UNION, max_pieces: limits.max_pieces,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage;
    scratch.exact.count = EXACT_TEMPORARIES;
    set_integer(&scratch.exact.values[EXACT_TEMPORARIES - 1], 913);
    assert(@catch(build_boolean_surface_pieces(
        scratch: &scratch, prepared: &prepared, partition: &partition, operation: BooleanOperation.UNION, max_pieces: limits.max_pieces,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == EXACT_TEMPORARIES);
    assert(scratch.exact.values[EXACT_TEMPORARIES - 1].limbs[0] == 913);
    scratch.exact.count = 0;
    complete = build_boolean_surface_pieces(
        scratch: &scratch, prepared: &prepared, partition: &partition, operation: BooleanOperation.UNION, max_pieces: limits.max_pieces,
    )!!;
    assert(complete.len == 2 && partition.first == first_cell && partition.occupied_count == original_count);
    assert(first.positions == first_copy.positions && first.indices == first_copy.indices && first.materials == first_copy.materials);
    assert(second.positions == second_copy.positions && second.indices == second_copy.indices && second.materials == second_copy.materials);
    FractureResult recovered = publish_surface_pieces(
        allocator: mem, scratch: &scratch, limits: limits, pieces: complete, grid: &prepared.grid,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 },
    )!!;
    defer destroy_fracture_result(&recovered);
    assert_published_valid(&scratch, recovered);
}

fn void test_boolean_surface_second_source_cavities_and_concavity_preserve_cut_orientation() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    long[3][4] volume_quarters = { { 864, 224, 32 }, { 716, 32, 76 }, { 13, 3, 1 }, { 96, 32, 32 } };
    uint[3][4] expected = { { 1, 1, 1 }, { 2, 1, 1 }, { 1, 1, 1 }, { 1, 2, 1 } };
    for (uint shape = 0; shape < volume_quarters.len; shape++) foreach (uint index, operation : SURFACE_BOOLEAN_OPERATIONS) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture first;
        ContainmentFixture second;
        partition_fixture(&second, shape == 0 ? 1 : shape == 1 ? 2 : shape == 2 ? 4 : 3);
        if (!shape) append_box_fixture(&first, { -2, -2, -2 }, { 2, 2, 2 });
        if (shape == 1) append_box_fixture(&first, { -1.5f, -1.5f, -1.5f }, { 1.5f, 1.5f, 1.5f });
        if (shape == 2) append_box_fixture(&first, { 0.5f, 0.5f, 0 }, { 1.5f, 1.5f, 1 });
        if (shape == 3) append_box_fixture(&first, { -2, -1, -1 }, { 2, 1, 1 });
        first.materials[..] = 11;
        second.materials[..] = 22;
        FractureResult result = publish_boolean_fixture(
            scratch: &scratch, first: first.mesh, second: second.mesh, operation: operation,
            volume_quarters: volume_quarters[shape][index], limits: limits,
        );
        defer destroy_fracture_result(&result);
        assert(result.pieces.len == expected[shape][index]);
        foreach (piece : result.pieces) foreach (material : piece.mesh.triangle_materials) {
            assert(material == 11 || material == (operation == BooleanOperation.UNION ? 22 : 17));
        }
    }
}
