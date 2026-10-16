module c3d::nav;

import std::math;
import c3d;

const uint DETAIL_CORNER_SPANS @local = 4 * (NOT_CONNECTED + 1);
const int[4] DETAIL_CORNER_X @private = { 0, 1, 1, 0 };
const int[4] DETAIL_CORNER_Z @private = { 0, 0, 1, 1 };

struct DetailSample @private {
    uint column;
    float height;
    float ceiling;
    float[4] corners;
    uint[4] connections;
    ushort height_voxel;
    char clearance;
    char area;
}

$assert DetailSample::size == 48;

struct DetailReference @private {
    Vec3 origin;
    double[2] origin_correction;
    uint width;
    uint height;
    uint border_size;
    float cell_size;
    float cell_height;
    CompactCell[] columns;
    DetailSample[] samples;
}

struct DetailReferenceHeader @private {
    Vec3 origin;
    double[2] origin_correction;
    uint width;
    uint height;
    uint border_size;
    float cell_size;
    float cell_height;
    uint sample_count;
}

$assert DetailReferenceHeader::size == 56;

fn DetailReference? build_detail_reference(
    Allocator allocator,
    CompactHeightfield* compact,
    uint border_size,
) @private {
    CompactCell[]? columns = alloc::alloc_array_try(allocator, CompactCell, compact.cells.len);
    if (catch columns) return c3d::CAPACITY_EXCEEDED~;
    DetailSample[]? samples = alloc::new_array_try(allocator, DetailSample, compact.span_count);
    if (catch samples) return c3d::CAPACITY_EXCEEDED~;
    columns[..] = compact.cells[..];
    DetailReference reference = {
        .origin = compact.bounds.min + (Vec3){ border_size * compact.cell_size, 0, border_size * compact.cell_size },
        .width = compact.width,
        .height = compact.height,
        .border_size = border_size,
        .cell_size = compact.cell_size,
        .cell_height = compact.cell_height,
        .columns = columns,
        .samples = samples,
    };
    foreach (column_index, column : compact.cells) {
        int x = (int)(column_index % compact.width);
        int z = (int)(column_index / compact.width);
        for (uint index = column.index; index < column.index + column.count; index++) {
            DetailSample* sample = &reference.samples[index];
            CompactSpan* span = &compact.spans[index];
            sample.column = (uint)column_index;
            sample.height = span.y * compact.cell_height;
            sample.ceiling = (float)(span.y + span.links.height) * compact.cell_height;
            sample.area = compact.areas[index];
            sample.height_voxel = span.y;
            sample.clearance = (char)span.links.height;
            for (uint direction = 0; direction < 4; direction++) {
                sample.connections[direction] = NULL_SPAN;
                uint neighbour = neighbour_index(
                    compact: compact,
                    x: x,
                    z: z,
                    index: index,
                    direction: direction,
                );
                if (neighbour == NULL_SPAN) continue;
                uint reciprocal = neighbour_index(
                    compact: compact,
                    x: x + dir_offset_x(direction),
                    z: z + dir_offset_z(direction),
                    index: neighbour,
                    direction: (direction + 2) & 3,
                );
                if (reciprocal == index) sample.connections[direction] = neighbour;
            }
        }
    }
    foreach (index, &sample : reference.samples) {
        int x = (int)(sample.column % reference.width);
        int z = (int)(sample.column / reference.width);
        for (uint corner = 0; corner < 4; corner++) {
            sample.corners[corner] = detail_corner_height(
                reference: &reference,
                seed: (uint)index,
                corner_x: x + DETAIL_CORNER_X[corner],
                corner_z: z + DETAIL_CORNER_Z[corner],
            )!;
        }
    }
    return reference;
}

fn void apply_detail_connections(DetailReference* reference, CompactHeightfield* compact) @private {
    foreach (index, sample : reference.samples) {
        for (uint direction = 0; direction < 4; direction++) {
            uint neighbour = sample.connections[direction];
            uint layer = neighbour == NULL_SPAN ? NOT_CONNECTED : neighbour - reference.columns[reference.samples[neighbour].column].index;
            compact.spans[index].set_connection(direction, layer);
        }
    }
}

fn CompactHeightfield? compact_detail_reference(
    Allocator allocator,
    DetailReference* reference,
    TileConfig* config,
) @private {
    CompactSpan[]? spans = alloc::new_array_try(allocator, CompactSpan, reference.samples.len);
    if (catch spans) return c3d::CAPACITY_EXCEEDED~;
    char[]? areas = alloc::alloc_array_try(allocator, char, reference.samples.len);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;
    Vec3 origin = reference.origin - (Vec3){ reference.border_size * reference.cell_size, 0, reference.border_size * reference.cell_size };
    float highest;
    foreach (index, sample : reference.samples) {
        spans[index].y = sample.height_voxel;
        spans[index].links.height = sample.clearance;
        areas[index] = sample.area;
        highest = math::max(highest, sample.ceiling);
    }
    CompactHeightfield compact = {
        .width = reference.width,
        .height = reference.height,
        .span_count = (uint)reference.samples.len,
        .walkable_height = config.walkable_height,
        .walkable_climb = config.walkable_climb,
        .bounds = { .min = origin, .max = origin + (Vec3){ reference.width * reference.cell_size, highest, reference.height * reference.cell_size } },
        .cell_size = reference.cell_size,
        .cell_height = reference.cell_height,
        .cells = reference.columns,
        .spans = spans,
        .areas = areas,
    };
    apply_detail_connections(reference, &compact);
    return compact;
}

