# Environments and image-based lighting

An environment is an asset that lights a scene and, optionally, fills its background. Standard materials combine diffuse
irradiance and roughness-filtered reflections from the environment with their direct lights and emission. Physical materials
add clearcoat reflections from the same GGX-filtered source and sheen reflections from a dedicated Charlie-filtered source.
The background can display that environment, another environment, or a solid color. Basic materials remain unlit.

Environment descriptions live in `c3d::light`; the asset store owns their records and the renderer owns the generated images.

## Quick start

Load a Radiance HDR texture, add an environment that references it, and select it on the scene:

```c3
TextureId source = image::load_hdr(&assets, "studio.hdr", "studio_source")!;
EnvironmentId studio = assets.add_environment(
    light::texture_environment(source),
    "studio_environment",
)!;

scene.environment = studio;
scene.environment_intensity = 1;
scene.environment_rotation = quaternion::IDENTITY;
renderer.prepare_scene(&scene)!;
```

Use the normal `c3d`, `c3d::asset`, `c3d::asset::image`, `c3d::light`, `c3d::scene`, `c3d::render` and `std::math` imports.
Asset keys share one namespace, so source textures and environments need distinct nonempty keys.

## Concepts

- **Source forms.** `light::texture_environment` accepts either an equirectangular HDR texture or an existing native color
  cube. `light::solid_environment({ 0.2f, 0.3f, 0.5f })` describes uniform scene-linear radiance without a texture.
  Constructors own nothing; insertion validates the description and resolves a texture source.

  | Source | Accepted data |
  | --- | --- |
  | Equirectangular | Single-layer 2D RGBA16_FLOAT or RGBA32_FLOAT |
  | Native cube | Six square faces, RGBA8_UNORM, RGBA8_SRGB, RGBA16_FLOAT or RGBA32_FLOAT |
  | Solid | Finite nonnegative RGB |

