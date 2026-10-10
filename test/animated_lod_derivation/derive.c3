module c3d::test::animated_lod_derivation;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import std::collections::list;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::io::path;
import std::math;

const uint FILE_MAGIC @private = 0x444f4c41;
const uint FORMAT_VERSION @private = 1;
const uint DERIVATION_VERSION @private = 1;
const uint ENDIAN_MARKER @private = 0x01020304;
const uint HEADER_WORDS @private = 24;
const uint TRIANGLE_CORNERS @private = 3;
const uint EXPECTED_PRIMITIVES @private = 2;
const uint EXPECTED_JOINTS @private = 53;
const char[32] SOURCE_DIGEST @private = {
    0x27, 0x2d, 0x5c, 0x1e, 0x2c, 0x27, 0xf5, 0x66,
    0x59, 0x5e, 0xce, 0x27, 0xb6, 0x98, 0x59, 0x35,
    0xd4, 0x2d, 0xce, 0xe1, 0xda, 0xce, 0xe1, 0xb3,
    0x20, 0xaf, 0x9f, 0x0c, 0x40, 0xd5, 0xc9, 0x7c,
};
const String HEX_DIGITS @private = "0123456789abcdef";
const String[2][2] FILE_NAMES @private = {
    { "primitive_0_lod_1.bin", "primitive_0_lod_2.bin" },
    { "primitive_1_lod_1.bin", "primitive_1_lod_2.bin" },
};
const uint POSITION_STREAM @private = 1u << 0;
const uint NORMAL_STREAM @private = 1u << 1;
const uint TANGENT_STREAM @private = 1u << 2;
const uint UV0_STREAM @private = 1u << 3;
const uint UV1_STREAM @private = 1u << 4;
const uint COLOR_STREAM @private = 1u << 5;
const uint JOINT_STREAM @private = 1u << 6;
const uint WEIGHT_STREAM @private = 1u << 7;
const uint CUSTOM_STREAM @private = 1u << 8;

struct Selection @private {
    List{uint} vertices;
    List{uint} indices;
    List{uint} faces;
}

struct FixtureBytes @private {
    List{char} bytes;
}

struct FixtureCheck @private {
    char[] bytes;
    usz cursor;
}

fn void FixtureBytes.u32(&self, uint value) {
    for (uint byte = 0; byte < uint::size; byte++) self.bytes.push((char)(value >> (byte * 8)));
}

fn void FixtureBytes.u16(&self, ushort value) {
    for (uint byte = 0; byte < ushort::size; byte++) self.bytes.push((char)(value >> (byte * 8)));
}

fn void FixtureBytes.f32(&self, float value) => self.u32(bitcast(value, uint));

fn void? FixtureCheck.u32(&self, uint expected) {
    if (self.cursor + uint::size > self.bytes.len) return c3d::ASSET_FORMAT_ERROR~;
    uint actual;
    for (uint byte = 0; byte < uint::size; byte++) actual |= (uint)self.bytes[self.cursor++] << (byte * 8);
    if (actual != expected) return c3d::ASSET_FORMAT_ERROR~;
}

fn void? FixtureCheck.u16(&self, ushort expected) {
    if (self.cursor + ushort::size > self.bytes.len) return c3d::ASSET_FORMAT_ERROR~;
    ushort actual;
    for (uint byte = 0; byte < ushort::size; byte++) {
        actual |= (ushort)((uint)self.bytes[self.cursor++] << (byte * 8));
    }
    if (actual != expected) return c3d::ASSET_FORMAT_ERROR~;
}

fn void? FixtureCheck.f32(&self, float expected) => self.u32(bitcast(expected, uint));

fn char[64] digest_hex(char[32] digest) @private {
    char[64] hex;
    for (usz byte = 0; byte < digest.len; byte++) {
        hex[byte * 2] = HEX_DIGITS[digest[byte] >> 4];
        hex[byte * 2 + 1] = HEX_DIGITS[digest[byte] & 15];
    }
    return hex;
}

fn uint source_triangle_count(Geometry* geometry) @private {
    return (uint)(geometry.indices.len ? geometry.indices.len : geometry.positions.len) / TRIANGLE_CORNERS;
}

fn uint source_index(Geometry* geometry, uint corner) @private {
    return geometry.indices.len ? geometry.indices[corner] : corner;
}

fn uint retained_streams(Geometry* geometry) @private {
    uint streams = POSITION_STREAM;
    if (geometry.normals.len) streams |= NORMAL_STREAM;
    if (geometry.tangents.len) streams |= TANGENT_STREAM;
    if (geometry.uv0.len) streams |= UV0_STREAM;
    if (geometry.uv1.len) streams |= UV1_STREAM;
    if (geometry.colors.len) streams |= COLOR_STREAM;
    if (geometry.joints.len) streams |= JOINT_STREAM;
    if (geometry.weights.len) streams |= WEIGHT_STREAM;
    if (geometry.custom_data.len) streams |= CUSTOM_STREAM;
    return streams;
}

