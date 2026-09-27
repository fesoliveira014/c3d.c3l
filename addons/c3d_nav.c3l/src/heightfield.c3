module c3d::nav;

import std::math;
import c3d;
import c3d::maths;

<* Bits of one span limit; mirrors RC_SPAN_HEIGHT_BITS. *>
const uint SPAN_HEIGHT_BITS = 13;

<* Highest span limit a heightfield holds, in voxels; mirrors RC_SPAN_MAX_HEIGHT. *>
const uint SPAN_MAX_HEIGHT = (1 << SPAN_HEIGHT_BITS) - 1;

<* Area id of unwalkable space; mirrors RC_NULL_AREA. *>
const char NULL_AREA = 0;

<* Default and highest area id of walkable space; mirrors RC_WALKABLE_AREA. *>
const char WALKABLE_AREA = 63;

<* Distinct area ids; the area field is six bits. *>
const uint MAX_AREAS = 64;

<* Span index that ends a column. *>
const uint NULL_SPAN = uint::max;

<* Spans a pool grows by. *>
const uint SPAN_POOL_GROWTH = 2048; // 16 KiB per growth, mirrors RC_SPANS_PER_POOL; the rasterization allocation lever

const int  OPEN_COLUMN_TOP @private = 0xffff; // the ceiling of a column with nothing above; mirrors upstream's MAX_HEIGHT and MAX_HEIGHTFIELD_HEIGHT
const uint CLIP_VERTICES @local = 7; // a triangle clipped by one row and one column plane never exceeds seven vertices

<* Packed limits and area of one span; min inclusive, max exclusive, in voxels. *>
bitstruct SpanExtent : uint {
    uint min  : 0..12;
    uint max  : 13..25;
    uint area : 26..31;
}

<* One solid span of a column; next is the span above or NULL_SPAN. *>
struct Span {
    SpanExtent extent;
    uint       next;
}

$assert Span::size == 8;

<* Span storage that grows and keeps its capacity. *>
struct SpanPool {
    Allocator allocator;
    Span[]    spans;       // capacity; live spans are reachable from columns, the rest from the free list or above high_water
    uint      free_head;   // NULL_SPAN when no released span waits
    uint      high_water;  // first never-used index
}

<* Solid space of one tile as columns of spans. *>
struct Heightfield {
    uint     width;        // columns along X
    uint     height;       // columns along Z
    Aabb     bounds;
    float    cell_size;
    float    cell_height;
    uint[]   columns;      // width * height heads into pool.spans; NULL_SPAN when empty
    SpanPool pool;
}

<*
 Empty every column and release every span to the pool, keeping its capacity.
*>
fn void Heightfield.reset(&self) {
    self.columns[..] = NULL_SPAN;
    self.pool.free_head = NULL_SPAN;
    self.pool.high_water = 0;
}

<*
 Insert a span into a column, merging with spans it touches; mirrors rcAddSpan.
 A span with min >= max is ignored.
 @param merge_threshold : "Voxels within which the higher area id wins when spans merge."
 @return? c3d::CAPACITY_EXCEEDED
 @require x < self.width, z < self.height, max <= SPAN_MAX_HEIGHT, area <= WALKABLE_AREA
*>
fn void? Heightfield.add_span(
    &self,
    uint x,
    uint z,
    uint min,
    uint max,
    char area,
    uint merge_threshold,
) {
    if (min >= max) return;
    return insert_span(
        heightfield:     self,
        x:               x,
        z:               z,
        min:             min,
        max:             max,
        area:            area,
        merge_threshold: merge_threshold,
    );
}

<*
 First span index of a column, or NULL_SPAN.
 @require x < self.width, z < self.height
*>
fn uint Heightfield.span_at(&self, uint x, uint z) => self.columns[x + z * self.width];

<*
 Span of an index from span_at or a span's next.
 Invalidated by add_span and the rasterizers.
 @require index < self.pool.high_water
*>
fn Span* Heightfield.span(&self, uint index) => &self.pool.spans[index];

<*
 Spans whose area is not NULL_AREA; mirrors rcGetHeightFieldSpanCount.
*>
fn uint Heightfield.walkable_span_count(&self) {
    uint count;
    foreach (head : self.columns) {
        for (uint index = head; index != NULL_SPAN; index = self.pool.spans[index].next) {
            if (self.pool.spans[index].extent.area != NULL_AREA) count++;
        }
    }
    return count;
}

