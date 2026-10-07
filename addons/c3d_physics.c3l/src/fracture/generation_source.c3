module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

struct PreparedSource @private {
    ValidatedSolid solid;
    SourceConstructions constructions;
}

struct PreparedGeneration @private {
    PreparedSource[2] sources;
    QuantizationGrid grid;
    uint count;
}

fn long generation_coordinate_key(float coordinate) @local {
    uint bits = bitcast(coordinate, uint);
    long magnitude = bits & ~((uint)1 << FLOAT_SIGN_BIT);
    return (bits >> FLOAT_SIGN_BIT) ? -magnitude : magnitude;
}

fn float generation_bound_coordinate(long key) @local {
    uint bits = (uint)(key < 0 ? -key : key);
    if (key < 0) bits |= (uint)1 << FLOAT_SIGN_BIT;
    return bitcast(bits, float);
}

fn int compare_generation_sites(uint first, uint second, Vec3[]* sites) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        long left = generation_coordinate_key((*sites)[first][axis]);
        long right = generation_coordinate_key((*sites)[second][axis]);
        if (left != right) return left < right ? -1 : 1;
    }
    return 0;
}

fn void? quantize_generation_source(
    SolidScratch* scratch,
    ValidatedSolid* solid,
    QuantizationGrid* grid,
) @local {
    SolidDiagnostic diagnostic;
    solid.surface.grid = reserve_elements(scratch, GridPoint, solid.surface.topology.vertices.len)!;
    foreach (uint identity, vertex : solid.surface.topology.vertices) {
        if (!vertex.degree) continue;
        solid.surface.grid[identity] = quantize_point(scratch.exact, *grid, surface_position(&solid.surface, identity))!;
    }
    if (catch failure = recheck_quantized_solid(solid, &diagnostic)) {
        if (failure == INVALID_SOLID) return NUMERICAL_FAILURE~;
        return failure~;
    }
    return;
}

<* @require inputs.len > 0 && inputs.len <= 2 *>
fn PreparedGeneration? prepare_generation_sources(
    SolidScratch* scratch,
    SolidMeshView[] inputs,
    float resolution,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    PreparedGeneration prepared = { .count = (uint)inputs.len };
    SolidBounds bounds;
    foreach (uint index, input : inputs) {
        SolidDiagnostic diagnostic;
        prepared.sources[index].solid = validate_solid(
            scratch: scratch,
            source: input,
            grid: null,
            diagnostic: &diagnostic,
        )!;
        SolidBounds source_bounds = prepared.sources[index].solid.surface.nodes[0].bounds;
        bounds = index ? joined_solid_bounds(bounds, source_bounds) : source_bounds;
    }
    Vec3 lower;
    Vec3 upper;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        lower[axis] = generation_bound_coordinate(bounds.lower[axis]);
        upper[axis] = generation_bound_coordinate(bounds.upper[axis]);
    }
    prepared.grid = create_quantization_grid(
        scratch: scratch.exact,
        lower: lower,
        upper: upper,
        resolution: resolution,
    )!;
    for (uint index = 0; index < prepared.count; index++) {
        PreparedSource* source = &prepared.sources[index];
        quantize_generation_source(scratch, &source.solid, &prepared.grid)!;
        source.constructions = build_source_constructions(scratch, &source.solid.surface)!;
    }
    return prepared;
}

fn GridPoint[]? prepare_voronoi_sites(
    SolidScratch* scratch,
    QuantizationGrid grid,
    Vec3[] sites,
    uint max_sites,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    if (!sites.len) return c3d::INVALID_ARGUMENT~;
    if (sites.len > max_sites) return c3d::CAPACITY_EXCEEDED~;
    foreach (site : sites) if (!finite_position(site)) return c3d::INVALID_ARGUMENT~;
    GridPoint[] points = reserve_elements(scratch, GridPoint, sites.len)!;
    if (sites.len == 1) {
        points[0] = {};
        return points;
    }
    usz retained = scratch.used;
    defer scratch.used = retained;
    uint[] ordered = reserve_elements(scratch, uint, sites.len)!;
    foreach (uint index, &slot : ordered) *slot = index;
    sort::quicksort(ordered, &compare_generation_sites, &sites);
    for (usz index = 1; index < ordered.len; index++) {
        if (same_position(sites[ordered[index - 1]], sites[ordered[index]])) return c3d::INVALID_ARGUMENT~;
    }
    foreach (uint index, site : sites) points[index] = quantize_point(scratch.exact, grid, site)!;
    return points;
}
