# Scene trace reference

Posed-instance rules, counters and capacities of the scene trace. [Scene tracing](scene_trace.md) explains what
traces, the two kinds and the shader API.

## Capacities

| Name | Value | Meaning |
| --- | --- | --- |
| `RendererDesc.max_trace_instances` | `DEFAULT_MAX_TRACE_INSTANCES`, 4096 | Size of the instance table; more eligible instances fault `c3d::CAPACITY_EXCEEDED`; with ray queries on, `create_renderer` faults `c3d::UNSUPPORTED` above the device's instance limit. The hardware kind keeps 64 bytes of CPU instance descriptors per entry, allocated with its first preparation |
| `RendererDesc.max_posed_trace_instances` | `DEFAULT_MAX_POSED_TRACE_INSTANCES`, 64 | Posed slots; zero never disables posing |
| `INSTANCE_ABSENCE_FRAMES` | `FRAMES_IN_FLIGHT + 1` | Frames a posed slot stays unclaimed before it is released |
| `shader::BVH_STACK_DEPTH` | 32 | Entries of the traversal stack per level |

`create_renderer` faults `c3d::INVALID_ARGUMENT` unless `2 × max_posed_trace_instances + 32 + 16 × max_views` fits the
device's allocation table (4,096 entries) and, with ray queries or ray-tracing pipelines,
`max_posed_trace_instances + 32` fits its acceleration-structure table (4,096 entries). The 32 are the renderer's own
entries in each table, and the 16 per view are one view's allocations. At the default 8 views, at most 1,968 slots are
accepted. A software slot takes 2 allocation entries, one for its posed streams and one for its node copy. A hardware slot
takes 1 allocation entry and 1 structure entry for its bottom level. The bound counts both kinds, so a scene of hardware
slots alone is bounded as if it used both, although its slots would fit about twice as many.

Content shares both tables uncounted: geometry blocks and their previous copies, rest trees and bottom levels, instance
batches and resident crowds, compute-skin bindings, material payloads, environments, buffers and upload overflow. A scene
can therefore fault `gpu::SLOT_TABLE_FULL` in `prepare_scene_trace` when it fills what is left. A frame that replaces every
slot holds the replaced entries until they retire, up to twice the slot entries.

## Counters

`begin_frame` resets these `Stats` fields.

| Field | Counts |
| --- | --- |
| `trace_instances`, `trace_nodes` | Rows and top-level nodes of the current trace |
| `trace_skipped` | Instances left out: released geometry, no triangle list, a custom row whose pose stage is missing or rejected |
| `trace_sway_at_rest` | Swaying batches and LOD groups traced at rest, including those that found no posed slot, whose CPU arrays are gone, or that have a custom vertex stage (which traces through its own trace-pose form and never through the sway) |
| `trace_build_ms` | CPU time spent in `prepare_scene_trace` |
| `trace_top_level_writes` | Rewrites of the top-level boxes and instance rows |
| `trace_posed_instances`, `trace_posed_shared` | Posed rows, and posed rows that use another row's slot |
| `trace_posed_overflow` | Posed candidates left out past the slot capacity |
| `trace_deform_overflow` | Custom-posed rows left out past the slot capacity |
| `trace_posed_bytes` | GPU bytes the posed slots hold |
| `trace_poses`, `trace_poses_reused` | Posing dispatches, and poses a slot took from compute skinning instead of dispatching |
| `trace_refits` | Trees refit; all share one dispatch |
| `blas_builds`, `blas_updates`, `tlas_builds` | Bottom-level builds, in-place bottom-level updates and top-level builds recorded this frame |
| `acceleration_batches` | Barrier-separated groups of bottom-level work |
| `dangling_refs` | Includes instances with dead geometry, material, skeleton or shader ids |

Posing and refits run under `Pass.TRACE_POSE`. Acceleration structure builds run under `Pass.ACCELERATION_BUILD`.

## Posed instances

A skinned mesh, a morphed mesh or both traces at the pose raster draws in the same frame. A compute pass applies the
raster deformation functions (morph targets, then skin) to the frame's palette and morph block and writes the posed
positions, normals and tangents into a renderer-owned slot behind its own geometry root. Every trace consumer reads hits
through the row's geometry root, so traced shadows, ambient occlusion, reflections, probe updates and path tracing see
the pose with no shader change.

- **Software.** One workgroup per instance refits a copy of the rest tree: each leaf takes the bounds of its posed
  triangles and each interior node the union of its children. Topology and leaf primitives stay those of the rest tree.
  At rest the copy equals the rest tree; a strong pose widens the boxes, so a posed instance traces slower than at rest.
- **Hardware.** Each slot owns one bottom level: a full build when the slot is new, rebuilt or its source geometry
  changed, and an in-place update each frame the pose changes. A pose change rebuilds the top level too. A geometry whose
  vertex or primitive counts change replaces the slot's bottom level.
