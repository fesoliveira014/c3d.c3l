module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import gltf;
import std::math;

const usz VEC2_COMPONENTS @private = 2;
const usz VEC3_COMPONENTS @private = 3;
const usz VEC4_COMPONENTS @private = 4;

alias PrimitiveCountFn @private = fn usz (usz entries);
alias CornerFn @private = fn usz (usz primitive, usz corner, usz entries);

fn void? convert_geometries(Importer* importer) @private {
    foreach (usz mesh_index, &mesh : importer.data.meshes) {
        foreach (usz primitive_index, &primitive : mesh.primitives) {
            usz slot = importer.mesh_offsets[mesh_index] + primitive_index;
            importer.geometries[slot] = convert_primitive(importer, mesh, mesh_index, primitive_index)!;
        }
    }
    return;
}

fn GeometryId? convert_primitive(
    Importer* importer,
    gltf::Mesh* mesh,
    usz mesh_index,
    usz primitive_index,
) @private {
    gltf::Primitive* primitive = &mesh.primitives[primitive_index];
    if (primitive.has_draco_mesh_compression) return c3d::UNSUPPORTED~;
    foreach (&attribute : primitive.attributes) {
        if (compressed(attribute.data)) return c3d::UNSUPPORTED~;
    }
    if (primitive.indices && compressed(primitive.indices)) return c3d::UNSUPPORTED~;

    gltf::Accessor* positions = primitive.find_accessor(gltf::AttributeType.POSITION, 0);
    if (!positions || !positions.count) return c3d::ASSET_FORMAT_ERROR~;
    usz vertex_count = positions.count;

    Allocator allocator = importer.assets.allocator;
    Geometry geometry;
    defer catch free_geometry_arrays(allocator, &geometry);

    foreach (&attribute : primitive.attributes) {
        switch (attribute.type) {
            case POSITION:
                if (attribute.index == 0) geometry.positions = read_vec3(importer, attribute.data, vertex_count)!;
            case NORMAL:
                if (attribute.index == 0) geometry.normals = read_vec3(importer, attribute.data, vertex_count)!;
            case TANGENT:
                if (attribute.index == 0) geometry.tangents = read_vec4(importer, attribute.data, vertex_count)!;
            case TEXCOORD:
                if (attribute.index == 0) geometry.uv0 = read_vec2(importer, attribute.data, vertex_count)!;
                if (attribute.index == 1) geometry.uv1 = read_vec2(importer, attribute.data, vertex_count)!;
            case COLOR:
                if (attribute.index == 0) geometry.colors = read_colors(importer, attribute.data, vertex_count)!;
            case JOINTS:
                if (attribute.index == 0) geometry.joints = read_joints(importer, attribute.data, vertex_count)!;
            case WEIGHTS:
                if (attribute.index == 0) geometry.weights = read_vec4(importer, attribute.data, vertex_count)!;
            case INVALID:
            case CUSTOM:
            case MAX_ENUM:
                break;
        }
    }
    if ((geometry.joints.len > 0) != (geometry.weights.len > 0)) return c3d::ASSET_FORMAT_ERROR~;
    if (primitive.indices) geometry.indices = read_indices(importer, primitive.indices)!;
    convert_topology(allocator, &geometry, primitive.type, vertex_count)!;
    read_morph_targets(importer, &geometry, mesh, primitive, vertex_count)!;

    if (geometry.topology == Topology.TRIANGLES && !geometry.normals.len) geometry.compute_normals(allocator);
    bool wants_tangents = importer.options.generate_tangents && geometry.topology == Topology.TRIANGLES
        && !geometry.tangents.len && geometry.uv0.len && has_normal_map(importer, primitive);
    if (wants_tangents) geometry.compute_tangents(allocator);
    geometry.finalize();

    String key = string::tformat("%s#mesh/%d/%d", importer.key, mesh_index, primitive_index);
    return importer.assets.add_geometry_owned(&geometry, key);
}

fn bool compressed(gltf::Accessor* accessor) @private {
    return accessor.buffer_view && accessor.buffer_view.has_meshopt_compression;
}

fn bool has_normal_map(Importer* importer, gltf::Primitive* primitive) @private {
    if (!primitive.material) return false;
    MaterialId material_id = importer.materials[gltf::material_index(importer.data, primitive.material)];
    material::Material* material = &importer.assets.material(material_id).data;
    switch (material.kind) {
        case STANDARD:
            return material.standard.normal_map.texture.asset.generation != 0;
        case PHYSICAL:
            return material.physical.standard.normal_map.texture.asset.generation != 0
                || material.physical.clearcoat_normal_map.texture.asset.generation != 0;
        case BASIC:
        case TOON:
            return false;
    }
}

