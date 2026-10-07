# Landscape serialization

Select `c3d_landscape` and `c3d_serial`, enable `C3D_LANDSCAPE_SERIAL`, register the normal landscape stores/hooks, then call `landscape::register_serial_codecs()`. The plain landscape manifest has no serialization dependency. Registration creates no scene or asset state.

The portable component names are `terrain`, `foliage` and `water`, all version 1. Their generated binary, JSONC and schema forms share the registered authoring descriptions and committed layout fingerprints. `TerrainDesc` and `WaterDesc` are used directly. Foliage's authoring value contains every `FoliageDesc` field, with `lod` represented as a zero-or-one-element `LodDesc` array. The descriptor, levels and parts are copied by attachment.

Defaults come from the existing terrain, foliage and water descriptor constructors. Nested scatter and sway defaults come from the foliage constructor. A standalone `Wave` declares zero defaults; the water constructor still supplies its two calm waves. Shared LOD, transform and effect values use `serial::register_core_value_types()`.

Read restores pending authoring. Terrain attaches in VALUE phase and foliage in OWNER phase so its ground already carries Terrain. No generated geometry, material, batch, cell or mirror is created during read. Prepare terrain before foliage through the existing explicit preparation APIs; water prepares independently. Existing owner validation faults propagate unchanged.

Export borrows authoring without changing it. Terrain and water generated same-node draw components are omitted. Foliage cell nodes and water mirror nodes are omitted only after their runtime ownership is verified. An external mirror is omitted when it belongs to the selected subtree; exporting only a mirror or foliage cell fails `INVALID_ARGUMENT`. Application-authored children or components on omitted generated nodes also fail instead of disappearing. Ordinary authored children on owner nodes remain in the graph.

`TerrainRuntime`, `FoliageRuntime`, `FoliageCellOwner`, `WaterRuntime` and `WaterMirror` are transient. The cell marker identifies its owner and table index; the runtime table remains authoritative. Both pending and prepared owners export the same authoring.

Run `c3c test landscape_serial_test --path addons/c3d_landscape.c3l`. The focused target checks both encodings, schema/layout pins, pending reads, deterministic export before and after preparation, copied LOD matrices, both foliage modes, keyed water geometry, external mirrors, generated-node rejection, capacity errors and rollback after a later authoring-copy failure.

`landscape_serial_policy_test` discovers all landscape component slots through normal registration and checks the three authoring and five transient policies. Registration is idempotent. The normal `landscape_test` target remains the feature-off check; `scripts/build.py --test` runs all three.
