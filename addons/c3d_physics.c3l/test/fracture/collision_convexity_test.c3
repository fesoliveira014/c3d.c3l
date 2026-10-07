module c3d::physics::fracture;

import c3d;

fn void test_collision_chunk_convexity_keeps_opposite_constraints_and_rewinds_temporary_storage() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch, source: fixture.mesh, grid: null, diagnostic: &diagnostic,
    )!!;
    SourceConstructions source = build_source_constructions(&scratch, &solid.surface)!!;
    CollisionChunk chunk = { .patches = collision_source_patches(&scratch, &solid.surface, &source)!! };
    usz retained = scratch.used;
    assert(collision_chunk_convex(&scratch, &chunk, workspace.limits.resolution_m)!!);
    assert(scratch.used == retained && scratch.exact.count == 0);

    foreach (&point : chunk.patches[0].boundary.boundary.vertices) {
        *point = { (*point)[2], (*point)[0], (*point)[1] };
    }
    assert(collision_chunk_convex(&scratch, &chunk, workspace.limits.resolution_m)!!);
    assert(scratch.used == retained && scratch.exact.count == 0);

    chunk.patches[0].flip = true;
    assert(!collision_chunk_convex(&scratch, &chunk, workspace.limits.resolution_m)!!);
    assert(scratch.used == retained && scratch.exact.count == 0);
    chunk.patches[0].flip = false;

    scratch.storage = workspace.storage[:retained];
    assert(@catch(collision_chunk_convex(&scratch, &chunk, workspace.limits.resolution_m)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == retained && scratch.exact.count == 0);
    scratch.storage = workspace.storage;
    assert(collision_chunk_convex(&scratch, &chunk, workspace.limits.resolution_m)!!);
    assert(scratch.used == retained && scratch.exact.count == 0);
}
