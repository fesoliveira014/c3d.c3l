module c3d::nav;

import std::math;
import c3d;

const usz DETAIL_REFERENCE_ALIGNMENT @local = 8;

fn TileConfig? detail_cache_config(TileCacheDesc desc) @private {
    NavBuildConfig config = default_nav_build_config();
    config.cell_size = desc.cell_size;
    config.cell_height = desc.cell_height;
    config.tile_size = desc.width;
    config.agent_height = desc.walkable_height;
    config.agent_radius = desc.walkable_radius;
    config.agent_max_climb = desc.walkable_climb;
    config.agent_max_slope_degrees = desc.agent_max_slope_degrees;
    config.region_min_size = 0;
    config.region_merge_size = 0;
    config.detail_mode = desc.detail_mode;
    config.clearance_mode = desc.clearance_mode;
    config.clearance_max_error = desc.clearance_max_error;
    config.detail_max_error = desc.detail_max_error;
    config.max_detail_vertices = desc.max_detail_vertices;
    config.max_detail_triangles = desc.max_detail_triangles;

    return tile_config(config);
}

fn char[]? build_precision_cache_tile(
    TileCache* cache,
    CachedLayer* tile,
    TileCacheLayer* layer,
    NavMesh* mesh,
) @private {
    Allocator arena = &cache.arena;
    DetailReference reference = cached_detail_reference(tile.data)!;
    TileConfig config = detail_cache_config(cache.desc)!;
    if (reference.border_size != config.border_size) return LAYER_CORRUPTED~;

    if (config.clearance_mode == ClearanceMode.SUB_CELL) {
        return build_sub_cell_cache_tile(
            cache: cache,
            tile: tile,
            reference: &reference,
            config: &config,
            mesh: mesh,
        );
    }

    CompactHeightfield compact = compact_detail_reference(arena, &reference, &config)!;
    classify_detail_reference(&reference, &compact, &config)!;
    if (cache.desc.volume_source) {
        VolumeRecord[] volumes = cache.desc.volume_source(cache.desc.volume_source_context, compact.bounds)!;
        foreach (&volume : volumes) apply_volume(&compact, volume);
    }
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state == EMPTY || obstacle.state == REMOVING) continue;
        mark_precision_obstacle(
            reference: &reference,
            compact: &compact,
            obstacle: obstacle,
            agent_height: cache.desc.walkable_height,
        );
    }
    if (config.walkable_radius) compact.erode_walkable_area(arena, config.walkable_radius)!;
    uint[] sources = cached_detail_sources(tile.data);
    ushort[]? regions = alloc::new_array_try(arena, ushort, reference.samples.len);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;
    foreach (cell, source : sources) {
        layer.areas[cell] = source == NULL_SPAN ? NULL_AREA : compact.areas[source];
        if (source != NULL_SPAN && layer.areas[cell] != NULL_AREA) regions[source] = 1;
    }
    layer.build_regions(arena, config.walkable_climb)!;
    LayerContourSet contours = build_tile_cache_contours(
        allocator: arena,
        scratch: arena,
        layer: layer,
        walkable_climb: config.walkable_climb,
        max_error: 0,
    )!;
    LayerPolyMesh layer_mesh = build_tile_cache_poly_mesh(
        allocator: arena,
        scratch: arena,
        contours: &contours,
        preserve_surface: true,
    )!;
    LayerHeader* header = layer.header;
    TileDataParams params = {
        .tile_x = header.tile_x,
        .tile_z = header.tile_z,
        .tile_layer = header.tile_layer,
        .walkable_height = cache.desc.walkable_height,
        .walkable_radius = cache.desc.walkable_radius,
        .walkable_climb = cache.desc.walkable_climb,
    };
    if (!layer_mesh.poly_count) {
        return {};
    }
    ushort[]? polygon_regions = alloc::new_array_try(arena, ushort, layer_mesh.poly_count);
    if (catch polygon_regions) return c3d::CAPACITY_EXCEEDED~;
    PolyMesh polygons = {
        .verts = layer_mesh.verts,
        .polys = layer_mesh.polys,
        .regions = polygon_regions,
        .flags = layer_mesh.flags,
        .areas = layer_mesh.areas,
        .vert_count = layer_mesh.vert_count,
        .poly_count = layer_mesh.poly_count,
        .verts_per_poly = layer_mesh.verts_per_poly,
        .bounds = header.bounds,
        .cell_size = cache.desc.cell_size,
        .cell_height = cache.desc.cell_height,
    };
    build_poly_details(
        allocator: arena,
        mesh: &polygons,
        reference: &reference,
        regions: regions,
        config: &config,
        height_offset: header.hmin * cache.desc.cell_height,
    )!;
    build_detail_portals(
        allocator: arena,
        mesh: &polygons,
        reference: &reference,
        regions: regions,
        areas: compact.areas,
        capacity: config.max_detail_triangles,
    )!;
    char[]? packed = alloc::alloc_array_try(arena, char, (sz)tile_mesh_size(&polygons));
    if (catch packed) return c3d::CAPACITY_EXCEEDED~;
    pack_tile_mesh(mesh: &polygons, tile_x: header.tile_x, tile_z: header.tile_z, blob: packed);
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
    if (cache.desc.link_source) {
        Aabb connection_bounds = header.bounds;
        foreach (vertex : polygons.detail.vertices) {
            float height = polygons.detail.origin.y + vertex.y;
            connection_bounds.min.y = math::min(connection_bounds.min.y, height);
            connection_bounds.max.y = math::max(connection_bounds.max.y, height);
        }
        connection_bounds.min.y -= cache.desc.walkable_climb;
        connection_bounds.max.y += cache.desc.walkable_climb;
        connections = cache.desc.link_source(cache.desc.link_source_context, connection_bounds);
    }
    return create_tile_blob(mesh: mesh, tile_mesh: packed, connections: connections, params: params);
}

