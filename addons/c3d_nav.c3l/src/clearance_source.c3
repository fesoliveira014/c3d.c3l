module c3d::nav;

import std::math;
import c3d;

const uint[4] CLEARANCE_FAN_DIRECTION @local = { 3, 2, 1, 0 };

struct ClearanceSurface @private {
    uint column;
    ushort ordinal;
    char area;
    double[5] heights;
    double[5] ceilings;
    bool ceiling_open;
}

struct ClearanceSource @private {
    CompactCell[] columns;
    ClearanceSurface[] surfaces;
    uint width;
    uint height;
    uint border_size;
    Vec3 origin;
    double[2] basis;
    int first_x;
    int first_z;
    float cell_size;
    Aabb bounds;
    bool center_on_diagonal;
}

struct ClearanceConnection @private {
    uint first_column;
    uint second_column;
    uint direction;
    GridEdgeMatch[] matches;
}

struct ClearanceCells @private {
    ClearanceSource* source;
    uint subdivision;
    bool[] admitted;
    bool[] selected;
    ClearanceConnection[] connections;
    double storage_delta;
}

struct ClearanceFragment @local {
    ClearancePoint[3] points;
    PrecisionInterval[3] headroom;
    bool active;
}

struct ClearanceEdgeRange @local {
    GridEdgeRoot min;
    GridEdgeRoot max;
    bool active;
}

fn ClearancePoint? clearance_source_point(
    ClearanceSource* source,
    uint column,
    double cell_x,
    double cell_z,
) @private {
    double x = (double)source.first_x + (double)(column % source.width) + cell_x;
    double z = (double)source.first_z + (double)(column / source.width) + cell_z;

    if (source.center_on_diagonal && cell_x == 0.5 && cell_z == 0.5) {
        ClearancePoint first = clearance_source_point(
            source: source,
            column: column,
            cell_x: 0,
            cell_z: 0,
        )!;
        ClearancePoint last = clearance_source_point(
            source: source,
            column: column,
            cell_x: 1,
            cell_z: 1,
        )!;

        return {
            .x = precision_multiply(precision_add(first.x, last.x)!, precision_point(0.5)!)!,
            .z = precision_multiply(precision_add(first.z, last.z)!, precision_point(0.5)!)!,
        };
    }

    float world_x = (float)(source.basis[0] + x * source.cell_size);
    float world_z = (float)(source.basis[1] + z * source.cell_size);
    if (!math::is_finite(world_x) || !math::is_finite(world_z)) return c3d::CAPACITY_EXCEEDED~;

    return clearance_point((double)world_x - source.origin.x, (double)world_z - source.origin.z);
}

fn Vec3? clearance_micro_vertex(
    ClearanceSource* source,
    uint column,
    uint micro_x,
    uint micro_z,
    uint subdivision,
    double height,
) @private {
    long x = ((long)source.first_x + (long)(column % source.width)) * subdivision + micro_x;
    long z = ((long)source.first_z + (long)(column / source.width)) * subdivision + micro_z;
    float world_x = (float)(source.basis[0] + ((double)x / subdivision) * source.cell_size);
    float world_z = (float)(source.basis[1] + ((double)z / subdivision) * source.cell_size);

    Vec3 local = { (float)((double)world_x - source.origin.x), (float)height, (float)((double)world_z - source.origin.z) };
    if (!detail_finite_vertex(local)) return c3d::CAPACITY_EXCEEDED~;

    // Storing local floats must preserve their shared world coordinates.
    if ((float)((double)source.origin.x + local.x) != world_x) return c3d::CAPACITY_EXCEEDED~;
    if ((float)((double)source.origin.z + local.z) != world_z) return c3d::CAPACITY_EXCEEDED~;

    return local;
}