- **Bounds.** A posed row's box in the top level is `mesh_world_bounds`: the rest bound widened by the selected morph
  targets and, for a skinned mesh, by the joints. A `Mesh.local_bounds` override replaces it.
- **Once per frame.** The pass runs only when the palette or morph block changed since the last recorded pose. Several
  views and preparations in one frame pose a slot once, so a node holds one pose per frame, as raster draws one palette
  per node per frame. A still pose keeps the trace revision unchanged, so the path tracer keeps accumulating. A changed
  joint or weight advances the revision once.
- **Capacity.** Posed instances are admitted in collection order. Past `RendererDesc.max_posed_trace_instances` an
  instance is left out of the trace, never traced at rest, and counted in `Stats.trace_posed_overflow`.
  `Mesh.trace = false` keeps a mesh out. A slot unclaimed for more than `INSTANCE_ABSENCE_FRAMES` frames is released; an
  off-screen posed mesh still traces, because it can cast, so it keeps its slot.
- **Cost.** A slot holds 24 bytes per vertex (40 with tangents) of posed streams, a 112-byte geometry root and 32 bytes
  per node of refit copy, plus a bottom level on the hardware kind. A geometry that can deform adds a depth table to its
  rest trace allocation: 4 bytes per node plus 132 bytes. A skinned mesh in bind pose still takes a slot. With no traced consumer in a frame nothing is allocated or recorded.
- **Closed frames.** A preparation outside a frame poses and refits in its own submission and reads the current pose.
- **Compute skinning.** With [compute skinning](animation.md#compute-skinning) on, a slot whose mesh or crowd part has a
  posed binding this frame takes that pose instead of running its own pose pass; its streams stay allocated, unwritten.
  The rule and its exceptions are on the animation page.

## Vertex-motion slots

A traced `Mesh` with `vertex_motion` and neither a skin binding nor selected morph targets takes a posed slot too, for
CPU deformation such as cloth. The slot follows the geometry's rest topology (geometry, vertex count, index count and
stream layout), not its revision. A new revision with the same topology does not rebuild the trace data: a transfer
copies the revision's positions, normals and tangents (when present) from the geometry mirror into the slot, then the
software tree is refit and the hardware bottom level is updated in place. No pose pass runs, and the triangle tree and
bottom level of the shared geometry are not rebuilt. Index values are not part of the key: a revision that rewrites the
triangle indices must also change a count to rebuild the slot.

