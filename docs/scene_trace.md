# Scene tracing

`Renderer.prepare_scene_trace` builds trace data over the scene and hands shaders a `SceneTraceRoot` address. Shaders
trace rays against it with `trace_scene` and `trace_scene_any` from `scene_trace.glsl`. Every built-in ray-traced effect
uses it: traced shadows, ray-traced ambient occlusion and reflections, probe updates, volumetric fog shadows and the
path tracer. This page owns what the trace contains and how the two kinds differ; the other pages link here.
[Scene trace reference](scene_trace_reference.md) holds the posed-instance rules, counters and capacities.

## Quick start

```c3
renderer.begin_frame()!;
gpu::GpuAddress scene_trace = renderer.prepare_scene_trace(&scene)!;
// pass scene_trace in a dispatch root
```

Built-in effects prepare the trace themselves when a view enables them. Call `prepare_scene_trace` for your own
dispatches, or on a loading screen.

In a compute shader, define exactly one of `SCENE_TRACE_BVH` (software) or `SCENE_TRACE_RAY_QUERY` (hardware) to match
the kind the renderer prepared, then include the file:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "scene_trace.glsl"

// in main, with scene_address read from the dispatch root:
SceneTraceRoot scene = SceneTraceRoot(scene_address);
SceneHit hit;
if (trace_scene(scene, origin, direction, 1.0e30, TRACE_MASK_ALL, hit)) {
    TraceInstanceGpu instance = TraceInstanceArray(scene.instances).values[hit.instance];
    GeometryRoot geometry = GeometryRoot(instance.geometry);
    uvec3 corners = pull_triangle(geometry, hit.primitive);
}
bool blocked = trace_scene_any(scene, origin, direction, distance_to_light, TRACE_MASK_SHADOW_CASTER);
```

`compile::compile_glsl` takes the define in `defines`, so one source serves both kinds.

## Concepts

### Software and hardware kinds

| Kind | Structure | Needs |
| --- | --- | --- |
| Software | A two-level bounding volume hierarchy the renderer builds on the CPU. The traversal is plain shader code. | Any Vulkan 1.3 device |
| Hardware | One bottom-level acceleration structure per geometry and a top-level structure over the rows, traversed with ray queries. | `RendererDesc.ray_queries` or `ray_tracing_pipelines` |

- Every built-in consumer picks its kind from whether the renderer has ray queries, which `RendererDesc.ray_queries` or
  `ray_tracing_pipelines` enables. There is no per-view or per-effect setting, so comparing the kinds means two
  renderers. A renderer created without ray queries runs every traced effect on the software walk, which traces slower
  than ray queries for the same rays.
- Both kinds report the same hits: the same triangles, the instance mask, the alpha test and the face rules
  ([facing](#facing)).
- The path tracer alone needs `RendererDesc.ray_tracing_pipelines`, which also enables ray queries, and always traces
  hardware data.
- The built-in shaders that serve both kinds compile twice through the `SCENE_TRACE_BVH` flag of
  `shaders/variants.json`. A custom stage's traced forms follow the same rule; see
  [custom shaders](custom_shaders_reference.md#traced-shadows).

### What traces

An instance enters the trace when all of these hold:

- its node is effectively visible;
- `Mesh.trace` (or `InstancedMesh.trace`) is set. `Scene.add_mesh`, `Scene.add_instanced_mesh` and `model::instantiate`
  set it. Clear it to keep a mesh out of every trace without touching raster, shadows or picking;
- its geometry, material and, for a skinned mesh, skeleton ids are live (dead ones count in `Stats.dangling_refs`), and a
  custom material's shader is live;
- the geometry has `TRIANGLES` topology;
- the material's alpha mode is `OPAQUE` or `MASK`;
- the material has no custom vertex stage, or its shader poses the trace geometry in the row's form
  ([custom trace poses](scene_trace_reference.md#custom-trace-poses)).

A mesh contributes one instance at its node's world matrix. An instanced batch contributes one instance per live
transform, at `node.world * transforms[i]`. Camera layers and frusta play no part: an object behind the camera traces
like any other. Every row carries its node's `layers`, which hit shading tests against `Light.layers`.

| Instance | Traces |
| --- | --- |
| Mesh with no skin binding over joints and no selected morph target | At its rest pose |
| Mesh with a skin binding over a geometry with joints, or morph weights that select a target | At its raster pose, in both kinds ([posed instances](scene_trace_reference.md#posed-instances)) |
| Mesh with `vertex_motion` and neither a skin binding nor a selected morph target | At its current vertex streams ([vertex-motion slots](scene_trace_reference.md#vertex-motion-slots)) |
| Crowd part batch | Only with `add_crowd(trace: true)`, at the placement's raster pose ([animated crowds](scene_trace_reference.md#animated-crowds)) |
| `InstancedMesh` with `source = DEVICE` | Only the instances of its host mirror ([device batches](instancing.md#device-batches)); none without one |
| `LodGroup` with `LodEffects.trace` | Its level-zero parts: an ordinary group at rest or, with `trace_sway`, swayed; an animated group at its raster pose |
| `InstancedMesh` or `LodGroup` with sway | At its rest pose, counted in `Stats.trace_sway_at_rest` |
| The same with `trace_sway` | Each instance at its swayed pose, up to the posed capacity |
| Mesh or `InstancedMesh` of a material with a custom vertex stage and a trace-pose stage | At the pose the stage computes |
| Any other material with a custom vertex stage | Never |
| `BLEND` material | Never |
| Billboard and ribbon batches (billboard and ribbon particles included), decals, LOD levels above zero | Never |

A custom vertex stage can move vertices anywhere, and the renderer sees the stage, not the displacement. A material with
one traces only when its shader also supplies a trace-pose stage, whatever `trace` says. A stage that displaces nothing
and should trace draws through the built-in vertex stage.

A bounds override (`has_bounds_override`) is a bound for culling and shadow fitting only; it does not keep a mesh out of
the trace.

A swaying batch or LOD group traces at its rest pose unless `InstancedMesh.trace_sway` or `LodEffects.trace_sway` is
set. A traced shadow of a swaying tree then stays still while atlas shadows sway, and a shadow ray from a swayed leaf
can meet the tree's own rest geometry. Coverage ignores the geometry's vertex alpha on every row of a batch or LOD group
whose sway takes its bend weight from it (`SwayWeight.VERTEX_ALPHA`), because raster consumes that alpha.

`Mesh.trace_only` marks a mesh that is traced but never drawn: raster views and shadow layers skip it, and trace
collection takes it like any traced mesh, so its node must be effectively visible. Picking, the scene index and impostor
capture skip it. Its row is a [trace proxy](#trace-proxies).

## Usage

### Prepare a scene trace

`prepare_scene_trace(scene, kind)` takes a `TraceKind`:

- `AUTO` (the default) builds the hardware data when the renderer has ray queries, else the software data.
- `SOFTWARE` builds the bounding volume hierarchy.
- `HARDWARE` builds acceleration structures; it faults `c3d::UNSUPPORTED` on a renderer created without
  `RendererDesc.ray_queries` or `ray_tracing_pipelines`.

A shader reads only the kind it asked for. Asking for both kinds in the same frame keeps one set of rows: the second call
fills in the other half.

- The call collects the eligible instances, poses the deformed ones, and builds each geometry's bottom level the first
  time the geometry traces and again after its revision moves. It rebuilds the top level only when the eligible set, an
  instance's world matrix, geometry, material or pose changed.
- A second call in the same frame for the same scene and kind returns at once. The returned address is the same for the
  renderer's life, but its contents and coordinate space can change.
- The renderer holds one trace set. Prepare one scene per frame: preparing a second scene in the same frame rewrites the
  same buffer, which is ordered only after a dispatch or view has recorded the first scene's copies and consumed them.
  The copies a preparation queues are recorded by the frame's next dispatch or view, or by `end_frame`.
- With no frame open, the call records, submits and waits on its own, like `Renderer.upload_geometry`.
- Rows, bounds and ray origins use the frame's relative space; supply the current absolute reference to `begin_frame`
  before preparing. A custom dispatch expresses its rays in the space of the preparation it consumes. Closed-frame
  preparation uses the most recently selected origin, initially zero, and the next frame refreshes the data if its origin
  changes. See [camera-relative rendering](large_world.md#coordinate-contract).
- `RendererDesc.max_trace_instances` bounds the instance table (4096 when zero). More eligible instances fault
  `c3d::CAPACITY_EXCEEDED` and leave the previous table in place. Each bottom level takes one acceleration-structure
  table entry and is owned by its geometry mirror.

### Release CPU geometry after preparing

```c3
renderer.prepare_scene_trace(&scene)!;
foreach (geometry : static_geometry) assets.release_geometry_cpu(geometry);
```

A bottom level built for the current revision keeps tracing after `release_geometry_cpu`. A geometry released before its
first preparation has nothing to build from: its instances are skipped and counted in `Stats.trace_skipped`. Hardware
data builds from the geometry's GPU streams, but only once the asset store proved the arrays form a valid triangle list
for the current revision (`AssetStore.triangles_valid`). A trace preparation or a triangle pick makes that proof, and it
carries over a later release. A geometry released before any proof, or before the renderer uploaded it, is skipped by both
kinds.

Triangle geometry whose arrays form no triangle list (fewer than three positions, an index count that is not a multiple
of three, an index past the last vertex) still draws, but its instances are skipped and counted in `Stats.trace_skipped`
until its revision moves. The software level is the store's triangle tree (`AssetStore.triangle_bvh`), built once per
revision and shared with triangle picks.

### Trace in a shader

`SceneHit` carries:

- `instance`: the row in `SceneTraceRoot.instances`. Rows follow the top level's order and are valid for the frame only.
- `primitive`: the triangle in the geometry's primitive order, the same numbering as `PickHit.triangle_index`.
- `barycentrics`: the weights of the triangle's second and third corners.
- `t`: the distance along `direction` as given. It is a world distance when `direction` is normalized.

`TraceInstanceGpu` gives the hit's `GeometryRoot`, material block address, material kind, the
`TRACE_INSTANCE_ALPHA_MASK` and `TRACE_INSTANCE_DOUBLE_SIDED` flags, the instance mask, the node's receiver `layers` and
both affine transforms as rows. A masked row (`TRACE_INSTANCE_ALPHA_MASK`) reports a triangle only where its coverage
reaches the material's `alpha_cutoff`: base color alpha times the base map's alpha at the hit's UV (sampled at the top
mip), times vertex alpha when the geometry has colors. A custom material uses slot 0's alpha. Both kinds apply the same
test.

The instance mask selects rows. Every row of a drawn mesh carries `TRACE_MASK_ALL`, and rows of meshes with `cast_shadow`
also carry `TRACE_MASK_SHADOW_CASTER`. A [trace proxy](#trace-proxies) carries `TRACE_MASK_PROXY` and, with
`cast_shadow`, `TRACE_MASK_PROXY_SHADOW_CASTER` instead, and the entry points reach it through the matching proxy bit of
the mask they are given. A row whose mask shares no bit with the argument is skipped. A shader that calls `traceRayEXT`
itself passes the proxy bits to see proxies.

The traversal keeps a stack of `BVH_STACK_DEPTH` entries per level; builds never exceed that depth.

### Facing

A triangle's front is its counter-clockwise side in the geometry's local space: the side raster draws, for mirrored
models too, and the side `PickFaces.FRONT` accepts. A double-sided material (`TRACE_INSTANCE_DOUBLE_SIDED`) has two
fronts. The entry points keep what raster would show from the ray's point of view:

- `trace_scene` is a looking ray. It keeps the faces a viewer at its origin sees: a single-sided triangle counts only from
  its front. Primary, ambient occlusion, reflection and path-tracer bounce rays use it.
- `trace_scene_any` is a shadow test toward the ray's far end. It keeps the faces a light there sees, the faces the
  shadow atlas draws: a single-sided triangle counts only when its front faces the far end. Its answer depends on the
  ray's direction; it is not a symmetric line-of-sight test.
- `trace_scene_with_back_faces` keeps both faces of every triangle, and `surface_from_hit` sets `TraceSurface.back_face`
  for a single-sided triangle hit from behind. The probe update uses it, because a probe inside geometry must read dark.
  Use it for a nearest hit on either face.

`Mesh.trace_facing` (`TraceFacing`) sets which faces a mesh's row has, for traces only. `MATERIAL`, the default, follows
the material's `double_sided`. `FRONT` gives the row front faces only, whatever the material says. `BOTH` gives it two
fronts. The resolved value sets `TRACE_INSTANCE_DOUBLE_SIDED`, so both kinds, the three entry points and
`TraceSurface.back_face` follow it. Raster, the shadow atlas and picking read the material alone. `InstancedMesh` and
`LodGroup` rows follow the material. The instance mask and the alpha test apply to all three entry points, after the
facing test. CPU picking applies `PickOptions.faces`, whose default `MATERIAL` matches `trace_scene`.

### Trace proxies

A trace-only mesh stands in for geometry that raster draws another way, so its triangles may sit above the drawn
surface: a coarse grid for terrain is above it wherever the surface dips. A ray from a drawn surface starts
`TRACE_SURFACE_OFFSET` (0.02 world units) along the normal whatever it meets, and a proxy under that start would
otherwise block it.

A material that knows how far its proxy may sit above its surface raises `trace_proxy_skip_height` before it shades, in
metres above the surface. `trace_proxy_t_min(skip_height, direction, normal)` gives the distance along a ray at which it
has risen that far above the plane of the surface at its origin. `trace_scene`, `trace_scene_any` and
`trace_scene_query` (only on the ray-query kind) take it as a `proxy_t_min` argument before the hit (or after the
instance mask, for `trace_scene_any`). A hit on a proxy nearer than it is ignored, on both kinds.

- Every other instance, a box on the terrain among them, keeps counting from the ray's start, so contact shadows stay.
  Every `trace_only` mesh is a proxy and a pixel's skip height applies to all of them: a trace-only occluder standing on
  the terrain loses its contact shadow within that height of the surface.
- `SceneTraceRoot.proxy_count` is the number of proxy rows in the frame's trace set; a frame without proxies pays no
  proxy query.
- The forward shadow paths read `trace_proxy_skip_height` themselves. A deferred view carries the height per pixel: `write_gbuffer` packs it into the upper 16 bits of the flags channel as
  centimetres, rounded up and clamped at 655.35 m, and the lighting resolve, [ray-traced ambient
  occlusion](ambient_occlusion.md#ray-traced) and [ray-traced reflections](reflections.md) read it back. A forward view
  with ray-traced ambient occlusion writes the same word from its depth prepass into an `R32_UINT` `proxy_skip` image;
  the core fragments write zero, and a shader's [prepass stage](custom_shaders_reference.md#prepass-stage) writes its own height.
  A multisampled view reads sample 0 of the word: a deferred view's flags and a forward view's multisample `proxy_skip`
  are copied to a single-sample image after the pass that writes them. A forward view's reflections read none, because only Standard and Physical pixels trace and they raise no height.
- A material that never sets the height writes zero. The path tracer starts its rays at trace hits and is unaffected.

### Hit surfaces

`trace_surface.glsl`, which `scene_trace.glsl` includes, turns a hit into a surface:

```glsl
TraceSurface surface = surface_from_hit(scene, hit, direction, cone_width);
```

`TraceSurface` holds the world position, the shading and geometric normals, albedo (base colour times its map and vertex
colour), emission, metallic and roughness (Standard and Physical rows; 0 and 1 otherwise), the material kind and block
address, the row's receiver `layers`, and `back_face`, set when the ray hit the back of a single-sided surface (only
`trace_scene_with_back_faces` reports such hits). A Physical row also fills the IOR, specular colour and weight,
clearcoat, sheen, anisotropy, transmission and thickness values; other rows hold the neutral values.

- Normal maps apply to the shading normal, the clearcoat normal map to the coat normal, through the tangent stream when
  the geometry has one and through the triangle's edges otherwise. A double-sided surface hit from behind reports
  flipped normals.
- Maps sample at the level of detail a ray cone of width `cone_width` (world units, at the hit) selects over the
  triangle; `ray_cone_lod` in `c3d::render` is its CPU twin.
- Hit shading (`shade_hit` in `hit_shading.glsl`) runs in compute and ray stages, so it takes no screen-space derivative
  and every texture it reads samples at an explicit level.
- Offset ray origins by `TRACE_SURFACE_OFFSET` along the geometric normal.

Ray-traced [reflections](reflections.md), [ambient occlusion](ambient_occlusion.md#ray-traced) and
[path tracing](path_tracing.md) use these helpers.

## Example

```bash
python3 scripts/fetch_benchmark_assets.py
python3 scripts/build.py --example software_rt
```

`examples/software_rt` renders Sponza and overwrites the right half of the view with one primary ray per pixel. `M`
cycles distance, geometric normal and instance colors. `--hardware` creates the renderer with ray queries, prepares
hardware data and compiles the same trace shader with `SCENE_TRACE_RAY_QUERY`.

## Limits

- Rays see only the traced scene ([What traces](#what-traces)). Custom shader code does not run at hits: `shade_hit`
  evaluates the built-in Basic, Standard, Physical and Toon rows and shades custom-material rows a neutral grey.
- One trace set per renderer; prepare one scene per frame.
- The software kind traces slower than ray queries. A strongly posed instance can trace slower than at rest, because
  posed trees are refit rather than rebuilt.
- The path tracer needs ray-tracing pipelines and hardware data; the other effects run on either kind.

## See also

- [Scene trace reference](scene_trace_reference.md) for posed instances, counters and capacities
- [Shadows](shadows.md), [ambient occlusion](ambient_occlusion.md), [reflections](reflections.md),
  [probe volumes](probe_volumes.md), [path tracing](path_tracing.md)
- [Custom shaders](custom_shaders.md) for trace-pose and traced-shadow stages
- [Camera-relative rendering](large_world.md)
