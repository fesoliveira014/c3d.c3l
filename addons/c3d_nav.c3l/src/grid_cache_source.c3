module c3d::nav;

import std::math;
import c3d;

const uint GRID_LAYER_MASK @local = (1u << MAX_GRID_FLOORS) - 1;

struct CachedGridHeader @private {
    ulong source_id;
    ulong source_revision;
    Vec3 origin;
    float min_height;
    float max_height;
    NavBuildConfig config;
    uint width;
    uint height;
    uint border_size;
    uint floor_count;
    int first_x;
    int first_z;
    uint floor_mask;
}

$assert CachedGridHeader::size == 136;
$assert GridFloor::size == 56;
$assert CompactCell::size == 4;

struct CachedGridReference @private {
    CachedGridHeader* header;
    CompactCell[] columns;
    GridFloor[] floors;
}

fn CachedGridReference? cached_grid_reference(char[] blob) @private {
    if (blob.len < LayerHeader::size || (uptr)blob.ptr % CachedGridHeader::alignment) return LAYER_CORRUPTED~;
    LayerHeader* layer = (LayerHeader*)blob.ptr;
    if (layer.magic != LAYER_MAGIC || layer.version != LAYER_VERSION || layer.source_kind != CachedSourceKind.GRID) {
        return LAYER_CORRUPTED~;
    }

    usz offset = detail_reference_offset(LayerHeader::size + (usz)layer.width * layer.height * 3);
    if (offset > blob.len || layer.reference_bytes != blob.len - offset) return LAYER_CORRUPTED~;
    if (layer.reference_bytes < CachedGridHeader::size) return LAYER_CORRUPTED~;

    CachedGridHeader* header = (CachedGridHeader*)(blob.ptr + offset);
    offset += CachedGridHeader::size;
    if (!header.source_id || !header.floor_mask || (header.floor_mask & ~GRID_LAYER_MASK)) return LAYER_CORRUPTED~;
    if (!detail_finite_vertex(header.origin) || !math::is_finite(header.min_height)
        || !math::is_finite(header.max_height) || header.min_height >= header.max_height) return LAYER_CORRUPTED~;

    TileConfig? config = tile_config(header.config);
    if (catch config) return LAYER_CORRUPTED~;
    if (header.width != config.width || header.height != config.height || header.border_size != config.border_size
        || layer.width != header.config.tile_size || layer.height != header.config.tile_size
        || layer.detail_mode != header.config.detail_mode) return LAYER_CORRUPTED~;
    long first_x = (long)layer.tile_x * header.config.tile_size - header.border_size;
    long first_z = (long)layer.tile_z * header.config.tile_size - header.border_size;
    if (first_x != header.first_x || first_z != header.first_z) return LAYER_CORRUPTED~;

    ulong column_count = (ulong)header.width * header.height;
    ulong columns_bytes = column_count * CompactCell::size;
    ulong floor_bytes = (ulong)header.floor_count * GridFloor::size;
    if (columns_bytes > blob.len - offset || floor_bytes != blob.len - offset - columns_bytes) return LAYER_CORRUPTED~;

    CompactCell[] columns = ((CompactCell*)(blob.ptr + offset))[:(usz)column_count];
    offset += (usz)columns_bytes;
    GridFloor[] floors = ((GridFloor*)(blob.ptr + offset))[:header.floor_count];
    GridSourceDesc source = {
        .origin = header.origin,
        .min_height = header.min_height,
        .max_height = header.max_height,
    };

    uint count;
    foreach (column : columns) {
        if (column.index != count || column.count > MAX_GRID_FLOORS || column.count > floors.len - count) {
            return LAYER_CORRUPTED~;
        }
        if (catch excuse = validate_grid_floors(floors[count:column.count], &source, header.config.detail_mode)) {
            return LAYER_CORRUPTED~;
        }
        count += column.count;
    }
    if (count != header.floor_count) return LAYER_CORRUPTED~;

    return { .header = header, .columns = columns, .floors = floors };
}

