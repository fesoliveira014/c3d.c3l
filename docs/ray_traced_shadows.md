# Ray-traced shadows

A light can resolve its shadow with rays instead of atlas layers: one ray per shaded pixel toward the light, or
several toward a light with a size, which gives a soft penumbra. Ray-traced shadows ignore `bias` and the
normal-offset settings and need no atlas layers. They use hardware ray queries when the renderer was created with
`RendererDesc.ray_queries` or `ray_tracing_pipelines`, and the software walk of [scene tracing](scene_trace.md)
otherwise. The switches are `ShadowSettings.ray_traced` and `Light.source_radius` / `source_angle` (`c3d::light`) and
`ViewDesc.ray_tracing` (`c3d::render`). The atlas path is described in [shadows](shadows.md).

## Quick start

Import `c3d::light`, `c3d::render` and `c3d::scene`.

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_queries = true })!;

Light sun = light::directional({ 1, 1, 1 }, 3);
sun.shadow.ray_traced = true;
Node* sun_node = scene.add_light(sun)!;

ViewDesc desc = render::default_view_desc();
desc.ray_tracing.shadows = true;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

Run `python3 scripts/build.py --example rt_shadows`. `--software` creates the renderer without ray queries. The
example's panels set the light's source extent and the shadow samples, and swap between traced shadows and the atlas.

## Concepts

- **When a light traces.** A light traces when `shadow.enabled`, `shadow.ray_traced` and the view's
  `ray_tracing.shadows` are all set. Every other light keeps the atlas, so one view can mix both. A traced light holds
  no atlas layer in that view.
