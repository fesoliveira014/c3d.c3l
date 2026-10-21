# Particle serialization

Saves particle systems as portable authoring under `C3D_PARTICLE_SERIAL`. The serialization model is in [Serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md). The component's version, restore phase and what older payloads read as are in the [versions table](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization_reference.md#versions-and-older-payloads).

## Enable and register

Select `c3d_particle` and `c3d_serial`, enable `C3D_PARTICLE_SERIAL`, register particles normally, then call `particle::register_serial_codecs()`. The plain particle package has no serialization dependency. Registration creates no scene or asset state, and installs the value descriptions it needs idempotently. Shared values come from `serial::register_core_value_types()`.

The portable component is `particle_system`.

## What is saved

One description holds the complete `ParticleSystemDesc` and the `emitting` flag. Binary, JSONC and the schema use it. Defaults come from `default_particle_system_desc()`; `emitting` defaults to true, lifetime tables default to unit multipliers and `ParticleRange` defaults to zeros.

Capacity, seed, references, shape, numeric ranges and every lifetime-table entry are preserved. A sub-emitter `target` is an entity reference, encoded as a record index like the ground reference of foliage. A target outside the exported subtree faults `INVALID_ARGUMENT` on export. Entries past `sub_emitter_count` are written empty, so a stale entity in an unused entry does not block export.

## What restarts

Live particles, trail points, queued bursts and events, the drop, eviction, event-drop, event-skip and collision-skip counters, spawn indices, fractional emission, turbulence time and the random state restart. The collision cast and its context are runtime state; a loaded system needs `ParticleSystem.set_collision` again. No draw child, simulation pool or asset is created during a read.

## Preparation after a read

A read copies the descriptor into a pending system through `Scene.attach_particle_system`, then restores the emitting flag. Call `particle::prepare` or `prepare_subtree` before ordinary updates; updates skip pending systems. See [owner readiness](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/owner_readiness.md).

## Export

Export borrows authoring and changes nothing. It verifies the owned draw child, and the trail child when trails are on, and omits only their billboard, mesh or ribbon batch and runtime marker. `ParticleDrawOwner` is transient. Exporting a draw or trail child on its own faults `INVALID_ARGUMENT`, as does an application-authored child or component on a generated node. Ordinary authored children under the emitter stay in the document.

## Targets

```bash
c3c test particle_serial_test --path addons/c3d_particle.c3l
c3c test particle_serial_policy_test --path addons/c3d_particle.c3l
```

`particle_serial_test` covers both encodings, schema pins, older payloads, the sub-emitter target, pending and prepared export, generated-node rejection, allocation faults and preparation retry. `particle_serial_policy_test` checks that every particle component slot has its expected authored or transient policy. `particle_test` stays the feature-off check. `scripts/build.py --test` runs all three.
