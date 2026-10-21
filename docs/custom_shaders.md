# Custom shaders

A custom material draws a mesh with your SPIR-V. The asset store owns the stages as a `ShaderAsset`. The material
carries a parameter payload and up to eight ordinary texture slots. The renderer builds pipelines for it like for any
built-in family: it keys them by shader id and revision, replaces them atomically when the revision moves, and retires
them after their last submitted frame.

The shader asset is `c3d::asset` (`ShaderDesc`), the material is `c3d::material` (`material::custom`), and the optional
in-process GLSL compiler is `c3d::shader::compile` under the `C3D_SHADER_COMPILER` feature.

Companion pages: [Custom shaders reference](custom_shaders_reference.md) for the `ShaderDesc` forms, public includes and
the vertex, weighted and trace-pose contracts; [Compute dispatch](compute.md) for compute stages, buffers and geometry
writes; [Shader packages](shader_packages.md) for compiling GLSL offline into embedded SPIR-V.

## Quick start

A material with one parameter, a tint color, and an optional base map in slot 0:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "pre_exposure.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TintParams {
    vec4 color;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    vec4 base_color = TintParams(material.parameters).color;
    if (custom_slot_present(material, 0u)) base_color *= sample_custom_map(material, 0u, v_uv0, v_uv1);
    out_color = material_output(pre_exposed(frame, base_color.rgb), base_color.a, material.flags);
}
```

Compile it to SPIR-V for Vulkan 1.3 and SPIR-V 1.5 (see [Shader packages](shader_packages.md) or
[In-process compilation](#in-process-compilation)), embed the result and register it:

```c3
import c3d;
import c3d::asset;
import c3d::material;
import std::math;

struct TintParams {
    Vec4 color;
}

const char[*] TINT_FRAGMENT = $embed("shaders/tint.frag.spv");

ShaderDesc desc = {
    .fragment         = TINT_FRAGMENT[..],
    .param_block_size = TintParams::size,
};
ShaderId shader = assets.add_shader(&desc, "tint")!;

