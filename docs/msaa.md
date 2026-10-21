# Multisample anti-aliasing

`ViewDesc.msaa` selects 1, 2, 4 or 8 samples per pixel for the opaque scene passes of a `FORWARD` or `DEFERRED`
view. It antialiases silhouettes, seams and creases between opaque surfaces. Every later pass reads single-sample
images. The setting belongs to the view (`c3d::render`); see [views](views.md) for how views are created and
configured.

## Quick start

```c3
ViewDesc desc = render::default_view_desc();
desc.msaa = MsaaSamples.FOUR;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

`MsaaSamples` is `ONE`, `TWO`, `FOUR` or `EIGHT`. `ONE`, the zero value and the value of both view constructors, is
off: the view allocates and records exactly what a view without the field does. Run
`python3 scripts/build.py --example deferred` and press `M` (or pass `--msaa <1|2|4|8>`) to cycle both halves
through the counts.

## Concepts

- **What is multisampled.** The depth prepass, the opaque forward pass and the sky draw into multisample twins of
  `hdr_color` and `depth`, then resolve. Color resolves to the average of the samples and depth to sample 0.
  Toon outlines and installed impostors draw in the multisample pass too.
- **Shading rate.** A fragment shades once per pixel and primitive, and the covered samples share its color. The
  sample count does not multiply shading cost. A `MASK` material's alpha test also runs once, so cut-out edges are
  not antialiased, and there is no alpha-to-coverage.
- **Shading position.** Lighting and traced shadow rays use a position interpolated at the pixel's centroid
  (`v_shading_pos`), which lies inside the triangle. Every other term interpolates at the pixel centre.
- **Later passes.** Clouds, fog and aerial perspective, scene-read and transmission draws, weighted and sorted
  transparency, exposure, debug lines, motion blur, depth of field, bloom, grading, FXAA and the output read
  single-sample images. An MSAA view takes the split a fogged view takes: blended draws and scene readers draw
  after the resolve, single-sample, against the resolved `depth`. A blended or scene-reading surface that meets an
  opaque silhouette can show a slight fringe where the resolved color and the sample-0 depth disagree.
- **Velocity.** Velocity is not averaged. Camera velocity runs at the view's count from the resolved `depth`, moved
  opaque items redraw at the view's count, and sample 0 of the result fills `velocity`. The scene-read draws that move
  and write depth are single-sample, so they redraw last into `velocity`.
- **Effects that read depth.** Ambient occlusion, screen-space GI and traced reflections read the resolved depth
  and the sample-0 surface (the thin reflection surface on a forward view, sample-0 copies of the G-buffer channels
  on a deferred view). Ray-traced ambient occlusion also reads sample 0 of the proxy skip word.

## Deferred views

A `DEFERRED` view keeps its G-buffer at the view's count and lights a pixel once where all its samples come from one
surface, and once per sample where they do not.

- **Edge pixels.** A pixel is an edge when any sample differs from sample 0 in depth by more than a small fraction
  of the larger reverse-Z depth, in the layer mask or flag bits at all, or in a color, normal, roughness,
  occlusion, emissive or specular channel by more than a small tolerance. A seam between a shadow receiver and a
  non-receiver is an edge because the receive-shadow bit differs.
- **Lighting.** Non-edge pixels light once from sample 0 and the result reaches every covered sample. Edge pixels
  shade each sample in its own invocation (sample-rate shading), reading that sample of the G-buffer and the depth.
  A sample with no geometry keeps the clear color. The layer mask and the receive-shadow bit are never averaged, so
  a sample at an edge takes the shadow decision of the surface it covers.
- **Cost.** The G-buffer writes and the edge classification scale with the sample count on every pixel. Lighting
  scales with it only on edge pixels.
- **Shadows.** A traced shadow is cast once per pixel away from edges and once per sample at edges. A shadow edge
  inside one triangle is shaded once per pixel and is not antialiased by the samples, as on a forward view.
- **Previews.** A preview of a multisample G-buffer channel shows sample 0.

## Combinations

| With `msaa` above `ONE` | Behavior |
| --- | --- |
| `TAA` | Faults `c3d::INVALID_ARGUMENT` |
| `PATH_TRACED` | Faults `c3d::INVALID_ARGUMENT` |
| `DEFERRED` | Faults `c3d::UNSUPPORTED` without sample-rate shading |
| A count a multisample image cannot be created at | Faults `c3d::UNSUPPORTED`; adapters differ in the counts they accept |
| `FXAA`, `NONE` | Allowed; FXAA filters the resolved image |
| Motion blur, screen-space GI | Velocity from sample 0 |
| Ambient occlusion, screen-space GI, traced reflections | Read the resolved depth and sample 0, as above |
| Traced shadows | Evaluated per fragment on a forward view; per pixel, and per sample at edges, on a deferred view |
| Depth of field, auto focus, bloom, grading, LUT, auto exposure | Read the resolved images |
| Decals | Applied in the receiving draw's stage, as without MSAA |
| Installed impostors | Draw in the multisample pass; their alpha cut is not antialiased |
| `render_scale`, `clip_plane`, mirror views, `share_shadows`, clustered lights, instance culling, LOD | Allowed |
| Shadow maps, overlays, reflection captures, probe updates, `bake_impostor` | Single-sample |

`create_view` and `configure_view` check every image the view needs at the working extent; a fault changes nothing.
Changing `msaa`, velocity use, traced reflections or the ambient occlusion kind reallocates only the multisample
images.

## Memory

Bytes per working pixel at `N` samples. `ViewStats.images` counts the images; the full per-setting image list is in
[views reference](views_reference.md#images-per-setting).

| Image | Bytes per pixel |
| --- | --- |
| `msaa_color`, `msaa_depth` | `12 * N` (8 and 4) |
| `msaa_velocity` | `4 * N` with motion blur alone, `8 * N` with screen-space GI, temporal ambient occlusion or reflection history |
| `msaa_reflection_gbuffer` | `8 * N`, on a forward view with traced reflections |
| `msaa_proxy_skip` | `4 * N`, on a forward view with ray-traced ambient occlusion |
| G-buffer, deferred | `28 * N`, in place of the 28 of a single-sample G-buffer |
| `normal_sample_zero`, `specular_sample_zero` | 8 each, single-sample |
| `proxy_skip`, `flags_sample_zero` | 4 each, single-sample |
| `msaa_edges`, deferred | 1, single-sample |

The single-sample images keep their formats and usages and are the resolve and copy targets. The multisample
`msaa_color` and a forward view's `msaa_depth` are attachment-only and hold no heap slot.

## Limits

- Antialiasing covers silhouettes, seams and creases. Shading detail inside a triangle (texture, normal map,
  shadow edge) is shaded once per pixel and is not antialiased.
- `MASK` cut-outs are not antialiased.
- TAA and path tracing exclude MSAA. Use FXAA with MSAA when an extra filter pass is wanted.

## See also

- [Views](views.md) and [views reference](views_reference.md) for `ViewDesc`, faults and capacities.
- [Shading paths](shading_paths.md) for forward and deferred views.
- [Post-processing](post.md) for FXAA, TAA and the passes after the resolve.
