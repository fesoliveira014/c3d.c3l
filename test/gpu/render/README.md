# Manual GPU submission acceptance

The LOD cases in `test_lod.c3` verify shared logical source indices, part/parity
transforms, independent view/shadow selection, whole-group arena fallback,
submission-owned history, temporal rejection, transparency sorting and common
sway/fade anchors. Image comparisons use 512×512 reference color/depth/shadows.
See [LOD acceptance](../../../docs/lod_acceptance.md) for the separate example run.

The vertex-motion cases in `test_vertex_motion.c3` move a stationary quad's base
positions and compare the centre velocity with the CPU projection (2e-3 UV) on
forward and deferred views, without TAA, across two views with different
cadence, across a render-origin crossing and under a static skin and morph. They
also check zero motion with rejection for first observation, replaced geometry,
a count change, reset, re-enabling and an aborted frame, the
`ASSET_DATA_UNAVAILABLE` fault for released positions, and the per-frame
`Stats.vertex_history_bytes` count.

The auto-exposure cases in `test_auto_exposure.c3` render constant-luminance backgrounds into float targets and
read each rendering's adapted value from the view's readback. They check the GLSL adaptation against its C3 twin
within 1e-4 relative over a sequence of 0, 1/144 to 0.5 s steps and luminance changes, and the delayed
`ViewStats.exposure` two frames late; a lit scene with bloom renders the same image under sixteen times the light;
a path-traced view settles within 0.01 stops of its converged image's target and steps, without a snap, after its
accumulation restarts; a `LINEAR_HDR` view records no exposure dispatch; auto exposure at unit scale equals manual
output with bloom bit for bit; a narrowed `max_ev` bounds the next rendering; two views of one camera adapt
independently at different cadences; an aborted frame changes nothing; a black frame holds and isolated 60,000-unit
pixels leave the metered mean unchanged; a cut into a black frame lands the first lit frame on its target; the state
is allocated with the view, not on toggle, and freed with it.
`test_manual_exposure.c3` prints the digest of a manual image with bloom; it compiles on any revision, so running it
before and after a change shows whether manual output moved.

Build the repository once so `shaders/spv/` exists, then invoke this project
separately:

```bash
python3 scripts/build.py --target compute_textures
c3c test acceptance --path test/gpu/render
```

These tests create a real Vulkan device with validation enabled and read the
renderer's debug log for validation errors. They do not run in the root test
matrix or CI. On Windows, the build step places the shader compiler DLL beside
this project's executable in `build/render_acceptance`.

The workload is headless: one box whose material samples an empty storage
texture, two render targets (`RGBA16_FLOAT`, `RGBA8_UNORM`), a compute shader
that stores a root color into a storage texture and one that samples a
texture or target into a readback buffer.

What the four cases establish:

- `render_to` completes for `LINEAR_HDR` and `DISPLAY_LDR` and writes the
  target; a `render_to` that faults closes the frame and frees its view.
  A `create_renderer` that faults after its arrays exist (a builtin texture
  without pixels) frees every allocation it made.
- A warm frame with only a fullscreen draw or only a compute dispatch submits;
  a frame with no recorded work is discarded without a fault.
- A storage texture uploaded, written and sampled in one frame, written twice
  in one frame, or written in a frame that is aborted before submission keeps
  a valid layout; the next frame's reads return the last submitted color.

- Two live scenes whose meshes share entity ids get distinct palette and
  morph blocks in one frame; a view's previous pose is published only by a
  submitted frame and dropped by an aborted one; an orthographic camera with
  motion blur leaves the background at the clear color under camera motion.

- Five boxes sharing one material resolve it once per view and look up one
  pipeline per draw item; a shadowed skinned and morphed box records its
  shadow layer with the pipeline prepared once.

- Supplied mips land in the texture byte for byte through one staging copy;
  a renderer with a tiny upload ring frees each frame's overflow allocations
  when the slot is reused and grows the ring without losing its old
  allocation.

