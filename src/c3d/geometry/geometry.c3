module c3d::geometry;

import c3d::maths;
import std::math;

<*
 Primitive assembly of the index or vertex stream.
*>
enum Topology {
    TRIANGLES,
    LINES,
    POINTS,
}

<*
 Per-vertex deltas of one morph target.
*>
struct MorphTarget {
    Vec3[] position_deltas;
    Vec3[] normal_deltas;
    String name;
}

<*
 Attribute arrays and indices of one mesh; carries no material.
*>
struct Geometry {
    Topology      topology;
    Vec3[]        positions;
    Vec3[]        normals;
    Vec4[]        tangents;
    Vec2[]        uv0;
    Vec2[]        uv1;
    Vec4[]        colors;
    ushort[<4>][] joints;
    Vec4[]        weights;
    uint[]        indices;
    MorphTarget[] targets;
    char[]        custom_data;
    uint          custom_stride;
    Aabb          bounds;
}

<*
 Recompute the local bounds from the positions.
 @require self.positions.len > 0
*>
fn void Geometry.finalize(&self) {
    Aabb bounds = { .min = self.positions[0], .max = self.positions[0] };
    foreach (position : self.positions) {
        bounds.min = math::min(bounds.min, position);
        bounds.max = math::max(bounds.max, position);
    }
    self.bounds = bounds;
}

<*
 Write per-vertex normals from the triangles.
 @param allocator : "Allocates normals when the geometry has none."
 @param smooth : "Averaged per vertex, or one face normal per corner."
 @require self.topology == Topology.TRIANGLES, self.positions.len > 0
 @require smooth || self.indices.len == 0
*>
fn void Geometry.compute_normals(&self, Allocator allocator, bool smooth = true) {
    if (!self.normals.len) {
        self.normals = alloc::new_array(allocator, Vec3, self.positions.len);
    } else {
        self.normals[..] = (Vec3){};
    }
    usz corners = triangle_count(self) * 3;
    for (usz slot = 0; slot < corners; slot += 3) {
        uint a = corner(self, slot);
        uint b = corner(self, slot + 1);
        uint c = corner(self, slot + 2);
        Vec3 face = (self.positions[b] - self.positions[a]).cross(self.positions[c] - self.positions[a]);
        if (smooth) {
            self.normals[a] += face;
            self.normals[b] += face;
            self.normals[c] += face;
        } else {
            self.normals[a] = face;
            self.normals[b] = face;
            self.normals[c] = face;
        }
    }
    foreach (&normal : self.normals) {
        if (normal.length() > 0) *normal = normal.normalize();
    }
}

<*
 Write per-vertex tangents with handedness in w from normals and uv0.
 @param allocator : "Allocates tangents when the geometry has none."
 @require self.topology == Topology.TRIANGLES
 @require self.normals.len == self.positions.len, self.uv0.len == self.positions.len
*>
fn void Geometry.compute_tangents(&self, Allocator allocator) {
    if (!self.tangents.len) {
        self.tangents = alloc::new_array(allocator, Vec4, self.positions.len);
    }
    @pool() {
        Vec3[] tangent_sum = alloc::new_array(tmem, Vec3, self.positions.len);
        Vec3[] bitangent_sum = alloc::new_array(tmem, Vec3, self.positions.len);
        usz corners = triangle_count(self) * 3;
        for (usz slot = 0; slot < corners; slot += 3) {
            uint a = corner(self, slot);
            uint b = corner(self, slot + 1);
            uint c = corner(self, slot + 2);
            Vec3 edge_1 = self.positions[b] - self.positions[a];
            Vec3 edge_2 = self.positions[c] - self.positions[a];
            Vec2 delta_1 = self.uv0[b] - self.uv0[a];
            Vec2 delta_2 = self.uv0[c] - self.uv0[a];
            float area = delta_1.x * delta_2.y - delta_2.x * delta_1.y;
            if (area == 0) continue;
            float inverse_area = 1.0f / area;
            Vec3 tangent = (edge_1 * delta_2.y - edge_2 * delta_1.y) * inverse_area;
            Vec3 bitangent = (edge_2 * delta_1.x - edge_1 * delta_2.x) * inverse_area;
            tangent_sum[a] += tangent;
            tangent_sum[b] += tangent;
            tangent_sum[c] += tangent;
            bitangent_sum[a] += bitangent;
            bitangent_sum[b] += bitangent;
            bitangent_sum[c] += bitangent;
        }
        foreach (index, normal : self.normals) {
            Vec3 tangent = tangent_sum[index];
            Vec3 orthogonal = tangent - normal * normal.dot(tangent);
            if (orthogonal.length() > 0) orthogonal = orthogonal.normalize();
            float handedness = normal.cross(orthogonal).dot(bitangent_sum[index]) < 0 ? -1.0f : 1.0f;
            self.tangents[index] = { orthogonal.x, orthogonal.y, orthogonal.z, handedness };
        }
    };
}

