# Custom shaders

A custom material draws a mesh with user SPIR-V. The store owns the stages as a `ShaderAsset`, the material carries a parameter payload and up to eight ordinary texture slots, and the renderer builds the pipelines like any built-in family: keyed by the shader id and revision, replaced atomically when the revision moves, retired after their last submitted frame.

## Shader asset

```c3
ShaderDesc desc = {
    .fragment         = fragment_spirv,
    .vertex           = { .shaded = vertex_spirv, .depth = depth_vertex_spirv },
    .param_block_size = PulseParams::size,
};
ShaderId shader = assets.add_shader(&desc, "pulse")!;
```

Every byte array is copied. `fragment` is required. `vertex` is optional; when present both forms are required: `shaded` for the forward pass and `depth` for the shadow atlas, so a deformation is applied to the caster too. `instanced_shaded` and `instanced_depth` are the same pair compiled with `INSTANCED`, for [instanced batches](instancing.md); they are optional and need the plain pair. `add_shader` and `replace_shader` fault `INVALID_ARGUMENT` on an empty fragment, a half pair, or a `gbuffer` stage with nonzero [`scene_reads`](#scene-reads). `param_block_size` is the byte size of the payload the shader reads; zero means none, and a shader whose size is zero must not read `parameters` (the address is zero).

The SPIR-V can come from anywhere: `$embed`ed `.spv` files, a build step, or the in-process compiler below.

## Custom material

```c3
PulseParams pulse = { .color = { 0.3f, 0.6f, 1, 1 }, .motion = { 0.4f, 3, 0, 0 } };
TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
slots[0] = material::texture_slot(base_texture);
MaterialId pulse_material = assets.add_material(material::custom(shader, material::@as_bytes(pulse), slots))!;
```

The payload bytes are copied into the store. Their layout is the application's: write a C3 struct matching the std430 layout the shader declares and pass its bytes through `material::@as_bytes`. The length must equal the shader's `param_block_size`; a mismatch, or a dead shader id, skips the material's draws (counted in `Stats.dangling_refs`) and makes `Renderer.upload(material)` fault `INVALID_ARGUMENT` or `INVALID_ID`.

Edits go through the store:

```c3
assets.@set_custom_params(pulse_material, pulse)!;             // replace the payload, bump the revision
PulseParams* live = assets.@custom_params(pulse_material, PulseParams);
live.motion.x = 0;
assets.mark_material_dirty(pulse_material);                    // in-place edit
assets.set_custom_params(pulse_material, bytes)!;              // untyped bytes, may resize
```

Parameter and texture edits repack the material and re-upload the payload. They never rebuild pipelines. `MaterialCommon` applies as for every family: `alpha_mode`, `alpha_cutoff`, `double_sided`, depth test and write, wireframe.

## Fragment contract

A custom fragment stage declares the 16-byte graphics push block, reads `DrawRoot` through `pc.fragment_root_gpu`, and finds its header and payload through `DrawRoot.material`:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "custom_material.glsl"
#include "lights.glsl"
#include "shadows.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PulseParams {
    vec4 color;
    vec4 motion;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    PulseParams params = PulseParams(material.parameters);
    vec4 base_color = params.color;
    if (custom_slot_present(material, 0u)) base_color *= sample_custom_map(material, 0u, v_uv0, v_uv1);
    ...
    out_color = material_output(color, base_color.a, material.flags);
}
```

`CustomMaterialGpu` (generated, 288 bytes) carries `kind`, `flags` (`MATERIAL_ALPHA_MASK`, `MATERIAL_DOUBLE_SIDED`, `MATERIAL_ALPHA_BLEND`), `alpha_cutoff`, `map_flags` (bit `i` = slot `i` present, bit `i + CUSTOM_MAP_UV1_SHIFT` = slot `i` reads UV1), `slots[8]` as `TextureMapGpu`, and `parameters`, the payload address. `custom_material.glsl` supplies `custom_slot_present`, `custom_map_uv` and `sample_custom_map`; `material_alpha.glsl` supplies `material_output`, which premultiplies for BLEND. Vertex inputs are the fixed locations 0 to 6 written by `mesh.vert.glsl`. `lights.glsl`, `shadows.glsl`, `ibl.glsl`, `brdf.glsl` and the other shared includes are available and read only `FrameRoot` through `DrawRoot.frame`. A forward stage receives the view's ambient occlusion with `draw_ambient_occlusion(frame, draw.flags, ivec2(gl_FragCoord.xy))` from `ambient_occlusion.glsl` (1 when the view has none or the draw is transparent or a [scene reader](#scene-reads)); pass it to `evaluate_environment(frame, world_position, surface, roughness, occlusion, ambient_occlusion)` after the material occlusion (the frame and the world position select a [probe volume](probe_volumes.md) where one covers the surface; call it when `frame_has_indirect(frame)`) and multiply the ambient fill by `min(material occlusion, ambient occlusion)`. A view with [screen-space GI](screen_space_gi.md) adds `draw_screen_space_indirect(frame, draw.flags, ivec2(gl_FragCoord.xy))` from `screen_space_gi.glsl`: pass it to the `evaluate_environment` overload that takes a `vec4 screen_indirect` last, and multiply the ambient fill by `screen_space_base_share(material occlusion, ambient occlusion, screen_indirect)` instead. A G-buffer stage receives both through the lighting resolve.

Custom fragment stages compile once, without the ray-traced shadow path: a light traced by the view (see [ray-traced shadows](shadows.md#ray-traced-shadows)) reaches them with `shadow_count == 0`, so `shadow_visibility` returns 1.

A masked custom material (`alpha_mode == MASK`) discards in its own fragment stage; the shadow atlas reads the same header and uses slot 0's alpha against `alpha_cutoff` as the caster coverage. A custom caster's `DrawRoot.material` is always its `CustomMaterialGpu`, so a custom depth vertex form can read the payload.

### Light selection

`FrameRoot.lights` and `light_count` still describe the complete selected light array in
both flat and clustered views. Existing custom loops, including the tint/pulse examples,
remain valid and flat; selecting a clustered view does not automatically accelerate them.

To opt in, `lights.glsl` provides `LightList select_lights(FrameRoot frame,
vec3 world_position, float view_depth)`, `flat_lights(frame)` and
`selected_light_index(frame, list, index)`. Compute camera-space depth as
`-(frame.view * vec4(world_position, 1.0)).z`, iterate `list.count`, and fetch
`LightArray(frame.lights).values[selected_light_index(frame, list, index)]`.
Retain the existing receiver-layer test, shadow evaluation and material lighting.
The returned indices preserve the original array's shadow mappings.

The selector includes globals once and falls back to the complete list outside coverage
or on cell overflow; do not append globals yourself. Use `flat_lights(frame)` when one
loop evaluates lighting away from the supplied position, as Physical transmission does
for its exit point. The same helpers are available to custom vertex consumers, using the
position/depth appropriate to that stage. See [view light selection](views.md#light-selection)
for grid coverage and ownership.

## G-buffer stage

`ShaderDesc.gbuffer` is an optional second fragment stage. A shader that supplies it is
G-buffer capable: on a `DEFERRED` view its opaque and masked draws join the G-buffer list and are
lit by the lighting resolve, exactly like `STANDARD`; on a `FORWARD` view, and for `BLEND`
materials, the `fragment` stage keeps drawing. A shader without the stage routes forward on every
view. No material field selects the route. A shader that declares [scene reads](#scene-reads) has
no G-buffer stage.

The stage consumes the same seven inputs as the forward stage and writes the five G-buffer
outputs of `gbuffer_output.glsl`: fill a `StandardMaterialSample` (`standard_surface.glsl`) and
call `write_gbuffer(sample, specular_weight, draw)`, or write locations 0 to 4 directly. Lighting,
ambient and environment terms then come from the resolve, so a forward stage that computes
less than the Standard model (the `pulse` example is diffuse only) differs from its G-buffer
route by those terms. `examples/shaders/custom/pulse_gbuffer.frag.glsl` is the reference.

The capability is also visible to shaders: `CustomMaterialGpu.capabilities` carries
`CUSTOM_CAPABILITY_GBUFFER` when the stage is present. Pipelines for the G-buffer stage are keyed
separately, so a rejected G-buffer stage leaves the forward stage of the same shader drawing, and
a replacement that drops the stage retires its pipelines while the forward ones are rebuilt.

## Scene reads

A custom fragment stage can sample the rendered scene behind it: its color for refraction, its
depth for absorption, soft particles, depth fog or decals. `ShaderDesc.scene_reads` declares what
the stage samples:

```c3
ShaderDesc desc = {
    .fragment    = water_spirv,
    .scene_reads = { .color, .depth },
};
```

A shader with a nonzero `scene_reads` has no G-buffer stage: `add_shader` and `replace_shader` fault
`INVALID_ARGUMENT` on the pair.

Routing follows the material's alpha mode. An opaque or masked reader draws in the scene-read list,
the list Physical transmission uses: after opaque, masked and the sky, sorted far to near by bounds
center, in a pass that keeps `MaterialCommon.depth_write`, so water writes depth for what follows. A
blended reader stays in the transparent list, sorted with every other blend, and never writes
depth.

Before each list that holds a reader the renderer copies the finished scene into the view's snapshot
images, at most twice per view and frame and only the kinds the list's draws declare: before the
scene-read list the snapshot holds opaque, masked and sky; before the transparent list, when it holds
a reader, it also holds the scene-read draws. No reader sees ordinary blends or the other draws of its
own list. A view whose frame draws no reader copies nothing; each image is allocated at the view's
working extent the first time a frame needs it and kept until the view's images are released.
`scene_color` is `RGBA16_FLOAT`; `scene_depth` is `R32_FLOAT` holding the reverse-Z depth bit for bit,
4 bytes per pixel (8.3 MB at 1920 × 1080, 33.2 MB at 3840 × 2160).

`scene_snapshot.glsl` samples the snapshots through `FrameRoot.scene_color` and `FrameRoot.scene_depth`.
Include it after `generated/shader_abi.glsl` and `c3d_abi.glsl`:

| Helper | Needs | Returns |
| --- | --- | --- |
| `scene_uv(frame, gl_FragCoord.xy)` | nothing | the fragment's snapshot uv, origin at the top left |
| `scene_color_at(frame, uv)` | `color` | the scene color, linearly filtered, mip zero |
| `scene_depth_at(frame, uv)` | `depth` | the reverse-Z depth of the nearest texel; 0 is background |
| `scene_view_distance_at(frame, uv)` | `depth` | the forward distance of that depth |
| `scene_position_at(frame, uv)` | `depth` | the world position; test `scene_depth_at` for background first |
| `scene_depth_gap(frame, gl_FragCoord)` | `depth` | the forward distance from the fragment to the scene behind it |

Only the `fragment` stage of a custom material may call them, and only for the images its
`scene_reads` declares: the snapshots are in a fragment read state, so vertex stages cannot, and
compute dispatches keep `read_view_color` and `read_view_depth`. Background pixels read depth 0;
`scene_view_distance_at` returns `BACKGROUND_VIEW_DISTANCE` under an infinite far plane and the far
distance otherwise. The snapshots have the view's working extent and share the frame's jittered
matrices, so render scale and TAA need nothing from the shader. Like transparent draws, readers get
no screen-space terms: `draw_ambient_occlusion` returns 1 and `draw_screen_space_indirect` returns
zero.

Routing uses the scene reads of the shader revision whose pipelines are drawing, not the store's
current desc: a replacement the backend rejects keeps the previous pipelines drawing and keeps the
snapshots they sample.

`Stats.scene_snapshots` counts the images copied in the frame (each copy also counts one
`Stats.draws`); `Pass.SCENE_SNAPSHOT` times the copies and `Pass.SCENE_READ` the scene-read list.
`gui::targets_panel` lists `scene_color` and `scene_depth`; `PreviewKind.VIEW_SCENE_DEPTH` previews
`scene_depth` as distance, like `VIEW_DEPTH`.

## Vertex contract

A custom vertex stage includes `mesh_vertex.glsl`, which declares the push block, the seven outputs and three helpers, and applies its own displacement between pulling and writing:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    uint index = uint(gl_VertexIndex);

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    vertex.position = pulse_position(vertex.position, frame.jitter_time.z, PulseParams(material.parameters).motion);
    write_mesh_outputs(vertex, draw, frame, geometry);
}
```