fn ClearanceRectangle? clearance_micro_square(
    ClearanceSource* source,
    uint column,
    uint micro_x,
    uint micro_z,
    uint subdivision,
    double* delta,
) @private {
    long first_x = ((long)source.first_x + (long)(column % source.width)) * subdivision + micro_x;
    long first_z = ((long)source.first_z + (long)(column / source.width)) * subdivision + micro_z;
    PrecisionInterval pitch = precision_point(source.cell_size)!;
    PrecisionInterval count = precision_point(subdivision)!;
    PrecisionInterval[2] xs;
    PrecisionInterval[2] zs;

    for (uint endpoint = 0; endpoint < 2; endpoint++) {
        xs[endpoint] = precision_subtract(
            precision_add(precision_point(source.basis[0])!,
                precision_divide(precision_multiply(precision_point((double)(first_x + endpoint))!, pitch)!, count)!)!,
            precision_point(source.origin.x)!,
        )!;
        zs[endpoint] = precision_subtract(
            precision_add(precision_point(source.basis[1])!,
                precision_divide(precision_multiply(precision_point((double)(first_z + endpoint))!, pitch)!, count)!)!,
            precision_point(source.origin.z)!,
        )!;
    }
    if (xs[1].min <= xs[0].max || zs[1].min <= zs[0].max) return c3d::CAPACITY_EXCEEDED~;

    Vec3[4] corners;
    for (uint z = 0; z < 2; z++) {
        for (uint x = 0; x < 2; x++) {
            Vec3 stored = clearance_micro_vertex(
                source: source,
                column: column,
                micro_x: micro_x + x,
                micro_z: micro_z + z,
                subdivision: subdivision,
                height: 0,
            )!;
            corners[x + z * 2] = stored;
            PrecisionInterval displacement = clearance_point_distance(
                { .x = xs[x], .z = zs[z] }, clearance_point(stored.x, stored.z)!,
            )!;
            *delta = math::max(*delta, displacement.max);
        }
    }

    if (corners[1].x <= corners[0].x || corners[2].z <= corners[0].z
        || corners[3].x <= corners[2].x || corners[3].z <= corners[1].z) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    return { .min_x = xs[0], .min_z = zs[0], .max_x = xs[1], .max_z = zs[1] };
}

fn ClearanceFragment? clearance_fragment(
    ClearanceSource* source,
    uint surface_index,
    uint fan,
    TileConfig* config,
) @local {
    ClearanceSurface* surface = &source.surfaces[surface_index];
    uint[3] indices = { 4, fan, (fan + 1) & 3 };
    ClearanceFragment fragment;

    for (uint point = 0; point < 3; point++) {
        uint index = indices[point];
        fragment.points[point] = clearance_source_point(
            source: source,
            column: surface.column,
            cell_x: index == 4 ? 0.5 : (double)DETAIL_CORNER_X[index],
            cell_z: index == 4 ? 0.5 : (double)DETAIL_CORNER_Z[index],
        )!;
        fragment.headroom[point] = surface.ceiling_open ? precision_point(1)! : precision_subtract(
            precision_subtract(precision_point(surface.ceilings[index])!, precision_point(surface.heights[index])!)!,
            precision_point(config.agent_height)!,
        )!;
    }
    if (surface.area == NULL_AREA) return fragment;

    double x1 = fragment.points[1].x.min - fragment.points[0].x.min;
    double z1 = fragment.points[1].z.min - fragment.points[0].z.min;
    double x2 = fragment.points[2].x.min - fragment.points[0].x.min;
    double z2 = fragment.points[2].z.min - fragment.points[0].z.min;
    double determinant = x1 * z2 - x2 * z1;
    if (determinant <= 0) return c3d::CAPACITY_EXCEEDED~;

    double y1 = surface.heights[fan] - surface.heights[4];
    double y2 = surface.heights[(fan + 1) & 3] - surface.heights[4];
    double dx = (y1 * z2 - y2 * z1) / determinant;
    double dz = (x1 * y2 - x2 * y1) / determinant;
    double slope = math::tan((double)config.slope_degrees * math::PI / 180.0);
    if (dx * dx + dz * dz > slope * slope) return fragment;

    bool positive;
    bool negative;
    foreach (headroom : fragment.headroom) {
        if (headroom.min < 0 && headroom.max >= 0) return c3d::CAPACITY_EXCEEDED~;
        positive |= headroom.min > 0;
        negative |= headroom.max < 0;
    }

    fragment.active = positive || !negative;
    return fragment;
}

fn ClearanceEdgeRange? clearance_edge_range(PrecisionInterval first, PrecisionInterval last) @local {
    ClearanceEdgeRange range = { .min = grid_edge_point(0)!, .max = grid_edge_point(1)! };
    if (first.max < 0 && last.max < 0) return range;
    if ((first.min < 0 && first.max >= 0) || (last.min < 0 && last.max >= 0)) return c3d::CAPACITY_EXCEEDED~;

    if (first.max < 0) range.min = grid_linear_root(first, last)!;
    if (last.max < 0) range.max = grid_linear_root(first, last)!;
    range.active = compare_grid_roots(range.min, range.max)! < 0;

    return range;
}

