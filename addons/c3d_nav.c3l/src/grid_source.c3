module c3d::nav;

import std::math;
import c3d;

<*
 Sample a world-space height or an absent vertex.
 @param [inout] context : "Caller-owned sampling state."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
alias GridHeightSampleFn = fn GridHeightSample? (void* context, float world_x, float world_z);

<* Half-open integer bounds in XZ. *>
struct GridRange {
    int min_x;
    int min_z;
    int max_x;
    int max_z;
}

<* Borrowed row-major height vertices with stride measured in samples. *>
struct GridHeightView {
    float[]      samples;
    uint         width;
    uint         height;
    usz          row_stride;
    Vec3         origin;
    float        cell_size;
    float        height_scale;
    float        height_offset;
    GridDiagonal diagonal;
    char         area;
}

<* A sampled world height, optionally absent. *>
struct GridHeightSample {
    float height;
    bool  present;
}

<* Borrowed sampler on the navigation grid's vertex lattice. *>
struct GridHeightSampler {
    Vec3               origin;
    float              cell_size;
    GridHeightSampleFn sample;
    void*              context;
    GridDiagonal       diagonal;
    char               area;
}

<*
 Adapt borrowed regular heights to corner-triangulated floors.
 @param [&in] view : "Metadata stays fixed while the source is borrowed."
 @return? c3d::INVALID_ARGUMENT
*>
fn GridSourceDesc? grid_height_source(GridHeightView* view, float min_height, float max_height) {
    validate_height_source(
        origin: view.origin,
        cell_size: view.cell_size,
        min_height: min_height,
        max_height: max_height,
        diagonal: view.diagonal,
        area: view.area,
    )!;
    if (view.width < 2 || view.height < 2 || view.row_stride < view.width) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(view.height_scale) || !math::is_finite(view.height_offset)) return c3d::INVALID_ARGUMENT~;
    if ((usz)(view.height - 1) * view.row_stride + view.width > view.samples.len) return c3d::INVALID_ARGUMENT~;

    return {
        .origin = view.origin,
        .min_height = min_height,
        .max_height = max_height,
        .context = view,
        .capture = &capture_height_view,
        .cell_size = view.cell_size,
    };
}

<*
 Adapt borrowed world samples to corner-triangulated floors.
 @param [&in] sampler : "Metadata stays fixed while the source is borrowed."
 @return? c3d::INVALID_ARGUMENT
*>
fn GridSourceDesc? grid_sampled_source(GridHeightSampler* sampler, float min_height, float max_height) {
    validate_height_source(
        origin: sampler.origin,
        cell_size: sampler.cell_size,
        min_height: min_height,
        max_height: max_height,
        diagonal: sampler.diagonal,
        area: sampler.area,
    )!;
    if (!sampler.sample) return c3d::INVALID_ARGUMENT~;

    return {
        .origin = sampler.origin,
        .min_height = min_height,
        .max_height = max_height,
        .context = sampler,
        .capture = &capture_height_sampler,
        .cell_size = sampler.cell_size,
    };
}

<*
 Select every tile whose capture window intersects edited cells.
 @param border_size : "Capture halo in cells."
 @param extent : "Configured tile-coordinate bounds."
 @return? c3d::INVALID_ARGUMENT
*>
fn GridRange? grid_dirty_tiles(
    GridRange cells,
    uint tile_size,
    uint border_size,
    GridRange extent,
) {
    if (!valid_grid_range(cells) || !valid_grid_range(extent) || tile_size == 0) return c3d::INVALID_ARGUMENT~;
    if (empty_grid_range(cells) || empty_grid_range(extent)) return {};

    // Signed floor division preserves the same capture windows left of the origin.
    long first_x = grid_floor_divide((long)cells.min_x - border_size, tile_size);
    long first_z = grid_floor_divide((long)cells.min_z - border_size, tile_size);
    long past_x = grid_floor_divide((long)cells.max_x + border_size - 1, tile_size) + 1;
    long past_z = grid_floor_divide((long)cells.max_z + border_size - 1, tile_size) + 1;

    GridRange result = {
        .min_x = (int)math::clamp(first_x, (long)extent.min_x, (long)extent.max_x),
        .min_z = (int)math::clamp(first_z, (long)extent.min_z, (long)extent.max_z),
        .max_x = (int)math::clamp(past_x, (long)extent.min_x, (long)extent.max_x),
        .max_z = (int)math::clamp(past_z, (long)extent.min_z, (long)extent.max_z),
    };
    if (empty_grid_range(result)) return {};

    return result;
}

<*
 Expand edited vertices to all incident cells.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn GridRange? grid_vertex_cells(GridRange vertices) {
    if (!valid_grid_range(vertices)) return c3d::INVALID_ARGUMENT~;
    if (empty_grid_range(vertices)) return {};
    if (vertices.min_x == int::min || vertices.min_z == int::min) return c3d::CAPACITY_EXCEEDED~;

    return {
        .min_x = vertices.min_x - 1,
        .min_z = vertices.min_z - 1,
        .max_x = vertices.max_x,
        .max_z = vertices.max_z,
    };
}