- Texture containers (`test_texture_containers.c3`, `sample_lod.comp.glsl`): an RGBA8 chain with a marker at
  texel 0 of each level, loaded from DDS, KTX1 and KTX2, samples level by level like the same texels supplied
  through `add_texture_mips`, with each marker at v = 0; `bc1_mips.dds` and four real-tool BC files match their
  hand-built chains, and each level of the example chain reads its solid color. A device without BC sampling
  prints `skipped: BC unsupported on <adapter>` and still runs the RGBA8 case.

- A skinned geometry drawn by a node without a skin binding renders with the
  unskinned vertex stage and shows its material.

- Vertex colors tint the built-in shading, and a masked material discards
  fragments whose vertex alpha falls under the cutoff in the visible and the
  shadow pass.

- A translucent draw blends inside the single forward attachment pass; FXAA
  writes the output directly when the working image matches the output
  rectangle and falls back to the compute route otherwise; bloom at zero
  intensity records no dispatch.

- The software scene trace matches CPU triangle picking ray for ray over a
  64 by 64 grid (a box, a sphere, an instanced batch with a mirrored
  instance and a non-indexed ground), skips a geometry released before its
  first preparation and one whose index count is not a multiple of three, and
  traces identically after every other geometry's CPU arrays are released.

- The instance cap counts the rows that trace: with more candidates than
  `max_trace_instances`, some left out for want of a posed slot, preparation
  succeeds, and one more kept row faults `c3d::CAPACITY_EXCEEDED`.

- On a renderer with ray queries, the software walk and ray queries report
  the same instance, triangle, distance and barycentrics over the same grid,
  with a masked checker box and a box that casts no shadow added; rays
  through the checker holes reach what lies behind on both, and the shadow
  caster mask hides the non-caster on both.

- A thin rod's shadow read along one image column across the first
  directional split: with `cascade_blend = 0` the two cascades meet in one
  luminance step; with 0.1 the image before the band is unchanged pixel for
  pixel, the band differs, and no step along the column is as large as the
  unblended seam (`line.comp.glsl` reads the column). The case sets no normal
  offset: an offset would shift the thin rod's shadow across the seam it
  measures.

- Own shadow sets render unchanged (`test_shadow_sets.c3`): one scene with casters over the first two cascades' blend
  bands renders forward, deferred, through a custom stage that calls `evaluate_standard_lights`
  (`standard_lights.frag.glsl`) and with volumetric fog. Each image is identical across two frames and every band
  probe is shadowed. The test prints an FNV-1a hash per image (`--test-show-output`) for comparing two commits on one
  machine.

