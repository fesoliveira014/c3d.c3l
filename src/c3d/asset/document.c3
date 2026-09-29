module c3d::asset;

import c3d;
import c3d::anim;
import c3d::material;

<*
 Entry capacities of a model document, fixed before conversion.
*>
struct ModelDocumentBounds {
    usz samplers;
    usz textures;
    usz materials;
    usz geometries;
    usz skeletons;
    usz clips;
}

<*
 Sampler decoded from a model file.
*>
struct DocumentSampler {
    SamplerDesc desc;
    String      key;
}

<*
 Texture decoded from a model file; pixels are mip zero.
*>
struct DocumentTexture {
    TextureDesc desc;
    char[]      pixels;
    String      key;
}

<*
 Material decoded from a model file.
*>
struct DocumentMaterial {
    Material data;
    String   key;
}

<*
 Geometry decoded from a model file.
*>
struct DocumentGeometry {
    Geometry data;
    String   key;
}

<*
 Skeleton decoded from a model file.
*>
struct DocumentSkeleton {
    Skeleton data;
    String   key;
}

<*
 Animation clip decoded from a model file.
*>
struct DocumentClip {
    AnimationClip data;
    String        key;
}

<*
 Store-free result of decoding one model file.
 References hold document index plus one at generation zero; the zero id is none.
*>
struct ModelDocument {
    Allocator           allocator;
    String              key;
    ModelDocumentBounds bounds;
    DocumentSampler[]   samplers;
    DocumentTexture[]   textures;
    DocumentMaterial[]  materials;
    DocumentGeometry[]  geometries;
    DocumentSkeleton[]  skeletons;
    DocumentClip[]      clips;
    ModelTemplate       template;
}

struct PublishedIds @local {
    SamplerId[]  samplers;
    TextureId[]  textures;
    MaterialId[] materials;
    GeometryId[] geometries;
    SkeletonId[] skeletons;
    ClipId[]     clips;
}

<*
 Append a sampler and return its reference.
 @param key : "Copied into the document allocator."
 @require self.samplers.len < self.bounds.samplers
*>
fn SamplerId ModelDocument.push_sampler(&self, SamplerDesc desc, String key) {
    @append_entry(self.samplers);
    self.samplers[^1] = { .desc = desc, .key = copy_string(self.allocator, key) };
    return @document_reference(SamplerId, self.samplers.len - 1);
}

<*
 Append a texture that takes over its pixels and return its reference.
 @param pixels : "Mip zero, allocated with the document allocator."
 @param key : "Copied into the document allocator."
 @require self.textures.len < self.bounds.textures
*>
fn TextureId ModelDocument.push_texture(
    &self,
    TextureDesc desc,
    char[] pixels,
    String key,
) {
    @append_entry(self.textures);
    self.textures[^1] = { .desc = desc, .pixels = pixels, .key = copy_string(self.allocator, key) };
    return @document_reference(TextureId, self.textures.len - 1);
}

<*
 Append a material and return its reference.
 @param material : "Slots hold references, builtin ids or the zero id."
 @param key : "Copied into the document allocator."
 @require self.materials.len < self.bounds.materials
*>
fn MaterialId ModelDocument.push_material(&self, Material material, String key) {
    @append_entry(self.materials);
    self.materials[^1] = { .data = material, .key = copy_string(self.allocator, key) };
    return @document_reference(MaterialId, self.materials.len - 1);
}

<*
 Append a geometry that takes over its arrays and return its reference.
 @param [&in] geometry : "Arrays were allocated with the document allocator."
 @param key : "Copied into the document allocator."
 @require self.geometries.len < self.bounds.geometries
*>
fn GeometryId ModelDocument.push_geometry(&self, Geometry* geometry, String key) {
    @append_entry(self.geometries);
    self.geometries[^1] = { .data = *geometry, .key = copy_string(self.allocator, key) };
    return @document_reference(GeometryId, self.geometries.len - 1);
}

<*
 Append a skeleton that takes over its arrays and return its reference.
 @param [&in] skeleton : "Arrays were allocated with the document allocator."
 @param key : "Copied into the document allocator."
 @require self.skeletons.len < self.bounds.skeletons
*>
fn SkeletonId ModelDocument.push_skeleton(&self, Skeleton* skeleton, String key) {
    @append_entry(self.skeletons);
    self.skeletons[^1] = { .data = *skeleton, .key = copy_string(self.allocator, key) };
    return @document_reference(SkeletonId, self.skeletons.len - 1);
}

