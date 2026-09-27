module c3d::nav;

import std::math;
import c3d;

<* Region id bit marking a tile-border region; mirrors RC_BORDER_REG. *>
const ushort BORDER_REGION = 0x8000;

const ushort NULL_NEIGHBOUR @local = 0xffff; // mirrors RC_NULL_NEI: the run touches two regions of the row below
const uint   DIRECTION_NEGATIVE_X @local = 0;
const uint   DIRECTION_NEGATIVE_Z @local = 3;
const sz     REGION_LIST_CAPACITY @local = 8; // initial connections and floors per region; lists double from here
const sz     REGION_STACK_CAPACITY @local = 32; // mirrors upstream's stack(32) and trace(32)
const sz     ROW_REGION_CAPACITY @local = 256; // mirrors upstream's prev(256); grows to the region count

struct SweepSpan @local {
    ushort region;
    ushort sample_count;
    ushort neighbour;
}

struct RegionRecord @local {
    int     span_count;
    ushort  id;
    char    area;
    bool    remap;
    bool    visited;
    bool    overlap;
    IntList connections;
    IntList floors;
}

<*
 Partition the walkable spans into monotone regions; mirrors rcBuildRegionsMonotone.
 Writes CompactSpan.region, max_regions and border_size.
 @param scratch : "Holds the sweep tables and per-region lists for the call."
 @param border_size : "Voxels; spans inside it get border regions."
 @param min_region_area : "Spans; smaller islands not touching the border are removed."
 @param merge_region_area : "Spans; smaller regions merge into a neighbour when they can."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? CompactHeightfield.build_regions_monotone(
    &self,
    Allocator scratch,
    uint border_size,
    uint min_region_area,
    uint merge_region_area,
) {
    int width = (int)self.width;
    int height = (int)self.height;
    int border = (int)border_size;
    ushort next_id = 1;

    ushort[]? span_regions = alloc::new_array_try(scratch, ushort, self.span_count);
    if (catch span_regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, span_regions.ptr);

    uint largest_row;
    for (int z = 0; z < height; z++) {
        uint row_spans;
        for (int x = 0; x < width; x++) row_spans += self.cells[x + z * width].count;
        largest_row = math::max(largest_row, row_spans);
    }
    // Run ids start at 1 and reach the row's run count; upstream's max(width, height) entries can be too few.
    SweepSpan[]? sweeps = alloc::new_array_try(scratch, SweepSpan, (sz)largest_row + 1);
    if (catch sweeps) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, sweeps.ptr);

    if (border > 0) {
        int border_width = math::min(width, border);
        int border_height = math::min(height, border);
        paint_rect_region(
            compact:      self,
            span_regions: span_regions,
            min_x:        0,
            max_x:        border_width,
            min_z:        0,
            max_z:        height,
            region:       next_id++ | BORDER_REGION,
        );
        paint_rect_region(
            compact:      self,
            span_regions: span_regions,
            min_x:        width - border_width,
            max_x:        width,
            min_z:        0,
            max_z:        height,
            region:       next_id++ | BORDER_REGION,
        );
        paint_rect_region(
            compact:      self,
            span_regions: span_regions,
            min_x:        0,
            max_x:        width,
            min_z:        0,
            max_z:        border_height,
            region:       next_id++ | BORDER_REGION,
        );
        paint_rect_region(
            compact:      self,
            span_regions: span_regions,
            min_x:        0,
            max_x:        width,
            min_z:        height - border_height,
            max_z:        height,
            region:       next_id++ | BORDER_REGION,
        );
    }

    IntList row_samples = create_int_list(scratch, ROW_REGION_CAPACITY)!;
    defer destroy_int_list(&row_samples);

    for (int z = border; z < height - border; z++) {
        row_samples.resize((sz)next_id + 1)!;
        row_samples.view()[..] = 0;
        ushort next_run = 1;

        for (int x = border; x < width - border; x++) {
            CompactCell cell = self.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (self.areas[index] == NULL_AREA) continue;

                ushort run;
                uint lower_x_span = neighbour_index(
                    compact:   self,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: DIRECTION_NEGATIVE_X,
                );
                if (lower_x_span != NULL_SPAN && (span_regions[lower_x_span] & BORDER_REGION) == 0
                    && self.areas[index] == self.areas[lower_x_span]) {
                    run = span_regions[lower_x_span];
                }
                if (run == 0) {
                    run = next_run++;
                    sweeps[run].sample_count = 0;
                    sweeps[run].neighbour = 0;
                }

                uint lower_z_span = neighbour_index(
                    compact:   self,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: DIRECTION_NEGATIVE_Z,
                );
                if (lower_z_span != NULL_SPAN && span_regions[lower_z_span] != 0
                    && (span_regions[lower_z_span] & BORDER_REGION) == 0
                    && self.areas[index] == self.areas[lower_z_span]) {
                    ushort below = span_regions[lower_z_span];
                    SweepSpan* sweep = &sweeps[run];
                    if (sweep.neighbour == 0 || sweep.neighbour == below) {
                        sweep.neighbour = below;
                        sweep.sample_count++;
                        row_samples.items[below]++;
                    } else {
                        sweep.neighbour = NULL_NEIGHBOUR;
                    }
                }
                span_regions[index] = run;
            }
        }

        for (ushort run = 1; run < next_run; run++) {
            SweepSpan* sweep = &sweeps[run];
            if (sweep.neighbour != NULL_NEIGHBOUR && sweep.neighbour != 0
                && row_samples.items[sweep.neighbour] == (int)sweep.sample_count) {
                sweep.region = sweep.neighbour;
                continue;
            }
            if (next_id == BORDER_REGION) return c3d::CAPACITY_EXCEEDED~;
            sweep.region = next_id++;
        }

        for (int x = border; x < width - border; x++) {
            CompactCell cell = self.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                ushort run = span_regions[index];
                if (run > 0 && run < next_run) span_regions[index] = sweeps[run].region;
            }
        }
    }

    ushort max_regions = merge_and_filter_regions(
        compact:           self,
        scratch:           scratch,
        span_regions:      span_regions,
        max_region_id:     next_id,
        min_region_area:   min_region_area,
        merge_region_area: merge_region_area,
    )!;
    self.border_size = border_size;
    self.max_regions = max_regions;
    foreach (index, region : span_regions) self.spans[index].region = region;
}

