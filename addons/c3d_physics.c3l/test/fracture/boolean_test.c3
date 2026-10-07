module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_boolean_generation_operations_keep_volume_materials_and_source_ownership() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    double[3] volumes = { 20, 4, 8 };
    foreach (uint index, operation : BooleanOperation::values) {
        ContainmentFixture first;
        ContainmentFixture second;
        append_box_fixture(&first, { -2, -1, -1 }, { 1, 1, 1 });
        append_box_fixture(&second, { 0, -1, -1 }, { 3, 1, 1 });
        first.mesh.triangle_materials[..] = 5;
        second.mesh.triangle_materials[..] = 9;
        Vec3 first_point = first.positions[0];
        Vec3 second_point = second.positions[0];
        FractureResult result = create_boolean(
            allocator: &tracker, workspace: &workspace, first: first.mesh, second: second.mesh,
            operation: operation, cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
        )!!;
        assert(result.pieces.len == 1 && tracker.allocation_count() == 1);
        assert(first.positions[0] == first_point && second.positions[0] == second_point);
        assert(math::abs(generated_piece_volume(result.pieces[0]) - volumes[index]) < 1e-9);
        bool first_material;
        bool second_material;
        bool cut_material;
        foreach (material : result.pieces[0].mesh.triangle_materials) {
            first_material |= material == 5;
            second_material |= material == 9;
            cut_material |= material == 77;
            assert(material == 5 || material == 9 || material == 77);
        }
        assert(first_material);
        assert(second_material == (operation == BooleanOperation.UNION));
        assert(cut_material == (operation != BooleanOperation.UNION));
        first = {};
        second = {};
        ExactScratch* statistics = (ExactScratch*)workspace.storage.ptr;
        assert(statistics.statistics.final_leaf_count >= statistics.statistics.occupied_leaf_count);
        assert(statistics.statistics.occupied_leaf_count && statistics.count == 0);
        workspace.storage[..] = 0xa5;
        SolidScratch scratch = begin_solid_scratch(&workspace);
        assert_published_valid(&scratch, result);
        assert(math::abs(generated_piece_volume(result.pieces[0]) - volumes[index]) < 1e-9);
        destroy_fracture_result(&result);
        assert(tracker.allocation_count() == 0);
    }
}

fn void test_boolean_generation_regularizes_empty_touching_and_identical_volumes() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint relation = 0; relation < 3; relation++) {
        ContainmentFixture first;
        ContainmentFixture second;
        append_box_fixture(&first, { -1, -1, -1 }, { 1, 1, 1 });
        float offset = relation == 0 ? 0 : relation == 1 ? 2 : 4;
        append_box_fixture(&second, { offset - 1, -1, -1 }, { offset + 1, 1, 1 });
        first.mesh.triangle_materials[..] = 5;
        second.mesh.triangle_materials[..] = 9;
        foreach (operation : BooleanOperation::values) {
            FractureResult result = create_boolean(
                allocator: mem, workspace: &workspace, first: first.mesh, second: second.mesh,
                operation: operation, cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
            )!!;
            defer destroy_fracture_result(&result);
            bool empty = operation == BooleanOperation.INTERSECTION ? relation != 0
                : operation == BooleanOperation.DIFFERENCE && relation == 0;
            assert((result.pieces.len == 0) == empty && result.storage.ptr);
            if (empty) {
                assert(result.storage.len == 1);
                continue;
            }
            uint expected = operation == BooleanOperation.UNION && relation == 2 ? 2 : 1;
            assert(result.pieces.len == expected);
            if (!relation) {
                assert(result.pieces[0].mesh.geometry.indices.len == first.mesh.geometry.indices.len);
                foreach (material : result.pieces[0].mesh.triangle_materials) assert(material == 5);
            }
            SolidScratch scratch = begin_solid_scratch(&workspace);
            assert_published_valid(&scratch, result);
        }
    }
}

fn void test_boolean_generation_nested_cavity_and_split_components_are_closed() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture first;
    ContainmentFixture second;
    append_box_fixture(&first, { -3, -3, -3 }, { 3, 3, 3 });
    append_box_fixture(&second, { -1, -1, -1 }, { 1, 1, 1 });
    FractureResult hollow = create_boolean(
        allocator: mem, workspace: &workspace, first: first.mesh, second: second.mesh,
        operation: BooleanOperation.DIFFERENCE, cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
    )!!;
    defer destroy_fracture_result(&hollow);
    assert(hollow.pieces.len == 1 && math::abs(generated_piece_volume(hollow.pieces[0]) - 208) < 1e-9);
    second = {};
    append_box_fixture(&second, { -1, -4, -4 }, { 1, 4, 4 });
    FractureResult split = create_boolean(
        allocator: mem, workspace: &workspace, first: first.mesh, second: second.mesh,
        operation: BooleanOperation.DIFFERENCE, cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
    )!!;
    defer destroy_fracture_result(&split);
    assert(split.pieces.len == 2);
    foreach (piece : split.pieces) assert(math::abs(generated_piece_volume(piece) - 72) < 1e-9);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    assert_published_valid(&scratch, hollow);
    assert_published_valid(&scratch, split);
}

fn void test_boolean_generation_failure_keeps_workspace_reusable_without_output_owner() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture first;
    ContainmentFixture second;
    append_box_fixture(&first, { -2, -1, -1 }, { 1, 1, 1 });
    append_box_fixture(&second, { 0, -1, -1 }, { 3, 1, 1 });
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits original = workspace.limits;
    char[] storage = workspace.storage;
    for (uint variant = 0; variant < 6; variant++) {
        workspace.limits = original;
        workspace.storage = storage;
        SolidMeshView input = second.mesh;
        CutSurface cut = { .material_slot = 77, .uv_repeats_per_meter = 1 };
        fault expected = c3d::CAPACITY_EXCEEDED;
        switch (variant) {
            case 0: workspace.limits.max_vertices = 1;
            case 1: workspace.limits.max_triangles = 1;
            case 2: workspace.storage = storage[:MIN_FRACTURE_SCRATCH_BYTES];
            case 3: input.topology_vertices = {}; expected = c3d::INVALID_ARGUMENT;
            case 4: input.geometry.topology = Topology.LINES; expected = c3d::UNSUPPORTED;
            case 5: cut.uv_repeats_per_meter = 0; expected = c3d::INVALID_ARGUMENT;
        }
        assert(@catch(create_boolean(
            allocator: &tracker, workspace: &workspace, first: first.mesh, second: input,
            operation: BooleanOperation.DIFFERENCE, cut: cut,
        )) == expected);
        assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
        assert(((ExactScratch*)storage.ptr).count == 0);
    }
    workspace.limits = original;
    workspace.storage = storage;
    NullAllocator unavailable;
    tracker.inner_allocator = &unavailable;
    assert(@catch(create_boolean(
        allocator: &tracker, workspace: &workspace, first: first.mesh, second: second.mesh,
        operation: BooleanOperation.UNION, cut: { .material_slot = 77, .uv_repeats_per_meter = 1 },
    )) == c3d::CAPACITY_EXCEEDED);
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
    tracker.inner_allocator = mem;
    FractureResult recovered = create_boolean(
        allocator: &tracker, workspace: &workspace, first: first.mesh, second: second.mesh,
        operation: BooleanOperation.UNION, cut: { .material_slot = 77, .uv_repeats_per_meter = 1 },
    )!!;
    assert(recovered.pieces.len == 1 && tracker.allocation_count() == 1);
    destroy_fracture_result(&recovered);
    assert(tracker.allocation_count() == 0);
}