TintParams tint = { .color = { 0.3f, 0.6f, 1, 1 } };
MaterialId tint_material = assets.add_material(material::custom(shader, material::@as_bytes(tint)))!;
Node* node = scene.add_mesh(geometry, tint_material)!;
```

## Concepts

- **Shader asset and material.** The shader asset holds SPIR-V stages and the payload size. The material holds the
  payload bytes, up to `MAX_CUSTOM_TEXTURE_SLOTS` (8) texture slots, up to `MAX_CUSTOM_MATERIAL_REFERENCES` (4)
  [Standard material references](#material-references) and the `MaterialCommon` state. Many materials share one shader
  and its pipelines.
- **Stages and forms.** A shader has one required fragment stage. Every other stage is optional. The vertex forms
  (shaded, depth, instanced, velocity) and the traced and weighted fragment forms are one source compiled with defines.
  The G-buffer and prepass stages are separate fragment sources, and the trace-pose stages are compute sources. A form
  is drawn only when the shader supplies it. The [reference](custom_shaders_reference.md#shaderdesc-forms) lists each
  form, its define and its requirements.
- **Payload.** The payload layout is yours. Write a C3 struct that matches the std430 layout the shader declares and
  pass its bytes through `material::@as_bytes`.
- **Camera-relative positions.** World-position shader values use [camera-relative coordinates](large_world.md).
  `FrameRoot.origin.xyz` gives the absolute offset. Core draw models, camera and light positions, clip planes, scene
  reconstruction and tracing use the same relative space. Convert application-supplied absolute payload positions before
  combining them with those values. Local geometry, palettes and directions keep their spaces. Rebuild consumer SPIR-V
  against the current ABI headers instead of copying the ABI by hand.
- **Public includes.** Stages include only the files listed as
  [public includes](custom_shaders_reference.md#public-includes). Other embedded files can change without notice.

### Pre-exposure

A view stores its scene radiance multiplied by a power of two, its pre-exposure. The display route divides it out. The
factor follows `Camera.exposure` times the view's [adapted exposure](post.md#auto-exposure), so stored values stay near
display scale however dim or bright the scene is. `FrameRoot.pre_exposure` carries it to every stage, and
`ViewStats.pre_exposure` reports it on the CPU. A stage that emits unscaled radiance appears `pre_exposure` times too
dark.

- Radiance that comes from the frame's data or a public helper is already scaled: the frame's lights through
  `sample_light` and the light loop, `shade_standard_surface`, image-based lighting, probes, ambient, `scene_color_at`
  and the fog helpers.
- Radiance a stage produces itself is not. An unlit or emissive color, a constant and a texture sampled as light (a
  render target, an HDR texture) go through `pre_exposed(frame, radiance)` from `pre_exposure.glsl`, which
  `blend_output.glsl` includes. Directions, positions, depth, alpha and optical depth are not radiance and stay as they
  are.
- A `LINEAR_HDR` target is physical. A stage that shows one as light, such as a mirror or a planar reflection, passes
  the sample through `pre_exposed`.
- A clamp that shapes the image applies to physical radiance, before `pre_exposed`. A clamp that only keeps half-float
  finite applies to the scaled value, after it.
- A compute dispatch that reads or writes `read_view_color` or `write_view_color` sees scaled values. It multiplies the
  constants it mixes in by `ViewStats.pre_exposure`, read after `render_view`.
- `ViewDesc.pre_exposure_override` forces the factor to a power of two from 2^-16 to 2^16. Zero keeps it automatic.
  Another value faults `INVALID_ARGUMENT` in `create_view` and `configure_view`.

## Shader asset

```c3
ShaderDesc desc = {
    .fragment         = fragment_spirv,
    .vertex           = { .shaded = vertex_spirv, .depth = depth_vertex_spirv },
    .param_block_size = PulseParams::size,
};
ShaderId shader = assets.add_shader(&desc, "pulse")!;
```

`add_shader` copies every byte array into the store. `fragment` is required. `vertex`, when present, needs both `shaded`
(the forward pass) and `depth` (the shadow atlas), so a deformation applies to the caster too. `param_block_size` is the
byte size of the payload the shader reads. Zero means no payload, and a shader with size zero must not read
`parameters`, which is then address zero.

`add_shader` faults `CAPACITY_EXCEEDED` when the pool is full and `INVALID_ARGUMENT` for a duplicate key or a desc that
breaks the pairing rules in the [forms table](custom_shaders_reference.md#shaderdesc-forms). `replace_shader` applies
the same checks. `asset::copy_shader_desc` and `asset::free_shader_desc` deep-copy and free a desc with any allocator.
The SPIR-V can come from `$embed`ed `.spv` files, a build step or the in-process compiler.

## Custom material

```c3
PulseParams pulse = { .color = { 0.3f, 0.6f, 1, 1 }, .motion = { 0.4f, 3, 0, 0 } };
TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
slots[0] = material::texture_slot(base_texture);
MaterialId pulse_material = assets.add_material(material::custom(shader, material::@as_bytes(pulse), slots))!;
```

The store copies the payload bytes. Their length must equal the shader's `param_block_size`. A mismatch or a dead shader
id skips the material's draws, counted in `Stats.dangling_refs`, and makes `Renderer.upload(material)` fault
`INVALID_ARGUMENT` or `INVALID_ID`. `references` names up to four Standard materials the stage reads
([Material references](#material-references)). `MaterialCommon` applies as for every family.

Edits go through the store:

```c3
assets.@set_custom_params(pulse_material, pulse)!;             // replace the payload, bump the revision
PulseParams* live = assets.@custom_params(pulse_material, PulseParams);
live.motion.x = 0;
assets.mark_material_dirty(pulse_material);                    // in-place edit
assets.set_custom_params(pulse_material, bytes)!;              // untyped bytes, may resize
```

Parameter and texture edits repack the material and re-upload the payload. They never rebuild pipelines.
`set_custom_params` faults `INVALID_ARGUMENT` on a material that is not custom.

## Fragment contract

A custom fragment stage declares the 16-byte graphics push block (as in the [Quick start](#quick-start)), reads
`DrawRoot` through `pc.fragment_root_gpu`, and finds its header and payload through `DrawRoot.material`.
`examples/shaders/custom/tint.frag.glsl` adds a masked discard, a double-sided normal flip and a loop over the frame's
lights with their shadows. To shade like the Standard family, call [`shade_standard_surface`](#standard-shading) instead
of writing the loop.

- `CustomMaterialGpu` (generated) carries `kind`, `flags` (`MATERIAL_ALPHA_MASK`, `MATERIAL_DOUBLE_SIDED`,
  `MATERIAL_ALPHA_BLEND`), `alpha_cutoff`, `map_flags` (bit `i` set when slot `i` is present, bit
  `i + CUSTOM_MAP_UV1_SHIFT` when it reads UV1), `slots[8]` as `TextureMapGpu`, `parameters` (the payload address) and
  `references` (the heap addresses of up to four referenced Standard blocks, zero when unused).
- `custom_material.glsl` supplies `custom_slot_present`, `custom_slot_texture`, `custom_map_uv`, `sample_custom_map`,
  `custom_reference` and the `material_mip_bias` global that `sample_standard_material` reads. `material_alpha.glsl`
  supplies `material_output`, which premultiplies for `BLEND`.
- The fragment inputs are the varyings of `mesh_vertex.glsl`, locations 0 to 6, 8 and 9 (and 7 in velocity passes). See
  [Varyings](custom_shaders_reference.md#varyings). The shared includes read only `FrameRoot` through `DrawRoot.frame`.
- A slot can hold an `R16_UINT` texture ([Textures](textures.md#sixteen-bit-single-channel-data)). The stage reads it
  with `gpu_fetch_uint(material.slots[i].texture_index, texel, 0)` (from gpu.c3l's `descriptor_heap.glsl`, which
  `custom_material.glsl` includes), never `sample_custom_map`. Slot 0 of a masked material cannot hold one: the material
  faults `UNSUPPORTED` when uploaded.
- A masked custom material (`alpha_mode == MASK`) discards in its own fragment stage. The shadow atlas reads the same
  header and uses slot 0's alpha against `alpha_cutoff` as the caster coverage. A custom caster's `DrawRoot.material` is
  always its `CustomMaterialGpu`, so a custom depth vertex form can read the payload.
- A blended custom material casts no shadow, with [colored shadows](shadows.md#colored-shadows) on or off.
  `shadow_transmittance` is the `vec3` form of `shadow_visibility` that carries the tint of the built-in translucent
  casters. A stage that calls `shadow_visibility` shows the opaque shadow only.

### View-provided slots

A slot built with `material::view_texture_slot(view_slot)`, or a `TextureSlot` whose `texture` is
`{ .kind = VIEW, .view_slot = n }`, holds no texture of its own. The view that draws the material supplies it:
`Renderer.set_view_texture(view, n, target)` binds a render target to the view's slot `n`, below `MAX_VIEW_TEXTURES`
(4). One material then shows the target of whichever view draws it ([view textures](views.md#view-textures)). The slot
keeps its sampler, UV set and transform. A stage resolves such a slot through the frame:

```glsl
if (custom_slot_present(frame, material, 0u)) {
    base_color *= sample_custom_map(frame, material, 0u, v_uv0, v_uv1, frame.mip_bias);
}
```

- `custom_slot_present(frame, material, slot)` is true for an asset or render-target slot that is present, and for a
  view-provided slot while `FrameRoot.view_textures[n]` holds a texture. `custom_slot_texture(frame, material, slot)` is
  the texture index to sample: the slot's own, the view's, or zero when the view provides none.
- The frame overloads of `sample_custom_map` return white for an absent view texture, as an empty asset slot does. A
  stage that wants another fallback tests `custom_slot_present(frame, ...)` first.
- The frame-less overloads read a view-provided slot as absent. The slot sets bit 31 of `TextureMapGpu.texture_index`
  (`VIEW_TEXTURE_FLAG`) and leaves its `map_flags` presence bit clear, so the depth stage's coverage and the traced
  coverage also see it absent.
- A view provides nothing in shadow layers, which are shared by every view that borrows the set, nor in probe updates
  and the path tracer. The slot reads as absent there. Traced hit shading shades a custom material as a constant grey
  Lambert albedo ([Reflections](reflections.md), [Path tracing](path_tracing.md)) and reads only slot 0's alpha. The
  depth prepass, G-buffer, velocity and scene-read passes of a view share its frame root and see its textures.
- A built-in material slot cannot hold a `VIEW` reference, and neither can slot 0 of a masked custom material:
  `Renderer.upload_material` faults `UNSUPPORTED`. A `view_slot` of `MAX_VIEW_TEXTURES` or above faults
  `INVALID_ARGUMENT`.

## Standard shading

`standard_shading.glsl` is the Standard model as functions. The built-in Standard forward stage and the lighting resolve
call them, so a custom stage that passes the sample Standard builds, with the same weight, returns Standard's radiance
on every view configuration:

```glsl
vec3 shade_standard_surface(FrameRoot frame, DrawRoot draw, StandardMaterialSample surface_sample,
                            float specular_weight, vec3 world_position, ivec2 pixel);