fn void paint_rect_region(
    CompactHeightfield* compact,
    ushort[] span_regions,
    int min_x,
    int max_x,
    int min_z,
    int max_z,
    ushort region,
) @local {
    for (int z = min_z; z < max_z; z++) {
        for (int x = min_x; x < max_x; x++) {
            CompactCell cell = compact.cells[x + z * (int)compact.width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (compact.areas[index] != NULL_AREA) span_regions[index] = region;
            }
        }
    }
}

// Returns the compacted region count.
fn ushort? merge_and_filter_regions(
    CompactHeightfield* compact,
    Allocator scratch,
    ushort[] span_regions,
    ushort max_region_id,
    uint min_region_area,
    uint merge_region_area,
) @local {
    int width = (int)compact.width;
    int height = (int)compact.height;
    sz region_count = (sz)max_region_id + 1;

    RegionRecord[]? regions = alloc::new_array_try(scratch, RegionRecord, region_count);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, regions.ptr);
    defer {
        foreach (&region : regions) {
            destroy_int_list(&region.floors);
            destroy_int_list(&region.connections);
        }
    }
    foreach (region_id, &region : regions) {
        region.id = (ushort)region_id;
        region.connections = create_int_list(scratch, REGION_LIST_CAPACITY)!;
        region.floors = create_int_list(scratch, REGION_LIST_CAPACITY)!;
    }

    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = compact.cells[x + z * width];
            uint cell_end = cell.index + cell.count;
            for (uint index = cell.index; index < cell_end; index++) {
                ushort region_id = span_regions[index];
                if (region_id == 0 || region_id >= region_count) continue;
                RegionRecord* region = &regions[region_id];
                region.span_count++;

                for (uint other = cell.index; other < cell_end; other++) {
                    if (other == index) continue;
                    ushort floor_id = span_regions[other];
                    if (floor_id == 0 || floor_id >= region_count) continue;
                    if (floor_id == region_id) region.overlap = true;
                    add_unique_floor_region(region, floor_id)!;
                }

                if (region.connections.count > 0) continue;
                region.area = compact.areas[index];

                for (uint direction = 0; direction < 4; direction++) {
                    bool solid_edge = is_solid_edge(
                        compact:      compact,
                        span_regions: span_regions,
                        x:            x,
                        z:            z,
                        index:        index,
                        direction:    direction,
                    );
                    if (!solid_edge) continue;
                    walk_region_contour(
                        compact:      compact,
                        span_regions: span_regions,
                        x:            x,
                        z:            z,
                        index:        index,
                        direction:    direction,
                        neighbours:   &region.connections,
                    )!;
                    break;
                }
            }
        }
    }

    IntList stack = create_int_list(scratch, REGION_STACK_CAPACITY)!;
    defer destroy_int_list(&stack);
    IntList trace = create_int_list(scratch, REGION_STACK_CAPACITY)!;
    defer destroy_int_list(&trace);
    foreach (region_index, &region : regions) {
        if (region.id == 0 || (region.id & BORDER_REGION) != 0) continue;
        if (region.span_count == 0 || region.visited) continue;

        bool connects_to_border;
        int span_count;
        stack.clear();
        trace.clear();
        region.visited = true;
        stack.push((int)region_index)!;
        while (stack.count > 0) {
            int current_index = stack.pop();
            RegionRecord* current = &regions[current_index];
            span_count += current.span_count;
            trace.push(current_index)!;
            foreach (connection : current.connections.view()) {
                if ((connection & BORDER_REGION) != 0) {
                    connects_to_border = true;
                    continue;
                }
                RegionRecord* neighbour = &regions[connection];
                if (neighbour.visited) continue;
                if (neighbour.id == 0 || (neighbour.id & BORDER_REGION) != 0) continue;
                stack.push(neighbour.id)!;
                neighbour.visited = true;
            }
        }
        // A region touching the tile border may continue in the next tile, so its size is unknown.
        if (span_count < (int)min_region_area && !connects_to_border) {
            foreach (traced : trace.view()) {
                regions[traced].span_count = 0;
                regions[traced].id = 0;
            }
        }
    }

    IntList connections_copy = create_int_list(scratch, REGION_LIST_CAPACITY)!;
    defer destroy_int_list(&connections_copy);
    int merge_count;
    do {
        merge_count = 0;
        foreach (&region : regions) {
            if (region.id == 0 || (region.id & BORDER_REGION) != 0) continue;
            if (region.overlap || region.span_count == 0) continue;
            if (region.span_count > (int)merge_region_area && is_region_connected_to_border(region)) continue;

            int smallest = int::max;
            ushort merge_id = region.id;
            foreach (connection : region.connections.view()) {
                if ((connection & BORDER_REGION) != 0) continue;
                RegionRecord* candidate = &regions[connection];
                if (candidate.id == 0 || (candidate.id & BORDER_REGION) != 0 || candidate.overlap) continue;
                if (candidate.span_count < smallest && can_merge_with_region(region, candidate)
                    && can_merge_with_region(candidate, region)) {
                    smallest = candidate.span_count;
                    merge_id = candidate.id;
                }
            }
            if (merge_id == region.id) continue;

            ushort old_id = region.id;
            bool merged = merge_regions(&regions[merge_id], region, &connections_copy)!;
            if (!merged) continue;
            foreach (&other : regions) {
                if (other.id == 0 || (other.id & BORDER_REGION) != 0) continue;
                // Records merged into this region earlier follow it to the new id.
                if (other.id == old_id) other.id = merge_id;
                replace_neighbour(other, old_id, merge_id);
            }
            merge_count++;
        }
    } while (merge_count > 0);

    foreach (&region : regions) region.remap = region.id != 0 && (region.id & BORDER_REGION) == 0;
    ushort compacted_id;
    foreach (region_index, &region : regions) {
        if (!region.remap) continue;
        ushort old_id = region.id;
        ushort new_id = ++compacted_id;
        foreach (&later : regions[region_index..]) {
            if (later.id != old_id) continue;
            later.id = new_id;
            later.remap = false;
        }
    }

    foreach (&region_id : span_regions) {
        if ((*region_id & BORDER_REGION) == 0) *region_id = regions[*region_id].id;
    }
    return compacted_id;
}

