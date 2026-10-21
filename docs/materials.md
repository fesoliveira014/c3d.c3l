# Materials

A material describes how a mesh surface looks and how it draws: its color, how light shades it, and its alpha, depth and
raster state. Materials are asset-store records (`c3d::asset`) built with the constructors of `c3d::material`. Meshes
refer to them by `MaterialId`.

| Family | Shading | Constructor |
| --- | --- | --- |
| Basic | Unlit color with an optional base map | `material::basic` |
| Standard | Metallic-roughness shading with direct lights, scene ambient, environment lighting and five texture maps | `material::standard` |
| Toon | Banded direct diffuse, smooth indirect fill, optional rim and outline | `material::toon` |
| Physical | The Standard surface plus clearcoat, sheen, specular and IOR, anisotropy and transmission | `material::physical` |
| Custom | User SPIR-V ([Custom shaders](custom_shaders.md)) | `material::custom` |

All parameters, defaults and ranges are in the [Materials reference](materials_reference.md).

## Quick start

```c3
import c3d::asset;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::scene;

StandardParams params = material::STANDARD_PARAMS_DEFAULT;
params.base_color = { 0.7f, 0.25f, 0.1f, 1 };
params.metallic = 0;
params.roughness = 0.5f;
MaterialId paint = assets.add_material(material::standard(params), "demo/paint")!;

GeometryId ball;
@pool() {
    Geometry sphere = geometry::sphere(tmem, 0.6f);
    ball = assets.add_geometry(&sphere, "demo/ball")!;
};
Node* ball_node = scene.add_mesh(ball, paint, name: "ball")!;
Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 1))!;
renderer.prepare_scene(&scene)!;
```

## Concepts

- **Shared ids.** The store owns materials. Any number of meshes can use one `MaterialId`, and an edit to the record
  shows on all of them. A mesh switches material by assigning another id to `Mesh.material`.
- **Factors, maps and common state.** Each family has constant factors (color, metallic, roughness, ...) and texture
  slots that multiply them. `MaterialCommon` carries the alpha mode, blend mode, cutoff, sidedness, depth test and
  write, and wireframe flag for every family.
- **Defaults.** Start from the family's `*_PARAMS_DEFAULT` constant. A zero-initialized params struct keeps literal
  zeros.
- **Color space.** Factors are scene-linear. The color space of a map belongs to its texture asset
  ([Textures](textures.md)); the renderer does not infer it from the slot.
- **Vertex colors.** A geometry with per-vertex colors multiplies them into the base color of every built-in family,
  after the factor and map and before alpha masking and lighting. A masked material also applies the vertex alpha in the
  shadow pass. Custom shaders read `v_color` themselves.
- **Contracts.** Constructors reject out-of-range values as programming errors. They do not return faults.

## Create a material

### Basic

```c3
Material flat = material::basic({ .color = { 0.9f, 0.2f, 0.2f, 1 } });
```

`BASIC_PARAMS_DEFAULT` is white with no base map and an identity map transform. Start from it when you change selected
factors or switch a material to Basic.

### Standard

The Quick start shows the Standard factors. `STANDARD_PARAMS_DEFAULT` gives white base color, metallic 1, roughness 1,
black emissive with strength 1, normal scale 1, occlusion strength 1 and five absent maps with identity transforms.
Emissive values above 1 keep HDR emission.

### Toon

```c3
ToonParams toon = material::TOON_PARAMS_DEFAULT;
toon.color = { 0.25f, 0.8f, 1, 1 };
toon.steps = 4;
toon.rim_color = { 1, 1, 1 };
toon.rim_strength = 0.4f;
toon.rim_power = 2;
MaterialId toon_id = assets.add_material(material::toon(toon))!;
```

