module c3d::nav;

import std::math;
import c3d;
import c3d::maths;

<* Largest erosion radius, in voxels. *>
const uint MAX_EROSION_RADIUS = 127; // twice the radius must fit the byte distance field

const char  UNREACHED @local = 0xff; // distance of a span no boundary has reached yet
const uint  NEIGHBOURHOOD @local = 9; // a span and its eight neighbours
const float MITER_LIMIT @local = 1.20f; // mirrors rcOffsetPoly; sharper corners bevel instead of mitring
const float NORMALIZE_EPSILON @local = 1e-6f; // mirrors rcOffsetPoly's EPSILON; shorter directions stay unnormalised
const int   STRAIGHT_STEP_COST @local = 2; // chamfer distance: a straight step costs 2, a diagonal 3, about 1 : sqrt(2)
const int   DIAGONAL_STEP_COST @local = 3;
const int   MAX_DISTANCE @local = 255; // the distance field is one byte

struct CellRange @local {
    int min_x;
    int max_x;
    int min_y;
    int max_y;
    int min_z;
    int max_z;
}

<*
 Erode the walkable area away from obstructions and edges by the radius; mirrors rcErodeWalkableArea.
 @param scratch : "Holds span_count bytes for the call."
 @param radius : "Voxels."
 @return? c3d::CAPACITY_EXCEEDED
 @require radius > 0, radius <= MAX_EROSION_RADIUS
*>
fn void? CompactHeightfield.erode_walkable_area(&self, Allocator scratch, uint radius) {
    char[]? allocated = alloc::new_array_try(scratch, char, self.span_count);
    if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
    char[] distances = allocated;
    defer alloc::free(scratch, distances.ptr);
    distances[..] = UNREACHED;

    int width = (int)self.width;
    int height = (int)self.height;
    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = self.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (self.areas[index] == NULL_AREA) {
                    distances[index] = 0;
                    continue;
                }
                uint walkable_neighbours;
                for (uint direction = 0; direction < 4; direction++) {
                    uint neighbour = neighbour_index(self, x, z, index, direction);
                    if (neighbour == NULL_SPAN || self.areas[neighbour] == NULL_AREA) break;
                    walkable_neighbours++;
                }
                if (walkable_neighbours != 4) distances[index] = 0;
            }
        }
    }

    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = self.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                relax_distance(
                    compact:   self,
                    distances: distances,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: 0,
                    turn:      3,
                );
                relax_distance(
                    compact:   self,
                    distances: distances,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: 3,
                    turn:      2,
                );
            }
        }
    }
    for (int z = height - 1; z >= 0; z--) {
        for (int x = width - 1; x >= 0; x--) {
            CompactCell cell = self.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                relax_distance(
                    compact:   self,
                    distances: distances,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: 2,
                    turn:      1,
                );
                relax_distance(
                    compact:   self,
                    distances: distances,
                    x:         x,
                    z:         z,
                    index:     index,
                    direction: 1,
                    turn:      0,
                );
            }
        }
    }

    char threshold = (char)(radius * 2);
    foreach (index, distance : distances) {
        if (distance < threshold) self.areas[index] = NULL_AREA;
    }
}

<*
 Replace each walkable span's area with the median of its neighbourhood; mirrors rcMedianFilterWalkableArea.
 @param scratch : "Holds span_count bytes for the call."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? CompactHeightfield.median_filter_walkable_area(&self, Allocator scratch) {
    char[]? allocated = alloc::new_array_try(scratch, char, self.span_count);
    if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
    char[] medians = allocated;
    defer alloc::free(scratch, medians.ptr);
    medians[..] = UNREACHED;

    int width = (int)self.width;
    int height = (int)self.height;
    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = self.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (self.areas[index] == NULL_AREA) {
                    medians[index] = NULL_AREA;
                    continue;
                }
                char[NEIGHBOURHOOD] neighbourhood;
                neighbourhood[..] = self.areas[index];
                for (uint direction = 0; direction < 4; direction++) {
                    uint neighbour = neighbour_index(self, x, z, index, direction);
                    if (neighbour == NULL_SPAN) continue;
                    if (self.areas[neighbour] != NULL_AREA) neighbourhood[direction * 2] = self.areas[neighbour];

                    uint turned = (direction + 1) & 3;
                    uint diagonal = neighbour_index(
                        compact:   self,
                        x:         x + dir_offset_x(direction),
                        z:         z + dir_offset_z(direction),
                        index:     neighbour,
                        direction: turned,
                    );
                    if (diagonal != NULL_SPAN && self.areas[diagonal] != NULL_AREA) {
                        neighbourhood[direction * 2 + 1] = self.areas[diagonal];
                    }
                }
                insert_sort(neighbourhood[..]);
                medians[index] = neighbourhood[4];
            }
        }
    }
    self.areas[..] = medians[..];
}

