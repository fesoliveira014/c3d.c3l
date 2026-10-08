module c3d::asset::fbx;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import std::io::path;
import ufbx;

const uint NOT_IMPORTED @private = uint::max;
const uint NO_TEXTURE @private = uint::max;
const usz MIXED_REPEAT_CLAMP @private = 0;
const usz MIXED_CLAMP_REPEAT @private = 1;
const usz MIXED_SAMPLER_COUNT @private = 2;
const usz COLOR_SPACES_PER_TEXTURE @private = 2; // a texture may be read as sRGB color and as linear data
const usz DERIVED_TEXTURES_PER_MATERIAL @private = 2; // one packed metallic-roughness map and one base-opacity map

struct DerivedTexture @private {
    uint      first;
    uint      second;
    bool      metallic_roughness;
    bool      invert_roughness;
    TextureId texture;
}

struct Importer @private {
    alloc::Allocator allocator;
    ufbx::Scene*     scene;
    String           key;
    String           base_dir;
    LoadOptions      options;
    TextureId[]      srgb_textures;
    TextureId[]      linear_textures;
    DerivedTexture[] derived_textures;
    usz              derived_count;
    SamplerId[MIXED_SAMPLER_COUNT] mixed_samplers;
    MaterialId[]     materials;
    MaterialId       default_material;
    usz[]            part_offsets;
    GeometryId[]     geometries;
    SkeletonId[]     skeletons;
    ClipId[]         clips;
    uint[]           node_remap;
    ModelTemplate    template;
    ModelDocument    document;
    bool             nodes_only;
    FileSource       file_source;
}

<*
 Load an FBX file into shared assets and a model template keyed by the path.
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
 Decode an FBX file into a document keyed by the path.
 @param allocator : "Owns the document; publish needs the store allocator."
 @param file_source : "Read during the call; a null read selects the file system."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require path.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model(
    alloc::Allocator allocator,
    String path,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    FileSource file_source = {},
) {
    ufbx::Scene* scene = parse_scene(path, &file_source)!;
    defer ufbx::free_scene(scene);
    Importer importer = create_importer(
        allocator: allocator,
        scene:     scene,
        key:       path,
        options:   options,
    );
    importer.file_source = file_source;
    defer free_tables(&importer);
    defer catch discard(&importer);
    @pool() {
        importer.base_dir = path.path_tdirname() ?? "";
        convert_model(&importer)!;
    };
    return importer.document;
}

<*
 Load every animation stack of the file as clips rebound onto the target model.
 @param allocator : "Owns the returned array."
 @param [&inout] assets : "Receives the clips; unchanged on a fault."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require path.len > 0
*>
fn ClipId[]? load_animations(
    alloc::Allocator allocator,
    AssetStore* assets,
    String path,
    ModelId target,
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT,
) {
    ModelAsset* record = assets.models.try_get(target)!;
    Importer importer = {
        .allocator   = assets.allocator,
        .key         = path,
        .options     = { .animations = true },
        .nodes_only  = true,
        .file_source = assets.file_source,
    };
    defer free_tables(&importer);
    importer.scene = parse_scene(path, &assets.file_source)!;
    defer ufbx::free_scene(importer.scene);

    ClipId[] clips = alloc::new_array(allocator, ClipId, importer.scene.anim_stacks.len);
    defer catch alloc::free(allocator, clips.ptr);
    defer catch remove_clips(assets, clips);
    @pool() {
        String mode = mode_label(options.root_motion);
        String rest = options.rest_pose == RestPose.CORRECT ? "#rest" : "";
        foreach (index, stack : importer.scene.anim_stacks) {
            String key = string::tformat("%s#anim/%d#%s#%s%s", path, index, record.header.key, mode, rest);
            if (assets.keys.has_key(key)) return c3d::INVALID_ARGUMENT~;
        }
        importer.node_remap = alloc::new_array(assets.allocator, uint, importer.scene.nodes.len);
        importer.node_remap[..] = NOT_IMPORTED;
        build_template(&importer)!;
        foreach (index, stack : importer.scene.anim_stacks) {
            AnimationClip baked = convert_stack(&importer, stack, tmem)!;
            AnimationClip clip = retarget::retarget_by_name(
                allocator:    assets.allocator,
                source:       &baked,
                source_nodes: importer.template.nodes,
                target:       &record.data,
                options:      options,
            )!;
            defer catch asset::free_clip(assets.allocator, &clip);
            String key = string::tformat("%s#anim/%d#%s#%s%s", path, index, record.header.key, mode, rest);
            clips[index] = assets.add_clip_owned(&clip, key)!;
        }
    };
    return clips;
}

fn ufbx::Scene*? parse_scene(String path, FileSource* file_source) @private {
    // ufbx attaches Blender's roughness, metallic and alpha textures to the pbr maps only on request.
    ufbx::LoadOpts options = {
        .target_axes                 = ufbx::axes_right_handed_y_up,
        .target_unit_meters          = 1,
        .space_conversion            = ufbx::SpaceConversion.MODIFY_GEOMETRY,
        .target_light_axes           = ufbx::axes_right_handed_y_up,
        .target_camera_axes          = ufbx::axes_right_handed_y_up,
        .generate_missing_normals    = true,
        .inherit_mode_handling       = ufbx::InheritModeHandling.COMPENSATE,
        .geometry_transform_handling = ufbx::GeometryTransformHandling.PRESERVE,
        .use_blender_pbr_material    = true,
        .open_file_cb                = { .fn_ = &open_through_source, .user = file_source },
    };
    ufbx::Scene*? scene = ufbx::load_file(path, &options);
    if (catch excuse = scene) return load_fault(excuse)~;
    return scene;
}