fn void? check_source(AssetStore* assets, ModelTemplate* template) @private {
    if (template.meshes.len != EXPECTED_PRIMITIVES || template.skins.len != EXPECTED_PRIMITIVES) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    ModelSkin* first = &template.skins[0];
    Skeleton* reference = &assets.skeleton(first.skeleton).data;
    if (first.joint_nodes.len != EXPECTED_JOINTS || reference.inverse_bind.len != EXPECTED_JOINTS) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    foreach (&skin : template.skins) {
        Skeleton* skeleton = &assets.skeleton(skin.skeleton).data;
        if (skin.joint_nodes[..] != first.joint_nodes[..] || skeleton.inverse_bind.len != reference.inverse_bind.len) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        for (usz joint = 0; joint < reference.inverse_bind.len; joint++) {
            for (usz component = 0; component < reference.inverse_bind[joint].m.len; component++) {
                if (bitcast(skeleton.inverse_bind[joint].m[component], uint)
                  != bitcast(reference.inverse_bind[joint].m[component], uint)) return c3d::ASSET_FORMAT_ERROR~;
            }
        }
    }
    foreach (&mesh : template.meshes) {
        Geometry* geometry = &assets.geometry(mesh.geometry).data;
        if (geometry.topology != Topology.TRIANGLES || !geometry.positions.len
          || (geometry.indices.len ? geometry.indices.len : geometry.positions.len) % TRIANGLE_CORNERS) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        if (geometry.targets.len || geometry.channels.len || mesh.default_morph_weights.len) return c3d::UNSUPPORTED~;
        usz count = (usz)geometry.positions.len;
        if ((geometry.normals.len && geometry.normals.len != count)
          || (geometry.tangents.len && geometry.tangents.len != count)
          || (geometry.uv0.len && geometry.uv0.len != count)
          || (geometry.uv1.len && geometry.uv1.len != count)
          || (geometry.colors.len && geometry.colors.len != count)
          || geometry.joints.len != count || geometry.weights.len != count
          || (geometry.custom_data.len && geometry.custom_data.len != count * geometry.custom_stride)) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        foreach (index : geometry.indices) if (index >= count) return c3d::ASSET_FORMAT_ERROR~;
        bool has_skin;
        foreach (skin : template.skins) has_skin |= skin.mesh_node == mesh.node;
        if (!has_skin) return c3d::ASSET_FORMAT_ERROR~;
    }
}

fn Selection select_faces(Allocator allocator, Geometry* source, uint stride) @private {
    Selection selection;
    selection.vertices.init(allocator);
    selection.indices.init(allocator);
    selection.faces.init(allocator);
    uint[] remap = alloc::new_array(allocator, uint, source.positions.len);
    defer alloc::free(allocator, remap.ptr);
    uint triangles = source_triangle_count(source);
    for (uint face = 0; face < triangles; face += stride) {
        selection.faces.push(face);
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint vertex = source_index(source, face * TRIANGLE_CORNERS + corner);
            if (!remap[vertex]) {
                selection.vertices.push(vertex);
                remap[vertex] = (uint)selection.vertices.len();
            }
            selection.indices.push(remap[vertex] - 1);
        }
    }
    return selection;
}

fn void destroy_selection(Selection* selection) @private {
    selection.faces.free();
    selection.indices.free();
    selection.vertices.free();
    *selection = {};
}

fn ModelSkin* skin_for(ModelTemplate* template, uint mesh_node) @private {
    foreach (&skin : template.skins) if (skin.mesh_node == mesh_node) return skin;
    unreachable();
}

fn uint[HEADER_WORDS] fixture_header(
    ModelTemplate* template,
    GeometryAsset* geometry,
    ModelSkin* skin,
    Selection* selection,
    uint primitive,
    uint level,
) @private {
    Geometry* source = &geometry.data;
    return {
        FILE_MAGIC, FORMAT_VERSION, DERIVATION_VERSION, ENDIAN_MARKER,
        primitive, level, 1u << level, (uint)template.nodes.len,
        skin.mesh_node, (uint)source.positions.len, (uint)source.indices.len, source_triangle_count(source),
        (uint)selection.vertices.len(), (uint)selection.indices.len(), (uint)selection.faces.len(),
        (uint)skin.joint_nodes.len, geometry.joints_u16 ? 16 : 8, 16, retained_streams(source),
        source.custom_stride, (uint)source.targets.len, (uint)source.channels.len, 0, HEADER_WORDS,
    };
}

