module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::material;
import gltf;
import std::io::path;

const String MEMORY_PLACEHOLDER_NAME @private = "model.gltf"; // buffers resolve against the directory of a file path
const usz TEXTURE_VARIANTS_PER_IMAGE @private = 3;

const String[] SUPPORTED_EXTENSIONS @private = {
    "KHR_lights_punctual",
    "KHR_mesh_quantization",
    "MSFT_lod",
};

struct TextureVariant @private {
    usz image;
    TextureSemantic semantic;
    PixelFormat format;
    CoveragePolicy coverage;
    double alpha_threshold;
    TextureId texture;
}

struct Importer @private {
    Allocator        allocator;
    gltf::Data*      data;
    String           key;
    String           base_dir;
    LoadOptions      options;
    SamplerId[]      samplers;
    TextureId[]      srgb_textures;
    TextureId[]      linear_textures;
    TextureId[]      normal_textures;
    TextureVariant[] texture_variants;
    usz              texture_variant_count;
    MaterialId[]     materials;
    MaterialId       default_material;
    GeometryId[]     geometries;
    SkeletonId[]     skeletons;
    ClipId[]         clips;
    usz[]            mesh_offsets;
    usz[]            node_remap;
    ModelTemplate    template;
    ModelDocument    document;
    SourceRecord*    source;
    FileSource       file_source;
}

<*
 Load a glTF or GLB file into shared assets and a model template keyed by the path.
 @param [&inout] assets : "Receives every converted asset; unchanged on a fault."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require path.len > 0
*>
fn ModelId? load_model(AssetStore* assets, String path, LoadOptions options = asset::LOAD_OPTIONS_DEFAULT) {
    if (assets.keys.has_key(path)) return c3d::INVALID_ARGUMENT~;
    ModelDocument document = decode_model(assets.allocator, path, options, assets.file_source)!;
    defer asset::destroy_model_document(&document);
    return assets.publish_document(&document);
}

<*
 Load glTF or GLB bytes; external resources resolve against the base directory.
 @param [&inout] assets : "Receives every converted asset; unchanged on a fault."
 @param bytes : "Borrowed for the call."
 @param key : "Model key and prefix of every content key."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require bytes.len > 0, key.len > 0
*>
fn ModelId? load_model_memory(
    AssetStore* assets,
    char[] bytes,
    String base_dir,
    String key,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
) {
    if (assets.keys.has_key(key)) return c3d::INVALID_ARGUMENT~;
    ModelDocument document = decode_model_memory(
        allocator:   assets.allocator,
        bytes:       bytes,
        base_dir:    base_dir,
        key:         key,
        options:     options,
        file_source: assets.file_source,
    )!;
    defer asset::destroy_model_document(&document);
    return assets.publish_document(&document);
}

<*
 Decode a file and replace the model loaded from it.
 @param [&inout] assets : "Receives the replaced parts; unchanged on a fault."
 @param missing : "Receives the first missing parts by kind, then key."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::INCOMPATIBLE_STRUCTURE
 @require path.len > 0
 @require assets.models.is_live(model)
*>
fn ModelReplaceReport? replace_model(
    AssetStore* assets,
    ModelId model,
    String path,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    AssetRef[] missing = {},
) {
    ModelDocument document = decode_model(assets.allocator, path, options, assets.file_source)!;
    defer asset::destroy_model_document(&document);
    return assets.replace_document(model, &document, missing);
}

<*
 Decode bytes and replace the model under the key.
 @param [&inout] assets : "Receives the replaced parts; unchanged on a fault."
 @param bytes : "Borrowed for the call."
 @param key : "Model key and prefix of every content key."
 @param missing : "Receives the first missing parts by kind, then key."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::INCOMPATIBLE_STRUCTURE
 @require bytes.len > 0, key.len > 0
 @require assets.models.is_live(model)
*>
fn ModelReplaceReport? replace_model_memory(
    AssetStore* assets,
    ModelId model,
    char[] bytes,
    String base_dir,
    String key,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    AssetRef[] missing = {},
) {
    ModelDocument document = decode_model_memory(
        allocator:   assets.allocator,
        bytes:       bytes,
        base_dir:    base_dir,
        key:         key,
        options:     options,
        file_source: assets.file_source,
    )!;
    defer asset::destroy_model_document(&document);
    return assets.replace_document(model, &document, missing);
}

<*
 Decode a glTF or GLB file into a document keyed by the path.
 @param allocator : "Owns the document; publish needs the store allocator."
 @param file_source : "Read during the call; a null read selects the file system."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require path.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model(
    Allocator allocator,
    String path,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    FileSource file_source = {},
) {
    return decode_file(
        allocator: allocator,
        path: path,
        options: options,
        file_source: file_source,
        source: null,
        diagnostic: null,
    );
}