- **Device writes.** A [geometry write](compute.md#geometry-writes) is a revision of the streams the slot copies. It
  refills and refits the slot in the same frame, so the dispatch precedes `prepare_scene_trace`.
- **Topology change.** A different geometry, vertex count, index count or stream layout rebuilds the slot, its tree and
  its bottom level.
- **Refit only.** The tree keeps the topology of its first revision with no periodic rebuild. A surface folded far from
  that shape traces slower, not wrongly.
- **Capacity.** Slots count against `max_posed_trace_instances`. With none free the mesh traces through the shared
  geometry and rebuilds it every revision, as a mesh without `vertex_motion` does; it is not counted in
  `trace_posed_overflow`. A static mesh with `vertex_motion` still holds a slot.
- **Top level.** On the hardware kind every `vertex_motion` revision rebuilds the top level and advances the trace
  revision, which resets traced accumulation, as for skin and morph poses. The rows are rewritten only when a field
  other than the pose changes.

## Custom trace poses

A shader's `trace_pose` forms pose the trace geometry of a custom material that has a vertex stage
([custom shaders](custom_shaders_reference.md#trace-pose)). `single` poses a mesh and `instanced` poses one instance of an
`InstancedMesh`; a form needs the vertex form of the same kind. The built-in sway is posed the same way for a batch or
LOD group with `trace_sway`. Both take posed slots and follow the rules of [posed instances](#posed-instances): the
compute pass writes the positions, normals and tangents into a renderer-owned slot, the software kind refits a copy of
the rest tree, and the hardware kind builds or updates the slot's bottom level.

- **Re-posing.** A row poses again when its inputs change. For a custom stage the inputs are the material's revision, the
  revisions of its asset textures, the revision of the shader the renderer published, the instance record of an
  instanced row and, with `CustomTracePose.reads_time`, the frame time. For the sway they are the batch's geometry, the
  sway at the frame time, the node's world and the batch's `revision`. A swaying batch therefore poses whenever the time
  moves. An in-place edit of a transform or colour reaches the pose only through `Scene.mark_instances_dirty` or
  `Scene.mark_lod_instances_dirty`, which advance the revision. A still scene keeps its pose, and with it the trace
  revision. A closed preparation poses at the last frame's time.
- **Hardware.** The first pose of a slot builds its bottom level in full. So does a re-pose of a custom stage without
  `reads_time`, because an edit may reshape the surface and an update would keep the first pose's tree. A `reads_time`
  stage and the sway update in place.
- **Software.** A geometry posed by a custom stage or the sway keeps the depth table of its rest tree, as a skinned
  geometry does. A tree built for a rigid row has no table, and only the CPU arrays can rebuild it. A swayed row whose
  geometry released them traces at rest and counts in `Stats.trace_sway_at_rest`. A custom row, which has no rest form,
  is left out and counted in `Stats.trace_skipped`.
- **Bounds.** A custom-posed mesh takes `Mesh.local_bounds` when `has_bounds_override` is set, else the geometry's bound.
  A custom-posed instance takes the geometry's bound under its matrix. The stage keeps its surface inside that bound, as
  a displaced geometry needs one to be culled; the top level does not see past it. A swayed row's bound grows by the sway
  reach.
- **Capacity.** Rows share `max_posed_trace_instances` with every other posed kind. A custom row without a slot is left
  out of the trace and counted in `Stats.trace_deform_overflow`. A swayed row without a slot traces at rest and counts
  once for its batch or group in `Stats.trace_sway_at_rest`. Each preparation claims swayed rows after every other kind,
  so a vegetation layer that holds every slot yields them to a character that appears later; its rows trace at rest until
  slots free again.
- **Cost.** A slot costs what [posed instances](#posed-instances) lists. A pose also takes frame upload ring bytes: 40
  per custom row, plus 128 for an instanced one, and 256 per swayed row plus 80 per swayed batch or group part. A stage
  that reads time poses and updates every frame.
- **Long rows.** A pose dispatch wraps a row whose groups of 64 vertices exceed the device's group count along x into
  rows of groups, so a row of any length poses in one dispatch. A custom stage that indexes through `trace_pose_index`
  and sets `ShaderDesc.trace_pose_grid` poses it. An undeclared stage faults `c3d::UNSUPPORTED` at `prepare_scene_trace`
  for a row past that count (4,194,240 vertices where the device allows only the guaranteed 65,535 groups). The built-in
  skin, morph and sway poses use the grid, and the terrain and water stages declare it.
- **Limits.** A custom stage sees only its material, the instance record and the time: it cannot reproduce a vertex stage
  that reads the camera or other frame data, and skin, morph targets and `vertex_motion` do not apply to a custom row. A
  `LodGroup` part and a crowd part with a custom vertex stage stay out of the trace. The sway applies no fade, which
  depends on the view, so every instance traces.
- **Published stages.** A row is posed by the stage the renderer published. When the store's newest revision was rejected
  and the published one lacks the form the row needs, or a pose pipeline the backend rejects, the row is left out and
  counted in `Stats.trace_skipped`. A rejected pipeline also counts in `Stats.shader_rejections`.

## Animated crowds

Each crowd row is boxed by the `pose_bounds` passed to `add_crowd`, which must cover every pose the crowd plays.
Placements of one crowd part batch (`AnimatedCrowd` or a crowd-backed `LodGroup`) with byte-identical palette and morph
inputs share a posed trace slot: the lowest placement index in the group claims the slot, and the others point their
rows at its root, refit nodes and bottom level (`Stats.trace_posed_shared`). Under compute skinning the shared slot
aliases the leader's skinned copy. When the leader's pose changes, its slot updates in place. A placement that leaves its
group claims its own slot with a full build, and unclaimed slots release after `INSTANCE_ABSENCE_FRAMES` frames.

Each posed slot holds its own streams and bottom level, so memory scales with the number of distinct poses per part batch.
On the hardware kind each claimed slot costs a bottom-level update every frame its pose changes. The software kind poses
and refits a tree copy per distinct pose and builds no bottom level.

## Hardware lifetime

- A geometry's bottom level is created the first time a hardware preparation traces the geometry and again after its
  revision moves; the old one is destroyed after every frame that could trace it completed. A posed instance's bottom
  level is updated in place while its slot lives.
- The renderer keeps two top-level structures and rebuilds one only when the rows, their world matrices, geometry,
  material or pose change. `SceneTraceRoot.tlas_index` names the top level the frame reads, or 0 without hardware data.
- A frame's bottom-level builds and updates are recorded in batches with one barrier after each. The scratch memory is
  one allocation per frame slot; it grows to the larger of the top-level build's need and the frame's largest batch, which
  is at most 64 MiB or the largest single build, and it does not shrink.

## See also

- [Scene tracing](scene_trace.md)
- [Custom shaders](custom_shaders.md) for `trace_pose` and geometry writes
- [Animation](animation.md#compute-skinning), [instancing](instancing.md), [LOD](lod.md)