vec3 evaluate_standard_lights(FrameRoot frame, StandardSurface surface, vec3 world_position,
                              vec3 shadow_normal, uint layers, bool receive_shadow);
vec3 standard_ambient_fill(FrameRoot frame, vec3 base_color, float metallic, float occlusion,
                           float ambient_occlusion, vec4 screen_indirect);
```

`shade_standard_surface` returns linear radiance without alpha: the ambient fill, the emissive term, the environment
(when `frame_has_indirect(frame)`; the world position selects a [probe volume](probe_volumes.md) where one covers the
surface and up to two [reflection probes](reflection_probes.md)) and every selected light with its shadow. Pass it to
`material_output`. `evaluate_standard_lights` and `standard_ambient_fill` are its parts, for a stage that composes its
own environment term. Call `evaluate_standard_lights` from `main`, not from a helper: with software-traced shadows its
light loop is markedly slower below `main`. The caller fills the sample:

| Field | Contents |
| --- | --- |
| `base_color` | Linear, alpha included; alpha is not shaded |
| `metallic`, `roughness`, `occlusion` | In [0, 1] |
| `emissive` | Linear radiance |
| `normal` | Shading normal |
| `offset_normal` | Geometric normal for the shadow offset. Both normals flip for double-sided back faces, as `sample_standard_material` does |
| `view_direction` | `standard_view_direction(frame, world_position)` |

- `world_position` selects the probes and the lights, sets the light direction and starts the traced shadow ray. A
  forward stage passes [`v_shading_pos`](custom_shaders_reference.md#shading-position-varying), not `v_world_pos`, so
  that on a view with [`msaa`](msaa.md) above `ONE` the ray starts inside the triangle.
- `specular_weight` is 1 for Standard and 0 for a diffuse-only surface, the value a G-buffer stage passes to
  `write_gbuffer`.
- `pixel` is `ivec2(gl_FragCoord.xy)`. Ambient occlusion and [screen-space GI](screen_space_gi.md) follow the draw flags
  the renderer sets for the opaque list, custom draws included. They read 1 and no indirect term on views without them,
  for transparent draws and for [scene readers](#scene-reads).
- The field list of `StandardMaterialSample` is frozen. A new surface property arrives as a new parameter or a new
  struct, so a stage that initializes the sample field by field stays complete.

A G-buffer stage fills the same sample and calls `write_gbuffer`, and the lighting resolve runs the same functions. The
reference stages are `examples/shaders/custom/standard_twin.glsl` (include name `custom/standard_twin.glsl`) with
`standard_twin.frag.glsl` and `standard_twin_gbuffer.frag.glsl`. `twin_surface` builds Standard's sample from a payload
of base color, metallic, roughness, occlusion and emissive, with slot 0 as the base color map and slot 1 as a
tangent-space normal map. It does not reproduce vertex colors, the normal-map scale, derivative normals for meshes
without tangents or Standard's other maps, which stay in `sample_standard_material`.

## Material references

A custom material reads up to four Standard materials through `CustomParams.references`, for example the layers of a
splat material:

```c3
MaterialId[material::MAX_CUSTOM_MATERIAL_REFERENCES] layers = { [0] = grass, [1] = rock };
MaterialId splat = assets.add_material(material::custom(splat_shader, slots: splat_slots, references: layers))!;
```

- An entry is unused (the zero id) or a live `STANDARD` material. A dead id or another kind skips the custom material's
  draws and leaves its traced meshes out of the trace, both counted in `Stats.dangling_refs`, and makes
  `Renderer.upload(material)` fault `INVALID_ARGUMENT`. A referenced material's own `INVALID_ID` or `INVALID_ARGUMENT`
  (a slot whose `uv_set` is above 1, a comparison sampler) skips the custom draws the same way. Its other faults
  propagate.
- References are one level deep. The renderer uploads a referenced material, with its textures, whenever the custom
  material resolves, whether or not anything draws it.
- An edit to a referenced material needs only its own `mark_material_dirty`. Changing `references` is an edit of the
  custom material and needs `mark_material_dirty` on it.
- Each layer is sampled with its own maps, UV sets, transforms and samplers. There is no per-layer UV scale. The custom
  material's `common`, `flags` and `alpha_cutoff` govern raster state, masking and `material_output`.
- Traced hit shading reads slot 0's alpha as coverage and ignores the references.

In GLSL, `custom_reference(material, index)` returns the `index`-th referenced block as `StandardMaterialGpu`. An unused
entry is address zero, so a stage reads only the entries its material sets. Sample each layer with
`sample_standard_material`, blend the samples, and pass the blend to `shade_standard_surface` from `main`, or to
`write_gbuffer` in a G-buffer stage. This stage blends two layers by slot 1's red channel. It includes
`vertex_pull.glsl`, `custom_material.glsl` and `standard_shading.glsl`, and declares the inputs at locations 0 to 4 and
the push block of the [Quick start](#quick-start):

```glsl
StandardMaterialSample sample_layer(StandardMaterialGpu layer, GeometryRoot geometry, vec3 view_direction) {
    return sample_standard_material(
        layer,
        geometry,
        v_world_pos,
        v_normal,
        v_tangent,
        v_uv0,
        v_uv1,
        view_direction,
        !gl_FrontFacing
    );
}

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    material_mip_bias = frame.mip_bias;
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    float weight = sample_custom_map(material, 1u, v_uv0, v_uv1, frame.mip_bias).r;
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    vec3 view_direction = standard_view_direction(frame, v_world_pos);
    StandardMaterialSample first = sample_layer(custom_reference(material, 0u), geometry, view_direction);
    StandardMaterialSample second = sample_layer(custom_reference(material, 1u), geometry, view_direction);

    StandardMaterialSample blend = first;
    blend.base_color = mix(first.base_color, second.base_color, weight);
    blend.metallic = mix(first.metallic, second.metallic, weight);
    blend.roughness = mix(first.roughness, second.roughness, weight);
    blend.occlusion = mix(first.occlusion, second.occlusion, weight);
    blend.emissive = mix(first.emissive, second.emissive, weight);
    blend.normal = normalize(mix(first.normal, second.normal, weight));

    vec3 color = shade_standard_surface(frame, draw, blend, 1.0, v_world_pos, ivec2(gl_FragCoord.xy));
    out_color = material_output(color, 1.0, material.flags);
}
```

`offset_normal` and `view_direction` are the same for both layers, so `blend` keeps the first layer's.

## Explicit gradients and tangents

`sample_standard_material` takes its texture derivatives from the stage's own coordinates and derives a normal-map frame
from the geometry. A stage that projects its own coordinates, such as a planar or triplanar mapping, calls
`sample_standard_material_grad` instead:

```glsl
StandardMaterialSample sample_standard_material_grad(
    StandardMaterialGpu material,
    vec3 vertex_normal,
    vec4 tangent,
    MaterialUvGrad uv,
    vec3 view_direction,
    bool back_face
);
```

- `MaterialUvGrad` holds one projected `uv` with its screen-space derivatives `uv_dx` and `uv_dy`, normally `dFdx` and
  `dFdy` of `uv`, taken in uniform control flow. Every map is sampled with `textureGrad` at them, so the call takes no
  implicit derivatives of its own and a stage calls it once for each projection. Each map's `uv_linear` applies to the
  gradients as it does to `uv`, and `material_mip_bias` scales them, so the bias matches `sample_standard_material`.
- One `uv` feeds every map: each map's UV-set selection is ignored, and its transform still applies.
- `tangent` orients normal maps. It is a unit vector perpendicular to the normalized `vertex_normal`, with the bitangent
  `cross(normal, tangent.xyz) * tangent.w`. The call never derives a frame. A zero tangent keeps the geometry normal.
- The rest of the sample is `sample_standard_material`'s: factors, maps and the double-sided flip.

## Displace vertices

A custom vertex stage includes `mesh_vertex.glsl`, which declares the push block, the varyings and the helpers
`pull_mesh_vertex`, `apply_mesh_deformation` and `write_mesh_outputs`. The stage applies its displacement between
pulling and writing:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PulseParams {
    vec4 color;
    vec4 motion;
};

vec3 pulse_position(vec3 local_position, float time, vec4 motion) {
    return local_position + vec3(0.0, motion.x * sin(time * motion.y + motion.z), 0.0);
}

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

Compile the same source more than once for the forms the shader supplies:

| Form | Define | Used for |
| --- | --- | --- |
| `vertex.shaded` | none | Forward pass |
| `vertex.depth` | `DEPTH_ONLY` | Shadow atlas; `write_mesh_outputs` writes only what the depth stage reads |
| `vertex.instanced_shaded`, `vertex.instanced_depth` | `INSTANCED` (with `DEPTH_ONLY`) | [Instanced batches](instancing.md); `write_mesh_outputs` reads the instance's matrices and color |
| `vertex.velocity`, `vertex.instanced_velocity` | `VELOCITY` (with `INSTANCED`) | The [velocity form](#velocity-form) |

`FrameRoot.jitter_time.z` is scene time. The [vertex contract](custom_shaders_reference.md#vertex-contract) covers
instance access, sway and fade, clip distance, varyings and the limits of a custom vertex stage.

### Velocity form

Motion blur, TAA, screen-space GI, temporal ambient occlusion and the reflection history read the view's velocity image.
Its geometry pass redraws each moved item with depth test `EQUAL` and no depth write. A custom vertex stage makes its
own displacement visible there through a velocity form: `velocity` for meshes and `instanced_velocity` for batches, the
same source compiled with `VELOCITY` (and `INSTANCED`). The `pulse` example's body:

```glsl
    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    PulseParams params = PulseParams(material.parameters);
    vertex.position = pulse_position(vertex.position, frame.jitter_time.z, params.motion);
