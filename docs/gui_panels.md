# GUI panels

`c3d::gui` ships ImGui panels for the scene tree and component inspectors, materials, display processing, renderer statistics
and view images. Each panel is a function the application calls between `GuiRenderer.new_frame()` and `finish_frame()`. The
adapter itself is described in [GUI overlay](gui.md).

## Quick start

```c3
gui_renderer.new_frame();

gui::scene_panel(&scene, &panels);
if (scene.world.is_alive(panels.selected)) {
    if (Mesh* mesh = scene.get(scene.node(panels.selected), Mesh)) {
        gui::material_panel(renderer.assets, mesh.material)!;
    }
}
gui::stats_panel(&renderer)!;

scene.update_world();
gui_renderer.finish_frame();
```

## Panels

| Call | Shows or edits |
| --- | --- |
| `scene_panel(scene, state)` | Node tree, the selected node's local transform, visibility, layers and component inspectors. `state` is a `GuiPanelState`. |
| `reflection_capture_buttons(renderer, scene, state)` | Capture buttons for the selected reflection probe. Call after `scene_panel`, outside a frame. |
| `material_panel(assets, material)` | Factors of one material. Faults `INVALID_ID` for a dead material. |
| `post_panel(desc, lut, stats)` | A view's display processing; returns whether anything changed. |
| `stats_panel(renderer)` | Renderer counters, GPU timings and memory. Call before `begin_frame`, which resets the counters. |
| `view_stats_table(renderer, views, labels)` | Per-view counters side by side. |
| `targets_panel(renderer, view, state, environment)` | Shading and light selection; previews of the view's images. Needs no open frame. |

