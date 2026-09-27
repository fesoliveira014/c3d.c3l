module c3d::nav;

import std::math;
import c3d;
import c3d::maths;

<* Neighbour layer meaning no connection; mirrors RC_NOT_CONNECTED. *>
const uint NOT_CONNECTED = 0x3f;

const int  MAX_CLEARANCE @local = 0xff; // the clearance field is eight bits
const uint MAX_NEIGHBOUR_LAYER @local = NOT_CONNECTED - 1; // a neighbour column deeper than this cannot be linked
const int[4] DIRECTION_OFFSET_X @local = { -1, 0, 1, 0 };
const int[4] DIRECTION_OFFSET_Z @local = { 0, 1, 0, -1 };
const int[5] DIRECTION_FOR_OFFSET @local = { 3, 0, -1, 2, 1 }; // indexed by (offset_z + 1) * 2 + offset_x

<* First span index and span count of one compact column. *>
bitstruct CompactCell : uint {
    uint index : 0..23;
    uint count : 24..31;
}

<* Four six-bit neighbour layers and the clearance of one open span. *>
bitstruct CompactLinks : uint {
    uint connections : 0..23;
    uint height      : 24..31;
}

<* One open span; y is its floor above the heightfield base, region 0 means none. *>
struct CompactSpan {
    ushort       y;
    ushort       region;
    CompactLinks links;
}

$assert CompactSpan::size == 8;

<* Open space of one tile, spans packed by column. *>
struct CompactHeightfield {
    uint          width;
    uint          height;
    uint          span_count;
    uint          walkable_height;
    uint          walkable_climb;
    uint          border_size;
    ushort        max_distance;
    ushort        max_regions;
    Aabb          bounds;
    float         cell_size;
    float         cell_height;
    CompactCell[] cells;      // width * height
    CompactSpan[] spans;      // span_count
    ushort[]      distances;  // empty; the distance field is not built
    char[]        areas;      // span_count
}

<*
 Layer of the neighbour span in the direction within its column, or NOT_CONNECTED; mirrors rcGetCon.
 @require direction < 4
*>
fn uint CompactSpan.connection(&self, uint direction) {
    return (self.links.connections >> (direction * 6)) & NOT_CONNECTED;
}

<*
 Set the neighbour layer in the direction; mirrors rcSetCon.
 @require direction < 4, layer <= NOT_CONNECTED
*>
fn void CompactSpan.set_connection(&self, uint direction, uint layer) {
    uint shift = direction * 6;
    self.links.connections = (self.links.connections & ~(NOT_CONNECTED << shift)) | (layer << shift);
}

<*
 Compact heightfield of the open space above walkable spans; mirrors rcBuildCompactHeightfield.
 Arrays come from the allocator and are never freed by the result; pass an arena.
 @param [&in] heightfield : "Filtered."
 @return? c3d::CAPACITY_EXCEEDED
 @require walkable_height >= 3
*>
fn CompactHeightfield? build_compact_heightfield(
    Allocator allocator,
    Heightfield* heightfield,
    uint walkable_height,
    uint walkable_climb,
) {
    uint span_count = heightfield.walkable_span_count();
    CompactCell[]? cells = alloc::new_array_try(allocator, CompactCell, (sz)heightfield.width * heightfield.height);
    if (catch cells) return c3d::CAPACITY_EXCEEDED~;
    CompactSpan[]? spans = alloc::new_array_try(allocator, CompactSpan, span_count);
    if (catch spans) return c3d::CAPACITY_EXCEEDED~;
    char[]? areas = alloc::new_array_try(allocator, char, span_count);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;

    CompactHeightfield compact = {
        .width           = heightfield.width,
        .height          = heightfield.height,
        .span_count      = span_count,
        .walkable_height = walkable_height,
        .walkable_climb  = walkable_climb,
        .bounds          = heightfield.bounds,
        .cell_size       = heightfield.cell_size,
        .cell_height     = heightfield.cell_height,
        .cells           = cells,
        .spans           = spans,
        .areas           = areas,
    };
    compact.bounds.max.y += walkable_height * heightfield.cell_height;

    fill_columns(&compact, heightfield);
    link_neighbours(&compact);
    return compact;
}

<* X step of a direction; mirrors rcGetDirOffsetX. *>
fn int dir_offset_x(uint direction) => DIRECTION_OFFSET_X[direction & 3];

<* Z step of a direction; mirrors rcGetDirOffsetY. *>
fn int dir_offset_z(uint direction) => DIRECTION_OFFSET_Z[direction & 3];

<*
 Direction of a unit step; mirrors rcGetDirForOffset.
 @require math::abs(offset_x) + math::abs(offset_z) == 1
*>
fn uint dir_for_offset(int offset_x, int offset_z) => (uint)DIRECTION_FOR_OFFSET[(offset_z + 1) * 2 + offset_x];

fn void fill_columns(CompactHeightfield* compact, Heightfield* heightfield) @local {
    Span[] source = heightfield.pool.spans;
    uint next_span;
    foreach (column, head : heightfield.columns) {
        if (head == NULL_SPAN) continue;
        compact.cells[column].index = next_span;
        uint count;
        for (uint index = head; index != NULL_SPAN; index = source[index].next) {
            if (source[index].extent.area == NULL_AREA) continue;
            int bottom = (int)source[index].extent.max;
            int top = source[index].next != NULL_SPAN ? (int)source[source[index].next].extent.min : OPEN_COLUMN_TOP;
            compact.spans[next_span].y = (ushort)math::clamp(bottom, 0, OPEN_COLUMN_TOP);
            compact.spans[next_span].links.height = (uint)math::clamp(top - bottom, 0, MAX_CLEARANCE);
            compact.areas[next_span] = (char)source[index].extent.area;
            next_span++;
            count++;
        }
        compact.cells[column].count = count;
    }
}

fn void link_neighbours(CompactHeightfield* compact) @local {
    int width = (int)compact.width;
    int height = (int)compact.height;
    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = compact.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                CompactSpan* span = &compact.spans[index];
                for (uint direction = 0; direction < 4; direction++) {
                    span.set_connection(direction, NOT_CONNECTED);
                    int neighbour_x = x + dir_offset_x(direction);
                    int neighbour_z = z + dir_offset_z(direction);
                    if (neighbour_x < 0 || neighbour_z < 0 || neighbour_x >= width || neighbour_z >= height) continue;

                    CompactCell neighbour_cell = compact.cells[neighbour_x + neighbour_z * width];
                    for (uint layer = 0; layer < neighbour_cell.count; layer++) {
                        CompactSpan* neighbour = &compact.spans[neighbour_cell.index + layer];
                        int bottom = math::max((int)span.y, (int)neighbour.y);
                        int top = math::min((int)span.y + (int)span.links.height, (int)neighbour.y + (int)neighbour.links.height);
                        if (top - bottom < (int)compact.walkable_height) continue;
                        if (math::abs((int)neighbour.y - (int)span.y) > (int)compact.walkable_climb) continue;
                        if (layer > MAX_NEIGHBOUR_LAYER) continue;
                        span.set_connection(direction, layer);
                        break;
                    }
                }
            }
        }
    }
}
