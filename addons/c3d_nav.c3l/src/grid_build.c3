module c3d::nav;

import std::math;
import c3d;

const uint GRID_QUAD_VERTICES @local = 4;
const uint GRID_EDGE_CUT_CAPACITY @local = 2 + 6 * (MAX_GRID_FLOORS - 1); // endpoints and three cuts per competitor per side
const uint GRID_COMPACT_INDEX_LIMIT @local = (1u << 24) - 1;

struct GridColumn @private {
    GridFloor[] floors;
    uint        span_base;
}

struct GridReference @private {
    GridColumn[] columns;
    uint         width;
    uint         height;
    uint         border_size;
    uint         span_count;
    int          first_x;
    int          first_z;
}

struct GridEdgeProfile @private {
    double[2] height;
    double[2] ceiling;
    double    min;
    double    max;
    ushort    ordinal;
    bool      ceiling_open;
}

struct GridEdgeRoot @private {
    PrecisionInterval bounds;
    PrecisionInterval numerator;
    PrecisionInterval denominator;
}

struct GridEdgeMatch @private {
    ushort       first;
    ushort       second;
    GridEdgeRoot min;
    GridEdgeRoot max;
    bool         include_min;
    bool         include_max;
}

struct GridPairRange @local {
    GridEdgeRoot min;
    GridEdgeRoot max;
    bool         active;
}

struct GridPartialEdge @local {
    GridPartialEdge* next;
    uint             first_column;
    uint             second_column;
    uint             direction;
    GridEdgeMatch[]  matches;
}

struct GridPolygonSide @local {
    uint polygon;
    uint edge;
}

struct GridConnection @local {
    uint   source_column;
    uint   target_column;
    uint   direction;
    ushort source_floor;
    ushort target_floor;
    float  min;
    float  max;
}

fn char[]? build_bounded_grid(GridTileBuilder* builder, int tile_x, int tile_z) @private {
    GridReference reference = capture_grid_reference(builder, tile_x, tile_z)!;
    if (!reference.span_count) return {};

    CompactHeightfield compact = grid_compact_reference(builder, &reference)!;
    GridPartialEdge* partials = connect_grid_edges(builder, &reference, &compact)!;
    if (builder.tile_config.walkable_radius) {
        compact.erode_walkable_area(&builder.arena, builder.tile_config.walkable_radius)!;
    }

    filter_grid_regions(
        builder: builder,
        reference: &reference,
        compact: &compact,
        partials: partials,
    )!;

    return pack_grid_cells(
        builder: builder,
        reference: &reference,
        compact: &compact,
        partials: partials,
        tile_x: tile_x,
        tile_z: tile_z,
    );
}

fn GridReference? capture_grid_reference(GridTileBuilder* builder, int tile_x, int tile_z) @private {
    TileConfig* tile = &builder.tile_config;
    ulong column_count = (ulong)tile.width * tile.height;
    if (column_count > int::max) return c3d::CAPACITY_EXCEEDED~;
    if (column_count > (ulong)sz::max / GridColumn::size) return c3d::CAPACITY_EXCEEDED~;

    long first_x = (long)tile_x * builder.config.tile_size - tile.border_size;
    long first_z = (long)tile_z * builder.config.tile_size - tile.border_size;
    if (first_x < int::min || first_z < int::min) return c3d::INVALID_ARGUMENT~;
    if (first_x + tile.width - 1 > int::max || first_z + tile.height - 1 > int::max) return c3d::INVALID_ARGUMENT~;

    GridColumn[]? allocated = alloc::new_array_try(&builder.arena, GridColumn, (sz)column_count);
    if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
    GridReference reference = {
        .columns = allocated,
        .width = tile.width,
        .height = tile.height,
        .border_size = tile.border_size,
        .first_x = (int)first_x,
        .first_z = (int)first_z,
    };

    GridFloor[MAX_GRID_FLOORS] storage;
    for (uint z = 0; z < tile.height; z++) {
        for (uint x = 0; x < tile.width; x++) {
            // Flat callbacks may leave the optional corner fields untouched.
            foreach (&floor : storage) *floor = {};
            usz count = builder.source.floors(
                context: builder.source.context,
                cell_x: reference.first_x + (int)x,
                cell_z: reference.first_z + (int)z,
                out_floors: storage[..],
            );
            if (count > MAX_GRID_FLOORS) return c3d::INVALID_ARGUMENT~;
            validate_grid_floors(storage[:count], &builder.source, DetailMode.BOUNDED)!;
            if (count > (usz)(GRID_COMPACT_INDEX_LIMIT - reference.span_count)) return c3d::CAPACITY_EXCEEDED~;

            GridColumn* column = &reference.columns[x + z * tile.width];
            column.span_base = reference.span_count;
            if (count) {
                GridFloor[]? floors = alloc::alloc_array_try(&builder.arena, GridFloor, (sz)count);
                if (catch floors) return c3d::CAPACITY_EXCEEDED~;
                column.floors = floors;
                column.floors[..] = storage[:count];
            }
            reference.span_count += (uint)count;
        }
    }

    return reference;
}

