module c3d::asset::gltf;

import c3d;
import c3d::asset;
import gltf;
import std::io::path;

const String MEMORY_PLACEHOLDER_NAME @private = "model.gltf"; // buffers resolve against the directory of a file path
const usz COLOR_SPACES_PER_IMAGE @private = 2; // an image may be read as sRGB color and as linear data

const String[] SUPPORTED_EXTENSIONS @private = {
    "KHR_materials_clearcoat",
    "KHR_materials_sheen",
    "KHR_materials_transmission",
    "KHR_materials_volume",
    "KHR_materials_ior",
    "KHR_materials_specular",
    "KHR_materials_anisotropy",
    "KHR_materials_emissive_strength",
    "KHR_materials_unlit",
    "KHR_texture_transform",
    "KHR_lights_punctual",
    "KHR_mesh_quantization",
    "MSFT_lod",
};

struct Importer @private {
    Allocator     allocator;
    gltf::Data*   data;
    String        key;
    String        base_dir;
    LoadOptions   options;
    SamplerId[]   samplers;
    TextureId[]   srgb_textures;
    TextureId[]   linear_textures;
    MaterialId[]  materials;
    MaterialId    default_material;
    GeometryId[]  geometries;
    SkeletonId[]  skeletons;
    ClipId[]      clips;
    usz[]         mesh_offsets;
    usz[]         node_remap;
    ModelTemplate template;
    ModelDocument document;
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
    ModelDocument document = decode_model(assets.allocator, path, options)!;
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
        allocator: assets.allocator,
        bytes:     bytes,
        base_dir:  base_dir,
        key:       key,
        options:   options,
    )!;
    defer asset::destroy_model_document(&document);
    return assets.publish_document(&document);
}

<*
 Decode a glTF or GLB file into a document keyed by the path.
 @param allocator : "Owns the document; publish needs the store allocator."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require path.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model(
    Allocator allocator,
    String path,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
) {
    gltf::Data* data = parse_document(path)!;
    defer gltf::free(data);
    prepare_document(data, path)!;
    Importer importer = create_importer(
        allocator: allocator,
        data:      data,
        key:       path,
        options:   options,
    )!;
    defer free_tables(&importer);
    defer catch discard(&importer);
    @pool() {
        importer.base_dir = path.path_tdirname() ?? "";
        convert_model(&importer)!;
    };
    return importer.document;
}

<*
 Decode glTF or GLB bytes; external resources resolve against the base directory.
 @param allocator : "Owns the document; publish needs the store allocator."
 @param bytes : "Borrowed for the call."
 @param key : "Model key and prefix of every content key."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require bytes.len > 0, key.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model_memory(
    Allocator allocator,
    char[] bytes,
    String base_dir,
    String key,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
) {
    gltf::Data* data = parse_bytes(bytes)!;
    defer gltf::free(data);
    @pool() {
        prepare_document(data, join_path(base_dir, MEMORY_PLACEHOLDER_NAME))!;
    };
    Importer importer = create_importer(
        allocator: allocator,
        data:      data,
        key:       key,
        options:   options,
    )!;
    importer.base_dir = base_dir;
    defer free_tables(&importer);
    defer catch discard(&importer);
    @pool() {
        convert_model(&importer)!;
    };
    return importer.document;
}

fn gltf::Data*? parse_document(String path) @private {
    gltf::Data*? data = gltf::parse_file(path);
    if (catch excuse = data) return load_fault(excuse)~;
    return data;
}

fn gltf::Data*? parse_bytes(char[] bytes) @private {
    gltf::Data*? data = gltf::parse(bytes);
    if (catch excuse = data) return load_fault(excuse)~;
    return data;
}

fn void? prepare_document(gltf::Data* data, String path) @private {
    if (catch excuse = gltf::load_buffers(data, path)) return load_fault(excuse)~;
    if (catch excuse = gltf::validate(data)) return load_fault(excuse)~;
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
        .textures   = COLOR_SPACES_PER_IMAGE * data.images.len,
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
    foreach (supported : SUPPORTED_EXTENSIONS) if (supported == name) return true;
    return false;
}

fn String join_path(String directory, String name) @private {
    if (!directory.len) return name;
    return string::tformat("%s/%s", directory, name);
}