<*
 Append a clip that takes over its arrays and return its reference.
 @param [&in] clip : "Arrays were allocated with the document allocator."
 @param key : "Copied into the document allocator."
 @require self.clips.len < self.bounds.clips
*>
fn ClipId ModelDocument.push_clip(&self, AnimationClip* clip, String key) {
    @append_entry(self.clips);
    self.clips[^1] = { .data = *clip, .key = copy_string(self.allocator, key) };
    return @document_reference(ClipId, self.clips.len - 1);
}

<*
 Entry a material reference names; a borrow into the document.
 @require document_index(reference) < self.materials.len
*>
fn DocumentMaterial* ModelDocument.material(&self, MaterialId reference) {
    return &self.materials[document_index(reference)];
}

<*
 Entry a geometry reference names; a borrow into the document.
 @require document_index(reference) < self.geometries.len
*>
fn DocumentGeometry* ModelDocument.geometry(&self, GeometryId reference) {
    return &self.geometries[document_index(reference)];
}

<*
 Insert a decoded document into the store and return its model.
 Decides every fault before the first insertion; the store is unchanged on a fault.
 @param [&inout] document : "Emptied on success; intact on a fault."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require document.allocator == self.allocator
 @require self.allocator != tmem
*>
fn ModelId? AssetStore.publish_document(&self, ModelDocument* document) {
    ModelId model;
    @pool() {
        check_document(self, document)!;
        PublishedIds ids = {
            .samplers   = alloc::new_array(tmem, SamplerId, (sz)document.samplers.len),
            .textures   = alloc::new_array(tmem, TextureId, (sz)document.textures.len),
            .materials  = alloc::new_array(tmem, MaterialId, (sz)document.materials.len),
            .geometries = alloc::new_array(tmem, GeometryId, (sz)document.geometries.len),
            .skeletons  = alloc::new_array(tmem, SkeletonId, (sz)document.skeletons.len),
            .clips      = alloc::new_array(tmem, ClipId, (sz)document.clips.len),
        };

        // check_document decided every fault; one here is a defect in it.
        foreach (index, &entry : document.samplers) {
            ids.samplers[index] = self.add_sampler(entry.desc, entry.key)!!;
        }
        foreach (index, &entry : document.textures) {
            ids.textures[index] = self.add_texture_owned(entry.desc, entry.pixels, entry.key)!!;
            entry.pixels = {};
        }
        foreach (index, &entry : document.materials) {
            material::@each_texture_reference(&entry.data; TextureId* texture, SamplerId* sampler) {
                *texture = @remapped(*texture, ids.textures);
                if (sampler) *sampler = @remapped(*sampler, ids.samplers);
            };
            ids.materials[index] = self.add_material(entry.data, entry.key)!!;
        }
        foreach (index, &entry : document.geometries) {
            ids.geometries[index] = self.add_geometry_owned(&entry.data, entry.key)!!;
            entry.data = {};
        }
        foreach (index, &entry : document.skeletons) {
            ids.skeletons[index] = self.add_skeleton_owned(&entry.data, entry.key)!!;
            entry.data = {};
        }
        foreach (index, &entry : document.clips) {
            ids.clips[index] = self.add_clip_owned(&entry.data, entry.key)!!;
            entry.data = {};
        }

        remap_template(&document.template, &ids);
        model = self.add_model_owned(&document.template, document.key)!!;
        document.template = {};
    };
    destroy_model_document(document);
    return model;
}

<*
 Empty document with every entry array allocated at its bound.
 @param key : "Model key; copied into the allocator."
*>
fn ModelDocument create_model_document(Allocator allocator, String key, ModelDocumentBounds bounds) {
    return {
        .allocator  = allocator,
        .key        = copy_string(allocator, key),
        .bounds     = bounds,
        .samplers   = alloc::new_array(allocator, DocumentSampler, (sz)bounds.samplers)[:0],
        .textures   = alloc::new_array(allocator, DocumentTexture, (sz)bounds.textures)[:0],
        .materials  = alloc::new_array(allocator, DocumentMaterial, (sz)bounds.materials)[:0],
        .geometries = alloc::new_array(allocator, DocumentGeometry, (sz)bounds.geometries)[:0],
        .skeletons  = alloc::new_array(allocator, DocumentSkeleton, (sz)bounds.skeletons)[:0],
        .clips      = alloc::new_array(allocator, DocumentClip, (sz)bounds.clips)[:0],
    };
}

