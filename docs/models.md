# Models, glTF and FBX import

A model is loaded once into shared assets plus a reusable template, then
instantiated any number of times without reparsing. `c3d::asset::gltf` reads
glTF 2.0 and GLB files through cgltf and `c3d::asset::fbx` reads FBX files through ufbx; `c3d::model::instantiate` turns a stored
template into live scene nodes. The renderer sees meshes, LOD groups, cameras and
lights afterwards and needs no model-specific path. Skeletons and animation
clips are shared assets; `c3d::anim` plays clips onto instances
([Animation](animation.md)). Asset kinds the store does not define are
registered by their owners ([Custom asset kinds](custom_assets.md)).

## Load once, instantiate twice

```c3
ModelId model = gltf::load_model(&assets, "models/helmet.glb")!;
Node* left = model::instantiate(&assets, &scene, model, name: "left")!;
Node* right = model::instantiate(&assets, &scene, model, name: "right")!;
right.local.position = { 2, 0, 0 };
renderer.prepare_scene(&scene)!;
```

`load_model` parses the file, converts every sampler, image, material and
primitive into store assets, and stores a `ModelTemplate` under the path as
its key. `load_model_memory` does the same from bytes, with a caller-supplied
key and a base directory for external URIs. Loading never touches a scene:
placing a model is always `model::instantiate`, and the caller sets the root
transform.

Instantiation creates one synthetic root under the parent and one live node per
template node, parents before children. `ModelInstance.present_node(i)` resolves
the original node of template index `i`, or null after its removal. The node
table captures entity identities, so reusing a removed node's slot does not
retarget the instance. Reparenting a live node keeps its template membership.
Indices and authored arrays retain their original extents after node removal.

