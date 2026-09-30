# Scene nodes

`c3d::scene` owns a fixed-capacity hierarchy of stable node addresses. Each node
is an ECS entity; components supply meshes, cameras, lights and application data.
The asset store owns the shared assets those components reference.

## Authored and published transforms

`Node.local` is an authored translation, rotation and scale. `transform_space`
selects its reference frame:

| Space | Published `Node.world` |
| --- | --- |
| `TransformSpace.PARENT` (default) | Parent world matrix multiplied by the authored transform. |
| `TransformSpace.WORLD` | Authored transform, independent of ancestor transforms. |

Call `Scene.update_world()` after edits to publish world matrices and effective
visibility. Changing `transform_space` retains the authored value and
reinterprets it at the next update; it does not convert or preserve the old
world placement automatically. The synthetic root has an identity transform
basis. A `PARENT` child of a `WORLD` node inherits that node's world matrix normally.

Given a live scene and the scene module imported:

```c3
Node* emitter = scene.add_node()!;
emitter.local.position = { 10, 0, 0 };
Node* particles = scene.add_node(emitter)!;
particles.transform_space = TransformSpace.WORLD;
particles.local.position = { 1, 2, 3 };
scene.update_world();
```

The child's world position is `(1, 2, 3)`. Moving the emitter leaves it there.
An instanced mesh with this space and an identity authored transform can hold
world-space instance transforms in its ordinary batch arrays. Instance bounds,
picking and rendering consume the published node matrix through their usual paths.

## World-space operations

`Node.transform_basis()` yields identity for a `WORLD` node or the root, and
the parent's last published world matrix for a `PARENT` node. It does not update
the scene.

`set_world_position`, `set_world_pose` and `look_at` write the authored transform
using this basis. Call them on live non-root nodes, with the world matrices they
read already current, and call `update_world` afterward. Position changes retain
authored rotation and scale; pose changes retain authored scale. `look_at` aims
the local negative Z axis at a world point and changes only authored rotation.
`WORLD` operations do not inspect ancestor scale or shear.

`Scene.reparent(node, parent, keep_world)` retains the node's transform space.
The new parent must not be the node or one of its descendants.
For `PARENT`, `keep_world = false` retains the authored transform; `true` derives
a new authored transform from the published world matrix and the new parent's
inverse. Both matrices must be current, and the result must fit TRS: arbitrary
shear preservation is unsupported. For `WORLD`, either setting retains the
authored transform. Reparenting publishes nothing until `update_world`.

## Hierarchy and lifetime

Transform space changes only transform inheritance. Effective visibility is
still the node's visibility combined with every ancestor's visibility. Layer
masks remain independent; a child does not inherit its parent's layers.

Removing a parent removes every descendant in either space and invokes the
normal component removal hooks. This frees scene-owned batch arrays and other
component payloads; shared assets stay in the asset store. Borrowed node pointers
expire when their nodes are removed.

IK chains support a `WORLD` first joint and world-space target/pole markers.
Every later articulated joint must use `PARENT`; see
[inverse kinematics](animation.md#inverse-kinematics).
