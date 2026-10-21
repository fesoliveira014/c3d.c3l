# Transparency

How c3d draws surfaces that let the scene show through: alpha blending, additive blending, weighted blended transparency
and Physical transmission. A material chooses its alpha mode and blend mode
([Materials](materials.md#alpha-blending-and-depth-state)); a view chooses how blended surfaces compose with
`ViewDesc.transparency` and `ViewDesc.transmission_layers`.

## Choose a technique

| Technique | Material setting | Ordering | Use it for |
| --- | --- | --- | --- |
| Cutout | `AlphaMode.MASK` | None; depth tested and written | Foliage, fences, wire meshes |
| Sorted blend | `AlphaMode.BLEND`, `PREMULTIPLIED_ALPHA` | Per object, back to front | Few, separate translucent objects |
| Weighted blend | Same material, view with `TransparencyMode.WEIGHTED` | None | Overlapping or intersecting translucent surfaces, particles |
| Additive blend | `AlphaMode.BLEND`, `BlendMode.ADDITIVE` | Sorted with the other blended draws; the result does not depend on the order | Sparks, glows, light shafts |
| Transmission | Physical material with `transmission` above 0 | Back to front in the scene-read list | Glass and liquids that refract the opaque scene |

## Sorted blending

A `SORTED` view, the default, draws blended objects back to front after the opaque and masked objects and the sky. The
order uses each object's world-bounds center in the current camera view, with a stable entity-id tie break. The renderer
orders per view, so record each view with its own camera.

- A blended instanced batch orders its instances by their own box centers ([Instancing](instancing.md#blended-batches)).
  The batch orders among other blended objects by its bound center.
- The renderer does not sort triangles or fragments. Intersecting transparent geometry and large objects whose centers
  do not match their visible depth can compose incorrectly. [Weighted transparency](#weighted-transparency) removes the
  dependence on order.
- `BLEND` honors `depth_test` and never writes depth. The authored `depth_write` value stays stored, so switching the
  material back to `OPAQUE` or `MASK` restores it.
- A blended mesh casts no atlas shadow unless [colored shadows](shadows.md#colored-shadows) are on; then it casts a
  tinted one. Standard, Physical and Toon blended meshes still receive direct shadows when `Mesh.receive_shadow` is set.
  Basic stays unlit.

## Additive blending

An `ADDITIVE` surface adds `C * a` to the destination color and leaves the destination alpha. Texture, vertex and
material alpha scale the brightness and do not darken what lies behind. HDR output can exceed 1. Additive surfaces keep
the ordinary blended routing, per-view instance sorting and depth rules above.

Fog attenuates an additive surface and adds no in-scatter. Custom stages apply `apply_material_fog` from `fog.glsl` with
their packed material flags ([Custom shaders](custom_shaders.md#additive-output-and-fog)).

## Weighted transparency

`ViewDesc.transparency = TransparencyMode.WEIGHTED` composes the view's `PREMULTIPLIED_ALPHA` blended draws without
ordering them. Intersecting surfaces, interleaved surfaces and a mesh passing between two instances of a blended batch
compose without ordering errors. The result is an approximation: coverage is exact (`1 - Π(1 - a)`), and colors are a
weighted average. The weight falls with view-space depth, after McGuire and Bavoil, "Weighted Blended Order-Independent
Transparency" (2013), so a nearer surface dominates only through that weight, and two surfaces of similar weight blend
evenly whichever is in front.

```c3
import c3d;
import c3d::render;

ViewDesc desc = render::default_view_desc();
desc.transparency = TransparencyMode.WEIGHTED;
ViewId view = render::create_view(&renderer, desc)!;
```

### Participants

In a `WEIGHTED` view these draws take part:

- Basic, Standard, Physical (without transmission) and Toon `BLEND` meshes with `PREMULTIPLIED_ALPHA`.
- Blended instanced batches and the blended parts of a [LOD group](lod.md).
- [Billboard batches](billboards.md) and [ribbon batches](ribbons.md), which are always blended, with a built-in
  material.
- Custom `BLEND` stages with `PREMULTIPLIED_ALPHA`, including billboard and ribbon batches with a custom fragment and
  [particle](particles.md) effects, when the shader supplies the weighted form the view needs
  ([Custom shaders](custom_shaders_reference.md#weighted-form)).

These draws do not take part:

- `ADDITIVE` draws record after the composite, in `hdr_color`, with the state and order of a `SORTED` view. Weighted
  surfaces in front of them do not dim them.
- Transmissive Physical draws and custom scene readers stay in the sorted scene-read list in both modes, drawn before
  any weighted surface. A blended draw that reads the scene sees it without any blended surface.
- Custom `BLEND` materials whose shader lacks the weighted form the view needs stay on the sorted path, after the
  composite.

A `WEIGHTED` view with no participating draw records the commands of a `SORTED` one and allocates nothing.

### Passes

After the scene-read list and the fog pass, a `WEIGHTED` view with at least one participating draw records:

1. `Pass.FORWARD_TRANSPARENT` accumulates into two view-owned images: the weighted color with its coverage, and the
   uncovered fraction. Depth is tested against the opaque depth and not written, so a surface behind opaque geometry is
   hidden, and a material with `depth_test` off still draws over everything.
2. `Pass.TRANSPARENT_COMPOSITE` is one fullscreen pass that blends the average accumulated color over `hdr_color`,
   weighted by the covered fraction.
3. Sorted blended draws, `ADDITIVE` among them, record into `hdr_color` as in a `SORTED` view.

Fog applies per fragment before accumulation, as in `SORTED`. Blended batches skip the per-instance sort in a `WEIGHTED`
view because order does not matter; `ADDITIVE` batches keep it ([Instancing](instancing.md#blended-batches)). `WEIGHTED`
has no capacity to overflow, so `Stats.sort_overflows` does not count its batches.

### Cost

- Two images, 10 bytes per pixel at the view's working extent. The view allocates them on the first frame with a
  participating draw, releases them with the view, drops them on a resize and re-creates them lazily. A reconfiguration
  at the same extent keeps them. Nothing allocates per frame.
- Each frame with participating draws adds one render pass and one fullscreen draw, counted in `Stats.draws`.
- A participating custom stage uses the `WEIGHTED_BLEND` form of its shader: one more compiled stage for each of the
  plain, `RT_SHADOWS` and `RT_SHADOWS` with `SCENE_TRACE_BVH` forms. `prepare_scene` and model preparation create the
  pipelines for each live `WEIGHTED` view. `SORTED` pipelines are unaffected.

### Limits

- **Color cap.** The straight HDR color of a weighted surface is clamped to 64 per channel before tone mapping and
  bloom. A glint or emissive highlight brighter than that flattens at 64. A `SORTED` view keeps the full range.
- **Saturation.** About 21 layers of full weight (coverage 1, color at the cap, view depth under about 0.3) fill the
  half-float accumulation. Past that the sum clamps, the average drifts toward the cap, and the result stays finite.
- **Faint surfaces.** A coverage under about 0.014 at a view depth of 200 or more (a smaller coverage nearer) rounds to
  zero in the color sum. It adds no reliable color but still dims what lies behind it by its coverage.
- **Custom stages.** A weighted form composes correctly only if it writes through `write_blend_output`. Nothing checks
  this at runtime.

## Physical transmission

A Physical material with `transmission` above 0 shows the opaque scene through its surface
([parameters](materials.md#physical-transmission)). The renderer draws it in the scene-read list, which transmissive
draws share with opaque and masked [custom scene readers](custom_shaders.md#scene-reads). The list renders after opaque
geometry and the sky and before ordinary blends, sorted back to front by bounds center.

- **Alpha modes.** Any alpha mode works. `OPAQUE` and `MASK` glass keeps its `depth_write` setting. With colored shadows
  off, `OPAQUE` and `MASK` glass casts opaque shadows, and `BLEND` glass follows the ordinary blend rules and casts
  none. With colored shadows on, glass of every alpha mode casts a [tinted shadow](shadows.md#colored-shadows).
- **Snapshot.** Before the list, the renderer copies the finished opaque color into the view's `scene_color` image. The
  view allocates it on first use at its working extent with a full mip chain. `Pass.SCENE_SNAPSHOT` times the copy and
  `Pass.SCENE_READ` the list.
- **Refraction.** Each fragment refracts the view direction by `1 / ior`, walks the thickness through the volume,
  projects the exit point and samples `scene_color` at
  `lod = log2(max(width, height)) * roughness * clamp(2 * ior - 2, 0, 1)`. Here `roughness` is the roughness factor
  times its map, before decals and before the lighting model's roughness floor. Roughness 0 or an `ior` of 1 samples mip
  zero.
- **Mip chain.** The chain is written only when the list holds a draw that can sample above mip zero: `transmission`
  above 0, `roughness` above 0 and `ior` above 1. `Pass.SCENE_MIPS`, after `Pass.SCENE_SNAPSHOT`, times one fullscreen
  pass per level, each a 2x2 box filter of the level above that counts one `Stats.draws`. Other frames record nothing
  extra. The chain adds a third of the `scene_color` size to the view's memory, plus a sampled view per level and an
  attachment view per level below the first. The box filter has no wider kernel, so strong blur steps visibly between
  levels on high-contrast content. Custom readers sample mip zero.
- **Off-screen exit.** An exit point outside the screen falls back to the environment's specular cube along the
  refracted direction, or to black without an environment.
- **Composition.** The transmitted radiance replaces the dielectric diffuse response by the transmission factor, is
  scaled by the base color and the non-metallic fraction, and is weighted by the surface's own Fresnel. Direct lights
  add a mirrored-light transmission lobe.

Draws of one layer never see each other, the custom readers of the same list or ordinary blends. By default all draws
share one layer, so glass behind glass shows the opaque scene through both. Transmission layers let a front pane see the
glass behind it.

### Transmission layers

`ViewDesc.transmission_layers` sets how many snapshots the scene-read list samples, from 1 to `MAX_TRANSMISSION_LAYERS`
(4). Zero reads as 1, so a zero-initialized desc keeps the default output. A value above 4 faults `INVALID_ARGUMENT` in
`create_view` and `configure_view`.

Above 1, the renderer walks the scene-read list back to front and gives each draw a layer from the screen rectangle of
its world bounds:

```
layer(d) = min(layers - 1, 1 + max(layer(e)))   over earlier draws e whose rectangle overlaps d's
layer(d) = 0                                    when none overlaps
```

Rectangles that only touch do not overlap. A bound with any corner at or behind the near plane covers the whole screen,
so every later draw overlaps it. The rule compares bounding rectangles, not silhouettes, and can place two panes in
separate layers where their shapes do not touch.

Layers record in order, back to front inside each. Before every non-empty layer the renderer copies `hdr_color` into
`scene_color` again, and regenerates its mips when that layer holds a draw that can sample above mip zero. A draw in
layer n sees the opaque scene and the glass of layers below n. Custom color readers in the list are layered the same
way. At the default of 1 the renderer projects no rectangle, reorders no draw and records the commands of a single
snapshot.

Cost, per non-empty layer past the first:

- one `scene_color` copy, counted in `Stats.scene_snapshots` and `Stats.draws`;
- one mip chain when the layer needs it;
- on a view with fog or an atmosphere, one `scene_depth` copy, because a color snapshot always brings its depth;
- assignment cost that grows with the square of the scene-read draws, paid only above 1.

Limits:

- Deeper overlaps than the setting share the last layer and do not see each other. No draw is dropped.
- On a view with fog or an atmosphere, a front pane fogs only the gap to the depth-writing pane behind it, because
  `scene_depth` is re-copied with each color snapshot. `BLEND` glass in an earlier layer writes no depth, so a pane in
  front of it fogs its refracted sample to the opaque depth behind the `BLEND` glass.
- Ordinary blends are not in the scene-read list and draw over glass in every setting.

## Limits

- Sorting works per object, not per triangle or fragment.
- Weighted transparency covers `PREMULTIPLIED_ALPHA` draws only. Additive draws and scene readers keep the sorted path.
- Transmission shows the opaque scene and, with layers, other glass. It never shows ordinary blends.

Run `python3 scripts/build.py --example transparency` for a view that switches between these techniques.

## See also

- [Materials](materials.md) and [Materials reference](materials_reference.md) for alpha mode, blend mode and Physical
  transmission parameters.
- [Custom shaders](custom_shaders.md) for scene reads and the weighted form of a custom stage.
- [Shadows](shadows.md#colored-shadows) for tinted shadows from translucent casters.
- [Instancing](instancing.md#blended-batches) for blended batches.
