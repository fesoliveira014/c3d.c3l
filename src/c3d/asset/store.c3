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
    AssetStore store = {
        .allocator    = allocator,
        .geometries   = pool::create_pool{GeometryAsset, GeometryId}(allocator, desc.max_geometries),
        .textures     = pool::create_pool{TextureAsset, TextureId}(allocator, desc.max_textures),
        .materials    = pool::create_pool{MaterialAsset, MaterialId}(allocator, desc.max_materials),
        .samplers     = pool::create_pool{SamplerAsset, SamplerId}(allocator, desc.max_samplers),
        .environments = pool::create_pool{EnvironmentAsset, EnvironmentId}(allocator, desc.max_environments),
        .models       = pool::create_pool{ModelAsset, ModelId}(allocator, desc.max_models),
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
    store.keys.free();
    pool::destroy_pool{GeometryAsset, GeometryId}(&store.geometries);
    pool::destroy_pool{TextureAsset, TextureId}(&store.textures);
    pool::destroy_pool{MaterialAsset, MaterialId}(&store.materials);
    pool::destroy_pool{SamplerAsset, SamplerId}(&store.samplers);
    pool::destroy_pool{EnvironmentAsset, EnvironmentId}(&store.environments);
    pool::destroy_pool{ModelAsset, ModelId}(&store.models);
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