<*
 Rasterize one triangle into the columns it overlaps; mirrors rcRasterizeTriangle.
 Triangles outside the bounds add nothing.
 @return? c3d::CAPACITY_EXCEEDED
 @require area <= WALKABLE_AREA
*>
fn void? Heightfield.rasterize_triangle(
    &self,
    Vec3 vertex_a,
    Vec3 vertex_b,
    Vec3 vertex_c,
    char area,
    uint merge_threshold = 1,
) {
    return rasterize(
        heightfield:         self,
        vertex_a:            vertex_a,
        vertex_b:            vertex_b,
        vertex_c:            vertex_c,
        area:                area,
        inverse_cell_size:   1.0f / self.cell_size,
        inverse_cell_height: 1.0f / self.cell_height,
        merge_threshold:     merge_threshold,
    );
}

<*
 Rasterize an indexed triangle list; mirrors rcRasterizeTriangles.
 @param positions : "World space."
 @param areas : "One per triangle."
 @return? c3d::CAPACITY_EXCEEDED
 @require areas.len * 3 == indices.len
*>
fn void? Heightfield.rasterize_triangles(
    &self,
    Vec3[] positions,
    uint[] indices,
    char[] areas,
    uint merge_threshold = 1,
) {
    float inverse_cell_size = 1.0f / self.cell_size;
    float inverse_cell_height = 1.0f / self.cell_height;
    foreach (usz triangle, area : areas) {
        rasterize(
            heightfield:         self,
            vertex_a:            positions[indices[triangle * 3]],
            vertex_b:            positions[indices[triangle * 3 + 1]],
            vertex_c:            positions[indices[triangle * 3 + 2]],
            area:                area,
            inverse_cell_size:   inverse_cell_size,
            inverse_cell_height: inverse_cell_height,
            merge_threshold:     merge_threshold,
        )!;
    }
}

<*
 Heightfield over the bounds with empty columns and room for initial_spans; mirrors rcCreateHeightfield.
 @param bounds : "World space; the grid covers it at cell_size."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require cell_size > 0, cell_height > 0
*>
fn Heightfield? create_heightfield(
    Allocator allocator,
    uint width,
    uint height,
    Aabb bounds,
    float cell_size,
    float cell_height,
    uint initial_spans = SPAN_POOL_GROWTH,
) {
    if (width == 0 || height == 0) return c3d::INVALID_ARGUMENT~;
    uint[]? columns = alloc::new_array_try(allocator, uint, (sz)width * height);
    if (catch columns) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, columns.ptr);
    Span[]? spans = alloc::new_array_try(allocator, Span, initial_spans);
    if (catch spans) return c3d::CAPACITY_EXCEEDED~;

    columns[..] = NULL_SPAN;
    return {
        .width       = width,
        .height      = height,
        .bounds      = bounds,
        .cell_size   = cell_size,
        .cell_height = cell_height,
        .columns     = columns,
        .pool        = { .allocator = allocator, .spans = spans, .free_head = NULL_SPAN },
    };
}

<*
 Free the columns and the pool.
 @param [&inout] heightfield : "Left zeroed."
*>
fn void destroy_heightfield(Heightfield* heightfield) {
    alloc::free(heightfield.pool.allocator, heightfield.columns.ptr);
    alloc::free(heightfield.pool.allocator, heightfield.pool.spans.ptr);
    *heightfield = {};
}

<*
 Columns covering the bounds at the cell size; mirrors rcCalcGridSize.
 @require cell_size > 0
*>
fn uint[<2>] grid_size(Aabb bounds, float cell_size) {
    return {
        (uint)math::max((int)((bounds.max.x - bounds.min.x) / cell_size + 0.5f), 0),
        (uint)math::max((int)((bounds.max.z - bounds.min.z) / cell_size + 0.5f), 0),
    };
}

<*
 Set the area of every triangle flatter than the slope limit to WALKABLE_AREA; mirrors rcMarkWalkableTriangles.
 @param positions : "World space."
 @param [inout] areas : "One per triangle; steeper triangles keep their value."
 @require areas.len * 3 == indices.len, slope_degrees >= 0, slope_degrees < 90
*>
fn void mark_walkable_triangles(
    float slope_degrees,
    Vec3[] positions,
    uint[] indices,
    char[] areas,
) {
    float walkable_limit = walkable_normal_y(slope_degrees);
    foreach (usz triangle, &area : areas) {
        if (normal_y(positions, indices, triangle) > walkable_limit) *area = WALKABLE_AREA;
    }
}