fn usz? grid_edge_matches(
    GridEdgeProfile[] first,
    GridEdgeProfile[] second,
    NavBuildConfig* config,
    GridEdgeMatch[] output,
) @private {
    if (first.len > MAX_GRID_FLOORS || second.len > MAX_GRID_FLOORS) return c3d::CAPACITY_EXCEEDED~;

    GridPairRange[MAX_GRID_FLOORS * MAX_GRID_FLOORS] storage;
    GridPairRange[] pairs = storage[:first.len * second.len];
    foreach (first_index, first_profile : first) {
        foreach (second_index, second_profile : second) {
            pairs[first_index * second.len + second_index] =
              grid_pair_range(first_profile, second_profile, config)!;
        }
    }

    usz count;
    foreach (first_index, first_profile : first) {
        foreach (second_index, second_profile : second) {
            GridPairRange pair = pairs[first_index * second.len + second_index];
            if (!pair.active) continue;

            GridEdgeRoot[GRID_EDGE_CUT_CAPACITY] cuts;
            usz cut_count = 2;
            cuts[0] = pair.min;
            cuts[1] = pair.max;

            foreach (candidate, profile : second) {
                if (candidate == second_index) continue;
                add_grid_winner_cuts(
                    cuts: cuts[..],
                    count: &cut_count,
                    range: pair,
                    competitor: pairs[first_index * second.len + candidate],
                    source: first_profile,
                    selected: second_profile,
                    other: profile,
                )!;
            }

            foreach (candidate, profile : first) {
                if (candidate == first_index) continue;
                add_grid_winner_cuts(
                    cuts: cuts[..],
                    count: &cut_count,
                    range: pair,
                    competitor: pairs[candidate * second.len + second_index],
                    source: second_profile,
                    selected: first_profile,
                    other: profile,
                )!;
            }

            GridEdgeMatch match = { .first = first_profile.ordinal, .second = second_profile.ordinal };
            bool open;
            for (usz index = 1; index < cut_count; index++) {
                double parameter = (cuts[index - 1].bounds.max + cuts[index].bounds.min) * 0.5;
                GridEdgeRoot sample = grid_edge_point(parameter)!;
                if (compare_grid_roots(sample, cuts[index - 1])! <= 0
                    || compare_grid_roots(sample, cuts[index])! >= 0) return c3d::CAPACITY_EXCEEDED~;

                bool selected = grid_pair_wins(
                    first: first,
                    second: second,
                    pairs: pairs,
                    first_index: (usz)first_index,
                    second_index: (usz)second_index,
                    sample: sample,
                )!;
                if (selected) {
                    if (open && !match.include_max) {
                        append_grid_match(output, &count, match)!;
                        open = false;
                    }

                    if (!open) {
                        match.min = cuts[index - 1];
                        match.include_min = grid_pair_wins(
                            first: first,
                            second: second,
                            pairs: pairs,
                            first_index: (usz)first_index,
                            second_index: (usz)second_index,
                            sample: match.min,
                        )!;
                    }

                    match.max = cuts[index];
                    match.include_max = grid_pair_wins(
                        first: first,
                        second: second,
                        pairs: pairs,
                        first_index: (usz)first_index,
                        second_index: (usz)second_index,
                        sample: match.max,
                    )!;
                    open = true;
                } else if (open) {
                    append_grid_match(output, &count, match)!;
                    open = false;
                }
            }

            if (open) append_grid_match(output, &count, match)!;
        }
    }

    return count;
}

fn GridPairRange? grid_pair_range(GridEdgeProfile first, GridEdgeProfile second, NavBuildConfig* config) @local {
    GridPairRange range = {
        .min = grid_edge_point(math::max(first.min, second.min))!,
        .max = grid_edge_point(math::min(first.max, second.max))!,
        .active = first.min < first.max && second.min < second.max,
    };
    if (!range.active || compare_grid_roots(range.min, range.max)! >= 0) return {};

    PrecisionInterval climb = precision_point(config.agent_max_climb)!;
    PrecisionInterval height = precision_point(config.agent_height)!;
    PrecisionInterval[2] rise;
    for (uint endpoint = 0; endpoint < 2; endpoint++) {
        rise[endpoint] = precision_subtract(
            left: precision_point(second.height[endpoint])!,
            right: precision_point(first.height[endpoint])!,
        )!;
    }

    clip_grid_pair(&range, precision_subtract(climb, rise[0])!, precision_subtract(climb, rise[1])!)!;
    clip_grid_pair(&range, precision_add(climb, rise[0])!, precision_add(climb, rise[1])!)!;

    // Crossing the edge needs headroom above either floor.
    for (uint ceiling = 0; ceiling < 2; ceiling++) {
        GridEdgeProfile upper = ceiling ? second : first;
        if (upper.ceiling_open) continue;
        for (uint floor = 0; floor < 2; floor++) {
            GridEdgeProfile lower = floor ? second : first;
            PrecisionInterval begin = precision_subtract(
                precision_subtract(precision_point(upper.ceiling[0])!, precision_point(lower.height[0])!)!,
                height,
            )!;
            PrecisionInterval end = precision_subtract(
                precision_subtract(precision_point(upper.ceiling[1])!, precision_point(lower.height[1])!)!,
                height,
            )!;
            clip_grid_pair(&range, begin, end)!;
        }
    }

    return range;
}

fn void? clip_grid_pair(GridPairRange* range, PrecisionInterval first, PrecisionInterval second) @local {
    if (!range.active) return;

    int first_sign = grid_interval_sign(first)!;
    int second_sign = grid_interval_sign(second)!;
    if (first_sign < 0 && second_sign < 0) {
        range.active = false;
        return;
    }
    if (first_sign >= 0 && second_sign >= 0) return;

    GridEdgeRoot root = grid_linear_root(first, second)!;
    if (first_sign < 0) {
        if (compare_grid_roots(root, range.min)! > 0) range.min = root;
    } else if (compare_grid_roots(root, range.max)! < 0) {
        range.max = root;
    }

    range.active = compare_grid_roots(range.min, range.max)! < 0;
}

