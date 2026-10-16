module c3d::nav;

import std::math;
import c3d;

fn char[]? build_sub_cell_grid(GridTileBuilder* builder, int tile_x, int tile_z) @private {
    GridReference captured = capture_grid_reference(builder, tile_x, tile_z)!;
    if (!captured.span_count) return {};

    Allocator allocator = &builder.arena;
    CompactCell[]? columns = alloc::new_array_try(allocator, CompactCell, (sz)captured.columns.len);
    if (catch columns) return c3d::CAPACITY_EXCEEDED~;
    ClearanceSurface[]? surfaces = alloc::new_array_try(allocator, ClearanceSurface, captured.span_count);
    if (catch surfaces) return c3d::CAPACITY_EXCEEDED~;

    long first_x = (long)tile_x * builder.config.tile_size;
    long first_z = (long)tile_z * builder.config.tile_size;
    double pitch = builder.config.cell_size;
    Vec3 origin = {
        (float)((double)builder.source.origin.x + (double)first_x * pitch),
        0,
        (float)((double)builder.source.origin.z + (double)first_z * pitch),
    };
    Aabb bounds = {
        .min = { origin.x, builder.source.min_height, origin.z },
        .max = {
            (float)((double)builder.source.origin.x + (double)(first_x + builder.config.tile_size) * pitch),
            builder.source.max_height,
            (float)((double)builder.source.origin.z + (double)(first_z + builder.config.tile_size) * pitch),
        },
    };
    if (!detail_finite_vertex(origin) || !detail_finite_vertex(bounds.max)) return c3d::CAPACITY_EXCEEDED~;
    if (bounds.max.x <= bounds.min.x || bounds.max.z <= bounds.min.z) return c3d::CAPACITY_EXCEEDED~;

    // Sampling keeps the authored basis despite rounding the local origin.
    ClearanceSource source = {
        .columns = columns,
        .surfaces = surfaces,
        .width = captured.width,
        .height = captured.height,
        .border_size = captured.border_size,
        .origin = origin,
        .basis = { builder.source.origin.x, builder.source.origin.z },
        .first_x = captured.first_x,
        .first_z = captured.first_z,
        .cell_size = builder.config.cell_size,
        .bounds = bounds,
        .center_on_diagonal = true,
    };

    foreach (column_index, column : captured.columns) {
        source.columns[column_index] = { .index = column.span_base, .count = (uint)column.floors.len };
        foreach (ordinal, &floor : column.floors) {
            ClearanceSurface* surface = &source.surfaces[column.span_base + ordinal];
            surface.column = (uint)column_index;
            surface.ordinal = (ushort)ordinal;
            surface.area = floor.area;
            surface.ceiling_open = floor.ceiling_kind == GridSurfaceKind.FLAT && floor.ceiling == float::max
                && ordinal + 1 == column.floors.len;

            for (uint point = 0; point <= DETAIL_CORNER_X.len; point++) {
                double cell_x = point < DETAIL_CORNER_X.len ? (double)DETAIL_CORNER_X[point] : 0.5;
                double cell_z = point < DETAIL_CORNER_Z.len ? (double)DETAIL_CORNER_Z[point] : 0.5;
                surface.heights[point] = grid_floor_height(floor, cell_x, cell_z);
                surface.ceilings[point] = grid_effective_ceiling(
                    floors: column.floors,
                    ordinal: (usz)ordinal,
                    cell_x: cell_x,
                    cell_z: cell_z,
                );
            }
        }
    }

    return build_clearance_mesh(
        allocator: allocator,
        source: &source,
        config: &builder.tile_config,
        tile_x: tile_x,
        tile_z: tile_z,
    );
}