The same source compiled with `DEPTH_ONLY` is the `depth` form; `write_mesh_outputs` then writes only what the depth stage reads. Compiled with `INSTANCED`, and with both defines, it is the instanced pair; `write_mesh_outputs` then reads the instance's matrices and color. `FrameRoot.jitter_time.z` is scene time.

An instanced stage that reads per-instance data itself indexes it with `instance_source(draw)`, never `gl_InstanceIndex`. With [instance culling](instancing.md#instance-culling) on, `gl_InstanceIndex` is the position in the visible list and `instance_source` maps it back to the instance; with culling off both are equal. `write_mesh_outputs` and `apply_mesh_deformation` already use it.

Limits of a custom vertex stage:

- It has one compiled form per pass. The renderer does not select `SKINNED`, `SKINNED_U16` or `MORPH` forms of user SPIR-V; compile with the defines that match the geometry when `apply_mesh_deformation` should skin or morph, or leave them out for rigid meshes. `DrawRoot.skin` and `DrawRoot.morph` are written either way.
- A crowd part (see [Instancing](instancing.md)) draws through the instanced pair. Compiled with `INSTANCED` and the deformation defines, `apply_mesh_deformation` reads each instance's palette at `DrawRoot.skin_stride` joints per instance and its own morph block; compiled without them, the crowd draws at the bind pose.
- Velocity uses the built-in `mesh` vertex variant, so motion blur and TAA see the undeformed mesh.
- Built-in materials sample with `FrameRoot.mip_bias` on TAA views; a custom fragment opts in with
  `sample_custom_map(material, slot, uv0, uv1, frame.mip_bias)`. The depth prepass cuts custom
  alpha coverage unbiased, so a masked custom material keeps the unbiased sample for its alpha:
  a biased one cuts different coverage than the prepass tests `EQUAL` against.
- A displaced mesh needs an authored `Mesh.local_bounds` override when the displacement can leave the geometry bounds; culling and shadow fitting use bounds, not vertices. A displaced batch sets `InstancedMesh.local_bounds` with `has_bounds_override`; its instances are then not culled one by one.
- A displacement that changes the surface orientation must adjust `vertex.normal` and `vertex.tangent` itself; the pulse example is a uniform translation and leaves them alone.

## In-process compilation

With the `C3D_SHADER_COMPILER` feature and `shaderc` in the consumer's dependencies, `c3d::shader::compile` compiles GLSL without a filesystem:

```c3
import c3d::shader::compile;

String log;
char[]? spirv = compile::compile_glsl(
    allocator:  tmem,
    source:     glsl_text,
    stage:      ShaderStage.FRAGMENT,
    defines:    {},
    debug_name: "pulse.frag",
    log:        &log,
);
```

Targets Vulkan 1.3 semantics and SPIR-V 1.5 like the offline build. `#include` resolves against the embedded table `shader::SHADER_INCLUDES`: every file under `shaders/common/`, `shaders/generated/` and gpu.c3l's `include/shaders/`, by the same names the built-in shaders use. An unknown include is a compile error. `SHADER_COMPILE_FAILED` carries no text; the optional `log` receives the compiler messages, including warnings on success.

Without the feature the module does not exist and `shaderc` is not linked; `ShaderDesc` still takes SPIR-V bytes from any other producer.

## Reload

```c3
assets.replace_shader(shader, &new_desc)!;
if (catch excuse = renderer.upload(shader)) { /* SHADER_INVALID or PIPELINE_CREATE_FAILED */ }
```

`replace_shader` copies the new stages and advances the revision. The renderer notices the moved revision at the next frame that draws the material, or immediately through `Renderer.upload(shader)`: every pipeline built from the old revision is rebuilt from the new stages first; on total success the new set is published and the old handles are retired after the frames that may reference them complete; on a backend rejection nothing is published, the previous pipelines and payload keep drawing, gpu.c3l's diagnostic lands in the renderer's `DebugLog` and on stderr, and `Stats.shader_rejections` counts it. Neither a rejected replacement nor a rejected configuration is retried until the shader is replaced again; `upload` returns the fault. Repeated use of one revision and configuration reuses its pipeline; a new configuration (a wireframe toggle, a shadow caster) adds one entry.

A configuration that fails on first use (a forward pipeline, or a shadow caster's depth form) skips those draws until the shader is replaced; other configurations of the same shader keep drawing.

## Compute dispatch

An application runs its own compute stages inside a frame: a `ComputeShaderAsset` in the store, renderer-owned buffers and declared textures the stage reads and writes, and `Renderer.dispatch` recorded at its call position in the frame.

A compute stage can trace rays against the static scene through `Renderer.prepare_scene_trace` and `scene_trace.glsl`; see [Scene tracing](scene_trace.md).

```c3
ComputeShaderDesc compute_desc = { .compute = compute_spirv };
ComputeShaderId simulate = assets.add_compute_shader(&compute_desc, "particles")!;

BufferId particles = renderer.create_buffer({
    .size       = PARTICLE_COUNT * Particle::size,
    .usage      = BufferUsage.GPU_PRIVATE,
    .debug_name = "particles",
})!;
BufferId emitter = renderer.create_buffer({ .size = EmitterBlock::size, .usage = BufferUsage.UPLOAD, .debug_name = "emitter" })!;
```

A compute shader is its own asset kind: one SPIR-V stage, copied into the store, replaced with `replace_compute_shader` (the revision advances), removed with `remove_compute_shader`. `compile_glsl` takes `ShaderStage.COMPUTE`. The stage declares the compute push block, one `uint64_t root_gpu`, which addresses a generated `DispatchRoot { uint64_t textures; uint64_t parameters; }`: `parameters` is the application's root, `textures` the renderer's binding block for declared textures (zero when none are declared). Everything else is reached through buffer references:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
layout(local_size_x = 64) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) buffer Particles { Particle values[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleRoot { uint64_t particles; uint count; float delta; };

void main() {
    ParticleRoot root = ParticleRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    Particles(root.particles).values[index].position_life.xyz += root.delta;
}
```

Buffers are renderer-owned device memory addressed by `BufferId`; `buffer_address` returns the device address an application packs into its root or into a custom material payload, so a custom vertex stage draws from a buffer a compute stage wrote. `GPU_PRIVATE` buffers are written by shaders only. `UPLOAD` buffers also take `write_buffer(id, bytes)` inside an open frame: the bytes are staged in the frame's upload ring and copied before the frame's first dispatch. `destroy_buffer` retires the allocation after its last submitted frame completes; `destroy_renderer` releases whatever is still live.

```c3
renderer.begin_frame(info)!;
renderer.write_buffer(emitter, material::@as_bytes(emitter_block))!;
ParticleRoot root = {
    .particles = (ulong)renderer.buffer_address(particles),
    .count     = PARTICLE_COUNT,
    .delta     = info.delta,
};
BufferId[1] writes = { particles };
renderer.dispatch({
    .shader = simulate,
    .root   = material::@as_bytes(root),
    .groups = { (PARTICLE_COUNT + 63) / 64, 1, 1 },
    .writes = writes[..],
})!;
renderer.render_view(&scene, camera_node, renderer.default_view)!;
renderer.finish_view(renderer.default_view)!;
renderer.end_frame()!;
```

`root` is the application's std430 root; its bytes are copied into the upload ring and their address becomes `DispatchRoot.parameters` (zero for an empty root). `writes` names the buffers the dispatch writes: the renderer records one barrier before the dispatch, from every consumer stage to compute, and one after, from compute to the vertex, fragment and compute stages, so a later dispatch or draw in the same frame reads the results. A dispatch with no writes records no buffer barrier. Buffer reads need no declaration. Dispatches record in call order anywhere between `begin_frame` and `end_frame`, outside an overlay, after the frame's pending asset uploads; `write_buffer` faults `INVALID_ARGUMENT` after the frame's first dispatch, so every staged write lands before every dispatch. A dead shader or buffer id faults `INVALID_ID`. Indirect dispatch and readback are outside this contract.

### Textures

A dispatch declares every texture it samples or stores in `DispatchDesc.textures`, at most `MAX_DISPATCH_TEXTURES` (8) entries; entry `i` becomes slot `i` of the generated `DispatchTexturesGpu` block behind `DispatchRoot.textures`, `{ uint texture_index; uint sampler_index; }` per slot. The constructors name the source and the access:

| Constructor | Source | Access |
| --- | --- | --- |
| `read_texture(texture, sampler = {})` | store texture | sampled |
| `write_texture(texture, mip = 0, layer = 0, access = WRITE)` | storage store texture | store, or load and store with `READ_WRITE` |
| `read_target(target, sampler = {})`, `write_target(target, access = WRITE)` | render target | sampled, or storage (not for `RGBA8_SRGB` targets: `UNSUPPORTED`) |
| `read_view_color(view, sampler = {})`, `write_view_color(view, access = WRITE)` | the view's current scene image | sampled or storage |
| `read_view_depth(view, sampler = {})` | the view's depth image | sampled only |

A zero sampler id selects the renderer's linear clamp sampler. Before the dispatch the renderer moves each declared image into its declared state, so a target rendered by an earlier view, a texture uploaded this frame, or an image written by an earlier dispatch is readable without further declaration; after the dispatch a store texture returns to the sampled state materials expect, while targets and view images keep their tracked state for the next pass that uses them. The renderer remembers each store texture's state when a recording first touches it and restores it when that recording is discarded without submission; two dispatches leaving a texture in the same storage state still record a barrier between them, only sampled reads share a state without one.

```glsl
DispatchRoot root = DispatchRoot(pc.root_gpu);
DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
float depth = sample_texture_2d(textures.slots[0].texture_index, textures.slots[0].sampler_index, uv).r;
vec4 color = load_storage_texture(textures.slots[1].texture_index, ivec2(coord));
store_storage_texture(textures.slots[1].texture_index, ivec2(coord), mix(color, fog, amount));
```

A store texture is writable when its `TextureDesc.storage` is set; block-compressed and sRGB formats reject the flag with `INVALID_ARGUMENT`. `add_texture_empty(desc, key)` creates a storage texture with no pixels, contents undefined until a dispatch writes them; it may be bound by a material before that. A dispatch writes one mip of one layer per declaration; levels it does not write keep their previous contents, and `Renderer.upload(texture)` writes the CPU pixels back over the GPU contents.

### Views

`render_view` records a view's scene passes; `finish_view(view)` records its depth of field, display chain and output. A dispatch between the two reads the view's depth and reads or writes its scene image in place, and the post chain sees the result; a dispatch after `finish_view` sees the finished image. `end_frame` faults `INVALID_ARGUMENT` when a rendered view was not finished; `Renderer.render` calls both. `view_extent(view)` gives the working size a dispatch over the view covers. A `write_view_color` before the view's `render_view` is overwritten by the view's clear.

Compute pipelines share the pipeline cache and the reload behavior of custom materials: `replace_compute_shader` followed by the next dispatch, or by `renderer.upload(compute_shader)`, rebuilds the pipeline under the new revision and publishes it on success; a backend rejection (a push block that is not `RootPush`, a missing `main`) keeps the previous revision dispatching, lands in the debug log and `Stats.shader_rejections`, and `upload` returns the fault. A first revision that is rejected skips its dispatches until the shader is replaced.

`Stats.dispatches` counts the frame's custom dispatches; `Pass.CUSTOM_COMPUTE` times those before the frame's first `render_view` and `Pass.CUSTOM_COMPUTE_POST` those after.

## Example

`examples/custom_shader` keeps `tint.frag.glsl`, `pulse.vert.glsl` and `pulse.frag.glsl` under `examples/shaders/custom/`, compiles them in process at startup, and every half second compares the files' modification times with the ones it last saw; a change, or R, recompiles and replaces the shader, printing the compiler log or the rejection fault. P pauses the pulse through `@custom_params`. Editing `pulse.frag.glsl` so its push block does not match (add a member to `Push`) demonstrates the rejection: the console shows the `SHADER_INVALID` diagnostic, the stats panel counts a rejection, and the box keeps drawing with the previous shader until the file is fixed.

`examples/custom_compute` advances a particle buffer with `particles.comp.glsl` every frame and draws it as camera-facing quads through a custom material whose vertex stage pulls each particle by `gl_VertexIndex / 4` from the same buffer; an `UPLOAD` buffer carries the moving emitter. The particles are a blended [scene reader](#scene-reads) of depth: each fades by `scene_depth_gap` over `softness` metres into what lies behind it, so they dissolve into the floor and the water instead of cutting through them; S switches `softness` between 0 and its default through `@set_custom_params`, and the hard intersections return. A 5 × 5 pool over the floor draws with `water.frag.glsl`, an opaque reader of color and depth: it refracts the checker floor through animated ripples, keeps the unrefracted uv where the offset sample lies in front of the surface, darkens and tints the floor by the length of the water path, and foams where the gap to the scene behind is small, around a Basic post standing in the pool. W shows or hides the pool. The stats panel shows `Scene snapshots: 3` with the pool (color and depth before the scene-read list, depth again before the particles) and `1` without it; with `--gpu-timings` the `SCENE_SNAPSHOT` and `SCENE_READ` rows appear, and `SCENE_READ` reads `N/A` while the pool is hidden. All four GLSL files are polled and reloaded like the custom shader example, Space reseeds the particles, and the stats panel shows `Dispatches: 1` and the completed custom compute time. Breaking the compute push block demonstrates the rejection: the console shows `SHADER_INVALID`, and the particles keep moving under the previous revision until the file is fixed.

`examples/compute_textures` writes an animated value-noise pattern into an empty storage texture every frame with `noise.comp.glsl` and binds it as the boxes' base map, then, between `render_view` and `finish_view`, runs `fog.comp.glsl` over the view: it samples the depth image and loads and stores the scene image in place. F toggles the fog, N freezes the noise, R reloads; both files are polled.
