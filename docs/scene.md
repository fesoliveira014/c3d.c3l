# Scene nodes

`c3d::scene` owns a fixed-capacity hierarchy of nodes with stable addresses. Each node is an ECS entity. Components supply
meshes, cameras, lights and application data. The asset store owns the shared assets those components reference. The
renderer reads the scene; the scene never calls the renderer.

## Quick start

```c3
import c3d;
import c3d::scene;

Scene scene = scene::create_scene(mem, scene::default_scene_desc());
defer scene::destroy_scene(&scene);

Node* pivot = scene.add_node(name: "pivot")!;
pivot.local.position = { 0, 1, 0 };
Node* child = scene.add_mesh(
    geometry: geometry,
    material: material,
    parent:   pivot,
    name:     "child",
)!;
child.local.position = { 2, 0, 0 };

scene.update_world();
// child.world_position() is (2, 1, 0)
```

`geometry` and `material` are ids from the asset store. `add_camera` and `add_light` create nodes the same way.

## Concepts

- A `Node` holds its `id`, `name`, authored `local` transform (`position`, `rotation`, `scale`), published `world`
  matrix, `layers` mask, `visible` flag and the links to its parent and children.
- `SceneDesc.max_nodes` fixes the node count at creation, excluding the root; `default_scene_desc()` sets 16,384, about
  2.6 MiB. `add_node` and the helpers built on it fault `CAPACITY_EXCEEDED` when the scene is full.
- The synthetic root has an identity transform; a node added without a parent hangs from it.
- A node pointer stays valid until the node is removed. The entity `id` stays valid across structural changes; check it with
  `scene.world.is_alive(id)`, then resolve it with `Scene.node(entity)`, which requires a live entity.
- The application calls `update_world` itself. No scheduler runs it.

## Authored and published transforms

`Node.local` is an authored translation, rotation and scale. `transform_space` selects its reference frame:

| Space | Published `Node.world` |
| --- | --- |
| `TransformSpace.PARENT` (default) | Parent world matrix multiplied by the authored transform. |
| `TransformSpace.WORLD` | Authored transform, independent of ancestor transforms. |

`Scene.update_world()` publishes world matrices and effective visibility for the whole tree. Call it after edits and before
anything reads `world` or `visible_effective`. Changing `transform_space` keeps the authored value and reinterprets it at
the next update; it does not convert the old world placement. A `PARENT` child of a `WORLD` node inherits that node's world
matrix normally.

```c3
Node* emitter = scene.add_node()!;
emitter.local.position = { 10, 0, 0 };
Node* particles = scene.add_node(emitter)!;
particles.transform_space = TransformSpace.WORLD;
particles.local.position = { 1, 2, 3 };
scene.update_world();
```

The child's world position is `(1, 2, 3)`. Moving the emitter leaves it there. An instanced mesh with this space and an
identity authored transform can hold world-space instance transforms in its ordinary batch arrays. Instance bounds, picking
and rendering consume the published node matrix through their usual paths.

## World-space operations

`Node.transform_basis()` yields identity for a `WORLD` node or the root, and the parent's last published world matrix for a
`PARENT` node. It does not update the scene.

`set_world_position`, `set_world_pose` and `look_at` write the authored transform using this basis.

| Call | Writes | Keeps |
| --- | --- | --- |
| `set_world_position(position)` | Authored position | Rotation and scale |
| `set_world_pose(position, rotation)` | Authored position and rotation | Scale |
| `look_at(target, up)` | Authored rotation, local negative Z toward the world point | Position and scale |

Call them on live non-root nodes whose parents' world matrices are current (`look_at` also reads the node's own matrix), then
call `update_world`. `WORLD` operations do
not inspect ancestor scale or shear.

## Reparent a node

`Scene.reparent(node, parent, keep_world)` keeps the node's transform space. The new parent must not be the node or one of its
descendants; a null parent selects the root. Reparenting publishes nothing until `update_world`.

| Space | `keep_world = false` | `keep_world = true` |
| --- | --- | --- |
| `PARENT` | Keeps the authored transform. | Derives a new authored transform from the published world matrix and the new parent's inverse. |
| `WORLD` | Keeps the authored transform. | Keeps the authored transform. |

`keep_world = true` needs current matrices on both nodes and a result that fits translation, rotation and scale; arbitrary
shear is not preserved.

## Hierarchy and lifetime

Transform space changes only transform inheritance. Effective visibility is the node's `visible` flag combined with every
ancestor's. Layer masks stay independent: a child does not inherit its parent's layers.

| Call | Effect |
| --- | --- |
| `Scene.remove(node)` | Removes the node and every descendant, in either space, through the component removal hooks. |
| `Scene.remove_later(node)` | Queues the subtree; safe inside a component iteration. The node and its ancestors must not be queued already. |
| `Scene.flush_removals()` | Removes the queued subtrees in queue order. |
| `Scene.find(name)` | First live node with the name by linear scan; faults `NOT_FOUND`. |

Removal frees scene-owned batch arrays and other component payloads. Shared assets stay in the asset store. Removal
invalidates the component pointers of every store the subtree used.

IK chains support a `WORLD` first joint and world-space target and pole markers. Every later articulated joint must use
`PARENT`; see [inverse kinematics](animation.md#inverse-kinematics).

[Billboard batches](billboards.md) and [ribbon batches](ribbons.md) are scene-owned components with the same transform-space,
visibility and subtree-lifetime rules as other draw components.

## Components

A component is any C3 struct registered with the scene. `create_scene` registers the built-in types; `Scene.register(Type)`
registers another. `Scene.add(node, value)` attaches a component and returns its short-lived address, `get` returns it or null,
`has` tests for it, `remove_component` detaches it through its hook, and `set_remove_hook` installs the hook every later removal
of the type runs. `Scene.@each(Type; entity, component)` visits every component of a type in dense order, and
`Scene.@each2` every node carrying two types. One process registers at most 128 component types, built-in and add-on types
included (`ecs::MAX_COMPONENT_TYPES`); one more returns `CAPACITY_EXCEEDED`. A type takes a process-wide slot on first
registration, and each world allocates a store for the types it registers. Every entity of a world's capacity carries a
16-byte mask, one bit per slot.

Presence comes from each type's store: `has`, `get` and `@each2` read its sparse array, never the mask. A component is absent
from the moment its store removes it, so `has` and `get` agree at every point of a removal, removal hooks included.
Removing an entity removes its components in ascending slot order and clears each type's mask bit after its hook: a hook sees
lower slots already gone and its own and higher slots still present.

`World.mask` and `World.@each_slot(entity; slot)` enumerate an entity's types for inspection and serialization.
`@each_slot` visits set slots in ascending order over a copy of the mask taken at entry; its body may remove only the visited
component. `Scene.world` exposes the `World`.

## Limits

- At most 128 component types per process (`ecs::MAX_COMPONENT_TYPES`), and `SceneDesc.max_nodes` nodes per scene.
- `WORLD`-space operations ignore ancestor scale and shear, and `reparent` with `keep_world` does not preserve shear.
- The scene holds no renderer state. GPU mirrors live in the renderer and follow the scene when it renders.

## See also

- [Architecture](architecture.md) for the layers and modules.
- [Animation](animation.md) for skeletons, animators and IK.
- [Picking](picking.md) for rays against the scene.
- [Type descriptions](type_descriptions.md) and [serialization](serialization.md) for describing and storing components.
