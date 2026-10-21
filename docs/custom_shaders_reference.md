# Custom shaders reference

The forms of a `ShaderDesc`, the public GLSL includes, and the contracts of vertex, traced, weighted, prepass, quadtree
and trace-pose stages. [Custom shaders](custom_shaders.md) explains how to write a material and its fragment stages.
[Compute dispatch](compute.md) covers compute stages and [Shader packages](shader_packages.md) covers offline
compilation.

## ShaderDesc forms

The vertex forms and the traced and weighted fragment forms are one source compiled with defines. `gbuffer` and `depth`
are separate fragment sources, and `trace_pose` stages are compute sources. A shader supplies only the forms it needs.
An empty form is not drawn.

| `ShaderDesc` field | Compiled with | Requires | Drawn |
| --- | --- | --- | --- |
| `fragment` | none | Always | Forward and sorted draws; drawn where `gbuffer` or the view's traced form is empty |
| `gbuffer` | separate source | No `scene_reads` | Opaque and masked draws on `DEFERRED` views ([G-buffer stage](custom_shaders.md#g-buffer-stage)) |
| `depth` | separate source | Nothing | Depth prepass of a `FORWARD` view with ray-traced AO; without it the core depth fragment draws ([Prepass stage](#prepass-stage)) |
| `traced_fragment.hardware` | `RT_SHADOWS` | Nothing | Views that trace shadows, on renderers with ray queries ([Traced shadows](#traced-shadows)) |
| `traced_fragment.software` | `RT_SHADOWS`, `SCENE_TRACE_BVH` | Nothing | Views that trace shadows, on renderers without ray queries |
| `weighted_fragment.shaded` | `WEIGHTED_BLEND` | Nothing | `WEIGHTED` views that trace no shadows; a view that needs a missing weighted form draws the item sorted, through `traced_fragment` or `fragment` ([Weighted form](#weighted-form)) |
| `weighted_fragment.traced.hardware` | `WEIGHTED_BLEND`, `RT_SHADOWS` | Nothing | `WEIGHTED` views that trace shadows, with ray queries |
| `weighted_fragment.traced.software` | `WEIGHTED_BLEND`, `RT_SHADOWS`, `SCENE_TRACE_BVH` | Nothing | `WEIGHTED` views that trace shadows, without ray queries |
| `vertex.shaded` | none | `vertex.depth` | Forward pass |
| `vertex.depth` | `DEPTH_ONLY` | `vertex.shaded` | Shadow atlas |
| `vertex.instanced_shaded` | `INSTANCED` | `vertex.instanced_depth` and `vertex.shaded` | Instanced batches, forward |
| `vertex.instanced_depth` | `INSTANCED`, `DEPTH_ONLY` | `vertex.instanced_shaded` | Instanced batches, shadow atlas |
| `vertex.velocity` | `VELOCITY` | `vertex.shaded` | Velocity pass ([Velocity form](custom_shaders.md#velocity-form)) |
| `vertex.instanced_velocity` | `VELOCITY`, `INSTANCED` | `vertex.instanced_shaded` and `vertex.velocity` | Velocity pass, instanced batches |
| `trace_pose.single` | separate compute source | `vertex.shaded` | Poses a mesh's trace geometry ([Trace pose](#trace-pose)) |
| `trace_pose.instanced` | compute source with `INSTANCED` | `vertex.instanced_shaded` | Poses one instance of a batch |
| `trace_pose.reads_time` | flag | Nothing | Re-poses every frame |
| `trace_pose_grid` | flag | Nothing | Declares that the pose stages index through `trace_pose_index` |
| `scene_reads` | `SceneReads` bits `color`, `depth` | No `gbuffer` | [Scene reads](custom_shaders.md#scene-reads) |
| `param_block_size` | bytes | Nothing | Size of the payload the shader reads |

`add_shader` and `replace_shader` fault `INVALID_ARGUMENT` on any of these: an empty `fragment`; a half pair (`shaded`
without `depth`, or `instanced_shaded` without `instanced_depth`, or the reverse); an instanced or velocity form without
the forms it requires; `trace_pose.single` without `vertex.shaded`; `trace_pose.instanced` without
`vertex.instanced_shaded`; a `gbuffer` stage with nonzero `scene_reads`. Neither the traced nor the weighted forms are
validated.

## Public includes

A custom or package stage starts with the prelude, `generated/shader_abi.glsl` (gpu.c3l) and `c3d_abi.glsl`, then
includes what it uses. The includes below are the contract for custom and package stages. Each compiles after the
prelude alone. The build checks that on every run by compiling one probe per row of `public_includes` in
`shaders/variants.json`. A probe that fails stops the shaders step with `public include <name> is not self-contained`
and glslang's output. The other files of the embedded set resolve too but can change without notice.

The includes of gpu.c3l under `shaders/gpu/` follow its own shader ABI and are not part of this contract. Among them,
`descriptor_heap.glsl` supplies `gpu_fetch_uint`, `sample_texture_2d`, `load_storage_texture` and
`store_storage_texture`, which [custom shaders](custom_shaders.md#fragment-contract) and
[compute stages](compute.md#textures) use. `custom_material.glsl` includes it, so a material stage that includes
`custom_material.glsl` has these functions. A compute stage that uses them includes `descriptor_heap.glsl` itself.

| Include | Public surface |
| --- | --- |
| `constants.glsl` | `PI` |
| `material_uv.glsl` | `custom_slot_present` (with or without the frame), `custom_slot_texture`, `custom_map_uv` ([view-provided slots](custom_shaders.md#view-provided-slots)) |
| `material_alpha.glsl` | `material_output` |
| `blend_output.glsl` | `write_blend_output`, the `out_color` output and, under `WEIGHTED_BLEND`, the `out_revealage` output ([weighted form](#weighted-form)); includes `pre_exposure.glsl` |
| `pre_exposure.glsl` | `pre_exposed` ([pre-exposure](custom_shaders.md#pre-exposure)); fragment and compute stages |
| `custom_material.glsl` | `sample_custom_map` (the plain and biased overloads, each with or without the frame), `custom_reference`, and the `material_mip_bias` global (set it from `frame.mip_bias`) |
| `normal_mapping.glsl` | `decode_normal`, `tangent_normal`, `derivative_normal`, `derivative_tangent`, `surface_tangent_frame` |
| `noise.glsl` | `interleaved_gradient_noise`, `pcg_hash`, `hash_unit` |
| `texture_fetch.glsl` | `fetch_texture_2d`, `texture_extent`, `sample_texture_2d_lod` |
| `gbuffer.glsl` | `reconstruct_world_position`, `view_distance`, `BACKGROUND_VIEW_DISTANCE`, `encode_octahedral`, `decode_octahedral` |
| `brdf.glsl` | `StandardSurface`, `prepare_surface`, `prepare_standard_surface`, `apply_anisotropy`, `apply_surface_anisotropy`, `evaluate_standard_lobes`, `evaluate_standard_brdf`, `fresnel_schlick` |
| `lights.glsl` | `LightArray`, `LightList`, `LightSample`, `select_lights`, `flat_lights`, `selected_light_index`, `sample_light`, `light_casts_shadow`, `standard_view_direction`, `evaluate_standard_light` |
| `shadows.glsl` | `shadow_visibility`, `shadow_transmittance`, and `ray_shadow_visibility` (`RT_SHADOWS` only). The first two include the [cloud layer's shadow](clouds.md#cloud-shadows) and the [media's sun column](fog.md#medium-volumes) for the sun, and a sun without shadow layers gets both through the `light_casts_shadow` gate. `shadow_transmittance` keeps the column's channels, and `shadow_visibility` takes their mean |
| `ibl.glsl` | `frame_has_indirect`, `indirect_diffuse_irradiance` (with or without an `irradiance_direction`), `evaluate_environment` (both), `evaluate_environment_lobes` (with or without an `irradiance_direction` and a `ReflectionSelection`), `environment_lobe_radiance`, `environment_tables` |
| `probe_classification.glsl` | `probe_classification(ProbeVolumeGpu, uvec3)` reads a valid probe's live provisional, eligible or excluded state; fragment and compute stages |
| `reflection_probe.glsl` | `ReflectionSelection`, `reflection_probe_select`, `reflection_probe_weight`, `reflection_box_direction`, `reflection_probe_radiance`, `ENVIRONMENT_GGX_CUBE`, `ENVIRONMENT_CHARLIE_CUBE`; fragment and compute stages |
| `ambient_occlusion.glsl` | `draw_ambient_occlusion`, `frame_ambient_occlusion`, `draw_bent_normal`, `frame_bent_normal` ([bent normals](ambient_occlusion.md#bent-normals)), `specular_occlusion` |
| `screen_space_gi.glsl` | `draw_screen_space_indirect`, `frame_screen_space_indirect`, `screen_space_base_share` |
| `fog.glsl` | `FogTerms`, `fog_terms`, `fog_background_terms`, `apply_fog`, `apply_material_fog`, `fog_behind`, `apply_fog_refracted`; the helpers include the view's [fog volume](fog.md#volumetric-fog) and [medium volumes](fog.md#medium-volumes) ([sky](fog.md#custom-stages)); fragment and compute stages |
| `scene_snapshot.glsl` | `scene_uv`, `scene_color_at`, `scene_depth_at`, `scene_view_distance_at`, `scene_position_at`, `scene_depth_gap` ([scene reads](custom_shaders.md#scene-reads)) |
| `standard_surface.glsl` | `StandardMaterialSample` (fields frozen), `sample_standard_material`, `MaterialUvGrad`, `sample_standard_material_grad` ([explicit gradients](custom_shaders.md#explicit-gradients-and-tangents)), and the `material_mip_bias` global (set it from `frame.mip_bias`) |
| `decals.glsl` | `apply_decals` ([decals](decals.md#decals-in-custom-shaders)) |
| `standard_shading.glsl` | `standard_ambient_fill`, `evaluate_standard_lights`, `shade_standard_surface` |
| `gbuffer_output.glsl` | `write_gbuffer`, outputs at locations 0 to 4, and the `trace_proxy_skip_height` global (raise it before shading; [G-buffer stage](custom_shaders.md#g-buffer-stage)) |
| `proxy_skip_output.glsl` | `write_proxy_skip`, the `out_proxy_skip` output at location 0 and the `trace_proxy_skip_height` global ([prepass stage](#prepass-stage)) |
| `vertex_pull.glsl` | `pull_vec2`, `pull_vec3`, `pull_vec4`, `pull_triangle`, `GEOMETRY_*` |
| `view_clip.glsl` | `view_clip_distance` and the redeclaration of `gl_ClipDistance` as a one-element array ([clip plane](views.md#clip-plane)); vertex stages only |
| `instance_effects.glsl` | `instance_anchor`, `instance_fade_scale`, `sway_height_weight`, `sway_offset` ([sway and fade](instancing.md#sway-and-distance-fade); the blocks are `c3d_abi.glsl`'s `InstanceEffectsGpu` and `SwayGpu`); vertex and compute stages |
| `mesh_vertex.glsl` | The push block, the [varyings](#varyings), `view_clip_distance` (through `view_clip.glsl`), `MeshVertexInput`, `pull_mesh_vertex`, `apply_mesh_deformation`, `write_mesh_outputs` (five arguments in `VELOCITY` forms), `previous_mesh_position` (`VELOCITY`; starts from the view's retained base positions of a [`vertex_motion`](geometry_edits.md#edited-vertices) mesh), `instance_source` and `world_instance` (`INSTANCED`), `instance_bend_weight` and `apply_instance_effects` (every form), `previous_world_model` (`VELOCITY` with `INSTANCED`) and `apply_previous_instance_effects` (`VELOCITY`) |
| `instance_record.glsl` | `pack_instance_record(model, color, seed)`, which fills an `InstanceGpu` the way host batches pack theirs ([device batches](instancing.md#device-batches)); compute stages only |
| `quadtree_morph.glsl` | `quadtree_range`, `quadtree_morph`, `quadtree_world_scale`, `quadtree_selection_orthographic` ([quadtree morph](#quadtree-morph); the blocks are `c3d_abi.glsl`'s `QuadtreeGpu` and `QuadtreeLevelGpu`); vertex and compute stages |
| `trace_pose.glsl` | The compute push block and group size, `TracePoseVertex`, `trace_pose_index`, `trace_pose_vertex`, `trace_pose_write`, `trace_pose_instance` ([trace pose](#trace-pose)); compute stages only |
| `scene_trace.glsl` | As in [Scene tracing](scene_trace.md) |

The probes cover these variants:

- `blend_output.glsl` plain and with `WEIGHTED_BLEND`.
- `shadows.glsl` and `standard_shading.glsl` plain, with `RT_SHADOWS`, with `RT_SHADOWS` and `SCENE_TRACE_BVH`, and each
  of those two with `RT_SHADOWS_HARD`.
- `lights.glsl` in fragment and vertex stages.
- `pre_exposure.glsl`, `probe_classification.glsl`, `reflection_probe.glsl` and `fog.glsl` in fragment and compute
  stages.
- `mesh_vertex.glsl` plain, with `INSTANCED`, `DEPTH_ONLY`, both, `VELOCITY`, and `VELOCITY` with `INSTANCED`.
- `instance_effects.glsl` and `quadtree_morph.glsl` in vertex and compute stages.
- `instance_record.glsl` and `trace_pose.glsl` in compute stages.
- `scene_trace.glsl` in compute with each trace kind.

## Varyings

`mesh_vertex.glsl` declares these outputs. A custom fragment stage reads the ones it needs at the same locations.

| Location | Name | Type | Meaning |
| --- | --- | --- | --- |
| 0 | `v_world_pos` | `vec3` | Camera-relative world position |
| 1 | `v_normal` | `vec3` | World normal |
| 2 | `v_tangent` | `vec4` | World tangent; `w` is the bitangent handedness |
| 3 | `v_uv0` | `vec2` | First UV set |
| 4 | `v_uv1` | `vec2` | Second UV set |
| 5 | `v_color` | `vec4` | Vertex color, multiplied by the instance tint on instanced draws |
| 6 | `v_clip_pos` | `vec4` | Clip position; with the TAA jitter removed in `VELOCITY` forms |
| 7 | `v_prev_clip_pos` | `vec4` | Previous clip position; `VELOCITY` forms only |
| 8 | `v_billboard` | `vec3` | [Billboard varying](#billboard-varying) |
| 9 | `v_shading_pos` | `vec3`, `centroid` | [Shading position](#shading-position-varying) |

The depth and velocity forms do not write locations 0 to 2 and 9.

Locations 8 and 9 are reserved by `mesh_vertex.glsl`. A stage that includes it and declares its own output at either
location does not compile. Extra varyings start at location 10, in the vertex and the fragment stage. A custom vertex
stage that writes its outputs itself instead of calling `write_mesh_outputs` must write locations 8 and 9 before it is
paired with a fragment that reads them. The built-in Standard, Physical, Toon, terrain and water fragments read
`v_shading_pos`.

### Billboard varying

`mesh_vertex.glsl` declares `layout(location = 8) out vec3 v_billboard`, and every `write_mesh_outputs` form writes
`(uv0, 0)` to it, depth and velocity forms included. The built-in billboard stage writes
`(quad u, quad v, fract(frame))` instead, with v running from the quad's top edge down: the quad coordinate and the
blend weight toward the next cell of a [sprite sheet](billboards.md#sprite-sheets). The built-in ribbon stage writes
`(u, v, 0)`, the coordinates of [ribbons](ribbons.md#texture-coordinates). A fragment stage reads it with
`layout(location = 8) in vec3 v_billboard;` on any draw. Its `.z` is zero wherever no sprite sheet applies.

### Shading position varying

`write_mesh_outputs` writes the world position that feeds `v_world_pos` to `v_shading_pos`. The depth and velocity forms
leave it out, as they leave out `v_world_pos`. The built-in billboard, ribbon, terrain and water stages write it too.

Under [multisample anti-aliasing](msaa.md) a forward fragment runs once per pixel when any
sample is covered and interpolates `v_world_pos` at the pixel center, which can lie outside the triangle. A traced
shadow ray started there can begin below the neighboring surface and hit it, which draws as speckle on finely
tessellated terrain. `centroid` interpolates inside the covered samples. On a view without MSAA it is the pixel center,
so `v_shading_pos` equals `v_world_pos` there.

A fragment stage reads it with `layout(location = 9) centroid in vec3 v_shading_pos;` and passes it as the position of
`shade_standard_surface`, `evaluate_standard_lights`, `shadow_visibility`, `shadow_transmittance`,
`ray_shadow_visibility` and the light direction. The two Standard functions take one position for probe and light
selection, light direction and shadow ray, so they take it whole. A stage that selects lights and probes through its own
calls, as Physical and Toon do, keeps `v_world_pos` for the selection. Derivatives, `view_depth`, decals, material and
terrain sampling, fog and `write_blend_output` keep `v_world_pos` in every stage. A custom fragment stage under MSAA
should pass `v_shading_pos` to its traced lighting. One that does not compiles unchanged and keeps the pixel-center
position. Deferred stages do not read it: the lighting resolve reconstructs the position from depth.

## Vertex contract

A custom vertex stage includes `mesh_vertex.glsl` and applies its own displacement between `pull_mesh_vertex` and
`write_mesh_outputs` ([example](custom_shaders.md#displace-vertices)). The same source compiled with `DEPTH_ONLY` is the
`depth` form. Compiled with `INSTANCED`, and with both defines, it is the instanced pair. Compiled with `VELOCITY` it is
the [velocity form](custom_shaders.md#velocity-form).

### Instances

- **Index.** An instanced stage that reads per-instance data itself indexes it with `instance_source(draw)`, never
  `gl_InstanceIndex`. With [instance culling](instancing.md#instance-culling) on, `gl_InstanceIndex` is the position in
  the visible list and `instance_source` maps it back to the instance. With culling off both are equal on opaque and
  masked batches. A [blended batch](instancing.md#blended-batches) always draws through a visible list, with or without
  culling, and there `gl_InstanceIndex` is the draw rank, 0 farthest. `write_mesh_outputs` and `apply_mesh_deformation`
  already use it.
- **Matrices.** `world_instance(draw, source)` returns the instance's `InstanceGpu` record in world space: `model` and
  the normal rows are the batch node's `DrawRoot.model` and normal rows composed with the stored record's. The raw
  `InstanceArray` records behind it are relative to the batch node, so a stage that reads them directly places instances
  wrongly under a moved node. In a velocity form take the previous matrix from
  `previous_world_model(draw, source, model)`.
- **Sway and fade.** In `INSTANCED` forms `write_mesh_outputs` applies the batch's
  [sway and fade](instancing.md#sway-and-distance-fade) in world space after the instance matrix, the sway first and
  then the collapse. Under `SwayWeight.VERTEX_ALPHA` it writes `v_color.a = 1` before the instance tint. A stage that
  writes its outputs itself calls `world_instance` (`INSTANCED`), then `instance_bend_weight` and
  `apply_instance_effects` on the world position and, in velocity forms, `apply_previous_instance_effects` on the
  previous world position. It sets `v_color.a = 1` when `DRAW_SWAY_VERTEX_ALPHA` is set. A stage supplies its own bend
  weight by writing `vertex.color.a` before `write_mesh_outputs` and selecting `VERTEX_ALPHA`.
- **Crowds.** A crowd part ([Crowds](crowds.md)) draws through the instanced pair. Compiled with `INSTANCED` and
  the deformation defines, `apply_mesh_deformation` reads the palette row and morph block of the instance's logical
  source, `InstanceGpu.normal_2.w`, at `DrawRoot.skin_stride` joints per row. Compiled without them, the crowd draws at
  the bind pose.

### Clip plane

`write_mesh_outputs` writes `gl_ClipDistance[0]` for the view's [clip plane](views.md#clip-plane) from the world
position that feeds `gl_Position`. In `INSTANCED` forms that is the position after the sway and fade. A stage that
writes `gl_Position` itself, velocity forms included, includes `view_clip.glsl` and writes
`gl_ClipDistance[0] = view_clip_distance(frame, world_position)` from that same world position. `view_clip_distance`
returns 1 in a view without a plane, and in shadow, probe and path-traced roots.

- A stage that does not write the distance draws unclipped in a clipped view.
- Compile every form of a shader from the same `mesh_vertex.glsl` and `view_clip.glsl`. Forms built against different
  versions leave holes along the cut.
- A stage that includes `mesh_vertex.glsl` or `view_clip.glsl` never redeclares `gl_PerVertex` or `gl_ClipDistance`.
  glslang accepts one redeclaration, before any use.
- A module that declares `ClipDistance` needs the device's `shaderClipDistance`, which `create_renderer` already
  requires. gpu.c3l rejects such a module with `gpu::UNSUPPORTED_FEATURE` on a device without it.

### Limits of a custom vertex stage

- It has one compiled form per pass. The renderer does not select `SKINNED`, `SKINNED_U16` or `MORPH` forms of user
  SPIR-V. Compile with the defines that match the geometry when `apply_mesh_deformation` should skin or morph, or leave
  them out for rigid meshes. `DrawRoot.skin` and `DrawRoot.morph` are written either way.
- The velocity pass draws the velocity form when the shader supplies one for the draw. Those items are redrawn on every
  rendering with history. Without it, velocity uses the built-in `mesh` variant and sees the undisplaced mesh. The
  built-in instanced velocity variant, and velocity forms that end in `write_mesh_outputs`, include the batch's sway.
- Built-in materials sample with `FrameRoot.mip_bias` on TAA views. A custom fragment opts in with
  `sample_custom_map(material, slot, uv0, uv1, frame.mip_bias)`. The depth prepass cuts custom alpha coverage unbiased,
  so a masked custom material keeps the unbiased sample for its alpha: a biased one cuts different coverage than the
  prepass tests `EQUAL` against.
- A displaced mesh needs an authored `Mesh.local_bounds` override when the displacement can leave the geometry bounds.
  Culling and shadow fitting use bounds, not vertices. The override is a bound only and does not keep the mesh out of
  [scene traces](scene_trace.md#what-traces). A displaced batch sets `InstancedMesh.local_bounds` with
  `has_bounds_override`. Its instances are then not culled one by one, though a blended one still lists and sorts every
  instance. The built-in sway needs no override: it grows the bound itself and keeps per-instance culling.
- A material with a custom vertex stage traces only through a [trace-pose stage](#trace-pose), whatever `Mesh.trace`
  says: the renderer sees the stage, not the displacement. A stage that displaces nothing and should trace draws through
  the built-in vertex stage.
- A displacement that changes the surface orientation must adjust `vertex.normal` and `vertex.tangent` itself.

### Velocity stages without mesh_vertex.glsl

A velocity stage that does not include `mesh_vertex.glsl` declares the 16-byte push block and writes:

- `gl_Position`, identical to its depth form's;
- `gl_ClipDistance[0]` through `view_clip.glsl`, identical to its depth form's;
- location 6 `vec4 v_clip_pos`: `gl_Position` with `xy -= frame.jitter_time.xy * gl_Position.w`;
- location 7 `vec4 v_prev_clip_pos`: `frame.prev_view_proj * previous_world`, with
  `previous = vec4(previous_local, 1.0)`.

For a plain form `previous_world` is `draw.prev_model * previous`. For an instanced form, with `model` the current
instance matrix from `world_instance(draw, instance_source(draw))`, `previous_world` is
`previous_world_model(draw, instance_source(draw), model) * previous`. That is the matrix the view drew the instance
with last time when the instance changed (the node's previous world, `draw.prev_model * draw.model`, times the
instance's previous matrix), and `draw.prev_model * model` otherwise. Only `mesh_vertex.glsl` declares `world_instance`,
`previous_world_model` and, for a batch with sway or fade, the effects helpers that both world positions also pass
through.

## Traced shadows

A custom forward stage receives ray-traced shadows through `ShaderDesc.traced_fragment`. `hardware` is the forward
source compiled with `RT_SHADOWS`, drawn on renderers with ray queries. `software` is the same source compiled with
`RT_SHADOWS` and `SCENE_TRACE_BVH`, drawn on renderers without them (see
[ray-traced shadows](ray_traced_shadows.md) and [scene tracing](scene_trace.md)). `shadows.glsl` defines
`SCENE_TRACE_RAY_QUERY` under `RT_SHADOWS` unless `SCENE_TRACE_BVH` is set, so one source serves all three forms. In a
fragment stage `shadow_visibility`, `shadow_transmittance` and `ray_shadow_visibility` cast the view's
[soft shadow](ray_traced_shadows.md#soft-shadows) rays at a light with a source extent. A traced form under forward MSAA should
pass them [`v_shading_pos`](#shading-position-varying) as the receiver position.

A traced form includes the soft-shadow code by default and draws on every view that traces shadows, whether or not a
light has an extent. An application whose lights have no source extent can drop that code by defining `RT_SHADOWS_HARD`
in the form, as a compile define next to `RT_SHADOWS` or with `#define` before `shadows.glsl`. `ray_shadow_visibility`
is then one ray toward the light's center, and the form ignores `source_radius` and `source_angle`. `ShaderDesc` has no
field for this: a custom form chooses by its source.

A view that traces shadows draws the form of its renderer's kind. A view that traces none draws `fragment`. When the
matching form is empty, the view draws `fragment`, which receives a traced light with `shadow_count == 0`, so
`shadow_visibility` returns 1 and the surface is lit without that shadow. A shader without traced forms allocates
nothing extra and draws `fragment` everywhere. G-buffer stages need no traced form: the lighting resolve shadows them. A
traced form the backend rejects behaves like any other configuration ([Reload](custom_shaders.md#reload)). A replacement
that drops a form retires its pipelines, and the next frame draws `fragment`.

## Light selection

`FrameRoot.lights` and `light_count` describe the complete selected light array in both flat and clustered views. A loop
over them stays valid and flat. Selecting a clustered view does not accelerate it.

To opt in, `lights.glsl` provides `LightList select_lights(FrameRoot frame, vec3 world_position, float view_depth)`,
`flat_lights(frame)` and `selected_light_index(frame, list, index)`. Compute camera-space depth as
`-(frame.view * vec4(world_position, 1.0)).z`, iterate `list.count`, and fetch
`LightArray(frame.lights).values[selected_light_index(frame, list, index)]`. Keep the receiver-layer test, the shadow
evaluation and the material lighting. The returned indices preserve the original array's shadow mappings.

The selector includes global lights once and falls back to the complete list outside coverage or on cell overflow. Do
not append globals yourself. Use `flat_lights(frame)` when one loop evaluates lighting away from the supplied position,
as Physical transmission does for its exit point. The same helpers work in custom vertex stages, with the position and
depth that suit the stage. [Lights](lights.md#select-lights-with-clusters) describes grid coverage and ownership.

## Prepass stage

`ShaderDesc.depth` is an optional fragment stage for the depth prepass of a `FORWARD` view with
[ray-traced ambient occlusion](ambient_occlusion.md#ray-traced). That prepass writes one `R32_UINT` word per pixel,
packed like the G-buffer flags, so the traced effects can read the pixel's
[proxy skip height](scene_trace.md#trace-proxies). A draw of the shader in that prepass runs `depth` in place of the
core depth fragment, with the vertex stage's `depth` form when it has one. The stage is unpaired: it needs no other
form, and no fault checks it.

The stage includes `proxy_skip_output.glsl`, raises `trace_proxy_skip_height` when its surface can sit below a trace
stand-in, and calls `write_proxy_skip()` on every path. The include declares the output at location 0. The stage does
its own alpha test: it calls `discard` for a cut-out pixel, as the core depth fragment does for a masked material. It
reads the inputs the vertex stage's `depth` form writes, for example a varying that carries the level of a terrain
chunk, and the draw's `fragment_root_gpu`. `terrain_depth.frag.glsl` in `addons/c3d_landscape.c3l` is the reference.

A shader without the stage draws with the core fragment, which writes zero: its pixels read no skip height. The stage
never runs in shadow layers or in the prepass of a `DEFERRED` view, whose G-buffer stage packs the height instead. A
material that reads the scene or blends never draws in the prepass, so its stage never runs.

## Weighted form

A view with `ViewDesc.transparency = WEIGHTED` composes its `PREMULTIPLIED_ALPHA` blended draws without ordering them
([Transparency](transparency.md#weighted-transparency)). A custom `BLEND` stage takes part when its shader supplies the
weighted form the view needs. Without it the draw stays sorted, after the composite, as in a `SORTED` view. `ADDITIVE`
stages are never weighted.

A weighted form is the forward source compiled with the `WEIGHTED_BLEND` define. The stage writes its color through
`write_blend_output` from the public `blend_output.glsl` and declares no `out_color` of its own. The include declares
the outputs:

```glsl
#include "custom_material.glsl"
#include "blend_output.glsl"
#include "fog.glsl"

// ... inputs and parameters ...

void main() {
    // ... color, alpha ...
    vec3 fogged = apply_material_fog(frame, v_world_pos, pre_exposed(frame, color.rgb), material.flags);
    write_blend_output(frame, material_output(fogged, color.a, material.flags), v_world_pos);
}
```

`write_blend_output(frame, premultiplied, world_position)` takes the premultiplied color `material_output` returns and
the fragment's world position, which gives the view-space depth the weight uses. Without `WEIGHTED_BLEND` it writes
`out_color` unchanged, so one source serves the plain and the weighted form. With it, the include also declares
`out_revealage` at location 1 and writes the weighted color and the coverage. A stage composes correctly only if it
writes through the helper. Nothing checks at runtime what a weighted form writes, and a form that declares and writes
its own `out_color` leaves the second attachment unwritten and composes wrongly.

| View | Form drawn | Compiled with |
| --- | --- | --- |
| Traces no shadows | `weighted_fragment.shaded` | `WEIGHTED_BLEND` |
| Traces shadows, renderer with ray queries | `weighted_fragment.traced.hardware` | `WEIGHTED_BLEND`, `RT_SHADOWS` |
| Traces shadows, renderer without them | `weighted_fragment.traced.software` | `WEIGHTED_BLEND`, `RT_SHADOWS`, `SCENE_TRACE_BVH` |

The traced forms follow [Traced shadows](#traced-shadows), with one difference: a missing form does not fall back to
another. A draw joins the accumulation only when the form its view needs exists. A shader that supplies `shaded` alone
is weighted in views that trace no shadows and sorted in views that do, where its `traced_fragment` form, or `fragment`,
still draws. A stage that reads no shadows supplies the same source for the traced forms.

Weighted and sorted pipelines of one shader coexist, so a view that switches mode creates nothing new once both have
drawn. A replacement that drops a form retires that form's pipelines, and the next frame draws the draw sorted.

Scene reads work as for a sorted blended stage. Their snapshots are taken before the accumulation, so the stage sees the
opaque scene without any weighted surface, and a stage that reads depth for a soft fade measures the gap to opaque
geometry.

## Quadtree morph

A custom vertex stage that draws a [quadtree batch](instancing_quadtree.md#box-ranges) under `BOX_RANGES` morphs its
vertices toward the parent level with the numbers that selected the node. `quadtree_morph.glsl` declares:

```glsl
float quadtree_range(QuadtreeGpu tree, uint depth, float pixel_scale, float world_scale);
float quadtree_morph(QuadtreeGpu tree, uint depth, float vertex_distance, float pixel_scale, float world_scale);
float quadtree_world_scale(mat4 node_world);
bool quadtree_selection_orthographic(FrameRoot frame);
```

`quadtree_range` is the selection range of a depth in a perspective view, in world units. The selection pass calls the
same function. `quadtree_morph` is 0 at `R_{d-1} (1 - b)` from the selection camera, 1 at `R_{d-1}`, and 0 for a root
and under the sphere metric. The arguments come from the draw:

```glsl
InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects); // set under DRAW_QUADTREE
QuadtreeGpu tree = QuadtreeGpu(effects.instance_quadtree);
uint depth = DepthArray(effects.instance_depths).values[instance_source(draw)];
float morph = quadtree_morph(
    tree,
    depth,
    distance(world_position, frame.selection_camera.xyz),
    frame.selection_camera.w,
    quadtree_world_scale(draw.model)
);
```

`DepthArray` is a `uint` array reference the stage declares. The batch's `QuadtreeGpu` is never zero for a quadtree
batch, so a stage that reads it under `DRAW_QUADTREE` needs no further check. The include states the two conditions the
ranges keep: no pop at a merge, and at most one depth between neighbors.

An orthographic selecting view has no distance term and takes the size rule, so a stage skips `quadtree_morph` when
`quadtree_selection_orthographic(frame)` holds. The morph is then 0. That function reads `FRAME_SELECTION_ORTHOGRAPHIC`
in `FrameRoot.flags`, not `frame.proj`: a shadow layer's `proj` is the light's, orthographic for every directional
cascade whatever the view is. Draws in shadow layers and the depth prepass read the owning view's camera from
`FrameRoot.selection_camera` and its projection kind from the flag, so their surface matches the shaded one
([selection camera](views_reference.md#selection-camera)).

## Trace pose

A custom vertex stage displaces vertices that [scene traces](scene_trace.md) never see. `ShaderDesc.trace_pose` supplies
the same displacement as a compute stage. For each traced row it writes the posed positions, normals and tangents of the
row's geometry into a renderer-owned slot, and every trace consumer reads hits through that slot. `trace_pose.single`
poses a mesh and needs `vertex.shaded`. `trace_pose.instanced`, the same source compiled with `INSTANCED`, poses one
instance of a batch and needs `vertex.instanced_shaded`. The renderer poses rows by the revision it published, so a
replacement the backend rejected keeps posing with the previous forms. The cost, capacity, `Mesh.local_bounds` rule and
BLAS policy are on the [scene trace](scene_trace_reference.md#custom-trace-poses) page.

The stage includes `trace_pose.glsl`, which declares the compute push block (one `uint64_t root_gpu`), a 64-lane group
and these helpers:

| Helper | Meaning |
| --- | --- |
| `bool trace_pose_index(out uint index)` | The vertex this invocation poses; false past `vertex_count`, where the stage returns |
| `TracePoseVertex trace_pose_vertex(uint index)` | Rest vertex `index`: `position`, `normal`, `tangent`, `uv0`, `uv1`, `color`, with the defaults `pull_mesh_vertex` gives a missing stream |
| `void trace_pose_write(uint index, vec3 position, vec3 normal, vec4 tangent)` | Writes the posed vertex; a stream the geometry lacks is not written, and the tangent keeps its `w` |
| `InstanceGpu trace_pose_instance()` | The record `world_instance` returns for the row, for the `instanced` form only |

The push block addresses a generated `TraceCustomPoseRoot` (`pc.root_gpu`):

| Field | Meaning |
| --- | --- |
| `source`, `posed` | Roots of the rest and the posed geometry; the helpers use them |
| `material` | The row's `CustomMaterialGpu`, whose `parameters` and `slots` the stage reads as the vertex stage does |
| `instance` | The row's `InstanceGpu`; zero for a mesh |
| `time` | `FrameRoot.jitter_time.z` of the frame |
| `vertex_count` | Vertices of the geometry; `trace_pose_index` reports an index past it |

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "trace_pose.glsl"

void main() {
    uint index;
    if (!trace_pose_index(index)) return;

    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    PulseParams params = PulseParams(CustomMaterialGpu(root.material).parameters);
    TracePoseVertex vertex = trace_pose_vertex(index);
    vec3 position = pulse_position(vertex.position, root.time, params.motion);
    trace_pose_write(index, position, vertex.normal, vertex.tangent);
}
```

`PulseParams` and `pulse_position` are the declarations of the vertex stage in
[Displace vertices](custom_shaders.md#displace-vertices).

A row dispatches as a grid of groups, 64 vertices each. The grid is as wide as the device's group count along x allows,
and `trace_pose_index` folds its rows into one linear index. A row that fits the device's group count along x (at least
65,535 groups, so 4,194,240 vertices) has a one-row grid, and `gl_GlobalInvocationID.x` is the same index. A stage that
indexes through `trace_pose_index` sets `ShaderDesc.trace_pose_grid`. A stage that does not poses only the first row of
groups, so `prepare_scene_trace` faults `c3d::UNSUPPORTED` for a row whose groups exceed the device's count along x, and
poses none of it. Rows above 4,194,240 vertices therefore need `trace_pose_index` and `trace_pose_grid`.

Keep the displacement the vertex stage applies in a function both stages include, so the two cannot drift. Scope:

- The stage sees `TraceCustomPoseRoot` and nothing else. A vertex stage that reads the camera, lights or other frame
  data cannot be reproduced: its displacement must come from the material, the instance record and the time.
- The pose is in the geometry's space, before the row's matrix, as a vertex stage's `vertex.position` is. The stage
  adjusts `normal` and `tangent` itself where its displacement turns the surface.
- The renderer re-poses a row only when its inputs change: the material's revision, the revisions of the asset textures
  in its slots, the shader's revision, the instance record and, with `reads_time`, the time. Set `reads_time` for a
  stage that reads `root.time`. Without it the pose is not refreshed as time moves. Neither a render target in a slot
  nor a Standard material in `CustomParams.references` is tracked.
- Skin, morph targets and `Mesh.vertex_motion` do not apply to a custom row, and a part of a `LodGroup` or of a crowd
  with a custom vertex stage stays out of the trace.
- The stage keeps its surface inside the bound the row uses: `Mesh.local_bounds` when `has_bounds_override` is set, else
  the geometry's bound. Give a flat geometry that is displaced a bound with thickness.

## See also

- [Custom shaders](custom_shaders.md) for the material, fragment, vertex and scene-read guides.
- [Compute dispatch](compute.md) and [Shader packages](shader_packages.md).
- [Scene tracing](scene_trace.md), [Instancing](instancing.md), [Shadows](shadows.md), [Transparency](transparency.md).
