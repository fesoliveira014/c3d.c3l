# Asset loading

Every model loader is a decode followed by a publish. `c3d::asset::gltf` and `c3d::asset::fbx` decode a file into a
store-free `ModelDocument`; `AssetStore.publish_document` inserts it into a store; `replace_document` replaces a live model
from a document; and `c3d::asset::loader` runs the decode on a worker thread. This page covers those steps. Importing and
instantiating a model is in [Models](models.md), and ids, keys and file sources are in [Asset store](assets.md).

## Quick start

Decode and publish in two steps, for a tool that edits the document in between:

```c3
ModelDocument document = gltf::decode_model(assets.allocator, "models/helmet.glb")!;
defer asset::destroy_model_document(&document);
ModelId helmet = assets.publish_document(&document)!;
```

Load in the background and publish on the owner thread:

```c3
import c3d::asset::loader;

AsyncLoader loader = loader::create_async_loader(mem, &assets)!;
defer loader::destroy_async_loader(&loader);
LoadId request = loader.request({
    .path = "models/city.gltf",
    .format = ModelFormat.GLTF,
    .options = asset::LOAD_OPTIONS_DEFAULT,
})!;

// Each frame, on the owner thread:
PublishReport publication = loader.publish_within({ .items = 1024 });
LoadStatus status = loader.status(request);
if (status.phase == LoadPhase.PUBLISHED) {
    prepare = renderer.begin_prepare_model(status.model)!;
    loader.release(request)!;
} else if (status.phase == LoadPhase.FAILED) {
    io::eprintfn("Model loading failed: %s", status.failure);
    loader.release(request)!;
} else if (status.phase == LoadPhase.CANCELLED) {
    loader.release(request)!;
}
```

