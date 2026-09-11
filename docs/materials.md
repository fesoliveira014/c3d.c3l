# Materials and direct lighting

`Basic` renders an unlit color with an optional texture map. `Standard` adds
metallic-roughness shading from directional, point and spot lights, scene ambient,
and five independent texture slots. Both use the asset store's shared material ids.

## Standard factors

```c3
StandardParams params = material::STANDARD_PARAMS_DEFAULT;
params.base_color = { 0.7f, 0.25f, 0.1f, 1 };
params.metallic = 0;
params.roughness = 0.5f;
MaterialId material_id = assets.add_material(material::standard(params))!;
```

`STANDARD_PARAMS_DEFAULT` uses white base RGBA, metallic 1, roughness 1, black
emissive RGB, emissive strength 1, normal scale 1 and occlusion strength 1.
All five maps start absent with identity UV transforms. A zero-initialized
`StandardParams` keeps literal zeros, including zero UV scale; use the named
default when you want those defaults.

Base RGBA, metallic and roughness are in [0, 1]. Emissive RGB and strength are
finite and nonnegative; values above 1 preserve HDR emission. Normal scale is
finite and may be negative; occlusion strength is in [0, 1]. The renderer floors
perceptual roughness at 0.045 for shading while preserving the authored value.

`MaterialCommon` controls alpha and sidedness. Standard supports `OPAQUE` and
`MASK`, using base factor alpha times sampled alpha and `alpha_cutoff` for the
mask. Double-sided Standard flips its shading normal on back faces. Resolving
Standard `BLEND` returns `c3d::UNSUPPORTED`.

## Standard maps

Each slot is a `TextureSlot` with its own texture, sampler, UV0/UV1 selection,
and scale/rotation/offset. The slots can share one `TextureId` while using
different coordinates and samplers. Color-space selection belongs to the texture
asset; the renderer does not infer it from the slot.

| Slot | Channels | Load color space | Effect |
| --- | --- | --- | --- |
| `base_color_map` | RGBA | sRGB RGB, linear alpha | Multiplies base RGBA |
| `metallic_roughness_map` | G roughness, B metallic | Linear | Multiplies the two scalar factors; R and A are ignored |
| `normal_map` | RGB tangent-space XYZ | Linear | Decodes `RGB * 2 - 1`, scales XY, then normalizes |
| `occlusion_map` | R | Linear | Multiplies ambient diffuse by `mix(1, R, occlusion_strength)` |
| `emissive_map` | RGB | sRGB | Multiplies emissive RGB and strength |

```c3
params.base_color_map = material::texture_slot(base_color_texture);
params.metallic_roughness_map = material::texture_slot(material_data_texture);
params.occlusion_map = material::texture_slot(material_data_texture, uv_set: 1);
params.normal_map = material::texture_slot(normal_texture);
params.emissive_map = material::texture_slot(emissive_texture);
```

Zero or stale texture ids make that slot absent. Absent color, metallic/roughness,
occlusion and emissive maps retain their scalar behavior; an absent normal map
retains the geometry normal. Occlusion never changes direct lighting or emission,
and strength zero removes its effect. A black emissive factor keeps emission
black even with a populated map. Normal scale zero disables normal perturbation.
Live cube and render-target references return `c3d::UNSUPPORTED`; comparison
samplers and UV sets above 1 return `c3d::INVALID_ARGUMENT`.

## Tangent frames

A supplied tangent stream is authoritative. Tangent XYZ follows the model's
linear transform, is orthogonalized against the inverse-transpose world normal,
and tangent W supplies bitangent handedness. W must be +1 or -1 and consistent
within each triangle. Reflected model transforms reverse that handedness.
Reflected model and camera transforms also preserve front-face classification;
double-sided shading flips the final normal on back faces.

Without a tangent stream, filled triangles derive a frame from world-position
and transformed normal-map UV derivatives. Mirrored or rotated lookup coordinates
therefore change this derived frame. A supplied frame keeps its authored basis:
changing the lookup UV set or transform does not rotate or rebuild it. A zero or
degenerate supplied tangent keeps the geometry normal without trying derivatives;
degenerate position or UV derivatives likewise keep the geometry normal. A decoded
zero-length map normal uses neutral tangent-space `(0, 0, 1)`.

`Geometry.compute_tangents(allocator)` explicitly creates tangents from UV0; it
does not use a material's UV1 selection or lookup transform. The renderer never
runs it implicitly. Neither `compute_tangents` nor the derivative frame promises
MikkTSpace compatibility. `Geometry.transform` updates tangent handedness when
baking a reflection, while retaining its existing winding contract: call
`flip_winding` explicitly when the reflected geometry needs its winding
reversed. Normal textures must contain XYZ in RGB: RG-only normal maps with
reconstructed Z are not supported.

