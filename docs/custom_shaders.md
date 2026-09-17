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

Every byte array is copied. `fragment` is required. `vertex` is optional; when present both forms are required: `shaded` for the forward pass and `depth` for the shadow atlas, so a deformation is applied to the caster too. `add_shader` and `replace_shader` fault `INVALID_ARGUMENT` on an empty fragment or a half pair. `param_block_size` is the byte size of the payload the shader reads; zero means none, and a shader whose size is zero must not read `parameters` (the address is zero).

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

`CustomMaterialGpu` (generated, 288 bytes) carries `kind`, `flags` (`MATERIAL_ALPHA_MASK`, `MATERIAL_DOUBLE_SIDED`, `MATERIAL_ALPHA_BLEND`), `alpha_cutoff`, `map_flags` (bit `i` = slot `i` present, bit `i + CUSTOM_MAP_UV1_SHIFT` = slot `i` reads UV1), `slots[8]` as `TextureMapGpu`, and `parameters`, the payload address. `custom_material.glsl` supplies `custom_slot_present`, `custom_map_uv` and `sample_custom_map`; `material_alpha.glsl` supplies `material_output`, which premultiplies for BLEND. Vertex inputs are the fixed locations 0 to 6 written by `mesh.vert.glsl`. `lights.glsl`, `shadows.glsl`, `ibl.glsl`, `brdf.glsl` and the other shared includes are available and read only `FrameRoot` through `DrawRoot.frame`.

A masked custom material (`alpha_mode == MASK`) discards in its own fragment stage; the shadow atlas reads the same header and uses slot 0's alpha against `alpha_cutoff` as the caster coverage. A custom caster's `DrawRoot.material` is always its `CustomMaterialGpu`, so a custom depth vertex form can read the payload.

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

The same source compiled with `DEPTH_ONLY` is the `depth` form; `write_mesh_outputs` then writes only what the depth stage reads. `FrameRoot.jitter_time.z` is scene time.

Limits of a custom vertex stage:

- It has one compiled form per pass. The renderer does not select `SKINNED`, `SKINNED_U16` or `MORPH` forms of user SPIR-V; compile with the defines that match the geometry when `apply_mesh_deformation` should skin or morph, or leave them out for rigid meshes. `DrawRoot.skin` and `DrawRoot.morph` are written either way.
- Velocity uses the built-in `mesh` vertex variant, so motion blur sees the undeformed mesh.
- A displaced mesh needs an authored `Mesh.local_bounds` override when the displacement can leave the geometry bounds; culling and shadow fitting use bounds, not vertices.
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

An application runs its own compute stages inside a frame: a `ComputeShaderAsset` in the store, renderer-owned buffers the stage reads and writes, and `Renderer.dispatch` recorded after the frame's uploads and before its first view.

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
renderer.end_frame()!;
```

`root` is the application's std430 root; its bytes are copied into the upload ring and their address becomes `DispatchRoot.parameters` (zero for an empty root). `writes` names the buffers the dispatch writes: the renderer records one barrier before the dispatch, from every consumer stage to compute, and one after, from compute to the vertex, fragment and compute stages, so a later dispatch or draw in the same frame reads the results. A dispatch with no writes records no barrier. Reads need no declaration. Dispatches record in call order, after the frame's pending asset uploads; `dispatch` and `write_buffer` fault `INVALID_ARGUMENT` once a view has been recorded, and `write_buffer` also faults after the frame's first dispatch. A dead shader or buffer id faults `INVALID_ID`. Textures, indirect dispatch and readback are outside this contract.

Compute pipelines share the pipeline cache and the reload behavior of custom materials: `replace_compute_shader` followed by the next dispatch, or by `renderer.upload(compute_shader)`, rebuilds the pipeline under the new revision and publishes it on success; a backend rejection (a push block that is not `RootPush`, a missing `main`) keeps the previous revision dispatching, lands in the debug log and `Stats.shader_rejections`, and `upload` returns the fault. A first revision that is rejected skips its dispatches until the shader is replaced.

`Stats.dispatches` counts the frame's custom dispatches; `Pass.CUSTOM_COMPUTE` times them together, between the uploads and the shadow atlas.

## Example

`examples/custom_shader` keeps `tint.frag.glsl`, `pulse.vert.glsl` and `pulse.frag.glsl` under `examples/shaders/custom/`, compiles them in process at startup, and every half second compares the files' modification times with the ones it last saw; a change, or R, recompiles and replaces the shader, printing the compiler log or the rejection fault. P pauses the pulse through `@custom_params`. Editing `pulse.frag.glsl` so its push block does not match (add a member to `Push`) demonstrates the rejection: the console shows the `SHADER_INVALID` diagnostic, the stats panel counts a rejection, and the box keeps drawing with the previous shader until the file is fixed.

`examples/custom_compute` advances a particle buffer with `particles.comp.glsl` every frame and draws it as camera-facing quads through a custom material whose vertex stage pulls each particle by `gl_VertexIndex / 4` from the same buffer; an `UPLOAD` buffer carries the moving emitter. All three GLSL files are polled and reloaded like the custom shader example, Space reseeds the particles, and the stats panel shows `Dispatches: 1` and the completed custom compute time. Breaking the compute push block demonstrates the rejection: the console shows `SHADER_INVALID`, and the particles keep moving under the previous revision until the file is fixed.
