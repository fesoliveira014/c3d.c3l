# Materials and direct lighting

`Basic` renders an unlit color with an optional texture map. `Standard` adds
metallic-roughness shading from directional, point and spot lights, scene ambient,
and emissive factors. Both use the asset store's shared material ids.

## Standard factors

```c3
StandardParams params = material::STANDARD_PARAMS_DEFAULT;
params.base_color = { 0.7f, 0.25f, 0.1f, 1 };
params.metallic = 0;
params.roughness = 0.5f;
MaterialId material_id = assets.add_material(material::standard(params))!;
```

`STANDARD_PARAMS_DEFAULT` uses white base RGBA, metallic 1, roughness 1, black
emissive RGB and emissive strength 1. A zero-initialized `StandardParams` keeps
literal zeros; use the named default when you want those defaults.

Base RGBA, metallic and roughness are in [0, 1]. Emissive RGB and strength are
finite and nonnegative; values above 1 preserve HDR emission. The renderer floors
perceptual roughness at 0.045 for shading while preserving the authored value.

`MaterialCommon` controls alpha and sidedness. Standard supports `OPAQUE` and
`MASK`, using base alpha and `alpha_cutoff` for the mask. Double-sided Standard
flips its shading normal on back faces. Resolving Standard `BLEND` returns
`c3d::UNSUPPORTED`.

## Shared edits

```c3
MaterialAsset* record = assets.material(material_id);
record.data.standard.roughness = 0.8f;
assets.mark_material_dirty(material_id);
```

Every mesh using the id sees the edit. Finish edits before scene preparation or
view recording; advance the revision once after changing values. An unchanged
GUI frame leaves the revision alone. The GUI material panel selects the active
material family before reading its parameters.

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
`ambient_color * ambient_intensity * base_color.rgb * (1 - metallic)`.
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

The static grid shares one sphere geometry and uses 49 distinct materials.
Columns increase metallic from 0 to 1; rows increase roughness from 0.05 to 1,
bottom to top. Alternating columns use receiver layers 1 and 2. Select a sphere
in Scene to edit its factors, or select a light to edit color, intensity, range,
cone angles and receiver layers. Scene supplies node visibility, layers and
transform controls. Reset grid factors restores only the sphere factors.

Controls supplies ambient, camera layer visibility and orthographic projection.
Drag outside GUI windows to orbit, scroll to zoom, and release Escape outside
GUI keyboard capture to close. Orthographic view height has a separate control.
GPU timings are optional; full validation is enabled for every run.

## Current rendering limits

Standard currently uses scalar factors and geometry normals. It has no texture
maps or normal mapping. Basic's texture path is described in
[Textures and images](textures.md). There are no shadows, environment lighting,
or ambient specular reflections. Shading writes scene-linear HDR into the
renderer target; the existing composite adds no tonemapper or exposure control,
so bright values can clip on presentation. Compare lighting with consistent
presentation settings.