- Shadow sets shared between views (`test_shadow_sets.c3`): a mirror fitted to the main camera records the set and
  main binds it, bit for bit as its own set (forward, deferred, the `evaluate_standard_lights` stage, volumetric fog,
  a batch the mirror's distance fades); two views of one camera share one set unless either opts out, and the
  opted-out frame renders the same image; a sun no cascade covers leaves an empty set and no layers for the own-set
  and the borrowing view, and both render the same image.

- Mirror shadow sets (`test_shadow_sets.c3`): the mirror records the frame's only atlas; its reflected wall matches
  its own-set image within tolerance with and without volumetric fog; a borrowed set shadows a receiver its selected
  cascade misses through a coarser cascade and leaves one outside every cascade lit; a spot outside the mirror's
  frustum and a batch past the mirror's fade distance shadow main; a LodGroup caster's shadow stays within 6 % in
  pixels; a light only the mirror sees draws unshadowed and counts in `shadow_lights_unshared`; a recording between
  mirror and main makes main record.

- Directional normal offsets at the default two texels of a 2048-texel atlas,
  in their own fixture (`test_shadow_bias.c3`): flat ground stays lit
  (visibility at least 0.99) in all four cascades at sun elevations of 10°,
  20°, 46.5° and 60°, forward and deferred; a 1 m box keeps its contact shadow
  in the first and third cascades; a slab 1.5 offsets thick still darkens the
  ground beyond its edge to 0.5 or less; a deferred view reads the same
  visibility with and without a 20° normal map (within 0.02, a flat 16 × 16
  block's variance at most 1e-3) and matches a forward view within 0.05 across
  a box's silhouettes and creases in the third and fourth cascades.

- A box casts a dark shadow on a plane under both the atlas and ray-traced
  shadows; a fully transparent masked box and a box with `cast_shadow` off
  cast nothing; the ray-traced frames record no atlas layer.

- The top level rebuilds only when the traced set changes, including an
  emptied and refilled set, and a same-frame software preparation leaves it
  alone; a geometry edit rebuilds its bottom level once and the replaced one
  is destroyed without a validation error; a renderer without ray queries
  rejects hardware preparation and ray-traced views with `c3d::UNSUPPORTED`.

- Ambient occlusion images follow the settings (half and full resolution,
  retired when switched off); a floor pixel 5 cm from a wall darkens below
  90 % of its unoccluded value while open floor stays above 97 %, alike on
  forward and deferred views; intensity 0 reproduces the image without AO,
  masked and cut-out surfaces included; a transparent quad over the crease
  reads no AO. A forward view renders the same image with and without its
  depth prepass (opaque, masked, cut-out and transparent surfaces), so the
  prepass and `EQUAL` shading lose nothing.

- Open ground under every pixel of a forward view, seen straight down, keeps
  its normal on the image border: the mean SSAO of each edge matches the
  opposite edge within 0.01 (half and full resolution), ray-traced AO keeps
  every border pixel above 97 % (software walk and ray queries), and SSGI
  changes no border pixel by 1 % or more.

- Probe volumes filled from the environment record four dispatches when first seen, none on a
  frame where nothing changed and two when only the environment rotation or `max_distance` moved,
  once per scene when two views render it; a surface inside a volume matches the SH render within
  2 of 255 on both shading paths, also for a volume whose slices wrap into rows, and an edited
  environment source refills the volume; a source edit rewrites the source, GGX and Charlie cubes
  and the SH in place and still refills the volume, while a `specular_size` change reallocates the
  GGX and Charlie cubes and keeps the source cube; of two nested volumes the smaller one lights the surfaces
  it contains; the GLSL atlas helpers match their C3 twins; removing the component frees the slot.

- A custom material that reads the scene colour shows the scene behind it, within 1 of 255, on
  forward, half-scale, deferred and TAA views; one that reads depth measures its gap to the floor
  under an orthographic and a perspective camera; a blended reader above an opaque reader sees the
  opaque reader's depth, not the floor's; views without readers copy nothing and allocate neither
  snapshot, and Physical transmission alone copies colour only; a replacement the backend rejects
  keeps drawing with its old pipelines and snapshots, and an accepted one that reads nothing drops
  them (`scene_probe.frag.glsl`).

- A custom twin of the Standard material, built on `standard_shading.glsl` and compiled in process
  with an application include, renders the same image as Standard within one half-float step on
  forward and deferred views with flat and clustered lights; its traced forms receive the traced
  sun's shadow on both kinds, and after a replacement without them the plain form draws unshadowed
  without a rejection.

- A custom shader's velocity form moves a still displaced box by its displacement between the
  view's previous and current time, also when another view rendered in between, on late and early
  velocity views; at frozen time it matches the background; an instanced form indexes by
  `instance_source` under culling (`wave.vert.glsl`); a moving opaque glass box and glass batch write
  geometry velocity while a blended one keeps the camera velocity; a velocity form rejected at first
  use skips its velocity draw, and a rejected replacement keeps the previous form drawing
  (`broken_push.vert.glsl`).

- A swayed batch draws, shadows and moves like a batch whose node moved, in the view, the depth
  prepass and the shadow layers, with instance culling on and off; its velocity follows the sway
  the view last drew and that sway's phase; a batch past its fade band leaves the image, the shadows
  and the culled lists, and one before the band draws bit for bit as without fade; the cull margin
  keeps an instance the sway brings into view; a custom instanced stage sways through
  `write_mesh_outputs`; vertex-alpha weighting keeps masked coverage in the depth prepass.

- A blended batch of 5,000 boxes stored in scrambled depth order draws far to near: a fragment
  that knows each instance's expected rank leaves the center pixel opaque green, with and without
  instance culling. A culled translucent line batch lists and sorts only its survivors; a sort that
  does not fit the cull arena draws from CPU arguments and counts one overflow; an opaque view
  never creates the sort pipeline.

- A world clip plane cuts a box and a batch on forward views with and without the depth prepass
  and on deferred views, and culls a box wholly behind it (one more `Stats.culled`) without
  reallocating the view's images; a caster behind the plane still casts its shadow; a plane that
  keeps everything changes no pixel; a mirror camera built with `reflection_matrix` and
  `transform_from_affine` shows only the kept side with single-sided faces kept; a custom stage
  clips through `write_mesh_outputs`; a clipped moving box keeps its geometry velocity above the
  plane; and the prepass and deferred paths cover an oblique cut exactly as the single pass does,
  column by column (`line.comp.glsl`).

- A shader replacement that gpu.c3l rejects leaves later pipelines on the published revision: a
  deferred view first rendered after the rejection draws the published box through its depth prepass
  and `EQUAL`, a batch added after it draws without a second rejection, and `prepare_scene` skips a
  batch whose shader has no instanced pair (`shifted.vert.glsl`).

- An `R16_UINT` texture keeps all 16 bits through upload and `gpu_fetch_uint`
  (`fetch_r16.comp.glsl`); a Basic map, a Toon gradient map and slot 0 of a masked custom
  material refuse it with `c3d::UNSUPPORTED`, while slot 0 of an opaque custom material and
  slot 1 of a masked one accept it.

- A custom stage that reads a referenced Standard block through `custom_reference`
  (`reference.frag.glsl`) matches the Standard material's own pixels while no drawable uses the
  referenced material; after both are edited and marked dirty the pair still matches without
  dirtying the custom material; removing the referenced material, even with a new material in its
  heap slot, skips the custom draws and counts them in `Stats.dangling_refs`.

- Additive materials add coverage-scaled RGB while preserving HDR alpha, switch
  between additive and source-over composition on the same pipeline, and share
  those rules with instanced draws under both culling settings. Basic and custom
  additive fog output is attenuated without another in-scatter contribution;
  zero opacity leaves the background unchanged.

- Two reflection-probe rooms light their own spheres per lobe: smooth and rough base, clearcoat, sheen and the
  transmission fallback read the room's probe on forward and deferred views, a point outside both boxes reads the
  global environment, metals agree across paths, and a sphere with `specular = 0` is bitwise equal without probes.

- A glossy floor across the wall shared by two probe boxes follows the CPU shares, sums them to one, steps by less
  than a tenth between neighbouring pixels, and a zero blend distance switches probes within one texel.

- Traced reflections compose with probes through the roughness fade band: traced only on smooth strips, probe only
  above the threshold, the half-and-half mix inside the band, on hardware and software traces.

- The path tracer never reads a reflection probe: its image is bitwise equal with and without probes.

- The probe-volume update never reads a reflection probe: its result is bitwise equal with and without probes.

- A probe lights specular without a global environment, and spheres outside every box are bitwise equal without the
  probe.

- Removing a probe's environment, component or node falls back to the global environment, counts the dangling
  reference and records no validation errors.

- The selection, shares and box projection in GLSL match the C3 twins on 64 points (`reflection_twins.comp.glsl`).

- A reflection capture renders six faces from a probe's capture point: each face's quadrant texels hold the wall
  tile its direction points at, a mirror sphere seen along each axis shows that wall's hue, nodes outside the
  capture layers are absent, and a capture frame records no exposure or other post compute work.

- A re-capture keeps the texture and environment ids, advances the texture revision, repeats its bytes (the probe
  never sees itself), shows an edited wall on the next frame with one environment preparation, and removing the
  captured assets records no validation errors.

- A capture with a dead probe node, a missing component, an invalid description, a key already in use or exhausted
  store capacity faults with the specific fault before any frame, texture, environment or view is created.

- Renderer capacities (`test_capacities.c3`): a renderer with 32 views and 64 render targets
  creates and destroys all of them, renders every view and samples the last view's output without
  per-frame allocation or leaks, and the next view or target faults `c3d::CAPACITY_EXCEEDED`; a
  zeroed `RendererDesc` holds 8 views (the default view among them) and 8 targets over gpu.c3l's
  default table and heap; with `max_views = 1` `create_view` and `render_to` fault and leave
  nothing behind. A target at index 32 is sampled, after a compute write, by two views in one
  frame through a Basic material and through a custom material's referenced Standard layer, and an
  aborted frame restores its state and the state of a target created inside it. A full texture
  table and a full heap fault `gpu::SLOT_TABLE_FULL` and `gpu::DESCRIPTOR_HEAP_FULL` with
  unchanged live counts; capacities over 65,536 and `max_render_targets` over the texture table
  fault at creation; `Stats` counts a new view's images and target at the next reading. The
  overlay case opens a window: without one it prints a skip line.

- Posed trace instances (`test_posed_trace.c3`, both kinds where noted): a skinned, a morphed and a combined mesh trace at the raster
  pose over four frames (traced hit distance against the raster depth of the same pixels, hits on the slot's geometry
  root), two instances of one geometry stay independent beside a static mesh, a still pose records no posing and keeps the
  trace revision while a joint or weight change advances it once (an aborted frame re-poses once), frames without a
  traced consumer allocate and record nothing, a morph target that leaves the rest box is hit, a closed-frame preparation
  reads the current pose and does not re-pose when repeated, the refit at rest reproduces the rest tree component for
  component, a strong pose's refit tree encloses every posed triangle and child, and a posed stream reused for a
  geometry with a new vertex count follows the new count.

  Both kinds: the bottom level of a posed instance updates in place (one full build, then updates, no rebuild of an
  unchanged pose, a rebuild after an aborted frame), the slot rebuilds on a source revision (also between two
  preparations of one frame) and follows a replacement geometry, the capacity leaves later meshes out in walk order and
  reuses a freed slot, absent slots retire and return fresh, two tracing views pose once, software and hardware hits agree,
  a software preparation's pose reaches the next hardware preparation, a posed caster casts its traced shadow at its pose,
  the path tracer accumulates on a still pose and restarts on a change, a posed cube occludes ray-traced ambient occlusion
  only at its pose, a posed emissive cube shows in ray-traced reflections only at its pose, and a posed roof slab closes the
  probe room's light only in place.

- Resize faults (`test_resize_faults.c3`): at a full texture table a target resize, one whose second view cannot get
  its images, and a `configure_view` that changes the render scale fault `gpu::SLOT_TABLE_FULL`; at a full heap an
  in-place `configure_view` that adds bloom beside kept TAA images and drops ambient occlusion faults
  `gpu::DESCRIPTOR_HEAP_FULL`. Each leaves the target, the views, their images and the live counts as they were and
  renders the same pixel; the failed target and configure resizes keep the TAA history. Each call succeeds once the
  fillers are destroyed. The window case grows its window over a full table: `begin_frame` faults with the window view
  unchanged and the next one succeeds at the swapchain's extent; without a window, or when the window keeps its size,
  it prints a skip line.

What they cannot establish: window clear-only and GUI-only frames need a
window (run the `clear` and `cube_gui` examples with validation), and a
presentation failure after submission needs a hardware observation.