fn char[]? build_sub_cell_cache_tile(
    TileCache* cache,
    CachedLayer* tile,
    DetailReference* reference,
    TileConfig* config,
    NavMesh* mesh,
) @local {
    Allocator arena = &cache.arena;
    ClearanceSource source = clearance_scene_source(arena, reference, config)!;
    VolumeRecord[] volumes;
    if (cache.desc.volume_source) volumes = cache.desc.volume_source(cache.desc.volume_source_context, source.bounds)!;

    LayerHeader* header = tile.header;
    char[] packed = build_clearance_mesh(
        allocator: arena,
        source: &source,
        config: config,
        tile_x: header.tile_x,
        tile_z: header.tile_z,
        selected_sources: cached_detail_sources(tile.data),
        obstacles: cache.obstacles,
        volumes: volumes,
    )!;
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
    if (cache.desc.link_source) {
        Aabb bounds = view.header.bounds;
        foreach (vertex : view.detail_corners) {
            float height = view.header.detail_origin.y + vertex.y;
            bounds.min.y = math::min(bounds.min.y, height);
            bounds.max.y = math::max(bounds.max.y, height);
        }

        foreach (vertex : view.detail_vertices) {
            float height = view.header.detail_origin.y + vertex.y;
            bounds.min.y = math::min(bounds.min.y, height);
            bounds.max.y = math::max(bounds.max.y, height);
        }

        bounds.min.y -= cache.desc.walkable_climb;
        bounds.max.y += cache.desc.walkable_climb;
        connections = cache.desc.link_source(cache.desc.link_source_context, bounds);
    }

    TileDataParams params = {
        .tile_x = header.tile_x,
        .tile_z = header.tile_z,
        .tile_layer = header.tile_layer,
        .walkable_height = cache.desc.walkable_height,
        .walkable_radius = cache.desc.walkable_radius,
        .walkable_climb = cache.desc.walkable_climb,
    };

    return create_tile_blob(
        mesh: mesh,
        tile_mesh: packed,
        connections: connections,
        params: params,
    );
}

fn void mark_precision_obstacle(
    DetailReference* reference,
    CompactHeightfield* compact,
    Obstacle* obstacle,
    float agent_height,
) @local {
    Aabb obstacle_bounds = obstacle.bounds();
    double half_cell = (double)reference.cell_size * 0.5;
    foreach (index, sample : reference.samples) {
        if (compact.areas[index] == NULL_AREA) continue;
        float low = sample.height;
        float high = sample.height;
        foreach (corner : sample.corners) {
            low = math::min(low, corner);
            high = math::max(high, corner);
        }
        double floor_low = (double)reference.origin.y + low;
        double floor_high = (double)reference.origin.y + high;
        if (obstacle_bounds.max.y < floor_low || obstacle_bounds.min.y > floor_high + agent_height) continue;
        int x = (int)(sample.column % reference.width) - (int)reference.border_size;
        int z = (int)(sample.column / reference.width) - (int)reference.border_size;
        double center_x = reference.origin.x + ((double)x + 0.5) * reference.cell_size;
        double center_z = reference.origin.z + ((double)z + 0.5) * reference.cell_size;
        bool intersects;
        switch (obstacle.kind) {
            case CYLINDER:
                double dx = math::max(0.0, math::abs(center_x - obstacle.position.x) - half_cell);
                double dz = math::max(0.0, math::abs(center_z - obstacle.position.z) - half_cell);
                intersects = dx * dx + dz * dz <= (double)obstacle.radius * obstacle.radius;
            case BOX:
                intersects = center_x + half_cell >= obstacle.box.min.x && center_x - half_cell <= obstacle.box.max.x
                    && center_z + half_cell >= obstacle.box.min.z && center_z - half_cell <= obstacle.box.max.z;
            case ORIENTED_BOX:
                double cosine = 2.0 * obstacle.rotation[1];
                double sine = -2.0 * obstacle.rotation[0];
                double dx = center_x - obstacle.position.x;
                double dz = center_z - obstacle.position.z;
                double projected_cell = half_cell * (math::abs(cosine) + math::abs(sine));
                intersects = math::abs(dx) <= half_cell + math::abs(cosine) * obstacle.half_extents.x + math::abs(sine) * obstacle.half_extents.z
                    && math::abs(dz) <= half_cell + math::abs(sine) * obstacle.half_extents.x + math::abs(cosine) * obstacle.half_extents.z
                    && math::abs(cosine * dx - sine * dz) <= obstacle.half_extents.x + projected_cell
                    && math::abs(sine * dx + cosine * dz) <= obstacle.half_extents.z + projected_cell;
        }
        if (intersects) compact.areas[index] = NULL_AREA;
    }
}