<*
 Give every triangle corner its own vertex and drop the indices.
 Old arrays stay owned by the caller.
 @param allocator : "Allocates the unrolled streams."
 @require self.topology == Topology.TRIANGLES, self.indices.len > 0
*>
fn void Geometry.unindex(&self, Allocator allocator) {
    uint[] indices = self.indices;
    self.positions = unroll(allocator, indices, self.positions);
    self.normals = unroll(allocator, indices, self.normals);
    self.tangents = unroll(allocator, indices, self.tangents);
    self.uv0 = unroll(allocator, indices, self.uv0);
    self.uv1 = unroll(allocator, indices, self.uv1);
    self.colors = unroll(allocator, indices, self.colors);
    self.joints = unroll(allocator, indices, self.joints);
    self.weights = unroll(allocator, indices, self.weights);
    foreach (&target : self.targets) {
        target.position_deltas = unroll(allocator, indices, target.position_deltas);
        target.normal_deltas = unroll(allocator, indices, target.normal_deltas);
    }
    if (self.custom_data.len) {
        usz stride = self.custom_stride;
        char[] unrolled = alloc::new_array(allocator, char, (sz)(stride * indices.len));
        foreach (slot, index : indices) {
            unrolled[(usz)slot * stride : stride] = self.custom_data[index * stride : stride];
        }
        self.custom_data = unrolled;
    }
    self.indices = {};
}

<*
 Apply a matrix to positions, normals and tangents, then finalize.
 @param model : "Affine; a mirroring matrix does not flip the winding."
 @require self.positions.len > 0
*>
fn void Geometry.transform(&self, Mat4 model) {
    Mat3 normal_transform = maths::normal_matrix(model);
    foreach (&position : self.positions) *position = maths::transform_point(model, *position);
    foreach (&normal : self.normals) *normal = normal_transform.apply(*normal).normalize();
    foreach (&tangent : self.tangents) {
        Vec3 direction = maths::transform_dir(model, tangent.xyz).normalize();
        *tangent = { direction.x, direction.y, direction.z, tangent.w };
    }
    self.finalize();
}

<*
 Reverse the winding of every triangle.
 @require self.topology == Topology.TRIANGLES
*>
fn void Geometry.flip_winding(&self) {
    usz corners = triangle_count(self) * 3;
    for (usz slot = 0; slot < corners; slot += 3) {
        if (self.indices.len) {
            @swap(self.indices[slot + 1], self.indices[slot + 2]);
            continue;
        }
        swap_vertices(self, slot + 1, slot + 2);
    }
}

<*
 Concatenate the parts into one geometry with rebased indices.
 Keeps normals, tangents, uv0, uv1 and colors only when every part has them.
 @param parts : "Same topology; every part has positions."
 @require parts.len > 0