fn void? add_grid_winner_cuts(
    GridEdgeRoot[] cuts,
    usz* count,
    GridPairRange range,
    GridPairRange competitor,
    GridEdgeProfile source,
    GridEdgeProfile selected,
    GridEdgeProfile other,
) @local {
    if (!competitor.active || compare_grid_roots(competitor.max, range.min)! <= 0
        || compare_grid_roots(competitor.min, range.max)! >= 0) return;

    insert_grid_cut(
        cuts: cuts,
        count: count,
        range: range,
        cut: competitor.min,
    )!;
    insert_grid_cut(
        cuts: cuts,
        count: count,
        range: range,
        cut: competitor.max,
    )!;

    PrecisionInterval first = grid_rise_midpoint(
        source: source,
        first: selected,
        second: other,
        endpoint: 0,
    )!;
    PrecisionInterval second = grid_rise_midpoint(
        source: source,
        first: selected,
        second: other,
        endpoint: 1,
    )!;
    int first_sign = grid_interval_sign(first)!;
    int second_sign = grid_interval_sign(second)!;
    if (first_sign == second_sign) return;

    GridEdgeRoot root = grid_linear_root(first, second)!;
    if (compare_grid_roots(root, competitor.min)! < 0
        || compare_grid_roots(root, competitor.max)! > 0) return;

    insert_grid_cut(
        cuts: cuts,
        count: count,
        range: range,
        cut: root,
    )!;
}

fn bool? grid_pair_wins(
    GridEdgeProfile[] first,
    GridEdgeProfile[] second,
    GridPairRange[] pairs,
    usz first_index,
    usz second_index,
    GridEdgeRoot sample,
) @local {
    // Require the same winning pair in both directions.
    for (uint pass = 0; pass < 2; pass++) {
        GridEdgeProfile source = pass ? second[second_index] : first[first_index];
        GridEdgeProfile selected = pass ? first[first_index] : second[second_index];
        GridEdgeProfile[] choices = pass ? first : second;
        foreach (index, other : choices) {
            if (other.ordinal == selected.ordinal) continue;

            usz pair_index = pass ? (usz)index * (usz)second.len + second_index
              : first_index * (usz)second.len + (usz)index;
            GridPairRange range = pairs[pair_index];
            if (!range.active || compare_grid_roots(sample, range.min)! < 0
                || compare_grid_roots(sample, range.max)! > 0) continue;

            PrecisionInterval begin = grid_rise_midpoint(
                source: source,
                first: selected,
                second: other,
                endpoint: 0,
            )!;
            PrecisionInterval end = grid_rise_midpoint(
                source: source,
                first: selected,
                second: other,
                endpoint: 1,
            )!;
            int sign = precision_compare_products(
                first: begin,
                second: precision_subtract(sample.denominator, sample.numerator)!,
                third: precision_subtract(precision_point(0)!, end)!,
                fourth: sample.numerator,
            )!;
            // Ordinals keep equal-climb choices deterministic.
            if (sign == 0) {
                if (other.ordinal < selected.ordinal) return false;
            } else if ((other.ordinal < selected.ordinal && sign > 0)
                || (other.ordinal > selected.ordinal && sign < 0)) {
                return false;
            }
        }
    }

    return true;
}

fn PrecisionInterval? grid_rise_midpoint(
    GridEdgeProfile source,
    GridEdgeProfile first,
    GridEdgeProfile second,
    uint endpoint,
) @local {
    return precision_subtract(
        precision_add(precision_point(first.height[endpoint])!, precision_point(second.height[endpoint])!)!,
        precision_multiply(precision_point(2)!, precision_point(source.height[endpoint])!)!,
    );
}

fn GridEdgeRoot? grid_edge_point(double value) @private {
    PrecisionInterval point = precision_point(value)!;
    return { .bounds = point, .numerator = point, .denominator = precision_point(1)! };
}

fn GridEdgeRoot? grid_linear_root(PrecisionInterval first, PrecisionInterval second) @private {
    if (first.min == 0 && first.max == 0) return grid_edge_point(0);
    if (second.min == 0 && second.max == 0) return grid_edge_point(1);

    PrecisionInterval denominator = precision_subtract(first, second)!;
    // Positive denominators preserve cross-product ordering.
    if (denominator.max < 0) {
        first = precision_subtract(precision_point(0)!, first)!;
        denominator = precision_subtract(precision_point(0)!, denominator)!;
    }
    if (denominator.min <= 0) return c3d::CAPACITY_EXCEEDED~;

    return {
        .bounds = precision_divide(first, denominator)!,
        .numerator = first,
        .denominator = denominator,
    };
}

fn int? compare_grid_roots(GridEdgeRoot first, GridEdgeRoot second) @private {
    if (first.bounds.max < second.bounds.min) return -1;
    if (first.bounds.min > second.bounds.max) return 1;

    return precision_compare_products(
        first: first.numerator,
        second: second.denominator,
        third: second.numerator,
        fourth: first.denominator,
    );
}

fn int? grid_interval_sign(PrecisionInterval value) @local {
    if (value.min > 0) return 1;
    if (value.max < 0) return -1;
    if (value.min == 0 && value.max == 0) return 0;

    // An unresolved sign cannot select a stable edge interval.
    return c3d::CAPACITY_EXCEEDED~;
}

fn void? insert_grid_cut(
    GridEdgeRoot[] cuts,
    usz* count,
    GridPairRange range,
    GridEdgeRoot cut,
) @local {
    if (compare_grid_roots(cut, range.min)! <= 0
        || compare_grid_roots(cut, range.max)! >= 0) return;

    usz slot;
    while (slot < *count) {
        int order = compare_grid_roots(cut, cuts[slot])!;
        if (order == 0) return;
        if (order < 0) break;
        slot++;
    }

    if (*count == cuts.len) return c3d::CAPACITY_EXCEEDED~;
    for (usz index = *count; index > slot; index--) cuts[index] = cuts[index - 1];
    cuts[slot] = cut;
    (*count)++;
}