fn void shift_cached_detail_reference(char[] blob, Vec3 offset) @private {
    LayerHeader* header = (LayerHeader*)blob.ptr;
    usz cells = (usz)header.width * header.height;
    usz position = detail_reference_offset(detail_reference_offset(LayerHeader::size + cells * 3) + cells * uint::size);
    DetailReferenceHeader* reference = (DetailReferenceHeader*)(blob.ptr + position);
    shift_detail_origin(&reference.origin, &reference.origin_correction, offset);
    reference.basis[0] -= offset.x;
    reference.basis[1] -= offset.z;
}

fn usz precision_layer_blob_size(HeightfieldLayer* layer, DetailReference* reference) @private {
    usz size = layer_blob_size(layer);
    if (!reference) return size;
    return detail_reference_offset(detail_reference_offset(size) + layer.source_spans.len * uint::size) + detail_reference_size(reference);
}

fn void pack_precision_layer(
    HeightfieldLayer* layer,
    int tile_x,
    int tile_z,
    int tile_layer,
    DetailReference* reference,
    char[] blob,
) @private {
    usz base_size = layer_blob_size(layer);
    build_tile_cache_layer(
        layer: layer,
        tile_x: tile_x,
        tile_z: tile_z,
        tile_layer: tile_layer,
        blob: blob[:base_size],
    );
    if (!reference) return;
    usz offset = detail_reference_offset(base_size);
    blob[base_size:offset - base_size] = 0;
    LayerHeader* header = (LayerHeader*)blob.ptr;
    header.detail_mode = DetailMode.BOUNDED;
    usz mapping_bytes = layer.source_spans.len * uint::size;
    usz reference_offset = detail_reference_offset(offset + mapping_bytes);
    header.reference_bytes = (uint)(reference_offset - offset + detail_reference_size(reference));
    ((uint*)(blob.ptr + offset))[:layer.source_spans.len] = layer.source_spans[..];
    blob[offset + mapping_bytes:reference_offset - offset - mapping_bytes] = 0;
    pack_detail_reference(reference, blob[reference_offset:detail_reference_size(reference)]);
}

fn DetailReference? cached_detail_reference(char[] blob) @private {
    if (blob.len < LayerHeader::size) return LAYER_CORRUPTED~;
    LayerHeader* header = (LayerHeader*)blob.ptr;
    if (header.detail_mode != DetailMode.BOUNDED) return LAYER_CORRUPTED~;
    usz offset = detail_reference_offset(LayerHeader::size + (usz)header.width * header.height * 3);
    if (offset > blob.len || header.reference_bytes != blob.len - offset) return LAYER_CORRUPTED~;
    usz cells = (usz)header.width * header.height;
    usz mapping_bytes = cells * uint::size;
    if (mapping_bytes > header.reference_bytes) return LAYER_CORRUPTED~;
    usz reference_offset = detail_reference_offset(offset + mapping_bytes);
    if (reference_offset > blob.len) return LAYER_CORRUPTED~;
    DetailReference reference = read_detail_reference(blob[reference_offset:blob.len - reference_offset])!;
    if (reference.width != header.width + reference.border_size * 2 || reference.height != header.height + reference.border_size * 2) return LAYER_CORRUPTED~;
    uint[] mapping = ((uint*)(blob.ptr + offset))[:cells];
    char[] heights = blob[LayerHeader::size:cells];
    foreach (cell, index : mapping) {
        if (index == NULL_SPAN) {
            if (heights[cell] != 0xff) return LAYER_CORRUPTED~;
            continue;
        }
        if (index >= reference.samples.len || heights[cell] == 0xff) return LAYER_CORRUPTED~;
        uint column = (uint)(cell % header.width) + reference.border_size
            + ((uint)(cell / header.width) + reference.border_size) * reference.width;
        if (reference.samples[index].column != column) return LAYER_CORRUPTED~;
    }
    return reference;
}

fn uint[] cached_detail_sources(char[] blob) @private {
    LayerHeader* header = (LayerHeader*)blob.ptr;
    usz cells = (usz)header.width * header.height;
    usz offset = detail_reference_offset(LayerHeader::size + cells * 3);
    return ((uint*)(blob.ptr + offset))[:cells];
}

fn usz detail_reference_offset(usz size) @private {
    return (size + DETAIL_REFERENCE_ALIGNMENT - 1) / DETAIL_REFERENCE_ALIGNMENT * DETAIL_REFERENCE_ALIGNMENT;
}
