module c3d::nav;

import std::math;
import c3d;
import c3d::debug;
import c3d::maths;

const uint     TILE_COLOR @local = 0xFF808080;
const uint     UNWALKABLE_SPAN_COLOR @local = 0xFF505050;
const uint     WALKABLE_COLOR @local = 0xFFFFC040;
const uint     PORTAL_COLOR @local = 0xFFFFFFFF;
const uint     LINK_COLOR @local = 0xFFFF40C0;
const uint     UNLINKED_COLOR @local = 0xFF808080; // an off-mesh connection whose start found no polygon
const uint     AGENT_COLOR @local = 0xFF40E040;
const uint     OFF_MESH_AGENT_COLOR @local = 0xFFFF40C0;
const uint     INVALID_AGENT_COLOR @local = 0xFF4040FF;
const uint     VELOCITY_COLOR @local = 0xFFFFFF40;
const uint     CORRIDOR_COLOR @local = 0xFF40A0FF;
const uint     CORNER_COLOR @local = 0xFF20E0FF;
const uint     BOUNDARY_COLOR @local = 0xFF4040FF;
const uint     NEIGHBOUR_COLOR @local = 0xFFC0C0C0;
const float    MESH_LIFT @local = 0.05f; // metres; outlines draw above the floor they lie on
const uint[8]  AREA_PALETTE @local = {
    0xFF40FF40,
    0xFF00A5FF,
    0xFF3080D0,
    0xFFFF40FF,
    0xFF40FFFF,
    0xFF4040FF,
    0xFFFFFF40,
    0xFFC0C0C0,
};

<* What NavBuilder.debug_draw appends. *>
struct NavDebugOptions {
    bool tiles;      // tile bounds; dirty tiles in red
    bool polys;      // polygon outlines, coloured by area
}

<* What NavMesh.debug_draw appends. *>
struct NavMeshDebugOptions {
    bool polys;     // polygon outlines by area
    bool links;     // linked portal edges and off-mesh connections
    bool bounds;    // tile bounds
}

<* What Crowd.debug_draw appends. *>
struct CrowdDebugOptions {
    bool agents;        // a circle at the radius, velocity as a line
    bool corridors;     // corridor polygon outlines and the corners ahead
    bool boundaries;    // local boundary segments
    bool neighbours;    // lines to neighbours
}

<*
 Append polygons, links and tile bounds of every resident tile to the sink.
 @param [&inout] sink : "Cleared by the application."
*>
fn void NavMesh.debug_draw(&self, debug::DebugDraw* sink, NavMeshDebugOptions options) {
    Vec3 lift = { 0, MESH_LIFT, 0 };
    foreach (&tile : self.tiles) {
        if (!tile.header) continue;
        if (options.bounds) sink.aabb(tile.header.bounds, TILE_COLOR);
        foreach (&poly : tile.polys) {
            if (poly.area_type.type == OFF_MESH_CONNECTION) {
                if (options.links) draw_off_mesh_connection(sink, tile, poly);
                continue;
            }
            int count = poly.vert_count;
            for (int edge = 0; edge < count; edge++) {
                Vec3 start = tile.verts[poly.verts[edge]] + lift;
                Vec3 end = tile.verts[poly.verts[(edge + 1) % count]] + lift;
                if (options.links && has_portal_link(tile, poly, edge)) {
                    sink.line(start + lift, end + lift, PORTAL_COLOR);
                } else if (options.polys) {
                    sink.line(start, end, area_color(poly.area_type.area));
                }
            }
        }
    }
}

<*
 Append tile bounds and polygon outlines to the sink.
 @param [&inout] sink : "Cleared by the application."
*>
fn void NavBuilder.debug_draw(&self, debug::DebugDraw* sink, NavDebugOptions options) {
    float border = self.tile_config.border_size * self.config.cell_size;
    for (uint tile_z = 0; tile_z < self.tiles_z; tile_z++) {
        for (uint tile_x = 0; tile_x < self.tiles_x; tile_x++) {
            TileRecord* record = &self.tiles[tile_x + tile_z * self.tiles_x];
            if (options.tiles) {
                Aabb tile = self.tile_bounds(tile_x, tile_z);
                tile.min.x += border;
                tile.min.z += border;
                tile.max.x -= border;
                tile.max.z -= border;
                sink.aabb(tile, record.dirty ? debug::COLOR_RED : TILE_COLOR);
            }
            if (options.polys && record.mesh.len) draw_tile_polys(sink, tile_mesh_view(record.mesh));
        }
    }
}

<*
 Append agents, corridors, boundaries and neighbour links of every active agent to the sink.
 @param [&inout] sink : "Cleared by the application."
*>
fn void Crowd.debug_draw(&self, debug::DebugDraw* sink, CrowdDebugOptions options) {
    Vec3 up = { 0, 1, 0 };
    Vec3 lift = { 0, MESH_LIFT * 2, 0 };
    foreach (&agent : self.agents) {
        if (!agent.active) continue;
        Vec3 position = agent.position + lift;
        if (options.agents) {
            sink.circle(position, up, agent.params.radius, agent_color(agent.state));
            sink.line(position, position + agent.velocity, VELOCITY_COLOR);
        }
        if (options.corridors) {
            foreach (ref : agent.corridor.polys()) draw_poly_outline(sink, self.query.mesh, ref, CORRIDOR_COLOR);
            Vec3 previous = position;
            foreach (corner : agent.corners[:agent.corner_count]) {
                sink.line(previous, corner.position + lift, CORNER_COLOR);
                previous = corner.position + lift;
            }
        }
        if (options.boundaries) {
            foreach (segment : agent.boundary.segments[:agent.boundary.segment_count]) {
                sink.line(segment.start + lift, segment.end + lift, BOUNDARY_COLOR);
            }
        }
        if (options.neighbours) {
            foreach (neighbour : agent.neighbours[:agent.neighbour_count]) {
                sink.line(position, self.agents[neighbour.index].position + lift, NEIGHBOUR_COLOR);
            }
        }
    }
}