fn void? classify_detail_reference(
    DetailReference* reference,
    CompactHeightfield* compact,
    TileConfig* config,
) @private {
    double slope = math::tan((double)config.slope_degrees * math::PI / 180.0);
    double maximum_gradient = slope * slope;
    foreach (index, &sample : reference.samples) {
        if (compact.areas[index] == NULL_AREA) continue;
        bool walkable = true;
        for (uint triangle_index = 0; triangle_index < 4; triangle_index++) {
            Vec3[3] triangle = detail_reference_triangle(reference, (uint)index, triangle_index);
            if (!detail_triangle_valid(triangle[0], triangle[1], triangle[2])) return c3d::CAPACITY_EXCEEDED~;
            double determinant = detail_triangle_area(triangle[0], triangle[1], triangle[2]);
            double first_height = (double)triangle[1].y - triangle[0].y;
            double second_height = (double)triangle[2].y - triangle[0].y;
            double gradient_x = (first_height * ((double)triangle[2].z - triangle[0].z)
                - second_height * ((double)triangle[1].z - triangle[0].z)) / determinant;
            double gradient_z = (((double)triangle[1].x - triangle[0].x) * second_height
                - ((double)triangle[2].x - triangle[0].x) * first_height) / determinant;
            float highest = math::max(triangle[0].y, math::max(triangle[1].y, triangle[2].y));
            if (gradient_x * gradient_x + gradient_z * gradient_z > maximum_gradient + 3.552713678800501e-15 * math::max(1.0, maximum_gradient)
                || (double)sample.ceiling - highest < config.agent_height) {
                walkable = false;
                break;
            }
        }
        if (!walkable) compact.areas[index] = NULL_AREA;
    }
}

fn Vec3[3] detail_reference_triangle(
    DetailReference* reference,
    uint sample_index,
    uint triangle_index,
) @private {
    Vec3[3] triangle = detail_reference_cell_triangle(reference, sample_index, triangle_index);
    foreach (&point : triangle) {
        point.x = (float)((double)point.x * reference.cell_size);
        point.z = (float)((double)point.z * reference.cell_size);
    }
    return triangle;
}

fn Vec3[3] detail_reference_cell_triangle(
    DetailReference* reference,
    uint sample_index,
    uint triangle_index,
) @private {
    DetailSample* sample = &reference.samples[sample_index];
    int x = (int)(sample.column % reference.width) - (int)reference.border_size;
    int z = (int)(sample.column / reference.width) - (int)reference.border_size;
    uint next = (triangle_index + 1) & 3;
    return {
        {
            (float)(x + DETAIL_CORNER_X[triangle_index]),
            sample.corners[triangle_index],
            (float)(z + DETAIL_CORNER_Z[triangle_index]),
        },
        {
            (float)(x + DETAIL_CORNER_X[next]),
            sample.corners[next],
            (float)(z + DETAIL_CORNER_Z[next]),
        },
        {
            (float)x + 0.5f,
            sample.height,
            (float)z + 0.5f,
        },
    };
}

fn usz detail_reference_size(DetailReference* reference) @private {
    return DetailReferenceHeader::size + reference.columns.len * CompactCell::size + reference.samples.len * DetailSample::size;
}

fn void pack_detail_reference(DetailReference* reference, char[] blob) @private {
    *(DetailReferenceHeader*)blob.ptr = {
        .origin = reference.origin,
        .origin_correction = reference.origin_correction,
        .width = reference.width,
        .height = reference.height,
        .border_size = reference.border_size,
        .cell_size = reference.cell_size,
        .cell_height = reference.cell_height,
        .sample_count = (uint)reference.samples.len,
    };
    usz offset = DetailReferenceHeader::size;
    ((CompactCell*)(blob.ptr + offset))[:reference.columns.len] = reference.columns[..];
    offset += reference.columns.len * CompactCell::size;
    ((DetailSample*)(blob.ptr + offset))[:reference.samples.len] = reference.samples[..];
}

