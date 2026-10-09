module c3d::asset;

import c3d;
import c3d::anim;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;

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

struct PublishedIds @private {
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
    PreparedModelDocument prepared = prepare_model_document(document)!;
    defer destroy_prepared_model_document(&prepared);
    ModelId? model = publish_prepared_model_document(self, &prepared);
    if (catch excuse = model) {
        *document = prepared.document;
        prepared.document = { .allocator = document.allocator };
        return excuse~;
    }
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

fn void? check_lod_groups(AssetStore* store, ModelTemplate* template, ModelDocument* document) @private {
    foreach (index, &group : template.lod_groups) {
        if (group.node >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
        scene::validate_lod_layout(group.desc)!;
        foreach (previous : template.lod_groups[:index]) {
            if (previous.node == group.node) return c3d::INVALID_ARGUMENT~;
        }
        foreach (mesh : template.meshes) {
            if (mesh.node == group.node) return c3d::INVALID_ARGUMENT~;
        }
        foreach (skin : template.skins) {
            if (skin.mesh_node == group.node) return c3d::INVALID_ARGUMENT~;
        }
        foreach (part : group.desc.parts) {
            Aabb bounds;
            if (part.geometry.generation) {
                if (!store.geometries.is_live(part.geometry)) return c3d::INVALID_ARGUMENT~;
                GeometryAsset* geometry = store.geometry(part.geometry);
                if (geometry.target_count || geometry.skin_bounds.joints.len || geometry.data.joints.len) return c3d::INVALID_ARGUMENT~;
                bounds = geometry.data.bounds;
            } else {
                if (!document || !part.geometry.index || part.geometry.index > document.geometries.len) {
                    return c3d::INVALID_ARGUMENT~;
                }
                Geometry* geometry = &document.geometries[document_index(part.geometry)].data;
                if (geometry.targets.len || geometry.joints.len) return c3d::INVALID_ARGUMENT~;
                bounds = geometry.bounds;
            }
            bounds = maths::aabb_transform(bounds, part.local);
            for (uint axis = 0; axis < 3; axis++) {
                if (!math::is_finite(bounds.min[axis]) || !math::is_finite(bounds.max[axis])
                  || bounds.min[axis] > bounds.max[axis]) return c3d::INVALID_ARGUMENT~;
            }
            if (part.material.generation) {
                if (!store.materials.is_live(part.material)) return c3d::INVALID_ARGUMENT~;
                Material* material = &store.material(part.material).data;
                if (material.kind == MaterialKind.CUSTOM) {
                    if (!store.shaders.is_live(material.custom.shader)) return c3d::INVALID_ARGUMENT~;
                    if (store.shader(material.custom.shader).desc.vertex.shaded.len && !group.desc.has_bounds_override) {
                        return c3d::INVALID_ARGUMENT~;
                    }
                }
            } else if (!document || !part.material.index || part.material.index > document.materials.len) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
    }
    return;
}

fn String[] document_keys(ModelDocument* document) @private {
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

fn void remap_template(ModelTemplate* template, PublishedIds* ids) @private {
    foreach (&group : template.lod_groups) {
        foreach (&part : group.desc.parts) {
            part.geometry = @remapped(part.geometry, ids.geometries);
            part.material = @remapped(part.material, ids.materials);
        }
    }
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

macro @remapped(id, ids) @private {
    if (id.generation || !id.index) return id;
    return ids[document_index(id)];
}

macro @document_reference($IdType, usz index) @private => ($IdType){ .index = (uint)index + 1 };

<*
 @require reference.generation == 0 && reference.index > 0
*>
macro usz document_index(reference) @private => (usz)reference.index - 1;