fn GridReference? unpack_grid_reference(Allocator allocator, CachedGridReference cached) @local {
    GridColumn[]? columns = alloc::new_array_try(allocator, GridColumn, (sz)cached.columns.len);
    if (catch columns) return c3d::CAPACITY_EXCEEDED~;

    foreach (index, column : cached.columns) {
        columns[index] = { .floors = cached.floors[column.index:column.count], .span_base = column.index };
    }

    CachedGridHeader* header = cached.header;
    return {
        .columns = columns,
        .width = header.width,
        .height = header.height,
        .border_size = header.border_size,
        .span_count = header.floor_count,
        .first_x = header.first_x,
        .first_z = header.first_z,
    };
}

fn uint? grid_cache_layer_masks(
    GridTileBuilder* builder,
    GridReference* reference,
    int tile_x,
    int tile_z,
    uint[] output,
) @private {
    if (builder.config.detail_mode == DetailMode.COARSE) {
        foreach (index, column : reference.columns) {
            if (!grid_core_column(reference, (uint)index)) continue;
            foreach (floor : column.floors) {
                if (floor.area == NULL_AREA) continue;
                if (!output.len) return c3d::CAPACITY_EXCEEDED~;
                output[0] = GRID_LAYER_MASK;
                return 1;
            }
        }
        return 0;
    }

    ClearanceSource source = clearance_grid_source(
        builder: builder,
        captured: reference,
        tile_x: tile_x,
        tile_z: tile_z,
    )!;
    ClearanceConnection[] connections = clearance_connections(&builder.arena, &source, &builder.tile_config)!;
    uint[MAX_GRID_FLOORS] roots;
    for (uint index = 0; index < MAX_GRID_FLOORS; index++) roots[index] = index;
    foreach (connection : connections) {
        foreach (match : connection.matches) {
            uint first = grid_layer_root(roots[..], match.first);
            uint second = grid_layer_root(roots[..], match.second);
            roots[math::max(first, second)] = math::min(first, second);
        }
    }

    uint present;
    foreach (index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)index)) continue;
        foreach (ordinal, floor : column.floors) {
            if (floor.area != NULL_AREA) present |= 1u << grid_layer_root(roots[..], (uint)ordinal);
        }
    }

    uint count;
    for (uint root = 0; root < MAX_GRID_FLOORS; root++) {
        if (!(present & (1u << root))) continue;
        if (count == output.len) return c3d::CAPACITY_EXCEEDED~;
        uint mask;
        for (uint ordinal = 0; ordinal < MAX_GRID_FLOORS; ordinal++) {
            if (grid_layer_root(roots[..], ordinal) == root) mask |= 1u << ordinal;
        }
        output[count++] = mask;
    }

    return count;
}