fn ModelDocument? decode_file(
    Allocator allocator,
    String path,
    LoadOptions options,
    FileSource file_source,
    SourceRecord* source,
    SourceDiagnostic* diagnostic,
) @private {
    gltf::Options reader = read_options(&file_source);
    gltf::Data* data = parse_document(path, reader)!;
    defer gltf::free(data);
    prepare_document(data, path, reader)!;
    Importer importer = create_importer(
        allocator: allocator,
        data:      data,
        key:       path,
        options:   options,
    )!;
    defer free_tables(&importer);
    defer catch discard(&importer);
    SourceRecord record;
    if (source) {
        record = create_source_record(&importer);
        importer.source = &record;
    }
    defer catch if (source) destroy_source_record(&record);
    importer.file_source = file_source;
    @pool() {
        importer.base_dir = path.path_tdirname() ?? "";
        convert_model(&importer)!;
        if (source) finish_source_record(&importer, diagnostic)!;
    };
    if (source) *source = record;
    return importer.document;
}

<*
 Decode glTF or GLB bytes; external resources resolve against the base directory.
 @param allocator : "Owns the document; publish needs the store allocator."
 @param bytes : "Borrowed for the call."
 @param key : "Model key and prefix of every content key."
 @param file_source : "Read during the call; a null read selects the file system."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require bytes.len > 0, key.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model_memory(
    Allocator allocator,
    char[] bytes,
    String base_dir,
    String key,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    FileSource file_source = {},
) {
    return decode_memory(
        allocator: allocator,
        bytes: bytes,
        base_dir: base_dir,
        key: key,
        options: options,
        file_source: file_source,
        source: null,
        diagnostic: null,
    );
}

fn ModelDocument? decode_memory(
    Allocator allocator,
    char[] bytes,
    String base_dir,
    String key,
    LoadOptions options,
    FileSource file_source,
    SourceRecord* source,
    SourceDiagnostic* diagnostic,
) @private {
    gltf::Options reader = read_options(&file_source);
    gltf::Data* data = parse_bytes(bytes, reader)!;
    defer gltf::free(data);
    @pool() {
        prepare_document(data, join_path(base_dir, MEMORY_PLACEHOLDER_NAME), reader)!;
    };
    Importer importer = create_importer(
        allocator: allocator,
        data:      data,
        key:       key,
        options:   options,
    )!;
    importer.base_dir = base_dir;
    importer.file_source = file_source;
    defer free_tables(&importer);
    defer catch discard(&importer);
    SourceRecord record;
    if (source) {
        record = create_source_record(&importer);
        importer.source = &record;
    }
    defer catch if (source) destroy_source_record(&record);
    @pool() {
        convert_model(&importer)!;
        if (source) finish_source_record(&importer, diagnostic)!;
    };
    if (source) *source = record;
    return importer.document;
}

fn gltf::Options read_options(FileSource* file_source) @private {
    return {
        .file = {
            .read      = &read_through_source,
            .release   = &release_read,
            .user_data = file_source,
        },
    };
}

fn gltf::Result read_through_source(
    gltf::MemoryOptions* memory,
    gltf::FileOptions* file,
    ZString path,
    usz* size,
    void** data,
) @private {
    FileSource* file_source = file.user_data;
    char[]? bytes = file_source.read_path(mem, path.str_view());
    if (catch bytes) return gltf::Result.IO_ERROR;
    if (*size > bytes.len) {
        alloc::free(mem, bytes.ptr);
        return gltf::Result.IO_ERROR;
    }
    if (!*size) *size = bytes.len;
    *data = bytes.ptr;
    return gltf::Result.SUCCESS;
}

fn void release_read(gltf::MemoryOptions* memory, gltf::FileOptions* file, void* data) @private {
    alloc::free(mem, data);
}

fn gltf::Data*? parse_document(String path, gltf::Options reader) @private {
    gltf::Data*? data = gltf::parse_file(path, reader);
    if (catch excuse = data) return load_fault(excuse)~;
    return data;
}

fn gltf::Data*? parse_bytes(char[] bytes, gltf::Options reader = {}) @private {
    gltf::Data*? data = gltf::parse(bytes, reader);
    if (catch excuse = data) return load_fault(excuse)~;
    return data;
}

