module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::model;
import c3d::scene;
import gltf;
import std::io::path;

const String MEMORY_PLACEHOLDER_NAME @private = "model.gltf"; // buffers resolve against the directory of a file path

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
};

<*
 Importer switches; scale applies to the instance root of load only.
*>
struct LoadOptions {
    bool  animations;
    bool  lights;
    bool  cameras;
    bool  generate_tangents;
    float scale;
}

<*
 Every switch on, scale one.
*>
const LoadOptions LOAD_OPTIONS_DEFAULT = {
    .animations = true, .lights = true, .cameras = true, .generate_tangents = true, .scale = 1,
};

<*
 Ids and nodes produced by one composed load; arrays belong to the caller's allocator.
*>
struct LoadResult {
    ModelId        model;
    scene::Node*   root;
    GeometryId[]   geometries;
    MaterialId[]   materials;
    TextureId[]    textures;
    ClipId[]       clips;
    SkeletonId[]   skeletons;
    scene::Node*[] cameras;
    scene::Node*[] lights;
}

struct Importer @private {
    AssetStore*   assets;
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
    ModelId       model;
}

<*
 Load a glTF or GLB file into shared assets and a model template keyed by the path.
 @param [&inout] assets : "Receives every converted asset; unchanged on a fault."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require path.len > 0
*>
fn ModelId? load_model(AssetStore* assets, String path, LoadOptions options = LOAD_OPTIONS_DEFAULT) {
    if (assets.keys.has_key(path)) return c3d::INVALID_ARGUMENT~;
    Importer importer = { .assets = assets, .key = path, .options = options };
    defer free_tables(&importer);
    defer catch discard(&importer);
    importer.data = parse_document(path)!;
    defer gltf::free(importer.data);
    prepare_document(importer.data, path)!;
    @pool() {
        importer.base_dir = path.path_tdirname() ?? "";
        import_model(&importer)!;
    };
    return importer.model;
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
    LoadOptions options = LOAD_OPTIONS_DEFAULT,
) {
    if (assets.keys.has_key(key)) return c3d::INVALID_ARGUMENT~;
    Importer importer = { .assets = assets, .key = key, .base_dir = base_dir, .options = options };
    defer free_tables(&importer);
    defer catch discard(&importer);
    importer.data = parse_bytes(bytes)!;
    defer gltf::free(importer.data);
    @pool() {
        prepare_document(importer.data, join_path(base_dir, MEMORY_PLACEHOLDER_NAME))!;
        import_model(&importer)!;
    };
    return importer.model;
}

<*
 Load a file and instantiate it once under the parent.
 @param allocator : "Owns the result arrays."
 @param [&inout] assets : "Receives every converted asset; unchanged on a fault."
 @param [&inout] scene : "Owns the instance."
 @param [in] parent : "Null means the scene root."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::INVALID_ID
 @require path.len > 0