fn void? append_grid_match(GridEdgeMatch[] output, usz* count, GridEdgeMatch match) @local {
    if (*count >= DEFAULT_DETAIL_TRIANGLES
        || (output.len && *count == output.len)) return c3d::CAPACITY_EXCEEDED~;

    if (output.len) output[*count] = match;
    (*count)++;
}

fn CompactHeightfield? grid_compact_reference(GridTileBuilder* builder, GridReference* reference) @local {
    Allocator arena = &builder.arena;
    CompactCell[]? cells = alloc::new_array_try(arena, CompactCell, (sz)reference.columns.len);
    if (catch cells) return c3d::CAPACITY_EXCEEDED~;
    CompactSpan[]? spans = alloc::new_array_try(arena, CompactSpan, reference.span_count);
    if (catch spans) return c3d::CAPACITY_EXCEEDED~;
    char[]? areas = alloc::new_array_try(arena, char, reference.span_count);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;

    CompactHeightfield compact = {
        .width = reference.width,
        .height = reference.height,
        .span_count = reference.span_count,
        .cells = cells,
        .spans = spans,
        .areas = areas,
    };

    double slope = math::tan((double)builder.config.agent_max_slope_degrees * math::PI / 180.0);
    foreach (column_index, column : reference.columns) {
        long cell_x = (long)reference.first_x + (long)(column_index % reference.width);
        long cell_z = (long)reference.first_z + (long)(column_index / reference.width);
        double width = (double)grid_world_coordinate(builder.source.origin.x, cell_x + 1, builder.config.cell_size)!
            - grid_world_coordinate(builder.source.origin.x, cell_x, builder.config.cell_size)!;
        double depth = (double)grid_world_coordinate(builder.source.origin.z, cell_z + 1, builder.config.cell_size)!
            - grid_world_coordinate(builder.source.origin.z, cell_z, builder.config.cell_size)!;
        if (width <= 0 || depth <= 0) return c3d::CAPACITY_EXCEEDED~;

        compact.cells[column_index] = { .index = column.span_base, .count = (uint)column.floors.len };
        foreach (ordinal, &floor : column.floors) {
            uint span = column.span_base + (uint)ordinal;
            compact.spans[span].links.connections = GRID_COMPACT_INDEX_LIMIT;
            if (floor.area == NULL_AREA) continue;
            if (!grid_surface_slope(
                floor: floor,
                width: width,
                depth: depth,
                maximum_gradient: slope * slope,
            )) continue;

            if (floor.ceiling_kind == GridSurfaceKind.FLAT && floor.ceiling == float::max
                && ordinal + 1 == column.floors.len) {
                compact.areas[span] = floor.area;
                continue;
            }

            bool admitted = true;
            for (uint point = 0; point <= DETAIL_CORNER_X.len; point++) {
                double sample_x = point < DETAIL_CORNER_X.len ? (double)DETAIL_CORNER_X[point] : 0.5;
                double sample_z = point < DETAIL_CORNER_Z.len ? (double)DETAIL_CORNER_Z[point] : 0.5;
                double height = grid_floor_height(floor, sample_x, sample_z);
                double ceiling = grid_effective_ceiling(
                    floors: column.floors,
                    ordinal: (usz)ordinal,
                    cell_x: sample_x,
                    cell_z: sample_z,
                );
                PrecisionInterval headroom = precision_subtract(precision_point(ceiling)!, precision_point(height)!)!;
                if (headroom.max < builder.config.agent_height) {
                    admitted = false;
                    break;
                }
                if (headroom.min < builder.config.agent_height) return c3d::CAPACITY_EXCEEDED~;
            }

            if (admitted) compact.areas[span] = floor.area;
        }
    }

    return compact;
}

fn bool grid_surface_slope(
    GridFloor* floor,
    double width,
    double depth,
    double maximum_gradient,
) @local {
    if (floor.floor_kind == GridSurfaceKind.FLAT) return true;

    for (uint triangle = 0; triangle < 2; triangle++) {
        uint[3] corners = grid_triangle_corners(floor.diagonal, triangle);
        double x1 = (double)(DETAIL_CORNER_X[corners[1]] - DETAIL_CORNER_X[corners[0]]) * width;
        double z1 = (double)(DETAIL_CORNER_Z[corners[1]] - DETAIL_CORNER_Z[corners[0]]) * depth;
        double x2 = (double)(DETAIL_CORNER_X[corners[2]] - DETAIL_CORNER_X[corners[0]]) * width;
        double z2 = (double)(DETAIL_CORNER_Z[corners[2]] - DETAIL_CORNER_Z[corners[0]]) * depth;
        double y1 = (double)floor.floor_corners[corners[1]] - floor.floor_corners[corners[0]];
        double y2 = (double)floor.floor_corners[corners[2]] - floor.floor_corners[corners[0]];

        double determinant = x1 * z2 - x2 * z1;
        double gradient_x = (y1 * z2 - y2 * z1) / determinant;
        double gradient_z = (x1 * y2 - x2 * y1) / determinant;
        if (gradient_x * gradient_x + gradient_z * gradient_z > maximum_gradient) return false;
    }

    return true;
}