fn ClearancePoint? clearance_edge_point(ClearancePoint first, ClearancePoint last, GridEdgeRoot root) @local {
    if (root.bounds.min == 0 && root.bounds.max == 0) return first;
    if (root.bounds.min == 1 && root.bounds.max == 1) return last;

    return {
        .x = precision_add(first.x, precision_multiply(precision_subtract(last.x, first.x)!, root.bounds)!)!,
        .z = precision_add(first.z, precision_multiply(precision_subtract(last.z, first.z)!, root.bounds)!)!,
    };
}

fn void? clearance_append_edge(
    ClearanceEdge[] output,
    uint* count,
    ClearancePoint first,
    ClearancePoint last,
    uint neighbour,
) @local {
    if (*count == uint::max) return c3d::CAPACITY_EXCEEDED~;

    if (output.len) {
        if (*count >= output.len) return c3d::CAPACITY_EXCEEDED~;
        output[*count] = { .first = first, .last = last, .neighbour = neighbour };
    }

    (*count)++;
}

fn ClearanceConnection[]? clearance_connections(
    Allocator allocator,
    ClearanceSource* source,
    TileConfig* config,
) @local {
    if (source.columns.len > (usz)sz::max / 2 / ClearanceConnection::size) return c3d::CAPACITY_EXCEEDED~;

    ClearanceConnection[]? allocation = alloc::new_array_try(allocator, ClearanceConnection, (sz)source.columns.len * 2);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;

    ClearanceConnection[] connections = allocation;
    GridEdgeProfile[MAX_GRID_FLOORS] first_profiles;
    GridEdgeProfile[MAX_GRID_FLOORS] second_profiles;
    NavBuildConfig settings = { .agent_height = config.agent_height, .agent_max_climb = config.agent_max_climb };

    for (uint z = 0; z < source.height; z++) {
        for (uint x = 0; x < source.width; x++) {
            uint first_column = x + z * source.width;
            for (uint direction = 1; direction <= 2; direction++) {
                uint other_x = x + (uint)dir_offset_x(direction);
                uint other_z = z + (uint)dir_offset_z(direction);
                if (other_x >= source.width || other_z >= source.height) continue;

                uint second_column = other_x + other_z * source.width;
                CompactCell first = source.columns[first_column];
                CompactCell second = source.columns[second_column];
                if (!first.count || !second.count) continue;
                if (first.count > MAX_GRID_FLOORS || second.count > MAX_GRID_FLOORS) return c3d::CAPACITY_EXCEEDED~;

                clearance_edge_profiles(
                    source: source,
                    column: first_column,
                    direction: direction,
                    config: config,
                    profiles: first_profiles[:first.count],
                )!;
                clearance_edge_profiles(
                    source: source,
                    column: second_column,
                    direction: (direction + 2) & 3,
                    config: config,
                    profiles: second_profiles[:second.count],
                )!;

                usz count = grid_edge_matches(
                    first: first_profiles[:first.count],
                    second: second_profiles[:second.count],
                    config: &settings,
                    output: {},
                )!;
                if (!count) continue;

                GridEdgeMatch[]? matches = alloc::new_array_try(allocator, GridEdgeMatch, (sz)count);
                if (catch matches) return c3d::CAPACITY_EXCEEDED~;

                grid_edge_matches(
                    first: first_profiles[:first.count],
                    second: second_profiles[:second.count],
                    config: &settings,
                    output: matches,
                )!;

                connections[first_column * 2 + direction - 1] = {
                    .first_column = first_column, .second_column = second_column, .direction = direction, .matches = matches,
                };
            }
        }
    }

    return connections;
}

fn void? clearance_edge_profiles(
    ClearanceSource* source,
    uint column,
    uint direction,
    TileConfig* config,
    GridEdgeProfile[] profiles,
) @local {
    CompactCell cell = source.columns[column];
    uint fan = 3 - direction;
    uint first_corner = direction == 0 || direction == 3 ? 0 : direction == 1 ? 3 : 1;
    uint last_corner = direction == 0 ? 3 : direction == 3 ? 1 : 2;

    for (uint ordinal = 0; ordinal < cell.count; ordinal++) {
        ClearanceSurface* surface = &source.surfaces[cell.index + ordinal];
        ClearanceFragment fragment = clearance_fragment(
            source: source,
            surface_index: cell.index + ordinal,
            fan: fan,
            config: config,
        )!;

        profiles[ordinal] = {
            .height = { surface.heights[first_corner], surface.heights[last_corner] },
            .ceiling = { surface.ceilings[first_corner], surface.ceilings[last_corner] },
            .max = fragment.active ? 1 : 0,
            .ordinal = (ushort)ordinal,
            .ceiling_open = surface.ceiling_open,
        };
    }
}

