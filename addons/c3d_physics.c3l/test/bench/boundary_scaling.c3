module c3d::physics::fracture;

import c3d;
import std::io;
import std::math;
import std::sort;
import std::time;

const uint SCALING_MAX_DIVISIONS @local = 8;
const uint SCALING_MAX_VERTICES @local = (SCALING_MAX_DIVISIONS + 1) * (SCALING_MAX_DIVISIONS + 1) * (SCALING_MAX_DIVISIONS + 1);
const uint SCALING_MAX_TRIANGLES @local = 12 * SCALING_MAX_DIVISIONS * SCALING_MAX_DIVISIONS;
const uint SCALING_REPEATS @local = 3;

struct ScalingBox @local {
    Vec3[SCALING_MAX_VERTICES] positions;
    uint[SCALING_MAX_VERTICES] identities;
    uint[SCALING_MAX_TRIANGLES * TRIANGLE_CORNERS] indices;
    uint[SCALING_MAX_TRIANGLES] materials;
    SolidMeshView mesh;
}

fn void make_scaling_box(ScalingBox* box, uint divisions) @local {
    uint width = divisions + 1;
    uint vertices = width * width * width;
    for (uint x = 0; x < width; x++) for (uint y = 0; y < width; y++) for (uint z = 0; z < width; z++) {
        uint vertex = (x * width + y) * width + z;
        box.positions[vertex] = { -1 + 2.0f * x / divisions, -1 + 2.0f * y / divisions, -1 + 2.0f * z / divisions };
        box.identities[vertex] = vertex;
    }
    uint count;
    for (uint axis = 0; axis < SPACE_AXES; axis++) for (uint side = 0; side < 2; side++) {
        for (uint row = 0; row < divisions; row++) for (uint column = 0; column < divisions; column++) {
            uint[4] corners;
            for (uint corner = 0; corner < corners.len; corner++) {
                uint[3] point;
                point[axis] = side * divisions;
                point[(axis + 1) % SPACE_AXES] = row + ((corner == 1 || corner == 2) ? 1 : 0);
                point[(axis + 2) % SPACE_AXES] = column + (corner >= 2 ? 1 : 0);
                corners[corner] = (point[0] * width + point[1]) * width + point[2];
            }
            uint[6] order = { 0, 1, 2, 0, 2, 3 };
            if (!side) order = { 0, 2, 1, 0, 3, 2 };
            foreach (corner : order) box.indices[count++] = corners[corner];
        }
    }
    box.mesh = {
        .geometry = { .positions = box.positions[:vertices], .indices = box.indices[:count] },
        .topology_vertices = box.identities[:vertices], .triangle_materials = box.materials[:count / TRIANGLE_CORNERS],
    };
}

fn void test_boundary_scaling() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, {
        .scratch_bytes = 64 * 1024 * 1024, .max_vertices = SCALING_MAX_VERTICES,
        .max_triangles = SCALING_MAX_TRIANGLES, .max_pieces = 2, .max_sites = 2, .max_hulls = 2, .resolution_m = 0.125,
    })!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint divisions = 1; divisions <= SCALING_MAX_DIVISIONS; divisions *= 2) {
        ScalingBox fixture;
        make_scaling_box(&fixture, divisions);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        ValidatedSolid solid = validate_solid(
            scratch: &scratch,
            source: fixture.mesh,
            grid: null,
            diagnostic: &diagnostic,
        )!!;
        SourceConstructions source = build_source_constructions(&scratch, &solid.surface)!!;
        SolidPartition partition = partition_solid(&scratch, &solid.surface, &source)!!;
        ExactPlane cut;
        plane_from_integers(scratch.exact, &cut, { 3, 2, 1, 0 })!!;
        for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
            if (!cell.occupied) continue;
            CellSplit split = split_convex_cell(&scratch, &cell.cell, &cut)!!;
            cell.cell = split.negative;
            cell.occupied = cell.cell.vertices.len != 0;
        }
        usz retained = scratch.used;
        ulong[SCALING_REPEATS] nanoseconds;
        ulong[SCALING_REPEATS] predicates;
        uint patch_count;
        usz peak;
        for (uint repeat = 0; repeat <= SCALING_REPEATS; repeat++) {
            scratch.used = retained;
            scratch.peak = retained;
            scratch.exact.predicate_count = 0;
            scratch.exact.filtered_count = 0;
            scratch.exact.exact_nanoseconds = 0;
            std::time::Clock started = clock::now();
            BoundaryCellFace[] faces = index_boundary_cell_faces(&scratch, &partition)!!;
            BoundaryPatch[] patches = source_boundary_patches(
                scratch: &scratch,
                surface: &solid.surface,
                source: &source,
                partition: &partition,
                cuts: { &cut },
                faces: faces,
            )!!;
            PlanarSegment[] segments = collect_boundary_segments(
                scratch: &scratch,
                partition: &partition,
                plane: &cut,
                faces: faces,
            )!!;
            BoundaryPatch cap = create_boundary_patch(
                scratch: &scratch,
                plane: &cut,
                segments: segments,
                reversed: false,
            )!!;
            BoundaryPatch[] combined = reserve_elements(&scratch, BoundaryPatch, patches.len + 1)!!;
            combined[:patches.len] = patches[..];
            combined[^1] = cap;
            reconcile_patch_boundaries(&scratch, combined)!!;
            ulong elapsed = (ulong)started.to_now();
            assert(combined.len > 1 && combined[^1].corners.len >= 3 && scratch.exact.count == 0);
            patch_count = (uint)combined.len;
            peak = scratch.peak;
            if (!repeat) continue;
            nanoseconds[repeat - 1] = elapsed;
            predicates[repeat - 1] = scratch.exact.predicate_count;
        }
        sort::quicksort(nanoseconds[..]);
        sort::quicksort(predicates[..]);
        io::printfn("boundary_scaling triangles=%d patches=%d median_ns=%d predicates=%d peak_bytes=%d",
            fixture.mesh.geometry.indices.len / TRIANGLE_CORNERS, patch_count, nanoseconds[1], predicates[1], peak);
    }
}
