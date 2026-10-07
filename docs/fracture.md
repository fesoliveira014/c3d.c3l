# Fracture generation

Fracture generation, its numerical kernel, surface construction and generator
tests are maintained in the standalone
[c3d_fracture.c3l](https://github.com/fesoliveira014/c3d_fracture.c3l) project under
the `fracture` namespace. That project depends on c3d.

c3d retains the generic interfaces used by fracture tooling:

- The [physics add-on](../addons/c3d_physics.c3l/README.md#breakables) accepts
  authored physical pieces with multiple hulls and provides preparation,
  read-only authoring views, welds and break events.
- [glTF source inspection](gltf_source.md) provides independent encoded images,
  source indices, sampler values and extension names alongside store-free
  document inspection.