fn ClearanceConnection* clearance_connection(
    ClearanceSource* source,
    ClearanceConnection[] connections,
    uint column,
    uint direction,
) @local {
    uint x = column % source.width;
    uint z = column / source.width;

    switch (direction) {
        case 0: return x ? &connections[(column - 1) * 2 + 1] : null;
        case 1: return z + 1 < source.height ? &connections[column * 2] : null;
        case 2: return x + 1 < source.width ? &connections[column * 2 + 1] : null;
        case 3: return z ? &connections[(column - source.width) * 2] : null;
    }

    unreachable();
}

fn uint? clearance_domain_edges(
    ClearanceSource* source,
    TileConfig* config,
    ClearanceConnection[] connections,
    ClearanceFace[] faces,
    ClearanceEdge[] edges,
) @local {
    uint count;
    foreach (surface_index, &surface : source.surfaces) {
        for (uint fan = 0; fan < 4; fan++) {
            uint face_index = (uint)surface_index * 4 + fan;
            ClearanceFragment fragment = clearance_fragment(
                source: source,
                surface_index: (uint)surface_index,
                fan: fan,
                config: config,
            )!;

            ClearanceFace* face = &faces[face_index];
            face.first_edge = count;
            face.source = (uint)surface_index;
            if (!fragment.active) continue;

            for (uint radial = 0; radial < 2; radial++) {
                uint corner = radial ? 2 : 1;
                ClearanceEdgeRange range = clearance_edge_range(fragment.headroom[0], fragment.headroom[corner])!;
                if (!range.active) continue;

                uint other_fan = (fan + (radial ? 1 : 3)) & 3;
                ClearanceFragment other = clearance_fragment(
                    source: source,
                    surface_index: (uint)surface_index,
                    fan: other_fan,
                    config: config,
                )!;

                clearance_append_edge(
                    output: edges,
                    count: &count,
                    first: clearance_edge_point(fragment.points[0], fragment.points[corner], range.min)!,
                    last: clearance_edge_point(fragment.points[0], fragment.points[corner], range.max)!,
                    neighbour: other.active ? (uint)surface_index * 4 + other_fan : CLEARANCE_NO_FACE,
                )!;
            }

            uint direction = CLEARANCE_FAN_DIRECTION[fan];
            bool reversed = fan >= 2;
            uint start = reversed ? 2 : 1;
            uint end = reversed ? 1 : 2;
            ClearanceEdgeRange range = clearance_edge_range(fragment.headroom[start], fragment.headroom[end])!;
            if (range.active) {
                ClearanceConnection* connection = clearance_connection(
                    source: source,
                    connections: connections,
                    column: surface.column,
                    direction: direction,
                );

                GridEdgeRoot cursor = range.min;
                while (compare_grid_roots(cursor, range.max)! < 0) {
                    GridEdgeMatch* next;
                    GridEdgeRoot next_min = range.max;
                    GridEdgeRoot next_max = range.max;

                    if (connection) {
                        bool forward = connection.first_column == surface.column;
                        foreach (&match : connection.matches) {
                            if ((forward ? match.first : match.second) != surface.ordinal) continue;
                            if (compare_grid_roots(match.max, cursor)! <= 0) continue;
                            if (compare_grid_roots(match.min, range.max)! >= 0) continue;

                            GridEdgeRoot low = compare_grid_roots(match.min, range.min)! < 0 ? range.min : match.min;
                            GridEdgeRoot high = compare_grid_roots(match.max, range.max)! > 0 ? range.max : match.max;
                            if (compare_grid_roots(low, cursor)! < 0) return c3d::CAPACITY_EXCEEDED~;

                            if (!next || compare_grid_roots(low, next_min)! < 0) {
                                next = match;
                                next_min = low;
                                next_max = high;
                            }
                        }
                    }

                    ClearancePoint first = clearance_edge_point(fragment.points[start], fragment.points[end], cursor)!;
                    ClearancePoint last = clearance_edge_point(fragment.points[start], fragment.points[end], next_min)!;
                    if (compare_grid_roots(cursor, next_min)! < 0) {
                        clearance_append_edge(
                            output: edges,
                            count: &count,
                            first: first,
                            last: last,
                            neighbour: CLEARANCE_NO_FACE,
                        )!;
                    }
                    if (!next) break;

                    bool forward = connection.first_column == surface.column;
                    uint other_column = forward ? connection.second_column : connection.first_column;
                    uint other_surface = source.columns[other_column].index + (forward ? next.second : next.first);
                    uint other_face = other_surface * 4 + 3 - ((direction + 2) & 3);
                    first = last;
                    last = clearance_edge_point(fragment.points[start], fragment.points[end], next_max)!;
                    clearance_append_edge(
                        output: edges,
                        count: &count,
                        first: first,
                        last: last,
                        neighbour: other_face,
                    )!;

                    // Excluded match endpoints remain barriers of zero length.
                    if (!next.include_min && compare_grid_roots(next_min, next.min)! == 0) {
                        clearance_append_edge(
                            output: edges,
                            count: &count,
                            first: first,
                            last: first,
                            neighbour: CLEARANCE_NO_FACE,
                        )!;
                    }
                    if (!next.include_max && compare_grid_roots(next_max, next.max)! == 0) {
                        clearance_append_edge(
                            output: edges,
                            count: &count,
                            first: last,
                            last: last,
                            neighbour: CLEARANCE_NO_FACE,
                        )!;
                    }

                    cursor = next_max;
                }
            }

            bool negative;
            foreach (headroom : fragment.headroom) negative |= headroom.max < 0;
            if (negative) {
                ClearancePoint[2] cuts;
                uint cut_count;
                for (uint edge = 0; edge < 3; edge++) {
                    uint other = (edge + 1) % 3;
                    PrecisionInterval a = fragment.headroom[edge];
                    PrecisionInterval b = fragment.headroom[other];
                    if (a.min == 0 && a.max == 0) {
                        if (cut_count == 2) return c3d::CAPACITY_EXCEEDED~;
                        cuts[cut_count++] = fragment.points[edge];
                    } else if ((a.max < 0 && b.min > 0) || (a.min > 0 && b.max < 0)) {
                        if (cut_count == 2) return c3d::CAPACITY_EXCEEDED~;
                        cuts[cut_count++] = clearance_edge_point(fragment.points[edge], fragment.points[other], grid_linear_root(a, b)!)!;
                    }
                }

                if (cut_count != 2) return c3d::CAPACITY_EXCEEDED~;
                clearance_append_edge(
                    output: edges,
                    count: &count,
                    first: cuts[0],
                    last: cuts[1],
                    neighbour: CLEARANCE_NO_FACE,
                )!;
            }

            face.edge_count = count - face.first_edge;
        }
    }

    return count;
}

