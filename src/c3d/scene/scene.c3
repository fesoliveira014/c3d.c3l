module c3d::scene;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::ecs;
import c3d::maths;
import std::math;

const uint DEFAULT_MAX_NODES @local = 16384; // 2.5 MiB of Node plus the entity pool; the only per-node fixed cost

<*
 Node capacity of a scene, excluding the root; fixed at creation.
*>
struct SceneDesc {
    uint max_nodes;
}

<*
 Owner of every node and of the world their components live in.
*>
struct Scene {
    Allocator  allocator;
    Allocator* hook_allocator;
    World      world;
    Node[]     nodes;
    Node*      root;
    Vec3       ambient_color;
    float      ambient_intensity;
    Node*[]    remove_queue;
    uint       remove_count;
}

<*
 Add an empty node under the parent.
 @param [in] parent : "Null means the root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn Node*? Scene.add_node(&self, Node* parent = null, String name = "") {
    if (!parent) parent = self.root;
    Entity entity = self.world.create_entity()!;
    Node* node = &self.nodes[entity.index];
    *node = {
        .id                = entity,
        .name              = name.copy(self.allocator),
        .local             = maths::TRANSFORM_IDENTITY,
        .world             = parent.world,
        .layers            = DEFAULT_LAYERS,
        .visible           = true,
        .visible_effective = parent.visible_effective,
    };
    link(node, parent);
    return node;
}

<*
 Add a node carrying a mesh that casts and receives shadows.
 @param [in] parent : "Null means the root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn Node*? Scene.add_mesh(&self, GeometryId geometry, MaterialId material, Node* parent = null, String name = "") {
    Node* node = self.add_node(parent, name)!;
    self.world.add(node.id, (Mesh){
        .geometry       = geometry,
        .material       = material,
        .cast_shadow    = true,
        .receive_shadow = true,
    });
    return node;
}

<*
 Add a node carrying a camera.
 @param [in] parent : "Null means the root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn Node*? Scene.add_camera(&self, Camera camera, Node* parent = null, String name = "") {
    Node* node = self.add_node(parent, name)!;
    self.world.add(node.id, camera);
    return node;
}

<*
 Add a node carrying a punctual light.
 @param [&inout] self : "Owns the new node and component."
 @param [in] parent : "Null means the root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn Node*? Scene.add_light(
    &self,
    Light light,
    Node* parent = null,
    String name = "",
) {
    Node* node = self.add_node(parent, name)!;
    self.world.add(node.id, light);
    return node;
}

<*
 Destroy the subtree's entities through their hooks, then release the nodes.
 Invalidates component pointers of every store the subtree used.
 @param [&inout] node : "Dead afterwards, with every descendant."
 @require node != self.root, self.world.is_alive(node.id)
*>
fn void Scene.remove(&self, Node* node) {
    while (node.first_child) self.remove(node.first_child);
    self.world.destroy_entity(node.id);
    alloc::free(self.allocator, node.name.ptr);
    unlink(node);
    *node = {};
}

<*
 Queue the subtree for the next flush; safe inside a component iteration.
 @param [&in] node : "Not already queued, and no ancestor of it queued."
 @require node != self.root, self.world.is_alive(node.id)
*>
fn void Scene.remove_later(&self, Node* node) {
    self.remove_queue[self.remove_count] = node;
    self.remove_count++;
}

<*
 Remove every queued subtree, in queue order.
 Invalidates component pointers of every store the subtrees used.
*>
fn void Scene.flush_removals(&self) {
    for (uint index = 0; index < self.remove_count; index++) {
        self.remove(self.remove_queue[index]);
    }
    self.remove_count = 0;
}

<*
 Move the node under another parent, keeping its local or its world transform.
 With keep_world, reads both world matrices as left by the last update.
 @param [in] parent : "Null means the root; never the node or a descendant."
 @require node != self.root, self.world.is_alive(node.id)
*>
fn void Scene.reparent(&self, Node* node, Node* parent, bool keep_world = false) {
    if (!parent) parent = self.root;
    if (keep_world) {
        Mat4 parent_inverse = maths::inverse_affine(parent.world);
        node.local = maths::transform_from_mat4(parent_inverse.mul(node.world));
    }
    unlink(node);
    link(node, parent);
}

<*
 Node of a live entity.
 @require self.world.is_alive(entity)
*>
fn Node* Scene.node(&self, Entity entity) {
    return &self.nodes[entity.index];
}

<*
 Recompute every world matrix and effective visibility from the root.
*>
fn void Scene.update_world(&self) {
    update_subtree(self.root, matrix::IDENTITY4, true);
}

<*
 First live node with the name, by linear scan.
 @return? NOT_FOUND
*>
fn Node*? Scene.find(&self, String name) {
    foreach (&node : self.nodes) {
        if (self.world.is_alive(node.id) && node.name == name) return node;
    }
    return NOT_FOUND~;
}

