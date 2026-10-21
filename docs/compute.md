# Compute dispatch

An application runs its own compute stages inside a frame. The asset store holds a `ComputeShaderAsset`, the renderer
owns the buffers and the declared textures the stage reads and writes, and `Renderer.dispatch` records the work at its
call position in the frame. The pieces live in `c3d::asset` (`ComputeShaderDesc`) and `c3d::render` (`Renderer`,
`DispatchDesc`, `BufferDesc`).

A compute stage can also trace rays against the static scene through `Renderer.prepare_scene_trace` and
`scene_trace.glsl` ([Scene tracing](scene_trace.md)).

## Quick start

Advance a particle buffer every frame:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(local_size_x = 64) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;

struct Particle {
    vec4 position_life;
    vec4 velocity;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer Particles { Particle values[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleRoot {
    uint64_t particles;
    uint count;
    float delta;
};

void main() {
    ParticleRoot root = ParticleRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    Particles(root.particles).values[index].position_life.xyz += root.delta;
}
```

```c3
import c3d::asset;
import c3d::material;
import c3d::render;
import std::math;

struct Particle {
    Vec4 position_life;
    Vec4 velocity;
}

struct ParticleRoot {
    ulong particles;
    uint  count;
    float delta;
}

ComputeShaderDesc compute_desc = { .compute = compute_spirv };
ComputeShaderId simulate = assets.add_compute_shader(&compute_desc, "particles")!;

BufferId particles = renderer.create_buffer({
    .size       = PARTICLE_COUNT * Particle::size,
    .usage      = BufferUsage.GPU_PRIVATE,
    .debug_name = "particles",
})!;

renderer.begin_frame(info)!;
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

## Concepts

- **Compute shader asset.** One SPIR-V stage, copied into the store. `add_compute_shader` faults `INVALID_ARGUMENT` for
  an empty stage or a duplicate key and `CAPACITY_EXCEEDED` when the pool is full. `replace_compute_shader` advances the
  revision, `mark_compute_shader_dirty` advances it after an in-place edit, and `remove_compute_shader` frees the
  record. `find_compute_shader` looks up a key. `compile_glsl` takes `ShaderStage.COMPUTE`.
- **Root.** The stage declares the compute push block, one `uint64_t root_gpu`. It addresses a generated
  `DispatchRoot { uint64_t textures; uint64_t parameters; }`. `parameters` is the application's root and `textures` is
  the renderer's binding block for declared textures, zero when none are declared. Everything else is reached through
  buffer references.
- **Frame position.** Dispatches record in call order anywhere between `begin_frame` and `end_frame`, outside an
  overlay, after the frame's pending asset uploads.
- **Ownership.** The renderer owns buffers. A `BufferId` stays live until `destroy_buffer`. `destroy_renderer` releases
  whatever is still live.

## Buffers

`Renderer.create_buffer(desc)` creates a device buffer that shaders address through `buffer_address`.

| `BufferDesc` field | Meaning |
| --- | --- |
| `size` | Bytes; must be above zero |
| `usage` | Who writes the buffer |
| `debug_name` | Name in debug tools |

| `BufferUsage` | Written by | Notes |
| --- | --- | --- |
| `GPU_PRIVATE` | Shaders only | |
| `UPLOAD` | Shaders and `write_buffer` | The CPU writes through the frame's upload ring |
| `READBACK` | Shaders | The CPU reads it back later ([Readback](#readback)) |

- `buffer_address(buffer)` returns the device address an application packs into its root or into a custom material
  payload, so a custom vertex stage can draw from a buffer a compute stage wrote.
- `write_buffer(buffer, bytes)` needs an open frame and an `UPLOAD` buffer. The renderer stages the bytes in the frame's
  upload ring and copies them before the frame's first dispatch. It writes from offset zero and faults
  `INVALID_ARGUMENT` for a buffer that is not `UPLOAD`, for more bytes than the buffer holds, and once the frame has
  recorded a dispatch or a rendered view, so every staged write lands before every dispatch.
- `destroy_buffer(buffer)` retires the allocation after its last submitted frame completes. The id is dead afterwards.
- A renderer holds at most `BUFFER_CAPACITY` (64) buffers. `create_buffer` faults `CAPACITY_EXCEEDED` past that.
- A dead buffer id faults `INVALID_ID`.

## Dispatch

`Renderer.dispatch(desc)` records one dispatch.

| `DispatchDesc` field | Meaning |
| --- | --- |
| `shader` | `ComputeShaderId` |
| `root` | The application's std430 root bytes; copied into the upload ring, and their address becomes `DispatchRoot.parameters` (zero for an empty root) |
| `groups` | Workgroup counts |
| `writes` | Buffers the dispatch writes |
| `geometry` | `GeometryWrite` entries ([Geometry writes](#geometry-writes)) |
| `textures` | Declared textures, at most `MAX_DISPATCH_TEXTURES` (8) ([Textures](#textures)) |

`writes` names the buffers the dispatch writes. The renderer records one barrier before the dispatch, from every
consumer stage to compute, and one after, from compute to the vertex, fragment and compute stages, so a later dispatch
or draw in the same frame reads the results. A dispatch with no writes records no buffer barrier. Buffer reads need no
declaration.

A dispatch faults `INVALID_ID` for a dead shader, buffer or geometry id and `INVALID_ARGUMENT` for more than
`MAX_DISPATCH_TEXTURES` textures. A rejected stage is skipped and counted ([Reload](#reload)). Indirect dispatch is not
supported.

`Stats.dispatches` counts the frame's custom dispatches. `Pass.CUSTOM_COMPUTE` times those before the frame's first
`render_view`, and `Pass.CUSTOM_COMPUTE_POST` those after.

### Textures

A dispatch declares every texture it samples or stores in `DispatchDesc.textures`. Entry `i` becomes slot `i` of the
generated `DispatchTexturesGpu` block behind `DispatchRoot.textures`, `{ uint texture_index; uint sampler_index; }` per
slot. The constructors name the source and the access:

| Constructor | Source | Access |
| --- | --- | --- |
| `read_texture(texture, sampler = {})` | Store texture | Sampled |
| `write_texture(texture, mip = 0, layer = 0, access = WRITE)` | Storage store texture | Store, or load and store with `READ_WRITE` |
| `read_target(target, sampler = {})`, `write_target(target, access = WRITE)` | Render target | Sampled, or storage |
| `read_view_color(view, sampler = {})`, `write_view_color(view, access = WRITE)` | The view's current scene image | Sampled or storage |
| `read_view_depth(view, sampler = {})` | The view's depth image | Sampled only |

```glsl
DispatchRoot root = DispatchRoot(pc.root_gpu);
DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
float depth = sample_texture_2d(textures.slots[0].texture_index, textures.slots[0].sampler_index, uv).r;
vec4 color = load_storage_texture(textures.slots[1].texture_index, ivec2(coord));
store_storage_texture(textures.slots[1].texture_index, ivec2(coord), mix(color, fog, amount));
```

- A zero sampler id selects the renderer's linear clamp sampler.
- Before the dispatch the renderer moves each declared image into its declared state. A target rendered by an earlier
  view, a texture uploaded this frame, or an image written by an earlier dispatch is readable without further
  declaration. After the dispatch a store texture returns to the sampled state materials expect, while targets and view
  images keep their tracked state for the next pass that uses them. Two dispatches that leave a texture in the same
  storage state still record a barrier between them. Only sampled reads share a state without one.
- A `read_texture` entry for an `R16_UINT` texture is read with
  `gpu_fetch_uint(textures.slots[i].texture_index, texel, 0)`, never sampled.
- A `read_view_depth` entry before the view's `render_view` of the open frame reads the depth of the view's previous
  rendering, because the prepass of this frame clears it later. `Renderer.view_depth_frame(view)` says which frame that
  rendering was and faults `NOT_READY` when the image holds none (a first frame, a `configure_view` that recreated it, a
  path-traced view). The depth is `D32_FLOAT`, reverse-Z, with 0 for background. A multisample view holds sample 0 of
  its resolve. Read it with `texelFetch` through `asset::SAMPLER_NEAREST`, because a filtered read blends a foreground
  surface into the background at silhouettes. Each dispatch that names the depth records one barrier into the sampled
  compute state, including when an earlier dispatch left it there, and the view's next pass moves it back.
- A store texture is writable when its `TextureDesc.storage` is set. Only `RGBA8_UNORM`, `RGBA16_FLOAT` and
  `RGBA32_FLOAT` accept the flag. Other formats, including block-compressed, sRGB and `R16_UINT`, fault
  `INVALID_ARGUMENT`. `add_texture_empty(desc, key)` creates a storage texture with no pixels, with contents undefined
  until a dispatch writes them. A material can bind it before that.
- A dispatch writes one mip of one layer per declaration. Levels it does not write keep their previous contents.
  `Renderer.upload(texture)` writes the CPU pixels back over the GPU contents.
- Faults: a dead id `INVALID_ID`; a write to a texture without `storage`, a mip or layer out of range, a write to a view
  depth, or a view with no scene image yet `INVALID_ARGUMENT`; a storage write to an `RGBA8_SRGB` target `UNSUPPORTED`.

### Geometry writes

A dispatch can write the vertex streams of a resident geometry. `DispatchDesc.geometry` lists
`GeometryWrite { geometry, streams, local_bounds }`, where `streams` names the positions, normals and tangents the
shader writes. The application packs the stream addresses into its root:

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

`geometry_stream_address` needs an open frame and returns the address of any present stream of the geometry's block for
the current frame. Positions and normals are packed three-float vectors (12 bytes per vertex), tangents are four-float
vectors, indexed by vertex. Only positions, normals and tangents can be written.

- **Validation.** A dead geometry id faults `INVALID_ID`. A geometry that is not resident (call `upload_geometry`
  first), a stream the geometry does not carry, a stream other than positions, normals or tangents, an empty stream set,
  or the same geometry twice faults `INVALID_ARGUMENT`. Every fault comes before the dispatch records or stages
  anything. A geometry with a CPU revision still waiting for its upload is uploaded first, so the write lands after it.
- **Barriers.** The dispatch brackets a geometry write like a buffer write: consumer stages to compute before, compute
  to the consumer stages and transfer after.
- **Device revision.** The write is a device revision of the named streams. Draws, shadows, the velocity pass and the
  trace refit read it in the same frame. The CPU arrays do not change, and no CPU upload happens. A later CPU revision
  (`mark_geometry_dirty`, `mark_geometry_streams_dirty`, `mark_geometry_range_dirty`, `replace_geometry`) uploads the
  whole block again from the CPU arrays, overwrites the device contents of every stream and restores the geometry's
  bounds. Record the dispatch before the draws that should show it and before `prepare_scene_trace`.
- **Velocity.** The first write of a frame that names positions copies the positions the block held into a
  renderer-owned buffer, allocated once at the geometry's first write, before the dispatch records. A `Mesh` with
  `vertex_motion` reads it as its previous positions in a view that drew the mesh the frame before: the velocity of a
  moving write is the per-vertex motion, and a frame without a write reports none. The buffer is per geometry, so a view
  that skips frames sees one frame of motion. `Stats.vertex_history_bytes` stays zero for a device-written geometry, and
  its CPU arrays can be released.
- **Tracing.** A `vertex_motion` mesh's posed trace slot copies the written streams and refits its tree or updates its
  bottom-level structure in the same frame ([Scene tracing](scene_trace.md)). The shared rest tree and bottom level of a
  geometry that no `vertex_motion` mesh traces keep the CPU form.
- **Bounds.** `local_bounds` replaces the geometry's bounds for culling, the scene index, picking and the top-level
  structure until the next CPU revision. It must contain every position the shader can write. Picking tests the bounds
  only, because the CPU arrays do not describe the drawn vertices.

`DeformRoot` is an application root struct that holds the two addresses.

### Readback

`BufferUsage.READBACK` creates a buffer that shaders write like a `GPU_PRIVATE` one and the CPU can read back later. At
the end of every frame that recorded work, the renderer copies each live `READBACK` buffer into a mapped staging copy.
`Renderer.read_buffer(buffer)` inside an open frame returns the contents the buffer held when the frame
`FRAMES_IN_FLIGHT` frames earlier ended:

```c3
renderer.begin_frame(info)!;
char[] bytes = renderer.read_buffer(positions)!;
```

The result borrows mapped memory without copying or allocating and stays valid until the next `begin_frame`.
`read_buffer` faults `render::NOT_READY` until that frame has been copied, so in the first `FRAMES_IN_FLIGHT` frames and
after a frame that recorded no work or was aborted. It faults `INVALID_ARGUMENT` for a buffer that is not `READBACK`.
The copy is made after every dispatch of the frame, and the staging keeps `FRAMES_IN_FLIGHT + 1` copies of the buffer.

### Dispatch around views

`render_view` records a view's scene passes. `finish_view(view)` records its depth of field, display chain and output. A
dispatch between the two reads the view's depth and reads or writes its scene image in place, and the post chain sees
the result. A dispatch after `finish_view` sees the finished image. `end_frame` faults `INVALID_ARGUMENT` when a
rendered view was not finished, and `Renderer.render` calls both. `view_extent(view)` gives the working size a dispatch
over the view covers and is zero while the view has no working images. A `write_view_color` before the view's
`render_view` is overwritten by the view's clear. A dispatch that reads or writes the view's color sees pre-exposed
values ([Pre-exposure](custom_shaders.md#pre-exposure)).

## Reload

Compute pipelines share the pipeline cache and the reload behavior of custom materials. `replace_compute_shader`
followed by the next dispatch, or by `renderer.upload(compute_shader)`, rebuilds the pipeline under the new revision and
publishes it on success. A backend rejection (a push block that is not `RootPush`, a missing `main`) keeps the previous
revision dispatching, lands in the debug log and in `Stats.shader_rejections`, and `upload` returns the fault. A first
revision that is rejected skips its dispatches until the shader is replaced. See [Reload](custom_shaders.md#reload).

## Limits

- At most 64 buffers and 8 declared textures per dispatch.
- Geometry writes cover positions, normals and tangents only.
- Indirect dispatch is not supported, and `read_buffer` works on `READBACK` buffers only.
- A stage that reads the view image sees pre-exposed values.

Run `python3 scripts/build.py --example custom_compute` for a particle simulation and
`python3 scripts/build.py --example compute_textures` for a storage texture and a view-image pass.

## See also

- [Custom shaders](custom_shaders.md) for materials that draw from the buffers.
- [Scene tracing](scene_trace.md) for tracing from a compute stage.
- [Views](views.md) for `render_view`, `finish_view` and view images.
- [Textures](textures.md) for storage textures.
