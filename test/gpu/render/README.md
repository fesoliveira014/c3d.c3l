# Manual GPU submission acceptance

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

- On a renderer with ray queries, the software walk and ray queries report
  the same instance, triangle, distance and barycentrics over the same grid,
  with a masked checker box and a box that casts no shadow added; rays
  through the checker holes reach what lies behind on both, and the shadow
  caster mask hides the non-caster on both.

- A thin rod's shadow read along one image column across the first
  directional split: with `cascade_blend = 0` the two cascades meet in one
  luminance step; with 0.1 the image before the band is unchanged pixel for
  pixel, the band differs, and no step along the column is as large as the
  unblended seam (`line.comp.glsl` reads the column).

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

What they cannot establish: window clear-only and GUI-only frames need a
window (run the `clear` and `cube_gui` examples with validation), and a
presentation failure after submission needs a hardware observation.