<*
 Set the area of every walkable span whose floor lies inside the box; mirrors rcMarkBoxArea.
 @param box : "World space."
 @require area <= WALKABLE_AREA
*>
fn void CompactHeightfield.mark_box_area(&self, Aabb box, char area) {
    CellRange range;
    if (!cell_range(self, box, &range)) return;
    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) {
            CompactCell cell = self.cells[x + z * (int)self.width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (!holds_floor(&range, self.spans[index].y) || self.areas[index] == NULL_AREA) continue;
                self.areas[index] = area;
            }
        }
    }
}

<*
 Set the area of every walkable span inside the polygon extruded between the heights; mirrors rcMarkConvexPolyArea.
 @param vertices : "World space; Y is ignored."
 @require vertices.len >= 3, area <= WALKABLE_AREA
*>
fn void CompactHeightfield.mark_convex_poly_area(
    &self,
    Vec3[] vertices,
    float min_y,
    float max_y,
    char area,
) {
    Aabb bounds = { .min = vertices[0], .max = vertices[0] };
    foreach (vertex : vertices[1..]) {
        bounds.min = math::min(bounds.min, vertex);
        bounds.max = math::max(bounds.max, vertex);
    }
    bounds.min.y = min_y;
    bounds.max.y = max_y;
    CellRange range;
    if (!cell_range(self, bounds, &range)) return;

    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) {
            CompactCell cell = self.cells[x + z * (int)self.width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (self.areas[index] == NULL_AREA || !holds_floor(&range, self.spans[index].y)) continue;
                Vec3 centre = cell_centre(self, x, z);
                if (point_in_poly(vertices, centre)) self.areas[index] = area;
            }
        }
    }
}

<*
 Set the area of every walkable span inside the upright cylinder; mirrors rcMarkCylinderArea.
 @param base : "Centre of the bottom disc."
 @require radius > 0, height > 0, area <= WALKABLE_AREA
*>
fn void CompactHeightfield.mark_cylinder_area(
    &self,
    Vec3 base,
    float radius,
    float height,
    char area,
) {
    Aabb bounds = {
        .min = { base.x - radius, base.y, base.z - radius },
        .max = { base.x + radius, base.y + height, base.z + radius },
    };
    CellRange range;
    if (!cell_range(self, bounds, &range)) return;

    float radius_sq = radius * radius;
    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) {
            Vec3 centre = cell_centre(self, x, z);
            float delta_x = centre.x - base.x;
            float delta_z = centre.z - base.z;
            if (delta_x * delta_x + delta_z * delta_z >= radius_sq) continue;

            CompactCell cell = self.cells[x + z * (int)self.width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (self.areas[index] == NULL_AREA) continue;
                if (holds_floor(&range, self.spans[index].y)) self.areas[index] = area;
            }
        }
    }
}

<*
 Grow a convex polygon by the offset in XZ, bevelling sharp corners; mirrors rcOffsetPoly.
 Vertices wound clockwise seen from above move outward; the opposite winding moves them inward.
 @param [out] out_vertices : "Up to 2 * vertices.len entries."
 @return "How many vertices were written; 0 when out_vertices is too small."
 @require vertices.len >= 3
*>
fn usz offset_poly(Vec3[] vertices, float offset, Vec3[] out_vertices) {
    usz count;
    usz vertex_count = vertices.len;
    for (usz index = 0; index < vertex_count; index++) {
        Vec3 previous_vertex = vertices[(index + vertex_count - 1) % vertex_count];
        Vec3 vertex = vertices[index];
        Vec3 next_vertex = vertices[(index + 1) % vertex_count];

        Vec3 previous_direction = safe_normalize({ vertex.x - previous_vertex.x, 0, vertex.z - previous_vertex.z });
        Vec3 current_direction = safe_normalize({ next_vertex.x - vertex.x, 0, next_vertex.z - vertex.z });
        float cross = current_direction.x * previous_direction.z - previous_direction.x * current_direction.z;

        float previous_normal_x = -previous_direction.z;
        float previous_normal_z = previous_direction.x;
        float current_normal_x = -current_direction.z;
        float current_normal_z = current_direction.x;

        float miter_x = (previous_normal_x + current_normal_x) * 0.5f;
        float miter_z = (previous_normal_z + current_normal_z) * 0.5f;
        float miter_sq = miter_x * miter_x + miter_z * miter_z;
        bool bevel = miter_sq * MITER_LIMIT * MITER_LIMIT < 1.0f;
        if (miter_sq > NORMALIZE_EPSILON) {
            float scale = 1.0f / miter_sq;
            miter_x *= scale;
            miter_z *= scale;
        }

        if (bevel && cross < 0.0f) {
            if (count + 2 > out_vertices.len) return 0;
            float along = (1.0f - (previous_direction.x * current_direction.x + previous_direction.z * current_direction.z)) * 0.5f;
            out_vertices[count++] = {
                vertex.x + (-previous_normal_x + previous_direction.x * along) * offset,
                vertex.y,
                vertex.z + (-previous_normal_z + previous_direction.z * along) * offset,
            };
            out_vertices[count++] = {
                vertex.x + (-current_normal_x - current_direction.x * along) * offset,
                vertex.y,
                vertex.z + (-current_normal_z - current_direction.z * along) * offset,
            };
            continue;
        }
        if (count + 1 > out_vertices.len) return 0;
        out_vertices[count++] = { vertex.x - miter_x * offset, vertex.y, vertex.z - miter_z * offset };
    }
    return count;
}