fn float[]? read_floats(
    Importer* importer,
    gltf::Accessor* accessor,
    usz components,
    usz count,
) @private {
    if (accessor.count != count || accessor.component_count() != components) return c3d::ASSET_FORMAT_ERROR~;
    float[]? floats = accessor.unpack_floats(importer.assets.allocator);
    if (catch excuse = floats) return load_fault(excuse)~;
    return floats;
}

fn Vec2[]? read_vec2(Importer* importer, gltf::Accessor* accessor, usz count) @private {
    float[] floats = read_floats(importer, accessor, VEC2_COMPONENTS, count)!;
    return ((Vec2*)floats.ptr)[:count];
}

fn Vec3[]? read_vec3(Importer* importer, gltf::Accessor* accessor, usz count) @private {
    float[] floats = read_floats(importer, accessor, VEC3_COMPONENTS, count)!;
    return ((Vec3*)floats.ptr)[:count];
}

fn Vec4[]? read_vec4(Importer* importer, gltf::Accessor* accessor, usz count) @private {
    float[] floats = read_floats(importer, accessor, VEC4_COMPONENTS, count)!;
    return ((Vec4*)floats.ptr)[:count];
}

fn Vec4[]? read_colors(Importer* importer, gltf::Accessor* accessor, usz count) @private {
    if (accessor.component_count() == VEC4_COMPONENTS) return read_vec4(importer, accessor, count);
    Allocator allocator = importer.assets.allocator;
    Vec3[] rgb = read_vec3(importer, accessor, count)!;
    defer alloc::free(allocator, rgb.ptr);
    Vec4[] colors = alloc::new_array(allocator, Vec4, (sz)count);
    foreach (index, color : rgb) colors[index] = { color.x, color.y, color.z, 1 };
    return colors;
}

fn ushort[<4>][]? read_joints(Importer* importer, gltf::Accessor* accessor, usz count) @private {
    if (accessor.count != count || accessor.component_count() != VEC4_COMPONENTS) return c3d::ASSET_FORMAT_ERROR~;
    Allocator allocator = importer.assets.allocator;
    ushort[<4>][] joints = alloc::new_array(allocator, ushort[<4>], (sz)count);
    defer catch alloc::free(allocator, joints.ptr);
    uint[VEC4_COMPONENTS] element;
    for (usz index = 0; index < count; index++) {
        if (!accessor.read_uint(index, element[..])) return c3d::ASSET_FORMAT_ERROR~;
        joints[index] = { (ushort)element[0], (ushort)element[1], (ushort)element[2], (ushort)element[3] };
    }
    return joints;
}

fn uint[]? read_indices(Importer* importer, gltf::Accessor* accessor) @private {
    uint[]? indices = accessor.unpack_indices(importer.assets.allocator);
    if (catch excuse = indices) return load_fault(excuse)~;
    return indices;
}

fn void? convert_topology(
    Allocator allocator,
    Geometry* geometry,
    gltf::PrimitiveType type,
    usz vertex_count,
) @private {
    switch (type) {
        case TRIANGLES:
            geometry.topology = Topology.TRIANGLES;
        case LINES:
            geometry.topology = Topology.LINES;
        case POINTS:
            geometry.topology = Topology.POINTS;
        case TRIANGLE_STRIP:
            geometry.topology = Topology.TRIANGLES;
            rewrite_indices(allocator, geometry, vertex_count, &strip_triangle_count, &strip_corner);
        case TRIANGLE_FAN:
            geometry.topology = Topology.TRIANGLES;
            rewrite_indices(allocator, geometry, vertex_count, &strip_triangle_count, &fan_corner);
        case LINE_STRIP:
            geometry.topology = Topology.LINES;
            rewrite_indices(allocator, geometry, vertex_count, &line_strip_segment_count, &line_strip_corner);
        case LINE_LOOP:
            geometry.topology = Topology.LINES;
            rewrite_indices(allocator, geometry, vertex_count, &line_loop_segment_count, &line_strip_corner);
        case INVALID:
        case MAX_ENUM:
            return c3d::ASSET_FORMAT_ERROR~;
    }
    return;
}