fn ClearanceSource? clearance_scene_source(Allocator allocator, DetailReference* reference, TileConfig* config) @private {
    ClearanceSurface[]? allocation = alloc::new_array_try(allocator, ClearanceSurface, (sz)reference.samples.len);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;

    ClearanceSource source = {
        .columns = reference.columns,
        .surfaces = allocation,
        .width = reference.width,
        .height = reference.height,
        .border_size = reference.border_size,
        .origin = reference.origin,
        .basis = reference.basis,
        .first_x = reference.first_x,
        .first_z = reference.first_z,
        .cell_size = reference.cell_size,
    };

    float lowest = float::max;
    float highest = -float::max;
    foreach (index, sample : reference.samples) {
        ClearanceSurface* surface = &source.surfaces[index];
        surface.column = sample.column;
        surface.ordinal = (ushort)(index - reference.columns[sample.column].index);
        surface.area = sample.area;
        surface.heights[4] = sample.height;
        surface.ceilings[..] = (double)sample.ceiling;
        foreach (corner, height : sample.corners) surface.heights[corner] = height;
        lowest = math::min(lowest, sample.height);
        highest = math::max(highest, sample.ceiling);
    }

    ClearancePoint first = clearance_source_point(
        source: &source,
        column: 0,
        cell_x: 0,
        cell_z: 0,
    )!;
    ClearancePoint last = clearance_source_point(
        source: &source,
        column: (uint)source.columns.len - 1,
        cell_x: 1,
        cell_z: 1,
    )!;
    source.bounds = {
        .min = { (float)(source.origin.x + first.x.min), source.origin.y + lowest, (float)(source.origin.z + first.z.min) },
        .max = { (float)(source.origin.x + last.x.max), source.origin.y + highest, (float)(source.origin.z + last.z.max) },
    };

    return source;
}

