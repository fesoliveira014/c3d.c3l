# Camera transparency

`ViewDesc.transparency` selects camera composition. It does not change a
material's alpha mode, transmission, absorption or lighting factors. The same
late transparency path follows forward and deferred opaque rendering.

## View configuration

`SORTED` is the default, including zero-initialized descriptors. It ignores
`layer_capacity` and orders objects by their camera-space bound centers. Instances
are sorted inside their batch. It does not order intersecting triangles or
fragments.

`LAYERED` retains the nearest distinct depth groups per pixel. Start from the
public default, then configure the view:

```c3
ViewDesc view_desc = render::default_view_desc();
view_desc.transparency = render::TRANSPARENCY_LAYERED_DEFAULT;
render::configure_view(&renderer, renderer.default_view, view_desc)!;
```

`TRANSPARENCY_LAYERED_DEFAULT` selects four groups. Explicit LAYERED capacities
are 1–16; zero and values above 16 return `c3d::INVALID_ARGUMENT` before the view
changes. Resource allocation faults leave the installed configuration usable.
Each view owns its resources and uses its own camera and working extent.

## Ordering and remainder

A group contains fragments with exactly equal stored reverse-Z depth. There is
no epsilon merge. Retained groups compose back to front. Coincident fragments
use scene node identity, source part/range, logical instance slot and source
primitive order as their stable tie order. Every fragment in a group reads the
same behind-group color snapshot.

Capacity exhaustion discards no surface. Fragments strictly behind the last
retained group compose through the existing SORTED path against opaque
snapshots. That remainder becomes the background for the deepest retained
group. Increasing capacity moves more depths into exact grouping; ordering
inside the farther remainder still has SORTED's limitations.

Basic, Standard, Toon and Physical BLEND surfaces participate, as do Physical
surfaces with positive transmission. Existing ordinary, instanced, mirrored,
skinned, morphed and billboard support remains family-specific. Opaque/masked
surfaces without transmission remain in the background path.

Depth-tested OPAQUE/MASK scene readers form the background before capture.
Depth-disabled scene readers and undeclared Custom BLEND surfaces draw afterward
in their existing sorted order. They preserve their opaque-depth test and scene
snapshot behavior. This fallback does not reject or change the view's mode;
its color can differ from a participating surface at the same depth.

## Custom stages

`ShaderDesc.layered_transparency` opts a Custom stage into grouping. Include
`transparency.glsl`, compile the fragment with `LAYERED` defined, and use
`layered_transparency_accept` for the actual fragment depth. Use
`layered_transparency_output` to supply capture output. Capture and shading use
the same supplied fragment program. They must
preserve coverage, discard decisions and stored depth, and every participating
vertex stage must declare `invariant gl_Position` with the same vertex output
in both phases.

The declaration is a shader authoring contract. The renderer does not prove
arbitrary SPIR-V cooperation. Rejected shader replacement retains the last-good
declaration and routing. A cooperating `scene_color_at` reads behind its group
at mip zero. Public depth helpers retain their opaque-depth meaning. See
[Custom shaders](custom_shaders.md#scene-reads).

## Rough Physical transmission

Both modes filter scene-linear snapshots for rough Physical transmission.
SORTED builds the pyramid once per list snapshot; LAYERED rebuilds it between
retained groups. The projected exit point still comes from authored thickness,
model scale and refraction direction. Off-screen exits retain the environment
or reflection-probe fallback.

For mapped roughness `rho` before the shading roughness floor, the LOD is:

```
min(last_mip, log2(max(width, height)) * rho * clamp(2 * ior - 2, 0, 1))
```

The scene-linear pyramid uses area-box averages, including odd image extents.
Fractional LOD interpolates adjacent levels with linear filtering. Roughness
zero takes the existing mip-zero branch and stays bit-identical. The shading
roughness floor is unchanged, and `scene_color_at` remains a mip-zero helper.

This is a bounded screen-space filter. It does not pair geometric interfaces
or follow off-screen refractive paths. In fog, the filtered color receives one
connecting transfer anchored at the mip-zero continuation depth at the projected
sample center. It does not transfer each footprint texel independently. Error
across a depth discontinuity grows with fog density and the depth gap.

## Fog and temporal behavior

LAYERED connecting segments use the combined cumulative fog terms through
`fog_between`. Above the existing transmittance floor this convention is cut
invariant: inserting an optically neutral retained layer does not change the
result. Intermediate in-scatter can be signed and is not clamped. Below that
floor the existing division-floor approximation remains.

SORTED, the farther remainder and post-resolve fallback keep their interval fog
convention. In combined height and aerial media, the retained-to-remainder
refraction handoff therefore differs from an all-SORTED transfer. Its size
depends on medium density: it can be small in moderate media and substantial
in dense media. Single-medium transfers have no such difference. Background
fog keeps height fog to infinity without aerial perspective.

Coverage, material lobes, absorption and fog are applied once. Additive surfaces
receive attenuation without another in-scatter contribution. Transparent
history and transmitted motion are not added: existing opaque/own-depth
velocity, TAA and render-scale behavior remain in use.

## Resource cost

Dedicated LAYERED images are allocated only in LAYERED mode. Their pixel
payload is `4*(K+1)*P + 40*P + 16*M` bytes, where `P` is the working pixel count
and `M` is the sum of a full mip chain, including level zero. This includes
retained/overflow D32 depths, RGBA16F raw/local composition pairs, R32
continuation pairs and two RGBA16F pyramids. Existing view images, device
padding and descriptor storage add to this amount. Configuration changes can
temporarily retain both old and replacement payloads.

SORTED rough filtering has its own snapshot mip cost even though it allocates
no dedicated layered images. Higher resolution and capacity both increase
memory and recording work. The `materials` example provides mode and capacity
controls with smooth and rough transmissive surfaces.
