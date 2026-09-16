module c3d::asset;

import c3d;
import c3d::pool;
import std::collections::map;

const uint DEFAULT_MAX_GEOMETRIES @local   = 4096; // 15 Asset Store defaults; one mirror slot each in the renderer
const uint DEFAULT_MAX_TEXTURES @local     = 4096;
const uint DEFAULT_MAX_MATERIALS @local    = 4096; // one heap slot each in the renderer
const uint DEFAULT_MAX_SAMPLERS @local     = 64;
const uint DEFAULT_MAX_ENVIRONMENTS @local = 16; // one CPU record and renderer mirror slot each; scene-wide assets
const uint DEFAULT_MAX_MODELS @local       = 256; // one template record each; arrays are sized by the loader
const uint DEFAULT_MAX_SKELETONS @local    = 256; // one record each; joint arrays are sized by the loader
const uint DEFAULT_MAX_CLIPS @local        = 1024; // one record each; key arrays are sized by the loader
const uint DEFAULT_MAX_SHADERS @local      = 64; // one ShaderRes each in the renderer; a scene has a handful of user shaders
const uint DEFAULT_MAX_COMPUTE_SHADERS @local = 16; // one ComputeShaderRes each in the renderer; a scene has a few compute stages

<*
 Key and content revision shared by every asset record.
*>
struct AssetHeader {
    String key;
    uint   revision;
}

<*
 Pool capacities of a store; fixed at creation.
*>
struct AssetStoreDesc {
    uint max_geometries;
    uint max_textures;
    uint max_materials;
    uint max_samplers;
    uint max_environments;
    uint max_models;
    uint max_skeletons;
    uint max_clips;
    uint max_shaders;
    uint max_compute_shaders;
}

<*
 Owner of every CPU asset and the ids that name them.
*>
struct AssetStore {
    Allocator                 allocator;
    GeometryPool              geometries;
    TexturePool               textures;
    MaterialPool              materials;
    SamplerPool               samplers;
    EnvironmentPool           environments;
    ModelPool                 models;
    SkeletonPool              skeletons;
    ClipPool                  clips;
    ShaderPool                shaders;
    ComputeShaderPool         compute_shaders;
    HashMap{String, AssetRef} keys;
}

<*
 Kind and id under a key, for browsers that span kinds.
 @return? NOT_FOUND
*>
fn AssetRef? AssetStore.find(&self, String key) {
    return self.keys.get(key);
}

