module c3d::test::animated_lod_fixtures;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::maths;
import c3d::render;
import std::hash::sha256;
import std::io::file;
import std::io::path;

<* Source mesh primitives in the immutable corpus. *>
const uint LOD_PRIMITIVES = 2;
<* Original geometry followed by two reduced levels. *>
const uint LOD_LEVELS = 3;
const uint HEADER_WORDS @private = 24;
const uint FILE_MAGIC @private = 0x444f4c41;
const uint FILE_VERSION @private = 1;
const uint DERIVATION_VERSION @private = 1;
const uint ENDIAN_MARKER @private = 0x01020304;
const uint SOURCE_NODES @private = 57;
const uint SOURCE_JOINTS @private = 53;
const uint SOURCE_CLIPS @private = 127;
const uint SOURCE_JOINT_BITS @private = 8;
const uint FILE_JOINT_BITS @private = 16;
const uint SOURCE_STREAMS @private = 219;
const uint TRIANGLE_CORNERS @private = 3;
const uint REDUCED_GEOMETRIES @private = LOD_PRIMITIVES * (LOD_LEVELS - 1);
const String SOURCE_PATH @private = "examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String SOURCE_KEY @private = "animated_lod_fixtures/source";
const String SOURCE_SHA @private = "272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c";
const String FIXTURE_DIRECTORY @private = "test/fixtures/animated_lod";
const String HEX_DIGITS @private = "0123456789abcdef";
const uint[LOD_PRIMITIVES] SOURCE_VERTICES @private = { 3389, 5157 };
const uint[LOD_PRIMITIVES] SOURCE_TRIANGLES @private = { 5732, 8012 };
const FixtureFile[2][2] FILES @private = {
    {
        {
            .name = "primitive_0_lod_1.bin",
            .sha256 = "58991acb0d453c09449e297bd69c71c1611a1f3a1bbe10e80739594c41179ee6",
            .vertices = 3297,
            .triangles = 2866,
            .bytes = 273808,
        },
        {
            .name = "primitive_0_lod_2.bin",
            .sha256 = "9bcc79c0ffb4108bb0672681b64a125bcb0a546151868b38f7c1c655f1730b11",
            .vertices = 2858,
            .triangles = 1433,
            .bytes = 221028,
        },
    },
    {
        {
            .name = "primitive_1_lod_1.bin",
            .sha256 = "284453c09e7d9119a363c6f4cf86b37b74ae8b87b6b956f60dafd4e9c8d366bd",
            .vertices = 4781,
            .triangles = 4006,
            .bytes = 392960,
        },
        {
            .name = "primitive_1_lod_2.bin",
            .sha256 = "dfd6032d9e00f383094da0c6150d2a6e551f0f2b51c41e22eb64cd87483e90f0",
            .vertices = 4150,
            .triangles = 2003,
            .bytes = 318004,
        },
    },
};

<* Store-owned source model and geometry alternatives, indexed primitive then level. *>
struct AnimatedLodFixtures {
    ModelId model;
    GeometryId[LOD_LEVELS][LOD_PRIMITIVES] levels;
    render::GeometryLayout[LOD_LEVELS][LOD_PRIMITIVES] layouts;
}

struct FixtureFile @private {
    String name;
    String sha256;
    uint vertices;
    uint triangles;
    uint bytes;
}

struct FixtureReader @private {
    char[] bytes;
    usz cursor;
}

fn uint? FixtureReader.u32(&self) {
    if (self.bytes.len - self.cursor < uint::size) return c3d::ASSET_FORMAT_ERROR~;
    uint word;
    for (uint byte = 0; byte < uint::size; byte++) word |= (uint)self.bytes[self.cursor++] << (byte * 8);
    return word;
}

fn ushort? FixtureReader.u16(&self) {
    if (self.bytes.len - self.cursor < ushort::size) return c3d::ASSET_FORMAT_ERROR~;
    ushort word;
    for (uint byte = 0; byte < ushort::size; byte++) {
        word |= (ushort)((uint)self.bytes[self.cursor++] << (byte * 8));
    }
    return word;
}

fn float? FixtureReader.f32(&self, float expected) {
    uint word = self.u32()!;
    if (word != bitcast(expected, uint)) return c3d::ASSET_FORMAT_ERROR~;
    return bitcast(word, float);
}

fn char[64] hash_hex(char[32] digest) @private {
    char[64] text;
    foreach (index, value : digest) {
        text[index * 2] = HEX_DIGITS[value >> 4];
        text[index * 2 + 1] = HEX_DIGITS[value & 15];
    }
    return text;
}

