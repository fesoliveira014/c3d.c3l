module c3d::geometry;

import c3d;
import c3d::maths;
import std::core::mem::alloc;
import std::math;

const uint NO_TANGENT_VERTEX @private = uint::max;

<* Origin of the tangent stream. *>
enum TangentOrigin {
    NONE,
    AUTHORED,
    GENERATED,
}

<* Tangent origin, raw source UV and published derivation revision. *>
struct TangentProvenance {
    TangentOrigin origin;
    uint uv_set;
    uint derivation_revision;
}

<* Owned complete geometry with generated tangent provenance. *>
struct TangentGeometry {
    Allocator allocator;
    Geometry data;
    TangentProvenance tangent_provenance;
}

<*
 Release every owned geometry stream and leave the owner empty.
 @param [&inout] owner : "All arrays and metadata are owned."
*>
fn void destroy_tangent_geometry(TangentGeometry* owner) {
    Geometry* geometry = &owner.data;

    foreach (&target : geometry.targets) {
        alloc::free(owner.allocator, target.position_deltas.ptr);
        alloc::free(owner.allocator, target.normal_deltas.ptr);
        alloc::free(owner.allocator, target.name.ptr);
    }

    foreach (&channel : geometry.channels) {
        alloc::free(owner.allocator, channel.name.ptr);
        alloc::free(owner.allocator, channel.full_weights.ptr);
    }

    alloc::free(owner.allocator, geometry.positions.ptr);
    alloc::free(owner.allocator, geometry.normals.ptr);
    alloc::free(owner.allocator, geometry.tangents.ptr);
    alloc::free(owner.allocator, geometry.uv0.ptr);
    alloc::free(owner.allocator, geometry.uv1.ptr);
    alloc::free(owner.allocator, geometry.colors.ptr);
    alloc::free(owner.allocator, geometry.joints.ptr);
    alloc::free(owner.allocator, geometry.weights.ptr);
    alloc::free(owner.allocator, geometry.indices.ptr);
    alloc::free(owner.allocator, geometry.targets.ptr);
    alloc::free(owner.allocator, geometry.channels.ptr);
    alloc::free(owner.allocator, geometry.custom_data.ptr);

    *owner = {};
}

