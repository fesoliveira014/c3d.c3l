module c3d::nav;

import std::math;
import c3d;

<* Layers one tile may split into; mirrors RC_MAX_LAYERS. *>
const uint MAX_LAYERS = 63; // layer ids are bytes with 0xff reserved; 63 bytes of overlap list per layer region

<* Neighbours one layer region tracks; mirrors RC_MAX_NEIS. *>
const uint MAX_LAYER_NEIGHBOURS = 16; // a region past it starts extra layers instead of joining its neighbours'

const char NO_LAYER_REGION @local = 0xff; // mirrors the 0xff of srcReg, layerId and the sweep neighbour
const int  MAX_LAYER_STACK @local = 64; // mirrors the layer flood's MAX_STACK
const int  MAX_LAYER_HEIGHT_RANGE @local = 255; // layer heights above hmin are stored in a byte
const uint LAYER_MERGE_HEIGHT_SCALE @local = 4; // mirrors mergeHeight = walkableHeight * 4
const uint DIRECTION_NEGATIVE_X @local = 0;
const uint DIRECTION_NEGATIVE_Z @local = 3;

<* One non-overlapping height layer of a tile; mirrors rcHeightfieldLayer. *>
struct HeightfieldLayer {
    Aabb   bounds;        // without the border; Y spans hmin to hmax
    float  cell_size;
    float  cell_height;
    uint   width;         // cells, without the border
    uint   height;
    uint   min_x;         // the cells holding data
    uint   max_x;
    uint   min_z;
    uint   max_z;
    uint   hmin;          // voxels above the compact heightfield's base
    uint   hmax;
    char[] heights;       // width * height voxels above hmin; 0xff where empty
    char[] areas;
    char[] connections;   // low four bits link neighbours in the layer, high four mark portals
}

struct LayerSweepSpan @local {
    ushort sample_count;
    char   id;
    char   neighbour;
}

struct LayerRegion @local {
    char[MAX_LAYERS]           layers;          // regions sharing a column with this one
    char[MAX_LAYER_NEIGHBOURS] neighbours;
    ushort                     min_y;
    ushort                     max_y;
    char                       layer_id;
    char                       layer_count;
    char                       neighbour_count;
    bool                       base;            // the root of the regions merged into its layer
}

<*
 Split the compact heightfield into non-overlapping layers; mirrors rcBuildHeightfieldLayers.
 @param allocator : "Receives the layers and their arrays; never freed by the result."
 @param scratch : "Holds the span regions, sweeps and layer regions for the call."
 @param [&in] compact : "Eroded."
 @param border_size : "Voxels trimmed from each side."
 @return "Empty when nothing is walkable."
 @return? c3d::CAPACITY_EXCEEDED
 @require walkable_height > 0
