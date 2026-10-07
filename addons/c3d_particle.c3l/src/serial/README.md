# Particle serialization

Select `c3d_particle` and `c3d_serial`, enable `C3D_PARTICLE_SERIAL`, register particles normally, then call `particle::register_serial_codecs()`. The plain particle manifest retains no serialization dependency. Registration creates no scene or asset state.

The version-1 portable component name is `particle_system`. One authoring description contains the complete `ParticleSystemDesc` and `emitting` flag. Binary, JSONC and schema use that description and committed layout fingerprints. Descriptor defaults come from `default_particle_system_desc()`, emitting defaults to true, lifetime tables default to unit multipliers, and the generic `ParticleRange` declares zero defaults. Shared values use `serial::register_core_value_types()`.

Read copies the descriptor into a pending system through `Scene.attach_particle_system`, then restores the emitting flag. Capacity, seed, references, shape, numeric ranges and every lifetime-table entry are preserved. Live particles, queued bursts, dropped counts, fractional emission and PRNG progress restart. No draw child, simulation pool or asset is created during read. Use `particle::prepare` or `prepare_subtree` before ordinary updates; updates skip pending systems.

Export borrows authoring without changing it. It verifies the owned draw child and excludes only its billboard/mesh batch and runtime marker. Exporting the draw child by itself fails `INVALID_ARGUMENT`. Application-authored children or components on that generated node also fail rather than being omitted. Ordinary authored children under the emitter remain portable. `ParticleDrawOwner` is transient.

Run `c3c test particle_serial_test --path addons/c3d_particle.c3l`. The focused target checks both encodings, schema/layout pins, pending and prepared deterministic export, mesh and stretched-billboard modes, emitting=false, update after preparation, generated-node rejection, reader allocation/capacity faults and preparation retry.

`particle_serial_policy_test` discovers all registered particle component slots and checks their explicit authored or transient policies. Registration installs prerequisite value descriptions idempotently. The normal `particle_test` target remains the feature-off check; `scripts/build.py --test` runs all three.