fn ushort neighbour_region(
    CompactHeightfield* compact,
    ushort[] span_regions,
    int x,
    int z,
    uint index,
    uint direction,
) @local {
    uint neighbour = neighbour_index(
        compact:   compact,
        x:         x,
        z:         z,
        index:     index,
        direction: direction,
    );
    return neighbour != NULL_SPAN ? span_regions[neighbour] : 0;
}

fn bool is_solid_edge(
    CompactHeightfield* compact,
    ushort[] span_regions,
    int x,
    int z,
    uint index,
    uint direction,
) @local {
    ushort region = neighbour_region(
        compact:      compact,
        span_regions: span_regions,
        x:            x,
        z:            z,
        index:        index,
        direction:    direction,
    );
    return region != span_regions[index];
}

fn void? walk_region_contour(
    CompactHeightfield* compact,
    ushort[] span_regions,
    int x,
    int z,
    uint index,
    uint direction,
    IntList* neighbours,
) @local {
    uint start_direction = direction;
    uint start_index = index;
    ushort current_region = neighbour_region(
        compact:      compact,
        span_regions: span_regions,
        x:            x,
        z:            z,
        index:        index,
        direction:    direction,
    );
    neighbours.push(current_region)!;

    for (uint step = 1; step < MAX_CONTOUR_WALK; step++) {
        ushort region = neighbour_region(
            compact:      compact,
            span_regions: span_regions,
            x:            x,
            z:            z,
            index:        index,
            direction:    direction,
        );
        if (region != span_regions[index]) {
            if (region != current_region) {
                current_region = region;
                neighbours.push(current_region)!;
            }
            direction = (direction + 1) & 3;
        } else {
            uint neighbour = neighbour_index(
                compact:   compact,
                x:         x,
                z:         z,
                index:     index,
                direction: direction,
            );
            if (neighbour == NULL_SPAN) return;
            x += dir_offset_x(direction);
            z += dir_offset_z(direction);
            index = neighbour;
            direction = (direction + 3) & 3;
        }
        if (start_index == index && start_direction == direction) break;
    }

    if (neighbours.count > 1) remove_adjacent_duplicates(neighbours);
}