Meshes, cameras and lights become the usual components. The root carries a
`ModelInstance` component holding the node table, captured identities, authored
local transforms and authored morph weights. The scene owns every node and
array. Removing the root removes its remaining subtree and frees the component
arrays through the removal hook; shared assets remain untouched. Removing the
model template afterwards leaves existing instances intact. See the
[animation lifetime rules](animation.md#removed-instance-nodes) for identity
lifetimes, missing tracks and required skin joints.

A subtree serialized with `c3d_serial` retains its model key, exact structural
signature, captured template identities and authored overrides. Restore creates
the saved graph directly, preserving deleted template slots and application
children; it does not recreate removed components from the template. The source
model and referenced keyed assets must be live in the destination store. A
structural mismatch returns `INCOMPATIBLE_TEMPLATE` with the model key and first
differing template index. See [serialization](serialization.md) for animation
restart, required skin references and owner preparation.

## Keys

Every asset an import creates is keyed under the model key, which is the file
path for `load_model` and the caller's key for `load_model_memory`:

| Asset | Key |
| --- | --- |
| Model template | `<key>` |
| Sampler `i` | `<key>#sampler/<i>` |
| Image `i` decoded as sRGB color | `<key>#image/<i>/srgb` |
| Image `i` decoded as linear data | `<key>#image/<i>/linear` |
| Material `i` | `<key>#material/<i>` |
| Default material for primitives without one | `<key>#material/default` |
| Primitive `j` of mesh `i` | `<key>#mesh/<i>/<j>` |
| Skin `i` | `<key>#skeleton/<i>` |
| Animation `i` | `<key>#anim/<i>` |

A key already present in the store makes the load fail with `INVALID_ARGUMENT`
before anything is parsed. An image referenced as base color, emissive, sheen
color or specular color becomes an sRGB texture; every other reference becomes a
linear texture; an image used both ways becomes two textures. Images nothing
references are not decoded.

## Options

`LoadOptions` selects what the importer keeps. `LOAD_OPTIONS_DEFAULT` enables
everything. Both live in `c3d::asset` and are shared by every model loader.

| Field | Effect |
| --- | --- |
| `animations` | Import animations as clip assets listed by the template; skins are imported either way. |
| `lights` | Import `KHR_lights_punctual` lights as `ModelLight` entries. |
| `cameras` | Import cameras as `ModelCamera` entries. |
| `generate_tangents` | Compute tangents for triangle primitives that have a normal map and UV0 but no `TANGENT` stream. |

## Node index contract

Template nodes are ordered depth first from the default scene's roots, or from
every parentless node when the file names no scene, with a parent always before
its children. `NodeTemplate.parent` is the model-local index of the parent, or
`-1` for a template root. A source node with a mesh keeps its transform and
gains one generated child per primitive, named `<node name>/primitive/<j>`,
placed before the node's authored children. Matrix nodes are decomposed into
position, rotation and scale; shear is dropped.

## Node-level LOD

Rigid node-level `MSFT_lod` becomes one [LodGroup](lod.md). Alternate subtrees
flatten into group-relative parts while preserving the alternate root transform
in the owner's parent space. Part counts and materials may differ. Absorbed
primitive nodes remain named template nodes without duplicate Mesh components;
unrelated cameras and lights remain. Each instantiation owns its descriptor copy.
Eager and budgeted renderer preparation visit every level's dependencies.

Whole-owner animation is retained. Skin/morph deformation or animation within
member subtrees is unsupported: optional LOD falls back to the ordinary highest
detail subtree; required LOD faults `UNSUPPORTED`. Required material-level LOD
also faults `UNSUPPORTED`. Bad node IDs, cycles, conflicting ownership and
malformed hints fault `ASSET_FORMAT_ERROR`.

For N levels, `extras.MSFT_screencoverage` must contain N finite numeric values.
The first N-1 are positive descending projected-height fractions; the final
nonnegative cull hint is ignored. Missing hints use transitions
`{0.2, 0.1, 0.05, 0.025}`. Five levels are supported. This projected-height
interpretation is c3d's import policy. `ModelDocument` validates references before
publication, then remaps all part geometry/material IDs atomically with the model.

## Material mapping

| glTF | c3d |
| --- | --- |
| `KHR_materials_unlit` | `material::basic` with the base color factor and texture |
| Metallic-roughness only | `material::standard` |
| Any of clearcoat, sheen, transmission, volume, IOR, specular or anisotropy | `material::physical` |
| `baseColorFactor`, `metallicFactor`, `roughnessFactor`, `emissiveFactor` | The matching Standard factors |
| `KHR_materials_emissive_strength` | `emissive_strength`; one when absent |
| `normalTexture.scale` | `normal_scale` |
| `occlusionTexture.strength` | `occlusion_strength` |
| `alphaMode`, `alphaCutoff`, `doubleSided` | `MaterialCommon` |
| `KHR_materials_clearcoat` | `clearcoat`, `clearcoat_roughness`, `clearcoat_normal_scale` and their maps |
| `KHR_materials_sheen` | `sheen_color`, `sheen_roughness` and their maps |
| `KHR_materials_ior` | `ior`; 1.5 when absent |
| `KHR_materials_specular` | `specular`, `specular_color` and their maps |
| `KHR_materials_anisotropy` | `anisotropy`, `anisotropy_rotation` and the direction map |
| `KHR_materials_transmission` | `transmission` and its map |
| `KHR_materials_volume` | `thickness`, `attenuation_color`, `attenuation_distance` and the thickness map; an absent or unbounded attenuation distance becomes zero |
| `KHR_texture_transform` | `TextureSlot.transform` offset, rotation and scale; the extension's `texCoord` overrides the view's |

Every texture view becomes a `TextureSlot` carrying its texture, its sampler or
the builtin linear repeat sampler, and its UV set. Sampler filters map
nearest-or-linear per stage; the mip filter follows the minification filter's
mipmap half and is linear when the source names none. Wrap modes map to the
matching address modes; the W axis repeats. Every factor is validated against
the constructor domains before the material is built; a value outside them is
`ASSET_FORMAT_ERROR`.

## Geometry

Each primitive becomes one `Geometry` asset. `POSITION`, `NORMAL`, `TANGENT`,
`TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `JOINTS_0` and `WEIGHTS_0` are read;
normalized integer streams are expanded to floats, three-component colors gain
an alpha of one, and a primitive with joints but no weights or the reverse is
`ASSET_FORMAT_ERROR`. Point, line and triangle lists pass through; strips, fans and loops are rewritten into
indexed lists. Triangle primitives without normals receive smooth normals.
A primitive with morph targets but no node or mesh weights starts every target at zero, so a
weights clip on the node plays; a supplied weights count that differs from the target count is an
`ASSET_FORMAT_ERROR`. A `matrix` node decomposes with its sign: a reflection lands in the x scale,
zero-scale columns complete an orthonormal frame, and shear or non-finite values are an
`ASSET_FORMAT_ERROR`. An orthographic camera keeps both magnitudes: `ortho_height = 2 * ymag` and
`aspect = xmag / ymag`. `COLOR_0` imports as RGBA (RGB gains alpha one) and tints the built-in
shading.
Morph targets keep position and normal deltas and their names; a target with
only one delta kind gains a zero array for the other. Sparse accessors are
expanded. A primitive whose `POSITION` accessor is missing or empty is
`ASSET_FORMAT_ERROR`.

## Skeletons and clips

Each skin becomes a `Skeleton` asset: joint names, parents as indices into the
joint array (`-1` when the parent is not a joint), the rest pose from the
joints' local transforms and the inverse-bind matrices from the accessor, or
identity when the skin has none. Every primitive child of a skinned mesh node
gets a `ModelSkin` entry naming the skeleton and the template indices of the
joints in skeleton order. Instantiation turns each entry into a `SkinBinding`
component on the live mesh node, with the joints mapped to live nodes. A joint
outside the imported node set is `ASSET_FORMAT_ERROR`.

Each animation becomes an `AnimationClip` asset over model-local node indices.
`targets` lists the distinct template nodes the channels address in first
appearance order and each `Track.target` indexes that list. Translation,
rotation and scale channels become one track on the authored node; a weights
channel becomes one track per primitive child of the node, with the mesh's
morph count as the value stride. Interpolation maps to `STEP`, `LINEAR` or
`CUBIC_SPLINE`; cubic keys keep their in-tangent, value and out-tangent
triples. `duration` is the largest key time. The template lists its clip ids
and every instance copies them. Channels whose target nodes are outside the
imported node set are omitted. This applies to every glTF import, including
unselected scenes and alternate subtrees skipped during optional LOD fallback.
Other imported channels remain intact; a clip with no imported channels has no
tracks. `options.animations = false` skips clips.

`c3d::anim` samples clips onto instance nodes and morph weights; the renderer
builds joint palettes from `SkinBinding` and selects the skinned and morphed
vertex variants ([Animation](animation.md)). glTF geometries carry no
`channels` table, so each morph weight drives the target at its index.

### Replacing geometry, skeletons and clips

```c3
assets.replace_geometry(geometry, &source)!;        // copies; replace_geometry_owned takes the arrays
assets.replace_skeleton_owned(skeleton, &source)!;
assets.replace_clip_owned(clip, &source)!;
```

Each call replaces the content under the same id and key, advances `revision` once and sets `replaced_revision`.
It takes the inputs of the matching `add_*` form and rejects the same data with `c3d::INVALID_ARGUMENT`.
A change that live components were sized against faults with `c3d::INCOMPATIBLE_STRUCTURE` and changes nothing.

| Kind | May change | Faults `INCOMPATIBLE_STRUCTURE` |
| --- | --- | --- |
| Geometry | vertex and index counts, streams other than joints, weights and morph deltas, custom data, bounds, target and channel names | topology; presence of joints and weights; a positive-weight joint above the largest one at add; morph target count; per target, presence of position and normal deltas; channel count, `first_target` and weight count |
| Skeleton | rest pose, inverse bind, names | joint count, parents |
| Clip | name, interpolation, times, values, events, a positive duration's value | targets table, track count, each track's target, path and stride, a duration that is or is not positive |

The joint bound is fixed when the geometry is added and survives `release_geometry_cpu`; a replacement may use any
range up to it. Physics mesh colliders and the nav rasterizer read the triangle list, so a topology change is structural.
Call replacements from the owner thread, outside frame recording. The renderer retires the old objects after
their last submitted frame.

Replacing a geometry rebuilds its skin and morph bounds and drops its triangle tree; both rebuild on next use.

## Replacing a model

```c3
ModelReplaceReport report = gltf::replace_model(&assets, model, "models/city.gltf", missing: missing[..])!;
```

`replace_document(model, &document, missing)` replaces a live model and its keyed parts from a decoded document.
`gltf::replace_model` and `fbx::replace_model` decode a file and call it; `gltf::replace_model_memory` mirrors
`load_model_memory`. The document key must equal the model's key (`INVALID_ARGUMENT` otherwise), and every entry key must
be nonempty and unique.

Each entry key is one of:

- a match: a live record of the same kind under that key. It is replaced in place by the kind's replace call, keeps its
  id, and advances its revision once;
- an addition: a key absent from the store. It is added as in `publish_document`;
- a conflict: a key held by another kind, a builtin texture or sampler, or the model itself (`INVALID_ARGUMENT`).

References inside the document and its template are remapped to the matched and added ids before each entry is replaced.
A template reference that is unset, outside the document's entries or a dead store record faults `INVALID_ARGUMENT`, as in
`publish_document`.
The check phase decides every fault, so a fault leaves the store and the document as they were; on success the document is
emptied.

A replacement faults with `INCOMPATIBLE_STRUCTURE` when a matched geometry, texture, skeleton or clip breaks the
structural rules of its kind (see Replacing geometry, skeletons and clips), a matched clip changes its name, or the new
template differs in its structural signature from the current one. The signature is:

- the node count and each node's parent;
- the mesh list in order: node, geometry, material;
- the skin list in order: mesh node, skeleton, joint nodes;
- the LOD groups in order: node and the full description.

Node names, local transforms, layers, visibility, lights, cameras and the clip list may change. This is the field set the
serialization add-on compares, so a file saved before a compatible replacement still loads after it. The response to
`INCOMPATIBLE_STRUCTURE` is to remove the model, add it again and instantiate again.

`replace_model_owned(model, &template)` swaps the template alone, under the same signature rule.

Existing `ModelInstance`s keep the nodes, base pose, morph baselines, lights, cameras and clip list they were created with.
They show the new meshes, textures and clips because their ids are unchanged. Instances created afterwards use the new
template. A crowd prepared before the replacement keeps its sizes: `set_crowd` faults with `INVALID_ARGUMENT` for a clip
with more tracks than the crowd was prepared for.

Missing parts are records whose key is `<model key>#<suffix>`, where the suffix contains no further `#`, that the document
does not name. This is the importers' sub-asset form (`#mesh`, `#material`, `#image`, `#sampler`, `#skeleton`, `#anim`).
Derived records, such as the clips `fbx::retarget_clips` keys `<anim path>#anim/<i>#<target>#<mode>`, are never reported.
`ModelReplaceReport.missing` counts them all; the optional `missing` slice receives the first `missing.len`, ordered by
`AssetKind`, then by key bytes. The store keeps them, as `remove_model` does; removing one is the application's call.

Call replacements from the owner thread, outside frame recording. The report holds `replaced`, `added` and `missing`.

## Supported and unsupported extensions

Supported: `KHR_materials_clearcoat`, `KHR_materials_sheen`,
`KHR_materials_transmission`, `KHR_materials_volume`, `KHR_materials_ior`,
`KHR_materials_specular`, `KHR_materials_anisotropy`,
`KHR_materials_emissive_strength`, `KHR_materials_unlit`,
`KHR_texture_transform`, `KHR_lights_punctual`, `KHR_mesh_quantization`.

Any other extension listed in `extensionsRequired` makes the load fail with
`UNSUPPORTED`, as does a primitive compressed with Draco or meshopt, and a
texture whose only image comes through `KHR_texture_basisu` or
`EXT_texture_webp`. Unsupported extensions that are merely used are ignored:
specular-glossiness, iridescence, diffuse transmission, dispersion, material
variants and GPU instancing import as if absent.

## File sources

Every file an importer or the asynchronous loader reads goes through the store's
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

- `AssetStoreDesc.file_source` is copied at `create_asset_store` and has no setter.
  The `user` pointer must outlive the store. A null `read` selects the file system.
- A `ReadFileFn` returns the whole file in bytes allocated with the given allocator,
  which the caller frees. Any fault it returns reaches the importer as
  `ASSET_IO_ERROR`, so importer fault lists do not change.
- The asynchronous loader copies the source at `create_async_loader` and calls it
  from its worker thread, while the owner thread may call it for synchronous loads.
  A source must be thread-safe and must not call into the store.
- The decoders that take no store, `gltf::decode_model`, `gltf::decode_model_memory`,
  their `_with_source` forms and `fbx::decode_model`, take a trailing
  `FileSource file_source = {}`. The `_memory` entry points read external buffers
  and images through it under `base_dir`.
- `AssetStore.read_file(allocator, path)` reads through the store's source, and
  `asset::read_file_system` is the default implementation, so a custom source can
  fall back to loose files.

A source sees one canonical form of every path. `asset::normalize_path` turns `\`
into `/`, keeps an absolute prefix (`/`, `X:/` or `//server/share`), drops empty
and `.` segments, and collapses `name/..` pairs. A `..` with nothing to remove
stays. It never decodes `%`; glTF URIs are decoded as before, and application
paths and FBX file names are used literally.

| Importer forms | Source receives |
| --- | --- |
| `models/a.gltf` | `models/a.gltf` |
| buffer `x.bin` and image `textures/a.png` of `model.gltf` | `x.bin` and `textures/a.png` |
| image `./textures/a.png` of `models/a.gltf` | `models/textures/a.png` |
| `C:\art\..\a.fbx` | `C:/a.fbx` |
| FBX texture, relative then absolute | each in normalized form, in that order |

Keys never change: a model key and its content keys keep the path exactly as
given. With the default source the only difference from reading the path
directly is that `..` collapses before the operating system sees it, which
matters on POSIX only when the path crosses a symlinked directory.

## Faults

| Fault | Meaning |
| --- | --- |
| `ASSET_IO_ERROR` | The file, an external buffer or an external image could not be read. |
| `ASSET_FORMAT_ERROR` | The document failed to parse or validate, an image failed to decode, an accessor could not be read, a joint lies outside the imported nodes, or a numeric value lies outside the constructor domains. |
| `UNSUPPORTED` | A required extension or a compressed primitive the importer does not implement. |
| `CAPACITY_EXCEEDED` | A store pool has fewer free slots than the model needs. |
| `INVALID_ARGUMENT` | The model key or a content key is already present, an image file is empty, a skin stream has invalid influences, or a storage texture has a non-storage format. |
| `INVALID_ID` | `instantiate` received a dead model id. |
| `INCOMPATIBLE_STRUCTURE` | A geometry, texture, skeleton, clip or model replacement changes a count or layout that live components were sized against. |

A loader decides every store fault before it inserts anything, so a fault
leaves the store as it was. An instantiation that runs out of nodes removes
the partial subtree and leaves no instance behind.

## Decode and publish

```c3
ModelDocument document = gltf::decode_model(assets.allocator, "models/helmet.glb")!;
defer asset::destroy_model_document(&document);
ModelId helmet = assets.publish_document(&document)!;
```

Every loader is a decode followed by a publish. `gltf::decode_model`,
`gltf::decode_model_memory` and `fbx::decode_model` read the file into a
`ModelDocument` and touch no store, scene or renderer. The allocator owns
everything in the document; it must be the allocator of the store the
document is published into, and never `tmem`, because the decoder opens a
temporary pool of its own.

`AssetStore.publish_document` inserts the document's samplers, textures,
materials, geometries, skeletons and clips, then its template as a model under
the document key. Before the first insertion it checks every key against the
store and against the other keys of the document, the free slots of every pool
the document needs, and the content: no `CUSTOM` material, valid skin
influences, storage formats on storage textures. A failed check returns its
fault with the store and the document untouched. On success the store owns
every payload and the document is empty. Call `destroy_model_document` after
either outcome.

Inside a document, a reference to one of its entries is a typed id holding
the entry index plus one at generation zero; no pool ever issues generation
zero, so a reference never resolves in a store. The zero id means none, as
everywhere else. Publish maps each reference to the id the store issued; the
builtin texture and sampler ids, which a converter may put in a material slot,
pass through unchanged.

An application can build a document by hand: `create_model_document` with a
`ModelDocumentBounds`, then `push_sampler`, `push_texture`, `push_material`,
`push_geometry`, `push_skeleton` and `push_clip`, each of which returns the
reference to use in later entries and in the template. A bound is the most
entries of that kind the document will hold. Every entry array is allocated at
its bound up front, a push past a bound is a programming error, and unused
capacity costs one entry record.

| Function | Fault | Meaning |
| --- | --- | --- |
| `decode_model`, `decode_model_memory` | `ASSET_IO_ERROR`, `ASSET_FORMAT_ERROR`, `UNSUPPORTED` | As for the loaders above. |
| | `INVALID_ARGUMENT` | An image file has zero bytes. |
| `publish_document` | `INVALID_ARGUMENT` | A document or entry key is in the store, two entries share a key, a material is `CUSTOM`, a geometry has invalid skin influences, a storage texture has a non-storage format, or a template reference is unset, outside the document's entries or a dead store record. |
| | `CAPACITY_EXCEEDED` | A pool has fewer free slots than the document has entries of that kind; the model pool needs one. |

## Background loading

```c3
AsyncLoader loader = loader::create_async_loader(mem, &assets)!;
defer loader::destroy_async_loader(&loader);
LoadId request = loader.request({
    .path    = "models/city.gltf",
    .format  = ModelFormat.GLTF,
    .options = asset::LOAD_OPTIONS_DEFAULT,
})!;

// every frame, before update_world
loader.publish();
LoadStatus status = loader.status(request);
if (status.phase == LoadPhase.PUBLISHED) {
    // upload over frames; instantiate when prepare_progress reads READY (see Views, Budgeted preparation)
    prepare = renderer.begin_prepare_model(status.model)!;
    loader.release(request)!;
} else if (status.phase == LoadPhase.FAILED) {
    io::eprintfn("%s failed: %s", "models/city.gltf", status.failure);
    loader.release(request)!;
}
```

`c3d::asset::loader` decodes model files on one worker thread while the
application keeps rendering. `request` queues a file with its importer
(`ModelFormat.GLTF` or `FBX`) and options; the worker runs that importer's
`decode_model` into a `ModelDocument`, one request at a time, in request order.
`publish` inserts every decoded document into the store with
`publish_document`, in request order, and returns how many requests it moved to
`PUBLISHED` or `FAILED`; a decode that fails on the worker is in no count, so
read `status` for every request. `release` frees a finished request's slot; a
`QUEUED`, `DECODING` or `DECODED` request cannot be released, and there is no
cancellation.

One thread owns the loader: `request`, `status`, `publish`, `release` and
`destroy_async_loader` are called from the same thread, which is also the only
thread that writes the store. That thread may keep calling `load_model`,
`decode_model` and `publish_document` while the worker decodes.

The worker allocates every document from the store's allocator and its
temporary pool from the loader's allocator, so both must be safe to use from
another thread. The heap allocator `mem` qualifies. A `TrackingAllocator`
qualifies because its `acquire`, `resize` and `release` take its own lock in
c3c 0.8.3, although the standard library's comment above the struct says
otherwise; read its `allocated()` only after the loader is destroyed. An arena
does not qualify (it has no lock), and neither does `tmem`, which belongs to
one thread. The worker's temporary pool starts at 256 KiB and grows through the
loader's allocator for larger files; `decode_model`'s rule against `tmem`
holds on the worker too, where `tmem` is the worker's own pool.

`request` checks, in order: the path is a model key already in the store
(`INVALID_ARGUMENT`), a queued, decoding or decoded request has the same path
(`INVALID_ARGUMENT`), every slot holds an unreleased request
(`CAPACITY_EXCEEDED`). Paths are compared byte for byte, as store keys are, so
two spellings of one file are two keys. A request for a path that ended
`FAILED` is accepted again. A key inserted into the store after the request
makes that request fail at `publish` with the store's `INVALID_ARGUMENT`; a
pool without room fails it with `CAPACITY_EXCEEDED`; the store is unchanged in
both cases.

Set `LoadRequest.replace` to a live model to replace it instead of adding one. The path must equal that model's key
(`INVALID_ARGUMENT`), and a dead target faults `INVALID_ID` at `request`. The worker decodes as for an add; `publish`
calls `replace_document` on the owner thread, so a structural change ends the request `FAILED` with
`INCOMPATIBLE_STRUCTURE` and the old content stays. A target removed after the request ends it `FAILED` with `INVALID_ID`.
`LoadStatus.model` is the replaced id and `LoadStatus.report` holds the counts. `LoadRequest.missing` is borrowed until
the request reaches `PUBLISHED` or `FAILED`, and only `publish` writes it; `release` requires a final phase, so the
borrow ends there in every case.

`status` never faults. A released, stale or zero id reports `FAILED` with
`failure == INVALID_ID`; a failed decode reports `FAILED` with the importer's
fault; the `failure` field is what separates them.

Memory: every unreleased slot can hold one decoded document until `publish`
takes it, and the capacity (8 by default) bounds requests, not bytes. A decoded
Sponza is 297,688,067 bytes, 285,212,736 of them texture pixels; eight waiting
documents of that size hold about 2.4 GB. Call `publish` every frame to keep
one or two at most.

Cost: a `publish` call costs the sum over the documents that waited, each by
its key count, not its bytes: pixels and vertex streams move by pointer. On the
WSL host CPU, Sponza's 199 keys publish in 0.43 ms and decode in 1.3 to 1.7 s.
`prepare_model` after publish is synchronous and uploads every texture and
geometry of the model before it returns: 3.9 s for Sponza on WSL with llvmpipe,
a stall of the frame that calls it. `begin_prepare_model` spreads the same work
over frames under a byte budget ([Views](views.md#budgeted-preparation)).

`destroy_async_loader` stops the worker and waits for the decode in progress,
up to one decode (1.3 s for Sponza on the WSL host CPU), then frees every
unpublished document and request. Destroy the loader before its store.

| Function | Fault | Meaning |
| --- | --- | --- |
| `create_async_loader` | `thread::INIT_FAILED` | The mutex, the condition variable or the worker thread could not be created; nothing is left allocated. |
| `request` | `INVALID_ARGUMENT` | The path is a model key in the store, or a queued, decoding or decoded request has the same path. |
| | `CAPACITY_EXCEEDED` | Every slot holds an unreleased request. |
| | `INVALID_ID`, `INVALID_ARGUMENT` | A replace target that is not a live model, or whose key differs from the path. |
| `release` | `INVALID_ID` | The id was released, is stale, or never named a request. |
| `status` (`failure` of `FAILED`) | `INVALID_ID` | As for `release`. |
| | `ASSET_IO_ERROR`, `ASSET_FORMAT_ERROR`, `UNSUPPORTED`, `INVALID_ARGUMENT` | The importer's decode fault; the wrong importer for a file gives `ASSET_FORMAT_ERROR`. |
| | `INVALID_ARGUMENT`, `CAPACITY_EXCEEDED` | The store's `publish_document` fault: a key inserted since the request, a pool without room. |
| | `INCOMPATIBLE_STRUCTURE`, `INVALID_ID` | A replacement the signature refuses, or whose target was removed after the request. |

## CPU release

Templates hold only ids, names and transforms. Releasing a geometry's CPU
arrays with `release_geometry_cpu` after the renderer uploaded it does not
affect instantiation, which copies nothing from the geometry.

## FBX import

```c3
ModelId hero = fbx::load_model(&assets, "characters/hero.fbx")!;
Node* first = model::instantiate(&assets, &scene, hero)!;
```

`fbx::load_model(assets, path, options)` converts an FBX file into the same
store assets and `ModelTemplate` as glTF, and takes the same `LoadOptions`.
ufbx loads the file with right-handed Y-up axes, meters and
`MODIFY_GEOMETRY` space conversion: vertices, node translations and baked
translation keys arrive in meters, authored node scales are kept, and a
centimeter Mixamo file ends at scale one. Cameras and lights are converted to
look along -Z.

| Asset | Key |
| --- | --- |
| Model template | `<path>` |
| Material part `j` of mesh `m` | `<path>#mesh/<m>/<j>` |
| Material `i` | `<path>#material/<i>` |
| Default material for parts without one | `<path>#material/default` |
| Texture `t` decoded as sRGB color or linear data | `<path>#image/<t>/srgb`, `<path>#image/<t>/linear` |
| Packed roughness `r` and metalness `m` | `<path>#image/<r>+<m>/metallic_roughness` |
| Base color `b` with opacity `o` | `<path>#image/<b>+<o>/srgb` |
| Sampler for mixed wrap modes | `<path>#sampler/repeat_clamp`, `<path>#sampler/clamp_repeat` |
| Skin deformer `s` | `<path>#skeleton/<s>` |
| Animation stack `k` | `<path>#anim/<k>` |

Indices are ufbx typed ids; an absent source in a packed key is `-`.

**Nodes.** Template nodes are the file's nodes depth first below the root. A
node with a mesh gains one child per non-empty material part, named
`<node name>/part/<j>`, before its authored children; the child's local
transform is the node's geometry transform, which FBX applies to the mesh and
not to the node's children.

**Geometry.** Faces are triangulated and corners with identical attributes
merged. Streams: positions, normals (generated when absent), UV sets 0 and 1,
the first color set, authored tangents when both tangents and bitangents
exist, joints and weights. UV v is flipped, because FBX places the UV origin
at the bottom left and c3d decodes images top row first; the authored tangent
handedness follows the flip. Tangents are otherwise generated as for glTF.

**Materials.** Every material becomes `STANDARD` from ufbx's PBR maps, which
ufbx also derives for Lambert and Phong materials. A property connected to a
texture takes its value from the texture; the base and emission factors still
multiply. Opacity below one or an opacity texture selects blending. Base
color, emissive, normal and occlusion textures map directly. Separate
roughness and metalness textures are packed into one metallic-roughness map
(roughness in green, metalness in blue), and an opacity texture is multiplied
into a copy of the base color's alpha; sources of different sizes are resampled
to the larger. Texture bytes come from embedded content, then the relative
path next to the file, then the absolute path.

**Skins.** Each skin deformer becomes a skeleton in cluster order, with the
bone's local transform as rest pose and ufbx's geometry-to-bone matrix as
inverse bind. Vertices keep their four largest weights, renormalized. When a
skinned mesh has vertices without weights, the skeleton gains one last joint
bound to the mesh part itself with an identity inverse bind, so those vertices
follow the mesh rigidly.

**Blend shapes.** Every blend channel becomes a `MorphChannel` and each of its
keyframe shapes a `MorphTarget`, so in-between shapes deform as authored
([Animation](animation.md)). Default morph weights are the channels' weights.

**Animation.** Each animation stack is baked at the file frame rate from time
zero into one clip: linear translation, rotation and scale tracks per animated
node, and one morph-weight track per part child of a mesh with animated
channels, holding every channel's weight per key.

**Animation files.** `fbx::load_animations(allocator, assets, path, model,
options)` loads a file that carries animation for another model, such as a
Mixamo animation downloaded without skin: the file is parsed and baked without
inserting anything of its own, each stack is rebound onto the model's template
nodes by name through `c3d::anim::retarget` ([Animation](animation.md)), and
the clips are stored under `<path>#anim/<k>#<model key>#<keep|strip_xz|extract>`
so one file can serve several characters and root-motion modes. The returned
ids live in the caller's allocator. A dead model id is `INVALID_ID`; an
unmatched animated node is `ASSET_FORMAT_ERROR` unless `allow_partial`.

Unsupported: texture UV transforms (`UNSUPPORTED`), UV set selection by name
(textures use UV set 0), a mesh with more than one skin deformer
(`UNSUPPORTED`), dual-quaternion skinning (imported as linear), area and
volume lights (skipped), NURBS, constraints and geometry caches. A texture
that has neither embedded content nor a readable file fails with
`ASSET_IO_ERROR`; any other ufbx load failure, a non-finite material value or
invalid in-between weights fail with `ASSET_FORMAT_ERROR`. Rollback on a fault
matches glTF.

## Example

```bash
python3 scripts/build.py --example gltf_viewer
./examples/build/gltf_viewer path/to/model.glb --gpu-timings
```

`streaming` renders a small scene while a glTF or GLB file decodes on the loader's
worker (`./examples/build/streaming path/to/model.gltf`, the bundled BoxTextured
by default; FBX paths end `FAILED` with `ASSET_FORMAT_ERROR` because the example
requests the glTF importer). The panel shows the phase and failure, and the example
prints the decode time, the `publish` call and its frame, and the `prepare_model`
call and its frame.

`gltf_viewer` loads the argument path, or the bundled
[BoxTextured](../examples/assets/gltf/README.md) sample, instantiates it twice
side by side under a studio environment and one directional light, and spins
the right instance. It prints the template's node, mesh, camera, light,
skeleton, skin and clip counts on load; the bundled `RiggedSimple.glb` and
`AnimatedMorphCube.glb` exercise the skin and morph paths. Drag to orbit, scroll to zoom, release Escape to quit.
The Camera panel, or `F`, switches to a free camera that starts from the orbit pose:
right-drag looks, `W A S D` move along the view, `Q`/`E` move down and up, Shift is
four times faster, and the wheel scales the speed. `--benchmark` runs the headless
scene benchmark instead; see [Benchmarking](benchmarking.md#scene-benchmark).
Imported cameras and lights are instantiated, but the example renders through
its own orbit camera. The Textures panel sets the texture budget and shows the
resident bytes, raises, evictions, bias and starved count, with one row per
texture: extent, resident and total mips, resident KiB, required mip, last used
frame, and whether it is streamed or pinned. `--texture-budget <MiB>` (or
`--texture-budget=<MiB>`) starts the viewer, and the benchmark, under a budget; zero or
absent leaves textures unbudgeted. See
[Residency and memory budgets](textures.md#residency-and-memory-budgets).
