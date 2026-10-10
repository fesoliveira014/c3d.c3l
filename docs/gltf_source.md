# glTF source inspection

`c3d::asset::gltf` offers `decode_model_with_source` and
`decode_model_memory_with_source` for tools that need source metadata alongside a
`ModelDocument`. Ordinary decode keeps its existing behavior and allocations.

Both entry points decode the same input once through cgltf. Source inspection
re-reads extension names from cgltf's retained JSON because cgltf discards
texture-info extensions; remove this metadata pass if a future pinned parser
retains them. The pass checks material/texture array counts and each recognized
texture-info slot and index against cgltf. It never resolves resources or
decodes asset values. The file entry point does not read the document twice.

The returned document and `SourceRecord` are separate owners using the requested
allocator. The output record is assigned only on success; failure releases both
temporary owners and leaves it unchanged. Destroying or publishing the document
does not invalidate the record. Destroying the record does not invalidate the
document. Call `destroy_source_record` once for its ownership. All record arrays
and strings are observational borrows until destruction; do not edit or free
them individually.

`SourceDiagnostic` is optional. Both indices reset to `NO_SOURCE_INDEX` at entry
and remain there on success. A metadata mismatch reports the source material
and texture indices when known; other failures may have neither index.

## Indices and retained data

| Record field | Index and contents |
|---|---|
| `images` | Source image order; encoded bytes and declared MIME type |
| `samplers` | Source sampler order; original glTF integer filter/wrap values |
| `textures` | Source texture order; source image/sampler pair and decoded sRGB/linear IDs |
| `materials` | Source material order; name, extension names, referenced source textures |
| `texture_images` | Decoded document texture order; source image index |
| `template_nodes` | Source node order; decoded template index |
| `extensions_required` | Source document required-extension names |

Absent source image/sampler indices use `NO_SOURCE_INDEX`. Source nodes outside
the imported scene use `NO_TEMPLATE_NODE`. A decoded texture variant that does
not exist uses the zero `TextureId`. Decoded IDs retain document references
(index plus one, generation zero), even after the document is published; they
are not live store IDs.

Only decoded images retain bytes. An unused image has an empty encoding slice
and is not loaded for inspection. sRGB and linear variants share one copied
encoding. Buffer-view bytes, decoded data-URI bytes and external-file bytes are
copied without re-encoding, using the existing importer resolver.

`declared_mime_type` copies the explicit image declaration or data-URI media type
and is empty when absent. It does not identify or validate the actual encoding.
An exporter must inspect supported encoded bytes before selecting its MIME
type. The declaration may disagree with those bytes.

Material and texture extension names come from the metadata pass. A material's
list also includes extensions on its recognized texture-info objects. Lists
are deduplicated and sorted lexicographically. Referenced source texture indices
are deduplicated and sorted numerically. `SUPPORTED_MATERIAL_EXTENSIONS` is the
shared list of material/texture-transform extensions represented by the decoder;
inspection reports unknown optional names without accepting their semantics.

## Material fidelity

The document owns decoded material factors, colors, alpha mode/cutoff,
double-sided state, normal scale, occlusion strength, effective UV set indices,
texture transforms and texture/sampler assignments. Effective UV indices include
`KHR_texture_transform.texCoord` overrides. Physical material thickness is in
the source mesh's length units; attenuation distance is in world meters.
Sampler descriptions contain decoded behavior; the source record additionally
preserves original filter values, including unspecified filters (zero) and the
distinction between mipmapped and non-mipmapped minification.

A material slot resolves to the lowest referenced source texture index whose
image matches the decoded texture and whose sampler decodes to the slot's
sampler. Compare sampler values, not document sampler identity. This handles
several source textures sharing one image and keeps each slot's decoded behavior.
Equivalent candidates may lose the distinction between an explicit filter and
an unspecified filter when both decode identically. The contract preserves
decoded equality rather than original JSON spelling.

The source record's sRGB and linear handles describe ordinary color variants.
Normal and masked-coverage variants resolve through the decoded material slots
and `texture_images`, which retain their source image identity. All variants of
one image share its copied encoded source bytes.