<*
 Enclose a closed world-space XZ edit in incident cells.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn GridRange? grid_world_cells(Aabb bounds, Vec3 origin, float cell_size) {
    if (!math::is_finite(cell_size) || cell_size <= 0) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(origin.x) || !math::is_finite(origin.z)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(bounds.min.x) || !math::is_finite(bounds.min.z)
        || !math::is_finite(bounds.max.x) || !math::is_finite(bounds.max.z)) return c3d::INVALID_ARGUMENT~;
    if (bounds.min.x > bounds.max.x || bounds.min.z > bounds.max.z) return c3d::INVALID_ARGUMENT~;

    double first_x = ((double)bounds.min.x - origin.x) / cell_size;
    double first_z = ((double)bounds.min.z - origin.z) / cell_size;
    double last_x = ((double)bounds.max.x - origin.x) / cell_size;
    double last_z = ((double)bounds.max.z - origin.z) / cell_size;

    // Closed edits touch both cells when an endpoint lies on their shared edge.
    double min_x = math::ceil(first_x) - 1;
    double min_z = math::ceil(first_z) - 1;
    double max_x = math::floor(last_x) + 1;
    double max_z = math::floor(last_z) + 1;
    if (min_x < int::min || min_z < int::min || max_x > int::max || max_z > int::max) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    return { .min_x = (int)min_x, .min_z = (int)min_z, .max_x = (int)max_x, .max_z = (int)max_z };
}

fn usz? capture_grid_floors(
    GridSourceDesc* source,
    int cell_x,
    int cell_z,
    GridFloor[] output,
) @private {
    if (source.capture) {
        return source.capture(
            context: source.context,
            cell_x: cell_x,
            cell_z: cell_z,
            out_floors: output,
        );
    }

    return source.floors(
        context: source.context,
        cell_x: cell_x,
        cell_z: cell_z,
        out_floors: output,
    );
}

fn usz? capture_height_view(
    void* context,
    int cell_x,
    int cell_z,
    GridFloor[] out_floors,
) @local {
    GridHeightView* view = context;
    if (cell_x < 0 || cell_z < 0 || (uint)cell_x >= view.width - 1 || (uint)cell_z >= view.height - 1) return 0;

    float[4] corners;
    foreach (index, offset_x : DETAIL_CORNER_X) {
        usz sample_index = (usz)cell_x + (usz)offset_x + ((usz)cell_z + (usz)DETAIL_CORNER_Z[index]) * view.row_stride;
        float height = view.samples[sample_index] * view.height_scale + view.height_offset;
        if (!math::is_finite(height)) return c3d::INVALID_ARGUMENT~;
        corners[index] = height;
    }

    out_floors[0] = height_grid_floor(corners, view.diagonal, view.area);
    return 1;
}

fn usz? capture_height_sampler(
    void* context,
    int cell_x,
    int cell_z,
    GridFloor[] out_floors,
) @local {
    GridHeightSampler* sampler = context;
    float[4] corners;
    bool present = true;
    foreach (index, offset_x : DETAIL_CORNER_X) {
        float world_x = (float)((double)sampler.origin.x + (double)((long)cell_x + offset_x) * sampler.cell_size);
        float world_z = (float)((double)sampler.origin.z + (double)((long)cell_z + DETAIL_CORNER_Z[index]) * sampler.cell_size);
        if (!math::is_finite(world_x) || !math::is_finite(world_z)) return c3d::CAPACITY_EXCEEDED~;

        GridHeightSample sample = sampler.sample(sampler.context, world_x, world_z)!;
        if (sample.present && !math::is_finite(sample.height)) return c3d::INVALID_ARGUMENT~;
        present &= sample.present;
        corners[index] = sample.height;
    }
    if (!present) return 0;

    out_floors[0] = height_grid_floor(corners, sampler.diagonal, sampler.area);
    return 1;
}

fn GridFloor height_grid_floor(float[4] corners, GridDiagonal diagonal, char area) @local {
    return {
        .ceiling = float::max,
        .area = area,
        .floor_kind = GridSurfaceKind.CORNERS,
        .floor_corners = corners,
        .diagonal = diagonal,
    };
}

fn void? validate_height_source(
    Vec3 origin,
    float cell_size,
    float min_height,
    float max_height,
    GridDiagonal diagonal,
    char area,
) @local {
    if (!math::is_finite(origin.x) || !math::is_finite(origin.z)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(cell_size) || cell_size <= 0) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(min_height) || !math::is_finite(max_height) || min_height >= max_height) {
        return c3d::INVALID_ARGUMENT~;
    }
    if ((uint)diagonal > (uint)GridDiagonal.MAX_MIN_TO_MIN_MAX || area >= MAX_AREAS) return c3d::INVALID_ARGUMENT~;
}

fn bool valid_grid_range(GridRange range) @local => range.min_x <= range.max_x && range.min_z <= range.max_z;

fn bool empty_grid_range(GridRange range) @local => range.min_x == range.max_x || range.min_z == range.max_z;

fn long grid_floor_divide(long value, long divisor) @local {
    long quotient = value / divisor;
    if (value % divisor < 0) quotient--;
    return quotient;
}