fn uint? clearance_root(
    ClearanceSource* source,
    uint surface,
    TileConfig* config,
    ClearanceRectangle square,
) @local {
    ClearancePoint point = clearance_point(
        square.min_x.max + (square.max_x.min - square.min_x.max) * 0.5,
        square.min_z.max + (square.max_z.min - square.min_z.max) * 0.5,
    )!;

    for (uint fan = 0; fan < 4; fan++) {
        ClearanceFragment fragment = clearance_fragment(
            source: source,
            surface_index: surface,
            fan: fan,
            config: config,
        )!;
        if (!fragment.active) continue;

        PrecisionInterval[3] weights;
        bool inside = true;
        for (uint edge = 0; edge < 3; edge++) {
            ClearancePoint a = fragment.points[(edge + 1) % 3];
            ClearancePoint b = fragment.points[(edge + 2) % 3];
            PrecisionInterval x = precision_subtract(b.x, a.x)!;
            PrecisionInterval z = precision_subtract(b.z, a.z)!;
            PrecisionInterval px = precision_subtract(point.x, a.x)!;
            PrecisionInterval pz = precision_subtract(point.z, a.z)!;
            if (precision_compare_products(
                first: x,
                second: pz,
                third: z,
                fourth: px,
            )! < 0) {
                inside = false;
                break;
            }
            weights[edge] = precision_subtract(precision_multiply(x, pz)!, precision_multiply(z, px)!)!;
        }
        if (!inside) continue;

        PrecisionInterval headroom = precision_point(0)!;
        for (uint vertex = 0; vertex < 3; vertex++) {
            headroom = precision_add(headroom, precision_multiply(weights[vertex], fragment.headroom[vertex])!)!;
        }
        if (headroom.max < 0) continue;
        if (headroom.min < 0) return c3d::CAPACITY_EXCEEDED~;

        return surface * 4 + fan;
    }

    return CLEARANCE_NO_FACE;
}

fn char[]? build_clearance_mesh(
    Allocator allocator,
    ClearanceSource* source,
    TileConfig* config,
    int tile_x,
    int tile_z,
    uint[] selected_sources = {},
    Obstacle[] obstacles = {},
    VolumeRecord[] volumes = {},
) @private {
    if (!source.surfaces.len) return {};
    if (source.surfaces.len > uint::max / 4 || source.surfaces.len > (usz)sz::max / 4 / ClearanceFace::size) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    NavBuildConfig settings_config = {
        .cell_size = source.cell_size, .agent_radius = config.agent_radius,
        .clearance_max_error = config.clearance_max_error,
    };
    ClearanceSettings settings = clearance_settings(settings_config)!;
    if (settings.subdivision != config.subdivision) return c3d::INVALID_ARGUMENT~;

    ulong mask_count = (ulong)source.surfaces.len * settings.subdivision * settings.subdivision;
    if (mask_count > (ulong)sz::max || mask_count > uint::max) return c3d::CAPACITY_EXCEEDED~;

    bool[]? admitted = alloc::new_array_try(allocator, bool, (sz)mask_count);
    if (catch admitted) return c3d::CAPACITY_EXCEEDED~;

    bool[]? selected = alloc::new_array_try(allocator, bool, (sz)source.surfaces.len);
    if (catch selected) return c3d::CAPACITY_EXCEEDED~;

    if (!selected_sources.len) selected[..] = true;
    foreach (index : selected_sources) {
        if (index == NULL_SPAN) continue;
        if (index >= selected.len) return LAYER_CORRUPTED~;
        selected[index] = true;
    }

    foreach (&surface : source.surfaces) {
        if (surface.area != NULL_AREA) surface.area = clearance_volume_area(source, surface, volumes)!;
    }

    ClearanceCells cells = {
        .source = source, .subdivision = settings.subdivision, .admitted = admitted, .selected = selected,
        .connections = clearance_connections(allocator, source, config)!,
    };

    ClearanceFace[]? faces = alloc::new_array_try(allocator, ClearanceFace, (sz)source.surfaces.len * 4);
    if (catch faces) return c3d::CAPACITY_EXCEEDED~;

    uint edge_count = clearance_domain_edges(
        source: source,
        config: config,
        connections: cells.connections,
        faces: faces,
        edges: {},
    )!;

    ClearanceEdge[]? edges = alloc::new_array_try(allocator, ClearanceEdge, edge_count);
    if (catch edges) return c3d::CAPACITY_EXCEEDED~;

    clearance_domain_edges(
        source: source,
        config: config,
        connections: cells.connections,
        faces: faces,
        edges: edges,
    )!;

    ClearancePoint first = clearance_source_point(
        source: source,
        column: 0,
        cell_x: 0,
        cell_z: 0,
    )!;
    ClearancePoint last = clearance_source_point(
        source: source,
        column: (uint)source.columns.len - 1,
        cell_x: 1,
        cell_z: 1,
    )!;
    ClearanceDomain domain = {
        .captured = { .min_x = first.x, .min_z = first.z, .max_x = last.x, .max_z = last.z },
        .faces = faces, .edges = edges, .source = source, .config = config, .obstacles = obstacles, .volumes = volumes,
    };
    ClearanceWork work = create_clearance_work(allocator, faces.len)!;

    foreach (surface_index, surface : source.surfaces) {
        if (!cells.selected[surface_index] || surface.area == NULL_AREA) continue;

        uint x = surface.column % source.width;
        uint z = surface.column / source.width;
        if (x < source.border_size || z < source.border_size || x >= source.width - source.border_size
            || z >= source.height - source.border_size) {
            continue;
        }

        for (uint micro_z = 0; micro_z < cells.subdivision; micro_z++) {
            for (uint micro_x = 0; micro_x < cells.subdivision; micro_x++) {
                double delta;
                ClearanceRectangle square = clearance_micro_square(
                    source: source,
                    column: surface.column,
                    micro_x: micro_x,
                    micro_z: micro_z,
                    subdivision: cells.subdivision,
                    delta: &delta,
                )!;
                if (delta > settings.storage_limit) return c3d::CAPACITY_EXCEEDED~;

                uint root = clearance_root(
                    source: source,
                    surface: (uint)surface_index,
                    config: config,
                    square: square,
                )!;
                if (root == CLEARANCE_NO_FACE) continue;

                bool keep = clearance_admits(
                    domain: &domain,
                    root: root,
                    square: square,
                    settings: settings,
                    agent_radius: config.agent_radius,
                    storage_delta: delta,
                    work: &work,
                )!;
                cells.admitted[(surface_index * cells.subdivision + micro_z) * cells.subdivision + micro_x] = keep;
                if (keep) cells.storage_delta = math::max(cells.storage_delta, delta);
            }
        }
    }

    filter_clearance_regions(allocator, &cells, config)!;

    return pack_clearance_cells(
        allocator: allocator,
        cells: &cells,
        config: config,
        tile_x: tile_x,
        tile_z: tile_z,
    );
}