fn void? verify_hash(char[] bytes, String expected) @private {
    char[64] actual = hash_hex(sha256::hash(bytes));
    if ((String)actual[..] != expected) return c3d::ASSET_FORMAT_ERROR~;
}

fn char[]? read_fixture_file(Allocator allocator, String filename) @private {
    if (try bytes = file::load(allocator, filename)) return bytes;
    return c3d::ASSET_IO_ERROR~;
}

fn String? fixture_path(String repository, String relative) @private {
    return (String)path::tnew(repository)!.tappend(relative)!;
}

fn String fixture_key(FixtureFile file) @private {
    return string::tformat("animated_lod_fixtures/%s", file.name);
}

fn ModelSkin*? source_skin(ModelTemplate* template, uint node) @private {
    foreach (&skin : template.skins) if (skin.mesh_node == node) return skin;
    return c3d::ASSET_FORMAT_ERROR~;
}

fn Skeleton* source_skeleton(ModelDocument* document, ModelSkin* skin) @private {
    return &document.skeletons[skin.skeleton.index - 1].data;
}

fn void? verify_source(ModelDocument* document) @private {
    ModelTemplate* template = &document.template;
    if (template.nodes.len != SOURCE_NODES || template.meshes.len != LOD_PRIMITIVES
      || template.skins.len != LOD_PRIMITIVES || template.clips.len != SOURCE_CLIPS) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    ModelSkin* first = source_skin(template, template.meshes[0].node)!;
    Skeleton* reference = source_skeleton(document, first);
    foreach (uint primitive, mesh : template.meshes) {
        Geometry* source = &document.geometry(mesh.geometry).data;
        ModelSkin* skin = source_skin(template, mesh.node)!;
        Skeleton* skeleton = source_skeleton(document, skin);
        if (mesh.node != primitive + 2 || source.topology != Topology.TRIANGLES
          || source.positions.len != SOURCE_VERTICES[primitive]
          || source.indices.len != SOURCE_TRIANGLES[primitive] * TRIANGLE_CORNERS
          || source.normals.len != source.positions.len || source.uv0.len != source.positions.len
          || source.uv1.len != source.positions.len || source.joints.len != source.positions.len
          || source.weights.len != source.positions.len || source.tangents.len || source.colors.len
          || source.targets.len || source.channels.len || source.custom_data.len || source.custom_stride
          || mesh.default_morph_weights.len || source.joints_exceed_byte()) return c3d::ASSET_FORMAT_ERROR~;
        if (skin.joint_nodes.len != SOURCE_JOINTS || skeleton.inverse_bind.len != SOURCE_JOINTS
          || skin.joint_nodes != first.joint_nodes || reference.inverse_bind.len != SOURCE_JOINTS) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        foreach (joint, inverse_bind : skeleton.inverse_bind) {
            foreach (component, value : inverse_bind.m) {
                if (bitcast(value, uint) != bitcast(reference.inverse_bind[joint].m[component], uint)) {
                    return c3d::ASSET_FORMAT_ERROR~;
                }
            }
        }
        foreach (index : source.indices) if (index >= source.positions.len) return c3d::ASSET_FORMAT_ERROR~;
    }
}

fn void? read_vec3_stream(
    FixtureReader* reader,
    Vec3[] destination,
    Vec3[] source,
    uint[] vertex_map,
) @private {
    foreach (vertex, &value : destination) {
        for (uint component = 0; component < 3; component++) {
            value[component] = reader.f32(source[vertex_map[vertex]][component])!;
        }
    }
}

fn void? read_vec2_stream(
    FixtureReader* reader,
    Vec2[] destination,
    Vec2[] source,
    uint[] vertex_map,
) @private {
    foreach (vertex, &value : destination) {
        for (uint component = 0; component < 2; component++) {
            value[component] = reader.f32(source[vertex_map[vertex]][component])!;
        }
    }
}

fn void? read_weight_stream(
    FixtureReader* reader,
    Vec4[] destination,
    Vec4[] source,
    uint[] vertex_map,
) @private {
    foreach (vertex, &value : destination) {
        for (uint component = 0; component < 4; component++) {
            value[component] = reader.f32(source[vertex_map[vertex]][component])!;
        }
    }
}

