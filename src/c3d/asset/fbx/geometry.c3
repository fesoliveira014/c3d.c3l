module c3d::asset::fbx;

import c3d;
import c3d::asset;
import c3d::geometry;
import std::math;
import ufbx;

const uint TRIANGLE_CORNERS @private = 3;
const usz MAX_SKIN_INFLUENCES @private = 4;
const usz MAX_STREAMS @private = 7;

struct CornerStreams @private {
    vector::Vec3[] positions;
    vector::Vec3[] normals;
    vector::Vec2[] uv0;
    vector::Vec2[] uv1;
    vector::Vec4[] tangents;
    vector::Vec4[] colors;
    uint[]         sources;
}

fn void? convert_geometries(Importer* importer) @private {
    foreach (mesh : importer.scene.meshes) {
        if (mesh.skin_deformers.len > 1) return c3d::UNSUPPORTED~;
        usz first_slot = importer.part_offsets[mesh.typed_id];
        foreach (usz part_index, &part : mesh.material_parts) {
            if (!part.num_triangles) continue;
            importer.geometries[first_slot + part_index] = convert_part(
                importer:   importer,
                mesh:       mesh,
                part:       part,
                part_index: part_index,
            )!;
        }
    }
    return;
}

fn GeometryId? convert_part(
    Importer* importer,
    ufbx::Mesh* mesh,
    ufbx::MeshPart* part,
    usz part_index,
) @private {
    alloc::Allocator allocator = importer.assets.allocator;
    usz corner_count = part.num_triangles * TRIANGLE_CORNERS;
    CornerStreams streams = corner_streams(mesh, part, corner_count);

    ufbx::VertexStream[MAX_STREAMS] stream_table;
    usz stream_count;
    stream_table[stream_count++] = vertex_stream(streams.positions, corner_count);
    stream_table[stream_count++] = vertex_stream(streams.normals, corner_count);
    if (streams.uv0.len) stream_table[stream_count++] = vertex_stream(streams.uv0, corner_count);
    if (streams.uv1.len) stream_table[stream_count++] = vertex_stream(streams.uv1, corner_count);
    if (streams.tangents.len) stream_table[stream_count++] = vertex_stream(streams.tangents, corner_count);
    if (streams.colors.len) stream_table[stream_count++] = vertex_stream(streams.colors, corner_count);
    stream_table[stream_count++] = vertex_stream(streams.sources, corner_count);

    Geometry geometry = {
        .topology = Topology.TRIANGLES,
        .indices  = alloc::new_array(allocator, uint, (sz)corner_count),
    };
    defer catch asset::free_geometry(allocator, &geometry);
    usz? merged = ufbx::generate_indices(stream_table[:stream_count], geometry.indices);
    if (catch merged) return c3d::ASSET_FORMAT_ERROR~;
    usz vertex_count = merged;
    uint[] sources = streams.sources[:vertex_count];

    geometry.positions = copy_prefix(allocator, streams.positions, vertex_count);
    geometry.normals = copy_prefix(allocator, streams.normals, vertex_count);
    geometry.uv0 = copy_prefix(allocator, streams.uv0, vertex_count);
    geometry.uv1 = copy_prefix(allocator, streams.uv1, vertex_count);
    geometry.tangents = copy_prefix(allocator, streams.tangents, vertex_count);
    geometry.colors = copy_prefix(allocator, streams.colors, vertex_count);
    if (mesh.skin_deformers.len) {
        write_skin_streams(
            allocator: allocator,
            geometry:  &geometry,
            skin:      mesh.skin_deformers[0],
            sources:   sources,
        )!;
    }
    write_morph_targets(
        allocator: allocator,
        geometry:  &geometry,
        mesh:      mesh,
        sources:   sources,
    )!;

    bool wants_tangents = importer.options.generate_tangents && !geometry.tangents.len && geometry.uv0.len
        && part_has_normal_map(mesh, part);
    if (wants_tangents) geometry.compute_tangents(allocator);
    geometry.finalize();

    String key = string::tformat("%s#mesh/%d/%d", importer.key, mesh.typed_id, part_index);
    return importer.assets.add_geometry_owned(&geometry, key);
}

