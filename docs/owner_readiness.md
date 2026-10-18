# Owner readiness

Authoring attachment copies an owner's configuration without creating its runtime.
Preparation completes the selected owner. Existing eager constructors perform both
steps and remove their attempted attachment if preparation fails.

| Owner | State after attachment | Drawing while pending | Completion call | Required order |
| --- | --- | --- | --- | --- |
| Animated crowd | Pending; copied placements, seed poses, colors and optional actions/spaces | No generated part batches | `model::prepare_crowd(assets, scene, node)` or `model::prepare_crowd_subtree(assets, scene, root)` | Source model, skeleton, clips, geometry and materials must be live; a dead source returns `INVALID_ID` and leaves the crowd pending |
| Particle system | Pending; validated descriptor and application emission control | No generated draw child | `particle::prepare(scene, node)` or `particle::prepare_subtree(scene, root)` | Register particles before attachment; restore authored `emitting` after attachment |
| Cloth | Pending; source geometry, original vertex-motion flag, copied pins and collider identities | Existing authored source Mesh remains visible | `cloth::prepare(scene, assets, node)` or `cloth::prepare_subtree(scene, assets, root)` | Publish node world matrices; synchronize listed physics bodies first or receive `physics::NO_BODY`. No contact bodies means no physics-world dependency |
| Terrain | Pending; validated height map and layer authoring | No generated chunk batch | `terrain::prepare(scene, assets, node)` or `terrain::prepare_subtree(scene, assets, root)` | Prepare before dependent foliage; a [tile](terrain.md#tile-sets) needs its parent's `TerrainSet`, and preparing a prepared tile re-validates its links |
| Foliage | Pending; validated descriptor and owned optional LOD copy | No generated cells | `foliage::prepare(scene, assets, node)` or `foliage::prepare_subtree(scene, assets, root)` | Prepare terrain and publish world matrices first; pending terrain returns `terrain::NOT_PREPARED` and can be retried |
| Water | Pending; validated descriptor | No generated surface or mirror camera | `water::prepare(scene, assets, node)` or `water::prepare_subtree(scene, assets, root)` | Publish node world matrices before preparation |
| Breakable | Pending; copied pieces, hulls and rest frames; explicit recipes also retain edges, strengths and anchors | Existing authored Mesh nodes remain visible | `PhysicsWorld.prepare_breakable(node)` or `prepare_breakable_subtree(root)` | Publish world matrices, provide live hull sources and synchronize required STATIC anchor targets. Connected piece poses must match the captured recipe up to common rigid motion; a returned failure retains pending authoring for retry |

`is_prepared` reports whether the owner's complete runtime is installed. Preparing
an already-prepared owner succeeds without changing it. A failed preparation
retains pending authoring and releases everything acquired by that attempt.

Subtree preparation includes the selected root; null selects the scene root. It
attempts every matching pending owner, retains successful preparations, and returns
the first fault in component iteration order after attempting the other owners.
System updates skip pending owners. Removing a pending owner releases its copied
authoring. Per-owner runtime operations require preparation first.

Crowd animation changes current pose clocks. Its retained seed times change only
through authored placement updates such as `model::set_crowd`.