*>
fn HeightfieldLayer[]? build_heightfield_layers(
    Allocator allocator,
    Allocator scratch,
    CompactHeightfield* compact,
    uint border_size,
    uint walkable_height,
) {
    int width = (int)compact.width;
    int height = (int)compact.height;
    int border = (int)border_size;

    char[]? span_regions = alloc::alloc_array_try(scratch, char, compact.span_count);
    if (catch span_regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, span_regions.ptr);
    span_regions[..] = NO_LAYER_REGION;

    uint largest_row = 1;
    for (int z = border; z < height - border; z++) {
        uint row_spans;
        for (int x = border; x < width - border; x++) row_spans += compact.cells[x + z * width].count;
        largest_row = math::max(largest_row, row_spans);
    }
    // Upstream sizes the sweeps by the width, too few when a row holds stacked spans.
    LayerSweepSpan[]? sweeps = alloc::new_array_try(scratch, LayerSweepSpan, largest_row);
    if (catch sweeps) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, sweeps.ptr);

    char region_count = sweep_layer_regions(
        compact:      compact,
        border:       border,
        span_regions: span_regions,
        sweeps:       sweeps,
    )!;

    LayerRegion[]? regions = alloc::new_array_try(scratch, LayerRegion, region_count);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, regions.ptr);
    foreach (&region : regions) {
        region.layer_id = NO_LAYER_REGION;
        region.min_y = ushort::max;
    }

    find_layer_neighbours(compact, span_regions, regions)!;
    flood_layers(regions)!;
    merge_close_layers(regions, (int)(walkable_height * LAYER_MERGE_HEIGHT_SCALE))!;
    char layer_count = compact_layer_ids(regions);
    if (layer_count == 0) return {};

    HeightfieldLayer[]? layers = alloc::new_array_try(allocator, HeightfieldLayer, layer_count);
    if (catch layers) return c3d::CAPACITY_EXCEEDED~;
    int layer_width = width - border * 2;
    int layer_height = height - border * 2;
    Aabb bounds = compact.bounds;
    float pad = border * compact.cell_size;
    bounds.min.x += pad;
    bounds.min.z += pad;
    bounds.max.x -= pad;
    bounds.max.z -= pad;

    foreach (index, &layer : layers) {
        sz cells = (sz)layer_width * layer_height;
        char[]? heights = alloc::alloc_array_try(allocator, char, cells);
        if (catch heights) return c3d::CAPACITY_EXCEEDED~;
        char[]? areas = alloc::new_array_try(allocator, char, cells);
        if (catch areas) return c3d::CAPACITY_EXCEEDED~;
        char[]? connections = alloc::new_array_try(allocator, char, cells);
        if (catch connections) return c3d::CAPACITY_EXCEEDED~;
        heights[..] = NO_LAYER_REGION;

        uint hmin;
        uint hmax;
        foreach (&region : regions) {
            if (!region.base || region.layer_id != (char)index) continue;
            hmin = region.min_y;
            hmax = region.max_y;
        }
        *layer = {
            .bounds      = bounds,
            .cell_size   = compact.cell_size,
            .cell_height = compact.cell_height,
            .width       = (uint)layer_width,
            .height      = (uint)layer_height,
            .hmin        = hmin,
            .hmax        = hmax,
            .heights     = heights,
            .areas       = areas,
            .connections = connections,
        };
        layer.bounds.min.y = compact.bounds.min.y + hmin * compact.cell_height;
        layer.bounds.max.y = compact.bounds.min.y + hmax * compact.cell_height;
        fill_layer(
            layer:        layer,
            layer_id:     (char)index,
            compact:      compact,
            border:       border,
            span_regions: span_regions,
            regions:      regions,
        );
    }
    return layers;
}

// Monotone regions over the tile interior, one byte id per span; mirrors the sweep of rcBuildHeightfieldLayers.
fn char? sweep_layer_regions(
    CompactHeightfield* compact,
    int border,
    char[] span_regions,
    LayerSweepSpan[] sweeps,
) @local {
    int width = (int)compact.width;
    int height = (int)compact.height;
    int[256] row_samples;
    char next_region;

    for (int z = border; z < height - border; z++) {
        row_samples[:next_region] = 0;
        char next_sweep;
        for (int x = border; x < width - border; x++) {
            CompactCell cell = compact.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (compact.areas[index] == NULL_AREA) continue;

                char sweep = NO_LAYER_REGION;
                uint lower_x = neighbour_index(
                    compact:   compact,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: DIRECTION_NEGATIVE_X,
                );
                if (lower_x != NULL_SPAN && compact.areas[lower_x] != NULL_AREA) sweep = span_regions[lower_x];
                if (sweep == NO_LAYER_REGION) {
                    // A byte sweep id reaching 0xff would read as no sweep.
                    if (next_sweep == NO_LAYER_REGION) return c3d::CAPACITY_EXCEEDED~;
                    sweep = next_sweep++;
                    sweeps[sweep].neighbour = NO_LAYER_REGION;
                    sweeps[sweep].sample_count = 0;
                }

                uint lower_z = neighbour_index(
                    compact:   compact,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: DIRECTION_NEGATIVE_Z,
                );
                if (lower_z != NULL_SPAN && span_regions[lower_z] != NO_LAYER_REGION) {
                    char neighbour = span_regions[lower_z];
                    if (sweeps[sweep].sample_count == 0) sweeps[sweep].neighbour = neighbour;
                    if (sweeps[sweep].neighbour == neighbour) {
                        sweeps[sweep].sample_count++;
                        row_samples[neighbour]++;
                    } else {
                        // A second region below invalidates the merge.
                        sweeps[sweep].neighbour = NO_LAYER_REGION;
                    }
                }
                span_regions[index] = sweep;
            }
        }

        foreach (&sweep : sweeps[:next_sweep]) {
            if (sweep.neighbour != NO_LAYER_REGION && row_samples[sweep.neighbour] == sweep.sample_count) {
                sweep.id = sweep.neighbour;
                continue;
            }
            if (next_region == NO_LAYER_REGION) return c3d::CAPACITY_EXCEEDED~;
            sweep.id = next_region++;
        }
        for (int x = border; x < width - border; x++) {
            CompactCell cell = compact.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (span_regions[index] != NO_LAYER_REGION) span_regions[index] = sweeps[span_regions[index]].id;
            }
        }
    }
    return next_region;
}