*>
fn LoadResult? load(
    Allocator allocator,
    AssetStore* assets,
    scene::Scene* scene,
    String path,
    scene::Node* parent = null,
    LoadOptions options = LOAD_OPTIONS_DEFAULT,
) {
    if (assets.keys.has_key(path)) return c3d::INVALID_ARGUMENT~;
    Importer importer = { .assets = assets, .key = path, .options = options };
    defer free_tables(&importer);
    defer catch discard(&importer);
    importer.data = parse_document(path)!;
    defer gltf::free(importer.data);
    prepare_document(importer.data, path)!;
    @pool() {
        importer.base_dir = path.path_tdirname() ?? "";
        import_model(&importer)!;
    };

    scene::Node* root = model::instantiate(assets, scene, importer.model, parent)!;
    root.local.scale = { options.scale, options.scale, options.scale };
    ModelInstance* instance = scene.get(root, ModelInstance);
    ModelTemplate* template = &assets.model(importer.model).data;
    return {
        .model      = importer.model,
        .root       = root,
        .geometries = live_ids(allocator, importer.geometries),
        .materials  = material_ids(allocator, &importer),
        .textures   = texture_ids(allocator, &importer),
        .clips      = live_ids(allocator, importer.clips),
        .skeletons  = live_ids(allocator, importer.skeletons),
        .cameras    = component_nodes(allocator, instance, template.cameras),
        .lights     = component_nodes(allocator, instance, template.lights),
    };
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

fn void? import_model(Importer* importer) @private {
    gltf::Data* data = importer.data;
    foreach (extension : data.extensions_required) {
        if (!supported_extension(extension.str_view())) return c3d::UNSUPPORTED~;
    }

    Allocator allocator = importer.assets.allocator;
    usz primitive_count;
    importer.mesh_offsets = alloc::new_array(allocator, usz, data.meshes.len + 1);
    foreach (index, &mesh : data.meshes) {
        importer.mesh_offsets[index] = primitive_count;
        primitive_count += mesh.primitives.len;
    }
    importer.mesh_offsets[data.meshes.len] = primitive_count;
    importer.samplers = alloc::new_array(allocator, SamplerId, data.samplers.len);
    importer.srgb_textures = alloc::new_array(allocator, TextureId, data.images.len);
    importer.linear_textures = alloc::new_array(allocator, TextureId, data.images.len);
    importer.materials = alloc::new_array(allocator, MaterialId, data.materials.len);
    importer.geometries = alloc::new_array(allocator, GeometryId, (sz)primitive_count);
    importer.skeletons = alloc::new_array(allocator, SkeletonId, data.skins.len);
    importer.clips = alloc::new_array(allocator, ClipId, data.animations.len);
    importer.node_remap = alloc::new_array(allocator, usz, data.nodes.len);
    importer.node_remap[..] = usz::max;

    convert_samplers(importer)!;
    convert_materials(importer)!;
    convert_geometries(importer)!;
    build_template(importer)!;
    convert_skins(importer)!;
    if (importer.options.animations) convert_animations(importer)!;
    importer.model = importer.assets.add_model_owned(&importer.template, importer.key)!;
    importer.template = {};
    return;
}

fn void discard(Importer* importer) @private {
    AssetStore* assets = importer.assets;
    if (importer.model.generation) {
        assets.remove_model(importer.model);
    } else {
        asset::free_model_template(assets.allocator, &importer.template);
    }
    foreach (id : importer.clips) if (id.generation) assets.remove_clip(id);
    foreach (id : importer.skeletons) if (id.generation) assets.remove_skeleton(id);
    foreach (id : importer.geometries) if (id.generation) assets.remove_geometry(id);
    if (importer.default_material.generation) assets.remove_material(importer.default_material);
    foreach (id : importer.materials) if (id.generation) assets.remove_material(id);
    foreach (id : importer.srgb_textures) if (id.generation) assets.remove_texture(id);
    foreach (id : importer.linear_textures) if (id.generation) assets.remove_texture(id);
    foreach (id : importer.samplers) if (id.generation) assets.remove_sampler(id);
}

fn void free_tables(Importer* importer) @private {
    Allocator allocator = importer.assets.allocator;
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

fn MaterialId[] material_ids(Allocator allocator, Importer* importer) @private {
    usz count = importer.default_material.generation ? 1 : 0;
    foreach (id : importer.materials) if (id.generation) count++;
    if (!count) return {};
    MaterialId[] ids = alloc::new_array(allocator, MaterialId, (sz)count);
    usz slot;
    foreach (id : importer.materials) if (id.generation) ids[slot++] = id;
    if (importer.default_material.generation) ids[slot] = importer.default_material;
    return ids;
}

fn TextureId[] texture_ids(Allocator allocator, Importer* importer) @private {
    usz count;
    foreach (id : importer.srgb_textures) if (id.generation) count++;
    foreach (id : importer.linear_textures) if (id.generation) count++;
    if (!count) return {};
    TextureId[] ids = alloc::new_array(allocator, TextureId, (sz)count);
    usz slot;
    foreach (id : importer.srgb_textures) if (id.generation) ids[slot++] = id;
    foreach (id : importer.linear_textures) if (id.generation) ids[slot++] = id;
    return ids;
}

macro live_ids(Allocator allocator, ids) @private {
    var $Id = $Typeof(ids[0]);
    usz count;
    foreach (id : ids) if (id.generation) count++;
    if (!count) return ($Id[]){};
    $Id[] live = alloc::new_array(allocator, $Id, (sz)count);
    usz slot;
    foreach (id : ids) if (id.generation) live[slot++] = id;
    return live;
}

macro component_nodes(Allocator allocator, ModelInstance* instance, components) @private {
    if (!components.len) return (scene::Node*[]){};
    scene::Node*[] nodes = alloc::new_array(allocator, scene::Node*, components.len);
    foreach (index, &component : components) nodes[index] = instance.nodes[component.node];
    return nodes;
}
