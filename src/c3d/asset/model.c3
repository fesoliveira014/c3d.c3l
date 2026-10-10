module c3d::asset;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::pool;
import c3d::scene;

<*
 Import animations, lights, cameras and missing tangents by default.
*>
const LoadOptions LOAD_OPTIONS_DEFAULT = {
    .animations = true, .lights = true, .cameras = true, .generate_tangents = true,
};

<* Logical encoding of imported normal-map texels. *>
enum NormalEncoding {
    RGB,
    RG,
}

<*
 Node of a reusable model, addressed by model-local index.
*>
struct NodeTemplate {
    int       parent;
    String    name;
    Transform local;
    uint      layers;
    bool      visible;
}

<*
 Mesh attached to a template node.
*>
struct ModelMesh {
    uint       node;
    GeometryId geometry;
    MaterialId material;
    float[]    default_morph_weights;
}

<* Whole-object alternatives attached to a template node. *>
struct ModelLodGroup {
    uint node;
    LodDesc desc;
}

<*
 Skin attached to a template mesh node; joints are template indices in skeleton order.
*>
struct ModelSkin {
    uint       mesh_node;
    SkeletonId skeleton;
    uint[]     joint_nodes;
}

<*
 Light attached to a template node.
*>
struct ModelLight {
    uint  node;
    Light value;
}

<*
 Camera attached to a template node.
*>
struct ModelCamera {
    uint   node;
    Camera value;
}

<*
 Reusable model: parent-before-child nodes, components and shared asset ids.
*>
struct ModelTemplate {
    NodeTemplate[] nodes;
    ModelMesh[]    meshes;
    ModelLodGroup[] lod_groups;
    ModelSkin[]    skins;
    ModelLight[]   lights;
    ModelCamera[]  cameras;
    ClipId[]       clips;
}

<*
 Model record.
*>
struct ModelAsset {
    AssetHeader   header;
    ModelTemplate data;
}

<*
 Importer switches shared by every model loader.
*>
struct LoadOptions {
    bool animations;
    bool lights;
    bool cameras;
    bool generate_tangents;
    bool regenerate_tangents;
    NormalEncoding normal_encoding;
}

<*
 Pool of model records addressed by ModelId.
*>
alias ModelPool = Pool{ModelAsset, ModelId};

<*
 Add a model whose arrays the store takes over on success.
 @param [&in] template : "Arrays and names were allocated with the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn ModelId? AssetStore.add_model_owned(&self, ModelTemplate* template, String key = "") {
    check_key(self, key)!;
    ModelId id = self.models.add({})!;
    *self.models.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data   = *template,
    };
    register_key(self, key, typed_ref(AssetKind.MODEL, id));
    return id;
}

<*
 Replace the template, taking its arrays on success; existing instances keep theirs.
 @param [&in] template : "Arrays and names were allocated with the store allocator."
 @return? c3d::INVALID_ARGUMENT, c3d::INCOMPATIBLE_STRUCTURE
 @require self.models.is_live(model)
*>
fn void? AssetStore.replace_model_owned(&self, ModelId model, ModelTemplate* template) {
    ModelAsset* record = self.models.get(model);
    if (!same_model_structure(&record.data, template)) return c3d::INCOMPATIBLE_STRUCTURE~;
    check_lod_groups(self, template, null)!;
    free_model_template(self.allocator, &record.data);
    record.data = *template;
    mark_replaced(&record.header);
    return;
}

<*
 Record of the model; a borrow into the pool.
 @require self.models.is_live(model)
*>
fn ModelAsset* AssetStore.model(&self, ModelId model) {
    return self.models.get(model);
}

<*
 Free the template and retire the id; referenced assets stay.
 @require self.models.is_live(model)
*>
fn void AssetStore.remove_model(&self, ModelId model) {
    ModelAsset* record = self.models.get(model);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_model_template(self.allocator, &record.data);
    *record = {};
    self.models.remove(model);
}

<*
 Model id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn ModelId? AssetStore.find_model(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.MODEL) return c3d::INVALID_ARGUMENT~;
    return (ModelId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Free every array and name of a template allocated with the allocator.
 @param [&inout] template : "Left zeroed."
*>
fn void free_model_template(Allocator allocator, ModelTemplate* template) {
    foreach (&node : template.nodes) alloc::free(allocator, node.name.ptr);
    foreach (&mesh : template.meshes) alloc::free(allocator, mesh.default_morph_weights.ptr);
    foreach (&skin : template.skins) alloc::free(allocator, skin.joint_nodes.ptr);
    foreach (&group : template.lod_groups) {
        alloc::free(allocator, group.desc.levels.ptr);
        alloc::free(allocator, group.desc.parts.ptr);
    }
    alloc::free(allocator, template.lod_groups.ptr);
    alloc::free(allocator, template.nodes.ptr);
    alloc::free(allocator, template.meshes.ptr);
    alloc::free(allocator, template.skins.ptr);
    alloc::free(allocator, template.lights.ptr);
    alloc::free(allocator, template.cameras.ptr);
    alloc::free(allocator, template.clips.ptr);
    *template = {};
}