<*
 Release whatever the document still owns, including what a publish left.
 @param [&inout] document : "Left empty; the allocator is kept."
 @require document.allocator != null
*>
fn void destroy_model_document(ModelDocument* document) {
    Allocator allocator = document.allocator;
    foreach (&entry : document.samplers) free_string(allocator, entry.key);
    foreach (&entry : document.textures) {
        alloc::free(allocator, entry.pixels.ptr);
        free_string(allocator, entry.key);
    }
    foreach (&entry : document.materials) free_string(allocator, entry.key);
    foreach (&entry : document.geometries) {
        free_geometry(allocator, &entry.data);
        free_string(allocator, entry.key);
    }
    foreach (&entry : document.skeletons) {
        free_skeleton(allocator, &entry.data);
        free_string(allocator, entry.key);
    }
    foreach (&entry : document.clips) {
        free_clip(allocator, &entry.data);
        free_string(allocator, entry.key);
    }
    alloc::free(allocator, document.samplers.ptr);
    alloc::free(allocator, document.textures.ptr);
    alloc::free(allocator, document.materials.ptr);
    alloc::free(allocator, document.geometries.ptr);
    alloc::free(allocator, document.skeletons.ptr);
    alloc::free(allocator, document.clips.ptr);
    free_model_template(allocator, &document.template);
    free_string(allocator, document.key);
    *document = { .allocator = allocator };
}

fn void? check_document(AssetStore* store, ModelDocument* document) @local {
    String[] keys = document_keys(document);
    foreach (key : keys) check_key(store, key)!;
    foreach (index, key : keys) {
        if (!key.len) continue;
        foreach (other : keys[index + 1..]) {
            if (other == key) return c3d::INVALID_ARGUMENT~;
        }
    }

    bool fits = store.samplers.free_count >= document.samplers.len
        && store.textures.free_count >= document.textures.len
        && store.materials.free_count >= document.materials.len
        && store.geometries.free_count >= document.geometries.len
        && store.skeletons.free_count >= document.skeletons.len
        && store.clips.free_count >= document.clips.len
        && store.models.free_count >= 1;
    if (!fits) return c3d::CAPACITY_EXCEEDED~;

    foreach (&entry : document.materials) {
        if (entry.data.kind == MaterialKind.CUSTOM) return c3d::INVALID_ARGUMENT~;
    }
    foreach (&entry : document.geometries) check_influences(&entry.data)!;
    foreach (&entry : document.textures) check_format_use(entry.desc)!;
    return;
}

fn String[] document_keys(ModelDocument* document) @local {
    usz count = 1 + document.samplers.len + document.textures.len + document.materials.len
        + document.geometries.len + document.skeletons.len + document.clips.len;
    String[] keys = alloc::new_array(tmem, String, (sz)count);
    usz next;
    keys[next++] = document.key;
    foreach (&entry : document.samplers) keys[next++] = entry.key;
    foreach (&entry : document.textures) keys[next++] = entry.key;
    foreach (&entry : document.materials) keys[next++] = entry.key;
    foreach (&entry : document.geometries) keys[next++] = entry.key;
    foreach (&entry : document.skeletons) keys[next++] = entry.key;
    foreach (&entry : document.clips) keys[next++] = entry.key;
    return keys;
}

fn void remap_template(ModelTemplate* template, PublishedIds* ids) @local {
    foreach (&mesh : template.meshes) {
        mesh.geometry = @remapped(mesh.geometry, ids.geometries);
        mesh.material = @remapped(mesh.material, ids.materials);
    }
    foreach (&skin : template.skins) skin.skeleton = @remapped(skin.skeleton, ids.skeletons);
    foreach (&clip : template.clips) *clip = @remapped(*clip, ids.clips);
}

macro @append_entry(#entries) @local {
    #entries = #entries.ptr[:#entries.len + 1];
}

macro @remapped(id, ids) @local {
    if (id.generation || !id.index) return id;
    return ids[document_index(id)];
}

macro @document_reference($IdType, usz index) @private => ($IdType){ .index = (uint)index + 1 };

<*
 @require reference.generation == 0 && reference.index > 0
*>
macro usz document_index(reference) @private => (usz)reference.index - 1;
