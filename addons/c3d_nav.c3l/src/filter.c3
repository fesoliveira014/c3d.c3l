module c3d::nav;

import std::math;

const int OPEN_COLUMN_TOP @local = 0xffff; // mirrors RecastFilter's MAX_HEIGHTFIELD_HEIGHT: the ceiling of a column with nothing above

<*
 Mark unwalkable spans walkable when their top is within walkable_climb of the walkable span below; mirrors rcFilterLowHangingWalkableObstacles.
 Undoes filter_ledge_spans, so it runs first.
*>
fn void Heightfield.filter_low_hanging_walkable_obstacles(&self, uint walkable_climb) {
    Span[] spans = self.pool.spans;
    foreach (head : self.columns) {
        uint previous = NULL_SPAN;
        bool previous_walkable;
        uint previous_area = NULL_AREA;
        for (uint index = head; index != NULL_SPAN; index = spans[index].next) {
            bool walkable = spans[index].extent.area != NULL_AREA;
            if (!walkable && previous_walkable
                && (int)spans[index].extent.max - (int)spans[previous].extent.max <= (int)walkable_climb) {
                spans[index].extent.area = previous_area;
            }
            // The original walkability, so stacked low obstacles do not chain.
            previous_walkable = walkable;
            previous_area = spans[index].extent.area;
            previous = index;
        }
    }
}

<*
 Mark spans beside a drop deeper than walkable_climb unwalkable; mirrors rcFilterLedgeSpans.
 @require walkable_height >= 3
*>
fn void Heightfield.filter_ledge_spans(&self, uint walkable_height, uint walkable_climb) {
    Span[] spans = self.pool.spans;
    int width = (int)self.width;
    int height = (int)self.height;
    int clearance = (int)walkable_height;
    int climb = (int)walkable_climb;
    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            for (uint index = self.columns[x + z * width]; index != NULL_SPAN; index = spans[index].next) {
                if (spans[index].extent.area == NULL_AREA) continue;
                int floor = (int)spans[index].extent.max;
                int ceiling = column_ceiling(spans, spans[index].next);
                int lowest_drop = OPEN_COLUMN_TOP;
                int lowest_traversable_floor = floor;
                int highest_traversable_floor = floor;
                for (uint direction = 0; direction < 4; direction++) {
                    int neighbour_x = x + dir_offset_x(direction);
                    int neighbour_z = z + dir_offset_z(direction);
                    if (neighbour_x < 0 || neighbour_z < 0 || neighbour_x >= width || neighbour_z >= height) {
                        lowest_drop = -climb - 1;
                        break;
                    }
                    uint neighbour = self.columns[neighbour_x + neighbour_z * width];
                    // Open space under the neighbour's lowest span is a drop to the bottom of the field.
                    if (math::min(ceiling, column_ceiling(spans, neighbour)) - floor >= clearance) {
                        lowest_drop = -climb - 1;
                        break;
                    }
                    for (; neighbour != NULL_SPAN; neighbour = spans[neighbour].next) {
                        int neighbour_floor = (int)spans[neighbour].extent.max;
                        int neighbour_ceiling = column_ceiling(spans, spans[neighbour].next);
                        if (math::min(ceiling, neighbour_ceiling) - math::max(floor, neighbour_floor) < clearance) continue;

                        int drop = neighbour_floor - floor;
                        lowest_drop = math::min(lowest_drop, drop);
                        if (math::abs(drop) <= climb) {
                            lowest_traversable_floor = math::min(lowest_traversable_floor, neighbour_floor);
                            highest_traversable_floor = math::max(highest_traversable_floor, neighbour_floor);
                        } else if (drop < -climb) {
                            break;
                        }
                    }
                }
                if (lowest_drop < -climb || highest_traversable_floor - lowest_traversable_floor > climb) {
                    spans[index].extent.area = NULL_AREA;
                }
            }
        }
    }
}

<*
 Mark walkable spans with less than walkable_height of clearance unwalkable; mirrors rcFilterWalkableLowHeightSpans.
 @require walkable_height >= 3
*>
fn void Heightfield.filter_walkable_low_height_spans(&self, uint walkable_height) {
    Span[] spans = self.pool.spans;
    foreach (head : self.columns) {
        for (uint index = head; index != NULL_SPAN; index = spans[index].next) {
            int floor = (int)spans[index].extent.max;
            if (column_ceiling(spans, spans[index].next) - floor < (int)walkable_height) spans[index].extent.area = NULL_AREA;
        }
    }
}

fn int column_ceiling(Span[] spans, uint above) @local {
    return above != NULL_SPAN ? (int)spans[above].extent.min : OPEN_COLUMN_TOP;
}