<*
 Append a polyline through the points, lifted above the mesh outlines.
 @param [&inout] sink : "Cleared by the application."
*>
fn void debug_draw_path(debug::DebugDraw* sink, StraightPoint[] points, uint rgba) {
    Vec3 lift = { 0, MESH_LIFT * 2, 0 };
    for (usz index = 1; index < points.len; index++) {
        sink.line(points[index - 1].position + lift, points[index].position + lift, rgba);
    }
}

<*
 Append the top face of every span; walkable spans in the colour, the rest grey.
 @param [&in] heightfield : "A slot's, between rasterize_next and commit."
 @param [&inout] sink : "Cleared by the application."
*>
fn void debug_draw_heightfield(Heightfield* heightfield, debug::DebugDraw* sink, uint rgba) {
    Vec3 origin = heightfield.bounds.min;
    float cell = heightfield.cell_size;
    for (uint z = 0; z < heightfield.height; z++) {
        for (uint x = 0; x < heightfield.width; x++) {
            for (uint index = heightfield.span_at(x, z); index != NULL_SPAN; index = heightfield.span(index).next) {
                SpanExtent extent = heightfield.span(index).extent;
                uint color = extent.area != NULL_AREA ? rgba : UNWALKABLE_SPAN_COLOR;
                Vec3 corner = {
                    origin.x + (float)x * cell,
                    origin.y + (float)extent.max * heightfield.cell_height,
                    origin.z + (float)z * cell,
                };
                Vec3 across_x = corner + { cell, 0, 0 };
                Vec3 across_z = corner + { 0, 0, cell };
                Vec3 opposite = corner + { cell, 0, cell };
                sink.line(corner, across_x, color);
                sink.line(across_x, opposite, color);
                sink.line(opposite, across_z, color);
                sink.line(across_z, corner, color);
            }
        }
    }
}

// Lifted one cell height so the outlines draw above the floor they lie on.
fn void draw_tile_polys(debug::DebugDraw* sink, TileMeshView view) @local {
    TileMeshHeader* header = view.header;
    uint stride = header.verts_per_poly;
    Vec3 scale = { header.cell_size, header.cell_height, header.cell_size };
    Vec3 origin = header.bounds.min + { 0, header.cell_height, 0 };
    for (uint poly = 0; poly < header.poly_count; poly++) {
        ushort[] indices = view.polys[(usz)poly * stride * 2:stride];
        int count = count_poly_verts(indices);
        uint color = area_color(view.areas[poly]);
        for (int slot = 0; slot < count; slot++) {
            Vec3 start = mesh_vertex_position(view, indices[slot], origin, scale);
            Vec3 end = mesh_vertex_position(view, indices[(slot + 1) % count], origin, scale);
            sink.line(start, end, color);
        }
    }
}

fn Vec3 mesh_vertex_position(
    TileMeshView view,
    ushort vertex,
    Vec3 origin,
    Vec3 scale,
) @local {
    ushort* voxel = &view.verts[vertex * 3];
    return origin + (Vec3){ (float)voxel[0], (float)voxel[1], (float)voxel[2] } * scale;
}

fn uint area_color(char area) @local {
    if (area == WALKABLE_AREA) return WALKABLE_COLOR;
    return AREA_PALETTE[area % AREA_PALETTE.len];
}

fn bool has_portal_link(MeshTile* tile, Poly* poly, int edge) @local {
    if ((poly.neighbours[edge] & EXTERNAL_LINK) == 0) return false;
    for (uint link = poly.first_link; link != NULL_LINK; link = tile.links[link].next) {
        if (tile.links[link].edge == edge) return true;
    }
    return false;
}

fn void draw_off_mesh_connection(debug::DebugDraw* sink, MeshTile* tile, Poly* poly) @local {
    OffMeshConnection* connection = &tile.off_mesh[(uint)(poly - tile.polys.ptr) - tile.header.off_mesh_base];
    uint color = poly.first_link == NULL_LINK ? UNLINKED_COLOR : LINK_COLOR;
    Vec3 up = { 0, 1, 0 };
    Vec3 start = tile.verts[poly.verts[0]];
    Vec3 end = tile.verts[poly.verts[1]];
    sink.line(start, end, color);
    sink.circle(start, up, connection.radius, color);
    sink.circle(end, up, connection.radius, color);
}

fn uint agent_color(AgentState state) @local {
    switch (state) {
        case INVALID:
            return INVALID_AGENT_COLOR;
        case WALKING:
            return AGENT_COLOR;
        case OFF_MESH:
            return OFF_MESH_AGENT_COLOR;
    }
}

// A polygon of a reinstalled tile is skipped until the corridor is replanned.
fn void draw_poly_outline(
    debug::DebugDraw* sink,
    NavMesh* mesh,
    PolyRef ref,
    uint rgba,
) @local {
    TileAndPoly? found = mesh.tile_and_poly(ref);
    if (catch found) return;
    Vec3 lift = { 0, MESH_LIFT * 2, 0 };
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(found.tile, found.poly);
    usz count = found.poly.vert_count;
    for (usz edge = 0; edge < count; edge++) sink.line(verts[edge] + lift, verts[(edge + 1) % count] + lift, rgba);
}