<*
 Geometry id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn GeometryId? AssetStore.find_geometry(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.GEOMETRY) return c3d::INVALID_ARGUMENT~;
    return (GeometryId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Texture id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn TextureId? AssetStore.find_texture(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.TEXTURE) return c3d::INVALID_ARGUMENT~;
    return (TextureId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Material id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn MaterialId? AssetStore.find_material(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.MATERIAL) return c3d::INVALID_ARGUMENT~;
    return (MaterialId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Sampler id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn SamplerId? AssetStore.find_sampler(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.SAMPLER) return c3d::INVALID_ARGUMENT~;
    return (SamplerId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Capacities for a scene of ordinary size.
*>
fn AssetStoreDesc default_asset_store_desc() {
    return {
        .max_geometries   = DEFAULT_MAX_GEOMETRIES,
        .max_textures     = DEFAULT_MAX_TEXTURES,
        .max_materials    = DEFAULT_MAX_MATERIALS,
        .max_samplers     = DEFAULT_MAX_SAMPLERS,
        .max_environments = DEFAULT_MAX_ENVIRONMENTS,
        .max_models       = DEFAULT_MAX_MODELS,
        .max_skeletons    = DEFAULT_MAX_SKELETONS,
        .max_clips        = DEFAULT_MAX_CLIPS,
        .max_shaders      = DEFAULT_MAX_SHADERS,
        .max_compute_shaders = DEFAULT_MAX_COMPUTE_SHADERS,
    };
}

<*
 Create a store holding the builtin textures and samplers.
 @require desc.max_geometries > 0
 @require desc.max_textures >= BUILTIN_TEXTURE_COUNT
 @require desc.max_materials > 0
 @require desc.max_samplers >= BUILTIN_SAMPLER_COUNT
*>
fn AssetStore create_asset_store(Allocator allocator, AssetStoreDesc desc) {
    if (!desc.max_environments) desc.max_environments = DEFAULT_MAX_ENVIRONMENTS;
    if (!desc.max_models) desc.max_models = DEFAULT_MAX_MODELS;
    if (!desc.max_skeletons) desc.max_skeletons = DEFAULT_MAX_SKELETONS;
    if (!desc.max_clips) desc.max_clips = DEFAULT_MAX_CLIPS;
    if (!desc.max_shaders) desc.max_shaders = DEFAULT_MAX_SHADERS;
    if (!desc.max_compute_shaders) desc.max_compute_shaders = DEFAULT_MAX_COMPUTE_SHADERS;
    AssetStore store = {
        .allocator    = allocator,
        .geometries   = pool::create_pool{GeometryAsset, GeometryId}(allocator, desc.max_geometries),
        .textures     = pool::create_pool{TextureAsset, TextureId}(allocator, desc.max_textures),
        .materials    = pool::create_pool{MaterialAsset, MaterialId}(allocator, desc.max_materials),
        .samplers     = pool::create_pool{SamplerAsset, SamplerId}(allocator, desc.max_samplers),
        .environments = pool::create_pool{EnvironmentAsset, EnvironmentId}(allocator, desc.max_environments),
        .models       = pool::create_pool{ModelAsset, ModelId}(allocator, desc.max_models),
        .skeletons    = pool::create_pool{SkeletonAsset, SkeletonId}(allocator, desc.max_skeletons),
        .clips        = pool::create_pool{ClipAsset, ClipId}(allocator, desc.max_clips),
        .shaders      = pool::create_pool{ShaderAsset, ShaderId}(allocator, desc.max_shaders),
        .compute_shaders = pool::create_pool{ComputeShaderAsset, ComputeShaderId}(allocator, desc.max_compute_shaders),
    };
    store.keys.init(allocator);
    add_builtins(&store);
    return store;
}

<*
 Free every record's payload, the keys, and the pools.
 @param [&inout] store : "Left zeroed; every id of it is dead."
*>
fn void destroy_asset_store(AssetStore* store) {
    foreach (&record : store.geometries.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_geometry(store.allocator, &record.data);
    }
    foreach (&record : store.textures.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_texture_source(store.allocator, record);
    }
    foreach (&record : store.materials.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_custom_params(store.allocator, &record.data);
    }
    foreach (&record : store.samplers.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
    }
    foreach (&record : store.environments.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
    }
    foreach (&record : store.models.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_model_template(store.allocator, &record.data);
    }
    foreach (&record : store.skeletons.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_skeleton(store.allocator, &record.data);
    }
    foreach (&record : store.clips.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_clip(store.allocator, &record.data);
    }
    foreach (&record : store.shaders.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        free_shader_desc(store.allocator, &record.desc);
    }
    foreach (&record : store.compute_shaders.items) {
        if (!record.header.revision) continue;
        free_string(store.allocator, record.header.key);
        alloc::free(store.allocator, record.desc.compute.ptr);
    }
    store.keys.free();
    pool::destroy_pool{GeometryAsset, GeometryId}(&store.geometries);
    pool::destroy_pool{TextureAsset, TextureId}(&store.textures);
    pool::destroy_pool{MaterialAsset, MaterialId}(&store.materials);
    pool::destroy_pool{SamplerAsset, SamplerId}(&store.samplers);
    pool::destroy_pool{EnvironmentAsset, EnvironmentId}(&store.environments);
    pool::destroy_pool{ModelAsset, ModelId}(&store.models);
    pool::destroy_pool{SkeletonAsset, SkeletonId}(&store.skeletons);
    pool::destroy_pool{ClipAsset, ClipId}(&store.clips);
    pool::destroy_pool{ShaderAsset, ShaderId}(&store.shaders);
    pool::destroy_pool{ComputeShaderAsset, ComputeShaderId}(&store.compute_shaders);
    *store = {};
}

fn void? check_key(AssetStore* store, String key) @private {
    if (key.len && store.keys.has_key(key)) return c3d::INVALID_ARGUMENT~;
    return;
}

fn void register_key(AssetStore* store, String key, AssetRef ref) @private {
    if (key.len) store.keys.set(key, ref);
}

fn void forget_key(AssetStore* store, String key) @private {
    if (key.len) (void)store.keys.remove(key);
}

fn String copy_string(Allocator allocator, String key) @private {
    return key.len ? key.copy(allocator) : (String){};
}

fn void free_string(Allocator allocator, String key) @private {
    alloc::free(allocator, key.ptr);
}

macro AssetRef typed_ref(AssetKind kind, id) @private {
    return { .kind = kind, .id = { .index = id.index, .generation = id.generation } };
}

macro copy_slice(Allocator allocator, slice) @private {
    var $Element = $Typeof(slice[0]);
    $Element[] copy = alloc::new_array(allocator, $Element, slice.len);
    copy[..] = slice[..];
    return copy;
}