fn void? find_layer_neighbours(CompactHeightfield* compact, char[] span_regions, LayerRegion[] regions) @local {
    int width = (int)compact.width;
    int height = (int)compact.height;
    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = compact.cells[x + z * width];
            char[MAX_LAYERS] column_regions;
            int column_count;
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                char region_id = span_regions[index];
                if (region_id == NO_LAYER_REGION) continue;
                LayerRegion* region = &regions[region_id];
                ushort floor = compact.spans[index].y;
                region.min_y = math::min(region.min_y, floor);
                region.max_y = math::max(region.max_y, floor);
                if (column_count < (int)MAX_LAYERS) column_regions[column_count++] = region_id;

                for (uint direction = 0; direction < 4; direction++) {
                    uint neighbour = neighbour_index(
                        compact:   compact,
                        x:         x,
                        z:         z,
                        index:     index,
                        direction: direction,
                    );
                    if (neighbour == NULL_SPAN) continue;
                    char other = span_regions[neighbour];
                    if (other == NO_LAYER_REGION || other == region_id) continue;
                    // A full neighbour list only splits the flood into more layers, as upstream accepts.
                    (void)add_unique_layer(region.neighbours[..], &region.neighbour_count, other);
                }
            }

            for (int first = 0; first < column_count - 1; first++) {
                for (int second = first + 1; second < column_count; second++) {
                    char first_id = column_regions[first];
                    char second_id = column_regions[second];
                    if (first_id == second_id) continue;
                    LayerRegion* first_region = &regions[first_id];
                    LayerRegion* second_region = &regions[second_id];
                    if (!add_unique_layer(first_region.layers[..], &first_region.layer_count, second_id)) {
                        return c3d::CAPACITY_EXCEEDED~;
                    }
                    if (!add_unique_layer(second_region.layers[..], &second_region.layer_count, first_id)) {
                        return c3d::CAPACITY_EXCEEDED~;
                    }
                }
            }
        }
    }
}

// Flood each unvisited region's neighbours into its layer while they overlap nothing already in it.
fn void? flood_layers(LayerRegion[] regions) @local {
    char next_layer;
    char[MAX_LAYER_STACK] stack;
    foreach (root_index, &root : regions) {
        if (root.layer_id != NO_LAYER_REGION) continue;
        root.layer_id = next_layer;
        root.base = true;

        int stack_count;
        stack[stack_count++] = (char)root_index;
        while (stack_count > 0) {
            LayerRegion* region = &regions[stack[0]];
            stack_count--;
            for (int shifted = 0; shifted < stack_count; shifted++) stack[shifted] = stack[shifted + 1];

            foreach (neighbour_id : region.neighbours[:region.neighbour_count]) {
                LayerRegion* neighbour = &regions[neighbour_id];
                if (neighbour.layer_id != NO_LAYER_REGION) continue;
                if (contains_layer(root.layers[:root.layer_count], neighbour_id)) continue;
                int min_y = math::min((int)root.min_y, (int)neighbour.min_y);
                int max_y = math::max((int)root.max_y, (int)neighbour.max_y);
                if (max_y - min_y >= MAX_LAYER_HEIGHT_RANGE) continue;
                if (stack_count >= MAX_LAYER_STACK) continue;

                stack[stack_count++] = neighbour_id;
                neighbour.layer_id = next_layer;
                foreach (layer : neighbour.layers[:neighbour.layer_count]) {
                    if (!add_unique_layer(root.layers[..], &root.layer_count, layer)) return c3d::CAPACITY_EXCEEDED~;
                }
                root.min_y = (ushort)min_y;
                root.max_y = (ushort)max_y;
            }
        }
        next_layer++;
    }
}

// Merge layers whose height ranges lie within merge_height of each other and whose regions never share a column.
fn void? merge_close_layers(LayerRegion[] regions, int merge_height) @local {
    foreach (first_index, &first : regions) {
        if (!first.base) continue;
        char new_id = first.layer_id;
        while (true) {
            char old_id = NO_LAYER_REGION;
            foreach (second_index, &second : regions) {
                if (first_index == second_index || !second.base) continue;
                int first_top = (int)first.max_y + merge_height;
                int second_top = (int)second.max_y + merge_height;
                if ((int)first.min_y > second_top || first_top < (int)second.min_y) continue;
                int min_y = math::min((int)first.min_y, (int)second.min_y);
                int max_y = math::max((int)first.max_y, (int)second.max_y);
                if (max_y - min_y >= MAX_LAYER_HEIGHT_RANGE) continue;

                bool overlap;
                foreach (other_index, &other : regions) {
                    if (other.layer_id != second.layer_id) continue;
                    if (contains_layer(first.layers[:first.layer_count], (char)other_index)) {
                        overlap = true;
                        break;
                    }
                }
                if (overlap) continue;
                old_id = second.layer_id;
                break;
            }
            if (old_id == NO_LAYER_REGION) break;

            foreach (&merged : regions) {
                if (merged.layer_id != old_id) continue;
                merged.base = false;
                merged.layer_id = new_id;
                foreach (layer : merged.layers[:merged.layer_count]) {
                    if (!add_unique_layer(first.layers[..], &first.layer_count, layer)) return c3d::CAPACITY_EXCEEDED~;
                }
                first.min_y = math::min(first.min_y, merged.min_y);
                first.max_y = math::max(first.max_y, merged.max_y);
            }
        }
    }
}