fn GridPartialEdge*? connect_grid_edges(
    GridTileBuilder* builder,
    GridReference* reference,
    CompactHeightfield* compact,
) @local {
    GridPartialEdge* partials;
    GridEdgeProfile[MAX_GRID_FLOORS] first_profiles;
    GridEdgeProfile[MAX_GRID_FLOORS] second_profiles;
    for (uint z = 0; z < reference.height; z++) {
        for (uint x = 0; x < reference.width; x++) {
            uint first_column = x + z * reference.width;
            for (uint direction = 1; direction <= 2; direction++) {
                uint other_x = x + (uint)dir_offset_x(direction);
                uint other_z = z + (uint)dir_offset_z(direction);
                if (other_x >= reference.width || other_z >= reference.height) continue;

                uint second_column = other_x + other_z * reference.width;
                GridColumn* first = &reference.columns[first_column];
                GridColumn* second = &reference.columns[second_column];
                if (!first.floors.len || !second.floors.len) continue;

                grid_edge_profiles(
                    column: first,
                    areas: compact.areas,
                    direction: direction,
                    profiles: first_profiles[:first.floors.len],
                );
                grid_edge_profiles(
                    column: second,
                    areas: compact.areas,
                    direction: (direction + 2) & 3,
                    profiles: second_profiles[:second.floors.len],
                );
                usz count = grid_edge_matches(
                    first: first_profiles[:first.floors.len],
                    second: second_profiles[:second.floors.len],
                    config: &builder.config,
                    output: {},
                )!;
                if (!count) continue;

                sz mark = builder.arena.mark();
                GridEdgeMatch[]? allocated = alloc::new_array_try(&builder.arena, GridEdgeMatch, (sz)count);
                if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
                GridEdgeMatch[] matches = allocated;
                (void)grid_edge_matches(
                    first: first_profiles[:first.floors.len],
                    second: second_profiles[:second.floors.len],
                    config: &builder.config,
                    output: matches,
                )!;
                // Full-width links need no separate partial-portal record.
                usz partial_count;
                foreach (match : matches) {
                    if (match.min.bounds.min == 0 && match.min.bounds.max == 0
                        && match.max.bounds.min == 1 && match.max.bounds.max == 1
                        && match.include_min && match.include_max) {
                        compact.spans[first.span_base + match.first].set_connection(direction, match.second);
                        compact.spans[second.span_base + match.second].set_connection((direction + 2) & 3, match.first);
                    } else {
                        matches[partial_count++] = match;
                    }
                }

                if (!partial_count || (!builder.tile_config.min_region_area
                    && !grid_core_column(reference, first_column) && !grid_core_column(reference, second_column))) {
                    builder.arena.reset(mark);
                    continue;
                }

                GridPartialEdge*? record = alloc::new_try(&builder.arena, GridPartialEdge);
                if (catch record) return c3d::CAPACITY_EXCEEDED~;
                *record = {
                    .next = partials,
                    .first_column = first_column,
                    .second_column = second_column,
                    .direction = direction,
                    .matches = matches[:partial_count],
                };
                partials = record;
            }
        }
    }

    return partials;
}

fn void grid_edge_profiles(
    GridColumn* column,
    char[] areas,
    uint direction,
    GridEdgeProfile[] profiles,
) @private {
    foreach (ordinal, &floor : column.floors) {
        GridEdgeProfile profile = {
            .ordinal = (ushort)ordinal,
            .ceiling_open = floor.ceiling_kind == GridSurfaceKind.FLAT && floor.ceiling == float::max
                && ordinal + 1 == column.floors.len,
        };

        for (uint endpoint = 0; endpoint < 2; endpoint++) {
            double cell_x = direction == 0 ? 0 : direction == 2 ? 1 : (double)endpoint;
            double cell_z = direction == 3 ? 0 : direction == 1 ? 1 : (double)endpoint;
            profile.height[endpoint] = grid_floor_height(floor, cell_x, cell_z);
            profile.ceiling[endpoint] = grid_effective_ceiling(
                floors: column.floors,
                ordinal: (usz)ordinal,
                cell_x: cell_x,
                cell_z: cell_z,
            );
        }

        if (areas[column.span_base + ordinal] != NULL_AREA) profile.max = 1;
        profiles[ordinal] = profile;
    }
}

fn bool grid_core_column(GridReference* reference, uint column) @local {
    uint x = column % reference.width;
    uint z = column / reference.width;
    return x >= reference.border_size && x < reference.width - reference.border_size
        && z >= reference.border_size && z < reference.height - reference.border_size;
}

fn void? filter_grid_regions(
    GridTileBuilder* builder,
    GridReference* reference,
    CompactHeightfield* compact,
    GridPartialEdge* partials,
) @local {
    if (!builder.tile_config.min_region_area) return;

    sz mark = builder.arena.mark();
    defer builder.arena.reset(mark);
    uint[]? parents = alloc::new_array_try(&builder.arena, uint, reference.span_count);
    if (catch parents) return c3d::CAPACITY_EXCEEDED~;
    uint[]? counts = alloc::new_array_try(&builder.arena, uint, reference.span_count);
    if (catch counts) return c3d::CAPACITY_EXCEEDED~;
    bool[]? touches_border = alloc::new_array_try(&builder.arena, bool, reference.span_count);
    if (catch touches_border) return c3d::CAPACITY_EXCEEDED~;

    for (uint index = 0; index < reference.span_count; index++) parents[index] = index;
    foreach (column_index, column : reference.columns) {
        for (usz ordinal = 0; ordinal < column.floors.len; ordinal++) {
            uint span = column.span_base + (uint)ordinal;
            if (compact.areas[span] == NULL_AREA) continue;
            for (uint direction = 1; direction <= 2; direction++) {
                uint layer = compact.spans[span].connection(direction);
                if (layer == NOT_CONNECTED) continue;
                uint neighbour_column = (uint)column_index + (direction == 1 ? reference.width : 1);
                uint neighbour = reference.columns[neighbour_column].span_base + layer;
                if (compact.areas[neighbour] != NULL_AREA) join_grid_components(parents, span, neighbour);
            }
        }
    }

    for (GridPartialEdge* edge = partials; edge; edge = edge.next) {
        foreach (match : edge.matches) {
            uint first = reference.columns[edge.first_column].span_base + match.first;
            uint second = reference.columns[edge.second_column].span_base + match.second;
            if (compact.areas[first] != NULL_AREA && compact.areas[second] != NULL_AREA) {
                join_grid_components(parents, first, second);
            }
        }
    }

    // Border-touching components may continue into neighbouring tiles.
    foreach (column_index, column : reference.columns) {
        bool core = grid_core_column(reference, (uint)column_index);
        for (usz ordinal = 0; ordinal < column.floors.len; ordinal++) {
            uint span = column.span_base + (uint)ordinal;
            if (compact.areas[span] == NULL_AREA) continue;
            uint root = grid_component_root(parents, span);
            if (core) {
                counts[root]++;
            } else {
                touches_border[root] = true;
            }
        }
    }

    foreach (column_index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)column_index)) continue;
        for (usz ordinal = 0; ordinal < column.floors.len; ordinal++) {
            uint span = column.span_base + (uint)ordinal;
            uint root = grid_component_root(parents, span);
            if (!touches_border[root] && counts[root] < builder.tile_config.min_region_area)
                compact.areas[span] = NULL_AREA;
        }
    }
}