fn DetailReference? read_detail_reference(char[] blob) @private {
    if (blob.len < DetailReferenceHeader::size || (uptr)blob.ptr % DetailReferenceHeader::alignment != 0) return LAYER_CORRUPTED~;
    DetailReferenceHeader* header = (DetailReferenceHeader*)blob.ptr;
    if (!header.width || !header.height || header.width >= MESH_NULL_INDEX || header.height >= MESH_NULL_INDEX
        || header.border_size >= header.width || header.border_size >= header.height
        || header.border_size * 2 >= header.width || header.border_size * 2 >= header.height) return LAYER_CORRUPTED~;
    if (!math::is_finite(header.cell_size) || !math::is_finite(header.cell_height)
        || header.cell_size <= 0 || header.cell_height <= 0) return LAYER_CORRUPTED~;
    if (!math::is_finite(header.origin.x) || !math::is_finite(header.origin.y) || !math::is_finite(header.origin.z)) return LAYER_CORRUPTED~;
    foreach (value : header.origin_correction) {
        if (!math::is_finite(value)) return LAYER_CORRUPTED~;
    }
    usz columns_size = (usz)header.width * header.height * CompactCell::size;
    usz samples_size = (usz)header.sample_count * DetailSample::size;
    if (columns_size > blob.len - DetailReferenceHeader::size || samples_size != blob.len - DetailReferenceHeader::size - columns_size) return LAYER_CORRUPTED~;
    DetailReference reference = {
        .origin = header.origin,
        .origin_correction = header.origin_correction,
        .width = header.width,
        .height = header.height,
        .border_size = header.border_size,
        .cell_size = header.cell_size,
        .cell_height = header.cell_height,
        .columns = ((CompactCell*)(blob.ptr + DetailReferenceHeader::size))[:(usz)header.width * header.height],
        .samples = ((DetailSample*)(blob.ptr + DetailReferenceHeader::size + columns_size))[:header.sample_count],
    };
    usz sample_count;
    foreach (column_index, column : reference.columns) {
        if ((usz)column.index + column.count > reference.samples.len) return LAYER_CORRUPTED~;
        sample_count += column.count;
        for (uint index = column.index; index < column.index + column.count; index++) {
            DetailSample* sample = &reference.samples[index];
            if (sample.column != column_index || !math::is_finite(sample.height) || !math::is_finite(sample.ceiling)
                || sample.ceiling < sample.height || sample.area > WALKABLE_AREA) return LAYER_CORRUPTED~;
            if (sample.height != sample.height_voxel * reference.cell_height
                || sample.ceiling != (float)((uint)sample.height_voxel + sample.clearance) * reference.cell_height) return LAYER_CORRUPTED~;
            foreach (corner : sample.corners) {
                if (!math::is_finite(corner)) return LAYER_CORRUPTED~;
            }
            foreach (direction, neighbour : sample.connections) {
                if (neighbour != NULL_SPAN && neighbour >= reference.samples.len) return LAYER_CORRUPTED~;
                if (neighbour == NULL_SPAN) continue;
                if (reference.samples[neighbour].column >= reference.columns.len) return LAYER_CORRUPTED~;
                CompactCell neighbour_column = reference.columns[reference.samples[neighbour].column];
                if (neighbour < neighbour_column.index || neighbour - neighbour_column.index >= NOT_CONNECTED) return LAYER_CORRUPTED~;
                int neighbour_x = (int)(column_index % reference.width) + dir_offset_x((uint)direction);
                int neighbour_z = (int)(column_index / reference.width) + dir_offset_z((uint)direction);
                if (neighbour_x < 0 || neighbour_x >= (int)reference.width || neighbour_z < 0 || neighbour_z >= (int)reference.height
                    || reference.samples[neighbour].column != (uint)(neighbour_x + neighbour_z * (int)reference.width)
                    || reference.samples[neighbour].connections[(direction + 2) & 3] != index) return LAYER_CORRUPTED~;
            }
        }
    }
    if (sample_count != reference.samples.len) return LAYER_CORRUPTED~;
    foreach (index, sample : reference.samples) {
        int x = (int)(sample.column % reference.width);
        int z = (int)(sample.column / reference.width);
        for (uint corner = 0; corner < 4; corner++) {
            float? height = detail_corner_height(
                reference: &reference,
                seed: (uint)index,
                corner_x: x + DETAIL_CORNER_X[corner],
                corner_z: z + DETAIL_CORNER_Z[corner],
            );
            if (catch height) return LAYER_CORRUPTED~;
            if (height != sample.corners[corner]) return LAYER_CORRUPTED~;
        }
    }
    return reference;
}

fn float? detail_corner_height(
    DetailReference* reference,
    uint seed,
    int corner_x,
    int corner_z,
) @local {
    uint[DETAIL_CORNER_SPANS] visited;
    uint count = 1;
    visited[0] = seed;
    float highest = reference.samples[seed].height;
    for (uint cursor = 0; cursor < count; cursor++) {
        DetailSample* sample = &reference.samples[visited[cursor]];
        highest = math::max(highest, sample.height);
        foreach (neighbour : sample.connections) {
            if (neighbour == NULL_SPAN) continue;
            uint column = reference.samples[neighbour].column;
            int x = (int)(column % reference.width);
            int z = (int)(column / reference.width);
            if (x < corner_x - 1 || x > corner_x || z < corner_z - 1 || z > corner_z) continue;
            bool present;
            foreach (seen : visited[:count]) {
                if (seen == neighbour) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            if (count == visited.len) return c3d::CAPACITY_EXCEEDED~;
            visited[count++] = neighbour;
        }
    }
    return highest;
}
