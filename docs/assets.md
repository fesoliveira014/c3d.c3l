# Asset store

`AssetStore` (module `c3d::asset`) owns every CPU asset of an application: geometries, textures, samplers, materials,
models, clips, skeletons, shaders, compute shaders, environments and fonts, plus kinds that add-ons register. An asset is
addressed by a typed generational id and optionally by a unique string key. The store never creates a GPU object: the
renderer mirrors a record when it first uses its id and again when the record's revision moves. Loaders write the
store; the scene refers to assets by id.

## Quick start

```c3
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;

AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
defer asset::destroy_asset_store(&assets);

@pool() {
    Geometry box_geometry = geometry::box(tmem, 1, 1, 1);
    GeometryId box = assets.add_geometry(&box_geometry, "cube/box")!;
};
MaterialId red = assets.add_material(material::basic({ .color = { 0.9f, 0.2f, 0.2f, 1 } }), "cube/red")!;

GeometryId again = assets.find_geometry("cube/box")!;
```

Pass `&assets` to the renderer when you create it, and to the loaders and importers ([Models](models.md)).

## Concepts

### Kinds, ids and records

Each kind has its own pool, id type and record type. An id is an `Id { index, generation }` made distinct per kind
(`GeometryId`, `TextureId`, `ModelId` and so on). The zero id is never live. Removing a record advances its slot's
generation, so every old id of it is stale.

`assets.geometry(id)`, `assets.model(id)` and the other accessors borrow the record from the pool. A record holds an
`AssetHeader` (`key`, `revision`, `replaced_revision`) and the kind's payload: `data` for geometry, material, model,
clip and skeleton, `desc` for texture, sampler, shader, compute shader, environment and font. Accessors require a live id. To test one, ask the pool: `assets.geometries.is_live(id)` or `try_get(id)`, which
faults `INVALID_ID`. A borrow stays valid until the pool changes structure, so reacquire it after adding or removing
records of that kind.

`AssetRef { kind, slot, id }` names an asset of any kind. `find` returns it and `AssetKind` enumerates the kinds:
`GEOMETRY`, `TEXTURE`, `SAMPLER`, `MATERIAL`, `MODEL`, `CLIP`, `SKELETON`, `SHADER`, `COMPUTE_SHADER`, `ENVIRONMENT`,
`CUSTOM` ([Custom asset kinds](custom_assets.md)) and `FONT`, in enum order: 11 built-in kinds plus `CUSTOM`.

### Keys

A key is an optional unique string given when a record is added. An empty key leaves the record unkeyed.

- Keys are unique across all kinds of one store. A duplicate faults `INVALID_ARGUMENT` before any capacity is taken.
- The store copies the key. Removing the record frees it, so the key can be used again.
- `find(key)` returns an `AssetRef` or faults `NOT_FOUND`. `find_geometry`, `find_texture`, `find_material` and the
  other typed forms fault `INVALID_ARGUMENT` when the key names another kind.