<*
 Set the area of every triangle at or above the slope limit to NULL_AREA; mirrors rcClearUnwalkableTriangles.
 @param [inout] areas : "One per triangle; flatter triangles keep their value."
 @require areas.len * 3 == indices.len, slope_degrees >= 0, slope_degrees < 90
*>
fn void clear_unwalkable_triangles(
    float slope_degrees,
    Vec3[] positions,
    uint[] indices,
    char[] areas,
) {
    float walkable_limit = walkable_normal_y(slope_degrees);
    foreach (usz triangle, &area : areas) {
        if (normal_y(positions, indices, triangle) <= walkable_limit) *area = NULL_AREA;
    }
}

fn float walkable_normal_y(float slope_degrees) @local => math::cos(slope_degrees / 180.0f * (float)math::PI);

fn float normal_y(Vec3[] positions, uint[] indices, usz triangle) @local {
    Vec3 origin = positions[indices[triangle * 3]];
    Vec3 normal = (positions[indices[triangle * 3 + 1]] - origin).cross(positions[indices[triangle * 3 + 2]] - origin);
    return normal.y * (1.0f / math::sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z));
}

fn uint? acquire_span(SpanPool* pool) @local {
    if (pool.free_head != NULL_SPAN) {
        uint index = pool.free_head;
        pool.free_head = pool.spans[index].next;
        return index;
    }
    if (pool.high_water == pool.spans.len) {
        Span[]? grown = alloc::realloc_array_try(pool.allocator, pool.spans.ptr, Span, (sz)pool.spans.len + SPAN_POOL_GROWTH);
        if (catch grown) return c3d::CAPACITY_EXCEEDED~;
        pool.spans = grown;
    }
    return pool.high_water++;
}

fn void release_span(SpanPool* pool, uint index) @local {
    pool.spans[index].next = pool.free_head;
    pool.free_head = index;
}

fn void? insert_span(
    Heightfield* heightfield,
    uint x,
    uint z,
    uint min,
    uint max,
    char area,
    uint merge_threshold,
) @local {
    uint inserted = acquire_span(&heightfield.pool)!;
    Span[] spans = heightfield.pool.spans;
    SpanExtent extent = { .min = min, .max = max, .area = area };
    uint column = x + z * heightfield.width;

    uint previous = NULL_SPAN;
    uint current = heightfield.columns[column];
    while (current != NULL_SPAN) {
        SpanExtent existing = spans[current].extent;
        if (existing.min > extent.max) break;
        if (existing.max < extent.min) {
            previous = current;
            current = spans[current].next;
            continue;
        }
        if (existing.min < extent.min) extent.min = existing.min;
        if (existing.max > extent.max) extent.max = existing.max;
        if (math::abs((int)extent.max - (int)existing.max) <= (int)merge_threshold) {
            extent.area = math::max(extent.area, existing.area);
        }
        uint next = spans[current].next;
        release_span(&heightfield.pool, current);
        if (previous != NULL_SPAN) {
            spans[previous].next = next;
        } else {
            heightfield.columns[column] = next;
        }
        current = next;
    }

    spans[inserted].extent = extent;
    if (previous != NULL_SPAN) {
        spans[inserted].next = spans[previous].next;
        spans[previous].next = inserted;
    } else {
        spans[inserted].next = heightfield.columns[column];
        heightfield.columns[column] = inserted;
    }
}

fn bool overlap_bounds(Aabb first, Aabb second) @private {
    return first.min.x <= second.max.x && first.max.x >= second.min.x
        && first.min.y <= second.max.y && first.max.y >= second.min.y
        && first.min.z <= second.max.z && first.max.z >= second.min.z;
}

// Returns the vertex counts of the part below the axis offset and of the remainder.
fn uint[<2>] divide_poly(
    Vec3[] input,
    Vec3[] out_below,
    Vec3[] out_remainder,
    float axis_offset,
    uint axis,
) @local {
    float[CLIP_VERTICES] delta;
    foreach (index, vertex : input) delta[index] = axis_offset - vertex[axis];

    uint below_count;
    uint remainder_count;
    usz previous = input.len - 1;
    for (usz current = 0; current < input.len; previous = current++) {
        bool same_side = (delta[current] >= 0) == (delta[previous] >= 0);
        if (!same_side) {
            float fraction = delta[previous] / (delta[previous] - delta[current]);
            Vec3 crossing = input[previous] + (input[current] - input[previous]) * fraction;
            out_below[below_count++] = crossing;
            out_remainder[remainder_count++] = crossing;
            // A vertex on the dividing line was already added as the crossing.
            if (delta[current] > 0) {
                out_below[below_count++] = input[current];
            } else if (delta[current] < 0) {
                out_remainder[remainder_count++] = input[current];
            }
            continue;
        }
        if (delta[current] >= 0) {
            out_below[below_count++] = input[current];
            if (delta[current] != 0) continue;
        }
        out_remainder[remainder_count++] = input[current];
    }
    return { below_count, remainder_count };
}