fn void rewrite_indices(
    Allocator allocator,
    Geometry* geometry,
    usz vertex_count,
    PrimitiveCountFn primitive_count,
    CornerFn corner,
) @private {
    uint[] source = geometry.indices;
    usz entries = source.len ? source.len : vertex_count;
    usz corners = geometry.topology == Topology.TRIANGLES ? 3 : 2;
    usz primitives = primitive_count(entries);
    uint[] rewritten = alloc::new_array(allocator, uint, (sz)(primitives * corners));
    for (usz primitive = 0; primitive < primitives; primitive++) {
        for (usz slot = 0; slot < corners; slot++) {
            usz entry = corner(primitive, slot, entries);
            rewritten[primitive * corners + slot] = source.len ? source[entry] : (uint)entry;
        }
    }
    alloc::free(allocator, source.ptr);
    geometry.indices = rewritten;
}

fn usz strip_triangle_count(usz entries) @private {
    return entries < 3 ? 0 : entries - 2;
}

fn usz line_strip_segment_count(usz entries) @private {
    return entries < 2 ? 0 : entries - 1;
}

fn usz line_loop_segment_count(usz entries) @private {
    return entries < 2 ? 0 : entries;
}

fn usz strip_corner(usz primitive, usz corner, usz entries) @private {
    // Odd triangles swap their first two corners so the winding stays consistent.
    if (primitive % 2 == 0) return primitive + corner;
    return corner == 0 ? primitive + 1 : (corner == 1 ? primitive : primitive + 2);
}

fn usz fan_corner(usz primitive, usz corner, usz entries) @private {
    return corner == 0 ? 0 : primitive + corner;
}

fn usz line_strip_corner(usz primitive, usz corner, usz entries) @private {
    return (primitive + corner) % entries;
}

fn void? read_morph_targets(
    Importer* importer,
    Geometry* geometry,
    gltf::Mesh* mesh,
    gltf::Primitive* primitive,
    usz vertex_count,
) @private {
    if (!primitive.targets.len) return;
    Allocator allocator = importer.assets.allocator;
    geometry.targets = alloc::new_array(allocator, geometry::MorphTarget, (sz)primitive.targets.len);
    foreach (target_index, &target : primitive.targets) {
        geometry::MorphTarget* morph = &geometry.targets[target_index];
        foreach (&attribute : target.attributes) {
            switch (attribute.type) {
                case POSITION:
                    if (attribute.index == 0) {
                        morph.position_deltas = read_vec3(importer, attribute.data, vertex_count)!;
                    }
                case NORMAL:
                    if (attribute.index == 0) {
                        morph.normal_deltas = read_vec3(importer, attribute.data, vertex_count)!;
                    }
                case INVALID:
                case TANGENT:
                case TEXCOORD:
                case COLOR:
                case JOINTS:
                case WEIGHTS:
                case CUSTOM:
                case MAX_ENUM:
                    break;
            }
        }
        if (morph.position_deltas.len && !morph.normal_deltas.len) {
            morph.normal_deltas = alloc::new_array(allocator, Vec3, (sz)vertex_count);
        }
        if (morph.normal_deltas.len && !morph.position_deltas.len) {
            morph.position_deltas = alloc::new_array(allocator, Vec3, (sz)vertex_count);
        }
        if (target_index < mesh.target_names.len) {
            morph.name = copy_name(allocator, mesh.target_names[target_index]);
        }
    }
    return;
}

fn void free_geometry_arrays(Allocator allocator, Geometry* geometry) @private {
    foreach (&target : geometry.targets) {
        alloc::free(allocator, target.position_deltas.ptr);
        alloc::free(allocator, target.normal_deltas.ptr);
        alloc::free(allocator, target.name.ptr);
    }
    alloc::free(allocator, geometry.targets.ptr);
    alloc::free(allocator, geometry.positions.ptr);
    alloc::free(allocator, geometry.normals.ptr);
    alloc::free(allocator, geometry.tangents.ptr);
    alloc::free(allocator, geometry.uv0.ptr);
    alloc::free(allocator, geometry.uv1.ptr);
    alloc::free(allocator, geometry.colors.ptr);
    alloc::free(allocator, geometry.joints.ptr);
    alloc::free(allocator, geometry.weights.ptr);
    alloc::free(allocator, geometry.indices.ptr);
    *geometry = {};
}

fn String copy_name(Allocator allocator, ZString name) @private {
    if (!name) return {};
    String view = name.str_view();
    return view.len ? view.copy(allocator) : (String){};
}