fn Geometry? decode_fixture(
    Allocator allocator,
    ModelDocument* document,
    char[] bytes,
    uint primitive,
    uint level,
) @private {
    FixtureFile file = FILES[primitive][level - 1];
    if (bytes.len != file.bytes) return c3d::ASSET_FORMAT_ERROR~;
    verify_hash(bytes, file.sha256)!;
    ModelMesh* mesh = &document.template.meshes[primitive];
    Geometry* source = &document.geometry(mesh.geometry).data;
    ModelSkin* skin = source_skin(&document.template, mesh.node)!;
    Skeleton* skeleton = source_skeleton(document, skin);
    FixtureReader reader = { .bytes = bytes };
    uint[HEADER_WORDS] expected = {
        FILE_MAGIC, FILE_VERSION, DERIVATION_VERSION, ENDIAN_MARKER,
        primitive, level, 1u << level, SOURCE_NODES, mesh.node,
        SOURCE_VERTICES[primitive], SOURCE_TRIANGLES[primitive] * TRIANGLE_CORNERS, SOURCE_TRIANGLES[primitive],
        file.vertices, file.triangles * TRIANGLE_CORNERS, file.triangles, SOURCE_JOINTS,
        SOURCE_JOINT_BITS, FILE_JOINT_BITS, SOURCE_STREAMS, 0, 0, 0, 0, HEADER_WORDS,
    };
    foreach (word : expected) if (reader.u32()! != word) return c3d::ASSET_FORMAT_ERROR~;
    // The embedded source digest is checked independently of the fixture digest.
    char[64] source_digest;
    for (uint byte = 0; byte < sha256::HASH_SIZE; byte++) {
        if (reader.cursor >= reader.bytes.len) return c3d::ASSET_FORMAT_ERROR~;
        char value = reader.bytes[reader.cursor++];
        source_digest[byte * 2] = HEX_DIGITS[value >> 4];
        source_digest[byte * 2 + 1] = HEX_DIGITS[value & 15];
    }
    if ((String)source_digest[..] != SOURCE_SHA) return c3d::ASSET_FORMAT_ERROR~;
    Geometry result = { .topology = Topology.TRIANGLES, .bounds = source.bounds };
    defer catch asset::free_geometry(allocator, &result);
    for (uint component = 0; component < 3; component++) {
        result.bounds.min[component] = reader.f32(source.bounds.min[component])!;
    }
    for (uint component = 0; component < 3; component++) {
        result.bounds.max[component] = reader.f32(source.bounds.max[component])!;
    }
    foreach (joint : skin.joint_nodes) if (reader.u32()! != joint) return c3d::ASSET_FORMAT_ERROR~;
    foreach (inverse_bind : skeleton.inverse_bind) foreach (value : inverse_bind.m) (void)reader.f32(value)!;
    @pool() {
        uint[] faces = alloc::new_array(tmem, uint, file.triangles);
        foreach (uint index, &face : faces) {
            *face = reader.u32()!;
            if (*face != index * (1u << level)) return c3d::ASSET_FORMAT_ERROR~;
        }
        uint[] vertices = alloc::new_array(tmem, uint, file.vertices);
        bool[] source_seen = alloc::new_array(tmem, bool, source.positions.len);
        foreach (&vertex : vertices) {
            *vertex = reader.u32()!;
            if (*vertex >= source.positions.len || source_seen[*vertex]) return c3d::ASSET_FORMAT_ERROR~;
            source_seen[*vertex] = true;
        }
        result.indices = alloc::new_array(allocator, uint, (sz)file.triangles * TRIANGLE_CORNERS);
        bool[] compact_seen = alloc::new_array(tmem, bool, file.vertices);
        uint next_vertex;
        foreach (uint corner, &index : result.indices) {
            *index = reader.u32()!;
            if (*index >= vertices.len) return c3d::ASSET_FORMAT_ERROR~;
            uint source_corner = faces[corner / TRIANGLE_CORNERS] * TRIANGLE_CORNERS + corner % TRIANGLE_CORNERS;
            if (vertices[*index] != source.indices[source_corner]) return c3d::ASSET_FORMAT_ERROR~;
            if (!compact_seen[*index]) {
                if (*index != next_vertex++) return c3d::ASSET_FORMAT_ERROR~;
                compact_seen[*index] = true;
            }
        }
        if (next_vertex != vertices.len) return c3d::ASSET_FORMAT_ERROR~;
        result.positions = alloc::new_array(allocator, Vec3, file.vertices);
        result.normals = alloc::new_array(allocator, Vec3, file.vertices);
        result.uv0 = alloc::new_array(allocator, Vec2, file.vertices);
        result.uv1 = alloc::new_array(allocator, Vec2, file.vertices);
        result.joints = alloc::new_array(allocator, ushort[<4>], file.vertices);
        result.weights = alloc::new_array(allocator, Vec4, file.vertices);
        read_vec3_stream(
            reader: &reader,
            destination: result.positions,
            source: source.positions,
            vertex_map: vertices,
        )!;
        read_vec3_stream(
            reader: &reader,
            destination: result.normals,
            source: source.normals,
            vertex_map: vertices,
        )!;
        read_vec2_stream(
            reader: &reader,
            destination: result.uv0,
            source: source.uv0,
            vertex_map: vertices,
        )!;
        read_vec2_stream(
            reader: &reader,
            destination: result.uv1,
            source: source.uv1,
            vertex_map: vertices,
        )!;
        foreach (vertex, &joints : result.joints) for (uint component = 0; component < 4; component++) {
            joints[component] = reader.u16()!;
            if (joints[component] != source.joints[vertices[vertex]][component]) return c3d::ASSET_FORMAT_ERROR~;
        }
        read_weight_stream(
            reader: &reader,
            destination: result.weights,
            source: source.weights,
            vertex_map: vertices,
        )!;
        foreach (position : result.positions) for (uint axis = 0; axis < 3; axis++) {
            if (position[axis] < result.bounds.min[axis] || position[axis] > result.bounds.max[axis]) {
                return c3d::ASSET_FORMAT_ERROR~;
            }
        }
    };
    if (reader.cursor != reader.bytes.len) return c3d::ASSET_FORMAT_ERROR~;
    return result;
}

