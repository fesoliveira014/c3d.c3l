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

## Example

`examples/custom_shader` keeps `tint.frag.glsl`, `pulse.vert.glsl` and `pulse.frag.glsl` under `examples/shaders/custom/`, compiles them in process at startup, and every half second compares the files' modification times with the ones it last saw; a change, or R, recompiles and replaces the shader, printing the compiler log or the rejection fault. P pauses the pulse through `@custom_params`. Editing `pulse.frag.glsl` so its push block does not match (add a member to `Push`) demonstrates the rejection: the console shows the `SHADER_INVALID` diagnostic, the stats panel counts a rejection, and the box keeps drawing with the previous shader until the file is fixed.