Handle a terminal result once, then stop querying its released ID. `prepare` is the `PrepareId` the application holds;
instantiate the model when its preparation reaches `READY` ([Budgeted preparation](views.md#budgeted-preparation)).

## Decode and publish

`gltf::decode_model`, `gltf::decode_model_memory` and `fbx::decode_model` read the file into a `ModelDocument` and touch
no store, scene or renderer. The allocator owns everything in the document. It must be the allocator of the store the
document is published into, and never `tmem`, because the decoder opens a temporary pool of its own.

`AssetStore.publish_document` inserts the document's samplers, textures, materials, geometries, skeletons and clips, then
its template as a model under the document key. Before the first insertion it checks:

- every key against the store and against the other keys of the document;
- the free slots of every pool the document needs;
- the content: no `CUSTOM` material, valid skin influences, valid clip events and storage formats on storage textures.

A failed check returns its fault with the store and the document untouched. On success the store owns every payload and the
document is empty. Call `destroy_model_document` after either outcome.

Inside a document, a reference to one of its entries is a typed ID holding the entry index plus one at generation zero. No
pool ever issues generation zero, so a reference never resolves in a store. The zero ID means none, as everywhere else.
Publish maps each reference to the ID the store issued; the built-in texture and sampler IDs, which a converter may put
in a material slot, pass through unchanged.

An application can build a document by hand: `create_model_document(allocator, key, bounds)` with a
`ModelDocumentBounds`, then `push_sampler`, `push_texture`, `push_material`, `push_geometry`, `push_skeleton` and
`push_clip`. Each push returns the reference to use in later entries and in the template. A bound is the most entries of
that kind the document holds. Every entry array is allocated at its bound up front, a push past a bound is a programming
error and unused capacity costs one entry record.

| Function | Fault | Meaning |
| --- | --- | --- |
| `decode_model`, `decode_model_memory` | `ASSET_IO_ERROR`, `ASSET_FORMAT_ERROR`, `UNSUPPORTED` | As for the loaders in [Models](models.md#faults). |
| | `INVALID_ARGUMENT` | An image file has zero bytes. |
| `publish_document` | `INVALID_ARGUMENT` | A document or entry key is in the store, two entries share a key, a material is `CUSTOM`, a geometry has invalid skin influences, a clip has invalid or unsorted events, a storage texture has a non-storage format, or a template reference is unset, outside the document's entries or a dead store record. |
| | `CAPACITY_EXCEEDED` | A pool has fewer free slots than the document has entries of that kind; the model pool needs one. |
| | `UNSUPPORTED` | A texture entry has no source data. |
| | `ASSET_DATA_UNAVAILABLE` | A texture entry with an alpha-coverage policy has no pixels. |

Ordinary public `ModelDocument` values stay editable. `publish_document` and `replace_document` validate and prepare the
document presented to each call, so edits after decoding cannot reuse stale derived data.

## Replace a model

```c3
ModelReplaceReport report = gltf::replace_model(&assets, model, "models/city.gltf", missing: missing[..])!;
```

`replace_document(model, &document, missing)` replaces a live model and its keyed parts from a decoded document.
`gltf::replace_model` and `fbx::replace_model` decode a file and call it; `gltf::replace_model_memory` mirrors
`load_model_memory`. The document key must equal the model's key (`INVALID_ARGUMENT` otherwise), and every entry key must
be nonempty and unique.

Each entry key is one of:

- a match: a live record of the same kind under that key. It is replaced in place by the kind's replace call, keeps its
  ID and advances its revision once;
- an addition: a key absent from the store. It is added as in `publish_document`;
- a conflict: a key held by another kind, a built-in texture or sampler, or the model itself (`INVALID_ARGUMENT`).

References inside the document and its template are remapped to the matched and added IDs before each entry is replaced.
A template reference that is unset, outside the document's entries or a dead store record faults `INVALID_ARGUMENT`, as in
`publish_document`. The check phase decides every fault, so a fault leaves the store and the document as they were; on
success the document is emptied.

A replacement faults with `INCOMPATIBLE_STRUCTURE` when a matched geometry, texture, skeleton or clip breaks the structural
rules of its kind ([Replacing geometry, skeletons and clips](assets.md#replacing-geometry-skeletons-and-clips)), a matched
clip changes its name, or the new template differs in its structural signature from the current one. The signature is:

- the node count and each node's parent;
- the mesh list in order: node, geometry, material;
- the skin list in order: mesh node, skeleton, joint nodes;
- the LOD groups in order: node and the full description.

Node names, local transforms, layers, visibility, lights, cameras and the clip list may change. The serialization add-on
compares the same field set, so a file saved before a compatible replacement still loads after it. The response to
`INCOMPATIBLE_STRUCTURE` is to remove the model, add it again and instantiate again. `replace_model_owned(model, &template)`
swaps the template alone, under the same signature rule.

Existing `ModelInstance`s keep the nodes, base pose, morph baselines, lights, cameras and clip list they were created with.
They show the new meshes, textures and clips because their IDs are unchanged. Instances created afterwards use the new
template. Prepared crowds keep their captured node and morph layout, while compatible clips allocate their own cursors at
play or seed replacement. The number of tracks is not limited by the template's original clip list.

Missing parts are records whose key is `<model key>#<suffix>`, where the suffix contains no further `#`, that the document
does not name. This is the importers' sub-asset form (`#mesh`, `#material`, `#image`, `#sampler`, `#skeleton`, `#anim`).
Derived records, such as the clips `fbx::load_animations` keys `<animation path>#anim/<i>#<model key>#<mode>`, are never
reported. `ModelReplaceReport` holds `replaced`, `added` and `missing`: `missing` counts them all, and the optional
`missing` slice receives the first `missing.len`, ordered by `AssetKind`, then by key bytes. The store keeps them, as
`remove_model` does; removing one is the application's call.

Call replacements from the owner thread, outside frame recording.

## Background loading

`c3d::asset::loader` decodes files on one worker thread. The worker also validates store-independent content and builds
geometry shape, skin bounds and morph bounds before the request becomes `DECODED`. It never reads or writes the live
store, scene or renderer. Publication checks current keys, capacities, references and replacement structure on the owner
thread, then transfers the private prepared payloads without rebuilding their derived data.

`create_async_loader(allocator, assets, capacity = 0)` starts the worker. `capacity` is the number of request slots; zero
selects `DEFAULT_LOAD_CAPACITY` (8). Slots bound requests, not payload bytes: a decoded slot can retain a complete document
until publication or cancellation. `destroy_async_loader` stops new selection, joins the current decode and disposes every
unpublished request. Destroy it before the store; shutdown and active abandonment can wait for a source or parser call to
finish.

| `LoadRequest` field | Meaning |
| --- | --- |
| `path` | File to decode. Copied. |
| `format` | `ModelFormat.GLTF` or `ModelFormat.FBX`. |
| `options` | `LoadOptions`. |
| `replace` | A live `ModelId` to replace instead of adding; its key must equal `path`. |
| `missing` | Borrowed until the request is terminal; publication alone writes it, and cancellation never does. |

| `LoadPhase` | Meaning |
| --- | --- |
| `QUEUED`, `DECODING`, `DECODED` | Pending. |
| `PUBLISHED`, `FAILED`, `CANCELLED` | Terminal. |
| `CANCELLING` | Pending cancellation of a request being decoded. |

`status(id)` returns a `LoadStatus` with the `phase`, the `model`, a `failure` fault and the replacement `report`.

`publish()` is the unbounded alternative to `publish_within` and returns the number of requests that this call moved to
`PUBLISHED` or commit `FAILED`; earlier worker failures are not in that count.

### Publication allowance and reports

`PublishLimits.items` is a logical item allowance per call; zero is unbounded. Decoded documents are admitted atomically
in FIFO order. A head that cannot fit stops the call, and later smaller documents do not bypass it. An admitted commit
failure consumes its charge and leaves existing assets unchanged.

A document's charge is one item for the model and one per entry, template node, template mesh, skin joint node, LOD part,
morph target, morph channel, skeleton joint and clip track. The worker computes it while decoding. A replacement also adds
one item per store key in its model's part namespace (`<model key>#<suffix>`), which it visits to collect missing parts.
Items do not count key or name bytes and promise no CPU instruction or wall-clock limit.

| `PublishReport` field | Meaning |
| --- | --- |
| `published` | Requests this call published. |
| `failed` | Commit failures in this call, excluding earlier decode failures. |
| `items_used` | Charges of the requests this call admitted. |
| `deferred` | A decoded head could not fit. |
| `required_items` | The deferred head's charge; zero when none. |

A deferred head spends nothing. Raise the allowance to `required_items` or select unbounded publication. A depleted finite
allowance stays finite; its zero remainder does not become unbounded.

### Cancellation and request lifetime

`cancel(id)` abandons loading; it does not interrupt a parser or `FileSource` operation.

| Phase at cancellation | Result |
| --- | --- |
| `QUEUED` | Becomes terminal `CANCELLED`; no decode starts. |
| `DECODING` | Becomes pending `CANCELLING`; the worker finishes, discards its result, then acknowledges `CANCELLED`. |
| `DECODED` | The owner destroys raw and derived data before terminal `CANCELLED`. This cleanup is outside the publication allowance. |
| `PUBLISHED`, `FAILED`, `CANCELLING`, `CANCELLED` | No-op; completed results and published assets stay intact. |

A `CANCELLING` request keeps its path and slot. Pending duplicate paths are rejected, and pending requests cannot be
released. Release a terminal request explicitly; the generation advances and old status, cancel and release operations
cannot succeed against a reused slot. Releasing a request does not unload published assets. A stale or released ID faults
`INVALID_ID` on `cancel` and `release`; `status` reports `FAILED` with `failure == INVALID_ID` for stale, released or zero
IDs.

A removed replacement target fails `INVALID_ID` at publication; an incompatible replacement fails
`INCOMPATIBLE_STRUCTURE` with the old content intact. `LoadStatus.model` and `report` keep the replaced ID and counts.

### Threads and allocators

One thread calls `request`, `status`, `publish`, `publish_within`, `cancel`, `counters`, `release` and destruction. It is
the only thread that mutates the store. Both allocators (the loader's and the store's) must support concurrent worker use;
neither can be `tmem` or an unlocked arena. The worker owns its temporary pool. The `FileSource` callback runs on the
worker and keeps its [thread-safety and lifetime contract](assets.md#file-sources). Active cancellation keeps parser-owned
source bytes alive until the decoder releases them.

### Counters

`counters()` snapshots pending phase counts (`queued`, `decoding`, `decoded`, `cancelling`) and cumulative `publications`,
`decode_failures`, `commit_failures`, `cancellations`, `publication_items` and `decode_ns`. Each terminal transition
counts once. `decode_ns` is the worker's decode time in nanoseconds, including independent preparation. A publication
report contains only its current call and has no cancellation field or event cursor.

### Faults

| Function | Fault | Meaning |
| --- | --- | --- |
| `create_async_loader` | `thread::INIT_FAILED` | Mutex, condition variable or worker initialization failed; owned resources are released. |
| `request` | `INVALID_ARGUMENT` | The add path is already a model key, a pending request owns the path, or a replacement path differs from its model key. |
| | `CAPACITY_EXCEEDED` | Every slot has an unreleased request. |
| | `INVALID_ID` | The replacement model is dead. |
| `cancel`, `release` | `INVALID_ID` | Stale, released or never-issued ID. Releasing a pending request is a programming error. |
| `status` (`FAILED.failure`) | `INVALID_ID` | Stale, released or zero request ID. |
| | `ASSET_IO_ERROR`, `ASSET_FORMAT_ERROR`, `UNSUPPORTED`, `INVALID_ARGUMENT` | Worker decode or independent preparation failed. |
| | `INVALID_ARGUMENT`, `CAPACITY_EXCEEDED`, `INCOMPATIBLE_STRUCTURE`, `INVALID_ID` | Owner publication failed without changing existing assets. |

## Run the example

```bash
python3 scripts/build.py --example streaming
./examples/build/streaming path/to/model.gltf
```

`streaming` renders a small scene while a glTF or GLB file decodes on the loader's worker (the bundled BoxTextured by
default). The panel shows phases, decode time, publication items, counters and the budgeted preparation progress. Loading
can be cancelled before publication, and a deferred document stays queued until the item allowance is raised. The example
requests the glTF importer, so an FBX path ends `FAILED` with `ASSET_FORMAT_ERROR`.

## Limits

- One worker thread decodes at a time; requests publish in FIFO order.
- Cancellation never interrupts a parser or file-source call.
- Publication runs on the owner thread and is bounded only by the item allowance, which does not promise a time limit.
- A decoded slot holds a whole document until it is published or cancelled.

## See also

- [Models](models.md) for what an import creates.
- [Asset store](assets.md) for keys, capacities, file sources and replacement of single assets.
- [Views](views.md#budgeted-preparation) for budgeted GPU preparation after a publish.
- [Textures](textures.md) for texture residency.
