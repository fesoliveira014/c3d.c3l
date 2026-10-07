module c3d::physics::fracture;

import std::io;
import std::sort;
import std::time;

const uint COMPONENT_SCALING_MAX_WIDTH @local = 16;
const uint COMPONENT_SCALING_REPEATS @local = 3;

fn void test_components_scaling() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, {
        .scratch_bytes = 64 * 1024 * 1024,
        .max_vertices = BOX_VERTICES,
        .max_triangles = BOX_PLANES * 2,
        .max_pieces = COMPONENT_SCALING_MAX_WIDTH * COMPONENT_SCALING_MAX_WIDTH * COMPONENT_SCALING_MAX_WIDTH,
        .max_sites = 1,
        .max_hulls = 1,
        .resolution_m = 0.125,
    })!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint width = 2; width <= COMPONENT_SCALING_MAX_WIDTH; width *= 2) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        uint count = width * width * width;
        PartitionCell[] cells = reserve_elements(&scratch, PartitionCell, count)!!;
        GridPoint[1] grid;
        SolidBvhNode[1] bounds;
        SolidSurface surface = { .grid = grid[..], .nodes = bounds[..] };
        for (uint x = 0; x < width; x++) for (uint y = 0; y < width; y++) for (uint z = 0; z < width; z++) {
            uint index = (x * width + y) * width + z;
            bounds[0].bounds = { .lower = { x, y, z }, .upper = { (long)(x + 1), (long)(y + 1), (long)(z + 1) } };
            cells[index] = {
                .cell = create_bounds_cell(&scratch, &surface)!!,
                .next = index + 1 < count ? &cells[index + 1] : null,
                .occupied = true,
            };
        }
        SolidPartition partition = { .first = &cells[0], .cell_count = count, .occupied_count = count };
        usz retained = scratch.used;
        ulong[COMPONENT_SCALING_REPEATS] nanoseconds;
        ulong predicates;
        ulong clips;
        usz peak;
        uint wide;
        for (uint repeat = 0; repeat <= COMPONENT_SCALING_REPEATS; repeat++) {
            scratch.used = retained;
            scratch.peak = retained;
            scratch.exact.peak = 0;
            scratch.exact.predicate_count = 0;
            scratch.exact.filtered_count = 0;
            scratch.exact.exact_nanoseconds = 0;
            ulong measured_clips;
            std::time::Clock started = clock::now();
            SolidPartition[] components = partition_material_components(&scratch, &partition, &measured_clips)!!;
            ulong elapsed = (ulong)started.to_now();
            assert(components.len == 1 && components[0].occupied_count == count);
            assert(measured_clips == (ulong)(count - 1) && scratch.exact.count == 0);
            if (repeat) {
                assert(predicates == scratch.exact.predicate_count && clips == measured_clips);
                nanoseconds[repeat - 1] = elapsed;
            }
            predicates = scratch.exact.predicate_count;
            clips = measured_clips;
            peak = scratch.peak;
            wide = scratch.exact.peak;
        }
        sort::quicksort(nanoseconds[..]);
        io::printfn(
            "components_scaling cells=%d median_ns=%d predicates=%d clips=%d peak_bytes=%d added_bytes=%d wide=%d",
            count, nanoseconds[COMPONENT_SCALING_REPEATS / 2], predicates, clips, peak, peak - retained, wide);
    }
}
