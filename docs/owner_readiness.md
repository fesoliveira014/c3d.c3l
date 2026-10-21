# Owner readiness

Authoring attachment copies an owner's configuration without creating its runtime. Preparation completes the selected
owner. Eager constructors such as `add_crowd` attach and prepare in one call, and remove their attachment if preparation
fails. A restored subtree ([Serialization](serialization.md)) attaches owners in the pending state, so the application
finishes them before use.

## Quick start

Finish every pending owner of a loaded subtree. Prepare crowds and terrain before the owners that depend on them.

```c3
model::prepare_crowd_subtree(&assets, &scene)!;
particle::prepare_subtree(&scene)!;
terrain::prepare_subtree(&scene, &assets)!;
foliage::prepare_subtree(&scene, &assets)!;
water::prepare_subtree(&scene, &assets)!;
physics.prepare_breakable_subtree()!;
cloth::prepare_subtree(&scene, &assets, null, &physics)!;
```

## Concepts

- **Pending.** An owner with authoring but no runtime. It holds copied configuration and validated descriptors, draws
  per the table below and is skipped by system updates.
- **Prepared.** The complete runtime is installed. `is_prepared` reports it for every owner.
- **Idempotent.** Preparing an already-prepared owner succeeds without changing it. A terrain tile is the exception: it
  re-validates and relinks, and faults leaving the tile unlinked when the set checks fail.
- **Atomic.** A failed preparation keeps the pending authoring and releases everything that attempt acquired, so the
  application can fix the cause and retry.

## Owners

| Owner | State after attachment | Drawing while pending | Completion call | Required order |
| --- | --- | --- | --- | --- |
| Animated crowd | Pending; copied placements, seed poses, colors and optional actions and spaces | No generated part batches | `model::prepare_crowd(assets, scene, node)` or `model::prepare_crowd_subtree(assets, scene, root)` | Source model, skeleton, clips, geometry and materials must be live; a dead source returns `INVALID_ID` and leaves the crowd pending |
| Particle system | Pending; validated descriptor and application emission control | No generated draw child | `particle::prepare(scene, node)` or `particle::prepare_subtree(scene, root)` | Register particles before attachment; restore authored `emitting` after attachment |
| Cloth | Pending; source geometry, original vertex-motion flag, copied pins and collider identities | The authored source `Mesh` stays visible | `cloth::prepare(scene, assets, node, world = null)` or `cloth::prepare_subtree(scene, assets, root, world)` | Publish node world matrices; synchronize listed physics bodies first or receive `physics::NO_BODY`. No contact bodies means no physics-world dependency. Pass the `PhysicsWorld` for a skinned source |
| Crowd cloth | Pending; attached part recipes on an `AnimatedCrowd` owner | The crowd's instanced part batch stays visible | `cloth::prepare_crowd_cloth(world, assets, owner, part = all)`, or `cloth::prepare_subtree` with a world | Prepare the crowd first; an unprepared crowd returns `INVALID_ARGUMENT` |
| Terrain | Pending; validated height map and layer authoring | No generated chunk batch | `terrain::prepare(scene, assets, node)` or `terrain::prepare_subtree(scene, assets, root)` | Prepare before dependent foliage; a [tile](terrain.md#tile-sets) needs its parent's `TerrainSet`, and preparing a prepared tile re-validates its links |
| Foliage | Pending; validated descriptor and owned optional LOD copy | No generated cells | `foliage::prepare(scene, assets, node)` or `foliage::prepare_subtree(scene, assets, root)` | Prepare terrain and publish world matrices first; pending terrain returns `terrain::NOT_PREPARED` and can be retried. The node's world transform must be a translation plus a rotation about Y |
| Water | Pending; validated descriptor | No generated surface or mirror camera | `water::prepare(scene, assets, node)` or `water::prepare_subtree(scene, assets, root)` | Publish node world matrices before preparation. A spectral wave model faults `UNSUPPORTED` when `C3D_LANDSCAPE_GPU` is off |
| Breakable | Pending; copied pieces, hulls and rest frames; explicit recipes also keep edges, strengths and anchors | The authored `Mesh` nodes stay visible | `PhysicsWorld.prepare_breakable(node)` or `prepare_breakable_subtree(root)` | Publish world matrices, provide live hull sources and synchronize required `STATIC` anchor targets. Connected piece poses must match the captured recipe up to common rigid motion; a returned failure keeps pending authoring for retry |

The owner pages describe each runtime: [Animated crowds](crowds.md), [Particles](particles.md),
[Cloth](cloth.md), [Terrain](terrain.md), [Vegetation](vegetation.md) and [Water](water.md).

## Subtree preparation

Subtree preparation includes the selected root; null selects the scene root. It attempts every matching pending owner,
keeps successful preparations and returns the first fault in component iteration order after attempting the other owners.
System updates skip pending owners. Removing a pending owner releases its copied authoring. Per-owner runtime operations
require preparation first.

Crowd animation changes current pose clocks. Its retained seed times change only through authored placement updates such
as `model::set_crowd`.

## Limits

- Preparation is an application call; nothing prepares an owner implicitly on load or update.
- A pending owner draws nothing generated, except where the table says the authored mesh stays visible.
- Several owners depend on others being prepared first (foliage on terrain, crowd cloth on its crowd).

## See also

- [Serialization](serialization.md) for restoring subtrees with pending owners.
- [Asset store](assets.md) for the store that owners resolve their assets from.
- [Architecture](architecture.md) for the module layout.