<*
 Validate tangent values against their origin without changing them.
 @param [&in] geometry : "Generated zero directions remain valid."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? check_tangent_stream(Geometry* geometry, TangentProvenance provenance = {}) {
    if (!geometry.tangents.len) {
        if (provenance.origin != TangentOrigin.NONE) return c3d::INVALID_ARGUMENT~;
        return;
    }
    if (geometry.tangents.len != geometry.positions.len) return c3d::INVALID_ARGUMENT~;
    if (provenance.origin == TangentOrigin.GENERATED) {
        if (provenance.uv_set > 1 || geometry.normals.len != geometry.positions.len) return c3d::INVALID_ARGUMENT~;
        Vec2[] selected = provenance.uv_set == 0 ? geometry.uv0 : geometry.uv1;
        if (selected.len != geometry.positions.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (tangent : geometry.tangents) {
        if (!finite_tangent_values(tangent) || tangent.w == 0) return c3d::INVALID_ARGUMENT~;
        if (provenance.origin == TangentOrigin.GENERATED) {
            if (tangent.w != -1 && tangent.w != 1) return c3d::INVALID_ARGUMENT~;
        } else if (tangent.x == 0 && tangent.y == 0 && tangent.z == 0) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

<*
 Validate authored tangents and normalize only their handedness signs.
 @param [&inout] geometry : "XYZ values are preserved."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? normalize_tangent_signs(Geometry* geometry) {
    check_tangent_stream(geometry)!;

    foreach (&tangent : geometry.tangents) tangent.w = tangent.w < 0 ? -1 : 1;
}

<*
 Derive tangents from raw UVs and split conflicting source vertices.
 @param [&in] source : "Unchanged; old tangents are discarded."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn TangentGeometry? create_tangent_geometry(Allocator allocator, Geometry* source, uint uv_set = 0) {
    check_tangent_source(source, uv_set)!;

    usz corner_count = source.indices.len ? source.indices.len : source.positions.len;
    usz face_count = corner_count / CORNERS_PER_TRIANGLE;

    MikkVertex[] vertices = @tangent_array(allocator, MikkVertex, source.positions.len)!;
    defer alloc::free(allocator, vertices);
    uint[] input_indices = @tangent_array(allocator, uint, corner_count)!;
    defer alloc::free(allocator, input_indices);
    int[] sizes = @tangent_array(allocator, int, face_count)!;
    defer alloc::free(allocator, sizes);
    int[] offsets = @tangent_array(allocator, int, face_count)!;
    defer alloc::free(allocator, offsets);
    Vec2[] selected = uv_set == 0 ? source.uv0 : source.uv1;

    foreach (index, position : source.positions) {
        Vec3 normal = source.normals[index];
        Vec2 uv = selected[index];
        vertices[index] = {
            .position = { .x = position.x, .y = position.y, .z = position.z },
            .normal = { .x = normal.x, .y = normal.y, .z = normal.z },
            .uv0 = { uv.x, uv.y },
            .uv1 = { uv.x, uv.y },
        };
    }

    foreach (corner, &index : input_indices) *index = source.indices.len ? source.indices[corner] : (uint)corner;

    foreach (face, &size : sizes) {
        *size = CORNERS_PER_TRIANGLE;
        offsets[face] = (int)face * CORNERS_PER_TRIANGLE;
    }

    MikkFullMesh full = {
        .vertices = vertices,
        .indices = input_indices,
        .face_offsets = offsets,
        .face_sizes = sizes,
        .uv_set = uv_set,
    };

    MikkTangent[] corners = mikk_generate_full(allocator, full)!;
    defer alloc::free(allocator, corners);

    usz capacity = math::min(source.positions.len + corner_count, (usz)uint::max);
    uint[] source_vertices = @tangent_array(allocator, uint, capacity)!;
    defer alloc::free(allocator, source_vertices);
    uint[] next_split = @tangent_array(allocator, uint, capacity)!;
    defer alloc::free(allocator, next_split);
    bool[] assigned = @tangent_array(allocator, bool, source.positions.len)!;
    defer alloc::free(allocator, assigned);

    TangentGeometry owner = {
        .allocator = allocator,
        .tangent_provenance = { .origin = TangentOrigin.GENERATED, .uv_set = uv_set },
        .data = { .topology = source.topology, .custom_stride = source.custom_stride, .bounds = source.bounds },
    };
    defer catch destroy_tangent_geometry(&owner);

    owner.data.tangents = @tangent_array(allocator, Vec4, capacity)!;
    if (source.indices.len) owner.data.indices = @tangent_array(allocator, uint, corner_count)!;

    foreach (vertex, &index : source_vertices[:source.positions.len]) {
        *index = (uint)vertex;
        next_split[vertex] = NO_TANGENT_VERTEX;
        owner.data.tangents[vertex] = { 1, 0, 0, -1 };
    }

    usz vertex_count = source.positions.len;

    foreach (corner, source_index : input_indices) {
        MikkTangent generated = corners[corner];
        Vec4 tangent = { generated.direction.x, generated.direction.y, generated.direction.z, generated.sign };
        uint destination = source_index;
        if (!assigned[source_index]) {
            owner.data.tangents[destination] = tangent;
            assigned[source_index] = true;
        } else {
            uint previous = destination;

            while (owner.data.tangents[destination] != tangent) {
                previous = destination;
                destination = next_split[destination];
                if (destination == NO_TANGENT_VERTEX) break;
            }

            if (destination == NO_TANGENT_VERTEX) {
                if (vertex_count == capacity) return c3d::CAPACITY_EXCEEDED~;
                destination = (uint)vertex_count++;
                next_split[previous] = destination;
                next_split[destination] = NO_TANGENT_VERTEX;
                source_vertices[destination] = source_index;
                owner.data.tangents[destination] = tangent;
            }
        }

        if (source.indices.len) owner.data.indices[corner] = destination;
    }

    owner.data.tangents = owner.data.tangents[:vertex_count];
    uint[] remap = source_vertices[:vertex_count];
    owner.data.positions = @remap_tangent_stream(allocator, source.positions, remap)!;
    owner.data.normals = @remap_tangent_stream(allocator, source.normals, remap)!;
    owner.data.uv0 = @remap_tangent_stream(allocator, source.uv0, remap)!;
    owner.data.uv1 = @remap_tangent_stream(allocator, source.uv1, remap)!;
    owner.data.colors = @remap_tangent_stream(allocator, source.colors, remap)!;
    owner.data.joints = @remap_tangent_stream(allocator, source.joints, remap)!;
    owner.data.weights = @remap_tangent_stream(allocator, source.weights, remap)!;

    owner.data.targets = @tangent_array(allocator, MorphTarget, source.targets.len)!;

    foreach (index, target : source.targets) {
        MorphTarget* output = &owner.data.targets[index];
        output.position_deltas = @remap_tangent_stream(allocator, target.position_deltas, remap)!;
        output.normal_deltas = @remap_tangent_stream(allocator, target.normal_deltas, remap)!;
        output.name = copy_tangent_name(allocator, target.name)!;
    }

    owner.data.channels = @tangent_array(allocator, MorphChannel, source.channels.len)!;

    foreach (index, channel : source.channels) {
        MorphChannel* output = &owner.data.channels[index];
        output.name = copy_tangent_name(allocator, channel.name)!;
        output.first_target = channel.first_target;
        output.full_weights = @tangent_array(allocator, float, channel.full_weights.len)!;
        output.full_weights[..] = channel.full_weights[..];
    }

    if (source.custom_data.len) {
        if (vertex_count > (usz)sz::max / source.custom_stride) return c3d::INVALID_ARGUMENT~;

        owner.data.custom_data = @tangent_array(allocator, char, vertex_count * source.custom_stride)!;

        foreach (destination, source_index : remap) {
            owner.data.custom_data[destination * source.custom_stride:source.custom_stride]
              = source.custom_data[(usz)source_index * source.custom_stride:source.custom_stride];
        }
    }

    check_tangent_stream(&owner.data, owner.tangent_provenance)!;

    return owner;
}

macro @remap_tangent_stream(Allocator allocator, source, uint[] remap) @private {
    var $Stream = $Typeof(source);
    if (!source.len) return ($Stream){};

    $Stream result = @tangent_array(allocator, $Typeof(source[0]), remap.len)!;

    foreach (destination, source_index : remap) result[destination] = source[source_index];

    return result;
}

fn String? copy_tangent_name(Allocator allocator, String name) @private {
    char[] result = @tangent_array(allocator, char, name.len)!;
    result[..] = name[..];

    return (String)result;
}

fn bool finite_tangent_values(Vec4 values) @private {
    return math::is_finite(values.x) && math::is_finite(values.y)
      && math::is_finite(values.z) && math::is_finite(values.w);
}

macro @check_tangent_vertices(values, usz vertex_count) @private {
    if (values.len && values.len != vertex_count) return c3d::INVALID_ARGUMENT~;

    foreach (value : values) {
        foreach (component : value) {
            if (!math::is_finite(component)) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? check_tangent_source(Geometry* source, uint uv_set) @private {
    if (source.topology != Topology.TRIANGLES || uv_set > 1) return c3d::UNSUPPORTED~;

    usz vertex_count = source.positions.len;
    if (!vertex_count || source.normals.len != vertex_count) return c3d::INVALID_ARGUMENT~;
    Vec2[] selected = uv_set == 0 ? source.uv0 : source.uv1;
    if (!selected.len) return c3d::UNSUPPORTED~;
    usz corner_count = source.indices.len ? source.indices.len : vertex_count;
    if (corner_count % CORNERS_PER_TRIANGLE != 0) return c3d::INVALID_ARGUMENT~;
    if (vertex_count > uint::max || corner_count > int::max
      || corner_count / CORNERS_PER_TRIANGLE > (usz)(int::max >> 2)
      || vertex_count > (usz)sz::max - corner_count) return c3d::INVALID_ARGUMENT~;

    @check_tangent_vertices(source.positions, vertex_count)!;
    @check_tangent_vertices(source.normals, vertex_count)!;
    @check_tangent_vertices(source.uv0, vertex_count)!;
    @check_tangent_vertices(source.uv1, vertex_count)!;
    @check_tangent_vertices(source.colors, vertex_count)!;
    @check_tangent_vertices(source.weights, vertex_count)!;
    if ((source.joints.len && source.joints.len != vertex_count)
      || (source.joints.len > 0) != (source.weights.len > 0)) return c3d::INVALID_ARGUMENT~;

    foreach (weight : source.weights) {
        foreach (component : weight) if (component < 0) return c3d::INVALID_ARGUMENT~;
    }

    foreach (index : source.indices) if (index >= vertex_count) return c3d::INVALID_ARGUMENT~;

    if (source.custom_data.len && (!source.custom_stride || vertex_count > (usz)sz::max / source.custom_stride
      || source.custom_data.len != vertex_count * source.custom_stride)) return c3d::INVALID_ARGUMENT~;

    foreach (target : source.targets) {
        @check_tangent_vertices(target.position_deltas, vertex_count)!;
        @check_tangent_vertices(target.normal_deltas, vertex_count)!;
    }

    foreach (channel : source.channels) {
        if (channel.first_target > source.targets.len
          || channel.full_weights.len > source.targets.len - channel.first_target) return c3d::INVALID_ARGUMENT~;

        foreach (weight : channel.full_weights) if (!math::is_finite(weight)) return c3d::INVALID_ARGUMENT~;
    }
}