- **Ray queries and the software walk.** `RendererDesc.ray_queries` requests ray queries, and
  `RendererDesc.ray_tracing_pipelines` enables them too. With no adapter that supports them, `create_renderer` faults
  `c3d::UNSUPPORTED`. A renderer created with neither traces through the software walk, which costs substantially more
  per ray; see [benchmarking](benchmarking.md#traced-effects-in-software-and-on-ray-queries).
- **Ray origin.** The ray starts `TRACE_SURFACE_OFFSET` (0.02 world units, shared with every traced effect) along the
  receiver's normal. The offset hides self-intersection at the cost of a small gap where a caster meets its receiver.
  On a forward view with `msaa` above `ONE`, the built-in forward stages take the receiver's position at the pixel's
  centroid (`v_shading_pos`, [custom shaders](custom_shaders.md#shading-position-varying)), because the pixel centre
  can lie outside the triangle and a ray started there can begin below a neighbouring surface. A fragment stage may
  raise the `trace_proxy_skip_height` global ([custom shaders](custom_shaders.md)) so that hits on a
  [trace proxy](scene_trace.md#trace-proxies) near the surface are ignored; terrain does.
- **Ray length.** `bias`, the normal offsets and `max_distance` do not apply. Directional rays stop at `RT_SHADOW_FAR`
  (10,000 world units) and punctual rays at the light.
- **Casters.** Casters are the traced scene (see [what traces](scene_trace.md#what-traces)). `cast_shadow = false` keeps
  a mesh out of shadow rays, `MASK` materials cast their alpha-tested coverage, and off-camera objects cast like any
  other. A single-sided caster casts where its front faces the light, as in the atlas; a double-sided one casts from
  both faces ([facing](scene_trace.md#facing)). Skinned and morphed meshes cast at their raster pose, crowd placements
  cast only through `add_crowd(trace: true)`, and custom vertex stages and `BLEND` meshes do not cast.
- **Hard by default.** A light with no source extent casts a hard shadow: one ray to its centre. A source extent
  softens the edge.

## Enable ray-traced shadows

1. Create the renderer with `ray_queries = true` (or `ray_tracing_pipelines = true`) for hardware tracing, or leave
   both off for the software walk.
2. Set `shadow.ray_traced = true` on each light that should trace, with `shadow.enabled` on.
3. Set `ViewDesc.ray_tracing.shadows = true` on each view that should trace, between frames.

The shadow-set key includes `ray_tracing.shadows`, so views that differ in it do not share a set
([shadow sets](shadows.md#shadow-sets)).

## Soft shadows

```c3
sun.source_angle = 0.02f;
lamp.source_radius = 0.3f;
desc.ray_tracing.shadow_samples = 8;
```

- **Source extent.** `Light.source_radius` (metres; point and spot lights) and `Light.source_angle` (half-angle in
  radians; directional lights) give the light a size. Both are zero by default, which keeps the hard shadow. A value is
  finite and not negative, and an angle is below `PI / 2`. `extract_lights` checks this contract for every light with
  shadows enabled, and the serialization add-on reads an invalid value as `c3d::INVALID_ARGUMENT`.
- **Samples.** `ViewDesc.ray_tracing.shadow_samples` is the number of rays a pixel casts toward a light that has an
  extent: 1 to `MAX_SHADOW_SAMPLES` (16), where zero reads as 1. A larger value faults `c3d::INVALID_ARGUMENT` in
  `create_view` and `configure_view`. A light without an extent casts one ray whatever the count.
- **Rays.** The rays go to points spread uniformly over the source as the surface sees it: a cone of the half-angle
  around the sun's direction, or the disc of the radius that faces the surface at a point or spot light. The shadow is
  the share of rays that arrive. Each pixel starts its pattern from interleaved gradient noise, and on a TAA view the
  pattern changes every frame.
- **Forms.** The built-in fragment stages (Standard, Physical, Toon, impostors and the deferred lighting resolve) have
  a hard-only form and a soft form. A view draws the hard-only form unless a light it traces has an extent: shadows
  enabled, ray traced, a visible node and `source_radius` or `source_angle` above zero. A scene without extents
  creates no soft pipelines. Adding or removing such a light changes the form from the next frame, and
  `prepare_scene` builds the form its scene needs. `prepare_model` has no scene and builds the hard-only form.
- **Noise.** One ray per pixel draws the penumbra as a dither of lit and shadowed pixels, `N` rays as `N + 1` steps of
  grey with a smaller dither. TAA averages the frames of the pattern; without it, raise the count. The cost is the
  count in traced queries for each shadowed pixel and each light with an extent.
- **Other consumers.** [Volumetric fog](fog.md#volumetric-fog), the hits of [traced reflections](reflections.md) and
  [probe updates](probe_volumes.md) cast one ray toward a point of the source, which their averaging smooths. The
  [path tracer](path_tracing.md) takes one point of the source at each bounce and converges with its accumulated
  samples; `shadow_samples` does not apply to it.
- **Atlas shadows** stay hard. They do not read the extent, and a light with one that a view does not trace shows the
  atlas's hard edge.
- **The sun's disc.** `Atmosphere.sun_angular_radius` sizes the sun in the sky and is independent of `source_angle`.
  Set both from one value when the shadow should match the disc.

## Custom shaders

- Custom forward stages receive traced shadows through `ShaderDesc.traced_fragment`: a form compiled with `RT_SHADOWS`
  for renderers with ray queries, and one with `RT_SHADOWS` and `SCENE_TRACE_BVH` for the software walk
  ([custom shaders](custom_shaders.md#traced-shadows)). Without the form the view draws the plain stage, which a
  traced light reaches with `shadow_count == 0`: lit, without that shadow.
- Custom G-buffer stages are shadowed by the lighting resolve.
- A custom stage that calls `shadow_visibility`, `shadow_transmittance` or `ray_shadow_visibility` inherits the soft
  path: a fragment stage casts the view's sample count and any other stage casts one ray. A custom traced form carries
  the soft path on every view; defining `RT_SHADOWS_HARD` in it drops the path.

## Reference

| Setting | Where | Default | Meaning |
| --- | --- | --- | --- |
| `ray_queries`, `ray_tracing_pipelines` | `RendererDesc` | false | Request hardware ray queries (pipelines enable them too); fault `c3d::UNSUPPORTED` without an adapter that supports them |
| `shadow.ray_traced` | `Light` | false | The light traces in views that enable traced shadows |
| `ray_tracing.shadows` | `ViewDesc` | false | The view traces the lights that ask to |
| `ray_tracing.shadow_samples` | `ViewDesc` | 0 (reads 1) | Rays per pixel toward a light with an extent, 1 to 16 |
| `source_radius` | `Light` | 0 | Point and spot light source radius in metres |
| `source_angle` | `Light` | 0 | Directional light source half-angle in radians, below `PI / 2` |

## Limits

- Traced shadows see the traced scene only: `BLEND` meshes and custom vertex stages do not cast, crowds cast only with
  `add_crowd(trace: true)`.
- `shadow_samples` applies to forward fragment stages and the deferred resolve; fog, reflection hits and probe updates
  cast one ray, and the path tracer one point per bounce.
- The software walk costs substantially more per ray than ray queries.
- Colored shadows do not affect traced shadows: `OPAQUE` and `MASK` glass cast opaque shadows and `BLEND` casts nothing.
- A `PATH_TRACED` view rejects `ray_tracing.shadows` with `c3d::INVALID_ARGUMENT`; the path tracer samples lights
  itself.

## See also

- [Shadows](shadows.md) for atlas shadows, shadow sets and colored shadows.
- [Scene tracing](scene_trace.md) for what traces and the software walk.
- [Lights](lights.md) for light selection and receiver masks.
- [Custom shaders](custom_shaders.md#traced-shadows) for `traced_fragment`.