#ifdef VELOCITY
    vec3 previous = pulse_position(previous_mesh_position(draw, geometry, index), frame.previous_time, params.motion);
    write_mesh_outputs(vertex, previous, draw, frame, geometry);
#else
    write_mesh_outputs(vertex, draw, frame, geometry);
#endif
```

- `previous_mesh_position(draw, geometry, index)` exists only under `VELOCITY`. It is the object-space position under
  the skin and morph the view drew last time.
- `write_mesh_outputs(vertex, previous_position, draw, frame, geometry)` takes the previous object-space position with
  the stage's displacement applied. Every other form ignores it. The four-argument call passes `previous_mesh_position`
  in a velocity form, so a velocity form that ends in it sees the undisplaced previous position.
- `FrameRoot.previous_time` is the `FrameInfo.time` of the view's last rendering, narrowed to float like
  `jitter_time.z`. It equals `jitter_time.z` on a view's first rendering, after `render::reset_view_history`,
  `configure_view`, a resize or an aborted frame, on a view without motion blur, TAA, screen-space GI, temporal ambient
  occlusion or reflection history, and in shadow, path-traced and probe roots.
- A velocity form computes its current position exactly as its depth form does, with the same source and expressions and
  only `VELOCITY` added. The pass tests `EQUAL` against the depth the depth or shaded form wrote.
- An item whose shader has the velocity form is redrawn on every rendering whose view has its node in history, also at a
  still node. At frozen time and rest its velocity equals the camera velocity. The previous displacement uses the
  current material parameters at the previous time, so a parameter edit shows no motion of its own.
- Call `render::reset_view_history` after a jump in `FrameInfo.time` (a seek, a loaded save), as after a camera cut.
  `jitter_time.z` and `previous_time` are floats: from 65,536 s (about 18 h) each rounds to within 1/256 s, and their
  difference is off by up to 1/128 s (about half of a 60 Hz step). An application that runs that long wraps its time and
  resets the history at the wrap.
- Without a velocity form, the velocity pass uses the built-in `mesh` variant and sees the undisplaced mesh. A velocity
  stage that does not include `mesh_vertex.glsl` follows the
  [stage rules](custom_shaders_reference.md#velocity-stages-without-mesh_vertexglsl).

## G-buffer stage

`ShaderDesc.gbuffer` is an optional second fragment stage. A shader that supplies it is G-buffer capable. On a
`DEFERRED` view its opaque and masked draws join the G-buffer list and the lighting resolve lights them, like
`STANDARD`. On a `FORWARD` view, and for `BLEND` materials, the `fragment` stage keeps drawing. A shader without the
stage routes forward on every view. No material field selects the route. A shader that declares
[scene reads](#scene-reads) has no G-buffer stage.

The stage consumes the same inputs as the forward stage and writes the five G-buffer outputs of `gbuffer_output.glsl`.
Fill a `StandardMaterialSample` and call `write_gbuffer(sample, specular_weight, draw)`, or write locations 0 to 4
directly. Lighting, ambient and environment terms then come from the resolve, so a forward stage that computes less than
the Standard model (the `pulse` example is diffuse only) differs from its G-buffer route by those terms. A forward stage
that calls `shade_standard_surface` with the sample and weight its G-buffer stage writes matches that route, as the
Standard twin does. `examples/shaders/custom/pulse_gbuffer.frag.glsl` is the reference.

- `write_gbuffer` also packs the `trace_proxy_skip_height` global (from `trace_surface.glsl`, declared through the
  include) into the upper 16 bits of the flags output (`GBUFFER_PROXY_SKIP_SHIFT`, in steps of
  `GBUFFER_PROXY_SKIP_UNIT`). A stage that writes location 4 itself keeps those bits for the lighting resolve and the
  traced effects. A material whose traced stand-in can sit above its surface raises the height before shading
  ([trace proxies](scene_trace.md#trace-proxies)). It stays zero otherwise.
- On a `DEFERRED` view with [`msaa`](msaa.md) above `ONE` the stage writes the multisample
  G-buffer. The stage source does not change, and it still shades once per pixel and primitive.
- `CustomMaterialGpu.capabilities` carries `CUSTOM_CAPABILITY_GBUFFER` when the stage is present. A rejected G-buffer
  stage leaves the forward stage of the same shader drawing.

## Additive output and fog

Set `MaterialCommon.alpha_mode = BLEND` and `blend_mode = ADDITIVE` for additive RGB with the destination alpha
preserved. Custom stages emit premultiplied RGB and coverage through `material_output`, as for ordinary blended
materials. Material, texture and vertex opacity scale the contribution, and the output alpha need not be zero.
`MATERIAL_BLEND_ADDITIVE` is set in the packed flags only for this combination.

The public `fog.glsl` include supplies `apply_material_fog(frame, world_position, color, material_flags)`. It returns
straight RGB after fog: color times transmittance for additive materials, plus in-scatter for source-over materials.
Apply coverage afterward, once, through `material_output`. With no fog the input color is unchanged.

The three-argument `apply_fog` applies source-over behavior. An additive stage uses the material-aware helper to avoid
another fog-color contribution over the background. Both helpers use the current view's analytic or volumetric fog.
Declare scene reads only when the stage also samples a scene snapshot, such as depth for soft fading.

For weighted transparency, a blended stage also supplies a weighted form
([reference](custom_shaders_reference.md#weighted-form)).

## Scene reads

A custom fragment stage can sample the rendered scene behind it: its color for refraction, its depth for absorption,
soft particles, depth fog or decals. `ShaderDesc.scene_reads` declares what the stage samples:

```c3
ShaderDesc desc = {
    .fragment    = water_spirv,
    .scene_reads = { .color, .depth },
};
```

A shader with a nonzero `scene_reads` has no G-buffer stage: `add_shader` and `replace_shader` fault `INVALID_ARGUMENT`
on the pair.

- **Routing.** An opaque or masked reader draws in the scene-read list, the list
  [Physical transmission](transparency.md#physical-transmission) uses: after opaque, masked and the sky, sorted far to
  near by bounds center, in a pass that keeps `MaterialCommon.depth_write`, so water writes depth for what follows. A
  blended reader stays in the transparent list, sorted with every other blend, and never writes depth.
- **Snapshots.** Before each list that holds a reader, the renderer copies the finished scene into the view's snapshot
  images, only the kinds the list's draws declare. A layer's snapshot holds opaque, masked and sky plus the layers drawn
  before it. The transparent list's snapshot also holds all the scene-read draws. At the default
  `ViewDesc.transmission_layers` of 1 a view copies at most twice per frame. Above 1 it copies at most
  `transmission_layers + 1` times, and custom readers are layered like glass
  ([transmission layers](transparency.md#transmission-layers)). No reader sees ordinary blends or the other draws of its
  own layer.
- **Memory.** A view whose frame draws no reader copies nothing. Each image is allocated at the view's working extent
  the first time a frame needs it and kept until the view's images are released. `scene_color` is `RGBA16_FLOAT` (8
  bytes per pixel at mip zero; its mip chain adds about a third). Only
  [Physical transmission](transparency.md#physical-transmission) fills the mip chain; the helpers below read mip zero.
  `scene_depth` is `R32_FLOAT` and holds the reverse-Z depth bit for bit (4 bytes per pixel).
- **MSAA.** On a view with [`msaa`](msaa.md) above `ONE`, the snapshots and the scene-read
  list record after the resolve: a reader samples single-sample color and depth and draws single-sample. A custom stage
  in the opaque list runs in the multisample pass and still shades once per pixel.
- **Extent and jitter.** The snapshots have the view's working extent and share the frame's jittered matrices, so render
  scale and TAA need nothing from the shader.
- **Screen-space terms.** Readers get no screen-space terms: `draw_ambient_occlusion` returns 1, `draw_bent_normal`
  returns the normal it is given and `draw_screen_space_indirect` returns zero.
- **Fog.** Snapshots are taken before the view's fog pass, so readers see unfogged radiance, and a color read also takes
  a depth snapshot ([where fog applies](fog.md#where-fog-applies)). The pass fogs a depth-writing reader at its own
  depth. A refracting reader returns `apply_fog_refracted(...)` so its refracted sample is fogged to its own depth. A
  blended reader draws after the pass and composes `apply_fog(frame, position, apply_fog_refracted(...))`. A blended
  stage that does not refract calls `apply_fog` on its output. A custom twin of Standard matches it the same way: an
  opaque twin needs nothing, and a blended twin calls `apply_fog`.

`scene_snapshot.glsl` samples the snapshots through `FrameRoot.scene_color` and `FrameRoot.scene_depth`. Include it
after `generated/shader_abi.glsl` and `c3d_abi.glsl`:

| Helper | Needs | Returns |
| --- | --- | --- |
| `scene_uv(frame, gl_FragCoord.xy)` | nothing | The fragment's snapshot uv, origin at the top left |
| `scene_color_at(frame, uv)` | `color` | The scene color, linearly filtered, mip zero |
| `scene_depth_at(frame, uv)` | `depth` | The reverse-Z depth of the nearest texel; 0 is background |
| `scene_view_distance_at(frame, uv)` | `depth` | The forward distance of that depth |
| `scene_position_at(frame, uv)` | `depth` | The world position; test `scene_depth_at` for background first |
| `scene_depth_gap(frame, gl_FragCoord)` | `depth` | The forward distance from the fragment to the scene behind it |

Only the `fragment` stage of a custom material can call them, and only for the images its `scene_reads` declares. Vertex
stages cannot, and compute dispatches keep `read_view_color` and `read_view_depth`. Background pixels read depth 0.
`scene_view_distance_at` returns `BACKGROUND_VIEW_DISTANCE` under an infinite far plane and the far distance otherwise.

`Stats.scene_snapshots` counts the images copied in the frame, and each copy also counts one `Stats.draws`.
`Pass.SCENE_SNAPSHOT` times the copies, `Pass.SCENE_MIPS` the transmission mip chain and `Pass.SCENE_READ` the
scene-read list. `gui::targets_panel` lists `scene_color` and `scene_depth`, and `PreviewKind.VIEW_SCENE_DEPTH` previews
`scene_depth` as distance.

## Reload

```c3
assets.replace_shader(shader, &new_desc)!;
if (catch excuse = renderer.upload(shader)) { /* SHADER_INVALID or PIPELINE_CREATE_FAILED */ }
```

`replace_shader` copies the new stages and advances the revision. The renderer notices the moved revision at the next
frame that draws the material, or immediately through `Renderer.upload(shader)`. It rebuilds every pipeline built from
the old revision from the new stages first:

- On total success the renderer publishes the new set and retires the old handles after the frames that can reference
  them complete.
- On a backend rejection nothing is published. The previous pipelines and payload keep drawing, gpu.c3l's diagnostic
  lands in the renderer's `DebugLog` and on stderr, and `Stats.shader_rejections` counts it. The renderer retries
  neither a rejected replacement nor a rejected configuration until the shader is replaced again. `upload` returns the
  fault.
- A configuration that fails on first use (a forward pipeline, a shadow caster's depth form, a velocity form) skips
  those draws until the shader is replaced. Other configurations of the same shader keep drawing.

A rejected revision never draws, in any pass: the renderer builds every pipeline and makes every routing decision
(forward or G-buffer, scene reads, depth, velocity and traced forms) from the published revision's stages. A material's
payload is checked against the published revision's `param_block_size`: a payload sized for a rejected revision skips
its draws and counts in `Stats.dangling_refs`. While a replacement that drops the instanced pair is rejected, extraction
skips the batch and counts it in `Stats.dangling_refs`, although the published revision could draw it. The published
copy holds the stage bytes a second time and is never allocated per frame. Bytes edited in place in the store reach the
renderer through `mark_shader_dirty` or `upload` only. The first revision builds nothing until first use. Repeated use
of one revision and configuration reuses its pipeline, and a new configuration (a wireframe toggle, a shadow caster)
adds one entry.

## In-process compilation

With the `C3D_SHADER_COMPILER` feature and `shaderc` in the consumer's dependencies, `c3d::shader::compile` compiles
GLSL without a filesystem:

```c3
import c3d::asset;
import c3d::shader::compile;