An active normal map without supplied tangents requires filled triangle
rasterization. Lines, points and effective wireframe triangles return
`c3d::UNSUPPORTED` during preparation or rendering. Supplied tangents, a missing
normal map, or normal scale zero preserve those geometry paths. A requested
wireframe on a device without line polygon mode still uses filled triangles.

## Material storage

Renderer material slots are 224 bytes (`render::MATERIAL_STRIDE`). The generated
`StandardMaterialGpu` has a 64-byte header followed by five nested 32-byte
`TextureMapGpu` members at offsets 64, 96, 128, 160 and 192. Each map record
contains `texture_index`, `sampler_index`, `uv_offset` and `uv_linear`; presence
and UV-set selection live in the header's `map_flags`. Bits 0–4 are presence bits
for base color, metallic-roughness, normal, occlusion and emissive in that order;
bits 5–9 select UV1 for those same slots. The matching schema constants are
`c3d::shader::MATERIAL_MAP_BASE_COLOR`, `MATERIAL_MAP_METALLIC_ROUGHNESS`,
`MATERIAL_MAP_NORMAL`, `MATERIAL_MAP_OCCLUSION`, `MATERIAL_MAP_EMISSIVE` and
`MATERIAL_MAP_UV1_SHIFT`.

`BasicMaterialGpu` occupies 64 bytes: `map_flags` is at offset 12 and its
`TextureMapGpu map` is at offset 32. It uses the same base-color presence and
UV1 bits as Standard. The default 4096-slot material heap is 917,504 bytes.
Custom renderer-side packing code supplies
`render::MaterialBindings` to `write_material_block`, with `base_color`,
`metallic_roughness`, `normal`, `occlusion` and `emissive` fields. Each is a
`TextureBinding` carrying texture/sampler indices and an explicit `present` flag.
Basic uses only `base_color`; inactive fields stay empty. Bindless index zero is
not a presence test. Ordinary consumers edit asset material slots and let the
renderer resolve these bindings.

## Shared edits

```c3
MaterialAsset* record = assets.material(material_id);
record.data.standard.roughness = 0.8f;
assets.mark_material_dirty(material_id);
```

Every mesh using the id sees the edit. Finish edits before scene preparation or
view recording; advance the revision once after changing values. An unchanged
GUI frame leaves the revision alone. The GUI material panel selects the active
material family before reading its parameters. Texture pixel, backing and sampler
revisions are tracked independently for every slot: editing and marking a texture
or sampler dirty does not require a material dirty call. Changing a slot itself
does require one. Removed or stale texture generations use the absent-map behavior;
they never silently bind a new asset reusing the index.