fn bool open_through_source(
    void* user,
    ufbx::Stream* stream,
    ZString path,
    usz path_len,
    ufbx::OpenFileInfo* info,
) @private {
    FileSource* file_source = user;
    String name = (String)((char*)path)[:path_len];
    char[]? bytes = file_source.read_path(mem, name);
    if (catch bytes) return false;
    defer alloc::free(mem, bytes.ptr);
    ufbx::OpenMemoryOpts memory_options;
    ufbx::Error error;
    return ufbx::open_memory(stream, bytes.ptr, bytes.len, &memory_options, &error);
}

fn Importer create_importer(
    alloc::Allocator allocator,
    ufbx::Scene* scene,
    String key,
    LoadOptions options,
) @private {
    usz part_count;
    usz[] part_offsets = alloc::new_array(allocator, usz, scene.meshes.len + 1);
    foreach (index, mesh : scene.meshes) {
        part_offsets[index] = part_count;
        part_count += mesh.material_parts.len;
    }
    part_offsets[scene.meshes.len] = part_count;
    usz derived_count = scene.materials.len * DERIVED_TEXTURES_PER_MATERIAL;
    ModelDocumentBounds bounds = {
        .samplers   = MIXED_SAMPLER_COUNT,
        .textures   = COLOR_SPACES_PER_TEXTURE * scene.textures.len + derived_count,
        .materials  = scene.materials.len + 1,
        .geometries = part_count,
        .skeletons  = scene.skin_deformers.len,
        .clips      = scene.anim_stacks.len,
    };
    Importer importer = {
        .allocator        = allocator,
        .scene            = scene,
        .key              = key,
        .options          = options,
        .srgb_textures    = alloc::new_array(allocator, TextureId, scene.textures.len),
        .linear_textures  = alloc::new_array(allocator, TextureId, scene.textures.len),
        .derived_textures = alloc::new_array(allocator, DerivedTexture, (sz)derived_count),
        .materials        = alloc::new_array(allocator, MaterialId, scene.materials.len),
        .part_offsets     = part_offsets,
        .geometries       = alloc::new_array(allocator, GeometryId, (sz)part_count),
        .skeletons        = alloc::new_array(allocator, SkeletonId, scene.skin_deformers.len),
        .clips            = alloc::new_array(allocator, ClipId, scene.anim_stacks.len),
        .node_remap       = alloc::new_array(allocator, uint, scene.nodes.len),
        .document         = asset::create_model_document(allocator, key, bounds),
    };
    importer.node_remap[..] = NOT_IMPORTED;
    return importer;
}

fn void? convert_model(Importer* importer) @private {
    convert_materials(importer)!;
    convert_geometries(importer)!;
    build_template(importer)!;
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
    alloc::Allocator allocator = importer.allocator;
    alloc::free(allocator, importer.part_offsets.ptr);
    alloc::free(allocator, importer.srgb_textures.ptr);
    alloc::free(allocator, importer.linear_textures.ptr);
    alloc::free(allocator, importer.derived_textures.ptr);
    alloc::free(allocator, importer.materials.ptr);
    alloc::free(allocator, importer.geometries.ptr);
    alloc::free(allocator, importer.skeletons.ptr);
    alloc::free(allocator, importer.clips.ptr);
    alloc::free(allocator, importer.node_remap.ptr);
}

fn void remove_clips(AssetStore* assets, ClipId[] clips) @private {
    foreach (id : clips) if (id.generation) assets.remove_clip(id);
}

fn String mode_label(RootMotion mode) @private {
    switch (mode) {
        case KEEP: return "keep";
        case STRIP_XZ: return "strip_xz";
        case EXTRACT: return "extract";
    }
}

fn fault load_fault(fault excuse) @private {
    if (excuse == ufbx::FILE_NOT_FOUND || excuse == ufbx::IO) return c3d::ASSET_IO_ERROR;
    return c3d::ASSET_FORMAT_ERROR;
}

fn String copy_name(alloc::Allocator allocator, String name) @private {
    return name.len ? name.copy(allocator) : (String){};
}

fn String join_path(String directory, String name) @private {
    if (!directory.len) return name;
    return string::tformat("%s/%s", directory, name);
}

fn usz live_part_count(ufbx::Mesh* mesh) @private {
    usz count;
    foreach (&part : mesh.material_parts) if (part.num_triangles) count++;
    return count;
}

fn usz channel_count(ufbx::Mesh* mesh) @private {
    usz count;
    foreach (deformer : mesh.blend_deformers) count += deformer.channels.len;
    return count;
}

macro @each_channel(ufbx::Mesh* mesh; @body(ufbx::BlendChannel* channel)) @private {
    foreach (deformer : mesh.blend_deformers) {
        foreach (channel : deformer.channels) @body(channel);
    }
}