<*
 Publish the unchanged source model and four verified reduced geometries.
 @param [&inout] assets : "Owns returned assets and their ordinary bindings."
 @param repository : "Contains the immutable source and fixture files."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @return? c3d::ASSET_IO_ERROR, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @require assets.allocator != tmem
*>
fn AnimatedLodFixtures? load_animated_lod_fixtures(AssetStore* assets, String repository) {
    @pool() {
        String source_path = fixture_path(repository, SOURCE_PATH)!;
        char[] input = read_fixture_file(assets.allocator, source_path)!;
        defer alloc::free(assets.allocator, input.ptr);
        verify_hash(input, SOURCE_SHA)!;
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.generate_tangents = false;
        ModelDocument document = gltf::decode_model_memory(
            allocator: assets.allocator,
            bytes: input,
            base_dir: "",
            key: SOURCE_KEY,
            options: options,
            file_source: assets.file_source,
        )!;
        defer asset::destroy_model_document(&document);
        verify_source(&document)!;
        sz source_geometries = document.geometries.len;
        DocumentGeometry[] entries = alloc::new_array(
            assets.allocator, DocumentGeometry, source_geometries + REDUCED_GEOMETRIES);
        entries[:source_geometries] = document.geometries[..];
        alloc::free(assets.allocator, document.geometries.ptr);
        document.geometries = entries[:source_geometries];
        document.bounds.geometries = (usz)entries.len;
        AnimatedLodFixtures fixtures;
        for (uint primitive = 0; primitive < LOD_PRIMITIVES; primitive++) {
            uint previous_triangles = SOURCE_TRIANGLES[primitive];
            for (uint level = 1; level < LOD_LEVELS; level++) {
                FixtureFile file = FILES[primitive][level - 1];
                String relative = string::tformat("%s/%s", FIXTURE_DIRECTORY, file.name);
                char[] bytes = read_fixture_file(assets.allocator, fixture_path(repository, relative)!)!;
                defer alloc::free(assets.allocator, bytes.ptr);
                if (file.triangles >= previous_triangles) return c3d::ASSET_FORMAT_ERROR~;
                previous_triangles = file.triangles;
                Geometry geometry = decode_fixture(
                    allocator: assets.allocator,
                    document: &document,
                    bytes: bytes,
                    primitive: primitive,
                    level: level,
                )!;
                defer catch asset::free_geometry(assets.allocator, &geometry);
                fixtures.layouts[primitive][level] = render::geometry_layout(&geometry);
                (void)document.push_geometry(&geometry, fixture_key(file));
                geometry = {};
            }
        }
        fixtures.model = assets.publish_document(&document)!;
        ModelTemplate* template = &assets.model(fixtures.model).data;
        for (uint primitive = 0; primitive < LOD_PRIMITIVES; primitive++) {
            fixtures.levels[primitive][0] = template.meshes[primitive].geometry;
            Geometry* source = &assets.geometry(fixtures.levels[primitive][0]).data;
            fixtures.layouts[primitive][0] = render::geometry_layout(source);
            for (uint level = 1; level < LOD_LEVELS; level++) {
                fixtures.levels[primitive][level] = assets.find_geometry(fixture_key(FILES[primitive][level - 1]))!;
            }
        }
        return fixtures;
    };
}