The add-on panels are `gui::profiler_panel` from `c3d_profile_gui` under `C3D_PROFILE_GUI`
([Profiling](profiling.md#inspect-captures-with-imgui)) and the physics panel from `c3d_physics_gui` under `C3D_PHYSICS_GUI`
([Physics inspector](physics_inspector.md)).

## Scene panel

Selecting a node shows its `Visible` flag, `Layers` mask, local `Position`, `Rotation (deg)` and `Scale`; a zero scale
component is refused. Below that, one section per component type the node carries shows that type's inspector. For each type
the panel uses the first of:

1. a custom inspector registered with `gui::expose(Type, inspector)`;
2. the type's [description](type_descriptions.md), when registered;
3. the exposed reflected default, one widget per supported struct member.

`create_gui_renderer` exposes Mesh, LodGroup, Camera, Light, Decal, ModelInstance, SkinBinding, Animator, IkChain, FootIk,
LookAt, ProbeVolume and ReflectionProbe.

A described component needs no `gui::expose` call. Descriptions supply display names, clamped ranges, units, enum choices and
typed references. Transient fields are omitted; arrays and slices expose existing elements without changing their lengths;
strings and references are read-only. Reconstruction hooks run after actual edits, once per changed value with children before
parents, and their faults appear inline without undoing the edit. A type that needs an external dirty mark or an ownership
change keeps a custom inspector. See [type descriptions](type_descriptions.md).

The `LodGroup` inspector is read-only: placement mode and count, bounds mode, sway, fade, each level's minimum height and
parts, and an installed impostor's atlas and capture radius. See [whole-object LOD](lod.md). The `Decal` inspector shows the
material id and edits the four weights in [0, 1], `Fade angle (deg)`, `Receiver layers` and `Order`; component edits need no
material dirty call. See [decals](decals.md).

## Material panel

`material_panel` edits the surface settings every kind shares (alpha mode and cutoff, double sided, depth test and write,
blend mode, wireframe) and the kind's own factors: Basic color; Standard base color, metallic, roughness, normal scale,
occlusion and emissive; Physical adds clearcoat, sheen, specular, anisotropy and transmission; Toon color, steps, rim and
outline. A Custom material shows its shader, filled texture slots and payload size, read-only. The panel calls
`mark_material_dirty` when a value changes, so the asset revision advances only after an edit.

## Post panel

`post_panel(&desc, lut, &stats)` edits a `ViewDesc` in place: tonemap, anti-aliasing, depth prepass, LUT, grade, bloom, depth
of field, motion blur, TAA, auto exposure, ambient occlusion, screen-space GI, ray-traced shadows and reflections and
path-trace sample limits. Apply the result with `render::configure_view`. `lut` offers a LUT checkbox when the id is live; zero
hides it. A non-null `stats` shows the view's delayed exposure and focus. `gui::anti_aliasing_combo` selects a view's filter on
its own. See [Display processing](post.md).

## Stats panel

`stats_panel` shows the previous frame's counters and the latest completed GPU timings. In panel order: frame and CPU record
time; draw work (draws, indirect draws, dispatches, scene snapshots, triangles, instances); culling (visible of tested
instances, cull and sort dispatches and overflows, culled and faded batches); LOD; lights, decals, probes and debug lines;
uploads and [preparation](#preparation-counters); dangling references; trace instances, nodes, builds and path-trace samples;
shader rejections; textures and texture views against their capacities; the completed cluster figures; the previous frame
slot's upload ring use; the completed GPU frame's per-pass milliseconds; per-heap memory; and a Diagnostics section with the
validation state and recent debug messages.

- Draw totals include composition and GUI. Indirect draws count batch draws issued through indirect commands, every pass
  included. Triangle totals include mesh and GUI geometry. Each scene snapshot is one image copy and one draw; snapshots serve
  [scene readers](custom_shaders.md#scene-reads).
- Instance visibility, GPU LOD counts and cluster figures arrive after frame-slot completion. They lag the CPU counters and can
  describe a different frame.
- Decals and Decals dropped sum current CPU selection counts across views. Completed decal overflows counts cells that exceeded
  their decal list capacity; those cells use the complete ordered list, so overflow does not discard decals.
- The cluster figures describe the view named by `Stats.cluster_view`; with several clustered views read each view's
  `ViewStats` ([lights](lights.md#diagnostics)). `view_stats_table` lists images, lights, decals, cluster counts, exposure,
  accumulated samples and shadow set per view; the fields are in the [views reference](views_reference.md#counters).
- The upload ring rows report the previous frame slot's used and total bytes and its overflow allocations. A dormant frame can
  also be the previous slot.
- The memory rows show the device's advisory usage and budget per heap, with its allocation and block sizes.

### Preparation counters

Upload bytes are the bytes staged this frame, not GPU resident memory; an edited geometry range counts only its vertices. The
preparation rows count the work of [preparation](preparation.md) this frame:

| Row | Meaning |
| --- | --- |
| `Prepare units` | Preparation units completed. |
| `Prepare bytes` | GPU-bound bytes staged. CPU-only copies, such as shader descriptions, are not counted here; they are `PrepareReport.copied_bytes` of an advance. |
| `Prepare generated texels` | Texels of generated mips. |
| `Prepare pipeline calls` | Pipeline creation calls that preparation issued. |
| `Pipelines created` | Cache lookups that missed and built a pipeline this frame, prepared ones included. `Stats.pipeline_lookups` counts every lookup, so the difference is the hits. |
| `Prepare generation ns`, `Prepare pipeline driver ns` | Time spent generating mips and in the driver creating pipelines. |
| `Prepare elapsed / overrun ns` | Wall time of the advances and the time beyond the requested time limit. |

The counters keep the work spent before a propagated fault; `abort_frame` does not clear them, and they reset at the next
`begin_frame`. Progress of a budgeted preparation (units, bytes and texels done) comes from its progress report; see
[Budgeted preparation](preparation.md#budgeted-preparation).

GPU timings are off by default. Build with the [GPU profiling features](profiling.md#capture-gpu-work) and set
`RendererDesc.gpu_timings`:

```bash
c3c build cube_gui --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
./examples/build/cube_gui --gpu-timings
```

Without `C3D_PROFILE_GPU` the panel prints `GPU timings: N/A (profiling excluded)` and `RendererDesc.gpu_timings` faults
`UNSUPPORTED`. The panel shows the completed GPU frame, `N/A` for absent measurements and a partial status for truncated
summaries; pass buckets sum all recorded views. Timestamp queries add overhead on some drivers, so compare against a run with
timing off instead of subtracting a fixed amount.

## Targets and cluster panel

`targets_panel` lists a view's images, render targets, shadow layers and the faces of an uploaded environment as collapsing
previews. Open entries request previews for the next overlay, so call it before `begin_frame`. Create the state with
`gui::default_targets_panel_state()`.

- Its Forward, Deferred and Path traced and its Flat and Clustered controls apply through `configure_view`, which can fault
  with invalid-argument, unsupported, allocation, recording and wait faults; do not treat the panel as an infallible display.
  Path traced needs ray tracing pipelines. The [light selection contract](lights.md#select-lights-with-clusters) describes the cluster settings.
- Controls set the preview exposure, depth and velocity ranges and size. The panel says when no preview slot is free.

### Cluster diagnostics

For a clustered view, `Cluster slice` starts at zero and is clamped to the current slice count. Expand `clusters` to see that
slice's tile occupancy. Color is the stored finite-light count over the per-cell capacity: blue is empty, intermediate values
add green, red is full, and **magenta marks overflow**. Dark grey marks a cell that [depth pruning](lights.md#depth-pruning)
skipped. Globals are excluded. This is a selected-slice heatmap, not the occupancy at visible surfaces. An overflowing cell
uses complete flat lighting, so magenta does not mean lights were dropped.

- Slice-depth labels use the last-rendered camera mapping. Changing the lighting mode, the slice count or the clustering far
  distance invalidates them; they read `unavailable` until a successful render publishes matching depth data. Inactive or
  unavailable cluster data clears the preview.
- A `VIEW_CLUSTERS` preview needs a live clustered view and an in-range slice (`PreviewSource.level`). A dead view faults
  `INVALID_ID`; a flat view or invalid slice faults `INVALID_ARGUMENT`.
- The Stats panel labels the cluster view, cell, overflow and skipped counts **Completed**. They lag current controls and work
  with GPU timestamps off. With timestamps on, the panel also shows completed `LIGHT_CULL` and opaque times. Cull time includes
  the private light upload and reset (an unpruned view only), the tile-depth reduction (a pruned view only), assignment and the
  counter copy; opaque time alone is not total cost. The dispatch also assigns decals, and sampling is timed in the receiver's
  draw pass; the heatmap shows light counts only. An open preview adds work, so close it for a timing comparison.

## Limits

- Panels draw immediately and keep only the state structs the application owns.
- Custom materials are shown, not edited.
- `targets_panel` lists at most `TARGETS_PANEL_ENTRIES` (64) entries and shows at most `render::PREVIEW_CAPACITY` (8) previews
  at once.
- Counters that arrive after completion describe an earlier frame than the CPU figures.
- Only described and exposed component types get inspectors.

## See also

- [GUI overlay](gui.md) for creating the adapter and ordering the frame.
- [Lights](lights.md) for the cluster settings the heatmap serves.
- [Views](views.md) for view configuration and [Views reference](views_reference.md#counters) for the counters.
- [Preparation](preparation.md) for budgeted preparation, whose counters the Stats panel prints.
- [Debug lines](debug_draw.md), whose counters the Stats panel prints.
