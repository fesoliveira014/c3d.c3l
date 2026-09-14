module c3d::asset::fbx;

import c3d;
import c3d::asset;
import std::io::path;
import ufbx;

const uint NOT_IMPORTED @private = uint::max;
const uint NO_TEXTURE @private = uint::max;
const usz MIXED_REPEAT_CLAMP @private = 0;
const usz MIXED_CLAMP_REPEAT @private = 1;
const usz DERIVED_TEXTURES_PER_MATERIAL @private = 2; // one packed metallic-roughness map and one base-opacity map

struct DerivedTexture @private {
    uint      first;
    uint      second;
    bool      metallic_roughness;
    TextureId texture;
}

struct Importer @private {
    AssetStore*      assets;
    ufbx::Scene*     scene;
    String           key;
    String           base_dir;
    LoadOptions      options;
    TextureId[]      srgb_textures;
    TextureId[]      linear_textures;
    DerivedTexture[] derived_textures;
    usz              derived_count;
    SamplerId[2]     mixed_samplers;
    MaterialId[]     materials;
    MaterialId       default_material;
    usz[]            part_offsets;
    GeometryId[]     geometries;
    SkeletonId[]     skeletons;
    ClipId[]         clips;
    uint[]           node_remap;
    ModelTemplate    template;
    ModelId          model;
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
    Importer importer = { .assets = assets, .key = path, .options = options };
    defer free_tables(&importer);
    defer catch discard(&importer);
    importer.scene = parse_scene(path)!;
    defer ufbx::free_scene(importer.scene);
    @pool() {
        importer.base_dir = path.path_tdirname() ?? "";
        import_model(&importer)!;
    };
    return importer.model;
}

fn ufbx::Scene*? parse_scene(String path) @private {
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
    };
    ufbx::Scene*? scene = ufbx::load_file(path, &options);
    if (catch excuse = scene) return load_fault(excuse)~;
    return scene;
}

fn void? import_model(Importer* importer) @private {
    ufbx::Scene* scene = importer.scene;
    alloc::Allocator allocator = importer.assets.allocator;

    usz part_count;
    importer.part_offsets = alloc::new_array(allocator, usz, scene.meshes.len + 1);
    foreach (index, mesh : scene.meshes) {
        importer.part_offsets[index] = part_count;
        part_count += mesh.material_parts.len;
    }
    importer.part_offsets[scene.meshes.len] = part_count;
    importer.srgb_textures = alloc::new_array(allocator, TextureId, scene.textures.len);
    importer.linear_textures = alloc::new_array(allocator, TextureId, scene.textures.len);
    importer.derived_textures = alloc::new_array(
        allocator,
        DerivedTexture,
        scene.materials.len * DERIVED_TEXTURES_PER_MATERIAL,
    );
    importer.materials = alloc::new_array(allocator, MaterialId, scene.materials.len);
    importer.geometries = alloc::new_array(allocator, GeometryId, (sz)part_count);
    importer.skeletons = alloc::new_array(allocator, SkeletonId, scene.skin_deformers.len);
    importer.clips = alloc::new_array(allocator, ClipId, scene.anim_stacks.len);
    importer.node_remap = alloc::new_array(allocator, uint, scene.nodes.len);
    importer.node_remap[..] = NOT_IMPORTED;

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
    foreach (&derived : importer.derived_textures[:importer.derived_count]) assets.remove_texture(derived.texture);
    foreach (id : importer.srgb_textures) if (id.generation) assets.remove_texture(id);
    foreach (id : importer.linear_textures) if (id.generation) assets.remove_texture(id);
    foreach (id : importer.mixed_samplers) if (id.generation) assets.remove_sampler(id);
}

fn void free_tables(Importer* importer) @private {
    alloc::Allocator allocator = importer.assets.allocator;
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