fn void emit_streams(FixtureBytes* output, Geometry* source, uint[] vertices) @private {
    foreach (vertex : vertices) foreach (value : source.positions[vertex]) output.f32(value);
    if (source.normals.len) foreach (vertex : vertices) foreach (value : source.normals[vertex]) output.f32(value);
    if (source.tangents.len) foreach (vertex : vertices) foreach (value : source.tangents[vertex]) output.f32(value);
    if (source.uv0.len) foreach (vertex : vertices) foreach (value : source.uv0[vertex]) output.f32(value);
    if (source.uv1.len) foreach (vertex : vertices) foreach (value : source.uv1[vertex]) output.f32(value);
    if (source.colors.len) foreach (vertex : vertices) foreach (value : source.colors[vertex]) output.f32(value);
    if (source.joints.len) foreach (vertex : vertices) foreach (value : source.joints[vertex]) output.u16(value);
    if (source.weights.len) foreach (vertex : vertices) foreach (value : source.weights[vertex]) output.f32(value);
    if (source.custom_data.len) {
        foreach (vertex : vertices) {
            usz offset = (usz)vertex * source.custom_stride;
            output.bytes.push_all(source.custom_data[offset:source.custom_stride]);
        }
    }
}

fn void? check_streams(FixtureCheck* check, Geometry* source, uint[] vertices) @private {
    foreach (vertex : vertices) foreach (value : source.positions[vertex]) check.f32(value)!;
    if (source.normals.len) foreach (vertex : vertices) foreach (value : source.normals[vertex]) check.f32(value)!;
    if (source.tangents.len) foreach (vertex : vertices) foreach (value : source.tangents[vertex]) check.f32(value)!;
    if (source.uv0.len) foreach (vertex : vertices) foreach (value : source.uv0[vertex]) check.f32(value)!;
    if (source.uv1.len) foreach (vertex : vertices) foreach (value : source.uv1[vertex]) check.f32(value)!;
    if (source.colors.len) foreach (vertex : vertices) foreach (value : source.colors[vertex]) check.f32(value)!;
    if (source.joints.len) foreach (vertex : vertices) foreach (value : source.joints[vertex]) check.u16(value)!;
    if (source.weights.len) foreach (vertex : vertices) foreach (value : source.weights[vertex]) check.f32(value)!;
    if (source.custom_data.len) {
        foreach (vertex : vertices) {
            usz offset = (usz)vertex * source.custom_stride;
            foreach (value : source.custom_data[offset:source.custom_stride]) {
                if (check.cursor >= check.bytes.len || check.bytes[check.cursor++] != value) {
                    return c3d::ASSET_FORMAT_ERROR~;
                }
            }
        }
    }
}

fn FixtureBytes serialize_fixture(
    Allocator allocator,
    uint[] header,
    Geometry* source,
    ModelSkin* skin,
    Skeleton* skeleton,
    Selection* selection,
) @private {
    FixtureBytes output;
    output.bytes.init(allocator);
    foreach (word : header) output.u32(word);
    output.bytes.push_all(SOURCE_DIGEST[..]);
    foreach (value : source.bounds.min) output.f32(value);
    foreach (value : source.bounds.max) output.f32(value);
    foreach (joint_node : skin.joint_nodes) output.u32(joint_node);
    foreach (binding : skeleton.inverse_bind) foreach (value : binding.m) output.f32(value);
    foreach (face : selection.faces.array_view()) output.u32(face);
    foreach (vertex : selection.vertices.array_view()) output.u32(vertex);
    foreach (index : selection.indices.array_view()) output.u32(index);
    emit_streams(&output, source, selection.vertices.array_view());
    return output;
}

fn void? verify_fixture(
    char[] bytes,
    uint[] header,
    Geometry* source,
    ModelSkin* skin,
    Skeleton* skeleton,
    Selection* selection,
) @private {
    FixtureCheck check = { .bytes = bytes };
    foreach (word : header) check.u32(word)!;
    foreach (byte : SOURCE_DIGEST) {
        if (check.bytes[check.cursor++] != byte) return c3d::ASSET_FORMAT_ERROR~;
    }
    foreach (value : source.bounds.min) check.f32(value)!;
    foreach (value : source.bounds.max) check.f32(value)!;
    foreach (joint_node : skin.joint_nodes) check.u32(joint_node)!;
    foreach (binding : skeleton.inverse_bind) {
        for (uint column = 0; column < 4; column++) {
            for (uint row = 0; row < 4; row++) check.f32(binding.m[column * 4 + row])!;
        }
    }
    foreach (face : selection.faces.array_view()) check.u32(face)!;
    foreach (vertex : selection.vertices.array_view()) check.u32(vertex)!;
    foreach (index : selection.indices.array_view()) check.u32(index)!;
    check_streams(&check, source, selection.vertices.array_view())!;
    if (check.cursor != bytes.len) return c3d::ASSET_FORMAT_ERROR~;
    uint stride = header[6];
    if (!selection.faces.len() || selection.faces.len() >= source_triangle_count(source)) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    foreach (uint face_index, face : selection.faces.array_view()) {
        if (face != face_index * stride) return c3d::ASSET_FORMAT_ERROR~;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint index = selection.indices.get((sz)(face_index * TRIANGLE_CORNERS + corner));
            if (selection.vertices.get(index) != source_index(source, face * TRIANGLE_CORNERS + corner)) {
                return c3d::ASSET_FORMAT_ERROR~;
            }
        }
    }
}