fn uint grid_component_root(uint[] parents, uint index) @local {
    while (parents[index] != index) {
        parents[index] = parents[parents[index]];
        index = parents[index];
    }

    return index;
}

fn void join_grid_components(uint[] parents, uint first, uint second) @local {
    first = grid_component_root(parents, first);
    second = grid_component_root(parents, second);
    parents[math::max(first, second)] = math::min(first, second);
}

fn char[]? pack_grid_cells(
    GridTileBuilder* builder,
    GridReference* reference,
    CompactHeightfield* compact,
    GridPartialEdge* partials,
    int tile_x,
    int tile_z,
) @local {
    uint cell_count;
    foreach (column_index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)column_index)) continue;
        for (usz ordinal = 0; ordinal < column.floors.len; ordinal++) {
            if (compact.areas[column.span_base + ordinal] != NULL_AREA) cell_count++;
        }
    }
    if (!cell_count) return {};
    if (cell_count > (MESH_NULL_INDEX - 1) / GRID_QUAD_VERTICES) return c3d::CAPACITY_EXCEEDED~;

    bool triangles = builder.config.verts_per_poly == 3;
    uint polygons_per_cell = triangles ? 2 : 1;
    uint vertex_count = cell_count * GRID_QUAD_VERTICES;
    uint polygon_count = cell_count * polygons_per_cell;
    uint stride = triangles ? 3 : GRID_QUAD_VERTICES;
    uint portal_count = grid_portal_count(reference, compact, partials)!;

    Allocator arena = &builder.arena;
    ushort[]? vertices = alloc::new_array_try(arena, ushort, (sz)vertex_count * 3);
    if (catch vertices) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? polygons = alloc::new_array_try(arena, ushort, (sz)polygon_count * stride * 2);
    if (catch polygons) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? regions = alloc::new_array_try(arena, ushort, polygon_count);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? flags = alloc::new_array_try(arena, ushort, polygon_count);
    if (catch flags) return c3d::CAPACITY_EXCEEDED~;
    char[]? areas = alloc::new_array_try(arena, char, polygon_count);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;
    Vec3[]? corners = alloc::new_array_try(arena, Vec3, vertex_count);
    if (catch corners) return c3d::CAPACITY_EXCEEDED~;
    PolyDetail[]? details = alloc::new_array_try(arena, PolyDetail, polygon_count);
    if (catch details) return c3d::CAPACITY_EXCEEDED~;
    DetailPortal[]? portals = alloc::new_array_try(arena, DetailPortal, portal_count);
    if (catch portals) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? span_polygons = alloc::new_array_try(arena, ushort, reference.span_count);
    if (catch span_polygons) return c3d::CAPACITY_EXCEEDED~;

    span_polygons[..] = MESH_NULL_INDEX;
    polygons[..] = MESH_NULL_INDEX;

    long origin_x = (long)tile_x * builder.config.tile_size;
    long origin_z = (long)tile_z * builder.config.tile_size;
    Vec3 origin = {
        grid_world_coordinate(builder.source.origin.x, origin_x, builder.config.cell_size)!,
        0,
        grid_world_coordinate(builder.source.origin.z, origin_z, builder.config.cell_size)!,
    };
    Vec3 maximum = {
        grid_world_coordinate(builder.source.origin.x, origin_x + builder.config.tile_size, builder.config.cell_size)!,
        builder.source.max_height,
        grid_world_coordinate(builder.source.origin.z, origin_z + builder.config.tile_size, builder.config.cell_size)!,
    };
    if (maximum.x <= origin.x || maximum.z <= origin.z) return c3d::CAPACITY_EXCEEDED~;

    PolyMesh mesh = {
        .verts = vertices,
        .polys = polygons,
        .regions = regions,
        .flags = flags,
        .areas = areas,
        .vert_count = vertex_count,
        .poly_count = polygon_count,
        .verts_per_poly = stride,
        .bounds = {
            .min = { origin.x, builder.source.min_height, origin.z },
            .max = maximum,
        },
        .cell_size = builder.config.cell_size,
        .cell_height = builder.config.cell_height,
        .border_size = reference.border_size,
        .detail = {
            .mode = DetailMode.BOUNDED,
            .origin = origin,
            .origin_correction = {
                (double)builder.source.origin.x + (double)origin_x * builder.config.cell_size - origin.x,
                (double)builder.source.origin.z + (double)origin_z * builder.config.cell_size - origin.z,
            },
            .corners = corners,
            .polygons = details,
            .portals = portals,
        },
    };

    uint cell_index;
    foreach (column_index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)column_index)) continue;
        uint cell_x = (uint)column_index % reference.width - reference.border_size;
        uint cell_z = (uint)column_index / reference.width - reference.border_size;
        foreach (ordinal, &floor : column.floors) {
            uint span = column.span_base + (uint)ordinal;
            if (compact.areas[span] == NULL_AREA) continue;

            uint vertex_base = cell_index * GRID_QUAD_VERTICES;
            uint polygon_base = cell_index * polygons_per_cell;
            span_polygons[span] = (ushort)polygon_base;
            uint start = grid_quad_first_corner(floor);
            for (uint slot = 0; slot < GRID_QUAD_VERTICES; slot++) {
                uint corner = (start + GRID_QUAD_VERTICES - slot) & 3;
                uint x = cell_x + (uint)DETAIL_CORNER_X[corner];
                uint z = cell_z + (uint)DETAIL_CORNER_Z[corner];
                Vec3 world = {
                    grid_world_coordinate(builder.source.origin.x, origin_x + x, builder.config.cell_size)!,
                    floor.floor_kind == GridSurfaceKind.FLAT ? floor.height : floor.floor_corners[corner],
                    grid_world_coordinate(builder.source.origin.z, origin_z + z, builder.config.cell_size)!,
                };
                Vec3 local = { (float)((double)world.x - origin.x), world.y, (float)((double)world.z - origin.z) };
                // Local storage must reproduce the shared world-space seam.
                Vec3 restored = local + origin;
                if (!detail_finite_vertex(local)) return c3d::CAPACITY_EXCEEDED~;
                if (restored.x != world.x || restored.y != world.y || restored.z != world.z) return c3d::CAPACITY_EXCEEDED~;
                mesh.detail.corners[vertex_base + slot] = local;
                mesh.verts[(vertex_base + slot) * 3] = (ushort)x;
                mesh.verts[(vertex_base + slot) * 3 + 2] = (ushort)z;
            }

            Vec3[] cell_corners = mesh.detail.corners[vertex_base:GRID_QUAD_VERTICES];
            if (!detail_triangle_valid(cell_corners[0], cell_corners[1], cell_corners[2])
                || !detail_triangle_valid(cell_corners[0], cell_corners[2], cell_corners[3]))
                return c3d::CAPACITY_EXCEEDED~;

            for (uint part = 0; part < polygons_per_cell; part++) {
                uint polygon = polygon_base + part;
                mesh.areas[polygon] = floor.area;
                mesh.regions[polygon] = (ushort)(cell_index + 1);
                ushort[] indices = mesh.polys[(usz)polygon * stride * 2:stride];
                if (triangles) {
                    indices[0] = (ushort)vertex_base;
                    indices[1] = (ushort)(vertex_base + part + 1);
                    indices[2] = (ushort)(vertex_base + part + 2);
                    uint diagonal_edge = part ? 0 : 2;
                    mesh.polys[(usz)polygon * stride * 2 + stride + diagonal_edge] =
                      (ushort)(polygon_base + (1 - part));
                } else {
                    for (uint slot = 0; slot < stride; slot++) indices[slot] = (ushort)(vertex_base + slot);
                }
            }
            cell_index++;
        }
    }

    uint written;
    foreach (column_index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)column_index)) continue;
        for (usz ordinal = 0; ordinal < column.floors.len; ordinal++) {
            uint span = column.span_base + (uint)ordinal;
            if (compact.areas[span] == NULL_AREA) continue;
            for (uint direction = 0; direction < 4; direction++) {
                uint layer = compact.spans[span].connection(direction);
                if (layer == NOT_CONNECTED) continue;
                uint neighbour_column = grid_neighbour_column(reference, (uint)column_index, direction);
                if (compact.areas[reference.columns[neighbour_column].span_base + layer] == NULL_AREA) continue;
                write_grid_connection(
                    mesh: &mesh,
                    reference: reference,
                    span_polygons: span_polygons,
                    connection: {
                        .source_column = (uint)column_index,
                        .target_column = neighbour_column,
                        .direction = direction,
                        .source_floor = (ushort)ordinal,
                        .target_floor = (ushort)layer,
                        .max = 1,
                    },
                    written: &written,
                );
            }
        }
    }

    for (GridPartialEdge* edge = partials; edge; edge = edge.next) {
        foreach (match : edge.matches) {
            uint first = reference.columns[edge.first_column].span_base + match.first;
            uint second = reference.columns[edge.second_column].span_base + match.second;
            if (compact.areas[first] == NULL_AREA || compact.areas[second] == NULL_AREA) continue;
            for (uint pass = 0; pass < 2; pass++) {
                uint source_column = pass ? edge.second_column : edge.first_column;
                if (!grid_core_column(reference, source_column)) continue;
                uint direction = pass ? (edge.direction + 2) & 3 : edge.direction;
                float[2] range = grid_match_limits(match, direction)!;
                write_grid_connection(
                    mesh: &mesh,
                    reference: reference,
                    span_polygons: span_polygons,
                    connection: {
                        .source_column = source_column,
                        .target_column = pass ? edge.first_column : edge.second_column,
                        .direction = direction,
                        .source_floor = pass ? match.second : match.first,
                        .target_floor = pass ? match.first : match.second,
                        .min = range[0],
                        .max = range[1],
                    },
                    written: &written,
                );
            }
        }
    }

    usz size = tile_mesh_size(&mesh);
    if (size > (usz)sz::max) return c3d::CAPACITY_EXCEEDED~;
    char[]? blob = alloc::alloc_array_try(arena, char, (sz)size);
    if (catch blob) return c3d::CAPACITY_EXCEEDED~;

    pack_tile_mesh(
        mesh: &mesh,
        tile_x: tile_x,
        tile_z: tile_z,
        blob: blob,
    );

    return blob;
}

