# Static impostors

An `Impostor` adds one terminal raster choice after the mesh levels of a [LOD group](lod.md). It is a baked atlas of the
subject seen from a grid of directions, drawn as two triangles per placement. The group borrows an ordinary texture
asset and stores the subject-local bounding sphere and the atlas dimensions. Core scene types do not depend on the
renderer: `Renderer.bake_impostor` makes the atlas and `Scene.set_lod_impostor` installs it.

An impostor cuts triangle work and can cost more GPU time than a very coarse mesh. Use it where the mesh is detailed.

## Quick start

```c3
scene.update_world();
Impostor baked = renderer.bake_impostor(&scene, prototype)!;
scene.set_lod_impostor(
    assets:          &assets,
    node:            forest,
    impostor:        baked,
    min_screen_size: 0.02f,
)!;
```

`prototype` is a node whose subtree is the subject. `forest` is a LOD group node. Below `min_screen_size` the group
draws the atlas; above it, the mesh levels.

## Concepts

- **Atlas.** A texture asset in the store that holds a grid of captured directions. The store owns it; the group borrows
  it.
- **Terminal choice.** The impostor follows the last mesh level. The last mesh threshold becomes `min_screen_size`, and
  the terminal threshold is zero. The mesh descriptors stay unchanged.
- **Bounds.** The subject-local sphere must enclose every authored level. It joins the group's common bounds, so a
  larger sphere can change the projected size and the sway and fade anchor.
- **Baking is authoring.** The bake is synchronous and unsuitable for the frame loop.

## Bake an impostor

Call `Renderer.bake_impostor(&scene, subject, desc = IMPOSTOR_DESC_DEFAULT, key = "")` outside a frame, with current
world transforms.

- **Captured parts.** The capture takes the visible subject subtree in subject-local coordinates. It uses the level-zero
  parts of LOD groups and the current placements of instanced meshes and groups. Bake a single prototype when the atlas
  represents each forest placement.
- **Isolated scene.** The capture freezes wind and fade at rest and renders an isolated scene with its own orthographic
  camera. It does not alter source components or public views. It uses its own capture reference, so a distant scene
  before the bake does not affect it.
- **Submission.** The bake submits and waits for each direction. Frame indices and renderer statistics advance.
- **Stale atlases.** Source asset edits do not update an existing atlas. Rebake after changing the captured geometry or
  material.
- **Multisampling.** An installed impostor draws at the view's [multisample count](views.md#multisample-anti-aliasing)
  in the multisample pass, but its alpha cut is evaluated once per pixel, so the cut edge is not antialiased. The bake
  renders through an internal single-sample view.

### Supported sources

| Requirement | Detail |
| --- | --- |
| Material | Rigid `Standard` meshes with opaque or masked coverage, zero metallic factor, no emissive contribution and no active occlusion map. |
| Textures | Base color, normal and metallic-roughness asset textures. |
| Geometry | CPU positions must stay available. |

| Fault | When |
| --- | --- |
| `UNSUPPORTED` | Blending, wireframe, disabled depth writes or tests, a `Basic`, `Physical` or custom material, a render-target texture reference, skinning or morph targets. |
| `ASSET_DATA_UNAVAILABLE` | The CPU positions were released. |
| `INVALID_ID` | A reference is dead. |
| `INVALID_ARGUMENT` | The dimensions are invalid, the subject is empty, or the asset `key` is a duplicate. |
| `CAPACITY_EXCEEDED` | The asset, view or target slots are exhausted. |
| `gpu::` faults | Device allocation, format and submission faults propagate. |

Validation precedes the capture, and the atlas enters the store only after every direction succeeds. A failure releases
the temporary ownership.

### Atlas cost

`ImpostorDesc` sets `frames_per_side` and `cell_size`. The default, `IMPOSTOR_DESC_DEFAULT`, is 8 sides of 128 texels.
The texture is `frames_per_side * cell_size` texels wide and twice as tall, RGBA8_UNORM, so the default takes 8 MiB.
`Renderer.last_impostor_bake` (`ImpostorBakeStats`) reports the explicit allocations of the last bake:

| Field | Meaning |
| --- | --- |
| `elapsed_ms` | Elapsed milliseconds. |
| `atlas_bytes` | Atlas texel bytes, transferred to the store on success. |
| `capture_texel_bytes` | Private capture attachment texels. |
| `readback_bytes` | Mapped readback. |
| `scene_host_peak` | Peak tracked host allocation of the capture scene. |