fn String joined_path(String directory, String filename) @private {
    Path root = path::tnew(directory)!!;
    return (String)root.tappend(filename)!!;
}

fn void? derive_all(String input_path, String output_directory, String expected_directory = "") @private {
    char[] input = file::load(mem, input_path)!;
    defer alloc::free(mem, input.ptr);
    char[32] digest = sha256::hash(input);
    if (digest[..] != SOURCE_DIGEST[..]) return c3d::INVALID_ARGUMENT~;
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 4, .max_textures = 8, .max_materials = 4,
        .max_samplers = 8, .max_models = 1, .max_skeletons = 2, .max_clips = 1,
    });
    defer asset::destroy_asset_store(&assets);
    Path source_path = path::tnew(input_path)!;
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
    options.animations = false;
    options.lights = false;
    options.cameras = false;
    options.generate_tangents = false;
    ModelId model = gltf::load_model_memory(
        assets: &assets,
        bytes: input,
        base_dir: (String)source_path.parent()!,
        key: "quaternius_lod_source",
        options: options,
    )!;
    ModelTemplate* template = &assets.model(model).data;
    check_source(&assets, template)!;
    List{char} sums;
    sums.init(mem);
    defer sums.free();
    for (uint primitive = 0; primitive < EXPECTED_PRIMITIVES; primitive++) {
        ModelMesh* mesh = &template.meshes[primitive];
        GeometryAsset* geometry = assets.geometry(mesh.geometry);
        ModelSkin* skin = skin_for(template, mesh.node);
        Skeleton* skeleton = &assets.skeleton(skin.skeleton).data;
        uint previous_triangles = source_triangle_count(&geometry.data);
        for (uint level = 1; level <= 2; level++) {
            Selection selection = select_faces(mem, &geometry.data, 1u << level);
            defer destroy_selection(&selection);
            uint[HEADER_WORDS] header = fixture_header(
                template: template,
                geometry: geometry,
                skin: skin,
                selection: &selection,
                primitive: primitive,
                level: level,
            );
            if (header[14] >= previous_triangles) return c3d::ASSET_FORMAT_ERROR~;
            previous_triangles = header[14];
            FixtureBytes output = serialize_fixture(
                allocator: mem,
                header: header[..],
                source: &geometry.data,
                skin: skin,
                skeleton: skeleton,
                selection: &selection,
            );
            defer output.bytes.free();
            char[] bytes = output.bytes.array_view();
            verify_fixture(
                bytes: bytes,
                header: header[..],
                source: &geometry.data,
                skin: skin,
                skeleton: skeleton,
                selection: &selection,
            )!;
            String filename = FILE_NAMES[primitive][level - 1];
            file::save(joined_path(output_directory, filename), bytes)!;
            if (expected_directory.len) {
                char[] expected = file::load(mem, joined_path(expected_directory, filename))!;
                defer alloc::free(mem, expected.ptr);
                if (bytes != expected) return c3d::ASSET_FORMAT_ERROR~;
            }
            char[64] hex = digest_hex(sha256::hash(bytes));
            sums.push_all(hex[..]);
            sums.push_all("  ");
            sums.push_all(filename);
            sums.push('\n');
            io::printfn("%s: selected triangles %s.", filename, header[14]);
            io::printfn("Source triangles %s; retained vertices %s.", header[11], header[12]);
            io::printfn("Index count %s; stream mask %s.", header[13], header[18]);
            io::printfn("Joint count %s; bytes %s.", header[15], bytes.len);
        }
    }
    file::save(joined_path(output_directory, "SHA256SUMS"), sums.array_view())!;
    io::printn("Source hash, two primitives, exact attributes/binds and all reductions verified.");
    if (expected_directory.len) io::printn("All four files match the frozen reference bytes.");
}

<* Derive and verify deterministic face-subset geometry fixtures. *>
fn int main(String[] arguments) {
    if (arguments.len < 3 || arguments.len > 4) {
        io::eprintn("Usage: animated_lod_derivation SOURCE.glb OUTPUT_DIR [EXPECTED_DIR]");
        return 2;
    }
    String expected = arguments.len == 4 ? arguments[3] : "";
    @pool() {
        if (catch excuse = derive_all(arguments[1], arguments[2], expected)) {
            io::eprintfn("Derivation failed: %s.", excuse);
            return 1;
        }
    };
    return 0;
}