fn void remove_adjacent_duplicates(IntList* list) @local {
    for (sz index = 0; index < list.count && list.count > 1;) {
        sz next = (index + 1) % list.count;
        if (list.items[index] != list.items[next]) {
            index++;
            continue;
        }
        for (sz shifted = index; shifted < list.count - 1; shifted++) list.items[shifted] = list.items[shifted + 1];
        list.count--;
    }
}

fn void replace_neighbour(RegionRecord* region, ushort old_id, ushort new_id) @local {
    bool changed;
    foreach (&connection : region.connections.view()) {
        if (*connection != old_id) continue;
        *connection = new_id;
        changed = true;
    }
    foreach (&floor : region.floors.view()) {
        if (*floor == old_id) *floor = new_id;
    }
    if (changed) remove_adjacent_duplicates(&region.connections);
}

fn bool can_merge_with_region(RegionRecord* region, RegionRecord* other) @local {
    if (region.area != other.area) return false;
    int shared_edges;
    foreach (connection : region.connections.view()) {
        if (connection == other.id) shared_edges++;
    }
    if (shared_edges > 1) return false;
    foreach (floor : region.floors.view()) {
        if (floor == other.id) return false;
    }
    return true;
}

fn void? add_unique_floor_region(RegionRecord* region, int floor_id) @local {
    foreach (floor : region.floors.view()) {
        if (floor == floor_id) return;
    }
    region.floors.push(floor_id)!;
}

// Returns false when the two regions do not share an edge.
fn bool? merge_regions(RegionRecord* target, RegionRecord* source, IntList* target_copy) @local {
    target_copy.resize(target.connections.count)!;
    target_copy.view()[..] = target.connections.view()[..];
    int[] target_ring = target_copy.view();
    int[] source_ring = source.connections.view();

    sz? target_insert = array::index_of(target_ring, (int)source.id);
    if (catch target_insert) return false;
    sz? source_insert = array::index_of(source_ring, (int)target.id);
    if (catch source_insert) return false;

    target.connections.clear();
    for (sz offset = 0; offset < target_ring.len - 1; offset++) {
        target.connections.push(target_ring[(target_insert + 1 + offset) % target_ring.len])!;
    }
    for (sz offset = 0; offset < source_ring.len - 1; offset++) {
        target.connections.push(source_ring[(source_insert + 1 + offset) % source_ring.len])!;
    }
    remove_adjacent_duplicates(&target.connections);

    foreach (floor : source.floors.view()) add_unique_floor_region(target, floor)!;
    target.span_count += source.span_count;
    source.span_count = 0;
    source.connections.clear();
    return true;
}

fn bool is_region_connected_to_border(RegionRecord* region) @local {
    foreach (connection : region.connections.view()) {
        if (connection == 0) return true;
    }
    return false;
}