- Importers key every asset they create under the model key ([Keys](models.md#keys)). Keys of built-in assets start
  with `builtin/`.

### Ownership and threads

The store owns every payload. An `add_*` or `replace_*` function without an `_owned` suffix copies its arguments, so
arrays may live in temporary memory. An `_owned` function takes over arrays that were allocated with `assets.allocator`
and frees them with the record, but only on success: after a fault the caller keeps them. Models, clips and skeletons
have only this form.
The store has no internal locking: one owner thread mutates it, and a background loader only decodes into private
documents ([Asset loading](asset_loading.md)). The renderer reads the store through the pointer it was created with, so
keep the store alive while the renderer uses it.

`destroy_asset_store` frees every payload, key and pool, runs the custom-kind destroy hooks and leaves the store zeroed.

## Create a store

`create_asset_store(allocator, desc)` allocates one fixed-capacity pool per kind and registers the built-in assets.
Capacities never grow: adding to a full pool faults `CAPACITY_EXCEEDED`.

| `AssetStoreDesc` field | Default | Constraint |
| --- | ---: | --- |
| `max_geometries` | 4096 | Greater than zero. |
| `max_textures` | 4096 | At least `BUILTIN_TEXTURE_COUNT` (4). |
| `max_materials` | 4096 | Greater than zero. |
| `max_samplers` | 64 | At least `BUILTIN_SAMPLER_COUNT` (5). |
| `max_environments` | 16 | Zero selects the default. |
| `max_models` | 256 | Zero selects the default. |
| `max_skeletons` | 256 | Zero selects the default. |
| `max_clips` | 1024 | Zero selects the default. |
| `max_shaders` | 64 | Zero selects the default. |
| `max_compute_shaders` | 16 | Zero selects the default. |
| `max_fonts` | 16 | Zero selects the default. |
| `file_source` | file system | Copied at creation; see [File sources](#file-sources). |

`default_asset_store_desc()` returns the defaults. Start from it and change the fields you need. `create_renderer` sizes
its mirror tables and the material heap from these capacities, so every slot costs renderer memory whether or not it is
used. Asset textures also share the renderer's texture table ([Views](views.md)).

Every store holds these built-in assets:

| Id | Key | Content |
| --- | --- | --- |
| `TEXTURE_WHITE`, `TEXTURE_BLACK` | `builtin/white`, `builtin/black` | One texel. |
| `TEXTURE_FLAT_NORMAL` | `builtin/flat_normal` | One +Z tangent-space normal. |
| `TEXTURE_CHECKER` | `builtin/checker` | 8x8 gray checkerboard. |
| `SAMPLER_LINEAR_REPEAT`, `SAMPLER_LINEAR_CLAMP` | `builtin/linear_repeat`, `builtin/linear_clamp` | Trilinear, repeat or clamp to edge. |
| `SAMPLER_NEAREST` | `builtin/nearest` | Nearest, repeat. |
| `SAMPLER_ANISOTROPIC` | `builtin/anisotropic` | Trilinear, repeat, 16x anisotropy clamped by the renderer. |
| `SAMPLER_SHADOW` | `builtin/shadow` | Linear clamp with `GREATER_EQUAL` compare. |

## Add, find and remove

Every kind has the same shape of calls. Remove calls require a live id, and `find_*` faults `NOT_FOUND`. The four
built-in textures and five built-in samplers can be neither removed nor replaced.

| Kind | Add | Replace | Mark changed | Remove, find |
| --- | --- | --- | --- | --- |
| Geometry | `add_geometry`, `add_geometry_owned` | `replace_geometry`, `replace_geometry_owned` | `mark_geometry_dirty`, `mark_geometry_streams_dirty`, `mark_geometry_range_dirty` | `remove_geometry`, `find_geometry` |
| Texture | `add_texture`, `add_texture_owned`, `add_texture_mips`, `add_texture_empty` | `replace_texture`, `replace_texture_owned`, `replace_texture_mips`, `replace_texture_empty` | `mark_texture_dirty`, `mark_texture_region_dirty` | `remove_texture`, `find_texture` |
| Sampler | `add_sampler` | `replace_sampler` | `mark_sampler_dirty` | `remove_sampler`, `find_sampler` |
| Material | `add_material` | `replace_material` | `mark_material_dirty` | `remove_material`, `find_material` |
| Model | `add_model_owned` | `replace_model_owned` | | `remove_model`, `find_model` |
| Clip | `add_clip_owned` | `replace_clip_owned` | | `remove_clip`, `find_clip` |
| Skeleton | `add_skeleton_owned` | `replace_skeleton_owned` | | `remove_skeleton`, `find_skeleton` |
| Shader | `add_shader` | `replace_shader` | `mark_shader_dirty` | `remove_shader`, `find_shader` |
| Compute shader | `add_compute_shader` | `replace_compute_shader` | `mark_compute_shader_dirty` | `remove_compute_shader`, `find_compute_shader` |
| Environment | `add_environment` | `replace_environment` | `mark_environment_dirty` | `remove_environment`, `find_environment` |
| Font | `add_font`, `add_font_owned` | `replace_font`, `replace_font_owned` | | `remove_font`, `find_font` |

Add calls return the new id and fault `CAPACITY_EXCEEDED` when the pool is full and `INVALID_ARGUMENT` for a duplicate key
or invalid content. Each kind adds its own faults for its payload: textures `UNSUPPORTED` and `ASSET_DATA_UNAVAILABLE`,
fonts `ASSET_FORMAT_ERROR` and `UNSUPPORTED`, environments `INVALID_ID` and `UNSUPPORTED`. The per-kind pages cover the payload rules: [Textures](textures.md), [Materials](materials.md),
[Models](models.md), [Animation](animation.md), [Text](text.md) and [Environments](environments.md). Removing a model
frees its template and leaves the assets it references in the store.

### Revisions

Every record carries `header.revision`, which starts at 1 on add. The renderer compares it with the revision it last
uploaded.

- `mark_*_dirty` advances the revision after an in-place edit of the payload.
- `replace_*` swaps the whole payload and advances the revision once. Every kind except shaders and compute shaders also
  sets `header.replaced_revision` to the new revision, so consumers that refresh incrementally do not patch replaced
  content as an edit.
- Replacing never changes an id or key. Call replacements from the owner thread, outside frame recording. The renderer
  retires the old GPU objects after their last submitted frame.

### Replacing geometry, skeletons and clips

```c3
assets.replace_geometry(geometry, &source)!;        // copies; replace_geometry_owned takes the arrays
assets.replace_skeleton_owned(skeleton, &source)!;
assets.replace_clip_owned(clip, &source)!;
```

The same rules cover `replace_texture` and its variants. Each call takes the inputs of the matching `add_*` form. Geometry and clip replacement reject the data their add form
rejects with `INVALID_ARGUMENT`; skeleton replacement checks only the structure. A change that live components were sized
against faults `INCOMPATIBLE_STRUCTURE` and changes nothing.

| Kind | May change | Faults `INCOMPATIBLE_STRUCTURE` |
| --- | --- | --- |
| Geometry | Vertex and index counts, streams other than joints, weights and morph deltas, custom data, bounds, target and channel names. | Topology; presence of joints and weights; a positive-weight joint above the largest one at add; morph target count; per target, presence of position and normal deltas; channel count, `first_target` and weight count. |
| Skeleton | Rest pose, inverse bind, names. | Joint count, parents. |
| Clip | Name, interpolation, times, values, events, a positive duration's value. | Targets table, track count, each track's target, path and stride, a duration that is or is not positive. |
| Texture | Extent, mip count, pixels and a format change that keeps `R16_UINT`-ness. | The cube flag, the storage flag, the layer count, whether depth is zero, and `R16_UINT` against any other format. |

The joint bound is fixed when the geometry is added and survives `release_geometry_cpu`; a replacement may use any range
up to it. Physics mesh colliders and the navigation rasterizer read the triangle list, so a topology change is
structural. Replacing a geometry rebuilds its skin and morph bounds at once and drops its triangle tree, which rebuilds on
next use.
A model replacement is described in [Asset loading](asset_loading.md#replace-a-model).

## File sources

Every file that a model importer, a texture or image loader or the asynchronous loader reads goes through the store's
file source. With none set, files come from the file system.

```c3
fn char[]? read_pack(void* user, Allocator allocator, String path) {
    Pack* pack = user;
    return pack.read(allocator, path);
}

AssetStoreDesc desc = asset::default_asset_store_desc();
desc.file_source = { .read = &read_pack, .user = &pack };
AssetStore assets = asset::create_asset_store(mem, desc);
```

- `AssetStoreDesc.file_source` is copied at `create_asset_store` and has no setter. The `user` pointer must outlive the
  store. A null `read` selects the file system.
- A `ReadFileFn` returns the whole file in bytes allocated with the given allocator, which the caller frees. Any fault it
  returns reaches the importer as `ASSET_IO_ERROR`, so importer fault lists do not change.
- The asynchronous loader copies the source at `create_async_loader` and calls it from its worker thread, while the owner
  thread may call it for synchronous loads. A source must be thread-safe and must not call into the store.
- Decoders that take no store (`gltf::decode_model`, `gltf::decode_model_memory`, their `_with_source` forms and
  `fbx::decode_model`) and `image::load_image` take a trailing `FileSource file_source = {}`. The `_memory` entry points
  read external buffers and images through it under `base_dir`.
- `AssetStore.read_file(allocator, path)` reads through the store's source, and `asset::read_file_system` is the default
  implementation, so a custom source can fall back to loose files.

A source sees one canonical form of every path. `asset::normalize_path` turns `\` into `/`, keeps an absolute prefix (`/`,
`X:/` or `//server/share`), drops empty and `.` segments and collapses `name/..` pairs. A `..` with nothing to remove stays.
It never decodes `%`: glTF URIs are decoded as usual, and application paths and FBX file names are used literally.

| Importer forms | Source receives |
| --- | --- |
| `models/a.gltf` | `models/a.gltf` |
| Buffer `x.bin` and image `textures/a.png` of `model.gltf` | `x.bin` and `textures/a.png` |
| Image `./textures/a.png` of `models/a.gltf` | `models/textures/a.png` |
| `C:\art\..\a.fbx` | `C:/a.fbx` |
| FBX texture, relative then absolute | Each in normalized form, in that order. |

Keys never change: a model key and its content keys keep the path exactly as given. With the default source, the path the
operating system sees is the normalized one: `\` becomes `/` on every platform (which matters on POSIX for a file name
that contains a backslash), `.` and empty segments disappear, `..` collapses (which matters on POSIX only when the path
crosses a symlinked directory) and a path that collapses to nothing becomes `.`.

## Limits

- Pool capacities are fixed at creation; there is no growth or compaction.
- The store is single-threaded; only the owner thread adds, replaces or removes.
- A key is unique per store across all kinds, and a key cannot be changed after the record is added.
- A process registers at most `MAX_CUSTOM_ASSET_TYPES` (16) custom kinds.
- The store holds CPU data. GPU residency, budgets and uploads belong to the renderer ([Textures](texture_streaming.md#residency-and-memory-budgets)).

## See also

- [Models, glTF and FBX import](models.md) and [Asset loading](asset_loading.md) for filling a store.
- [Custom asset kinds](custom_assets.md) for registering a kind.
- [Geometry edits](geometry_edits.md) for changing a geometry in place and publishing the changed vertices.
- [Owner readiness](owner_readiness.md) for components that finish after a load.
- [Architecture](architecture.md) for where the store sits between the scene and the renderer.