String log;
ShaderInclude[1] includes = { { .name = "custom/standard_twin.glsl", .text = twin_include_text } };
char[]? spirv = compile::compile_glsl(
    allocator:  tmem,
    source:     glsl_text,
    stage:      ShaderStage.FRAGMENT,
    defines:    { "RT_SHADOWS" },
    debug_name: "standard_twin.frag",
    log:        &log,
    includes:   includes[..],
);
```

The compiler targets Vulkan 1.3 semantics and SPIR-V 1.5 like the offline build. `defines` are defined as `1`. `stage`
is `VERTEX`, `FRAGMENT` or `COMPUTE`.

`#include` resolves against the embedded table `shader::SHADER_INCLUDES` first: every file under `shaders/common/`,
`shaders/generated/` and `shaders/gpu/` (a copy of gpu.c3l's `include/shaders/`), by the same names the built-in shaders
use. It then searches the optional `includes`, in order: an application's or a [shader package's](shader_packages.md)
own includes, borrowed for the call. Names match exactly and the first match wins, so a caller entry never replaces an
embedded file. An include written relative to its sibling (`"params.glsl"` inside `app/`) does not resolve: write the
full name (`"app/params.glsl"`). An include in neither table is a compile error.

`compile_glsl` faults `SHADER_COMPILE_FAILED`, which carries no text. The optional `log` receives the compiler messages,
including warnings on success. Without the feature the module does not exist and `shaderc` is not linked. `ShaderDesc`
still takes SPIR-V bytes from any other producer.

## Limits

- Custom vertex stages have one compiled form per pass ([vertex contract](custom_shaders_reference.md#vertex-contract)).
- Fragment-only custom materials with `AlphaMode.BLEND` can also shade core [billboard batches](billboards.md) and
  [ribbon batches](ribbons.md). Core supplies their view-facing vertex stages. Custom vertex forms are not compatible
  with those primitives.
- Traced hit shading shades a custom material as a constant grey Lambert albedo with slot 0's alpha as coverage.
- A displaced mesh traces only through a [trace-pose stage](custom_shaders_reference.md#trace-pose).
- Scene readers get no screen-space terms and have no G-buffer stage.
- A shader without the instanced pair draws no instanced batch.

Run `python3 scripts/build.py --example custom_shader` for the tint and pulse materials with live reload. The
`shading_paths` example compares a `standard_twin` sphere with the Standard material. `custom_compute` and
`compute_textures` cover [compute dispatch](compute.md).

## See also

- [Custom shaders reference](custom_shaders_reference.md)
- [Compute dispatch](compute.md) and [Shader packages](shader_packages.md)
- [Materials](materials.md) and [Transparency](transparency.md)
- [Scene tracing](scene_trace.md), [Instancing](instancing.md), [Views](views.md)
