# glTF source inspection

`c3d::asset::gltf` offers `decode_model_with_source` and `decode_model_memory_with_source` for tools that need source
metadata alongside a `ModelDocument`: independent encoded images, source indices, original sampler values and extension
names. The ordinary decoders build no source record. An exporter or converter uses it to write what the source
file contained; an application that only loads models does not need it.

## Quick start

```c3
import c3d::asset;
import c3d::asset::gltf;

gltf::SourceRecord source;
ModelDocument document = gltf::decode_model_with_source(assets.allocator, "models/helmet.glb", &source)!;
defer asset::destroy_model_document(&document);
defer gltf::destroy_source_record(&source);

foreach (image : source.images) {
    // image.encoded holds the original bytes; image.declared_mime_type holds the declaration.
}
```

Both entry points decode the input once through cgltf. `decode_model_memory_with_source` takes the same bytes, base
directory and key as `decode_model_memory`, and both take optional `LoadOptions`, `SourceDiagnostic*` and `FileSource`
arguments.

## Concepts

### Two owners

The returned document and the `SourceRecord` are separate owners using the requested allocator. The record is assigned
only on success; a failure releases both temporary owners and leaves it unchanged. Destroying or publishing the document
does not invalidate the record, and destroying the record does not invalidate the document. Call `destroy_source_record`
once. All record arrays and strings are observational borrows until destruction: do not edit or free them individually.

### Diagnostics

`SourceDiagnostic` is optional. Both of its indices reset to `NO_SOURCE_INDEX` at entry and stay there on success. A
metadata mismatch reports the source material and texture indices when known; other failures may report neither.

### Index spaces

| `SourceRecord` field | Index and contents |
| --- | --- |
| `images` | Source image order; encoded bytes and declared MIME type. |
| `samplers` | Source sampler order; original glTF integer filter and wrap values. |
| `textures` | Source texture order; source image and sampler, decoded sRGB and linear IDs, and extension names. |
| `materials` | Source material order; name, extension names, referenced source textures. |
| `texture_images` | Decoded document texture order; source image index. |
| `template_nodes` | Source node order; decoded template index. |
| `extensions_required` | The document's required-extension names. |

Absent source image or sampler indices use `NO_SOURCE_INDEX`. Source nodes outside the imported scene use
`NO_TEMPLATE_NODE`. A decoded texture variant that does not exist uses the zero `TextureId`. Decoded IDs keep document
references (index plus one, generation zero) even after the document is published, so they are not live store IDs.

### Encoded images

Only decoded images retain bytes. An unused image has an empty encoding slice and is not loaded for inspection. The sRGB
and linear variants share one copied encoding. Buffer-view bytes, decoded data-URI bytes and external-file bytes are
copied without re-encoding, using the importer's file resolver.

`declared_mime_type` copies the explicit image declaration or data-URI media type and is empty when absent. It does not
identify or validate the actual encoding and may disagree with the bytes: an exporter inspects the encoded bytes before
choosing its MIME type.

### Extension names

Material and texture extension names come from a pass over the retained JSON, because cgltf discards texture-info
extensions. The pass checks material and texture array counts and each recognized texture-info slot and index against
cgltf, and it never resolves resources or decodes asset values. A material's list also includes extensions on its
recognized texture-info objects. Lists are deduplicated and sorted lexicographically; referenced source texture indices are
deduplicated and sorted numerically. `SUPPORTED_MATERIAL_EXTENSIONS` is the shared list of material and texture-transform
extensions the decoder represents; inspection reports unknown optional names without accepting their semantics.

## Material and sampler fidelity

The document owns decoded material factors, colors, alpha mode and cutoff, double-sided state, normal scale, occlusion
strength, effective UV set indices, texture transforms and texture and sampler assignments. Effective UV indices include
`KHR_texture_transform.texCoord` overrides. Physical material thickness is in the source mesh's length units; attenuation
distance is in world meters. The mapping to c3d materials is in [Models](models.md#materials).

Sampler descriptions in the document hold decoded behavior. The source record also keeps the original filter values,
including unspecified filters (zero) and the distinction between mipmapped and non-mipmapped minification.

To map a material slot back to a source texture, pick the lowest index in the material's `textures` whose image matches
the slot's decoded texture (through `texture_images`) and whose `SourceSampler` decodes to the slot's sampler. Compare
sampler values, not document sampler identity. This handles several source textures sharing one image and keeps each
slot's decoded behavior. Equivalent candidates can lose the distinction between an explicit filter and an unspecified
filter when both decode identically: decoded equality is preserved, not the original JSON spelling.

The record's sRGB and linear handles describe ordinary color variants. Normal and masked-coverage variants resolve through
the decoded material slots and `texture_images`, which keep their source image identity. All variants of one image share
its copied encoded bytes.

## Faults

`decode_model_with_source` and `decode_model_memory_with_source` fault `ASSET_IO_ERROR`, `ASSET_FORMAT_ERROR`,
`UNSUPPORTED`, `INVALID_ARGUMENT` and `CAPACITY_EXCEEDED`, as the ordinary decoders do ([Models](models.md#faults)). A
metadata mismatch between the retained JSON and cgltf is an `ASSET_FORMAT_ERROR`. The diagnostic names the material or
texture for a per-entry mismatch; a count mismatch, a missing array or an unparsable document leaves both indices at
`NO_SOURCE_INDEX`. The allocator must not be `tmem`; the file entry point needs a nonempty path and the memory entry point
nonempty bytes and key.

## Limits

- glTF only; FBX has no source record.
- Encoded bytes are copied for every decoded image, so a record holds a second copy of each image file's content.
- The declared MIME type is not validated.

## See also

- [Models](models.md) for import and material mapping.
- [Asset loading](asset_loading.md) for publishing the document.
- [Fracture](fracture.md) for a consumer of independent encoded images.