fn CornerStreams corner_streams(ufbx::Mesh* mesh, ufbx::MeshPart* part, usz corner_count) @private {
    bool has_tangents = mesh.vertex_tangent.exists && mesh.vertex_bitangent.exists;
    CornerStreams streams = {
        .positions = alloc::new_array(tmem, vector::Vec3, (sz)corner_count),
        .normals   = alloc::new_array(tmem, vector::Vec3, (sz)corner_count),
        .uv0       = mesh.uv_sets.len > 0 ? alloc::new_array(tmem, vector::Vec2, (sz)corner_count) : {},
        .uv1       = mesh.uv_sets.len > 1 ? alloc::new_array(tmem, vector::Vec2, (sz)corner_count) : {},
        .tangents  = has_tangents ? alloc::new_array(tmem, vector::Vec4, (sz)corner_count) : {},
        .colors    = mesh.color_sets.len > 0 ? alloc::new_array(tmem, vector::Vec4, (sz)corner_count) : {},
        .sources   = alloc::new_array(tmem, uint, (sz)corner_count),
    };

    uint[] triangle = alloc::new_array(tmem, uint, (sz)(mesh.max_face_triangles * TRIANGLE_CORNERS));
    usz corner;
    foreach (face_index : part.face_indices) {
        uint triangles = ufbx::triangulate_face(triangle, mesh, mesh.faces[face_index]);
        for (uint slot = 0; slot < triangles * TRIANGLE_CORNERS; slot++) {
            write_corner(
                streams: &streams,
                corner:  corner++,
                mesh:    mesh,
                index:   triangle[slot],
            );
        }
    }
    return streams;
}

fn void write_corner(CornerStreams* streams, usz corner, ufbx::Mesh* mesh, uint index) @private {
    vector::Vec3 normal = narrow_vec3(mesh.vertex_normal.values[mesh.vertex_normal.indices[index]]);
    streams.positions[corner] = narrow_vec3(mesh.vertex_position.values[mesh.vertex_position.indices[index]]);
    streams.normals[corner] = normal;
    streams.sources[corner] = mesh.vertex_indices[index];
    if (streams.uv0.len) streams.uv0[corner] = flipped_uv(&mesh.uv_sets[0].vertex_uv, index);
    if (streams.uv1.len) streams.uv1[corner] = flipped_uv(&mesh.uv_sets[1].vertex_uv, index);
    if (streams.colors.len) {
        ufbx::VertexVec4* colors = &mesh.color_sets[0].vertex_color;
        ufbx::Vec4 color = colors.values[colors.indices[index]];
        streams.colors[corner] = { (float)color.x, (float)color.y, (float)color.z, (float)color.w };
    }
    if (streams.tangents.len) {
        vector::Vec3 tangent = narrow_vec3(mesh.vertex_tangent.values[mesh.vertex_tangent.indices[index]]);
        vector::Vec3 bitangent = narrow_vec3(mesh.vertex_bitangent.values[mesh.vertex_bitangent.indices[index]]);
        // The v flip mirrors the tangent frame, so the handedness sign is inverted.
        float handedness = normal.cross(tangent).dot(bitangent) < 0 ? 1.0f : -1.0f;
        streams.tangents[corner] = { tangent.x, tangent.y, tangent.z, handedness };
    }
}

fn vector::Vec2 flipped_uv(ufbx::VertexVec2* uvs, uint index) @private {
    // FBX puts the UV origin at the bottom left; c3d decodes images top row first.
    ufbx::Vec2 uv = uvs.values[uvs.indices[index]];
    return { (float)uv.x, 1 - (float)uv.y };
}

fn vector::Vec3 narrow_vec3(ufbx::Vec3 value) @private {
    return { (float)value.x, (float)value.y, (float)value.z };
}

macro ufbx::VertexStream vertex_stream(slice, usz vertex_count) @private {
    return { .data = slice.ptr, .vertex_count = vertex_count, .vertex_size = @sizeof(slice[0]) };
}

macro copy_prefix(alloc::Allocator allocator, slice, usz count) @private {
    var $Element = $Typeof(slice[0]);
    if (!slice.len) return ($Element[]){};
    $Element[] copy = alloc::new_array(allocator, $Element, (sz)count);
    copy[..] = slice[:count];
    return copy;
}

fn bool part_has_normal_map(ufbx::Mesh* mesh, ufbx::MeshPart* part) @private {
    if (part.index >= mesh.materials.len) return false;
    return mesh.materials[part.index].pbr.normal_map.texture != null;
}