fn void? prepare_document(gltf::Data* data, String path, gltf::Options reader) @private {
    if (catch excuse = gltf::load_buffers(data, path, reader)) return load_fault(excuse)~;
    if (catch excuse = gltf::validate(data)) return load_fault(excuse)~;

    bool quantized;

    foreach (extension : data.extensions_required) {
        if (extension.str_view() == "KHR_mesh_quantization") quantized = true;
    }

    foreach (&mesh : data.meshes) {
        foreach (&primitive : mesh.primitives) {
            gltf::Accessor* position = primitive.find_accessor(gltf::AttributeType.POSITION, 0);

            foreach (&attribute : primitive.attributes) {
                if (attribute.type != gltf::AttributeType.TANGENT) continue;
                gltf::Accessor* tangent = attribute.data;
                bool floating = tangent.component_type == gltf::ComponentType.R_32F && !tangent.normalized;
                bool normalized_integer = quantized && tangent.normalized != 0
                  && (tangent.component_type == gltf::ComponentType.R_8 || tangent.component_type == gltf::ComponentType.R_16);
                if (!position || attribute.index != 0 || tangent.type != gltf::Type.VEC4
                  || tangent.count != position.count || (!floating && !normalized_integer)) {
                    return c3d::ASSET_FORMAT_ERROR~;
                }
            }
        }
    }

    return;
}

fn Importer? create_importer(
    Allocator allocator,
    gltf::Data* data,
    String key,
    LoadOptions options,
) @private {
    foreach (extension : data.extensions_required) {
        if (!supported_extension(extension.str_view())) return c3d::UNSUPPORTED~;
    }

    usz primitive_count;
    usz[] mesh_offsets = alloc::new_array(allocator, usz, data.meshes.len + 1);

    foreach (index, &mesh : data.meshes) {
        mesh_offsets[index] = primitive_count;
        primitive_count += mesh.primitives.len;
    }

    mesh_offsets[data.meshes.len] = primitive_count;

    ModelDocumentBounds bounds = {
        .samplers   = data.samplers.len,
        .textures   = TEXTURE_VARIANTS_PER_IMAGE * data.images.len + data.materials.len,
        .materials  = data.materials.len + 1,
        .geometries = primitive_count,
        .skeletons  = data.skins.len,
        .clips      = data.animations.len,
    };

    Importer importer = {
        .allocator       = allocator,
        .data            = data,
        .key             = key,
        .options         = options,
        .samplers        = alloc::new_array(allocator, SamplerId, data.samplers.len),
        .srgb_textures   = alloc::new_array(allocator, TextureId, data.images.len),
        .linear_textures = alloc::new_array(allocator, TextureId, data.images.len),
        .normal_textures = alloc::new_array(allocator, TextureId, data.images.len),
        .texture_variants = alloc::new_array(allocator, TextureVariant, (sz)bounds.textures),
        .materials       = alloc::new_array(allocator, MaterialId, data.materials.len),
        .geometries      = alloc::new_array(allocator, GeometryId, (sz)primitive_count),
        .skeletons       = alloc::new_array(allocator, SkeletonId, data.skins.len),
        .clips           = alloc::new_array(allocator, ClipId, data.animations.len),
        .mesh_offsets    = mesh_offsets,
        .node_remap      = alloc::new_array(allocator, usz, data.nodes.len),
        .document        = asset::create_model_document(allocator, key, bounds),
    };

    importer.node_remap[..] = usz::max;

    return importer;
}

fn void? convert_model(Importer* importer) @private {
    convert_samplers(importer);
    convert_materials(importer)!;
    convert_geometries(importer)!;
    build_template(importer)!;
    convert_lod_groups(importer)!;
    convert_skins(importer)!;
    if (importer.options.animations) convert_animations(importer)!;
    importer.document.template = importer.template;
    importer.template = {};
    return;
}

fn void discard(Importer* importer) @private {
    asset::destroy_model_document(&importer.document);
    asset::free_model_template(importer.allocator, &importer.template);
}

fn void free_tables(Importer* importer) @private {
    Allocator allocator = importer.allocator;
    alloc::free(allocator, importer.mesh_offsets.ptr);
    alloc::free(allocator, importer.samplers.ptr);
    alloc::free(allocator, importer.srgb_textures.ptr);
    alloc::free(allocator, importer.linear_textures.ptr);
    alloc::free(allocator, importer.normal_textures.ptr);
    alloc::free(allocator, importer.texture_variants.ptr);
    alloc::free(allocator, importer.materials.ptr);
    alloc::free(allocator, importer.geometries.ptr);
    alloc::free(allocator, importer.skeletons.ptr);
    alloc::free(allocator, importer.clips.ptr);
    alloc::free(allocator, importer.node_remap.ptr);
}

fn fault load_fault(fault excuse) @private {
    if (excuse == gltf::FILE_NOT_FOUND || excuse == gltf::IO_ERROR) return c3d::ASSET_IO_ERROR;
    return c3d::ASSET_FORMAT_ERROR;
}

fn bool supported_extension(String name) @private {
    foreach (supported : SUPPORTED_MATERIAL_EXTENSIONS) if (supported == name) return true;
    foreach (supported : SUPPORTED_EXTENSIONS) if (supported == name) return true;
    return false;
}

fn String join_path(String directory, String name) @private {
    if (!directory.len) return name;
    return string::tformat("%s/%s", directory, name);
}