fn void? rasterize(
    Heightfield* heightfield,
    Vec3 vertex_a,
    Vec3 vertex_b,
    Vec3 vertex_c,
    char area,
    float inverse_cell_size,
    float inverse_cell_height,
    uint merge_threshold,
) @local {
    Aabb triangle = {
        .min = math::min(math::min(vertex_a, vertex_b), vertex_c),
        .max = math::max(math::max(vertex_a, vertex_b), vertex_c),
    };
    if (!overlap_bounds(triangle, heightfield.bounds)) return;

    int width = (int)heightfield.width;
    int height = (int)heightfield.height;
    Vec3 origin = heightfield.bounds.min;
    float bounds_height = heightfield.bounds.max.y - origin.y;
    float cell_size = heightfield.cell_size;

    // -1 rather than 0 so the polygon is cut at the tile's first row and column.
    int first_z = math::clamp((int)((triangle.min.z - origin.z) * inverse_cell_size), -1, height - 1);
    int last_z = math::clamp((int)((triangle.max.z - origin.z) * inverse_cell_size), 0, height - 1);

    Vec3[CLIP_VERTICES * 4] buffer;
    Vec3[] polygon = buffer[0:CLIP_VERTICES];
    Vec3[] row = buffer[CLIP_VERTICES:CLIP_VERTICES];
    Vec3[] cell = buffer[CLIP_VERTICES * 2:CLIP_VERTICES];
    Vec3[] row_remainder = buffer[CLIP_VERTICES * 3:CLIP_VERTICES];
    polygon[0] = vertex_a;
    polygon[1] = vertex_b;
    polygon[2] = vertex_c;
    uint polygon_count = 3;

    for (int z = first_z; z <= last_z; z++) {
        float cell_z = origin.z + (float)z * cell_size;
        uint[<2>] row_counts = divide_poly(polygon[:polygon_count], row, cell, cell_z + cell_size, 2);
        uint row_count = row_counts[0];
        polygon_count = row_counts[1];
        @swap(polygon, cell);
        if (row_count < 3 || z < 0) continue;

        float min_x = row[0].x;
        float max_x = row[0].x;
        foreach (vertex : row[1:row_count - 1]) {
            min_x = math::min(min_x, vertex.x);
            max_x = math::max(max_x, vertex.x);
        }
        int first_x = (int)((min_x - origin.x) * inverse_cell_size);
        int last_x = (int)((max_x - origin.x) * inverse_cell_size);
        if (last_x < 0 || first_x >= width) continue;
        first_x = math::clamp(first_x, -1, width - 1);
        last_x = math::clamp(last_x, 0, width - 1);

        uint remaining = row_count;
        for (int x = first_x; x <= last_x; x++) {
            float cell_x = origin.x + (float)x * cell_size;
            uint[<2>] cell_counts = divide_poly(row[:remaining], cell, row_remainder, cell_x + cell_size, 0);
            uint cell_count = cell_counts[0];
            remaining = cell_counts[1];
            @swap(row, row_remainder);
            if (cell_count < 3 || x < 0) continue;

            float span_min = cell[0].y;
            float span_max = cell[0].y;
            foreach (vertex : cell[1:cell_count - 1]) {
                span_min = math::min(span_min, vertex.y);
                span_max = math::max(span_max, vertex.y);
            }
            span_min -= origin.y;
            span_max -= origin.y;
            if (span_max < 0 || span_min > bounds_height) continue;
            span_min = math::max(span_min, 0.0f);
            span_max = math::min(span_max, bounds_height);

            int min_index = math::clamp((int)math::floor(span_min * inverse_cell_height), 0, (int)SPAN_MAX_HEIGHT);
            int max_index = math::clamp((int)math::ceil(span_max * inverse_cell_height), min_index + 1, (int)SPAN_MAX_HEIGHT);
            insert_span(
                heightfield:     heightfield,
                x:               (uint)x,
                z:               (uint)z,
                min:             (uint)min_index,
                max:             (uint)max_index,
                area:            area,
                merge_threshold: merge_threshold,
            )!;
        }
    }
}
