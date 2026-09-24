# Scene tracing

`Renderer.prepare_scene_trace` builds trace data over the static scene and hands shaders a `SceneTraceRoot` address. Shaders trace rays against it with `trace_scene` and `trace_scene_any` from `scene_trace.glsl`. Two kinds of trace data serve the same rows and the same shader functions:

- **Software**: a two-level bounding volume hierarchy the renderer builds on the CPU. The traversal is plain shader code and runs on any Vulkan 1.3 device.
- **Hardware**: one bottom-level acceleration structure per geometry and a top-level structure over the rows, traversed with ray queries. It needs `RendererDesc.ray_queries`.

## What traces

An instance enters the trace when all of these hold:

- its node is effectively visible;
- `Mesh.trace` (or `InstancedMesh.trace`) is set. `Scene.add_mesh`, `Scene.add_instanced_mesh` and `model::instantiate` set it; clear it to keep a mesh out of every trace without touching raster, shadows or picking;
- its geometry, material and, for a skinned mesh, skeleton ids are live, and a custom material's shader is live;
- the geometry is static triangles: `TRIANGLES` topology, no morph targets, no skin binding, no bounds override;
- the material's alpha mode is `OPAQUE` or `MASK`.

A mesh contributes one instance at its node's world matrix. An instanced batch contributes one instance per live transform, at `node.world * transforms[i]`. Camera layers and frusta play no part: an object behind the camera traces like any other.

Every instance traces its rest pose. A mesh a custom vertex stage deforms needs `trace = false` or a bounds override, which excludes it.

## Preparing

```c3
renderer.begin_frame()!;
gpu::GpuAddress scene_trace = renderer.prepare_scene_trace(&scene)!;
// pass scene_trace in a dispatch root
```

`prepare_scene_trace(scene, kind)` takes a `TraceKind`:

- `AUTO` (the default) builds the hardware data when the renderer has ray queries, else the software data.
- `SOFTWARE` builds the bounding volume hierarchy.
- `HARDWARE` builds acceleration structures; it faults `c3d::UNSUPPORTED` on a renderer created without `RendererDesc.ray_queries`.

A shader reads only the kind it asked for. Asking for both kinds in the same frame keeps one set of rows: the second call fills in the other half.

The call collects the eligible instances and builds each geometry's bottom level the first time the geometry traces, and again after its revision moves. It rebuilds the top level only when the eligible set, an instance's world matrix, geometry or material changed. A second call in the same frame for the same scene and kind returns at once. The returned address is the same for the renderer's life. Copies it queues are recorded by the frame's next dispatch or view, or by `end_frame`.

The renderer holds one top level. Prepare one scene per frame: preparing a second scene in the same frame rewrites the same buffer, which is ordered only after a dispatch or view has recorded the first scene's copies and consumed them.

With no frame open, the call records, submits and waits on its own, like `Renderer.upload_geometry`. Use it on a loading screen:

```c3
renderer.prepare_scene_trace(&scene)!;
foreach (geometry : static_geometry) assets.release_geometry_cpu(geometry);
```

A bottom level built for the current revision keeps tracing after `release_geometry_cpu`. A geometry released before its first preparation has nothing to build from: its instances are skipped and counted in `Stats.trace_skipped`. An acceleration structure builds from the geometry's GPU streams, but only after the CPU arrays, or a software level of the same revision, proved the arrays form a valid triangle list; a geometry released before any preparation is skipped by both kinds.

Triangle geometry whose arrays form no triangle list (fewer than three positions, an index count that is not a multiple of three, an index past the last vertex) still draws, but it does not trace: its instances are skipped and counted in `Stats.trace_skipped` until its revision moves.

`RendererDesc.max_trace_instances` bounds the instance table (4096 when zero). More eligible instances fault `c3d::CAPACITY_EXCEEDED` and leave the previous table in place. The top level, the instance table and the root live in one buffer of that capacity; each bottom level is one allocation owned by its geometry mirror and released with it.

`Stats.trace_instances`, `trace_nodes` (top-level nodes), `trace_skipped` and `trace_build_ms` (CPU time spent in the call) describe the current frame; `begin_frame` resets them. `Stats.blas_builds` and `tlas_builds` count acceleration structure builds recorded in the frame; builds run under `Pass.ACCELERATION_BUILD`.

### Hardware lifetime

A geometry's bottom-level structure is created the first time a hardware preparation traces the geometry and again after its revision moves; the old one is destroyed after every frame that could trace it completed. The renderer keeps two top-level structures and rebuilds one only when the rows, their world matrices, geometry or material change. A frame reads at most one of them. A rebuild in a later frame targets the other, whose readers have completed; a rebuild in the same frame reuses the one the frame already reads, ordered after those reads. Build scratch is per frame slot and grows to the largest build. `SceneTraceRoot.tlas_index` names the top level the frame reads, or 0 without hardware data.

## Tracing in a shader

Define exactly one of `SCENE_TRACE_BVH` (software) or `SCENE_TRACE_RAY_QUERY` (hardware) to match the kind the renderer prepared, then include the file. `compile::compile_glsl` takes the define in `defines`, so one source serves both:

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

The instance mask selects rows: every row carries `TRACE_MASK_ALL`, and rows of meshes with `cast_shadow` also carry `TRACE_MASK_SHADOW_CASTER`. A row whose mask shares no bit with the argument is skipped.

`SceneHit` carries:

- `instance`: the row in `SceneTraceRoot.instances`. Rows follow the top level's order and are valid for the frame only.
- `primitive`: the triangle in the geometry's primitive order, the same numbering as `PickHit.triangle_index`.
- `barycentrics`: the weights of the triangle's second and third corners.
- `t`: the distance along `direction` as given. It is a world distance when `direction` is normalized.

`TraceInstanceGpu` gives the hit's `GeometryRoot`, material block address, material kind, `TRACE_INSTANCE_ALPHA_MASK` and `TRACE_INSTANCE_DOUBLE_SIDED` flags, the instance mask and both affine transforms as rows. Triangles are two-sided. A masked row (`TRACE_INSTANCE_ALPHA_MASK`) reports a triangle only where its coverage reaches the material's `alpha_cutoff`: base color alpha times the base map's alpha at the hit's UV (sampled at the top mip), times vertex alpha when the geometry has colors; a custom material uses slot 0's alpha. Both kinds apply the same test, so they report the same hits.

The traversal keeps a stack of `BVH_STACK_DEPTH` entries per level; builds never exceed that depth.

## Example

`examples/software_rt` renders Sponza and overwrites the right half of the view with one primary ray per pixel. `M` cycles distance, geometric normal and instance colors. `--hardware` creates the renderer with ray queries, prepares hardware data and compiles the same trace shader with `SCENE_TRACE_RAY_QUERY`. It needs the benchmark assets: `python3 scripts/fetch_benchmark_assets.py`.

```bash
python3 scripts/build.py --example software_rt
```

In a GPU-profiling build (`c3c build software_rt --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL`), `--gpu-timings` shows rays per second in the panel, and `--gpu-timings --benchmark 300` opens 1920x1080, times the trace pass over 300 frames after a warm-up and prints the mean. On a software Vulkan driver such as llvmpipe those numbers measure the CPU; take them on a hardware driver.

`cpu_bench bvh_top N` times a top-level build over `N` scattered boxes and `cpu_bench bvh_triangles S` a bottom-level build over a plane of `S` by `S` segments.
