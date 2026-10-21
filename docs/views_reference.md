# Views reference

Reference tables for [views and render targets](views.md): every `ViewDesc` field, the faults of view creation,
renderer capacities and how to size them, the images each setting allocates, the per-view counters, and the camera
values vertex stages read. Everything is in `c3d::render`.

## ViewDesc

Both constructors fill the defaults below. `default_view_desc()` is a full-window `DISPLAY_LDR` view.
`texture_view_desc(target, color = LINEAR_HDR)` covers a target with the same defaults, except `color`. A
zero-initialized `ViewDesc` has none of them: start from a constructor.

| Field | Default | Meaning |
| --- | --- | --- |
| `output` | `WINDOW` / `TEXTURE` | `WINDOW` or `TEXTURE` |
| `target` | none | The `RenderTargetId` a `TEXTURE` view writes; ignored for `WINDOW` |
| `viewport` | zero (whole output) | `PixelRect` in output pixels; a zero extent covers the whole output |
| `render_scale` | 1 | Working resolution relative to the viewport, in `(0, MAX_RENDER_SCALE]` (2.0) |
| `lod_bias` | 0 | Finite log2 bias for [whole-object LOD](lod.md); positive adds detail |
| `color` | `DISPLAY_LDR` / `LINEAR_HDR` | `DISPLAY_LDR` runs the display route; `LINEAR_HDR` keeps scene-linear color in physical units whatever the view's [pre-exposure](post.md#pre-exposure) |
| `post` | `default_post_stack()` | The view's `PostStack` ([post-processing](post.md)); FXAA is on |
| `shading` | `FORWARD` | `FORWARD`, `DEFERRED` ([shading paths](shading_paths.md)) or `PATH_TRACED` ([path tracing](path_tracing.md)) |
| `depth_prepass` | true | A `FORWARD` view draws its opaque set into depth first and shades it once |
| `instance_culling` | true | Batch instances are culled per instance on the GPU in this view, its prepass and its shadow layers ([instancing](instancing.md#instance-culling)) |
| `lights` | `FLAT` | `FLAT` or `CLUSTERED` candidate light selection ([lights](lights.md)) |
| `clusters` | `default_cluster_desc()` | Editable `ClusterDesc`; ignored by `FLAT` |
| `ray_tracing` | see below | `RayTracingDesc`; zero disables all |
| `ambient_occlusion` | zero (off) | `AmbientOcclusionDesc` ([ambient occlusion](ambient_occlusion.md)) |
| `screen_space_gi` | zero (off) | `ScreenSpaceGiDesc` ([screen-space GI](screen_space_gi.md)) |
| `path_trace` | `PATH_TRACE_DEFAULT` | `PathTraceDesc`: bounces, samples per frame and sample cap of a `PATH_TRACED` view |
| `clip_plane` | zero plane | World-space `maths::Plane`; geometry on its negative side is not drawn ([clip plane](views.md#clip-plane)) |
| `volumetric_fog` | false | A froxel volume for the view's `HeightFog`, allocated with the view ([volumetric fog](fog.md#volumetric-fog)) |
| `fog_quality` | `MEDIUM` (the zero value) | `FogQuality` of the fog volume: `LOW`, `MEDIUM` or `HIGH`; a change reallocates the volume |
| `fog_temporal` | false | Accumulates the fog volume over frames ([temporal accumulation](fog.md#temporal-accumulation)); needs `volumetric_fog`; keeps a second volume |
| `cloud_temporal` | false | Accumulates the cloud layer over frames ([cloud temporal accumulation](clouds.md#cloud-temporal-accumulation)); keeps a second pair of cloud images |
| `share_shadows` | true | Binds an earlier view's [shadow set](shadows.md#shadow-sets) when the keys match and publishes its own |
| `transmission_layers` | 0 (reads 1) | Scene-read snapshots, so glass can see glass behind it ([transmission layers](materials.md#transmission-layers)); up to `MAX_TRANSMISSION_LAYERS` (4) |
| `transparency` | `SORTED` | `SORTED` orders blended surfaces by object; `WEIGHTED` accumulates them without ordering ([weighted transparency](materials.md#weighted-transparency)) |
| `pre_exposure_override` | 0 (follow the camera) | Forces the view's [pre-exposure](post.md#pre-exposure) factor, a power of two from 2^-16 to 2^16 |
| `msaa` | `ONE` (off) | `MsaaSamples`: samples per pixel of the opaque scene passes ([MSAA](msaa.md)) |

`RayTracingDesc`:

| Field | Default | Meaning |
| --- | --- | --- |
| `shadows` | false | Ray-traced shadows ([ray-traced shadows](ray_traced_shadows.md)) |
| `shadow_samples` | 0 (reads 1) | Rays per pixel toward a light with a source extent, up to `MAX_SHADOW_SAMPLES` (16) |
| `reflections` | false | Ray-traced reflections ([reflections](reflections.md)) |
| `max_reflection_roughness` | `RT_REFLECTION_ROUGHNESS_DEFAULT` (0.5) | Roughest surface that traces; in `(0, 1]` when `reflections` is set |
| `reflection_rays` | 0 (reads 1) | Rays per pixel, up to `RT_REFLECTION_RAYS_MAX` (4) |
| `reflection_resolution` | `FULL` | `FULL` or `HALF` extent the rays are cast at |
| `reflection_history` | false | Accumulates the traced reflection; keeps two history and depth images |

## Faults

`create_view` and `configure_view` validate the description between frames. A fault changes nothing.

| Condition | Fault |
| --- | --- |
| Dead view (`configure_view`, `destroy_view`), dead `target` or dead `post.grade.lut` | `c3d::INVALID_ID` |
| `LINEAR_HDR` on a window view or on an RGBA8 target | `c3d::INVALID_ARGUMENT` |
| Viewport outside the output, `render_scale` outside its range, non-finite `lod_bias`, invalid `post` stack or a LUT whose descriptor is invalid | `c3d::INVALID_ARGUMENT` |
| `clip_plane` other than the zero plane with a normal that is not unit length or a `d` that is not finite | `c3d::INVALID_ARGUMENT` |
| `transmission_layers` above `MAX_TRANSMISSION_LAYERS`, `shadow_samples` above `MAX_SHADOW_SAMPLES` | `c3d::INVALID_ARGUMENT` |
| `pre_exposure_override` other than zero or a power of two in range | `c3d::INVALID_ARGUMENT` |
| Invalid ambient occlusion or screen-space GI settings, including a `ray_count` outside its range | `c3d::INVALID_ARGUMENT` |
| `reflections` with `max_reflection_roughness` outside `(0, 1]` or `reflection_rays` above the maximum | `c3d::INVALID_ARGUMENT` |
| `msaa` above `ONE` with `TAA` or on a `PATH_TRACED` view | `c3d::INVALID_ARGUMENT` |
| `msaa` count the device cannot create, or `DEFERRED` with `msaa` on a device without sample-rate shading | `c3d::UNSUPPORTED` |
| `CLUSTERED` with zero dimensions or capacity, a non-positive or non-finite `far_distance`, or unrepresentable sizes | `c3d::INVALID_ARGUMENT` |
| `CLUSTERED` with a grid beyond the device's compute dispatch limits | `c3d::UNSUPPORTED` |
| `reflections` on a `PATH_TRACED` view; a `PATH_TRACED` view on a device without ray-tracing pipelines | `c3d::UNSUPPORTED` |
| `PATH_TRACED` with `TAA`, motion blur, depth of field, ambient occlusion, `ray_tracing.shadows`, `CLUSTERED`, screen-space GI, a non-zero `clip_plane`, `volumetric_fog` or an invalid `path_trace` | `c3d::INVALID_ARGUMENT` |
| A full view pool | `c3d::CAPACITY_EXCEEDED` |
| `destroy_view` on the default view | `c3d::INVALID_ARGUMENT` |

Image allocation faults come from gpu.c3l: a full texture, attachment, allocation or acceleration structure table
faults `gpu::SLOT_TABLE_FULL`, a full heap `gpu::DESCRIPTOR_HEAP_FULL`, and exhausted memory the
`gpu::OUT_OF_*_MEMORY` faults. `create_view`, `create_render_target`, `render_to`, `bake_impostor` and the reflection
captures release what they acquired on a fault. `render_view` and `finish_view` can fault for the images they
allocate, and the frame aborts.

## Capacities

| `RendererDesc` field | Zero selects | Bound |
| --- | --- | --- |
| `max_views` | `DEFAULT_MAX_VIEWS`, 8 | Memory only |
| `max_render_targets` | `DEFAULT_MAX_RENDER_TARGETS`, 8 | At most the resolved `texture_capacity`, else `create_renderer` faults `c3d::INVALID_ARGUMENT` |
| `max_posed_trace_instances` | `DEFAULT_MAX_POSED_TRACE_INSTANCES`, 64 | See below |
| `texture_capacity` | `gpu::DEFAULT_TEXTURE_CAPACITY`, 1,024 | 65,536 (`gpu::MAX_SHADER_HEAP_CAPACITY`), else `gpu::INVALID_ARGUMENT` |
| `texture_heap_capacity` | `gpu::DEFAULT_TEXTURE_HEAP_CAPACITY`, 4,096 | 65,536, else `gpu::INVALID_ARGUMENT`; past the device's descriptor limits no adapter qualifies and `create_renderer` faults `c3d::UNSUPPORTED` |

`max_posed_trace_instances`: `2 * max_posed_trace_instances + 32 + 16 * max_views` must fit the device's allocation
table (4,096 entries) and, with ray queries or ray-tracing pipelines, `max_posed_trace_instances + 32` its
acceleration structure table (4,096 entries), else `create_renderer` faults `c3d::INVALID_ARGUMENT`. The limit is
1,968 at the default 8 views. Content shares both tables uncounted and can still fault `gpu::SLOT_TABLE_FULL`
mid-frame ([scene trace](scene_trace_reference.md#posed-instances)). A slot holds a mesh's posed streams, a node copy and a
bottom level.

The pools are fixed at creation. A full pool faults `c3d::CAPACITY_EXCEEDED`. These take a view slot:

- the default view, from creation to teardown;
- every `create_view`;
- `render_to`, for the length of the call;
- `bake_impostor`, `capture_reflection_probe` and `recapture_reflection_probe`, for the length of the call. Each also
  takes one render-target slot.

An editor with a game view, two viewports and live thumbnails drawn through `render_to` needs `max_views` of at
least 1 + 1 + 2 + 1.

### Table and heap slots

Every working image of a view and every render target holds one texture-table entry and one heap slot, except a
view's attachment-only multisample images, `msaa_color` and a forward view's `msaa_depth`, which hold no heap slot. A
hierarchical GI depth pyramid also holds one single-level view and heap slot per mip, in addition to its full-chain
view.

A render target also holds one attachment view, and so do a view's `hdr_color`, `depth`, scene snapshots, weighted
accumulation and revealage, velocity, G-buffer and SSGI color: at most 13 per view, and at most 7 more for the
multisample images, sample-0 copies and edge mask. gpu.c3l's attachment table holds 4,096 views and cannot be
configured, so a renderer with three plain views holds at most 4,090 render targets whatever `texture_capacity`
allows.

Asset textures share the table and the heap with the renderer. `default_asset_store_desc()` holds 4,096 textures and
the table 1,024 by default, so a store filled past about 1,000 uploaded textures faults on upload unless
`texture_capacity` is raised. A mipmapped or storage asset texture can hold several heap slots, so size
`texture_heap_capacity` from `Stats.texture_views`, not from the texture count.

`resize_render_target`, `configure_view` and the window resize in `begin_frame` allocate every new image before they
release an old one, so a fault changes nothing. They need room for the old and the new images at once, and near
capacity they fault where releasing first would have fit. Leave room for the largest single resize in the texture
table, the heap and the attachment table: a target plus the images of every view on it for `resize_render_target`, the
images of every window view for a window resize, or one view's full image set for `configure_view`.

Per-frame cost grows with `max_render_targets`: `begin_frame` and each view's preparation visit every target slot,
and `begin_frame` also visits every view slot to snapshot and count its images.

### Images per setting

Images a view allocates at creation, by setting:

| Setting | Images |
| --- | --- |
| Raster view: `hdr_color`, `depth`, sky-view table, aerial perspective volume | 4 |
| `FXAA` (on in both constructors) | +1 |
| `TAA` | +6 history, +1 debug image with `TaaDebug` |
| `bloom` | +`bloom_params.levels` (5 by default, 8 at most) |
| `depth_of_field` | +4, plus the 2 tile images |
| `motion_blur` | +1, plus the 2 tile images |
| Velocity, under `TAA`, `motion_blur`, `screen_space_gi`, `ambient_occlusion.temporal` or `ray_tracing.reflection_history` | +1 |
| `DEFERRED` G-buffer | +5 |
| `msaa` above `ONE` | +2 (`msaa_color`, `msaa_depth`), +1 `msaa_velocity` where velocity is used; a `FORWARD` view adds +1 `msaa_reflection_gbuffer` with `ray_tracing.reflections` and +1 `msaa_proxy_skip` with ray-traced ambient occlusion; a `DEFERRED` view also holds its G-buffer at that count, adds +1 `msaa_edges`, +1 `normal_sample_zero` with ambient occlusion, screen-space GI or `ray_tracing.reflections`, +1 `specular_sample_zero` with `ray_tracing.reflections`, +1 `flags_sample_zero` with ray-traced ambient occlusion or `ray_tracing.reflections` |
| `ambient_occlusion` | +2: `ao_raw` and `ao`, `R8_UNORM`, or `RGBA8_UNORM` with `ambient_occlusion.bent_normals` |
| `ambient_occlusion` of kind `RAY_TRACED`, on a `FORWARD` view | +1: `proxy_skip`, `R32_UINT` |
| `ambient_occlusion.temporal` | +4: two history images, `R16_FLOAT` or `RGBA16_FLOAT` with `bent_normals`, and two depth images |
| `screen_space_gi` | +7 |
| Enabled `screen_space_gi` with `trace = HIERARCHICAL` | +1 full-resolution depth pyramid |
| `ray_tracing.reflections` | +2, and +1 on a `FORWARD` view |
| `ray_tracing.reflection_resolution` `HALF`, with `reflections` | +1 (`reflection_half`) |
| `ray_tracing.reflection_history`, with `reflections` | +4: two history and two depth images |
| `volumetric_fog` | +1, and +1 more with `fog_temporal`; the volume's size is in [volumetric fog](fog.md#volumetric-fog) |
| `PATH_TRACED`: accumulation, no sky images | 3 in all |

Other images allocate on the first frame that needs them: the weighted transparency accumulation and revealage
(`WEIGHTED` view with a participating draw, 10 bytes per working pixel in all), the cloud images of a visible cloud
layer, up to two scene snapshots when a material reads the scene (inside `render_view`), and the FXAA fallback
output when FXAA cannot write the output rectangle directly (inside `finish_view`). A headless renderer's default
view holds no images.

`texture_view_desc` and `default_view_desc` views hold 5 images.

### Sizing

Render representative frames until the next reading, at most `TEXTURE_STATS_INTERVAL` (16) frames, then read `Stats`
and `ViewStats`:

- `Stats.textures` and `texture_views` count live table entries and heap slots at frame start, and `texture_capacity`
  and `texture_heap_capacity` the resolved sizes. They are read every `TEXTURE_STATS_INTERVAL` frames, because a
  reading walks the texture table. Images created inside a frame show at the next reading.
- `ViewStats.images` counts one view's live images at frame start, every frame.
- `gui::stats_panel` shows the four `Stats` fields, `gui::view_stats_table` the images per view.

Worked example. A game view with `DEFERRED`, `TAA`, five bloom levels and `ambient_occlusion` holds 23 images
(4 + 6 + 1 + 5 + 5 + 2). The window view holds 5. Two editor viewports from `texture_view_desc` hold 5 each. A
`render_to` thumbnail holds 5 while it renders. The game view, the viewports and 64 thumbnails write 67 targets. That
is 110 entries and 110 heap slots. Add the uploaded asset textures and the renderer's own images (shadow atlas,
environment maps, atmosphere tables, built-in textures, probe volumes, reflection probes, swapchain images); read the
last amount from `Stats.textures` minus the views' and targets' share. With 2,000 asset textures the table needs
about 2,150 entries, so `texture_capacity = 2560` leaves headroom. The views need `max_views = 5` and the targets
`max_render_targets = 67` or more.

## Counters

`Renderer.view_stats(view)` returns `ViewStats`. `Stats` keeps renderer-wide sums and the last completed results.
`gui::view_stats_table(renderer, views, labels)` prints several views side by side.

| `ViewStats` field | Meaning |
| --- | --- |
| `images` | Live working images at frame start, scene snapshots included |
| `lights`, `lights_dropped` | Selected lights and budget drops of the last rendering |
| `decals`, `decals_dropped` | Selected decals and budget drops |
| `cluster_count`, `cluster_overflows`, `cluster_skipped`, `decal_overflows` | Completed cluster results ([lights](lights.md#diagnostics)) |
| `accumulated_samples` | Samples a `PATH_TRACED` view has accumulated |
| `shadow_set_shared` | The last raster rendering bound another view's [shadow set](shadows.md#shadow-sets) |
| `exposure` | Applied exposure multiplier; delayed under auto exposure; `LINEAR_HDR` applies none |
| `pre_exposure` | Radiance scale of the last rendering's stored images; 1 is physical |
| `focus_distance` | Applied depth-of-field focus in meters; delayed under [auto focus](post.md#auto-focus) |
| `gpu_pass_ms` | Completed GPU pass timings (`C3D_PROFILE_GPU`) |

| `Stats` field | Meaning |
| --- | --- |
| `lights`, `lights_dropped`, `decals`, `decals_dropped` | Sums over the frame's recorded views; reset at `begin_frame`. Hidden, culled and collapsed decals are not budget drops |
| `culled` | Meshes, batches and LOD groups outside a view's frustum or wholly behind its `clip_plane`, summed over views |
| `media_dropped` | Per view, the visible [medium volumes](fog.md#medium-volumes) past the nearest `MAX_VIEW_MEDIA` (4); reset at `begin_frame` |
| `cluster_view`, `cluster_count`, `cluster_overflows`, `cluster_skipped`, `decal_overflows` | Delayed cluster results ([lights](lights.md#diagnostics)) |
| `shadow_layers`, `shadow_requests_dropped`, `shadow_sets_recorded`, `shadow_sets_shared`, `shadow_lights_unshared`, `shadow_timings` | Shadow counters ([shadows](shadows.md#shadow-counters)) |
| `pipelines_created` | Pipelines the cache built this frame, prepared ones included |
| `prepare_*` | Work spent by [preparation](preparation.md) this frame |
| `textures`, `texture_views`, `texture_capacity`, `texture_heap_capacity` | Texture table readings, every 16 frames |
| `gpu_pass_ms`, `gpu_frame_index`, `gpu_timing_state` | Completed GPU pass timings (`C3D_PROFILE_GPU`) |

`Stats.gpu_pass_ms` sums all measured view and pass instances in the completed frame `Stats.gpu_frame_index`.
These delayed results can lag the draw, dispatch and light counters. Absent pass measurements show as N/A and a
truncated summary is partial. See [profiling](profiling.md) for the build features and capture configuration.

## Selection camera

`FrameRoot.selection_camera` holds the camera that selected a pass's [quadtree](instancing.md#quadtree-selection)
levels: `xyz` is its position relative to the frame origin and `w` its pixel scale, `working_height / (2 * tan(fov_y /
2))` for a perspective camera and `working_height / ortho_height` for an orthographic one. The working height includes
`render_scale`. `FrameRoot.previous_selection_camera` is the same camera one rendering earlier. A vertex stage that
morphs a quadtree batch reads both, so the surface it draws agrees with the selection and, for motion vectors, with
the previous rendering's surface.

`FRAME_SELECTION_ORTHOGRAPHIC` (bit 11 of `FrameRoot.flags`, 2048) is set when the selecting camera is orthographic,
which selects by size and gives no morph. It describes the selecting camera, not the root's own `proj`: a shadow
layer's `proj` is the light's, orthographic for every directional cascade. `quadtree_selection_orthographic(frame)`
in `quadtree_morph.glsl` reads it. It is clear in a probe update.

| Pass | Camera written |
| --- | --- |
| Main view: depth prepass, G-buffer, velocity, scene reads | The view's own camera |
| Shadow layers | The owning view's camera and flag, not the light's: the casters are the nodes the view selected. A layer shared by several views carries the camera of the view that recorded it |
| Mirror views | The mirror view's own camera, as a view that selects for itself |
| Path tracer | Its own camera |
| Probe update | Zero in both fields, flag clear; it draws no quadtree batch |

A temporal view keeps the camera of its last published rendering and moves it to the current frame origin. Without a
valid history, which a camera cut or `reset_view_history` leaves, and for a view that keeps none, the previous camera
equals the current one.

## See also

- [Views](views.md) for the guide.
- [MSAA](msaa.md), [shading paths](shading_paths.md) and [preparation](preparation.md).
- [Lights](lights.md) and [shadows](shadows.md) for the cluster and shadow counters.
- [Instancing](instancing.md#quadtree-selection) for quadtree batches.