fn char[]? pack_grid_cache_layer(
    GridTileBuilder* builder,
    GridReference* reference,
    ulong source_id,
    ulong source_revision,
    int tile_x,
    int tile_z,
    uint layer,
    uint floor_mask,
) @private {
    uint size = builder.config.tile_size;
    usz cells = (usz)size * size;
    usz offset = detail_reference_offset(LayerHeader::size + cells * 3);
    ulong bytes = (ulong)offset + CachedGridHeader::size
        + (ulong)reference.columns.len * CompactCell::size + (ulong)reference.span_count * GridFloor::size;
    if (bytes > sz::max || bytes > uint::max) return c3d::CAPACITY_EXCEEDED~;

    char[]? storage = alloc::new_array_try(&builder.arena, char, (sz)bytes);
    if (catch storage) return c3d::CAPACITY_EXCEEDED~;
    char[] blob = storage;

    LayerHeader* header = (LayerHeader*)blob.ptr;
    *header = {
        .magic = LAYER_MAGIC,
        .version = LAYER_VERSION,
        .tile_x = tile_x,
        .tile_z = tile_z,
        .tile_layer = (int)layer,
        .bounds = builder.tile_bounds(tile_x, tile_z),
        .width = (char)size,
        .height = (char)size,
        .min_x = (char)(size - 1),
        .min_z = (char)(size - 1),
        .source_kind = CachedSourceKind.GRID,
        .detail_mode = builder.config.detail_mode,
        .reference_bytes = (uint)(bytes - offset),
    };
    header.bounds.min.y = float::max;
    header.bounds.max.y = -float::max;
    blob[LayerHeader::size:cells] = 0xff;

    foreach (index, column : reference.columns) {
        if (!grid_core_column(reference, (uint)index)) continue;
        uint x = (uint)index % reference.width - reference.border_size;
        uint z = (uint)index / reference.width - reference.border_size;
        foreach (ordinal, &floor : column.floors) {
            if (!(floor_mask & (1u << ordinal)) || floor.area == NULL_AREA) continue;
            usz cell = (usz)(x + z * size);
            blob[LayerHeader::size + cell] = 0;
            blob[LayerHeader::size + cells + cell] = floor.area;
            header.min_x = (char)math::min((uint)header.min_x, x);
            header.max_x = (char)math::max((uint)header.max_x, x);
            header.min_z = (char)math::min((uint)header.min_z, z);
            header.max_z = (char)math::max((uint)header.max_z, z);
            for (uint corner = 0; corner < 4; corner++) {
                float height = floor.floor_kind == GridSurfaceKind.FLAT ? floor.height : floor.floor_corners[corner];
                header.bounds.min.y = math::min(header.bounds.min.y, height);
                header.bounds.max.y = math::max(header.bounds.max.y, height);
            }
        }
    }

    CachedGridHeader* cached = (CachedGridHeader*)(blob.ptr + offset);
    *cached = {
        .source_id = source_id,
        .source_revision = source_revision,
        .origin = builder.source.origin,
        .min_height = builder.source.min_height,
        .max_height = builder.source.max_height,
        .config = builder.config,
        .width = reference.width,
        .height = reference.height,
        .border_size = reference.border_size,
        .floor_count = reference.span_count,
        .first_x = reference.first_x,
        .first_z = reference.first_z,
        .floor_mask = floor_mask,
    };
    offset += CachedGridHeader::size;

    CompactCell[] columns = ((CompactCell*)(blob.ptr + offset))[:reference.columns.len];
    offset += reference.columns.len * CompactCell::size;
    GridFloor[] floors = ((GridFloor*)(blob.ptr + offset))[:reference.span_count];
    foreach (index, column : reference.columns) {
        columns[index] = { .index = column.span_base, .count = (uint)column.floors.len };
        floors[column.span_base:column.floors.len] = column.floors[..];
    }

    return blob;
}

