# Environments and image-based lighting

Standard materials combine diffuse irradiance and roughness-filtered reflections
from an environment with their direct lights and emission. The background can
display that environment, another environment, or a solid color. Basic materials
remain unlit.

## Load and select an environment

Environment descriptions live in `c3d::light`; the asset store owns their records.
Load a Radiance HDR texture and add a description that references it:

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

Use the normal `c3d`, `c3d::asset`, `c3d::asset::image`, `c3d::light`,
`c3d::scene`, `c3d::render`, and `std::math` imports. Asset keys share one
namespace, so source textures and environments need distinct nonempty keys.

`light::texture_environment` accepts either an equirectangular HDR texture or an
existing native color cube. `light::solid_environment({ 0.2f, 0.3f, 0.5f })`
describes uniform scene-linear radiance without a texture. Constructors own
nothing; insertion validates the description and resolves a texture source.

The source forms are:

| Source | Accepted data |
| --- | --- |
| Equirectangular | Single-layer 2D RGBA16_FLOAT or RGBA32_FLOAT |
| Native cube | Six square faces, RGBA8_UNORM, RGBA8_SRGB, RGBA16_FLOAT or RGBA32_FLOAT |
| Solid | Finite nonnegative RGB |

Native cubes keep their authored resolution and orientation. Their face order
is +X, -X, +Y, -Y, +Z, -Z; see [cube textures](textures.md#load-six-cube-faces).
Equirectangular conversion places north at the first image row and the horizontal
seam at world -X. Exact poles use the image's central longitude. Depth textures,
non-cube arrays and compressed environment sources are unsupported.

## Independent lighting and background

Display a source sky independently of the lighting selection:

```c3
scene.background = scene::BACKGROUND_DEFAULT;
scene.background.kind = BackgroundKind.ENVIRONMENT;
scene.background.environment = studio;
scene.background.intensity = 0.25f;
scene.background.rotation = quaternion::IDENTITY;
```

For a color background, keep `BackgroundKind.COLOR` and set `background.color`.
Its default is opaque black. Lighting can remain enabled while a color is shown;
a sky can also be displayed with no lighting environment. A zero
`scene.environment` selects no environment lighting.

Lighting and background intensity default to 1 and their rotations default to
identity. An active role's intensity must be finite and nonnegative, and its
quaternion must be normalized when rendering. Rotation describes the environment
frame in world space; sampling transforms directions into that frame. Camera
translation does not move the sky.

These values change view data only. Changing intensity, rotation, background
color or which prepared environment is selected does not regenerate lighting.
`prepare_scene` prepares resources independently of these view-only values, so
they can be finalized after preparation and before rendering.

The sky samples the original source cube at mip zero. Reflections use a separate
filtered cube, so roughness filtering never blurs the displayed sky.

## Ambient, occlusion and material normals

Without a lighting environment, the existing constant scene ambient remains
available. With one selected, SH irradiance replaces constant ambient unless
`scene.ambient_add` is true. Selecting an environment with intensity zero still
suppresses constant ambient when `ambient_add` is false.

The material occlusion map affects diffuse environment lighting and constant
ambient only. It does not attenuate environment reflections, direct lights or
emissive output. Shadow visibility affects direct lights only. IBL uses the final
normal after normal mapping, with the same material factors and view direction as
the Standard BRDF.

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
| `specular_size` | 256 | At least 32, allowing six roughness mips |

Sizes are not restricted to powers of two. Each filtered mip halves the previous
dimensions, rounded down. GPU device limits and allocation failures still apply.
Sampling budgets and the six roughness levels are internal implementation choices.

Generated cubes use RGBA16_FLOAT and its precision/range. At the defaults, the
converted source occupies 12 MiB and the filtered cube occupies just under 4 MiB
of texels per equirectangular environment. These figures exclude the original
source texture and its mips, CPU pixels, temporary allocations, allocator overhead
and the renderer-shared 256-square BRDF LUT. A native cube needs no converted
copy; a solid source uses one texel per face. Doubling an edge dimension roughly
quadruples that image's storage and processing work.

## Preparation and edits

`renderer.upload_environment(id)` prepares the complete environment. The generic
`renderer.upload(id)` facade accepts EnvironmentId too. Outside a frame,
preparation submits the required work and waits without acquiring or presenting
a window image. Inside an output frame it queues work before subsequent consumers.
An upload failure leaves the open frame and earlier queued preparation intact;
the caller can continue the frame or abort it.

`renderer.prepare_scene(&scene)` prepares selected lighting/background assets,
referenced mesh assets and their required pipelines. A background-only environment
prepares its source and sky pipeline without allocating unused specular, SH or LUT
resources. Selecting it for lighting later adds the missing resources.

Rendering also supports lazy first use; allocation, pipeline creation and
processing can then stall the frame. Explicit preparation is the loading-screen
path. SH coefficients remain in GPU memory throughout normal rendering.

Edit a borrowed environment record and mark its description dirty:

```c3
assets.environment(studio).desc.settings.specular_size = 512;
assets.mark_environment_dirty(studio);
renderer.upload_environment(studio)!;
```

Specular-size changes reuse the source cube. Equirectangular conversion-size
changes rebuild the converted source and its lighting. Source texture identity,
content revision or backing changes also invalidate derived results; call
`assets.mark_texture_dirty(source)` after a pixel edit. Redundant dirty marks and
changes to inactive settings do not regenerate equivalent processing.

Keep environment descriptions, processing settings and source pixels stable from
`begin_frame` through `end_frame` or `abort_frame`. Cheap scene lighting/background
values can differ between ordered views. Recorded outputs become committed only
after successful submission; aborting unsubmitted work leaves it retryable.

## Ownership and failures

The environment borrows its source TextureId. `remove_environment` invalidates
the environment id and frees its key/record; it does not remove the texture.
There is no separate environment CPU-release operation.

The renderer owns generated images, views and SH allocations. It retains them
for reuse and retires replaced objects after their submitted consumers complete.
It never releases CPU source pixels. After successful preparation, the application
may call `assets.release_texture_cpu(source)`; an existing source mirror can still
support a settings-only rebuild. Another renderer needing those missing bytes
returns `ASSET_DATA_UNAVAILABLE` until the application reloads them.

Use `assets.validate_environment(desc)` to validate editable descriptions against
current source metadata without GPU work. Typed lookup uses
`assets.find_environment(key)`. Important failure meanings are:

| Fault | Meaning |
| --- | --- |
| `INVALID_ID` | Explicit upload of a dead environment, or a live environment referencing a dead texture |
| `INVALID_ARGUMENT` | Invalid processing data, non-finite/negative solid color, zero extent, malformed cube shape, duplicate key or wrong-kind key lookup |
| `UNSUPPORTED` | Unsupported environment texture format, positive texture depth or non-cube array |
| `CAPACITY_EXCEEDED` | The fixed environment asset pool is full |
| `NOT_FOUND` | No asset exists under the requested key |
| `ASSET_DATA_UNAVAILABLE` | Source bytes are needed for upload but were released |

Description validation checks processing size, source liveness, zero extent,
positive depth, cube/array shape and format in that order. Conversion size is
checked only for supported equirectangular input. GPU allocation, descriptor,
pipeline, command and device faults propagate unchanged from gpu.c3l.

A stale scene environment selection is counted as a dangling reference and falls
back to no IBL. A stale background selection uses `background.color`. A live
environment with a removed source texture remains an error rather than silently
sampling its old source.

`AssetStoreDesc.max_environments` defaults to 16; zero also selects that default.
GPU images are allocated on use, not for every reserved store slot.

## Example

```bash
python3 scripts/build.py --example ibl
./examples/build/ibl --gpu-timings
```

The example bundles two small CC0 HDRs and prepares both before the first frame.
Columns vary metallic from 0 to 1; rows increase roughness from bottom to top.
Lighting and background controls select either environment independently, with
an optional link checkbox. AO strength, constant ambient and rotation controls
show their separate effects. Processing sizes are edited per environment and
take effect with **Apply processing sizes**. The preparation counter stays zero
when frames reuse prepared resources.

Drag outside the GUI to orbit, scroll to zoom, and release Escape outside GUI
keyboard capture to close. Full validation is enabled; GPU timing is optional.

Rendering writes scene-linear HDR. The current display composite has no
tonemapping or exposure control, so highlights can clip on presentation. Source
and lighting intensities help inspect the result but do not replace display
processing. Local probes, environment capture and compressed cube processing are
not supported.
