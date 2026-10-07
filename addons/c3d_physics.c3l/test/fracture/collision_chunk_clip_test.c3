module c3d::physics::fracture;

import c3d;
import std::math;

fn void? validate_collision_chunk_topology(
    SolidScratch* scratch,
    CollisionChunk* chunk,
    BoundaryPatch[] patches,
    SurfacePointMap* points,
    uint first_patch,
) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;

    PatchTriangles[] triangles = reserve_elements(scratch, PatchTriangles, patches.len)!;
    usz count;
    foreach (index, &patch : patches) {
        triangles[index] = triangulate_boundary_patch(scratch, patch)!;
        count += triangles[index].triangles.len * TRIANGLE_CORNERS;
    }

    uint[] indices = reserve_elements(scratch, uint, count)!;
    uint written;
    foreach (uint patch, &faces : triangles) {
        OrientedPatchTriangles oriented = {
            .shared = faces, .reversed = patches[patch].reversed != chunk.patches[patch].flip,
        };

        for (uint triangle = 0; triangle < faces.triangles.len; triangle++) {
            foreach (corner : oriented_patch_triangle(oriented, triangle)) {
                indices[written++] = points.vertices[points.patch_offsets[first_patch + patch] + corner];
            }
        }
    }

    SolidMeshView mesh = collision_indexed_mesh(scratch, points.positions, indices)!;
    (void)build_solid_topology(scratch, mesh)!;
    return;
}

fn void assert_collision_chunk_planes(ExactScratch* scratch, CollisionChunk* chunk, float resolution) @local {
    foreach (face : chunk.patches) {
        foreach (other : chunk.patches) {
            foreach (point : other.boundary.boundary.vertices) {
                int side = plane_side(scratch, face.boundary.plane, point)!!;
                if (!side || (side > 0) == (face.boundary.reversed != face.flip)) continue;

                assert(within_collision_plane_distance(
                    scratch: scratch,
                    plane: face.boundary.plane,
                    vertex: point,
                    resolution: resolution,
                )!!);
            }
        }
    }
}

fn SurfacePointMap collision_clip_topology(SolidScratch* scratch, CollisionChunks* chunks) @local {
    usz count;
    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) count += chunk.patches.len;

    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, count)!!;
    uint first;
    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
        foreach (uint index, patch : chunk.patches) patches[first + index] = patch.boundary;
        reconcile_patch_boundaries(scratch, patches[first:chunk.patches.len])!!;
        first += (uint)chunk.patches.len;
    }

    SurfacePointMap points = map_surface_points(scratch, patches)!!;
    first = 0;
    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
        validate_collision_chunk_topology(
            scratch: scratch,
            chunk: chunk,
            patches: patches[first:chunk.patches.len],
            points: &points,
            first_patch: first,
        )!!;
        first += (uint)chunk.patches.len;
    }

    return points;
}

fn void test_collision_chunk_clip_rotated_reflex_edges_keep_two_closed_chunks() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);

    for (uint sample = 0; sample < 12; sample++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture fixture;
        rotate_collision_fixture(&fixture, 4, sample);

        SolidDiagnostic diagnostic;
        ValidatedSolid solid = validate_solid(
            scratch: &scratch, source: fixture.mesh, grid: null, diagnostic: &diagnostic,
        )!!;
        SourceConstructions source = build_source_constructions(&scratch, &solid.surface)!!;
        CollisionChunks chunks = partition_collision_chunks(
            scratch: &scratch, solid: &solid, source: &source, resolution: workspace.limits.resolution_m,
        )!!;
        assert(chunks.count == 2 && chunks.cuts.len == 1);
        assert(!plane_side(scratch.exact, chunks.cuts[0], source.vertices[3])!!);
        assert(!plane_side(scratch.exact, chunks.cuts[0], source.vertices[9])!!);

        uint original_points;
        foreach (point : source.vertices) original_points += plane_side(scratch.exact, chunks.cuts[0], point)!! ? 0 : 1;
        assert(original_points >= 3);

        CollisionChunkPatch[2] caps;
        uint cap_count;
        for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
            assert_collision_chunk_planes(scratch.exact, chunk, workspace.limits.resolution_m);
            foreach (patch : chunk.patches) {
                if (!patch.cut) continue;
                assert(cap_count < caps.len);
                caps[cap_count++] = patch;
            }
        }
        assert(cap_count == 2 && caps[0].flip != caps[1].flip);
        assert(caps[0].boundary.boundary.vertices.ptr == caps[1].boundary.boundary.vertices.ptr);
        assert(caps[0].boundary.corners.ptr == caps[1].boundary.corners.ptr);

        (void)collision_clip_topology(&scratch, &chunks);
        assert(scratch.exact.count == 0);
    }
}