fn void? write_skin_streams(
    alloc::Allocator allocator,
    Geometry* geometry,
    ufbx::SkinDeformer* skin,
    uint[] sources,
) @private {
    if (skin.clusters.len >= ushort::max) return c3d::UNSUPPORTED~;
    ushort rigid_joint = (ushort)skin.clusters.len;
    geometry.joints = alloc::new_array(allocator, ushort[<4>], sources.len);
    geometry.weights = alloc::new_array(allocator, vector::Vec4, sources.len);
    foreach (vertex, source : sources) {
        ufbx::SkinVertex influence = skin.vertices[source];
        usz count = math::min((usz)influence.num_weights, MAX_SKIN_INFLUENCES);
        float total;
        for (usz slot = 0; slot < count; slot++) total += (float)skin.weights[influence.weight_begin + slot].weight;
        if (total <= 0) {
            geometry.joints[vertex] = { rigid_joint, 0, 0, 0 };
            geometry.weights[vertex] = { 1, 0, 0, 0 };
            continue;
        }
        for (usz slot = 0; slot < count; slot++) {
            ufbx::SkinWeight weight = skin.weights[influence.weight_begin + slot];
            geometry.joints[vertex][slot] = (ushort)weight.cluster_index;
            geometry.weights[vertex][slot] = (float)weight.weight / total;
        }
    }
    return;
}

fn void? write_morph_targets(
    alloc::Allocator allocator,
    Geometry* geometry,
    ufbx::Mesh* mesh,
    uint[] sources,
) @private {
    usz channels = channel_count(mesh);
    if (!channels) return;
    usz targets;
    @each_channel(mesh; ufbx::BlendChannel* channel) {
        targets += channel.keyframes.len;
    };
    geometry.channels = alloc::new_array(allocator, MorphChannel, (sz)channels);
    geometry.targets = alloc::new_array(allocator, MorphTarget, (sz)targets);

    vector::Vec3[] dense_positions = alloc::new_array(tmem, vector::Vec3, (sz)mesh.num_vertices);
    vector::Vec3[] dense_normals = alloc::new_array(tmem, vector::Vec3, (sz)mesh.num_vertices);
    usz channel_slot;
    usz target_slot;
    @each_channel(mesh; ufbx::BlendChannel* channel) {
        MorphChannel* morph_channel = &geometry.channels[channel_slot++];
        morph_channel.name = copy_name(allocator, channel.name);
        morph_channel.first_target = (uint)target_slot;
        morph_channel.full_weights = alloc::new_array(allocator, float, channel.keyframes.len);
        foreach (key_index, &keyframe : channel.keyframes) {
            float full_weight = (float)keyframe.target_weight;
            bool ascending = key_index == 0 || full_weight > morph_channel.full_weights[key_index - 1];
            if (full_weight == 0 || !math::is_finite(full_weight) || !ascending) return c3d::ASSET_FORMAT_ERROR~;
            morph_channel.full_weights[key_index] = full_weight;
            geometry.targets[target_slot++] = shape_target(
                allocator:       allocator,
                shape:           keyframe.shape,
                sources:         sources,
                dense_positions: dense_positions,
                dense_normals:   dense_normals,
            );
        }
    };
    return;
}

fn MorphTarget shape_target(
    alloc::Allocator allocator,
    ufbx::BlendShape* shape,
    uint[] sources,
    vector::Vec3[] dense_positions,
    vector::Vec3[] dense_normals,
) @private {
    dense_positions[..] = (vector::Vec3){};
    dense_normals[..] = (vector::Vec3){};
    for (usz offset = 0; offset < shape.num_offsets; offset++) {
        uint vertex = shape.offset_vertices[offset];
        if (vertex >= dense_positions.len) continue;
        dense_positions[vertex] = narrow_vec3(shape.position_offsets[offset]);
        if (shape.normal_offsets.len) dense_normals[vertex] = narrow_vec3(shape.normal_offsets[offset]);
    }

    MorphTarget target = {
        .position_deltas = alloc::new_array(allocator, vector::Vec3, sources.len),
        .normal_deltas   = alloc::new_array(allocator, vector::Vec3, sources.len),
        .name            = copy_name(allocator, shape.name),
    };
    foreach (index, source : sources) {
        target.position_deltas[index] = dense_positions[source];
        target.normal_deltas[index] = dense_normals[source];
    }
    return target;
}