These are explicit allocations, not process or driver memory. GPU padding, driver caches, upload rings, retained
renderer mirrors and tracking metadata are excluded. Padding also uses one reusable
`2 * cell_size * cell_size * usz::size` scratch allocation for the bake, freed afterward and not included in the stats.

## Install an impostor

`Scene.set_lod_impostor(assets, node, impostor, min_screen_size)` validates a live atlas of the contract below, an
enclosing finite positive sphere, and a finite positive threshold below the preceding mesh threshold.

| Fault | When |
| --- | --- |
| `INVALID_ID` | The atlas is dead. |
| `INVALID_ARGUMENT` | The atlas shape, the sphere or the threshold is invalid, or the sphere does not enclose every authored level (including any bounds override). |
| `UNSUPPORTED` | The group is animated, or its sway uses `VERTEX_ALPHA` with a nonzero amplitude. |

While an atlas is installed, use `HEIGHT` sway or a zero amplitude. Later `set_lod_effects` edits keep that programming
contract.

`clear_lod_impostor` removes the metadata and restores the final mesh threshold to zero. Clearing or removing the group
never deletes the texture. `prepare_scene` prepares installed live atlases; model preparation has no scene-installed
terminal metadata.

### Fallback

Retiring the atlas, or changing it to an incompatible shape, falls back to the last mesh in the main and shadow passes
and increments `Stats.impostor_fallbacks`. A cull arena overflow uses the separate level-zero fallback ([GPU
drawing](lod.md#gpu-drawing)). A change to the terminal metadata invalidates temporal correspondence.

## Atlas contract

An application that supplies its own atlas builds it to this layout.

- **Grid.** `frames_per_side` directions per side: 2, 4, 8, 16 or 32. A cell holds at least four texels. Device limits
  still apply.
- **Cell.** The default cell is 128 by 128 texels, with a one-texel duplicated gutter on each side, so the usable
  capture is 126 by 126.
- **Texture.** RGBA8_UNORM, one mip, no mip generation, linear clamped sampling, no sRGB conversion. Width is
  `frames_per_side * cell_size` and height is twice that. The default is 1024 by 2048 texels (8 MiB).
- **Upper square.** Linear RGB and coverage. Coverage comes from the captured depth, never from metallic alpha.
- **Lower square.** Subject-local octahedral normal XY, roughness and normalized linear capture depth. Bake-time
  nearest-surface padding fills its transparent texels within each cell, so the depth estimate exists before refinement
  reaches coverage. Empty cells stay empty. Only the upper RGB is divided by coverage.
- **Precision.** Depth spans the sphere diameter, with a maximum quantization step of `2 * radius / 255`. Normals and
  other channels have eight-bit precision.
- **Directions.** For sides of four or more, directions decode the inclusive octahedral lattice
  `2 * (x,y) / (side - 1) - 1`. Selection uses the containing grid triangle, and duplicate seam and pole directions use
  a deterministic tie. A 2 by 2 atlas uses four tetrahedral directions, because four octahedral corners would all decode
  to the same pole. The CPU and GLSL share the direction constants through the generated ABI.

## Drawing

- **Shading.** Each placement emits two triangles with no geometry-buffer read. The fragment stages reconstruct three
  direction samples, blend attributes by coverage and write reverse-Z surface depth. Forward, deferred, depth and
  velocity use the same reconstruction.
- **Shadows.** Shadow passes use light-relative directions and keep the parent view's selected level, including
  offscreen casters.
- **Transforms.** Reflections and nonuniform scales use the placement transform and its inverse transpose. HEIGHT sway
  and fade use the shared object anchor.
- **Motion.** Stable velocity reconstructs the same local point under the previous placement and wind time. LOD and
  frame-triplet changes mark affected pixels for temporal rejection. Histories stay independent per view and instance.
- **Other consumers.** Picking, tracing, physics and spatial indexing keep their base-mesh or explicit-collider
  contracts.

## Limits

- Thin features, occluded surfaces and hard-normal edges are atlas approximations.
- Strong nonlinear sway need not match the interpolation of a coarse mesh.
- Impostor shadows approximate the mesh's shadows. Thin or multiply occluded geometry is not exact.
- Close-up quality and suitability depend on the asset. Check it for each kind of vegetation.
- No animated impostors. An animated group returns `UNSUPPORTED`.
- The sources in the table above only: rigid, opaque or masked `Standard` meshes with zero metallic factor.
- An atlas is stale after its source changes until it is baked again.

## See also

- [Whole-object LOD](lod.md) for groups, selection and the fallback.
- [Views](views.md#multisample-anti-aliasing) for multisampling.
- [Vegetation](vegetation.md#whole-object-lod) for scattered LOD groups.