- **Orientation.** Native cubes keep their authored resolution and orientation. Their face order is +X, -X, +Y, -Y, +Z, -Z; see
  [cube textures](textures.md#load-six-cube-faces). Equirectangular conversion places north at the first image row and the
  horizontal seam at world -X. Exact poles use the image's central longitude.
- **Lighting and background are separate roles.** `scene.environment` lights the scene; `scene.background` shows a sky or a
  color. Each has its own intensity and rotation. A zero `scene.environment` selects no environment lighting.
- **View-only values.** Intensity, rotation, background color and the choice of prepared environment change view data only.
  They do not regenerate lighting, so they can be finalized after preparation and before rendering.
- **Ownership.** The environment borrows its source `TextureId`. The renderer owns generated images, views and SH
  allocations, reuses them across frames and retires replaced objects after their submitted consumers complete.

## Independent lighting and background

Display a source sky independently of the lighting selection:

```c3
scene.background = scene::BACKGROUND_DEFAULT;
scene.background.kind = BackgroundKind.ENVIRONMENT;
scene.background.environment = studio;
scene.background.intensity = 0.25f;
scene.background.rotation = quaternion::IDENTITY;
```

For a color background, keep `BackgroundKind.COLOR` and set `background.color`; its default is opaque black. Lighting can
stay enabled while a color is shown, and a sky can be displayed with no lighting environment.

Lighting and background intensity default to 1 and their rotations default to identity. An active role's intensity must be
finite and nonnegative, and its quaternion must be normalized when rendering. Rotation describes the environment frame in world
space; sampling transforms directions into that frame. Camera translation does not move the sky.

The sky samples the original source cube at mip zero. Reflections use a separate filtered cube, so roughness filtering never
blurs the displayed sky.

An [atmosphere](sky.md) replaces `scene.environment` and the background while it resolves. Its lighting cubes are
renderer-owned, not assets.

## Ambient, occlusion and material normals

- Without a lighting environment, the constant scene ambient applies. With one selected, SH irradiance replaces constant
  ambient unless `scene.ambient_add` is true. An environment with intensity zero still suppresses constant ambient when
  `ambient_add` is false.
- The material occlusion map affects diffuse environment lighting and constant ambient only. It does not attenuate Standard,
  clearcoat or sheen reflections, direct lights or emissive output. Shadow visibility affects direct lights only.
- Standard image-based lighting uses the base normal after normal mapping. Physical clearcoat uses its own coat normal for
  direct and environment reflection; without a coat normal map it uses the geometry normal.
- Physical transmission samples the lighting environment's specular cube along the refracted direction, at the base roughness
  level, when the refracted exit point falls outside the screen; without a lighting environment that fallback is black.

The material composition of clearcoat, sheen and transmission is in
[Physical clearcoat and sheen](materials.md#physical-clearcoat-and-sheen) and
[Physical transmission](materials.md#physical-transmission).

## Processing quality

Start from the named settings default and override either face-edge dimension:

```c3
EnvironmentSettings settings = light::ENVIRONMENT_SETTINGS_DEFAULT;
settings.conversion_size = 256;
settings.specular_size = 128;

EnvironmentId preview = assets.add_environment(
    light::texture_environment(source, settings),
    "preview_environment",
)!;
renderer.upload_environment(preview)!;
```

| Setting | Default | Domain and effect |
| --- | --- | --- |
| `conversion_size` | 512 | Positive for equirectangular input; ignored for native cubes and solid sources |
| `specular_size` | 256 | At least 32 (`asset::MIN_ENVIRONMENT_SPECULAR_SIZE`), allowing six roughness mips |

Sizes are not restricted to powers of two. Each filtered mip halves the previous dimensions, rounded down. GPU device limits
and allocation failures still apply. Sampling budgets and the six roughness levels are internal choices. Generated cubes use
RGBA16_FLOAT.

### Memory and heap slots

At the defaults, an equirectangular environment's converted source takes 16 MiB (12 MiB plus its mip chain) and its
GGX-filtered cube just under 4 MiB. An environment used by an active sheen material adds a Charlie-filtered cube of the same
size. These figures exclude the source texture and its mips, CPU pixels, the renderer-shared 256-square BRDF LUT and the
512 KiB renderer-shared sheen LUT. A lit environment also keeps a 9 KiB buffer for its SH projection. Doubling an edge
dimension roughly quadruples a generated cube's storage and processing work.

Each generated cube keeps one storage view per face and mip. The views occupy texture heap slots while the cube lives:

| Environment | Heap slots, about |
| --- | --- |
| Lit, equirectangular source at the default size | 96; six more per extra source mip |
| Lit, solid source | 42 |
| Lit, native cube | 36 |
| Charlie cube for active sheen | 37 more |

The renderer's default heap holds 4,096 slots (`RendererDesc.texture_heap_capacity` changes it). A full heap fails preparation
with `gpu::DESCRIPTOR_HEAP_FULL`. A native cube needs no converted copy, and a solid source uses one texel per face.

A native cube with a full mip chain down to one texel filters with a small sampling budget. Without the chain, the renderer
reads the cube's base level with a much larger budget. The renderer builds the chain for converted, solid and atmosphere
sources itself.

## Preparation and edits

`renderer.upload_environment(id)` prepares the base environment source, GGX reflection cube and SH irradiance. It has no
material context and does not prepare Charlie sheen resources. The generic `renderer.upload(id)` accepts an `EnvironmentId`
with the same behavior. Outside a frame, preparation submits the required work and waits without acquiring or presenting a
window image. Inside an output frame it queues work before subsequent consumers. An upload failure leaves the open frame and
earlier queued preparation intact; the caller can continue the frame or abort it.

`renderer.prepare_scene(&scene)` prepares the selected lighting and background assets, all referenced mesh assets and their
required pipelines, including hidden mesh nodes. If any referenced material has active sheen, it also prepares the shared
sheen LUT and the selected lighting environment's Charlie cube. A background-only environment prepares its source and sky
pipeline without allocating unused GGX, SH or sheen resources; selecting it for lighting later adds the missing resources.

Rendering also prepares lazily from visible candidates. Only active sheen requests the shared LUT and, with a lighting
environment, the Charlie cube. That one-time allocation and filtering can stall the first frame, so `prepare_scene` is the
loading-screen path for complete material-dependent preparation. Prepared LUTs and cubes are retained and shared on later
frames.

Sheen demand does not depend on environment intensity. Changing intensity, rotation, sheen color or sheen roughness reuses
prepared filtering. Changing the environment source or `specular_size` invalidates the Charlie cube as well as the base
filtered results; it is rebuilt only when active sheen next needs that environment. Disabling sheen keeps a still-current
Charlie cube for later reuse.

Edit a borrowed environment record and mark its description dirty:

```c3
assets.environment(studio).desc.settings.specular_size = 512;
assets.mark_environment_dirty(studio);
renderer.upload_environment(studio)!;
```

`assets.replace_environment(studio, desc)` validates a complete description with `validate_environment`, assigns it under the
same id and key and advances the revision once. It faults like `add_environment` (`INVALID_ARGUMENT`, `INVALID_ID`,
`UNSUPPORTED`) and changes nothing on a fault. The previous source texture stays in the store. Path-traced views restart after a
replacement; see [Accumulation and resets](path_tracing.md#accumulation-and-resets).

What regenerates:

- A `specular_size` change reuses the source cube and rebuilds the needed GGX and Charlie filters.
- A `conversion_size` change rebuilds the converted source and its lighting.
- A change of source texture identity, content revision or backing also invalidates derived results; call
  `assets.mark_texture_dirty(source)` after a pixel edit.
- Redundant dirty marks and changes to inactive settings regenerate nothing.
- At unchanged sizes, regeneration writes the existing cubes and SH through their views and allocates nothing: a source pixel
  edit, a new solid color or a re-uploaded native cube. A changed size reallocates the affected cubes and retires the replaced
  ones after their submitted consumers complete.
- Probe volumes filled from the environment refill in the frame its lighting regenerates.
- A source change keeps the filtered cubes of an environment that is not lit this frame; they are rewritten when lighting or
  sheen next needs them.

Environment work recorded inside a frame is timed as `Pass.ENVIRONMENT`. `Stats.gpu_environment_stage_ms` splits it by
`EnvironmentStage`:

| Stage | Work |
| --- | --- |
| `environment.source` | Conversion of an equirectangular or solid source, and the mip chain of either. |
| `environment.prefilter` | GGX filtering. |
| `environment.irradiance` | SH projection. |
| `environment.sheen` | Charlie filtering. |
| `environment.luts` | The shared lookup tables, once. |
| `environment.sky_transmittance`, `environment.sky_multi_scattering`, `environment.sky` | An atmosphere's tables, and the march and mip chain of its cube. |
| `environment.cloud_noise` | The shared cloud noise volume, once. |

Preparation outside a frame is not timed.

Keep environment descriptions, processing settings and source pixels stable from `begin_frame` through `end_frame` or
`abort_frame`. Cheap scene lighting and background values can differ between ordered views. Recorded outputs become committed
only after successful submission; aborting unsubmitted work leaves it retryable.

## Remove an environment and release sources

`remove_environment` invalidates the environment id and frees its key and record; it does not remove the texture. There is no
separate environment CPU-release operation.

The renderer never releases CPU source pixels. After successful preparation, the application may call
`assets.release_texture_cpu(source)`; an existing source mirror can still support a settings-only rebuild. Another renderer
needing the missing bytes returns `ASSET_DATA_UNAVAILABLE` until the application reloads them.

A stale scene environment selection is counted as a dangling reference and falls back to no IBL. A stale background selection
uses `background.color`. A live environment whose source texture was removed stays an error rather than silently sampling its
old source.

## Reference

| Call | Use |
| --- | --- |
| `light::texture_environment(source, settings)` | Describe an environment over a texture. |
| `light::solid_environment(color, settings)` | Describe a uniform environment. |
| `AssetStore.add_environment(desc, key)` | Validate and add; returns the `EnvironmentId`. |
| `AssetStore.replace_environment(id, desc)` | Replace the description under the same id and key. |
| `AssetStore.validate_environment(desc)` | Validate against current source metadata without GPU work. |
| `AssetStore.environment(id)`, `mark_environment_dirty(id)` | Borrow the record; advance its revision after an edit. |
| `AssetStore.find_environment(key)` | Typed lookup by key. |
| `AssetStore.remove_environment(id)` | Free the record, keep the texture. |
| `Renderer.upload_environment(id)` | Prepare now or in the open frame. |

`AssetStoreDesc.max_environments` sets the fixed environment pool; it defaults to 16, and zero also selects that default. GPU
images are allocated on use, not for every reserved store slot.

| Fault | Meaning |
| --- | --- |
| `INVALID_ID` | Explicit upload of a dead environment, or a live environment referencing a dead texture |
| `INVALID_ARGUMENT` | Invalid processing data, non-finite or negative solid color, zero extent, malformed cube shape, duplicate key or wrong-kind key lookup |
| `UNSUPPORTED` | Unsupported environment texture format, positive texture depth or non-cube array |
| `CAPACITY_EXCEEDED` | The fixed environment asset pool is full |
| `NOT_FOUND` | No asset exists under the requested key |
| `ASSET_DATA_UNAVAILABLE` | Source bytes are needed for upload but were released |

Validation checks, in this order, the processing size, source liveness, zero extent, positive depth, cube or array shape and
format. Conversion size is checked only for supported equirectangular input. GPU allocation, descriptor, pipeline, command and
device faults propagate unchanged from gpu.c3l.

## Limits

- Compressed cube sources and compressed environment textures are not supported. Depth textures and non-cube arrays are not
  supported either.
- The environment pool is fixed at store creation.
- A lit environment holds about 96 texture heap slots at the default sizes, six more per extra source mip, and 37 more with
  sheen; plan the heap size for several environments.
- Rendering writes scene-linear HDR. A `DISPLAY_LDR` view, the default, tonemaps with ACES and applies `Camera.exposure`;
  adaptive exposure is an opt-in post setting. A `LINEAR_HDR` view does not tonemap. Source and lighting intensities help
  inspect the result but do not replace display processing; see [Display processing](post.md).

Run the worked example with `python3 scripts/build.py --example ibl`. It bundles two small CC0 HDRs; see
`examples/assets/ibl/README.md`.

## See also

- [Reflection probes](reflection_probes.md) capture a scene into a cube environment that lights local specular reflections.
- [Probe volumes](probe_volumes.md) give local diffuse lighting from a grid of probes.
- [Sky and atmosphere](sky.md) for the atmosphere that replaces the scene environment.
- [Materials](materials.md) for how materials consume the environment.
- [Textures](textures.md) for loading HDR and cube textures.