fn char[]? build_grid_cache_runtime(TileCache* cache, char[] blob, NavMesh* mesh) @private {
    CachedGridReference cached = cached_grid_reference(blob)!;
    LayerHeader* layer = (LayerHeader*)blob.ptr;
    GridReference reference = unpack_grid_reference(&cache.arena, cached)!;

    GridTileBuilder builder = {
        .config = cached.header.config,
        .tile_config = tile_config(cached.header.config)!,
        .source = {
            .origin = cached.header.origin,
            .min_height = cached.header.min_height,
            .max_height = cached.header.max_height,
        },
        .arena = cache.arena,
    };
    ClearanceSource source = clearance_grid_source(
        builder: &builder,
        captured: &reference,
        tile_x: layer.tile_x,
        tile_z: layer.tile_z,
    )!;
    VolumeRecord[] volumes;
    if (cache.desc.volume_source) volumes = cache.desc.volume_source(cache.desc.volume_source_context, source.bounds)!;

    char[] packed;
    if (builder.config.detail_mode == DetailMode.COARSE) {
        builder.source.floors = &retained_grid_floors;
        builder.source.context = &reference;
        builder.heightfield = create_heightfield(
            allocator: &builder.arena,
            width: builder.tile_config.width,
            height: builder.tile_config.height,
            bounds: window_bounds(&builder, layer.tile_x, layer.tile_z),
            cell_size: builder.config.cell_size,
            cell_height: builder.config.cell_height,
            initial_spans: builder.tile_config.width * builder.tile_config.height * 2 * MAX_GRID_FLOORS,
        )!;
        packed = build_coarse_grid(
            self: &builder,
            tile_x: layer.tile_x,
            tile_z: layer.tile_z,
            obstacles: cache.obstacles,
            volumes: volumes,
        )!;
    } else if (builder.config.clearance_mode == ClearanceMode.SUB_CELL) {
        uint[]? selected = alloc::alloc_array_try(&builder.arena, uint, reference.span_count);
        if (catch selected) return c3d::CAPACITY_EXCEEDED~;
        foreach (index, surface : source.surfaces) {
            selected[index] = cached.header.floor_mask & (1u << surface.ordinal) ? (uint)index : NULL_SPAN;
        }
        packed = build_clearance_mesh(
            allocator: &builder.arena,
            source: &source,
            config: &builder.tile_config,
            tile_x: layer.tile_x,
            tile_z: layer.tile_z,
            selected_sources: selected,
            obstacles: cache.obstacles,
            volumes: volumes,
        )!;
    } else {
        CompactHeightfield compact = grid_compact_reference(&builder, &reference)!;
        mark_grid_cache_obstacles(
            builder: &builder,
            source: &source,
            compact: &compact,
            obstacles: cache.obstacles,
            volumes: volumes,
        )!;
        foreach (index, surface : source.surfaces) {
            if (!(cached.header.floor_mask & (1u << surface.ordinal))) compact.areas[index] = NULL_AREA;
        }

        GridPartialEdge* partials = connect_grid_edges(&builder, &reference, &compact)!;
        if (builder.tile_config.walkable_radius) compact.erode_walkable_area(&builder.arena, builder.tile_config.walkable_radius)!;
        filter_grid_regions(
            builder: &builder,
            reference: &reference,
            compact: &compact,
            partials: partials,
        )!;
        packed = pack_grid_cells(
            builder: &builder,
            reference: &reference,
            compact: &compact,
            partials: partials,
            tile_x: layer.tile_x,
            tile_z: layer.tile_z,
        )!;
    }
    if (!packed.len) return {};

    TileMeshView view = tile_mesh_view(packed);
    if (cache.desc.mesh_process) {
        cache.desc.mesh_process(
            context: cache.desc.mesh_process_context,
            mesh: view,
            areas: view.areas,
            flags: view.flags,
        );
    }
    OffMeshConnectionDesc[] connections;
    if (cache.desc.link_source) connections = cache.desc.link_source(cache.desc.link_source_context, layer.bounds);

    return create_tile_blob(
        mesh: mesh,
        tile_mesh: packed,
        connections: connections,
        params: {
            .tile_x = layer.tile_x,
            .tile_z = layer.tile_z,
            .tile_layer = layer.tile_layer,
            .walkable_height = cache.desc.walkable_height,
            .walkable_radius = cache.desc.walkable_radius,
            .walkable_climb = cache.desc.walkable_climb,
        },
    );
}

fn void? mark_grid_cache_obstacles(
    GridTileBuilder* builder,
    ClearanceSource* source,
    CompactHeightfield* compact,
    Obstacle[] obstacles,
    VolumeRecord[] volumes,
) @local {
    foreach (index, &surface : source.surfaces) {
        if (compact.areas[index] == NULL_AREA) continue;
        compact.areas[index] = clearance_volume_area(source, surface, volumes)!;

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
        ClearanceRectangle square = { .min_x = first.x, .min_z = first.z, .max_x = last.x, .max_z = last.z };

        for (uint fan = 0; fan < 4; fan++) {
            if (!clearance_obstacle_meets(
                source: source,
                surface_index: (uint)index,
                fan: fan,
                config: &builder.tile_config,
                square: square,
                radius: precision_point(0)!,
                interval_limit: 0,
                obstacles: obstacles,
                volumes: volumes,
            )!) continue;
            compact.areas[index] = NULL_AREA;
            break;
        }
    }
}

fn usz retained_grid_floors(
    void* context,
    int cell_x,
    int cell_z,
    GridFloor[] output,
) @local {
    GridReference* reference = context;
    uint x = (uint)(cell_x - reference.first_x);
    uint z = (uint)(cell_z - reference.first_z);
    GridColumn column = reference.columns[x + z * reference.width];
    output[:column.floors.len] = column.floors[..];
    return column.floors.len;
}

fn void shift_cached_grid_reference(char[] blob, Vec3 offset) @private {
    LayerHeader* layer = (LayerHeader*)blob.ptr;
    usz position = detail_reference_offset(LayerHeader::size + (usz)layer.width * layer.height * 3);
    CachedGridHeader* header = (CachedGridHeader*)(blob.ptr + position);
    header.origin -= offset;
}

fn uint grid_layer_root(uint[] roots, uint index) @local {
    while (roots[index] != index) index = roots[index];
    return index;
}
