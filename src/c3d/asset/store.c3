module c3d::asset;

import c3d;
import c3d::pool;
import std::collections::map;

<*
 Payload release of one custom record at store destruction.
 @param [inout] data : "Payload; arrays came from allocator."
 @param [in] user : "Pointer given to register."
*>
alias CustomFreeFn = fn void (Allocator allocator, void* data, void* user);

alias ErasedDestroy @local = fn void (void* erased, Allocator allocator, CustomFreeFn on_destroy, void* user);

<*
 Custom asset kinds one process can register.
*>
const uint MAX_CUSTOM_ASSET_TYPES = 16; // one CustomSlot per store; a scene has a few add-on kinds

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

uint registered_kind_count @local;

<*
 Key and content revision shared by every asset record.
*>
struct AssetHeader {
    String key;
    uint   revision;
}

struct CustomSlot @private {
    void*         pool;
    ErasedDestroy destroy;
    CustomFreeFn  on_destroy;
    void*         user;
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
    CustomSlot[MAX_CUSTOM_ASSET_TYPES] custom;
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
 Give the type a process-wide kind slot and this store a pool.
 A repeated call keeps the first capacity and hook.
 @param on_destroy : "Runs on each live record at store destruction."
 @param [in] user : "Passed to on_destroy unchanged."
 @return? c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
macro void? AssetStore.register(
    &self,
    $Type,
    uint capacity,
    CustomFreeFn on_destroy = null,
    void* user = null,
) {
    if (!custom::slot{$Type}) {
        if (registered_kind_count == MAX_CUSTOM_ASSET_TYPES) return c3d::CAPACITY_EXCEEDED~;
        registered_kind_count++;
        custom::slot{$Type} = registered_kind_count;
    }
    CustomSlot* slot = &self.custom[custom::slot{$Type} - 1];
    if (slot.pool) return;
    *slot = {
        .pool       = custom::create_erased{$Type}(self.allocator, capacity),
        .destroy    = &custom::destroy_erased{$Type},
        .on_destroy = on_destroy,
        .user       = user,
    };
    return;
}

<*
 Whether this store has a pool for the type.
*>
macro bool AssetStore.is_registered(&self, $Type) {
    return custom::slot{$Type} != 0 && self.custom[custom::slot{$Type} - 1].pool != null;
}

<*
 Pool of the registered kind.
 @require self.is_registered($Type)
*>
macro AssetStore.pool(&self, $Type) {
    return (custom::CustomPool{$Type}*)self.custom[custom::slot{$Type} - 1].pool;
}

<*
 Kind-carrying reference of a custom id, for key registration.
 @require custom::slot{$Type} != 0
*>
macro AssetRef custom_ref($Type, id) {
    return {
        .kind = AssetKind.CUSTOM,
        .slot = custom::slot{$Type},
        .id   = { .index = id.index, .generation = id.generation },
    };
}

<*
 Custom id of a reference of the type's kind.
 @return? c3d::INVALID_ARGUMENT
*>
macro custom_id($Type, AssetRef ref) {
    if (ref.kind != AssetKind.CUSTOM || ref.slot != custom::slot{$Type}) return c3d::INVALID_ARGUMENT~;
    return (custom::CustomId{$Type}){ .index = ref.id.index, .generation = ref.id.generation };
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
        geometry::free_skin_bounds(store.allocator, &record.skin_bounds);
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
    foreach (&slot : store.custom) {
        if (slot.pool) slot.destroy(slot.pool, store.allocator, slot.on_destroy, slot.user);
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

<*
 Fault when a non-empty key is already taken.
 @param [&in] store
 @return? c3d::INVALID_ARGUMENT
*>
fn void? check_key(AssetStore* store, String key) {
    if (key.len && store.keys.has_key(key)) return c3d::INVALID_ARGUMENT~;
    return;
}

<*
 Map a non-empty key to the reference.
 @param [&inout] store
*>
fn void register_key(AssetStore* store, String key, AssetRef ref) {
    if (key.len) store.keys.set(key, ref);
}

<*
 Drop a non-empty key.
 @param [&inout] store
*>
fn void forget_key(AssetStore* store, String key) {
    if (key.len) (void)store.keys.remove(key);
}

<*
 Copy of the key in the allocator; an empty key stays empty.
*>
fn String copy_string(Allocator allocator, String key) {
    return key.len ? key.copy(allocator) : (String){};
}

<*
 Free a key made by copy_string.
*>
fn void free_string(Allocator allocator, String key) {
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