Toon quantizes the normal-light cosine separately for each directional, point or spot light into `steps` bands. Light
intensity, attenuation and shadow visibility, scene ambient and the environment's diffuse fill stay smooth. Toon has no
specular environment reflection and no normal-map slot. `gradient_map` replaces uniform steps with an intensity ramp
texture; load the ramp as linear data. The rim adds a view-dependent edge term that ignores lights and shadows. Ranges
and the ramp rules are in the [reference](materials_reference.md#toon).

#### Toon outline

```c3
toon.outline_width = 3;           // pixels of the view's image; 0 draws no outline
toon.outline_color = { 0, 0, 0 }; // linear
toon.outline_depth_offset = 0;    // view-space units
```

An inverted hull draws the outline: the renderer draws the mesh a second time right after itself, with front faces
culled and each vertex moved along its normal in clip space. The width is constant on screen whatever the distance or
object scale. The hull is flat `outline_color`, exposed with the rest of the view and cut out by the same coverage as
the surface under `MASK`. `outline_depth_offset` pushes the hull away from the eye, which hides it where it intersects
other geometry. A width of 0, the default, adds no draw and no pipeline.

- **Draws.** `OPAQUE` and `MASK` Toon meshes, batches and crowds that test and write depth outline, in every vertex form
  (static, skinned, morphed, instanced and posed). `BLEND`, `WEIGHTED`, billboards, impostors and non-triangle meshes
  ignore `outline_width`. Under `MASK` the far side of the hull shows through the cutouts of the near side.
- **Passes.** Forward views draw the hull in `Pass.FORWARD_OPAQUE`. Deferred views draw it in the forward draws after
  the lighting resolve. Shadow layers, the depth prepass and the G-buffer pass skip it, and it is not part of the trace
  structures, so ray-traced effects and the path tracer do not see outlines.
- **Motion.** Under TAA, motion blur or screen-space GI, a moved outlined draw redraws its hull in the velocity pass, so
  a moving outline does not trail.
- **Counts.** The hull is a second draw: `Stats.draws` and `Stats.triangles` count it.
- **Geometry.** A mesh with hard edges has split vertices that each move along their own face normal, so its outline
  opens at those edges. Smooth normals keep it continuous. An open surface has no back faces to extrude and shows no
  outline from the front.

### Physical

`material::physical` embeds a complete Standard surface in `PhysicalParams.standard` and layers extra lobes over it.
`PHYSICAL_PARAMS_DEFAULT` embeds `STANDARD_PARAMS_DEFAULT` with every layer off, so it shades like the Standard surface
until you set a layer.

#### Physical clearcoat and sheen

```c3
PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
params.standard.base_color = { 0.12f, 0.3f, 0.7f, 1 };
params.standard.metallic = 0.1f;
params.standard.roughness = 0.45f;
params.clearcoat = 0.8f;
params.clearcoat_roughness = 0.2f;
params.sheen_color = { 0.3f, 0.08f, 0.12f };
params.sheen_roughness = 0.65f;
MaterialId coated = assets.add_material(material::physical(params))!;
```

Clearcoat adds a glossy dielectric layer with its own roughness and optional normal map. Sheen adds a soft fabric lobe.
Both read the same [reflection probes](reflection_probes.md) and the global environment as the base layer
([Environments](environments.md)). Composition rules are in the [reference](materials_reference.md#composition-rules).

#### Physical specular and IOR

```c3
params.ior = 2.4f;
params.specular = 0.8f;
params.specular_color = { 1, 0.6f, 0.2f };
```

`ior` sets the dielectric reflectance, `specular` weights it and `specular_color` tints it. The defaults reproduce the
Standard reflectance of 0.04.

#### Physical anisotropy

```c3
params.standard.metallic = 1;
params.standard.roughness = 0.35f;
params.anisotropy = 0.8f;
params.anisotropy_rotation = (float)math::PI / 4;
```

Anisotropy stretches the specular lobe along a tangent-space direction, as on brushed metal. The direction uses the
frame of the normal map ([Tangent frames](materials_reference.md#tangent-frames)). Clearcoat and sheen stay isotropic.

#### Physical transmission

```c3
params.standard.metallic = 0;
params.standard.roughness = 0.05f;
params.ior = 1.5f;
params.transmission = 1;
params.thickness = 1;
params.attenuation_distance = 1;
params.attenuation_color = { 0.9f, 0.5f, 0.3f };
```

Transmission shows the opaque scene through the surface. `thickness` is an object-space distance and `attenuation_color`
tints radiance over `attenuation_distance`. A transmissive draw joins the scene-read list, refracts a snapshot of the
opaque color and, by default, never sees other glass. The view setting `transmission_layers` lets a front pane see the
glass behind it. [Transparency](transparency.md#physical-transmission) describes the rendering, the cost and the layer
rules.

## Standard maps

Each slot is a `TextureSlot` with its own texture, sampler, UV set (0 or 1) and scale, rotation and offset. Slots can
share one `TextureId` while using different coordinates and samplers.

```c3
params.base_color_map = material::texture_slot(base_color_texture);
params.metallic_roughness_map = material::texture_slot(material_data_texture);
params.occlusion_map = material::texture_slot(material_data_texture, uv_set: 1);
params.normal_map = material::texture_slot(normal_texture);
params.emissive_map = material::texture_slot(emissive_texture);
```

The channels each slot reads and the color space to load it in are in the [reference](materials_reference.md#standard).
Physical adds ten more slots for its layers ([Physical](materials_reference.md#physical)).

- Basic has one base map (`BasicParams.map`). Toon has a base map (`ToonParams.map`) and a gradient ramp
  (`gradient_map`, a `TextureId`).
- A zero or stale texture id makes the slot absent. Absent maps keep the scalar factor, and an absent normal map keeps
  the geometry normal.
- Normal encoding belongs to the texture asset (`TextureDesc.semantic`), not the slot.
- A built-in slot can reference a render target: set `slot.texture` to `{ .kind = RENDER_TARGET, .target = id }`. A
  custom material slot can take a texture the drawing view supplies: set `slot.texture` to
  `{ .kind = VIEW, .view_slot = n }` ([Custom shaders](custom_shaders.md#view-provided-slots)).
- Without a tangent stream, filled triangles derive the normal-map frame from UV derivatives. Supply tangents, or
  generate them with `geometry::create_tangent_geometry`, for an authored basis
  ([Tangent frames](materials_reference.md#tangent-frames)).

## Alpha, blending and depth state

`MaterialCommon` sets the state for every family.

```c3
MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
common.alpha_mode = AlphaMode.BLEND;
common.blend_mode = BlendMode.ADDITIVE;
Material sparks = material::basic({ .color = { 1, 0.5f, 0.2f, 0.25f } }, common);
```

| `alpha_mode` | Use it for | Notes |
| --- | --- | --- |
| `OPAQUE` | Solid surfaces | Ignores coverage |
| `MASK` | Cutouts | Discards below `alpha_cutoff` (default 0.5); the shadow pass uses the same coverage |
| `BLEND` | Translucent surfaces | Premultiplied output; `blend_mode` selects `PREMULTIPLIED_ALPHA` (source-over) or `ADDITIVE` |

- `BLEND` honors `depth_test` and never writes depth. The authored `depth_write` stays stored, so switching back to
  `OPAQUE` or `MASK` restores it.
- Double-sided Standard, Physical and Toon flip their shading normal on back faces.
- `wireframe` falls back to filled triangles on a device without line polygon mode.
- Opaque and masked Basic, Standard, Physical and Toon meshes cast shadows. Masked coverage comes from the base factor,
  base texture and cutoff.

How blended surfaces order, compose and cast shadows is in [Transparency](transparency.md).

## Edit a shared material

```c3
MaterialAsset* record = assets.material(material_id);
record.data.standard.roughness = 0.8f;
assets.mark_material_dirty(material_id);
```

Every mesh using the id sees the edit. Finish edits before scene preparation or view recording and advance the revision
once after changing values.

- Texture pixel, backing and sampler revisions are tracked independently for every slot. Editing and marking a texture
  or sampler dirty does not need a material dirty call. Changing a slot itself does.
- A removed or stale texture generation uses the absent-map behavior. It never binds a new asset that reuses the index.
- Prepare or upload resources before releasing CPU sources, and keep edits and releases outside the interval from
  preparation through submission ([Textures](textures.md#upload-edit-and-release-cpu-sources)).

### Change the family

Assign a complete `Material` and mark it dirty:

```c3
record.data = material::basic({ .color = { 1, 0.5f, 0.2f, 1 } });
assets.mark_material_dirty(material_id);
```

Use the matching `.data.basic`, `.data.standard`, `.data.physical` or `.data.toon` arm. Initialize the arm from its
named defaults before you change `kind`.

`assets.replace_material(material_id, material)` assigns a complete `Material` under the same id and key and advances
the revision once. The kind can change. A custom payload is copied and the old one freed. The call returns no fault.
Call it from the owner thread, outside frame recording. Path-traced views restart after a replacement
([Accumulation and resets](path_tracing.md#accumulation-and-resets)).

A draw can still fault at preparation or render time, as with `add_material` and `mark_material_dirty`, because a
material cannot see which geometries draw it ([faults](materials_reference.md#faults)).

## Import materials

`c3d::asset::gltf` selects Basic for unlit materials, Standard for metallic-roughness and Physical when any layer
extension is present. It validates every factor against the constructor ranges before building the material.
`c3d::asset::fbx` builds Standard materials. The mapping tables are in [Models, glTF and FBX import](models.md).

## Limits

- Basic is unlit. Toon has no PBR reflections or transmission. Toon uses only the environment's diffuse SH term.
- [Shadows](shadows.md) attenuate direct light on Standard, Physical and Toon. Standard and Physical support
  [environment lighting and independent skies](environments.md).
- Physical transmission samples the opaque scene through a 2x2 box-filtered mip chain and never sees ordinary blended
  surfaces.
- Shading writes scene-linear HDR into the view's working image. The view's output mode decides whether display
  processing tone maps it ([Views](views.md), [Post-processing](post.md)).
- Decals project only a Standard material onto Standard and Physical receivers ([Decals](decals.md)).

Run `python3 scripts/build.py --example materials` for a view that switches between the families and
`python3 scripts/build.py --example pbr` for a Standard sphere grid with editable maps.

## See also

- [Materials reference](materials_reference.md) for parameter tables, slots, tangent frames and faults.
- [Transparency](transparency.md) for blending, weighted transparency and transmission.
- [Decals](decals.md) for projected materials.
- [Lights](lights.md) for lights, receiver layers, ambient and light capacity.
- [Textures](textures.md), [Environments](environments.md), [Shadows](shadows.md).
- [Custom shaders](custom_shaders.md) for `material::custom`.