fn char? clearance_volume_area(ClearanceSource* source, ClearanceSurface* surface, VolumeRecord[] volumes) @local {
    char area = surface.area;
    ClearancePoint point = clearance_source_point(
        source: source,
        column: surface.column,
        cell_x: 0.5,
        cell_z: 0.5,
    )!;
    double x = (double)source.origin.x + point.x.min;
    double z = (double)source.origin.z + point.z.min;
    double height = (double)source.origin.y + surface.heights[4];

    foreach (&volume : volumes) {
        if (volume.area == NULL_AREA) continue;

        bool inside;
        switch (volume.kind) {
            case BOX:
                if (height < volume.box.min.y || height > volume.box.max.y) continue;

                ClearancePoint first = clearance_source_point(
                    source: source,
                    column: surface.column,
                    cell_x: 0,
                    cell_z: 0,
                )!;
                ClearancePoint last = clearance_source_point(
                    source: source,
                    column: surface.column,
                    cell_x: 1,
                    cell_z: 1,
                )!;

                inside = source.origin.x + first.x.min <= volume.box.max.x && source.origin.x + last.x.max >= volume.box.min.x
                    && source.origin.z + first.z.min <= volume.box.max.z && source.origin.z + last.z.max >= volume.box.min.z;

            case CYLINDER:
                double dx = x - volume.base.x;
                double dz = z - volume.base.z;
                inside = height >= volume.base.y && height <= (double)volume.base.y + volume.height
                    && dx * dx + dz * dz < (double)volume.radius * volume.radius;

            case CONVEX:
                if (height < volume.min_y || height > volume.max_y) continue;
                if (volume.vert_count < 3 || volume.vert_count > volume.verts.len) return c3d::INVALID_ARGUMENT~;

                uint previous = volume.vert_count - 1;
                for (uint current = 0; current < volume.vert_count; previous = current++) {
                    Vec3 a = volume.verts[current];
                    Vec3 b = volume.verts[previous];
                    if ((a.z > z) == (b.z > z)) continue;
                    if (x >= ((double)b.x - a.x) * (z - a.z) / ((double)b.z - a.z) + a.x) continue;
                    inside = !inside;
                }
        }
        if (inside) area = volume.area;
    }

    return area;
}