Prepare or upload resources before releasing CPU sources. A current mirror stays
usable after explicit texture or geometry source release; a renderer that needs
the missing source reports `c3d::ASSET_DATA_UNAVAILABLE`. Keep edits and releases
outside the interval from preparation through submission. See
[source ownership](textures.md#upload-edit-and-release-cpu-sources).

Changing families requires assigning a complete `Material`, then marking it dirty:

```c3
record.data = material::basic({ .color = { 1, 0.5f, 0.2f, 1 } });
assets.mark_material_dirty(material_id);
```

Use the matching `.data.basic` or `.data.standard` arm. Do not change `kind`
without initializing that arm.

## Lights

```c3
Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 1))!;
Node* bulb = scene.add_light(light::point({ 1, 1, 1 }, 10, 10))!;
bulb.local.position = { -3, 2, 4 };
Node* spot = scene.add_light(light::spot(
    color: { 1, 1, 1 },
    intensity: 20,
    inner: 0.3f,
    outer: 0.6f,
    range: 12,
))!;
spot.local.position = { 3, 3, 5 };
spot.local.rotation = maths::look_rotation((-spot.local.position).normalize(), { 0, 1, 0 });
```

Directional and spot lights emit along their node's transformed local −Z axis.
Point and spot positions come from the node's world transform. Parenting therefore
moves and rotates a light; scale does not rescale intensity or range. The
transformed direction must remain nonzero.

Light color and intensity are finite and nonnegative. Directional intensity
is an irradiance scale; point and spot intensity is a radiant-intensity scale.
Point and spot lights use inverse-square distance attenuation. A positive range
is a world-space cutoff with smooth attenuation inside it and zero contribution
at and beyond it; range 0 is unbounded.

Spot angles are half-angles in radians, with `0 <= inner < outer <= PI/2`.
The GUI displays degrees. Ordinary cones have full angular weight inside the
inner cone and zero weight at the outer boundary, with a smooth ramp between
them. For very narrow cones, the renderer floors the inner-to-outer cosine
difference at 0.001 to keep the calculation bounded. This approximation can
reduce the angular weight inside the authored inner cone.

`Scene.add_light` can return `c3d::CAPACITY_EXCEEDED` when node capacity is full.
Lights are ordinary components owned by the scene. Edit the component and call
`scene.update_world()` after transform changes, before rendering. Light values
are gathered anew for each view and need no material dirty call.

## Visibility and receiver layers

A hidden node or ancestor disables its light. The light node's `layers` must
intersect the camera's `layers` to make the light eligible for that view.
`Light.layers` separately selects receiving mesh-node layers. A zero receiver
mask or zero intensity disables contribution without consuming the light budget.

These masks serve different purposes. A mesh visible through camera layer 1
may have node layers 1|2 and receive a light whose receiver mask is only 2.
Keep the complete receiver mask; it is not restricted to camera bits.

```c3
Light* light = scene.get(bulb, Light);
bulb.layers = 3;
light.layers = 2;
```

Here cameras seeing layer 1 or 2 can include the bulb, but it illuminates only
meshes carrying layer 2. Ambient and emissive do not use direct-light masks.

## Ambient and light capacity

Scenes start with white `ambient_color` and zero `ambient_intensity`. Both must
remain finite and nonnegative. Ambient supplies a simple diffuse contribution:
`ambient_color * ambient_intensity * base_color.rgb * (1 - metallic)`,
using mapped base/metallic values and the occlusion multiplier when present.
It adds no ambient specular reflection. Emissive RGB times strength remains
visible without any direct lights or ambient illumination.

`RendererDesc.max_lights` sets per-view capacity. Zero chooses the default 256;
`Renderer.max_lights` holds the resolved capacity. The renderer first excludes
hidden, off-camera-layer, zero-intensity and zero-receiver-mask lights, then
culls finite point and spot ranges against the view frustum. Directional and
unbounded lights have no spatial culling.

The first eligible lights in current dense component order fill the budget.
Remaining eligible lights count as drops. Removing components can change that
order; selection is neither brightness-ranked nor stable insertion order.
`Stats.lights` and `Stats.lights_dropped` accumulate packed lights and budget
drops across recorded views and reset at `begin_frame`. The GUI Stats panel
shows the previous frame's counts.

## Interactive example

```bash
python3 scripts/build.py --example pbr
./examples/build/pbr --gpu-timings
```

The static grid uses 49 distinct materials. Columns increase metallic from 0 to
1; rows increase roughness from 0.05 to 1, bottom to top. Alternating columns use
receiver layers 1 and 2. Both prepared sphere assets have UV1 equal to twice UV0;
“Geometry has supplied tangents” switches the entire grid between an absent
tangent stream and explicitly generated UV0 tangents.

All maps initially use trilinear repeat, identity transforms and strength 1.
Occlusion uses UV1; other maps use UV0. Metallic/roughness and occlusion share one
linear image. The middle row has emissive RGB `(0.15, 0.15, 0.15)`; the other rows
start black. Opaque alpha leaves the base-color checker solid until “Alpha mask”
is enabled for a selected sphere.

Select a sphere in Scene to edit factors and the five collapsible Sphere maps
sections, or select a light to edit color, intensity, range, cone angles and
receiver layers. Each map exposes enable, UV set, scale, rotation in degrees,
offset and sampler presets. Scene supplies visibility, layers and transforms.
“Scalar-only preset” restores the original grid factors, empty maps and opaque
common state; “Reset mapped preset” restores the mapped materials described
above. Both leave geometry selection, lights and camera settings unchanged.

Controls supplies ambient, camera layer visibility and orthographic projection.
Drag outside GUI windows to orbit, scroll to zoom, and release Escape outside
GUI keyboard capture to close. Orthographic view height has a separate control.
GPU timings are optional; full validation is enabled for every run.

## Current rendering limits

Texture ownership and sampling are described in [Textures and
images](textures.md). [Sun, spot and point shadows](shadows.md) attenuate Standard
direct lighting; Basic and Standard surfaces can cast opaque or masked shadows. There is
no environment lighting or ambient specular reflection. Shading writes scene-linear
HDR into the renderer target;
the existing composite adds no tonemapper or exposure control, so bright values
can clip on presentation. Compare lighting with consistent presentation
settings.
