module c3d::geometry;

import c3d::maths;
import std::math;

<*
 Axis-aligned box centered at the origin, with per-face normals.
 @require width > 0 && height > 0 && depth > 0, segments > 0
*>
fn Geometry box(Allocator allocator, float width, float height, float depth, uint segments = 1) {
    uint ring = segments + 1;
    Geometry geometry = allocate_streams(allocator, 6 * ring * ring, 36 * segments * segments);
    Vec3 half = { width * 0.5f, height * 0.5f, depth * 0.5f };
    Vec3[6] normals = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
    Vec3[6] tangents = { { 0, 0, -1 }, { 0, 0, 1 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { -1, 0, 0 } };
    Vec3[6] bitangents = { { 0, 1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 }, { 0, 1, 0 }, { 0, 1, 0 } };
    for (uint face = 0; face < 6; face++) {
        Vec3 normal = normals[face];
        Vec3 tangent = tangents[face];
        Vec3 bitangent = bitangents[face];
        Vec3 origin = normal * half;
        Vec3 extent_u = tangent * half;
        Vec3 extent_v = bitangent * half;
        uint first_vertex = face * ring * ring;
        for (uint j = 0; j < ring; j++) {
            for (uint i = 0; i < ring; i++) {
                float u = (float)i / segments;
                float v = (float)j / segments;
                uint slot = first_vertex + j * ring + i;
                geometry.positions[slot] = origin + extent_u * (2.0f * u - 1.0f) + extent_v * (2.0f * v - 1.0f);
                geometry.normals[slot] = normal;
                geometry.uv0[slot] = { u, v };
            }
        }
        grid_indices(
            indices:      geometry.indices,
            first_index:  (usz)(face * 6 * segments * segments),
            columns:      segments,
            rows:         segments,
            first_vertex: first_vertex,
            reversed:     false,
        );
    }
    geometry.finalize();
    return geometry;
}

<*
 Horizontal plane in XZ facing +Y, centered at the origin.
 @require width > 0 && depth > 0, segments_x > 0 && segments_z > 0
*>
fn Geometry plane(Allocator allocator, float width, float depth, uint segments_x = 1, uint segments_z = 1) {
    Geometry geometry = allocate_streams(allocator, (segments_x + 1) * (segments_z + 1), 6 * segments_x * segments_z);
    for (uint j = 0; j <= segments_z; j++) {
        for (uint i = 0; i <= segments_x; i++) {
            float u = (float)i / segments_x;
            float v = (float)j / segments_z;
            uint slot = j * (segments_x + 1) + i;
            geometry.positions[slot] = { (u - 0.5f) * width, 0, (v - 0.5f) * depth };
            geometry.normals[slot] = { 0, 1, 0 };
            geometry.uv0[slot] = { u, v };
        }
    }
    grid_indices(
        indices:      geometry.indices,
        first_index:  0,
        columns:      segments_x,
        rows:         segments_z,
        first_vertex: 0,
        reversed:     true,
    );
    geometry.finalize();
    return geometry;
}

<*
 UV sphere centered at the origin.
 @require radius > 0, slices >= 3, stacks >= 2
*>
fn Geometry sphere(Allocator allocator, float radius, uint slices = 32, uint stacks = 16) {
    Geometry geometry = allocate_streams(allocator, (slices + 1) * (stacks + 1), 6 * slices * stacks);
    for (uint stack = 0; stack <= stacks; stack++) {
        float phi = (float)math::PI * stack / stacks;
        for (uint slice = 0; slice <= slices; slice++) {
            float theta = (float)math::TWO_PI * slice / slices;
            uint slot = stack * (slices + 1) + slice;
            Vec3 normal = { math::sin(phi) * math::cos(theta), math::cos(phi), math::sin(phi) * math::sin(theta) };
            geometry.positions[slot] = normal * radius;
            geometry.normals[slot] = normal;
            geometry.uv0[slot] = { (float)slice / slices, 1.0f - (float)stack / stacks };
        }
    }
    grid_indices(
        indices:      geometry.indices,
        first_index:  0,
        columns:      slices,
        rows:         stacks,
        first_vertex: 0,
        reversed:     false,
    );
    geometry.finalize();
    return geometry;
}

<*
 Capped cylinder along Y, centered at the origin.
 @param radius_top : "Zero skips the top cap."
 @param radius_bottom : "Zero skips the bottom cap."
 @require radius_top >= 0 && radius_bottom >= 0, radius_top > 0 || radius_bottom > 0
 @require height > 0, slices >= 3
*>
fn Geometry cylinder(Allocator allocator, float radius_top, float radius_bottom, float height, uint slices = 32) {
    uint cap_count = (radius_top > 0 ? 1 : 0) + (radius_bottom > 0 ? 1 : 0);
    uint vertex_count = 2 * (slices + 1) + cap_count * (slices + 2);
    uint index_count = 6 * slices + cap_count * 3 * slices;
    Geometry geometry = allocate_streams(allocator, vertex_count, index_count);
    float half_height = height * 0.5f;
    float slope = radius_bottom - radius_top;
    for (uint row = 0; row < 2; row++) {
        float radius = row == 0 ? radius_bottom : radius_top;
        float y = row == 0 ? -half_height : half_height;
        for (uint slice = 0; slice <= slices; slice++) {
            float theta = (float)math::TWO_PI * slice / slices;
            uint slot = row * (slices + 1) + slice;
            Vec3 around = { math::cos(theta), 0, math::sin(theta) };
            geometry.positions[slot] = { around.x * radius, y, around.z * radius };
            geometry.normals[slot] = ((Vec3){ around.x * height, slope, around.z * height }).normalize();
            geometry.uv0[slot] = { (float)slice / slices, (float)row };
        }
    }
    grid_indices(
        indices:      geometry.indices,
        first_index:  0,
        columns:      slices,
        rows:         1,
        first_vertex: 0,
        reversed:     true,
    );
    uint next_vertex = 2 * (slices + 1);
    usz next_index = (usz)(6 * slices);
    if (radius_bottom > 0) {
        ring_cap(
            geometry:     &geometry,
            first_vertex: next_vertex,
            first_index:  next_index,
            radius:       radius_bottom,
            y:            -half_height,
            slices:       slices,
            facing_up:    false,
        );
        next_vertex += slices + 2;
        next_index += (usz)(3 * slices);
    }
    if (radius_top > 0) {
        ring_cap(
            geometry:     &geometry,
            first_vertex: next_vertex,
            first_index:  next_index,
            radius:       radius_top,
            y:            half_height,
            slices:       slices,
            facing_up:    true,
        );
    }
    geometry.finalize();
    return geometry;
}

<*
 Capped cone along Y with its apex at +Y, centered at the origin.
 @require radius > 0 && height > 0, slices >= 3
*>
fn Geometry cone(Allocator allocator, float radius, float height, uint slices = 32) {
    return cylinder(
        allocator:     allocator,
        radius_top:    0,
        radius_bottom: radius,
        height:        height,
        slices:        slices,
    );
}

<*
 Torus in the XZ plane centered at the origin.
 @param radius : "Distance from the center to the tube center."
 @param tube : "Tube radius."
 @require radius > 0 && tube > 0, radial >= 3, tubular >= 3
*>
fn Geometry torus(Allocator allocator, float radius, float tube, uint radial = 32, uint tubular = 16) {
    Geometry geometry = allocate_streams(allocator, (radial + 1) * (tubular + 1), 6 * radial * tubular);
    for (uint j = 0; j <= tubular; j++) {
        float v = (float)math::TWO_PI * j / tubular;
        for (uint i = 0; i <= radial; i++) {
            float u = (float)math::TWO_PI * i / radial;
            uint slot = j * (radial + 1) + i;
            Vec3 center = { radius * math::cos(u), 0, radius * math::sin(u) };
            Vec3 normal = { math::cos(v) * math::cos(u), math::sin(v), math::cos(v) * math::sin(u) };
            geometry.positions[slot] = center + normal * tube;
            geometry.normals[slot] = normal;
            geometry.uv0[slot] = { (float)i / radial, (float)j / tubular };
        }
    }
    grid_indices(
        indices:      geometry.indices,
        first_index:  0,
        columns:      radial,
        rows:         tubular,
        first_vertex: 0,
        reversed:     true,
    );
    geometry.finalize();
    return geometry;
}

<*
 Capsule along Y centered at the origin.
 @param height : "Distance between the hemisphere centers."
 @require radius > 0 && height >= 0, slices >= 3, stacks >= 2 && stacks % 2 == 0
*>
fn Geometry capsule(Allocator allocator, float radius, float height, uint slices = 32, uint stacks = 8) {
    uint half_stacks = stacks / 2;
    uint rings = stacks + 2;
    Geometry geometry = allocate_streams(allocator, (slices + 1) * rings, 6 * slices * (stacks + 1));
    float half_height = height * 0.5f;
    float arc_total = (float)math::PI * radius + height;
    for (uint ring = 0; ring < rings; ring++) {
        bool top = ring <= half_stacks;
        uint step = top ? ring : ring - half_stacks - 1;
        float phi = top
            ? (float)math::PI * 0.5f * step / half_stacks
            : (float)math::PI * 0.5f + (float)math::PI * 0.5f * step / half_stacks;
        float center_y = top ? half_height : -half_height;
        float arc = top
            ? radius * phi
            : radius * (float)math::PI * 0.5f + height + radius * (phi - (float)math::PI * 0.5f);
        for (uint slice = 0; slice <= slices; slice++) {
            float theta = (float)math::TWO_PI * slice / slices;
            uint slot = ring * (slices + 1) + slice;
            Vec3 normal = { math::sin(phi) * math::cos(theta), math::cos(phi), math::sin(phi) * math::sin(theta) };
            geometry.positions[slot] = normal * radius + (Vec3){ 0, center_y, 0 };
            geometry.normals[slot] = normal;
            geometry.uv0[slot] = { (float)slice / slices, 1.0f - arc / arc_total };
        }
    }
    grid_indices(
        indices:      geometry.indices,
        first_index:  0,
        columns:      slices,
        rows:         stacks + 1,
        first_vertex: 0,
        reversed:     false,
    );
    geometry.finalize();
    return geometry;
}

fn Geometry allocate_streams(Allocator allocator, uint vertex_count, uint index_count) @local {
    return {
        .topology  = Topology.TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, vertex_count),
        .normals   = alloc::new_array(allocator, Vec3, vertex_count),
        .uv0       = alloc::new_array(allocator, Vec2, vertex_count),
        .indices   = alloc::new_array(allocator, uint, index_count),
    };
}