*>
fn Geometry merge(Allocator allocator, Geometry[] parts) {
    sz vertex_count;
    sz index_count;
    bool has_normals = true;
    bool has_tangents = true;
    bool has_uv0 = true;
    bool has_uv1 = true;
    bool has_colors = true;
    foreach (&part : parts) {
        vertex_count += (sz)part.positions.len;
        index_count += (sz)(part.indices.len ? part.indices.len : part.positions.len);
        has_normals = has_normals && part.normals.len == part.positions.len;
        has_tangents = has_tangents && part.tangents.len == part.positions.len;
        has_uv0 = has_uv0 && part.uv0.len == part.positions.len;
        has_uv1 = has_uv1 && part.uv1.len == part.positions.len;
        has_colors = has_colors && part.colors.len == part.positions.len;
    }

    Geometry merged = {
        .topology  = parts[0].topology,
        .positions = alloc::new_array(allocator, Vec3, vertex_count),
        .normals   = has_normals ? alloc::new_array(allocator, Vec3, vertex_count) : (Vec3[]){},
        .tangents  = has_tangents ? alloc::new_array(allocator, Vec4, vertex_count) : (Vec4[]){},
        .uv0       = has_uv0 ? alloc::new_array(allocator, Vec2, vertex_count) : (Vec2[]){},
        .uv1       = has_uv1 ? alloc::new_array(allocator, Vec2, vertex_count) : (Vec2[]){},
        .colors    = has_colors ? alloc::new_array(allocator, Vec4, vertex_count) : (Vec4[]){},
        .indices   = alloc::new_array(allocator, uint, index_count),
    };

    usz vertex_base;
    usz index_base;
    foreach (&part : parts) {
        usz count = part.positions.len;
        merged.positions[vertex_base : count] = part.positions[..];
        if (has_normals) merged.normals[vertex_base : count] = part.normals[..];
        if (has_tangents) merged.tangents[vertex_base : count] = part.tangents[..];
        if (has_uv0) merged.uv0[vertex_base : count] = part.uv0[..];
        if (has_uv1) merged.uv1[vertex_base : count] = part.uv1[..];
        if (has_colors) merged.colors[vertex_base : count] = part.colors[..];
        usz part_indices = part.indices.len ? part.indices.len : count;
        for (usz slot = 0; slot < part_indices; slot++) {
            merged.indices[index_base + slot] = (uint)vertex_base + corner(part, slot);
        }
        vertex_base += count;
        index_base += part_indices;
    }
    merged.finalize();
    return merged;
}

fn usz triangle_count(Geometry* geometry) @local {
    return (geometry.indices.len ? geometry.indices.len : geometry.positions.len) / 3;
}

fn uint corner(Geometry* geometry, usz slot) @local {
    return geometry.indices.len ? geometry.indices[slot] : (uint)slot;
}

macro unroll(Allocator allocator, uint[] indices, slice) @local {
    var $Element = $Typeof(slice[0]);
    if (!slice.len) return ($Element[]){};
    $Element[] unrolled = alloc::new_array(allocator, $Element, indices.len);
    foreach (slot, index : indices) unrolled[slot] = slice[index];
    return unrolled;
}

fn void swap_vertices(Geometry* geometry, usz first, usz second) @local {
    @swap(geometry.positions[first], geometry.positions[second]);
    if (geometry.normals.len) @swap(geometry.normals[first], geometry.normals[second]);
    if (geometry.tangents.len) @swap(geometry.tangents[first], geometry.tangents[second]);
    if (geometry.uv0.len) @swap(geometry.uv0[first], geometry.uv0[second]);
    if (geometry.uv1.len) @swap(geometry.uv1[first], geometry.uv1[second]);
    if (geometry.colors.len) @swap(geometry.colors[first], geometry.colors[second]);
    if (geometry.joints.len) @swap(geometry.joints[first], geometry.joints[second]);
    if (geometry.weights.len) @swap(geometry.weights[first], geometry.weights[second]);
    foreach (&target : geometry.targets) {
        @swap(target.position_deltas[first], target.position_deltas[second]);
        if (target.normal_deltas.len) @swap(target.normal_deltas[first], target.normal_deltas[second]);
    }
    if (geometry.custom_data.len) {
        usz stride = geometry.custom_stride;
        for (usz byte = 0; byte < stride; byte++) {
            @swap(geometry.custom_data[first * stride + byte], geometry.custom_data[second * stride + byte]);
        }
    }
}