fn uint? clearance_cell_neighbour(
    ClearanceCells* cells,
    uint index,
    uint direction,
    bool* external,
) @local {
    ClearanceSource* source = cells.source;
    uint count = cells.subdivision;
    uint surface_index = index / (count * count);
    uint micro_x = index % count;
    uint micro_z = (index / count) % count;

    if (direction == 0 && micro_x) return index - 1;
    if (direction == 2 && micro_x + 1 < count) return index + 1;
    if (direction == 3 && micro_z) return index - count;
    if (direction == 1 && micro_z + 1 < count) return index + count;

    ClearanceSurface surface = source.surfaces[surface_index];
    ClearanceConnection* connection = clearance_connection(
        source: source,
        connections: cells.connections,
        column: surface.column,
        direction: direction,
    );
    if (!connection) return CLEARANCE_NO_FACE;

    uint start_x = direction == 0 ? 0 : direction == 2 ? count : micro_x;
    uint start_z = direction == 3 ? 0 : direction == 1 ? count : micro_z;
    bool vertical = direction == 0 || direction == 2;
    Vec3 first = clearance_micro_vertex(
        source: source,
        column: surface.column,
        micro_x: start_x,
        micro_z: start_z,
        subdivision: count,
        height: 0,
    )!;
    Vec3 last = clearance_micro_vertex(
        source: source,
        column: surface.column,
        micro_x: start_x + (vertical ? 0 : 1),
        micro_z: start_z + (vertical ? 1 : 0),
        subdivision: count,
        height: 0,
    )!;

    ClearancePoint a = clearance_source_point(
        source: source,
        column: surface.column,
        cell_x: direction == 2 ? 1 : 0,
        cell_z: direction == 1 ? 1 : 0,
    )!;
    ClearancePoint b = clearance_source_point(
        source: source,
        column: surface.column,
        cell_x: direction == 0 ? 0 : 1,
        cell_z: direction == 3 ? 0 : 1,
    )!;
    PrecisionInterval start = vertical ? a.z : a.x;
    PrecisionInterval length = precision_subtract(vertical ? b.z : b.x, start)!;
    PrecisionInterval first_offset = precision_subtract(precision_point(vertical ? first.z : first.x)!, start)!;
    PrecisionInterval last_offset = precision_subtract(precision_point(vertical ? last.z : last.x)!, start)!;
    GridEdgeRoot low = { .bounds = precision_divide(first_offset, length)!, .numerator = first_offset, .denominator = length };
    GridEdgeRoot high = { .bounds = precision_divide(last_offset, length)!, .numerator = last_offset, .denominator = length };

    bool forward = connection.first_column == surface.column;
    foreach (match : connection.matches) {
        if ((forward ? match.first : match.second) != surface.ordinal) continue;

        int lower = compare_grid_roots(match.min, low)!;
        int upper = compare_grid_roots(match.max, high)!;
        if (lower > 0 || upper < 0) continue;
        if (lower == 0 && !match.include_min) continue;
        if (upper == 0 && !match.include_max) continue;

        uint column = forward ? connection.second_column : connection.first_column;
        uint other = source.columns[column].index + (forward ? match.second : match.first);
        uint x = column % source.width;
        uint z = column / source.width;
        if (!cells.selected[other] || x < source.border_size || z < source.border_size
            || x >= source.width - source.border_size || z >= source.height - source.border_size) {
            *external = true;
            return CLEARANCE_NO_FACE;
        }

        uint next_x = direction == 0 ? count - 1 : direction == 2 ? 0 : micro_x;
        uint next_z = direction == 3 ? count - 1 : direction == 1 ? 0 : micro_z;
        return (other * count + next_z) * count + next_x;
    }

    return CLEARANCE_NO_FACE;
}

fn void? filter_clearance_regions(Allocator allocator, ClearanceCells* cells, TileConfig* config) @local {
    if (!config.min_region_area) return;

    ulong minimum = (ulong)config.min_region_area * cells.subdivision * cells.subdivision;

    bool[]? seen = alloc::new_array_try(allocator, bool, (sz)cells.admitted.len);
    if (catch seen) return c3d::CAPACITY_EXCEEDED~;

    uint[]? queue = alloc::alloc_array_try(allocator, uint, (sz)cells.admitted.len);
    if (catch queue) return c3d::CAPACITY_EXCEEDED~;

    foreach (index, admitted : cells.admitted) {
        if (!admitted || seen[index]) continue;

        queue[0] = (uint)index;
        seen[index] = true;
        uint count = 1;
        bool external;

        for (uint cursor = 0; cursor < count; cursor++) {
            for (uint direction = 0; direction < 4; direction++) {
                uint neighbour = clearance_cell_neighbour(
                    cells: cells,
                    index: queue[cursor],
                    direction: direction,
                    external: &external,
                )!;
                if (neighbour == CLEARANCE_NO_FACE || !cells.admitted[neighbour] || seen[neighbour]) continue;

                seen[neighbour] = true;
                queue[count++] = neighbour;
            }
        }

        // The local count cannot bound regions that continue outside the selected cells.
        if (external || count >= minimum) continue;

        foreach (member : queue[:count]) cells.admitted[member] = false;
    }
}