<*
 Give the type a process-wide slot and this scene's world a store for it.
 @return? c3d::CAPACITY_EXCEEDED
*>
macro void? Scene.register(&self, $Type) => self.world.register($Type);

<*
 Attach a component to the node and return its short-lived address.
 @require self.world.is_registered($Typeof(value)), !self.has(node, $Typeof(value))
*>
macro Scene.add(&self, Node* node, value) => self.world.add(node.id, value);

<*
 Short-lived address of the node's component, null when absent.
*>
macro Scene.get(&self, Node* node, $Type) => self.world.get(node.id, $Type);

<*
 Whether the node carries the type.
*>
macro bool Scene.has(&self, Node* node, $Type) => self.world.has(node.id, $Type);

<*
 Detach the node's component through its hook.
 Invalidates component pointers of the same store.
 @require self.has(node, $Type)
*>
macro void Scene.remove_component(&self, Node* node, $Type) => self.world.remove(node.id, $Type);

<*
 Install the hook every later removal of the type runs.
 @param [in] user : "Passed to the hook unchanged."
 @require self.world.is_registered($Type)
*>
macro void Scene.set_remove_hook(&self, $Type, RemoveFn on_remove, void* user) => self.world.set_remove_hook($Type, on_remove, user);

<*
 Components of the type in this scene.
*>
macro uint Scene.count(&self, $Type) => self.world.count($Type);

<*
 Visit every component of the type once, in dense order.
 The body must not add or remove components of the same type.
*>
macro Scene.@each(&self, $Type; @body(entity, component)) {
    self.world.@each($Type; entity, component) {
        @body(entity, component);
    };
}

<*
 Visit every entity carrying both types once.
 The body must not add or remove components of either type.
*>
macro Scene.@each2(&self, $TypeA, $TypeB; @body(entity, a, b)) {
    self.world.@each2($TypeA, $TypeB; entity, a, b) {
        @body(entity, a, b);
    };
}

<*
 Capacity for a scene of ordinary size.
*>
fn SceneDesc default_scene_desc() {
    return { .max_nodes = DEFAULT_MAX_NODES };
}

<*
 Create a scene with mesh, camera and light components registered.
 @require desc.max_nodes > 0
*>
fn Scene create_scene(Allocator allocator, SceneDesc desc) {
    uint capacity = desc.max_nodes + 1;
    Scene scene = {
        .allocator      = allocator,
        .hook_allocator = alloc::new(allocator, Allocator),
        .world          = ecs::create_world(allocator, capacity),
        .nodes          = alloc::new_array(allocator, Node, capacity),
        .remove_queue   = alloc::new_array(allocator, Node*, desc.max_nodes),
    };
    *scene.hook_allocator = allocator;
    Entity root_entity = scene.world.create_entity()!!;
    scene.root = &scene.nodes[root_entity.index];
    *scene.root = {
        .id                = root_entity,
        .local             = maths::TRANSFORM_IDENTITY,
        .world             = matrix::IDENTITY4,
        .layers            = DEFAULT_LAYERS,
        .visible           = true,
        .visible_effective = true,
    };
    scene.world.register(Mesh)!!;
    scene.world.register(Camera)!!;
    scene.world.register(Light)!!;
    scene.ambient_color = { 1, 1, 1 };
    scene.world.set_remove_hook(Mesh, &free_morph_weights, scene.hook_allocator);
    return scene;
}

<*
 Remove every node through its hooks, then free the world and the arrays.
 @param [&inout] scene : "Left zeroed; every node and entity of it is dead."
*>
fn void destroy_scene(Scene* scene) {
    while (scene.root.first_child) scene.remove(scene.root.first_child);
    ecs::destroy_world(&scene.world);
    alloc::free(scene.allocator, scene.hook_allocator);
    alloc::free(scene.allocator, scene.remove_queue.ptr);
    alloc::free(scene.allocator, scene.nodes.ptr);
    *scene = {};
}

fn void link(Node* node, Node* parent) @local {
    node.parent = parent;
    node.next_sibling = parent.first_child;
    parent.first_child = node;
}

fn void unlink(Node* node) @local {
    Node* parent = node.parent;
    if (parent.first_child == node) {
        parent.first_child = node.next_sibling;
    } else {
        Node* previous = parent.first_child;
        while (previous.next_sibling != node) previous = previous.next_sibling;
        previous.next_sibling = node.next_sibling;
    }
    node.parent = null;
    node.next_sibling = null;
}

fn void update_subtree(Node* node, Mat4 parent_world, bool parent_visible) @local {
    node.world = parent_world.mul(node.local.to_mat4());
    node.visible_effective = parent_visible && node.visible;
    for (Node* child = node.first_child; child; child = child.next_sibling) {
        update_subtree(child, node.world, node.visible_effective);
    }
}

fn void free_morph_weights(Entity entity, void* component, void* user) @local {
    Mesh* mesh = (Mesh*)component;
    alloc::free(*(Allocator*)user, mesh.morph_weights.ptr);
}
