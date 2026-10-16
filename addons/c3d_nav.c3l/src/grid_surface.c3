module c3d::nav;

import std::math;
import c3d;

<* Select a scalar height or four authored corner heights. *>
enum GridSurfaceKind : uint {
    FLAT,
    CORNERS,
}

<* Select the shared diagonal of an authored floor and ceiling. *>
enum GridDiagonal : uint {
    MIN_MIN_TO_MAX_MAX,
    MAX_MIN_TO_MIN_MAX,
}

fn void? validate_grid_floors(GridFloor[] floors, GridSourceDesc* source, DetailMode mode) @private {
    if (floors.len > MAX_GRID_FLOORS || (uint)mode > (uint)DetailMode.BOUNDED) return c3d::INVALID_ARGUMENT~;
    foreach (&floor : floors) {
        if ((uint)floor.floor_kind > (uint)GridSurfaceKind.CORNERS
            || (uint)floor.ceiling_kind > (uint)GridSurfaceKind.CORNERS
            || floor.area >= MAX_AREAS) return c3d::INVALID_ARGUMENT~;
        bool corners = floor.floor_kind == GridSurfaceKind.CORNERS
            || floor.ceiling_kind == GridSurfaceKind.CORNERS;
        if (corners && (mode != DetailMode.BOUNDED
            || (uint)floor.diagonal > (uint)GridDiagonal.MAX_MIN_TO_MIN_MAX)) return c3d::INVALID_ARGUMENT~;

        switch (floor.floor_kind) {
            case FLAT:
                if (!valid_grid_height(floor.height, source)) return c3d::INVALID_ARGUMENT~;
            case CORNERS:
                foreach (height : floor.floor_corners) {
                    if (!valid_grid_height(height, source)) return c3d::INVALID_ARGUMENT~;
                }
        }
        switch (floor.ceiling_kind) {
            case FLAT:
                if (floor.ceiling != float::max && !valid_grid_height(floor.ceiling, source)) {
                    return c3d::INVALID_ARGUMENT~;
                }
            case CORNERS:
                foreach (height : floor.ceiling_corners) {
                    if (!valid_grid_height(height, source)) return c3d::INVALID_ARGUMENT~;
                }
        }
    }

    foreach (ordinal, &floor : floors) {
        bool ceiling_below_next;
        bool ceiling_above_next;
        for (uint point = 0; point <= DETAIL_CORNER_X.len; point++) {
            double cell_x = point < DETAIL_CORNER_X.len ? (double)DETAIL_CORNER_X[point] : 0.5;
            double cell_z = point < DETAIL_CORNER_Z.len ? (double)DETAIL_CORNER_Z[point] : 0.5;
            double height = grid_floor_height(floor, cell_x, cell_z);
            double ceiling = grid_ceiling_height(floor, cell_x, cell_z);
            if (ceiling < height) return c3d::INVALID_ARGUMENT~;
            if (ordinal + 1 == floors.len) continue;

            double next_height = grid_floor_height(&floors[ordinal + 1], cell_x, cell_z);
            if (height >= next_height) return c3d::INVALID_ARGUMENT~;
            ceiling_below_next |= ceiling < next_height;
            ceiling_above_next |= ceiling > next_height;
        }
        if (ceiling_below_next && ceiling_above_next) return c3d::INVALID_ARGUMENT~;
    }
}

fn double grid_floor_height(GridFloor* floor, double cell_x, double cell_z) @private {
    if (floor.floor_kind == GridSurfaceKind.FLAT) return floor.height;
    return grid_corner_height(
        corners: floor.floor_corners,
        diagonal: floor.diagonal,
        cell_x: cell_x,
        cell_z: cell_z,
    );
}

fn double grid_ceiling_height(GridFloor* floor, double cell_x, double cell_z) @private {
    if (floor.ceiling_kind == GridSurfaceKind.FLAT) return floor.ceiling;
    return grid_corner_height(
        corners: floor.ceiling_corners,
        diagonal: floor.diagonal,
        cell_x: cell_x,
        cell_z: cell_z,
    );
}

fn double grid_effective_ceiling(
    GridFloor[] floors,
    usz ordinal,
    double cell_x,
    double cell_z,
) @private {
    double ceiling = grid_ceiling_height(&floors[ordinal], cell_x, cell_z);
    if (ordinal + 1 == floors.len) return ceiling;
    return math::min(ceiling, grid_floor_height(&floors[ordinal + 1], cell_x, cell_z));
}

fn uint[3] grid_triangle_corners(GridDiagonal diagonal, uint triangle) @private {
    switch (diagonal) {
        case MIN_MIN_TO_MAX_MAX:
            if (triangle == 0) return { 0, 2, 1 };
            return { 0, 3, 2 };
        case MAX_MIN_TO_MIN_MAX:
            if (triangle == 0) return { 0, 3, 1 };
            return { 1, 3, 2 };
    }
}

fn bool valid_grid_height(float height, GridSourceDesc* source) @local {
    return math::is_finite(height) && height >= source.min_height && height <= source.max_height;
}

fn double grid_corner_height(
    float[4] corners,
    GridDiagonal diagonal,
    double cell_x,
    double cell_z,
) @local {
    switch (diagonal) {
        case MIN_MIN_TO_MAX_MAX:
            if (cell_x >= cell_z) {
                return corners[0] * (1 - cell_x) + corners[1] * (cell_x - cell_z) + corners[2] * cell_z;
            }
            return corners[0] * (1 - cell_z) + corners[2] * cell_x + corners[3] * (cell_z - cell_x);
        case MAX_MIN_TO_MIN_MAX:
            double diagonal_position = cell_x + cell_z;
            if (diagonal_position <= 1) {
                return corners[0] * (1 - diagonal_position) + corners[1] * cell_x + corners[3] * cell_z;
            }
            return corners[1] * (1 - cell_z) + corners[2] * (diagonal_position - 1) + corners[3] * (1 - cell_x);
    }
}
