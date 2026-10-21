# Texture streaming

Three ways to change what the renderer holds for a texture after the first upload: upload only the edited texels of a
region, replace the texture's content under its id, and bound the device memory the store's textures use. The store side
is in `c3d::asset` and the residency side in `c3d::render`. [Textures](textures.md) covers loading and the basic
edit-and-upload cycle.

## Quick start

Mark the texels an in-place edit changed and upload:

```c3
TextureAsset* source = assets.texture(texture);
// write the new texels into source.pixels
assets.mark_texture_region_dirty(texture, 0, { .x = 8, .y = 4, .width = 16, .height = 8, .depth = 1 })!;
renderer.upload(texture)!;
```

Cap the device bytes of store textures:

```c3
RendererDesc desc = { .texture_budget_bytes = 256 << 20 };
renderer.set_texture_budget(128 << 20);   // replaces the budget; zero lifts it
```

## Editing a region

A `TextureRegion` is a texel box of one mip level. `z` and `depth` count the layers of a cube texture or the slices of a
volume; a 2D texture uses `z` 0 and `depth` 1. `width`, `height` and `depth` are positive (a contract).

- The call advances the revision once. It faults `c3d::INVALID_ID` for a dead id and `c3d::INVALID_ARGUMENT` for a mip the
  texture does not name, a box outside the mip's extent, or a texture with no texels (an empty storage texture).
- A mip-zero texture names mip 0 only, generated mips included. A texture with supplied mips names any supplied level;
  edit that level's bytes.
- `mark_texture_dirty`, a replacement and `release_texture_cpu` change or drop the source as a whole, so they empty the
  log of marks.

### Marks and uploads

Each texture keeps its last `TEXTURE_REGION_MARKS` (4) marks. When the log is full, the two oldest marks merge into their
bounding box if they share a mip, else the oldest is dropped, and a reader older than the log uploads the whole texture.
Every renderer reads the log independently. `TextureAsset.regions_since(revision, per_mip)` answers `NONE`, `REGIONS` (one
union region per mip) or `WHOLE`.

A renderer copies only the marked regions when its image is current at an earlier revision, the shape is unchanged, the
format is uncompressed and not a storage texture, the texture does not combine generated mips with `THRESHOLD` alpha
coverage, and no upload for the image waits unrecorded in the open frame. Otherwise it stages the whole texture; the mark
is still accepted and advances the revision. `Stats.upload_bytes` counts the staged texels of the boxes.

With generated mips, the renderer keeps a CPU chain of about one third of mip 0 for a region-edited texture. The first
region upload builds the whole chain at the cost of a whole upload, and later ones filter only the boxes the edit reaches.
A whole upload refilters the chain, and a replaced image or a released CPU source frees it. With supplied mips the renderer
copies each marked level's box from that level's bytes. A streamed texture copies only the levels of its resident chain.

## Replacing a texture

A replacement swaps the content of a live texture under its id and key. Every material, environment and overlay that
references the id shows the new content at its next use.

```c3
assets.replace_texture(texture, desc, pixels)!;           // copies mip-zero pixels
assets.replace_texture_owned(texture, desc, pixels)!;     // takes pixels allocated with the store allocator
assets.replace_texture_mips(texture, desc, levels)!;      // copies supplied mips
assets.replace_texture_empty(texture, desc)!;             // an empty storage texture
```

- Each form takes the inputs of its `add_texture` form and rejects the same data with `c3d::INVALID_ARGUMENT`.
  `c3d::UNSUPPORTED` and `c3d::ASSET_DATA_UNAVAILABLE` follow the add forms as well.
- The source form can change between mip zero, supplied mips and empty. Width, height, mip count and a format of the same
  sample type can change.
- `is_cube`, `storage`, `layers`, 2D versus volume (zero or positive `depth`) and whether the format is `R16_UINT` cannot
  change. A change faults `c3d::INCOMPATIBLE_STRUCTURE`. Add a new texture and update the references instead.
- A fault changes nothing. An `_owned` form takes the pixels only on success; on a fault the caller keeps them.
- `revision` advances once. `replaced_revision` takes the same value; `mark_texture_dirty` leaves it alone. Consumers that
  refresh part of a texture compare it, so they never patch replaced content as an edit.
- Call from the owner thread, outside frame recording. The renderer retires the old image after its last submitted frame.
- Built-in textures cannot be replaced (a contract).

## Residency and memory budgets

By default every texture is fully resident on its first use. A texture budget makes the renderer keep the device bytes of
store textures at or under it. `RendererDesc.texture_budget_bytes` sets it at creation and `set_texture_budget(bytes)`
replaces it between frames. Zero lifts it, and every streamed texture then rises to full residency.

### Which textures stream

