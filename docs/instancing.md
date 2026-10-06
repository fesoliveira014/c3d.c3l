# Explicit instancing

GPU instance models use the shared [frame origin](large_world.md). The renderer
subtracts it from the node matrix before composing local placements. CPU source
transforms stay local; previous placements use their recorded history origin.
An origin change rewrites consumed resident records without reallocating them.

For camera-facing or direction-aligned quads, use core
[billboard batches](billboards.md). They share instance culling/sorting and GPU
record lifetime while keeping their own typed scene data.

Module `c3d::scene` owns the component; `c3d::render` draws it. An `InstancedMesh` draws many copies of one geometry and one material with one draw call per pass. Each copy has its own transform and color. There is no automatic batching: a batch exists because the application made one.

For whole-object alternatives with different geometry, materials and part counts,
use [LOD groups](lod.md). They retain original placement indices across parity
changes and select one level for all parts. A group can also borrow a
[static impostor atlas](lod.md#static-impostors) as its terminal choice. Its
placements retain their colors, transforms and HEIGHT sway/fade; vertex-alpha
sway is unavailable while the atlas is installed.

## Batches

```c3
Transform[3] transforms = { left, middle, right };
Vec4[1] colors = { { 1, 0.2f, 0.2f, 1 } };
Node* trio = scene.add_instanced_mesh(
    geometry:   cube,
    material:   white,
    capacity:   16,
    transforms: transforms[..],
    colors:     colors[..],
    name:       "trio",
)!;
```

`add_instanced_mesh` allocates `transforms` and `colors` once, at `capacity`, from the scene allocator, and copies the slices in. Instances live in `[0, count)`. Colors past the given slice start white. The node's world matrix applies to every instance: an instance's model matrix is `node.world * transforms[i].to_mat4()`.

Edit elements in place, then mark the batch before the `render_view` that should show the edit:

```c3
InstancedMesh* batch = scene.get(trio, InstancedMesh);
batch.transforms[1].position.y = height;
batch.colors[2] = { 0.2f, 0.4f, 1, 1 };
scene.mark_instances_dirty(trio);
```

The drawn records change only through `mark_instances_dirty`, `set_instances` or `resize_instances`; each advances `InstancedMesh.revision`, which is never 0 and is compared for equality only. An unmarked edit is not drawn, with no fault and no message. The batch bound that extraction, shadows and picking use, the mirrored count and view history also follow the revision, so an unmarked edit moves none of them. Tracing and picking's per-instance tests read the arrays at once, so an unmarked edit does move traces and per-instance picks. A mark after `render_view` takes effect in the next frame.

Change the count with `resize_instances(node, count)`, which fills new slots with the identity transform and white, or replace the live instances with `set_instances(node, transforms, colors)`. Neither allocates; past the capacity both fault `CAPACITY_EXCEEDED`. A color slice longer than the transform slice is `INVALID_ARGUMENT`. Removing the node frees both arrays and never the assets.

The instance index is the array position. It is not a generational identity: it moves when the application reorders or resizes.

## Drawing

- **Culling.** Extraction culls the batch as a whole against the bound of all live instances, or `local_bounds` when `has_bounds_override` is set; [instance culling](#instance-culling) then culls each instance on the GPU. The bound of all live instances is kept node-local on the batch (`InstancedMesh.aggregate`, written by the library). It is computed once per revision and geometry revision, and transformed by the node's world each frame; the batch's [sway](#sway-and-distance-fade) then grows the world box by its reach along each axis, for computed and override bounds alike. Under a rotated node it is the box of that box, looser than a per-instance merge, and the looseness grows with the batch's extent: for a batch about 5.7 units long under a node turned 45 degrees, the shadow cascade's depth range grew by up to 1.3%. `cast_shadow` and `receive_shadow` apply to every instance.
- **Indirect draws.** Every batch draws through one indirect command per parity range and pass, `draw_count` 1 and first instance 0; plain meshes draw directly. An unculled range's arguments are written by the CPU into the frame upload ring (20 bytes indexed, 16 non-indexed, 32 with alignment); a culled range's are written by the cull pass. `Stats.indirect_draws` counts these draws across every pass, the velocity pass included.
- **Mirrored instances.** A transform whose scale product is negative mirrors space. The renderer packs non-mirrored instances first and draws each group with its own front face, so a batch holding both makes two draws per pass.
- **Color.** The instance color multiplies the vertex color, alpha included, in every built-in material. A masked material cuts per instance, and its shadow matches.
- **Motion blur and TAA.** Each instance moves by its own previous matrix, kept per view while the batch's live count stays the same; after a count change the batch node's motion applies for one rendering. The view keeps node-local matrices and rewrites them only when the batch's revision changes. A batch at rest, or one whose node moves without an edit, draws through the node's motion, with no per-instance work and no upload; at rest its velocity is exactly zero when its sway is off, or has frequency 0 and unchanged parameters. A swaying batch's velocity comes from the sway the view last drew it with, at the view's previous time. In the frame of an edit the renderer uploads 64 bytes per instance. A batch marked every frame (an animated batch, a crowd part) pays that every frame, so a large batch that must stay cheap is edited rarely.
- **Materials.** Opaque, masked and blended materials draw. A blended batch draws its instances back to front in each view ([Blended batches](#blended-batches)) and does not cast shadows.
- **Deformation.** Instances draw the rest pose of the geometry, apart from the built-in [sway and fade](#sway-and-distance-fade); skinning and morph targets are not applied.

The renderer keeps each batch's instance records in its own GPU memory, 128 bytes per instance of capacity, and shares them across every view and shadow layer. It uploads them when the batch's revision or its node's world matrix changes, or its capacity grows; a batch at rest uploads nothing. `Stats.uploads` and `Stats.upload_bytes` count these uploads. `Stats.instances` counts the instances of unlisted ranges across passes; `Stats.triangles` counts each of those instances' triangles. Listed ranges, culled or blended, report through the culling fields below.

Records are world-space, so a batch whose node moves re-uploads every record in that frame: a batch of 100,000 instances under a moving node uploads 12.8 MB per frame. For a large batch that must stay resident, move the instances and keep the node at rest.

`RendererDesc.max_instance_batches` (default 1024) bounds the batch nodes holding records: live ones plus those unresolved within the last `INSTANCE_ABSENCE_FRAMES` frames. Past it, `render_view` faults `CAPACITY_EXCEEDED`. A batch not drawn by any view or shadow layer for more than `INSTANCE_ABSENCE_FRAMES` frames (hidden, culled, wholly past its [fade band](#sway-and-distance-fade), removed) releases its records and uploads them again on its next draw. Shadow layers draw a shadow-casting batch whether or not a view sees it, so such a batch keeps its records while a shadow-casting light is on, unless it lies wholly past its fade band.

## Instance culling

`ViewDesc.instance_culling`, on in `default_view_desc` and `texture_view_desc`, culls every instance of a batch against the frustum on the GPU before it is drawn. The view's shadow layers and depth prepass follow the flag of the view that renders them. Culling is frustum only: no occlusion, no level of detail.

- **Passes.** Each culling pass runs one compute dispatch per listed range: the view (with its uploads, before its shadow atlas and passes), its depth prepass, and all of its shadow layers in one stage before the shadow atlas. The velocity pass and the forward and deferred passes of a view read the view's ranges and dispatch nothing. `Pass.INSTANCE_CULL` times the dispatches. `Pass.INSTANCE_SORT` times the sort steps of [blended batches](#blended-batches), which run in the view's culling pass only, after its cull dispatches.
- **Bounds.** An instance is tested as the eight corners of a local box under its world matrix against each plane, which is tighter than the world box extraction tests. The local box is the geometry bound for a plain batch and the crowd's `pose_bounds` for a crowd part. A batch with `has_bounds_override` that is not a crowd part is drawn unculled: its override bounds the batch, not one instance. A blended one still lists every instance, through open planes. A swaying batch widens each plane by its sway amplitude, and a fading batch drops the instances whose collapse is complete.
- **Index space.** A culled range draws `gl_InstanceIndex` over its visible list; on a blended range it is the draw rank, 0 farthest. Built-in stages and `write_mesh_outputs` map it back with `instance_source(draw)`; a custom instanced vertex stage that reads per-instance data itself must do the same ([Custom shaders](custom_shaders.md)).
- **Memory.** Each frame slot owns one device-local arena of `RendererDesc.instance_cull_bytes` (default `INSTANCE_CULL_ARENA_BYTES`, 16 MiB), so culling reserves `FRAMES_IN_FLIGHT x instance_cull_bytes` of device memory once the first range is listed, which a blended batch does with culling off too. A culling pass first places one 32-byte indirect command per listed range, then each range's visible list of 4 bytes per instance; a blended range's list is followed by its sort keys, `8 * pow2(n)` bytes for `n` instances. List and keys are placed all or nothing per range; a range whose list does not fit keeps its unused command slot, and a stage whose commands do not fit sends every listed range to the fallback. A range that does not fit is drawn unculled and counted in `Stats.cull_overflows` (`Stats.sort_overflows` for a blended range); nothing faults. `instancing` at 99,856 instances uses about 400 KB per culling pass; a blended range of 100,000 instances takes 1,448,608 B per view and frame slot.
- **Turning it off.** `instance_culling = false` restores the CPU-written arguments and draws every instance of opaque and masked batches. Blended ranges still list, with open planes, and sort.

Cost model. GPU work grows with instances tested: one invocation per instance per culling pass. CPU recording grows with listed ranges times culling passes: a 352-byte root and one dispatch each, plus one barrier per pass. A blended range adds one 40-byte root and dispatch per sort step, and the view one barrier per step round. `instancing` culls 3 ranges (two trio parities and the props) in up to 6 passes (four shadow cascades, the depth prepass, the view): 16 to 18 dispatches as the trio enters and leaves cascades; its glass cloud adds one listed range to the view and 15 sort steps. 300 batches with one range each in 6 passes would record about 1,800. Culling on against culling off at one count, 99,856 instances, WSL llvmpipe (frame counts are environment only): `cpu_record` median 23.54 ms culled against 23.41 ms unculled before the aggregate and history below, and 26 frames against 13 in the same six seconds. 170,818 of 599,151 instances were visible across passes.

Recording against instance count, one build with the grid size as the only difference, culling on, host CPU, 12-second runs:

| Props | Non-temporal `cpu_record` | Temporal `cpu_record` | Temporal ring bytes |
| --- | --- | --- | --- |
| 1,024 | 0.539 ms | 0.629 ms | 68,824 |
| 10,000 | 0.532 ms | 0.615 ms | 69,000 |
| 99,856 | 0.535 ms | 0.620 ms | 69,288 |

Before the kept aggregate and the stamped history, the same runs took 0.786, 2.850 and 23.803 ms (non-temporal) and 0.957, 3.698 and 30.903 ms (temporal, with 6.46 MB of previous matrices per frame at 99,856).

"Flat" covers a batch at rest in views that do not trace. These still walk every instance: a batch with `trace` set in a view that traces (the trace instance list), a batch whose node moves (its world-space records re-upload, 128 bytes per instance: 16.0 ms and 12.8 MB at 99,856), a batch marked every frame, and picking, per call.

| `Stats` field | Frame | Meaning |
| --- | --- | --- |
| `cull_dispatches` | This frame | Listed ranges (culled or blended) dispatched, summed over culling passes |
| `cull_overflows` | This frame | Ranges drawn unculled because the arena was full |
| `sort_dispatches` | This frame | Sort steps dispatched, summed over blended ranges |
| `sort_overflows` | This frame | Blended ranges drawn unsorted and unculled because they did not fit |
| `instances_tested` | Read back, `FRAMES_IN_FLIGHT` frames late | Instances of listed ranges, summed over culling passes |
| `instances_visible` | Same frame as `instances_tested` | Instances that survived, faded ones excluded; never above `instances_tested` |
| `indirect_draws` | This frame | Unchanged: culled and unculled ranges alike |
| `batches_faded` | This frame | View batches inside the frustum and wholly past their [fade band](#sway-and-distance-fade); they list no range and record no draw |

`instances_tested` and `instances_visible` describe one earlier frame together and count listed ranges only; an aborted frame reports nothing. `stats_panel` shows them as a percentage.

### Blended batches

A batch whose material has `alpha_mode == BLEND` draws its instances back to front in every view, inside the batch, with no per-instance CPU work and with the records still shared across views. The cull pass writes a 64-bit key beside each visible index: the view depth of the instance's box center under its world matrix, then its storage index. The box is the cull bound (the geometry bound, or the crowd's `pose_bounds`), or the geometry bound under `has_bounds_override`. A fixed plan of bitonic compute steps then sorts the keys and rewrites the visible list far to near; equal depths keep storage order, which holds from frame to frame.

- **Automatic.** Every blended range lists, in every draw list, with or without instance culling and with `has_bounds_override`: a range the view does not cull runs the cull pass with open planes, so every instance survives and gets a key, and a fading batch still drops its fully collapsed instances. Opaque and masked ranges never sort; the depth prepass, shadow layers and the velocity pass never draw a blended range.
- **Order across draws.** Each parity range sorts on its own, the unmirrored range first. The batch orders as one unit among other blended draws by its bound center ([Materials](materials.md)); its instances do not interleave with other blended objects. The key point ignores sway and custom vertex displacement.
- **Steps.** The plan is sized by the range's instance count, not its visible count: 1 step up to 1,024 instances, 10 at 8,192, 15 at 16,384, 36 at 131,072 and 78 at `MAX_SORTED_INSTANCES` (2,097,152). Each step is one dispatch; the view's sorted ranges step together, one barrier per step round.
- **Memory.** A sorted range of `n` instances takes `32 + align8(4n) + 8 * pow2(n)` bytes of the arena: 1,448,608 B at 100,000, per view and frame slot.
- **Overflow.** A range above `MAX_SORTED_INSTANCES`, or whose list and keys do not fit the arena, draws unsorted and unculled from CPU arguments and counts in `Stats.sort_overflows`; nothing faults.
- **Stats.** A blended range reports through the culling fields with culling on or off: it adds to `cull_dispatches`, `instances_tested` and `instances_visible`, and not to `Stats.instances` or `Stats.triangles`. With culling off, a blended batch still reserves the cull arena.
- **Cost.** Measured on an RTX 4090 (driver 610.88) with `instancing`'s glass cloud, validation on, medians of three interleaved runs:

| Glass cubes | Sort steps | `INSTANCE_SORT` 1280 × 720 (ms) | `INSTANCE_SORT` 2560 × 1440 (ms) | `FORWARD_TRANSPARENT` 1280 × 720 (ms) |
| --- | --- | --- | --- | --- |
| 10,648 | 15 | 0.068 | 0.162 | 0.042 |
| 103,823 | 36 | 0.135 | 0.199 | 0.259 |

  At 10,648 cubes one of the three 720p runs read 0.192 ms. The sort's work does not depend on the resolution; the small cloud's 1440p reading (0.162 ms) is above its 720p one for a reason not isolated here, and above the 0.10 ms the sort was planned to stay under at that count. Showing the cloud adds to `cpu_record` 0.008 ms at 10,648 and 0.021 ms at 103,823 without validation, and 0.053 and 0.113 ms with it: the validation layer's per-dispatch cost is most of the recording cost of the sort steps. `INSTANCE_SORT_BLOCK` (1,024 keys, 8 KiB of shared memory per group) sets the step count: 2,048 (16 KiB) would take 16,384 instances in 10 steps instead of 15. It stays at 1,024 until a measured workload asks for the change.

## Sway and distance fade

```c3
InstancedMesh* grass = scene.get(grass_node, InstancedMesh);
grass.sway = {
    .direction  = { 1, 0, 0.4f },
    .amplitude  = 0.15f,
    .frequency  = 0.8f,
    .lean       = 0.3f,
    .wavelength = 6,
    .variation  = 0.25f,
    .weight     = SwayWeight.VERTEX_ALPHA,
};
grass.fade = { .start = 30, .end = 60 };
```

`InstancedMesh.sway` bends a batch's vertices along one world direction; `InstancedMesh.fade` collapses its instances over a band of camera distance. Both are values read by every `render_view`, like `cast_shadow`: an edit needs no mark, uploads no record and leaves the aggregate alone. Zero values, the `add_instanced_mesh` default, are off and draw as a batch without them. A scene-wide wind is the application's value, copied into its batches. Extraction checks the fields' contract (`InstancedMesh.validate_effects`): finite, non-negative amplitude, frequency, wavelength and variation, `lean` in [0, 1], a non-zero direction when the amplitude is above zero, and `0 <= start < end` when `end` is set.

- **Motion.** A vertex moves by `direction * amplitude * weight * (lean + (1 - lean) * swing)` in world space, after the instance matrix. `lean` is the share of the amplitude held as a steady bend downwind; `swing` sums two sines of one phase and never exceeds 1 in size, so no vertex moves further than `amplitude`. The phase advances `frequency` cycles per second of `FrameInfo.time`, computed on the CPU in double precision; gust crests travel along the direction `wavelength` world units apart (0 keeps the batch in phase); `variation` spreads the phase over the instances. An instance's seed hashes its node-local position, so it holds under node motion and reordering. A `frequency` edit moves the phase at once. `FrameInfo` time 0, the `begin_frame` default, holds the sway still.
- **Weight.** `SwayWeight.HEIGHT`, the default, weighs a vertex by the square of its height within the instance-local bound, so the base stays planted; it assumes +Y up in geometry space, and a flat bound does not sway. `SwayWeight.VERTEX_ALPHA` takes the vertex colour's alpha as the weight and consumes it: shading, masking, the depth prepass and shadows see vertex alpha 1, so the alpha no longer cuts a masked material. A geometry without colours then weighs 1 everywhere and sways rigidly. A custom vertex stage supplies any weight by writing `vertex.color.a` and selecting `VERTEX_ALPHA` ([Custom shaders](custom_shaders.md#vertex-contract)).
- **Fade.** Each instance collapses toward the base centre of its local bound once the view camera's distance to that point crosses the instance's vanish distance, hashed from its seed across the band: the first instances shrink from `start`, none is drawn past `end`, and one instance takes a quarter of the band (`FADE_COLLAPSE_SHARE`) to collapse. An instance before the band draws exactly as without fade. The cull pass drops fully collapsed instances, so they leave `instances_visible`; on an opaque or masked batch with instance culling off or with `has_bounds_override`, collapsed instances still run the vertex stage as degenerate triangles. Extraction skips a batch whose bound lies wholly past `end` from the view camera, in the view and in its shadow layers alike: every anchor lies inside the bound and no vanish distance exceeds `end`, so none of its instances would draw. A skipped batch records no root, dispatch or draw; `Stats.batches_faded` counts the view's skipped batches inside the frustum.
- **Passes.** The view's passes, its depth prepass and its shadow layers read one block per batch, so shadows sway with the batch and fade from the view's camera, not the light's. The depth prepass, forward and velocity passes compute identical positions, so their `EQUAL` depth tests hold.
- **Bounds.** The batch bound grows by the sway reach, `|normalize(direction)| * amplitude` per axis, after the node transform; the per-instance cull test admits a box within `amplitude` of each plane. The collapse moves toward a point inside both.
- **Motion vectors.** The velocity pass uses the sway the view last drew the batch with, at the view's previous time, so a batch whose sway parameters change every frame keeps exact motion. A view without history uses the current sway for both. The collapse carries no motion vector. A batch the view skipped past the band has no history there: in the rendering that brings it back it draws without object motion, while its instances are still collapsed at the far edge of the band.
- **Cost.** One 112-byte block per batch and view in the frame upload ring, and the seed written into `InstanceGpu.normal_0.w` whenever records upload; no per-instance CPU work per frame. The seed adds about 25 ns per record to a re-pack: 2.5 ms (+19 %) for a full re-pack of 99,856 records, paid only on frames that re-pack a batch. Measured below.
- **Limits.** Picking's per-instance tests, CPU triangle trees and the scene trace (ray-traced shadows, reflections, ambient occlusion, path tracing, probe traces) see the rest pose and every instance; a swaying batch traces at its rest pose and casts a still traced shadow; `Stats.trace_sway_at_rest` counts such batches, the error is bounded by the sway reach, and `trace = false` keeps the batch out ([scene trace](scene_trace.md#what-traces)). Picking's broad phase uses the grown bound. Normals and tangents are not bent. Amplitude neither varies per instance nor scales with it. No fade for plain meshes, no per-view opt-out (a minimap fades from its own camera), no dithered or alpha fade, and no weight from `Geometry.custom_data`.

Measured on an RTX 4090 (driver 610.88), `instancing` at 99,856 props, 1280 × 720, instance culling and motion blur on, 12-second runs; medians in ms, each the median of three interleaved runs:

| Configuration | Depth prepass | Forward opaque | Shadow atlas | Instance cull | Velocity | `cpu_record` |
| --- | --- | --- | --- | --- | --- | --- |
| Before sway and fade | 0.0881 | 0.1782 | 0.6160 | 0.0632 | 0.1065 | 1.433 |
| Sway and fade off | 0.0884 | 0.1782 | 0.6169 | 0.0640 | 0.1075 | 1.433 |
| Sway on | 0.0887 | 0.1802 | 0.6097 | 0.0667 | 0.1075 | 1.433 |
| Sway and fade on | 0.0444 | 0.1116 | 0.3357 | 0.0719 | 0.0461 | 1.456 |

Off costs nothing measurable: every pass is within 1.3 % of the build before sway and fade. With fade on, 43,346 of 599,154 instances stay visible across passes (7.2 %), against 170,818 of 599,151 without it, and the passes after culling shrink with them. The `view.resolve` scope of a frame that re-packs all props rises from 12.74 ms (12.69–13.11) to 15.21 ms (15.07–15.35). The third runs of "Sway and fade on" and of the re-pack before the change hit a lower GPU clock state; those two medians use the steady runs.

Skipping batches wholly past the band, measured on an RTX 4090 (driver 610.88) with `instancing --benchmark`, 1280 × 720,
three repeats; medians in ms with the range across repeats. `--fade-field` adds 4,096 cell batches of 64 props, most of
them past a 60–90 m band:

| `--fade-field` | Before | After |
| --- | ---: | ---: |
| `cpu_record` | 2.821 (2.815–2.989) | 0.260 (0.255–0.265) |
| Instance cull | 0.290 (0.289–0.291) | 0.048 (0.047–0.048) |
| Depth prepass | 0.061 | 0.047 |
| Forward opaque | 0.094 | 0.078 |
| Shadow atlas | 0.247 | 0.234 |
| Velocity | 0.063 | 0.053 |
| Draws | 2,957 | 137 |
| `batches_faded` | — | 926 |

Without the field every pass is within noise (`cpu_record` 0.092 before, 0.082 after; the GPU passes within 1 %).

The shared mesh/billboard kind branch adds about 1–2 microseconds to mesh
`INSTANCE_CULL` on an RTX 4090 (driver 610.88), at 2560 × 1440. The
[billboard review measurements](https://github.com/fesoliveira014/c3d.c3l/pull/189#discussion_r4151646830)
compare `69e060d` with `726bca4`, using medians of three runs:
`instancing --benchmark` rose from 0.0449 to 0.0457 ms, `--fade-field` from
0.0544 to 0.0557 ms, and stationary vegetation from 0.0750 to 0.0761 ms.
Other passes were unchanged within the measured spread. This cost does not
justify a separate mesh culling variant.

## Custom vertex stages

A custom material whose shader has a vertex stage draws a batch only when the shader also supplies the instanced pair, `CustomVertex.instanced_shaded` and `instanced_depth`: the same source compiled with `INSTANCED`, and with `DEPTH_ONLY` and `INSTANCED`. A stage that ends in `write_mesh_outputs` needs no source change, and it inherits the batch's sway and fade; instanced SPIR-V built against an older `mesh_vertex.glsl` draws without them until it is rebuilt. Without the pair the batch is skipped and counted in `Stats.dangling_refs`. The published revision's pair draws; a batch whose pair exists only in a rejected replacement is skipped without a count (see [Reload](custom_shaders.md#reload)). `CustomVertex.instanced_velocity`, the same source compiled with `VELOCITY` and `INSTANCED`, is optional and needs the instanced pair and `velocity` (see [Velocity form](custom_shaders.md#velocity-form)); without it a batch's velocity uses the built-in instanced variant and sees the undisplaced instances. Fragment-only custom materials draw batches unchanged.

## Picking

`spatial::pick` tests a batch's aggregate bound, then each live instance. A hit carries the batch node, `instanced = true` and `instance_index`.

Example: `python3 scripts/build.py --example instancing`. `--fade-field` adds 4,096 fading cell batches around the scene and the stats panel shows `Faded batches`; `--gpu-timings` needs the profile add-on; `--benchmark` runs the headless benchmark ([Benchmarking](benchmarking.md#instancing-benchmark)).

## Crowds

A crowd draws many animated copies of one skinned model, each instance with its own clip, time and
speed, in one draw per skinned part per parity per pass.

```c3
Node* crowd = model::add_crowd(
    assets:      &assets,
    scene:       &scene,
    model:       character,
    capacity:    512,
    pose_bounds: pose_bounds,
    instances:   instances[..],
)!;

while (window.poll()) {
    anim::crowd_update(&assets, &scene, window.clock.delta);
    scene.update_world();
    // render
}
```

- `add_crowd` covers every skin of the template that shares one skeleton and joint list; it faults
  `INVALID_ARGUMENT` for a template without skins, skins on different skeletons, more instances than
  `capacity`, or an instance clip the template does not own. It creates the crowd node, which carries
  `AnimatedCrowd`, and one child `InstancedMesh` node per skinned part: one scene node plus one per part.
  Meshes without a skin (a rigid prop) are not drawn; `template.meshes.len - crowd.parts.len` of them
  are left out.
- Each `CrowdInstance` has a placement, a `CrowdPose` (`clip`, `time`, `speed`, `loop`) and a tint.
  `set_crowd` replaces them and the live count for every part at once.
- `crowd_update` advances every pose (loop wraps, otherwise the time clamps), samples its clip into one
  model-space palette per instance, writes the placements into every part batch and bounds each batch
  by `pose_bounds` under every placement. Poses are independent: no blending, fading or retargeting per
  instance; a character that needs those is an `Animator` instance.
- `pose_bounds` is instance-local and must cover every pose of one instance; culling and shadow fitting
  use nothing else.
- Part nodes keep an identity local transform and are removed only by removing the crowd node, which
  removes them with it. The crowd's model must stay in the store while the crowd lives.
- Every part reads the same palettes: all parts share the placements, so they pack instances in the
  same parity order. Morph weights are per instance and per part.
- `crowd_update` marks every part batch, so part records upload every frame (128 bytes per instance
  per part).
- The renderer uploads one palette array per crowd per frame (`joints * 64` bytes per instance) and
  reuses it for every part, view and shadow layer. Above `OVERSIZED_UPLOAD_BYTES` (8 MiB, about 2470
  instances of a 53-joint character) the upload takes dedicated overflow memory every frame.
- Crowds never enter the ray tracing paths (shadows, ambient occlusion, reflections, path tracing),
  whatever `InstancedMesh.trace` says; raster shadows and temporal views work. This is the limit plain
  skinned meshes have.
- Custom materials: a fragment-only custom material draws with the built-in skinned instanced stage. A
  custom instanced vertex pair skins a crowd when compiled with the deformation defines
  ([Custom shaders](custom_shaders.md)).

Example: `python3 scripts/build.py --example skinned_crowd` walks 512 instances of the committed Quaternius
character through six of its clips; `B` switches to 512 `Animator` instances of the same model for
comparison, `--baseline` starts there.