fn uint? grid_portal_count(GridReference* reference, CompactHeightfield* compact, GridPartialEdge* partials) @local {
    uint count;
    foreach (column_index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)column_index)) continue;
        for (usz ordinal = 0; ordinal < column.floors.len; ordinal++) {
            uint span = column.span_base + (uint)ordinal;
            if (compact.areas[span] == NULL_AREA) continue;
            for (uint direction = 0; direction < 4; direction++) {
                uint layer = compact.spans[span].connection(direction);
                if (layer == NOT_CONNECTED) continue;
                uint neighbour_column = grid_neighbour_column(reference, (uint)column_index, direction);
                uint neighbour = reference.columns[neighbour_column].span_base + layer;
                if (compact.areas[neighbour] == NULL_AREA || grid_core_column(reference, neighbour_column)) continue;
                if (count == DEFAULT_DETAIL_TRIANGLES) return c3d::CAPACITY_EXCEEDED~;
                count++;
            }
        }
    }

    for (GridPartialEdge* edge = partials; edge; edge = edge.next) {
        foreach (match : edge.matches) {
            uint first = reference.columns[edge.first_column].span_base + match.first;
            uint second = reference.columns[edge.second_column].span_base + match.second;
            if (compact.areas[first] == NULL_AREA || compact.areas[second] == NULL_AREA) continue;
            uint added = (uint)grid_core_column(reference, edge.first_column)
              + (uint)grid_core_column(reference, edge.second_column);
            if (added > DEFAULT_DETAIL_TRIANGLES - count) return c3d::CAPACITY_EXCEEDED~;
            count += added;
        }
    }

    return count;
}