- A 2D, single-layer, mipped, sampled-only texture with a CPU source streams. Generated and supplied mips qualify,
  compressed formats included.
- Cubes, arrays, volumes, storage textures, single-mip textures, empty textures and render targets stay fully resident.
- A streamed texture holds a contiguous range of mips from `resident_base` to the last level; its image has only those
  levels.
- The tail is the levels whose larger extent is at most `TEXTURE_TAIL_EXTENT` (64). Under a budget every streamed texture
  starts with its tail resident.
- Shading samples the resident image, so a texture below the detail it needs is blurry, never missing.

### Demand

Each raster view records, per material, the largest on-screen extent of the objects, batches and decals it draws with that
material, scaled by the view's material sampling bias. The next frame turns that extent into the mip each texture of the
material needs, including the Standard materials a custom material references. Shadow, trace and path-traced views
record nothing, so a path-traced view samples what raster views keep resident.

### Budget and pacing

The step runs at `begin_frame`, after retired resources are released.

- A drawn texture rises toward its needed mip when the bytes fit the budget. The first raise of a frame is exempt
  from pacing but must still fit the budget. Further raises share `TEXTURE_STREAM_FRAME_BYTES` (8 MiB) per frame, largest
  deficit first.
- A raise of a texture whose chain is generated from mip zero also costs its mip-zero texels. Further raises must keep
  the frame within `TEXTURE_REGENERATION_FRAME_TEXELS`, one 1024x1024 regeneration per frame. Supplied mips cost no
  texels and are paced by bytes alone. The first resolve of a texture under a budget still regenerates from mip zero,
  outside this pacing.
- When bytes exceed the budget, textures that were not drawn return to their tail, least recently used first.
- When the drawn set still does not fit, one global bias holds every drawn texture the same number of levels below its
  need. The bias relaxes once the set fits within 90% of the budget.
- Lifting the budget raises every streamed texture to full residency under the same pacing: the first raise of each frame,
  then 8 MiB and the regeneration-texel limit.

### Full readers

Some paths read a texture outside material sampling and need every level: environment sources, cloud-layer coverage maps,
overlay and UI images, compute dispatch reads, textures in custom-material slots (except the base-color slot of a masked
material) and toon
gradient maps. A texture used this way is a full reader. It never streams and is never evicted, and its bytes count against
the budget as fixed bytes. The flag stays set for the texture's life in that renderer, replacements included. A texture
already streamed that becomes a full reader rises to full residency at the next step.

### Keep the source

A raise re-reads the CPU source, so `release_texture_cpu` pins the texture: the step neither raises nor evicts it. Under a
budget, releasing sources after the first frames pins those textures at whatever they hold, usually their tails. Keep the
sources of textures that should stream, or release them once the detail is final.

### Memory accounting and observation

`Stats.texture_bytes` counts resident images. A raise or eviction creates a new image, copies the surviving levels on the
device and retires the old image after the frames in flight, so memory overshoots the budget briefly.

- `Renderer.texture_residency(texture)` returns the record of a store texture as this renderer holds it: `resident_base`,
  `chain_mips`, `required_base`, `last_used_frame` and the `streamed`, `full_reader` and `raisable` flags. A live texture
  the renderer has not resolved has `chain_mips == 0`. A dead id faults `c3d::INVALID_ID`.
- `Stats` reports, per frame: `texture_bytes`, `texture_raises`, `texture_evictions`, `texture_bias`, `textures_starved`
  (drawn textures below their biased target) and `texture_changes_deferred`.

### Faults

`begin_frame` reports failures while resolving or moving a texture, with the faults of `upload_texture`. A change that
cannot allocate an image or a view slot (`gpu::SLOT_TABLE_FULL`, `gpu::DESCRIPTOR_HEAP_FULL`,
`gpu::OUT_OF_DEVICE_MEMORY`) is skipped for the frame and counted in `texture_changes_deferred`. A replacement keeps its
record and restarts at the tail when the dimensions, mip count or format change; the texture rises again from its last
demand one frame later.

## Limits

- Region uploads help only uncompressed, non-storage textures without threshold coverage on generated mips; others stage
  whole.
- A reader older than the log reaches uploads the whole texture.
- Budgeting applies to store textures. Render targets, cubes, arrays, volumes and single-mip textures stay resident.
- Initial uploads of a model's textures follow [budgeted preparation](preparation.md#budgeted-preparation) and do not
  change raise pacing.
- Memory overshoots the budget briefly while retired images wait for the frames in flight.

## See also

- [Textures](textures.md) for loaders and the edit-and-upload cycle.
- [Textures reference](textures_reference.md) for supplied mips and compressed formats.
- [Preparation](preparation.md) for uploading before the first frame.
- [Asset store](assets.md) for revisions and replacement across kinds.
