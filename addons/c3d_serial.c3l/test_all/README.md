# Combined serialization acceptance

`serial_all_test` selects all serialization adapters and character navigation. It creates no GPU device and adds no test-only component types.

The explicit inventory checks all 50 policies: 37 described authoring adapters and 13 transient components. It uses already assigned slots and checks the exact registered-type count, distinct slots, exclusive policies, complete registered scene-store coverage, and repeated registration. The separate core and package inventories also remain enabled.

One scene contains every authored type together: core values and batches, an animated skinned ragdoll, an animated crowd, IK constraints, ordinary physics and cloth, fracture pieces, navigation with a driven character, terrain and foliage, water, and particles. The source prepares all owners and synchronizes physics/navigation so all 13 transient types are actually present before export.

Both binary and JSONC runs check authored values and references for every type, pending/reset runtime state on read, exact canonical re-export, and independent snapshot restoration after changing values across core and add-ons. Each restored scene then prepares its owners and runs ordinary physics/navigation synchronization; all transient types reappear and canonical authoring remains unchanged. Cloth and NavSource share one Mesh in the scene, exercising their projection ordering together with every other adapter.

`scripts/build.py --test` includes this device-free target. Run it directly from the repository root:

```text
c3c test serial_all_test --path addons/c3d_serial.c3l
```