fn void grid_indices(uint[] indices, usz first_index, uint columns, uint rows, uint first_vertex,
  bool reversed) @local {
    usz slot = first_index;
    for (uint j = 0; j < rows; j++) {
        for (uint i = 0; i < columns; i++) {
            uint a = first_vertex + j * (columns + 1) + i;
            uint b = a + 1;
            uint c = a + columns + 1;
            uint d = c + 1;
            if (reversed) {
                indices[slot : 6] = (uint[6]){ a, c, b, b, c, d }[..];
            } else {
                indices[slot : 6] = (uint[6]){ a, b, c, b, d, c }[..];
            }
            slot += 6;
        }
    }
}

fn void ring_cap(Geometry* geometry, uint first_vertex, usz first_index, float radius, float y, uint slices,
  bool facing_up) @local {
    Vec3 normal = { 0, facing_up ? 1.0f : -1.0f, 0 };
    geometry.positions[first_vertex] = { 0, y, 0 };
    geometry.normals[first_vertex] = normal;
    geometry.uv0[first_vertex] = { 0.5f, 0.5f };
    for (uint slice = 0; slice <= slices; slice++) {
        float theta = (float)math::TWO_PI * slice / slices;
        uint slot = first_vertex + 1 + slice;
        geometry.positions[slot] = { radius * math::cos(theta), y, radius * math::sin(theta) };
        geometry.normals[slot] = normal;
        geometry.uv0[slot] = { 0.5f + 0.5f * math::cos(theta), 0.5f + 0.5f * math::sin(theta) };
    }
    usz index = first_index;
    for (uint slice = 0; slice < slices; slice++) {
        uint rim = first_vertex + 1 + slice;
        geometry.indices[index] = first_vertex;
        geometry.indices[index + 1] = facing_up ? rim + 1 : rim;
        geometry.indices[index + 2] = facing_up ? rim : rim + 1;
        index += 3;
    }
}