fn void write_grid_connection(
    PolyMesh* mesh,
    GridReference* reference,
    ushort[] span_polygons,
    GridConnection connection,
    uint* written,
) @local {
    GridColumn* source = &reference.columns[connection.source_column];
    GridColumn* target = &reference.columns[connection.target_column];
    GridPolygonSide source_side = grid_polygon_side(
        floor: &source.floors[connection.source_floor],
        direction: connection.direction,
        triangles: mesh.verts_per_poly == 3,
    );
    uint polygon = span_polygons[source.span_base + connection.source_floor] + source_side.polygon;
    uint target_polygon = span_polygons[target.span_base + connection.target_floor];
    bool internal = target_polygon != MESH_NULL_INDEX;

    if (internal) {
        GridPolygonSide target_side = grid_polygon_side(
            floor: &target.floors[connection.target_floor],
            direction: (connection.direction + 2) & 3,
            triangles: mesh.verts_per_poly == 3,
        );
        target_polygon += target_side.polygon;
        if (connection.min == 0 && connection.max == 1) {
            mesh.polys[(usz)polygon * mesh.verts_per_poly * 2 + mesh.verts_per_poly + source_side.edge] =
              (ushort)target_polygon;
            return;
        }
    } else {
        mesh.polys[(usz)polygon * mesh.verts_per_poly * 2 + mesh.verts_per_poly + source_side.edge] =
          PORTAL_EDGE | (ushort)connection.direction;
    }

    mesh.detail.portals[(*written)++] = {
        .polygon = polygon,
        .edge = source_side.edge,
        .min = connection.min,
        .max = connection.max,
        .kind = internal ? DetailPortalKind.INTERNAL : DetailPortalKind.FLOOR_BORDER,
        .source_floor = connection.source_floor,
        .target = internal ? target_polygon : connection.target_floor,
    };
}

fn GridPolygonSide grid_polygon_side(GridFloor* floor, uint direction, bool triangles) @local {
    uint edge = (direction + grid_quad_first_corner(floor)) & 3;
    if (triangles && edge >= 2) return { .polygon = 1, .edge = edge - 1 };
    return { .edge = edge };
}

fn uint grid_quad_first_corner(GridFloor* floor) @local {
    bool alternate = (floor.floor_kind == GridSurfaceKind.CORNERS || floor.ceiling_kind == GridSurfaceKind.CORNERS)
        && floor.diagonal == GridDiagonal.MAX_MIN_TO_MIN_MAX;
    // The implicit fan keeps the first authored triangle first.
    return alternate ? 1 : 2;
}

fn uint grid_neighbour_column(GridReference* reference, uint column, uint direction) @local {
    return (uint)((int)column + dir_offset_x(direction) + dir_offset_z(direction) * (int)reference.width);
}

fn float? grid_world_coordinate(float origin, long cell, float pitch) @local {
    float world = (float)((double)origin + (double)cell * pitch);
    if (!math::is_finite(world)) return c3d::CAPACITY_EXCEEDED~;
    return world;
}

fn float[2]? grid_match_limits(GridEdgeMatch match, uint direction) @local {
    bool reversed = direction >= 2;
    PrecisionInterval lower = match.min.bounds;
    PrecisionInterval upper = match.max.bounds;
    bool include_lower = match.include_min;
    bool include_upper = match.include_max;

    if (reversed) {
        lower = precision_subtract(precision_point(1)!, match.max.bounds)!;
        upper = precision_subtract(precision_point(1)!, match.min.bounds)!;
        include_lower = match.include_max;
        include_upper = match.include_min;
    }

    // Round inward so float endpoints cannot widen a certified opening.
    float minimum = (float)lower.max;
    float maximum = (float)upper.min;
    if ((double)minimum < lower.max || (!include_lower && (double)minimum == lower.max))
        minimum = minimum.nexthigher();
    if ((double)maximum > upper.min || (!include_upper && (double)maximum == upper.min)) {
        if (maximum == 0) return c3d::CAPACITY_EXCEEDED~;
        maximum = bitcast(bitcast(maximum, uint) - 1, float);
    }

    if (minimum < 0 || maximum > 1 || minimum >= maximum) return c3d::CAPACITY_EXCEEDED~;

    return { minimum, maximum };
}
