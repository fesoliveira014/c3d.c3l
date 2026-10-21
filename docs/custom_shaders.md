# Custom shaders

Fragment-only custom materials with `AlphaMode.BLEND` can also shade core
[billboard batches](billboards.md) and [ribbon batches](ribbons.md). Core supplies their
view-facing vertex stages; custom vertex forms are not compatible with those primitives.

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

Every byte array is copied. `fragment` is required. `vertex` is optional; when present both forms are required: `shaded` for the forward pass and `depth` for the shadow atlas, so a deformation is applied to the caster too. `instanced_shaded` and `instanced_depth` are the same pair compiled with `INSTANCED`, for [instanced batches](instancing.md); they are optional and need the plain pair. `velocity` is the source compiled with `VELOCITY` and `instanced_velocity` the source compiled with `VELOCITY` and `INSTANCED`, for the [velocity pass](#velocity-form); both are optional, `velocity` needs the plain pair, and `instanced_velocity` needs the instanced pair and `velocity`. `traced_fragment.hardware` and `traced_fragment.software` are the forward stage compiled for views that trace shadows ([traced shadows](#traced-shadows)); either may be empty or supplied alone, and neither is validated. `weighted_fragment.shaded`, `weighted_fragment.traced.hardware` and `weighted_fragment.traced.software` are the forward stage compiled with `WEIGHTED_BLEND` for views that compose blended surfaces by weight ([weighted transparency](#weighted-transparency)); each may be empty or supplied alone, and none is validated. `trace_pose` holds the compute sources that pose the shader's geometry for [scene traces](#trace-pose): `single` for a mesh, `instanced` for one instance of a batch, and `reads_time` when the stage reads the frame time; both forms are optional. `depth` is the [prepass stage](#prepass-stage), optional and unpaired. `trace_pose_grid` declares that the stages index through `trace_pose_index`, which a row past the 1-D dispatch limit needs. `add_shader` and `replace_shader` fault `INVALID_ARGUMENT` on an empty fragment, a half pair, an instanced or velocity form without the forms it needs, a `trace_pose.single` without `vertex.shaded`, a `trace_pose.instanced` without `vertex.instanced_shaded`, or a `gbuffer` stage with nonzero [`scene_reads`](#scene-reads). `param_block_size` is the byte size of the payload the shader reads; zero means none, and a shader whose size is zero must not read `parameters` (the address is zero). `asset::copy_shader_desc` and `asset::free_shader_desc` deep-copy and free a desc with any allocator.

The SPIR-V can come from anywhere: `$embed`ed `.spv` files, a build step, or the in-process compiler below.

## Custom material

```c3
PulseParams pulse = { .color = { 0.3f, 0.6f, 1, 1 }, .motion = { 0.4f, 3, 0, 0 } };
TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
slots[0] = material::texture_slot(base_texture);
MaterialId pulse_material = assets.add_material(material::custom(shader, material::@as_bytes(pulse), slots))!;
```

The payload bytes are copied into the store. Their layout is the application's: write a C3 struct matching the std430 layout the shader declares and pass its bytes through `material::@as_bytes`. The length must equal the shader's `param_block_size`; a mismatch, or a dead shader id, skips the material's draws (counted in `Stats.dangling_refs`) and makes `Renderer.upload(material)` fault `INVALID_ARGUMENT` or `INVALID_ID`.

`references` names up to `MAX_CUSTOM_MATERIAL_REFERENCES` (4) Standard materials the stage reads ([material references](#material-references)).

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

World-position shader values use [camera-relative coordinates](large_world.md).
`FrameRoot.origin.xyz` gives the absolute offset. Core draw models, camera and
light positions, clip planes, scene reconstruction and tracing already use the
same relative space. Convert application-supplied absolute payload positions
before combining them with those values. Local geometry, palettes and directions
keep their existing spaces. Rebuild consumer SPIR-V against the appended frame
root layout; do not hand-copy the ABI. A stage built before `FrameRoot.pre_exposure`
existed must also route the radiance it emits itself through `pre_exposed`
([pre-exposure](#pre-exposure)). `write_mesh_outputs` also handles previous
origins and LOD history for published velocity stages.

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

`CustomMaterialGpu` (generated, 320 bytes) carries `kind`, `flags` (`MATERIAL_ALPHA_MASK`, `MATERIAL_DOUBLE_SIDED`, `MATERIAL_ALPHA_BLEND`), `alpha_cutoff`, `map_flags` (bit `i` = slot `i` present, bit `i + CUSTOM_MAP_UV1_SHIFT` = slot `i` reads UV1), `slots[8]` as `TextureMapGpu`, `parameters`, the payload address, and `references`, the heap addresses of up to four referenced Standard blocks (0 when unused). `custom_material.glsl` supplies `custom_slot_present`, `custom_slot_texture`, `custom_map_uv`, `sample_custom_map` and `custom_reference`; `material_alpha.glsl` supplies `material_output`, which premultiplies for BLEND. Vertex inputs are the fixed locations 0 to 6, 8 and 9 written by `mesh.vert.glsl`; location 8 is [`v_billboard`](#billboard-varying) and location 9 is [`v_shading_pos`](#shading-position-varying). The shared includes read only `FrameRoot` through `DrawRoot.frame`.

A slot may hold an `R16_UINT` texture (see [sixteen-bit single-channel data](textures.md#sixteen-bit-single-channel-data)). The stage reads it with `gpu_fetch_uint(material.slots[i].texture_index, texel, 0)`, never `sample_custom_map`; slot 0 of a masked material cannot hold one, and the material faults `UNSUPPORTED` when uploaded.

A masked custom material (`alpha_mode == MASK`) discards in its own fragment stage; the shadow atlas reads the same header and uses slot 0's alpha against `alpha_cutoff` as the caster coverage. A custom caster's `DrawRoot.material` is always its `CustomMaterialGpu`, so a custom depth vertex form can read the payload. A blended custom material casts no shadow, with [colored shadows](shadows.md#colored-shadows) on or off. `shadow_transmittance` is the `vec3` form of `shadow_visibility` that carries the tint of the built-in translucent casters; a stage that calls `shadow_visibility` shows the opaque shadow only.

### View-provided slots

A slot built with `material::view_texture_slot(view_slot)`, or a `TextureSlot` whose `texture` is `{ .kind = VIEW, .view_slot = n }`, holds no texture of its own. The view that draws the material supplies it: `Renderer.set_view_texture(view, n, target)` binds a render target to the view's slot `n`, below `MAX_VIEW_TEXTURES` (4). One material then shows the target of whichever view draws it ([view textures](views.md#view-textures)). The slot keeps its sampler, UV set and transform.

A stage resolves such a slot through the frame:

```glsl
if (custom_slot_present(frame, material, 0u)) {
    base_color *= sample_custom_map(frame, material, 0u, v_uv0, v_uv1, frame.mip_bias);
}
```

- A view-provided slot sets bit 31 of its `TextureMapGpu.texture_index` (`VIEW_TEXTURE_FLAG`); the low bits are the view's slot. Its `map_flags` presence bit stays clear, so every reader that does not take the frame sees the slot absent: the depth stage's coverage and the traced coverage read `custom_slot_present(material, slot)`.
- `custom_slot_present(frame, material, slot)` is true for an asset or render-target slot that is present, and for a view-provided slot while `FrameRoot.view_textures[n]` holds a texture. `custom_slot_texture(frame, material, slot)` is the texture index to sample: the slot's own, or the view's, or zero when the view provides none.
- The frame overloads of `sample_custom_map` sample `custom_slot_texture` and return white (1, 1, 1, 1) for an absent view texture, as an empty asset slot does. A stage that wants a different fallback tests `custom_slot_present(frame, ...)` first.
- A view that provides nothing for the slot reads it as absent, so the stage's own fallback runs.

The frame-less `custom_slot_present` and `sample_custom_map` keep their signatures and their results for asset and render-target slots. For a view-provided slot they read absent: `custom_slot_present(material, slot)` is false and `sample_custom_map(material, slot, ...)` returns white without touching the descriptor heap. A stage compiled before the slot kind existed never meets one unless the application assigns it.

Where a view provides nothing:

- Shadow layers render from the light and are shared by every view that borrows the set, so they write no view textures. A custom depth form reads such a slot as absent.
- The forward depth prepass, the G-buffer, velocity and scene-read passes of a view share the view's frame root and see its textures.
- Probe updates and the path tracer provide none. Traced hit shading shades a custom material as a constant grey Lambert albedo ([reflections](reflections.md), [path tracing](path_tracing.md)) and reads only slot 0's alpha, which a view-provided slot never holds.

A built-in material slot cannot hold a `VIEW` reference, nor can slot 0 of a masked custom material: `Renderer.upload_material` faults `UNSUPPORTED`. A `view_slot` of `MAX_VIEW_TEXTURES` or above faults `INVALID_ARGUMENT`.

### Standard shading

`standard_shading.glsl` is the Standard model as functions. The built-in Standard forward stage and the lighting resolve call them, so a custom stage that passes the sample Standard builds, with the same weight, returns Standard's radiance on every view configuration:

```glsl
vec3 shade_standard_surface(FrameRoot frame, DrawRoot draw, StandardMaterialSample surface_sample,
                            float specular_weight, vec3 world_position, ivec2 pixel);
vec3 evaluate_standard_lights(FrameRoot frame, StandardSurface surface, vec3 world_position,
                              vec3 shadow_normal, uint layers, bool receive_shadow);
vec3 standard_ambient_fill(FrameRoot frame, vec3 base_color, float metallic, float occlusion,
                           float ambient_occlusion, vec4 screen_indirect);
```

`shade_standard_surface` returns linear radiance without alpha: the ambient fill, the emissive term, the environment (when `frame_has_indirect(frame)`; the frame and the world position select a [probe volume](probe_volumes.md) where one covers the surface and up to two [reflection probes](reflection_probes.md) for the specular term) and every selected light with its shadow. Pass it to `material_output`. `evaluate_standard_lights` and `standard_ambient_fill` are its parts, for a stage that composes its own environment term. Call `evaluate_standard_lights` from `main`: with software-traced shadows its light loop costs about twice as much when it runs two calls below `main`, which is why `shade_standard_surface` expands the same loop in place instead of calling it. The caller fills the sample:

| Field | Contents |
| --- | --- |
| `base_color` | Linear, alpha included; alpha is not shaded |
| `metallic`, `roughness`, `occlusion` | In [0, 1] |
| `emissive` | Linear radiance |
| `normal` | Shading normal |
| `offset_normal` | Geometric normal for the shadow offset. Both normals are flipped for double-sided back faces, as `sample_standard_material` does |
| `view_direction` | `standard_view_direction(frame, world_position)` |

`world_position` selects the probes and the lights, sets the light direction and starts the traced shadow ray. A forward stage passes [`v_shading_pos`](#shading-position-varying), not `v_world_pos`, so that on a view with [`msaa`](views.md#multisample-anti-aliasing) above `ONE` the ray starts inside the triangle.

`specular_weight` is 1 for Standard and 0 for a diffuse-only surface, the value a G-buffer stage passes to `write_gbuffer`. `pixel` is `ivec2(gl_FragCoord.xy)`: ambient occlusion and [screen-space GI](screen_space_gi.md) follow the draw flags the renderer sets for the opaque list, custom draws included, and read 1 and no indirect term on views without them, for transparent draws and for [scene readers](#scene-reads). The field list of `StandardMaterialSample` is frozen: a new surface property arrives as a new parameter or a new struct, never a new field, so a stage that initializes the sample field by field stays complete. A G-buffer stage fills the same sample and calls `write_gbuffer`; the resolve runs the same functions.

The reference is `examples/shaders/custom/standard_twin.glsl` (include name `custom/standard_twin.glsl`) with `standard_twin.frag.glsl` and `standard_twin_gbuffer.frag.glsl`. `twin_surface` builds Standard's sample from a payload of base colour, metallic, roughness, occlusion and emissive, with slot 0 as the base colour map and slot 1 as a tangent-space normal map. Vertex colours, the normal-map scale, derivative normals for meshes without tangents and Standard's other maps stay in `sample_standard_material`; the twin does not reproduce them.

### Material references

A custom material reads up to four Standard materials through `CustomParams.references`, for example the layers of a splat material:

```c3
MaterialId[material::MAX_CUSTOM_MATERIAL_REFERENCES] layers = { [0] = grass, [1] = rock };
MaterialId splat = assets.add_material(material::custom(splat_shader, slots: splat_slots, references: layers))!;
```

- An entry is unused (the zero id) or a live `STANDARD` material. A dead id or another kind skips the custom material's draws and counts them in `Stats.dangling_refs`, leaves its traced meshes out of the trace (counted the same way), and makes `Renderer.upload(material)` fault `INVALID_ARGUMENT`. A referenced material's own `INVALID_ID` or `INVALID_ARGUMENT` (a slot whose `uv_set` is above 1, a comparison sampler) skips the custom draws the same way; its other faults propagate.
- References are one level deep. A referenced material is uploaded, with its textures, whenever the custom material resolves, whether or not anything draws it.
- An edit to a referenced material needs only its own `mark_material_dirty`: its block is rewritten in place at the same address, and the custom block stays current. Changing `references` is an edit of the custom material and needs `mark_material_dirty` on it.
- Each layer is sampled with its own maps, UV sets, transforms and samplers. There is no per-layer UV scale.
- The custom material's `common`, `flags` and `alpha_cutoff` govern raster state, masking and `material_output`; the layer blocks supply factors and maps.

In GLSL, `custom_reference(material, index)` returns the `index`-th referenced block as `StandardMaterialGpu`. An unused entry is address zero, so a stage reads only the entries its material sets. Sample each layer with `sample_standard_material`, blend the samples, and pass the blend to `shade_standard_surface` from `main`, or to `write_gbuffer` in a G-buffer stage. Two layers blended by slot 1's red channel, in a stage that declares the inputs and push block of [the fragment contract](#fragment-contract) and includes `descriptor_heap.glsl`, `vertex_pull.glsl`, `custom_material.glsl` and `standard_shading.glsl`:

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

Traced hit shading (probe updates, reflections, the path tracer) reads a custom material as before, with slot 0's alpha as coverage, and ignores its references. `begin_prepare_model` uploads a referenced material's textures inside the custom material's unit, not as units of their own.

### Explicit gradients and tangents

`sample_standard_material` takes its texture derivatives from the stage's own coordinates and derives a normal-map frame from
the geometry. A stage that projects its own coordinates, such as a planar or triplanar mapping, calls
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

- `MaterialUvGrad` holds one projected `uv` with its screen-space derivatives `uv_dx` and `uv_dy`, normally
  `dFdx` and `dFdy` of `uv`, taken in uniform control flow. Every map is sampled with `textureGrad` at them, so the call
  takes no implicit derivatives of its own and a stage calls it once for each projection. Each map's `uv_linear`
  applies to the gradients as it does to `uv`, and `material_mip_bias` scales them, so the bias matches
  `sample_standard_material`.
- One `uv` feeds every map: each map's UV-set selection is ignored, and its transform still applies.
- Normal maps are oriented by `tangent`, a unit vector perpendicular to the normalised `vertex_normal`, with the bitangent
  `cross(normal, tangent.xyz) * tangent.w`. The call never derives a frame. A zero tangent keeps the geometry normal.
- The rest of the sample is `sample_standard_material`'s: factors, maps and the double-sided flip.

### Public includes

A custom or package stage starts with the prelude, `generated/shader_abi.glsl` (gpu.c3l) and `c3d_abi.glsl`, then includes what it uses. The includes below are the contract for custom and package stages: each compiles after the prelude alone, which the build checks on every run by compiling one probe per row of `public_includes` in `shaders/variants.json` (a probe that fails stops the shaders step with `public include <name> is not self-contained` and glslang's output). The other files of the embedded set resolve too but may change without notice.

| Include | Public surface |
| --- | --- |
| `constants.glsl` | `PI` |
| `material_uv.glsl` | `custom_slot_present` (with or without the frame), `custom_slot_texture`, `custom_map_uv` ([view-provided slots](#view-provided-slots)) |
| `material_alpha.glsl` | `material_output` |
| `blend_output.glsl` | `write_blend_output`, the `out_color` output and, under `WEIGHTED_BLEND`, the `out_revealage` output ([weighted transparency](#weighted-transparency)); includes `pre_exposure.glsl` |
| `pre_exposure.glsl` | `pre_exposed` ([pre-exposure](#pre-exposure)); fragment and compute stages |
| `custom_material.glsl` | `sample_custom_map` (the plain and biased overloads, each with or without the frame), `custom_reference` |
| `normal_mapping.glsl` | `decode_normal`, `tangent_normal`, `derivative_normal`, `derivative_tangent`, `surface_tangent_frame` |
| `noise.glsl` | `interleaved_gradient_noise`, `pcg_hash`, `hash_unit` |
| `texture_fetch.glsl` | `fetch_texture_2d`, `texture_extent`, `sample_texture_2d_lod` |
| `gbuffer.glsl` | `reconstruct_world_position`, `view_distance`, `BACKGROUND_VIEW_DISTANCE`, `encode_octahedral`, `decode_octahedral` |
| `brdf.glsl` | `StandardSurface`, `prepare_surface`, `prepare_standard_surface`, `apply_anisotropy`, `apply_surface_anisotropy`, `evaluate_standard_lobes`, `evaluate_standard_brdf`, `fresnel_schlick` |
| `lights.glsl` | `LightArray`, `LightList`, `LightSample`, `select_lights`, `flat_lights`, `selected_light_index`, `sample_light`, `light_casts_shadow`, `standard_view_direction`, `evaluate_standard_light` |
| `shadows.glsl` | `shadow_visibility`, `shadow_transmittance`; both include the [cloud layer's shadow](sky.md#cloud-shadows) and the [media's sun column](sky.md#medium-volumes) for the sun, and a sun without shadow layers gets both through the `light_casts_shadow` gate. `shadow_transmittance` keeps the column's channels; `shadow_visibility` takes their mean |
| `ibl.glsl` | `frame_has_indirect`, `indirect_diffuse_irradiance` (with or without an `irradiance_direction`), `evaluate_environment` (both), `evaluate_environment_lobes` (with or without an `irradiance_direction` and a `ReflectionSelection`), `environment_lobe_radiance`, `environment_tables` |
| `probe_classification.glsl` | `probe_classification(ProbeVolumeGpu, uvec3)` reads a valid probe's live provisional/eligible/excluded state; compiled in fragment and compute stages |
| `reflection_probe.glsl` | `ReflectionSelection`, `reflection_probe_select`, `reflection_probe_weight`, `reflection_box_direction`, `reflection_probe_radiance`, `ENVIRONMENT_GGX_CUBE`, `ENVIRONMENT_CHARLIE_CUBE`; compiled in fragment and compute stages |
| `ambient_occlusion.glsl` | `draw_ambient_occlusion`, `frame_ambient_occlusion`, `draw_bent_normal`, `frame_bent_normal` ([bent normals](ambient_occlusion.md#bent-normals)), `specular_occlusion` |
| `screen_space_gi.glsl` | `draw_screen_space_indirect`, `frame_screen_space_indirect`, `screen_space_base_share` |
| `fog.glsl` | `FogTerms`, `fog_terms`, `fog_background_terms`, `apply_fog`, `fog_behind`, `apply_fog_refracted`; the helpers include the view's [fog volume](sky.md#volumetric-fog) and [medium volumes](sky.md#medium-volumes) ([sky](sky.md#custom-stages)) |
| `scene_snapshot.glsl` | `scene_uv`, `scene_color_at`, `scene_depth_at`, `scene_view_distance_at`, `scene_position_at`, `scene_depth_gap` ([scene reads](#scene-reads)) |
| `standard_surface.glsl` | `StandardMaterialSample` (fields frozen), `sample_standard_material`, `MaterialUvGrad`, `sample_standard_material_grad` ([explicit gradients](#explicit-gradients-and-tangents)) |
| `decals.glsl` | `apply_decals` ([decals](materials.md#decals)) |
| `standard_shading.glsl` | `standard_ambient_fill`, `evaluate_standard_lights`, `shade_standard_surface` |
| `gbuffer_output.glsl` | `write_gbuffer`, outputs at locations 0 to 4 |
| `proxy_skip_output.glsl` | `write_proxy_skip` and the `out_proxy_skip` output at location 0 ([prepass stage](#prepass-stage)) |
| `vertex_pull.glsl` | `pull_vec2`, `pull_vec3`, `pull_vec4`, `pull_triangle`, `GEOMETRY_*` |
| `view_clip.glsl` | `gl_ClipDistance[1]` (redeclared) and `view_clip_distance` ([clip plane](views.md#clip-plane)); vertex stages only |
| `instance_effects.glsl` | `instance_anchor`, `instance_fade_scale`, `sway_height_weight`, `sway_offset` ([sway and fade](instancing.md#sway-and-distance-fade); the blocks are `c3d_abi.glsl`'s `InstanceEffectsGpu` and `SwayGpu`) |
| `mesh_vertex.glsl` | the push block, outputs 0 to 6 and 8, `gl_ClipDistance[1]` and `view_clip_distance` (through `view_clip.glsl`), `MeshVertexInput`, `pull_mesh_vertex`, `apply_mesh_deformation`, `write_mesh_outputs` (five arguments in `VELOCITY` forms), `previous_mesh_position` (`VELOCITY`; starts from the view's retained base positions of a [`vertex_motion`](geometry_edits.md#edited-vertices) mesh), `instance_source`, `world_instance`, `instance_bend_weight` and `apply_instance_effects` (`INSTANCED`), `previous_world_model` and `apply_previous_instance_effects` (`VELOCITY` with `INSTANCED`) |
| `instance_record.glsl` | `pack_instance_record(model, color, seed)`, which fills an `InstanceGpu` the way host batches pack theirs ([device batches](instancing.md#device-batches)); compute stages only |
| `quadtree_morph.glsl` | `quadtree_range`, `quadtree_morph` and `quadtree_world_scale` ([quadtree morph](#quadtree-morph); the blocks are `c3d_abi.glsl`'s `QuadtreeGpu` and `QuadtreeLevelGpu`); vertex and compute stages |
| `trace_pose.glsl` | the compute push block and group size, `TracePoseVertex`, `trace_pose_index`, `trace_pose_vertex`, `trace_pose_write`, `trace_pose_instance` ([trace pose](#trace-pose)); compute stages only |
| `scene_trace.glsl` | as in [Scene tracing](scene_trace.md) |

`blend_output.glsl` is probed plain and with `WEIGHTED_BLEND`; `shadows.glsl` and `standard_shading.glsl` are probed plain, with `RT_SHADOWS`, with `RT_SHADOWS` and `SCENE_TRACE_BVH`, and each of those two with `RT_SHADOWS_HARD`; `lights.glsl` in fragment and vertex stages; `mesh_vertex.glsl` plain, with `INSTANCED`, `DEPTH_ONLY`, both, `VELOCITY`, and `VELOCITY` with `INSTANCED`; `instance_effects.glsl` and `quadtree_morph.glsl` in vertex and compute stages; `instance_record.glsl` in compute stages; `trace_pose.glsl` in compute stages; `scene_trace.glsl` in compute with each trace kind.

### Quadtree morph

A custom vertex stage that draws a [quadtree batch](instancing.md#quadtree-selection) under `BOX_RANGES` morphs its vertices toward the parent level with the numbers that selected the node. `quadtree_morph.glsl` declares

```glsl
float quadtree_range(QuadtreeGpu tree, uint depth, float pixel_scale, float world_scale);
float quadtree_morph(QuadtreeGpu tree, uint depth, float vertex_distance, float pixel_scale, float world_scale);
float quadtree_world_scale(mat4 node_world);
bool quadtree_selection_orthographic(FrameRoot frame);
```

`quadtree_range` is the selection range of a depth in a perspective view, in world units; the selection pass calls the same function. `quadtree_morph` is 0 at `R_{d-1} (1 - b)` from the selection camera, 1 at `R_{d-1}`, and 0 for a root and under the sphere metric. The arguments come from the draw:

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

`DepthArray` is a `uint` array reference the stage declares. The batch's `QuadtreeGpu` is never zero for a quadtree batch, so a stage that reads it under `DRAW_QUADTREE` needs no further check. The include states the two conditions the ranges keep: no pop at a merge, and at most one depth between neighbours. An orthographic selecting view has no distance term and takes the size rule, so a stage skips `quadtree_morph` when `quadtree_selection_orthographic(frame)` holds; the morph is 0. That function reads `FRAME_SELECTION_ORTHOGRAPHIC` in `FrameRoot.flags`, not `frame.proj`: a shadow layer's `proj` is the light's, orthographic for every directional cascade whatever the view is. Draws in shadow layers and the depth prepass read the owning view's camera from `FrameRoot.selection_camera` and its projection kind from the flag, so their surface matches the shaded one ([selection camera](views.md#selection-camera)).

### Traced shadows

A custom forward stage receives ray-traced shadows through `ShaderDesc.traced_fragment`. `hardware` is the forward source compiled with `RT_SHADOWS`, drawn on renderers with ray queries; `software` is the same source compiled with `RT_SHADOWS` and `SCENE_TRACE_BVH`, drawn on renderers without them (see [ray-traced shadows](shadows.md#ray-traced-shadows) and [scene tracing](scene_trace.md)). `shadows.glsl` defines `SCENE_TRACE_RAY_QUERY` under `RT_SHADOWS` unless `SCENE_TRACE_BVH` is set, so one source serves all three forms. In a fragment stage `shadow_visibility`, `shadow_transmittance` and `ray_shadow_visibility` cast the view's [soft shadow](shadows.md#soft-shadows) rays at a light with a source extent; they keep their signatures. A traced form under forward MSAA should pass them [`v_shading_pos`](#shading-position-varying) as the receiver position.

A traced form includes the soft-shadow code by default and draws on every view that traces shadows, whether or not a light has an extent. An application whose lights have no source extent can drop that code by defining `RT_SHADOWS_HARD` in the form, as a compile define next to `RT_SHADOWS` or with `#define` before `shadows.glsl`. `ray_shadow_visibility` is then one ray toward the light's centre, as for a light without an extent, and the form ignores `source_radius` and `source_angle`. `ShaderDesc` has no field for this: the built-in stages keep a hard-only form of their own, and a custom form chooses by its source.

A view that traces shadows draws the form of its renderer's kind; a view that traces none draws `fragment`. When the matching form is empty, the view draws `fragment`, which receives a traced light with `shadow_count == 0`, so `shadow_visibility` returns 1 and the surface is lit without that shadow. A shader without traced forms allocates nothing extra and draws `fragment` everywhere. G-buffer stages need no traced form: the lighting resolve shadows them. A traced form the backend rejects behaves like any other configuration (see [reload](#reload)); a replacement that drops a form retires its pipelines, and the next frame draws `fragment`.

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
route by those terms; a forward stage that calls `shade_standard_surface` with the sample and
weight its G-buffer stage writes matches that route, as the Standard twin does.
`examples/shaders/custom/pulse_gbuffer.frag.glsl` is the reference.

`write_gbuffer` also packs `trace_proxy_skip_height` into the upper 16 bits of the flags output
(`GBUFFER_PROXY_SKIP_SHIFT`, in steps of `GBUFFER_PROXY_SKIP_UNIT`), so a stage that writes location 4 itself keeps those
bits for the lighting resolve and the traced effects. A material whose traced stand-in may sit above its surface raises the
height before shading, as the forward, the G-buffer and the prepass stage of terrain do; see
[trace proxies](scene_trace.md#trace-proxies). It stays zero otherwise.

On a `DEFERRED` view with [`msaa`](views.md#multisample-anti-aliasing) above `ONE` the stage writes the multisample
G-buffer: the sample count is pipeline state, the stage source does not change, and it still shades once per pixel
and primitive. The resolve lights an edge pixel per sample from its own channels and any other pixel once.

The capability is also visible to shaders: `CustomMaterialGpu.capabilities` carries
`CUSTOM_CAPABILITY_GBUFFER` when the stage is present. Pipelines for the G-buffer stage are keyed
separately, so a rejected G-buffer stage leaves the forward stage of the same shader drawing, and
a replacement that drops the stage retires its pipelines while the forward ones are rebuilt.

## Prepass stage

`ShaderDesc.depth` is an optional fragment stage for the depth prepass of a `FORWARD` view with
[ray-traced ambient occlusion](ambient_occlusion.md#ray-traced). That prepass writes one `R32_UINT` word per pixel, packed
like the G-buffer flags, so the traced effects can read the pixel's
[proxy skip height](scene_trace.md#trace-proxies). A draw of the shader in that prepass runs `depth` in place of the core
depth fragment, with the vertex stage's `depth` form when it has one. The stage is unpaired: it needs no other form, and
no fault checks it.

The stage includes `proxy_skip_output.glsl`, raises `trace_proxy_skip_height` when its surface can sit below a trace
stand-in, and calls `write_proxy_skip()` on every path; the include declares the output at location 0. The stage does its
own alpha test: it calls `discard` for a cut-out pixel, as the core depth fragment does for a masked material. It reads
the inputs the vertex stage's `depth` form writes, for example a varying that carries the level of a terrain chunk, and
the draw's `fragment_root_gpu`. `terrain_depth.frag.glsl` in `addons/c3d_landscape.c3l` is the reference.

A shader without the stage draws with the core fragment, which writes zero: its pixels read no skip height, and traced
rays start as before. The stage never runs in shadow layers or in the prepass of a `DEFERRED` view, whose G-buffer stage
packs the height instead. A material that reads the scene or blends never draws in the prepass, so its stage never runs.

## Additive output and fog

Set `MaterialCommon.alpha_mode = BLEND` and `blend_mode = ADDITIVE` for additive
RGB with destination alpha preserved. Custom stages emit premultiplied RGB and
coverage through `material_output`, as for ordinary blended materials. Material,
texture and vertex opacity scale the contribution; output alpha need not be zero.
`MATERIAL_BLEND_ADDITIVE` is set in the packed flags only for this combination.

The public `fog.glsl` include supplies
`apply_material_fog(frame, world_position, straight_color, material_flags)`.
It returns straight RGB after fog: colour times transmittance for additive
materials, plus in-scatter for source-over materials. Apply coverage afterward,
once, through `material_output`. With no fog the input colour is unchanged.

The existing three-argument `apply_fog` retains its source-over behaviour. An
additive stage uses the material-aware helper to avoid another fog-colour
contribution over the background. Both helpers use the current view's analytic
or volumetric fog. Declaring scene reads is required only if the stage also
samples a scene snapshot, such as depth for soft fading.

## Weighted transparency

A view with `ViewDesc.transparency = WEIGHTED` composes its `PREMULTIPLIED_ALPHA` blended draws without ordering them ([weighted transparency](materials.md#weighted-transparency)). A custom `BLEND` stage takes part when its shader supplies the weighted form the view needs. Without it the draw stays sorted, after the composite, exactly as in a `SORTED` view. `ADDITIVE` stages are never weighted: they draw after the composite with the state and order of a `SORTED` view, and weighted surfaces in front of them do not dim them.

A weighted form is the forward source compiled with the `WEIGHTED_BLEND` define. The stage writes its color through `write_blend_output` from the public `blend_output.glsl` and declares no `out_color` of its own; the include declares the outputs:

```glsl
#include "custom_material.glsl"
#include "blend_output.glsl"
#include "fog.glsl"

// ... inputs and parameters ...

void main() {
    // ... color, alpha ...
    vec3 fogged = apply_material_fog(frame, v_world_pos, color.rgb, material.flags);
    write_blend_output(frame, material_output(fogged, color.a, material.flags), v_world_pos);
}
```

`write_blend_output(frame, premultiplied, world_position)` takes the premultiplied color `material_output` returns and the fragment's world position, which gives the view-space depth the weight uses. Without `WEIGHTED_BLEND` it writes `out_color` unchanged, so one source serves the plain and the weighted form. With it, the include also declares `out_revealage` at location 1 and writes the weighted color and the coverage. A stage composes correctly only if it writes through the helper; nothing checks at runtime what a weighted form writes, and a form that declares and writes its own `out_color` leaves the second attachment unwritten and composes wrongly.

The forms, by what the view traces:

| View | Form drawn | Compiled with |
| --- | --- | --- |
| traces no shadows | `weighted_fragment.shaded` | `WEIGHTED_BLEND` |
| traces shadows, renderer with ray queries | `weighted_fragment.traced.hardware` | `WEIGHTED_BLEND`, `RT_SHADOWS` |
| traces shadows, renderer without them | `weighted_fragment.traced.software` | `WEIGHTED_BLEND`, `RT_SHADOWS`, `SCENE_TRACE_BVH` |

The traced forms follow [traced shadows](#traced-shadows), with one difference: a missing form does not fall back to another. A draw joins the accumulation only when the form its view needs exists, so a shader that supplies `shaded` alone is weighted in views that trace no shadows and sorted in views that do, where its `traced_fragment` form, or `fragment`, still draws. A stage that reads no shadows supplies the same source for the traced forms. The pipelines are keyed by the shader id, its revision, the form and the two accumulation formats, so a shader's weighted and sorted pipelines coexist and a view that switches mode creates nothing new once both have drawn. A replacement retires them together, and one that drops a form retires that form's pipelines; the next frame draws the draw sorted.

Scene reads work as for a sorted blended stage. Their snapshots are taken before the accumulation, so the stage sees the opaque scene without any weighted surface, and a stage that reads depth for a soft fade measures the gap to opaque geometry.

## Pre-exposure

A view stores its scene radiance multiplied by a power of two, its pre-exposure, and the display
route divides it out. The factor follows `Camera.exposure` times the view's
[adapted exposure](post.md#auto-exposure), so stored values stay near display scale however dim or bright
the scene is. `FrameRoot.pre_exposure` carries it to every stage and `ViewStats.pre_exposure` reports it on the
CPU. A stage that emits unscaled radiance appears `pre_exposure` times too dark.

- Radiance that comes from the frame's data or a public helper is already scaled: the frame's lights through
  `sample_light` and the light loop, `shade_standard_surface`, image-based lighting, probes, ambient,
  `scene_color_at` and the fog helpers.
- Radiance a stage produces itself is not. An unlit or emissive colour, a constant and a texture sampled as light
  (a render target, an HDR texture) go through `pre_exposed(frame, radiance)` from `pre_exposure.glsl`, which
  `blend_output.glsl` includes. Directions, positions, depth, alpha and optical depth are not radiance and stay
  as they are.
- A `LINEAR_HDR` target is physical. A stage that shows one as light, such as a mirror or a planar
  reflection, passes the sample through `pre_exposed`.
- A clamp that shapes the image applies to physical radiance, before `pre_exposed`; a clamp that only keeps
  half-float finite applies to the scaled value, after it.
- A compute dispatch that reads or writes `read_view_color` or `write_view_color` sees scaled values. It
  multiplies the constants it mixes in by `ViewStats.pre_exposure`, read after `render_view`.
- `ViewDesc.pre_exposure_override` forces the factor, a power of two from 2^-16 to 2^16; 0 keeps it automatic.
  A stage not yet migrated renders unchanged under an override of 1.

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

On a view with [`msaa`](views.md#multisample-anti-aliasing) above `ONE`, the snapshots and the scene-read list are
recorded after the resolve: a reader samples single-sample color and depth and draws single-sample. A custom stage in
the opaque list, including its velocity and depth forms, runs in the multisample pass with the view's sample count
as pipeline state; the stage source does not change, and it still shades once per pixel.

Before each list that holds a reader the renderer copies the finished scene into the view's snapshot
images, only the kinds the list's draws declare, once before each non-empty layer of the scene-read list
and once before the transparent list when it holds a reader. A layer's snapshot holds opaque, masked and
sky plus the layers drawn before it, and the transparent list's also holds all the scene-read draws. At the
default `ViewDesc.transmission_layers` of 1 the scene-read list is one layer, so a view copies at most twice
per frame; above 1 it copies at most `transmission_layers + 1` times, and custom readers are layered like glass
([transmission layers](materials.md#transmission-layers)). No reader sees ordinary blends or the other draws
of its own layer. A view whose frame draws no reader copies nothing; each image is allocated at the view's
working extent the first time a frame needs it and kept until the view's images are released.
`scene_color` is `RGBA16_FLOAT`; `scene_depth` is `R32_FLOAT` holding the reverse-Z depth bit for bit,
4 bytes per pixel (8.3 MB at 1920 × 1080, 33.2 MB at 3840 × 2160). `scene_color` also holds a mip chain
that only [Physical transmission](materials.md#physical-transmission) fills; the helpers below read mip zero.

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
no screen-space terms: `draw_ambient_occlusion` returns 1, `draw_bent_normal` returns the normal it is
given and `draw_screen_space_indirect` returns zero.

On a view with fog or an atmosphere ([sky](sky.md#where-fog-applies)) the snapshots are taken before the
view's fog pass, so readers see unfogged radiance, and a colour read also takes a depth snapshot. The pass
fogs a depth-writing reader at its own depth; a refracting one returns `apply_fog_refracted(...)` so its
refracted sample is fogged to its own depth. A blended reader draws after the pass and composes
`apply_fog(frame, position, apply_fog_refracted(...))`; a blended stage that does not refract calls
`apply_fog` on its output. A custom twin of Standard keeps matching it: an opaque twin needs nothing, a
blended twin calls `apply_fog` as Standard does.

Routing uses the scene reads of the shader revision whose pipelines are drawing, not the store's
current desc: a replacement the backend rejects keeps the previous pipelines drawing and keeps the
snapshots they sample.

`Stats.scene_snapshots` counts the images copied in the frame (each copy also counts one
`Stats.draws`); `Pass.SCENE_SNAPSHOT` times the copies, `Pass.SCENE_MIPS` the transmission mip chain and
`Pass.SCENE_READ` the scene-read list.
`gui::targets_panel` lists `scene_color` and `scene_depth`; `PreviewKind.VIEW_SCENE_DEPTH` previews
`scene_depth` as distance, like `VIEW_DEPTH`.

Measured cost on an RTX 4090 (driver 610.88) at 1920 × 1080, `--gpu-timings`, mean of three runs of
600 frames with the range:

| Case | Pass | Time (ms) |
| --- | --- | --- |
| `materials`, transmission | `SCENE_SNAPSHOT` (one color copy) | 0.020 (0.018–0.022) |
| `materials`, transmission | `SCENE_SNAPSHOT` + `SCENE_READ` | 0.077 (0.071–0.082) |
| `materials`, transmission, before scene reads | the former single transmission pass | 0.084 (0.078–0.095) |
| `custom_compute`, pool hidden | `SCENE_SNAPSHOT` (one depth copy) | 0.012 (0.008–0.015) |
| `custom_compute`, pool shown | `SCENE_SNAPSHOT` (color and two depth copies) | 0.070 (0.062–0.086) |
| `custom_compute`, pool shown | `SCENE_READ` | 0.012 (0.011–0.013) |

Transmission costs the same as before within the spread. Frames run about 1.5 ms, so per-pass
timestamps carry clock noise; the differences above are inside it. 3840 × 2160 was not measured: no
available display holds it.

## Vertex contract

A custom vertex stage includes `mesh_vertex.glsl`, which declares the push block, the seven outputs and the helpers `pull_mesh_vertex`, `apply_mesh_deformation` and `write_mesh_outputs` (a [velocity form](#velocity-form) also calls `previous_mesh_position` and the five-argument `write_mesh_outputs`), and applies its own displacement between pulling and writing:

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

An instanced stage that reads per-instance data itself indexes it with `instance_source(draw)`, never `gl_InstanceIndex`. With [instance culling](instancing.md#instance-culling) on, `gl_InstanceIndex` is the position in the visible list and `instance_source` maps it back to the instance; with culling off both are equal on opaque and masked batches. A [blended batch](instancing.md#blended-batches) always draws through a visible list, with or without culling, and there `gl_InstanceIndex` is the draw rank, 0 farthest. `write_mesh_outputs` and `apply_mesh_deformation` already use it.

An instanced stage reads an instance's matrices, normal rows, seed and color through `world_instance(draw, source)`, which returns the `InstanceGpu` record in world space: `model` and the normal rows are the batch node's `DrawRoot.model` and normal rows composed with the stored record's. The raw `InstanceArray` records behind it are relative to the batch node, an implementation detail rather than part of the contract; a stage that reads them directly places instances wrongly under a moved node. Migration: replace `InstanceArray(draw.instance_data).values[source]` with `world_instance(draw, source)`, and in a velocity form take the previous matrix from `previous_world_model(draw, source, model)`. The previous matrices behind that helper are `AffineRowsGpu` records, also an implementation detail, so a stage that calls the helper keeps its contract.

In `INSTANCED` forms `write_mesh_outputs` applies the batch's [sway and fade](instancing.md#sway-and-distance-fade) in world space after the instance matrix, the sway first and then the collapse, and under `SwayWeight.VERTEX_ALPHA` writes `v_color.a = 1` before the instance tint. A stage that writes its outputs itself calls the helpers `mesh_vertex.glsl` declares under `INSTANCED`: `world_instance`, `instance_bend_weight`, `apply_instance_effects` on the world position and, in velocity forms, `apply_previous_instance_effects` on the previous world position; it sets `v_color.a = 1` when `DRAW_SWAY_VERTEX_ALPHA` is set. A stage supplies its own bend weight by writing `vertex.color.a` before `write_mesh_outputs` and selecting `VERTEX_ALPHA`. Instanced SPIR-V built against an older `mesh_vertex.glsl` draws without sway and fade until it is rebuilt.

`write_mesh_outputs` also writes `gl_ClipDistance[0]` for the view's [clip plane](views.md#clip-plane), from the world position that feeds `gl_Position`: in `INSTANCED` forms, the position after the sway and fade. A stage that writes `gl_Position` itself, velocity forms included, includes `view_clip.glsl` and writes `gl_ClipDistance[0] = view_clip_distance(frame, world_position)` from that same world position; `view_clip_distance` returns 1 in a view without a plane, and in shadow, probe and path-traced roots.

### Billboard varying

`mesh_vertex.glsl` declares `layout(location = 8) out vec3 v_billboard`, and every `write_mesh_outputs` form writes `(uv0, 0)` to it, depth and velocity forms included. The built-in billboard stage writes `(quad u, quad v, fract(frame))` instead, with v running from the quad's top edge down: the quad coordinate and the blend weight toward the next cell of a [sprite sheet](billboards.md#sprite-sheets). The built-in ribbon stage writes `(u, v, 0)`, the coordinates of [ribbons](ribbons.md#texture-coordinates). A fragment stage reads it with `layout(location = 8) in vec3 v_billboard;` on any draw, and it is zero in `.z` wherever no sprite sheet applies.

A custom vertex stage that writes its outputs itself instead of calling `write_mesh_outputs` must write location 8 before a fragment that reads it is paired with it. Location 8 is reserved by `mesh_vertex.glsl`: a stage that includes it and declares its own output at that location no longer compiles, so extra varyings start at location 10, after [`v_shading_pos`](#shading-position-varying).

### Shading position varying

`mesh_vertex.glsl` declares `layout(location = 9) centroid out vec3 v_shading_pos`, and `write_mesh_outputs` writes the world position that feeds `v_world_pos` to it. The depth and velocity forms leave it out, as they leave out `v_world_pos`. The built-in billboard, ribbon, terrain and water stages write it as well.

Under [multisample anti-aliasing](views.md#multisample-anti-aliasing) a forward fragment runs once per pixel when any sample is covered and interpolates `v_world_pos` at the pixel centre, which can lie outside the triangle. A traced shadow ray started there can begin below the neighbouring surface and hit it, which draws as speckle on finely tessellated terrain. `centroid` interpolates inside the covered samples, and on a view without MSAA it is the pixel centre, so `v_shading_pos` equals `v_world_pos` there.

A fragment stage reads it with `layout(location = 9) centroid in vec3 v_shading_pos;` and passes it as the position of `shade_standard_surface`, `evaluate_standard_lights`, `shadow_visibility`, `shadow_transmittance`, `ray_shadow_visibility` and the light direction. The two Standard functions take one position for probe and light selection, light direction and shadow ray, so they take it whole; a stage that selects lights and probes through its own calls, as Physical and Toon do, keeps `v_world_pos` for the selection. Derivatives, `view_depth`, decals, material and terrain sampling, fog and `write_blend_output` keep `v_world_pos` in every stage. The built-in Standard, Physical, Toon, terrain and water fragments read it. A custom fragment stage under MSAA should pass it to its traced lighting; one that does not compiles unchanged and keeps the pixel-centre position. Deferred stages do not read it: the lighting resolve reconstructs the position from depth.

A custom vertex stage that writes its outputs itself instead of calling `write_mesh_outputs` must write location 9 before it is paired with a fragment that reads it, including the built-in fragments above. Location 9 is reserved by `mesh_vertex.glsl`: a stage that includes it and declares its own output at that location no longer compiles. Migration: declare the output at location 10 or above, in the vertex and the fragment stage.

Limits of a custom vertex stage:

- It has one compiled form per pass. The renderer does not select `SKINNED`, `SKINNED_U16` or `MORPH` forms of user SPIR-V; compile with the defines that match the geometry when `apply_mesh_deformation` should skin or morph, or leave them out for rigid meshes. `DrawRoot.skin` and `DrawRoot.morph` are written either way.
- A crowd part (see [Instancing](instancing.md)) draws through the instanced pair. Compiled with `INSTANCED` and the deformation defines, `apply_mesh_deformation` reads the palette row and morph block of the instance's logical source, `InstanceGpu.normal_2.w`, at `DrawRoot.skin_stride` joints per row; compiled without them, the crowd draws at the bind pose.
- The velocity pass draws the velocity form when the shader supplies one for the draw; those items are redrawn on every rendering with history. Without it, velocity uses the built-in `mesh` variant and sees the undisplaced mesh. The built-in instanced velocity variant, and velocity forms that end in `write_mesh_outputs`, include the batch's sway.
- Built-in materials sample with `FrameRoot.mip_bias` on TAA views; a custom fragment opts in with
  `sample_custom_map(material, slot, uv0, uv1, frame.mip_bias)`. The depth prepass cuts custom
  alpha coverage unbiased, so a masked custom material keeps the unbiased sample for its alpha:
  a biased one cuts different coverage than the prepass tests `EQUAL` against.
- A displaced mesh needs an authored `Mesh.local_bounds` override when the displacement can leave the geometry bounds; culling and shadow fitting use bounds, not vertices. The override is a bound only and does not keep the mesh out of [scene traces](scene_trace.md#what-traces). A displaced batch sets `InstancedMesh.local_bounds` with `has_bounds_override`; its instances are then not culled one by one, though a blended one still lists and sorts every instance. The built-in sway needs no override: it grows the bound itself and keeps per-instance culling.
- A material with a custom vertex stage traces only through a [trace-pose stage](#trace-pose), whatever `Mesh.trace` says: the renderer sees the stage, not the displacement. A stage that displaces nothing and should trace draws through the built-in vertex stage.
- A displacement that changes the surface orientation must adjust `vertex.normal` and `vertex.tangent` itself; the pulse example is a uniform translation and leaves them alone.
- SPIR-V without the clip-distance write, compiled before `view_clip.glsl` existed or from a stage that writes its outputs without it, draws unclipped in a clipped view; its shaded, depth and velocity forms still agree with each other. A shader without a velocity form gets its velocity from the built-in `mesh` variant, which clips, so a moving, unclipped custom surface behind the plane carries camera-only motion there.
- Compile every form of a shader from the same `mesh_vertex.glsl` and `view_clip.glsl`: forms built against different versions leave holes along the cut.
- A stage that includes `mesh_vertex.glsl` or `view_clip.glsl` never redeclares `gl_PerVertex` or `gl_ClipDistance`: glslang accepts one redeclaration, before any use.
- A module that declares `ClipDistance` needs the device's `shaderClipDistance`, which `create_renderer` already requires; gpu.c3l rejects such a module with `gpu::UNSUPPORTED_FEATURE` on a device without it.

### Velocity form

Motion blur, TAA, screen-space GI, temporal ambient occlusion and the reflection history read the view's velocity image. Its geometry pass redraws each moved item with depth test `EQUAL` and no depth write. A custom vertex stage makes its own displacement visible there through a velocity form: `velocity` for meshes and `instanced_velocity` for batches, the same source compiled with `VELOCITY` (and `INSTANCED`). The pulse example's body:

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

- `previous_mesh_position(draw, geometry, index)` exists only under `VELOCITY`: the object-space position under the skin and morph the view drew last time.
- `write_mesh_outputs(vertex, previous_position, draw, frame, geometry)` takes the previous object-space position with the stage's displacement applied; every other form ignores it. The four-argument call passes `previous_mesh_position` in a velocity form, so a velocity form that ends in it sees the undisplaced previous position.
- `FrameRoot.previous_time` is the `FrameInfo.time` of the view's last rendering, narrowed to float like `jitter_time.z`. It equals `jitter_time.z` on a view's first rendering, after `render::reset_view_history`, `configure_view`, a resize or an aborted frame, on a view without motion blur, TAA, screen-space GI, temporal ambient occlusion or reflection history, and in shadow, path-traced and probe roots. Any stage may read it; it is meaningful in velocity forms.
- A velocity form computes its current position exactly as its depth form does, with the same source and expressions and only `VELOCITY` added: the pass tests `EQUAL` against the depth the depth or shaded form wrote.
- A velocity stage that does not include `mesh_vertex.glsl` declares the 16-byte push block and writes `gl_Position`, identical to its depth form's; `gl_ClipDistance[0]` through `view_clip.glsl`, identical to its depth form's; location 6 `vec4 v_clip_pos`, `gl_Position` with `xy -= frame.jitter_time.xy * gl_Position.w`; and location 7 `vec4 v_prev_clip_pos`, `frame.prev_view_proj * previous_world` with `previous = vec4(previous_local, 1.0)` and `previous_world` `draw.prev_model * previous` for a plain form. For an instanced form, with `model` the current instance matrix from `world_instance(draw, instance_source(draw))`, `previous_world` is `previous_world_model(draw, instance_source(draw), model) * previous`: the matrix the view drew the instance with last time when the instance changed (the node's previous world, `draw.prev_model * draw.model`, times the instance's previous matrix), and `draw.prev_model * model` otherwise. Only `mesh_vertex.glsl` declares `world_instance`, `previous_world_model` and, for a batch with sway or fade, the effects helpers that both world positions also pass through.
- An item whose shader has the velocity form for its draw is redrawn on every rendering whose view has its node in history, also at a still node; at frozen time and rest its velocity equals the camera velocity.
- The previous displacement uses the current material parameters at the previous time, so a parameter edit shows no motion of its own.
- Call `render::reset_view_history` after a jump in `FrameInfo.time` (a seek, a loaded save), as after a camera cut.
- `jitter_time.z` and `previous_time` are floats: from 65,536 s (about 18 h) each rounds to within 1/256 s and their difference is off by up to 1/128 s, up to about half of a 60 Hz step. An application that runs that long wraps its time and calls `render::reset_view_history` at the wrap, which is itself a time jump.

## Trace pose

A custom vertex stage displaces vertices that [scene traces](scene_trace.md) never see. `ShaderDesc.trace_pose` supplies the same displacement as a compute stage: for each traced row it writes the posed positions, normals and tangents of the row's geometry into a renderer-owned slot, and every trace consumer reads hits through that slot. `trace_pose.single` poses a mesh and needs `vertex.shaded`; `trace_pose.instanced`, the same source compiled with `INSTANCED`, poses one instance of a batch and needs `vertex.instanced_shaded`. Rows are posed by the revision the renderer published, so a replacement the backend rejected keeps posing with the previous forms. The cost, capacity, `Mesh.local_bounds` rule and BLAS policy are on the [scene trace](scene_trace.md#custom-trace-poses) page.

The stage includes `trace_pose.glsl`, which declares the compute push block, one `uint64_t root_gpu`, a 64-lane group and these helpers:

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

A row is dispatched as a grid of groups, 64 vertices each. The grid is as wide as the device's group count along x allows, and `trace_pose_index` folds its rows into one linear index. A row that fits the device's group count along x (at least 65,535 groups, so 4,194,240 vertices) has a one-row grid, and `gl_GlobalInvocationID.x` is the same index. A stage that indexes through `trace_pose_index` sets `ShaderDesc.trace_pose_grid`. A stage that does not poses only the first row of groups, so `prepare_scene_trace` faults `c3d::UNSUPPORTED` for a row whose groups exceed the device's count along x, and poses none of it.

Migration: rows above 4,194,240 vertices need `trace_pose_index` and `trace_pose_grid`. Replace the `gl_GlobalInvocationID.x` index and its range check with `uint index; if (!trace_pose_index(index)) return;`, and set the flag on the `ShaderDesc`.

Keep the displacement the vertex stage applies in a function both stages include, so the two cannot drift. Scope:

- The stage sees `TraceCustomPoseRoot` and nothing else. A vertex stage that reads the camera, lights or other frame data cannot be reproduced; its displacement must come from the material, the instance record and the time.
- The pose is in the geometry's space, before the row's matrix, as a vertex stage's `vertex.position` is. The stage adjusts `normal` and `tangent` itself where its displacement turns the surface.
- It runs again only when its inputs change: the material's revision, the revisions of the asset textures in its slots, the shader's revision, the instance record and, with `reads_time`, the time. Set `reads_time` for a stage that reads `root.time`; without it the pose is not refreshed as time moves. Neither a render target in a slot nor a Standard material in `CustomParams.references` is tracked.
- Skin, morph targets and `Mesh.vertex_motion` do not apply to a custom row, and a part of a `LodGroup` or of a crowd with a custom vertex stage stays out of the trace.
- The stage keeps its surface inside the bound the row uses: `Mesh.local_bounds` when `has_bounds_override` is set, else the geometry's bound. Give a flat geometry that is displaced a bound with thickness.

## In-process compilation

With the `C3D_SHADER_COMPILER` feature and `shaderc` in the consumer's dependencies, `c3d::shader::compile` compiles GLSL without a filesystem:

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

Targets Vulkan 1.3 semantics and SPIR-V 1.5 like the offline build. `#include` resolves against the embedded table `shader::SHADER_INCLUDES` first: every file under `shaders/common/`, `shaders/generated/` and `shaders/gpu/` (a copy of gpu.c3l's `include/shaders/`), by the same names the built-in shaders use. It then searches the optional `includes`, in order: an application's or a [shader package's](#shader-packages) own includes, borrowed for the call. Names match exactly and the first match wins, so a caller entry never replaces an embedded file, and an include written relative to its sibling (`"params.glsl"` inside `app/`) does not resolve: write the full name (`"app/params.glsl"`). An include in neither table is a compile error. `SHADER_COMPILE_FAILED` carries no text; the optional `log` receives the compiler messages, including warnings on success.

Without the feature the module does not exist and `shaderc` is not linked; `ShaderDesc` still takes SPIR-V bytes from any other producer.

## Shader packages

An add-on or an application that ships GLSL compiles it offline with `scripts/build_shaders.py` into a committed C3 file of `$embed` constants. A shader package is a directory with `shaders/shaders.json`:

```
addons/c3d_landscape.c3l/
├── shaders/
│   ├── shaders.json
│   ├── terrain.frag.glsl                         entries' sources
│   ├── include/landscape/terrain_layers.glsl     includes, under the package name
│   └── spv/                                      build output, not committed
└── src/shaders.c3                                the generated output, committed
```

```json
{
  "module": "c3d::landscape",
  "output": "src/shaders.c3",
  "flags": ["DEPTH_ONLY", "RT_SHADOWS", "SCENE_TRACE_BVH"],
  "entries": [
    { "shader": "terrain_fragment", "source": "terrain.frag.glsl", "stage": "frag", "defines": [] },
    { "shader": "terrain_fragment", "source": "terrain.frag.glsl", "stage": "frag", "defines": ["RT_SHADOWS"] },
    { "shader": "terrain_fragment", "source": "terrain.frag.glsl", "stage": "frag", "defines": ["RT_SHADOWS", "SCENE_TRACE_BVH"] },
    { "shader": "terrain_vertex", "source": "terrain.vert.glsl", "stage": "vert", "defines": [] },
    { "shader": "terrain_vertex", "source": "terrain.vert.glsl", "stage": "vert", "defines": ["DEPTH_ONLY"] }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `module` | yes | Module of the generated file; its last component `<name>` names the include directory and the include table |
| `output` | yes | Generated C3 path relative to the package root; committed |
| `flags` | yes, may be empty | Defines entries may use, in constant-name order; vertex entries name `DEPTH_ONLY`, `INSTANCED` and `VELOCITY` here for their depth, instanced and [velocity](#velocity-form) forms |
| `entries[]` | yes | `shader`, `source` (under `shaders/`), `stage` (the core stage names: `vert`, `frag`, `comp` and the rest glslang takes) and optional `defines` (a subset of `flags`) |

A package compiles against core's include roots, so every [public include](#public-includes) is available, plus its own `shaders/include/`. Its includes live in `shaders/include/<name>/` and are written `#include "<name>/x.glsl"`, also between the package's own includes, because the in-process resolver matches names exactly. Another package's includes are never visible: cross-package includes are unsupported. Package includes are not probed; the entries that include them compile them. SPIR-V goes to `<package>/shaders/spv/<shader>{_<define>}.spv`.

The generated file declares the module, one `@private` constant per entry named as core's registry names them (`<SHADER>{_<DEFINE>}_SPIRV`, defines in `flags` order), and, when the package has includes, the public `<NAME>_SHADER_INCLUDES` table for `compile_glsl(includes:)`. With the table, it imports only the scene-layer `c3d::asset`, never a render-layer module:

```c3
// Generated by build_shaders.py from shaders/shaders.json - do not edit.
module c3d::landscape;

import c3d::asset;

const char[*] TERRAIN_FRAGMENT_SPIRV @private = $embed("../shaders/spv/terrain_fragment.spv");
const char[*] TERRAIN_FRAGMENT_RT_SHADOWS_SPIRV @private = $embed("../shaders/spv/terrain_fragment_rt_shadows.spv");
...
const char[*] INCLUDE_LANDSCAPE_TERRAIN_LAYERS_TEXT @private = $embed("../shaders/include/landscape/terrain_layers.glsl");

<*
 GLSL includes of this package, by the name a shader writes.
*>
const asset::ShaderInclude[1] LANDSCAPE_SHADER_INCLUDES = {
    { .name = "landscape/terrain_layers.glsl", .text = (String)INCLUDE_LANDSCAPE_TERRAIN_LAYERS_TEXT[..] },
};
```

The SPIR-V constants are `@private` to the package's module. A submodule of the add-on reads them with `import c3d::landscape @public;`, which lifts the private visibility for the importing module; every add-on with submodules follows this rule:

```c3
module c3d::landscape::terrain;

import c3d::landscape @public;

ShaderDesc desc = {
    .fragment         = landscape::TERRAIN_FRAGMENT_SPIRV[..],
    .traced_fragment  = {
        .hardware = landscape::TERRAIN_FRAGMENT_RT_SHADOWS_SPIRV[..],
        .software = landscape::TERRAIN_FRAGMENT_RT_SHADOWS_SCENE_TRACE_BVH_SPIRV[..],
    },
    .vertex           = {
        .shaded = landscape::TERRAIN_VERTEX_SPIRV[..],
        .depth  = landscape::TERRAIN_VERTEX_DEPTH_ONLY_SPIRV[..],
    },
    .param_block_size = TerrainParams::size,
};
ShaderId shader = assets.add_shader(&desc, "terrain")!;
```

`add_shader` copies the bytes into the store. Payload structs stay hand-mirrored C3 structs with `$assert` size pins.

In-repo packages are discovered: every `addons/*/shaders/shaders.json` and `test/shaders/shaders.json` (the shader package the unit tests read). `python3 scripts/build.py` compiles them after core's registry and probes, and `--regen` rewrites their outputs; without it, a stale output fails the shaders step. An application outside the repository compiles its own package with `python3 lib/c3d.c3l/scripts/build_shaders.py --package <dir>` (repeatable; `--check` verifies the output instead of writing it). With `--package` the script compiles only the named packages against core's include roots and writes only their outputs: it reads neither `shaders/variants.json` nor `lib/`, so it also runs from a copy holding just `scripts/build_shaders.py` and `shaders/{common,generated,gpu}`. An add-on without `shaders/shaders.json` needs nothing.

A manifest error stops the step with `[shaders] manifest error:` and exits 1: a missing field; an unknown stage or a missing source; a define outside `flags`, or duplicate flags; a duplicate `(shader, defines)`; a `.glsl` under `shaders/include/` outside `<name>/`; a package name equal to a first-level directory of core's include roots (`generated`, `internal`); an include name equal to a core include or to another package's include in the same run; a `--package` directory without `shaders/shaders.json`.

Committed: `shaders.json`, the sources, `shaders/include/**` and the output. Build output, ignored: `shaders/spv/`.

## Reload

```c3
assets.replace_shader(shader, &new_desc)!;
if (catch excuse = renderer.upload(shader)) { /* SHADER_INVALID or PIPELINE_CREATE_FAILED */ }
```

`replace_shader` copies the new stages and advances the revision. The renderer notices the moved revision at the next frame that draws the material, or immediately through `Renderer.upload(shader)`: every pipeline built from the old revision is rebuilt from the new stages first; on total success the new set is published and the old handles are retired after the frames that may reference them complete; on a backend rejection nothing is published, the previous pipelines and payload keep drawing, gpu.c3l's diagnostic lands in the renderer's `DebugLog` and on stderr, and `Stats.shader_rejections` counts it. Neither a rejected replacement nor a rejected configuration is retried until the shader is replaced again; `upload` returns the fault. Repeated use of one revision and configuration reuses its pipeline; a new configuration (a wireframe toggle, a shadow caster) adds one entry.

The renderer keeps a copy of the published revision's stages. Every pipeline it builds for the shader, including one first needed after a rejected replacement (a new view or shading path, a first shadow caster, an instanced batch, a velocity or traced form), is built from that copy under that revision, and every routing decision (forward or G-buffer, scene reads, depth, velocity and traced forms) reads it, so a rejected revision never draws, in any pass. A material's payload is checked against the published revision's `param_block_size`: a payload sized for a rejected revision is skipped and counted in `Stats.dangling_refs`. The copy is taken at each publication (the first use, an accepted replacement, a successful `upload`), freed when the next publication supersedes it, when the shader is removed, or with the renderer; it holds the stage bytes a second time and is never allocated per frame. Bytes edited in place in the store reach the renderer through `mark_shader_dirty` or `upload` only. The first revision is published without building anything; its pipelines compile at first use.

Extraction admits a batch by the store's newest revision. While a replacement that adds the instanced pair is rejected, the batch is skipped without a count; while one that drops the pair is rejected, extraction skips the batch and counts it in `Stats.dangling_refs`, although the published revision could draw it.

A configuration that fails on first use (a forward pipeline, a shadow caster's depth form, or a velocity form, whose velocity draw is skipped while the camera velocity stands) skips those draws until the shader is replaced; other configurations of the same shader keep drawing.

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

`root` is the application's std430 root; its bytes are copied into the upload ring and their address becomes `DispatchRoot.parameters` (zero for an empty root). `writes` names the buffers the dispatch writes: the renderer records one barrier before the dispatch, from every consumer stage to compute, and one after, from compute to the vertex, fragment and compute stages, so a later dispatch or draw in the same frame reads the results. A dispatch with no writes records no buffer barrier. Buffer reads need no declaration. Dispatches record in call order anywhere between `begin_frame` and `end_frame`, outside an overlay, after the frame's pending asset uploads; `write_buffer` faults `INVALID_ARGUMENT` after the frame's first dispatch, so every staged write lands before every dispatch. A dead shader or buffer id faults `INVALID_ID`. Indirect dispatch is outside this contract; [readback](#readback) is limited to `READBACK` buffers.

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

A `read_texture` entry for an `R16_UINT` texture is read with `gpu_fetch_uint(textures.slots[i].texture_index, texel, 0)`, never sampled.

A `read_view_depth` entry before the view's `render_view` of the open frame reads the depth of the view's previous
rendering: the prepass of this frame clears it later. `Renderer.view_depth_frame(view)` says which frame that rendering
was, and faults `NOT_READY` when the image holds none (a first frame, a `configure_view` that recreated it, a
path-traced view). The depth is `D32_FLOAT`, reverse-Z, with 0 for background; a multisample view holds sample 0 of its
resolve. Read it with `texelFetch` through `asset::SAMPLER_NEAREST`, because a filtered read blends a foreground
surface into the background at silhouettes. Each dispatch that names the depth records one barrier into the sampled
compute state, including when an earlier dispatch left it there, and the view's next pass moves it back.

A store texture is writable when its `TextureDesc.storage` is set; block-compressed, sRGB and `R16_UINT` formats reject the flag with `INVALID_ARGUMENT`. `add_texture_empty(desc, key)` creates a storage texture with no pixels, contents undefined until a dispatch writes them; it may be bound by a material before that. A dispatch writes one mip of one layer per declaration; levels it does not write keep their previous contents, and `Renderer.upload(texture)` writes the CPU pixels back over the GPU contents.

### Geometry writes

A dispatch may write the vertex streams of a resident geometry. `DispatchDesc.geometry` lists `GeometryWrite { geometry, streams, local_bounds }`, where `streams` names the positions, normals and tangents the shader writes. The application packs the stream addresses into its root:

```c3
DeformRoot root = {
    .positions = (ulong)renderer.geometry_stream_address(geometry, GeometryStream.POSITIONS)!,
    .normals   = (ulong)renderer.geometry_stream_address(geometry, GeometryStream.NORMALS)!,
};
GeometryWrite[1] writes = {{
    .geometry     = geometry,
    .streams      = { .positions = true, .normals = true },
    .local_bounds = bounds,
}};
renderer.dispatch({
    .shader   = deform,
    .root     = material::@as_bytes(root),
    .groups   = { groups, 1, 1 },
    .geometry = writes[..],
})!;
```

`geometry_stream_address` needs an open frame and returns the address of any present stream of the geometry's block for the current frame: positions and normals are packed three-float vectors (12 bytes per vertex), tangents four-float vectors, indexed by vertex. Only positions, normals and tangents can be written.

- **Validation.** A dead geometry id faults `INVALID_ID`. A geometry that is not resident (call `upload_geometry` first), a stream the geometry does not carry, a stream other than positions, normals or tangents, an empty stream set or the same geometry twice faults `INVALID_ARGUMENT`. Every fault comes before the dispatch records or stages anything. A geometry with a CPU revision still waiting for its upload is uploaded first, so the write lands after it.
- **Barriers.** The dispatch brackets a geometry write like a buffer write: consumer stages to compute before, compute to the consumer stages and transfer after.
- **Device revision.** The write is a device revision of the named streams. Draws, shadows, the velocity pass and the trace refit read it in the same frame; the CPU arrays do not change, and no CPU upload happens. A later CPU revision (`mark_geometry_dirty`, `mark_geometry_streams_dirty`, `mark_geometry_range_dirty`, `replace_geometry`) uploads the whole block again from the CPU arrays, overwrites the device contents of every stream and restores the geometry's bounds. Record the dispatch before the draws that should show it and before `prepare_scene_trace`.
- **Velocity.** The first write of a frame that names positions copies the positions the block held into a renderer-owned buffer, allocated once at the geometry's first write, before the dispatch records. A `Mesh` with `vertex_motion` reads it as its previous positions in a view that drew the mesh the frame before: the velocity of a moving write is the per-vertex motion, and a frame without a write reports none. The buffer is per geometry, so a view that skips frames sees one frame of motion. `Stats.vertex_history_bytes` stays zero for a device-written geometry, and its CPU arrays may be released.
- **Tracing.** A `vertex_motion` mesh's posed trace slot copies the written streams and refits its tree or updates its bottom-level structure in the same frame (see [Scene tracing](scene_trace.md)). The shared rest tree and bottom level of a geometry that no `vertex_motion` mesh traces keep the CPU form.
- **Bounds.** `local_bounds` replaces the geometry's bounds for culling, the scene index, picking and the top-level structure until the next CPU revision. It must contain every position the shader can write. Picking tests the bounds only, because the CPU arrays no longer describe the drawn vertices.

### Readback

`BufferUsage.READBACK` creates a buffer that shaders write like a `GPU_PRIVATE` one and the CPU can read back later. At the end of every frame that recorded work, the renderer copies each live `READBACK` buffer into a mapped staging copy. `Renderer.read_buffer(buffer)` inside an open frame returns the contents the buffer held when the frame `FRAMES_IN_FLIGHT` frames earlier ended:

```c3
renderer.begin_frame(info)!;
char[] bytes = renderer.read_buffer(positions)!;
```

The result borrows mapped memory without copying or allocating and stays valid until the next `begin_frame`. `read_buffer` faults `render::NOT_READY` until that frame has been copied, so in the first `FRAMES_IN_FLIGHT` frames and after a frame that recorded no work or was aborted; `INVALID_ARGUMENT` for a buffer that is not `READBACK`. The copy is made after every dispatch of the frame, and the staging keeps `FRAMES_IN_FLIGHT + 1` copies of the buffer.

### Views

`render_view` records a view's scene passes; `finish_view(view)` records its depth of field, display chain and output. A dispatch between the two reads the view's depth and reads or writes its scene image in place, and the post chain sees the result; a dispatch after `finish_view` sees the finished image. `end_frame` faults `INVALID_ARGUMENT` when a rendered view was not finished; `Renderer.render` calls both. `view_extent(view)` gives the working size a dispatch over the view covers. A `write_view_color` before the view's `render_view` is overwritten by the view's clear.

Compute pipelines share the pipeline cache and the reload behavior of custom materials: `replace_compute_shader` followed by the next dispatch, or by `renderer.upload(compute_shader)`, rebuilds the pipeline under the new revision and publishes it on success; a backend rejection (a push block that is not `RootPush`, a missing `main`) keeps the previous revision dispatching, lands in the debug log and `Stats.shader_rejections`, and `upload` returns the fault. A first revision that is rejected skips its dispatches until the shader is replaced.

`Stats.dispatches` counts the frame's custom dispatches; `Pass.CUSTOM_COMPUTE` times those before the frame's first `render_view` and `Pass.CUSTOM_COMPUTE_POST` those after.

## Example

`examples/custom_shader` keeps `tint.frag.glsl`, `pulse.vert.glsl` and `pulse.frag.glsl` under `examples/shaders/custom/`, compiles them in process at startup, and every half second compares the files' modification times with the ones it last saw; a change, or R, recompiles and replaces the shader, printing the compiler log or the rejection fault. P pauses the pulse through `@custom_params`. The pulse shader supplies a velocity form: M toggles motion blur, V toggles TAA with the velocity view (`TaaDebug.VELOCITY`), and N drops or restores the velocity form and reloads the shader. With V and a still camera the pulsing box's green channel swings above and below neutral at the pulse rate while the tint sphere and the floor stay the flat olive of zero velocity; after N the box is flat olive too. With M and a still camera the box's top and bottom edges blur along the pulse; without the form they stay sharp. Editing `pulse.frag.glsl` so its push block does not match (declare the first member of `Push` as a `uint`; a member appended at the end is accepted) demonstrates the rejection: the console shows the `SHADER_INVALID` diagnostic, the stats panel counts a rejection, and the box keeps drawing with the previous shader until the file is fixed.

`examples/custom_compute` advances a particle buffer with `particles.comp.glsl` every frame and draws it as camera-facing quads through a custom material whose vertex stage pulls each particle by `gl_VertexIndex / 4` from the same buffer; an `UPLOAD` buffer carries the moving emitter. The particles are a blended [scene reader](#scene-reads) of depth: each fades by `scene_depth_gap` over `softness` metres into what lies behind it, so they dissolve into the floor and the water instead of cutting through them; S switches `softness` between 0 and its default through `@set_custom_params`, and the hard intersections return. A 5 × 5 pool over the floor draws with `water.frag.glsl`, an opaque reader of color and depth: it refracts the checker floor through animated ripples, keeps the unrefracted uv where the offset sample lies in front of the surface, darkens and tints the floor by the length of the water path, and foams where the gap to the scene behind is small, around a Basic post standing in the pool. W shows or hides the pool. The stats panel shows `Scene snapshots: 3` with the pool (color and depth before the scene-read list, depth again before the particles) and `1` without it; with `--gpu-timings` the `SCENE_SNAPSHOT` and `SCENE_READ` rows appear, and `SCENE_READ` reads `N/A` while the pool is hidden. All four GLSL files are polled and reloaded like the custom shader example, Space reseeds the particles, and the stats panel shows `Dispatches: 1` and the completed custom compute time. Breaking the compute push block demonstrates the rejection: the console shows `SHADER_INVALID`, and the particles keep moving under the previous revision until the file is fixed.

`examples/shading_paths` puts a `standard_twin` sphere beside the Standard `dielectric` sphere with the same parameters. The twin compiles in process from its two stage files, which share `custom/standard_twin.glsl` through `compile_glsl(includes:)`; the two spheres look the same in all four views (forward and deferred, flat and clustered). `examples/rt_shadows` swaps its ground between the Standard material and a twin with the same parameters on `C` (`--twin-ground` starts on the twin); the twin carries both traced forms, so with ray-traced shadows on, on either trace kind (`--software`), the off-camera box's shadow stays on the ground across the swap.

`examples/compute_textures` writes an animated value-noise pattern into an empty storage texture every frame with `noise.comp.glsl` and binds it as the boxes' base map, then, between `render_view` and `finish_view`, runs `fog.comp.glsl` over the view: it samples the depth image and loads and stores the scene image in place. F toggles the fog, N freezes the noise, R reloads; both files are polled.