fn void test_collision_chunk_clip_keeps_nested_convex_island_separate() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    rotate_collision_fixture(&fixture, 2, 4);

    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch, source: fixture.mesh, grid: null, diagnostic: &diagnostic,
    )!!;
    SourceConstructions source = build_source_constructions(&scratch, &solid.surface)!!;
    CollisionChunks chunks = partition_collision_chunks(
        scratch: &scratch, solid: &solid, source: &source, resolution: workspace.limits.resolution_m,
    )!!;
    uint islands;

    for (CollisionChunk* chunk = chunks.first; chunk; chunk = chunk.next) {
        if (chunk.component != 1) continue;
        assert_collision_chunk_planes(scratch.exact, chunk, workspace.limits.resolution_m);
        islands++;
        assert(chunk.patches.len == 12);

        foreach (patch : chunk.patches) {
            assert(!patch.cut);
            foreach (point : patch.boundary.boundary.vertices) {
                bool original;
                for (uint vertex = 16; vertex < 24; vertex++) original |= same_vertex(scratch.exact, point, source.vertices[vertex])!!;
                assert(original);
            }
        }
    }

    assert(islands == 1 && scratch.peak <= workspace.limits.scratch_bytes && scratch.exact.count == 0);
    (void)collision_clip_topology(&scratch, &chunks);
}

fn void test_collision_chunk_clip_triangle_permutations_preserve_exact_cut_planes() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);

    foreach (shape : (uint[3]){ 4, 1, 2 }) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture first;
        ContainmentFixture second;
        rotate_collision_fixture(&first, shape, 4);
        rotate_collision_fixture(&second, shape, 4);

        for (uint face = 0; face < second.triangle_count; face++) {
            uint opposite = second.triangle_count - face - 1;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                second.indices[face * TRIANGLE_CORNERS + corner] = first.indices[opposite * TRIANGLE_CORNERS + (corner + 1) % TRIANGLE_CORNERS];
            }
        }

        SolidDiagnostic diagnostic;
        ValidatedSolid first_solid = validate_solid(
            scratch: &scratch, source: first.mesh, grid: null, diagnostic: &diagnostic,
        )!!;
        SourceConstructions first_source = build_source_constructions(&scratch, &first_solid.surface)!!;
        CollisionChunks original = partition_collision_chunks(
            scratch: &scratch, solid: &first_solid, source: &first_source, resolution: workspace.limits.resolution_m,
        )!!;
        SurfacePointMap original_points = collision_clip_topology(&scratch, &original);

        ValidatedSolid second_solid = validate_solid(
            scratch: &scratch, source: second.mesh, grid: null, diagnostic: &diagnostic,
        )!!;
        SourceConstructions second_source = build_source_constructions(&scratch, &second_solid.surface)!!;
        CollisionChunks permuted = partition_collision_chunks(
            scratch: &scratch, solid: &second_solid, source: &second_source, resolution: workspace.limits.resolution_m,
        )!!;
        SurfacePointMap permuted_points = collision_clip_topology(&scratch, &permuted);

        assert(original.count == permuted.count && original.cuts.len == permuted.cuts.len);
        foreach (uint index, plane : original.cuts) assert(!compare_exact_planes(plane, permuted.cuts[index]));
        assert(original_points.exact.len == permuted_points.exact.len);
        foreach (uint index, point : original_points.exact) {
            assert(same_vertex(scratch.exact, point, permuted_points.exact[index])!!);
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                assert(bitcast(original_points.positions[index][axis], uint) == bitcast(permuted_points.positions[index][axis], uint));
            }
        }
        assert(scratch.exact.count == 0);
    }
}

fn void test_collision_chunk_clip_capacity_failure_preserves_source_and_reuses_scratch() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    rotate_collision_fixture(&fixture, 4, 1);
    ContainmentFixture original = fixture;

    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: &scratch, source: fixture.mesh, grid: null, diagnostic: &diagnostic,
    )!!;
    SourceConstructions source = build_source_constructions(&scratch, &solid.surface)!!;
    usz saved = scratch.used;
    CollisionChunks complete = partition_collision_chunks(
        scratch: &scratch, solid: &solid, source: &source, resolution: workspace.limits.resolution_m,
    )!!;
    assert(complete.count == 2);
    usz required = scratch.peak;

    for (usz capacity = saved; capacity < required; capacity += 8191) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(partition_collision_chunks(
            scratch: &scratch, solid: &solid, source: &source, resolution: workspace.limits.resolution_m,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }

    scratch.used = saved;
    scratch.storage = workspace.storage;
    scratch.exact.count = EXACT_TEMPORARIES;
    set_integer(&scratch.exact.values[EXACT_TEMPORARIES - 1], 913);
    assert(@catch(partition_collision_chunks(
        scratch: &scratch, solid: &solid, source: &source, resolution: workspace.limits.resolution_m,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == EXACT_TEMPORARIES);
    assert(scratch.exact.values[EXACT_TEMPORARIES - 1].limbs[0] == 913);

    scratch.exact.count = 0;
    CollisionChunks recovered = partition_collision_chunks(
        scratch: &scratch, solid: &solid, source: &source, resolution: workspace.limits.resolution_m,
    )!!;
    assert(recovered.count == 2 && recovered.cuts.len == 1);
    assert(fixture.positions == original.positions && fixture.indices == original.indices);
    assert(solid.surface.validated && scratch.exact.count == 0);
}