// Renumber layer ids densely from 0; the count of distinct layers.
fn char compact_layer_ids(LayerRegion[] regions) @local {
    char[256] remap;
    foreach (&region : regions) remap[region.layer_id] = 1;
    char next_layer;
    foreach (&id : remap) {
        if (*id) {
            *id = next_layer++;
        } else {
            *id = NO_LAYER_REGION;
        }
    }
    foreach (&region : regions) region.layer_id = remap[region.layer_id];
    return next_layer;
}

fn void fill_layer(
    HeightfieldLayer* layer,
    char layer_id,
    CompactHeightfield* compact,
    int border,
    char[] span_regions,
    LayerRegion[] regions,
) @local {
    int width = (int)compact.width;
    int layer_width = (int)layer.width;
    int layer_height = (int)layer.height;
    int min_x = layer_width;
    int max_x;
    int min_z = layer_height;
    int max_z;

    for (int z = 0; z < layer_height; z++) {
        for (int x = 0; x < layer_width; x++) {
            int column_x = border + x;
            int column_z = border + z;
            CompactCell cell = compact.cells[column_x + column_z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (span_regions[index] == NO_LAYER_REGION) continue;
                if (regions[span_regions[index]].layer_id != layer_id) continue;

                min_x = math::min(min_x, x);
                max_x = math::max(max_x, x);
                min_z = math::min(min_z, z);
                max_z = math::max(max_z, z);
                usz cell_index = (usz)(x + z * layer_width);
                layer.heights[cell_index] = (char)(compact.spans[index].y - layer.hmin);
                layer.areas[cell_index] = compact.areas[index];

                char portals;
                char links;
                for (uint direction = 0; direction < 4; direction++) {
                    uint neighbour = neighbour_index(
                        compact:   compact,
                        x:         column_x,
                        z:         column_z,
                        index:     index,
                        direction: direction,
                    );
                    if (neighbour == NULL_SPAN || compact.areas[neighbour] == NULL_AREA) continue;
                    char neighbour_region = span_regions[neighbour];
                    char neighbour_layer = neighbour_region != NO_LAYER_REGION ? regions[neighbour_region].layer_id : NO_LAYER_REGION;
                    if (neighbour_layer != layer_id) {
                        portals |= (char)(1 << direction);
                        // Raised so the heights match on both sides of the portal.
                        ushort neighbour_floor = compact.spans[neighbour].y;
                        if (neighbour_floor > layer.hmin) {
                            layer.heights[cell_index] = math::max(layer.heights[cell_index], (char)(neighbour_floor - layer.hmin));
                        }
                        continue;
                    }
                    int neighbour_x = column_x + dir_offset_x(direction) - border;
                    int neighbour_z = column_z + dir_offset_z(direction) - border;
                    if (neighbour_x >= 0 && neighbour_z >= 0 && neighbour_x < layer_width && neighbour_z < layer_height) {
                        links |= (char)(1 << direction);
                    }
                }
                layer.connections[cell_index] = portals << 4 | links;
            }
        }
    }

    if (min_x > max_x) {
        min_x = 0;
        max_x = 0;
    }
    if (min_z > max_z) {
        min_z = 0;
        max_z = 0;
    }
    layer.min_x = (uint)min_x;
    layer.max_x = (uint)max_x;
    layer.min_z = (uint)min_z;
    layer.max_z = (uint)max_z;
}

fn bool contains_layer(char[] items, char value) @local {
    foreach (item : items) {
        if (item == value) return true;
    }
    return false;
}

// False only when the list is full and lacks the value.
fn bool add_unique_layer(char[] items, char* count, char value) @local {
    if (contains_layer(items[:*count], value)) return true;
    if ((usz)*count >= items.len) return false;
    items[(*count)++] = value;
    return true;
}