fn bool holds_floor(CellRange* range, ushort floor) @local => (int)floor >= range.min_y && (int)floor <= range.max_y;

// Truncating casts, not floor, as upstream; only X and Z are clamped.
fn bool cell_range(CompactHeightfield* compact, Aabb bounds, CellRange* range) @local {
    Vec3 origin = compact.bounds.min;
    *range = {
        .min_x = (int)((bounds.min.x - origin.x) / compact.cell_size),
        .min_y = (int)((bounds.min.y - origin.y) / compact.cell_height),
        .min_z = (int)((bounds.min.z - origin.z) / compact.cell_size),
        .max_x = (int)((bounds.max.x - origin.x) / compact.cell_size),
        .max_y = (int)((bounds.max.y - origin.y) / compact.cell_height),
        .max_z = (int)((bounds.max.z - origin.z) / compact.cell_size),
    };
    int width = (int)compact.width;
    int height = (int)compact.height;
    if (range.max_x < 0 || range.min_x >= width || range.max_z < 0 || range.min_z >= height) return false;
    range.min_x = math::max(range.min_x, 0);
    range.max_x = math::min(range.max_x, width - 1);
    range.min_z = math::max(range.min_z, 0);
    range.max_z = math::min(range.max_z, height - 1);
    return true;
}

fn Vec3 cell_centre(CompactHeightfield* compact, int x, int z) @local {
    return {
        compact.bounds.min.x + ((float)x + 0.5f) * compact.cell_size,
        0,
        compact.bounds.min.z + ((float)z + 0.5f) * compact.cell_size,
    };
}

fn uint neighbour_index(
    CompactHeightfield* compact,
    int x,
    int z,
    uint index,
    uint direction,
) @local {
    uint layer = compact.spans[index].connection(direction);
    if (layer == NOT_CONNECTED) return NULL_SPAN;
    int neighbour_x = x + dir_offset_x(direction);
    int neighbour_z = z + dir_offset_z(direction);
    return compact.cells[neighbour_x + neighbour_z * (int)compact.width].index + layer;
}

fn void relax_distance(
    CompactHeightfield* compact,
    char[] distances,
    int x,
    int z,
    uint index,
    uint direction,
    uint turn,
) @local {
    uint neighbour = neighbour_index(compact, x, z, index, direction);
    if (neighbour == NULL_SPAN) return;
    distances[index] = math::min(distances[index], (char)math::min((int)distances[neighbour] + STRAIGHT_STEP_COST, MAX_DISTANCE));

    uint diagonal = neighbour_index(
        compact:   compact,
        x:         x + dir_offset_x(direction),
        z:         z + dir_offset_z(direction),
        index:     neighbour,
        direction: turn,
    );
    if (diagonal == NULL_SPAN) return;
    distances[index] = math::min(distances[index], (char)math::min((int)distances[diagonal] + DIAGONAL_STEP_COST, MAX_DISTANCE));
}

fn void insert_sort(char[] values) @local {
    for (usz sorted = 1; sorted < values.len; sorted++) {
        char value = values[sorted];
        usz slot = sorted;
        while (slot > 0 && values[slot - 1] > value) {
            values[slot] = values[slot - 1];
            slot--;
        }
        values[slot] = value;
    }
}

fn bool point_in_poly(Vec3[] vertices, Vec3 point) @local {
    bool inside;
    usz previous = vertices.len - 1;
    for (usz current = 0; current < vertices.len; previous = current++) {
        Vec3 a = vertices[current];
        Vec3 b = vertices[previous];
        if ((a.z > point.z) == (b.z > point.z)) continue;
        if (point.x >= (b.x - a.x) * (point.z - a.z) / (b.z - a.z) + a.x) continue;
        inside = !inside;
    }
    return inside;
}

fn Vec3 safe_normalize(Vec3 vector) @local {
    float length_sq = vector.x * vector.x + vector.y * vector.y + vector.z * vector.z;
    if (length_sq <= NORMALIZE_EPSILON) return vector;
    return vector * (1.0f / math::sqrt(length_sq));
}
