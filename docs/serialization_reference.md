# Serialization reference

Entry points, options, codec and described-value APIs, the container layout, the JSONC profile, component policies and faults of `c3d_serial` (module `c3d::serial`). The [serialization guide](serialization.md) explains the model and the common tasks.

## Entry points

| Function | Returns | Faults |
| --- | --- | --- |
| `write_subtree(allocator, scene, assets, root, options = {})` | `char[]` owned by `allocator` | `INVALID_ID`, `INVALID_ARGUMENT`, `UNSUPPORTED`, `CAPACITY_EXCEEDED` |
| `read_subtree(scene, assets, bytes, parent = null, options = READ_OPTIONS_DEFAULT)` | The restored root `Node*` | `ASSET_FORMAT_ERROR`, `UNSUPPORTED`, `INVALID_ID`, `CAPACITY_EXCEEDED` |
| `write_subtree_text(allocator, scene, assets, root, options = TEXT_WRITE_OPTIONS_DEFAULT)` | `String` owned by `allocator` | `INVALID_ID`, `INVALID_ARGUMENT`, `UNSUPPORTED`, `CAPACITY_EXCEEDED`, `describe::MISSING_DESCRIPTION` |
| `read_subtree_text(scene, assets, text, parent = null, options = READ_OPTIONS_DEFAULT)` | The restored root `Node*` | `ASSET_FORMAT_ERROR`, `UNSUPPORTED`, `INVALID_ID`, `INVALID_ARGUMENT`, `CAPACITY_EXCEEDED` |
| `write_schema(allocator, limits = TEXT_LIMITS_DEFAULT)` | `String` owned by `allocator` | `INVALID_ARGUMENT`, `UNSUPPORTED`, `CAPACITY_EXCEEDED`, `describe::MISSING_DESCRIPTION` |
| `read_header(bytes)` | `SubtreeHeader` of a binary document | `ASSET_FORMAT_ERROR`, `UNSUPPORTED` |
| `register_core_codecs()` | Registers every built-in component policy and its prerequisites | `describe::DESCRIPTION_CONFLICT`, `describe::MISSING_DESCRIPTION`, `INVALID_ARGUMENT`, `UNSUPPORTED`, `CAPACITY_EXCEEDED` |
| `register_core_value_types()` | Registers the shared value types (transform, bounds, sway, fade, LOD, billboard, node reference) | `describe::DESCRIPTION_CONFLICT`, `describe::MISSING_DESCRIPTION`, `INVALID_ARGUMENT` |
| `is_serializable(Type)` | Whether the type has an authored or transient policy | none |

Rules shared by the calls:

- `write_*` require the root to be live in the source scene. `read_*` require `parent` to be null or live in the destination scene with current world matrices.
- The write, read and schema calls use `tmem` scratch and need an enclosing `@pool()`. They never open an inner pool.
- The scene and the store stay fixed while a call runs. A read never modifies the store.
- Registration calls run during single-threaded setup. Repeating a registration adds no slot and keeps the same policy.

## Options and diagnostics

| Type | Field | Meaning |
| --- | --- | --- |
| `ReadOptions` | `allocator` | Reader-owned acquisitions and the allocator passed to codecs. Defaults to the destination scene allocator |
| | `limits` | `TextLimits` for text reads. Binary reads ignore it |
| | `diagnostic` | `SerialDiagnostic*` that retains failure details |
| | `skip_unknown` | Text reads skip unknown fields and components. Binary reads ignore it |
| `WriteOptions` | `diagnostic` | `SerialDiagnostic*` that retains failure details |
| `TextWriteOptions` | `limits` | `TextLimits` for the output |
| | `diagnostic` | `SerialDiagnostic*` that retains failure details |
| | `omit_binary_only` | Omit binary-only components instead of failing. Requires `omissions` |
| | `omissions` | Initialized `OmissionReport*` |
| `TextLimits` | `max_bytes` | Document size; default 64 MiB |
| | `max_string_bytes` | One raw quoted string, quotes and escapes included; default 1 MiB |
| | `max_number_bytes` | One number token; default 128 |
| | `max_depth` | Nested objects and arrays; default and ceiling `TEXT_MAX_DEPTH` (64) |

The defaults are `READ_OPTIONS_DEFAULT`, `TEXT_WRITE_OPTIONS_DEFAULT` and `TEXT_LIMITS_DEFAULT`. A struct literal that leaves `limits` zero is invalid for the text calls. Each byte limit must be positive and at most `uint::max`, and `max_depth` must be in `1..TEXT_MAX_DEPTH`. Invalid limits fault `INVALID_ARGUMENT` before parsing.

`SerialDiagnostic` fields:

| Field | Meaning |
| --- | --- |
| `cause` | The fault that ended the call |
| `node_path` | `/nodes/<record>` of the failing record |
| `type_name` | Portable component name |
| `asset_key` | Key of the failing asset reference |
| `model_key`, `template_index`, `has_template_index` | Model and first differing template node of an `INCOMPATIBLE_TEMPLATE` fault |
| `bone_index`, `has_bone_index` | Failing ragdoll bone |
| `pointer`, `byte_offset`, `line`, `byte_column`, `has_text_position` | JSON Pointer and source position of a text fault |

`create_serial_diagnostic(allocator)` returns an empty diagnostic without allocating. Each call clears the previous details. The diagnostic owns its strings until the next call or `destroy_serial_diagnostic`, and its details survive the reader's rollback. Binary diagnostics carry no text position. A failed diagnostic allocation returns `CAPACITY_EXCEEDED` and clears the incomplete details. JSON Pointers escape `~` and `/`. Byte offsets are zero-based; lines and byte columns are one-based.

`create_omission_report(allocator)` returns an empty report. `OmissionReport.components` holds one `OmittedComponent` (`node_path`, `type_name`) per omission. The report owns its strings until the next export or `destroy_omission_report`.

## Container format

Version 1 is the only container version. Fields are written one at a time; native struct padding and endianness never reach the stream. Scalars are little-endian.

Header, 24 bytes of six `u32` values: magic `0x53443343` (the bytes `C3DS`), version, `byte_count`, `node_count`, `key_count`, `chunk_count`. `byte_count` must equal the blob length and `node_count` must be nonzero. A larger version faults `UNSUPPORTED`.

Chunk table, 12 bytes per entry of three `u32` values: kind, offset from the blob start, size. The table holds at most `MAX_CHUNKS` (64) entries; a larger count faults `ASSET_FORMAT_ERROR` before the table is scanned. The required kinds are `KEYS` = 0, `TYPES` = 1, `NODES` = 2 and `COMPONENTS` = 3, each exactly once. Chunks must fit the blob, start after the table and not overlap. Unknown kinds with a valid range are skipped. Empty chunks can share an offset.

| Chunk | Contents |
| --- | --- |
| `KEYS` | `key_count` unique, nonempty asset keys, as strings |
| `TYPES` | A `u32` count, then (name string, version `u32`) pairs. The writer sorts names lexicographically |
| `NODES` | One record per node, parents before children, in depth-first insertion order |
| `COMPONENTS` | A `u32` group count, then one group per type: `type_index` `u32`, `count` `u32`, and `count` entries of (node record `u32`, payload size `u32`, payload bytes) |

A `NODES` record holds the parent record (`INDEX_NONE` only for record zero), three reserved `u32` fields (`INDEX_NONE`), a template-signature length (zero) with its bytes, the name string, the transform, the transform space (`u32`), the layers (`u32`) and the visible flag (one byte). Nonzero reserved fields fault `UNSUPPORTED`; a nonzero signature length faults `ASSET_FORMAT_ERROR`. An ordinary record takes at least 73 bytes. Model mappings and signatures live in the `ModelInstance` payload, not in the node record.

Each type group appears once, and each (node, type) pair appears once. A group has at least one entry. A payload may be empty. A type absent from the destination scene's stores faults `UNSUPPORTED`. A name no codec registers faults `UNSUPPORTED`, even when the type has only a transient policy. A stored version above the codec's version faults `UNSUPPORTED`. Payload framing keeps a decoder inside its own payload.

The writer discovers keys in traversal order and emits one group per used codec. The header limits a document to `uint::max` bytes; a larger output faults `CAPACITY_EXCEEDED`.

## Codec API

### Component codecs

`register_codec(Type, ComponentCodec)` binds a type to a manual codec. `register_transient(Type, collect = null)` marks it transient.

| `ComponentCodec` field | Meaning |
| --- | --- |
| `name` | Unique portable name with static lifetime and valid UTF-8 |
| `version` | Current payload version; positive |
| `phase` | `RestorePhase`: `VALUE`, `REFERENCES`, `OWNER` or `BINDINGS` |
| `collect` | Optional `CollectFn`; runs once per component before record numbering |
| `write` | Required `WriteFn`; runs twice per component, to measure and to fill |
| `read` | Required `ReadFn`; receives exactly one bounded payload |

- Registering a type again replaces its policy. A name that another type already holds faults `INVALID_ARGUMENT` and leaves the existing entry.
- `write` must emit identical bytes for the same fixed scene state. It writes field-wise values and uses the context helpers for references.
- `read` attaches its component to `context.node` through the owner API or hook. It consumes the whole payload, retains no pointer into the blob or the context, and frees allocations it has not transferred when it fails. It can attach explicitly owned authoring, but it cannot create, reparent or remove nodes, change the store or touch unrelated scene state.
- `collect` may reject, claim generated state and project authored state through `WriteContext` (below). Claims affect scratch only. Duplicate or conflicting projections and owner claims fault `INVALID_ARGUMENT`.
- A transient collector may only reject. It makes no ownership claims. Repeating the same collector is idempotent; a different collector for an already transient type faults `INVALID_ARGUMENT`. A transient type never writes a component record.
- Omitting a component does not omit its node. An omitted generated node needs all its non-transient components claimed, and so does every omitted descendant. A saved reference to an omitted node faults `INVALID_ARGUMENT`.

### WriteContext

| Method | Purpose |
| --- | --- |
| `omit_node(node)` | Exclude a generated node. Its components must be claimed |
| `omit_component(node, slot)` | Exclude a component the current owner reconstructs |
| `contains_node(node)` | Whether the original selection includes the node, before omissions |
| `project_component(node, value)` | Write a substitute through the component's ordinary codec. Borrowed data must outlive the export |
| `project_absent_component(node, value)` | Re-emit an authored component a prepared owner moved off a retained node |
| `set_local(node, local)` | Project a retained node's authored local transform |
| `set_transform(node, local, transform_space)` | Project the transform and its space together |
| `write_node(writer, node)`, `write_entity(writer, entity)` | Encode a same-subtree reference. Null and the zero entity encode `INDEX_NONE` |
| `write_geometry`, `write_material`, `write_texture`, `write_sampler`, `write_model`, `write_clip`, `write_skeleton`, `write_environment`, `write_shader`, `write_compute_shader` | Encode an asset id as its key |
| `write_custom(writer, Type, id)` | Encode a custom asset id as its key |
| `make_node_reference(node, required, missing)`, `make_entity_reference(entity, required, missing)` | Capture a `NodeReference` |

`omit_node`, `omit_component`, `contains_node`, `project_component`, `project_absent_component`, `set_local` and `set_transform` run only inside `collect`. `write_node` and `write_entity` run only inside `write`.

### ReadContext

| Member | Purpose |
| --- | --- |
| `scene`, `assets`, `allocator`, `diagnostic`, `node`, `version` | Destination, reader allocator, current node and the stored payload version |
| `read_node(reader)`, `read_entity(reader)` | Resolve a same-subtree reference |
| `read_geometry`, `read_material`, `read_texture`, `read_sampler`, `read_model`, `read_clip`, `read_skeleton`, `read_environment`, `read_shader`, `read_compute_shader` | Resolve a key to an asset id. A key of another kind faults `INVALID_ID` |
| `read_custom(reader, Type)` | Resolve a key of a registered custom kind |
| `resolve_node_reference(reference, required, missing)` | Resolve a `NodeReference` against the preflighted model mappings |
| `has_component(Type)` | Whether the document restores that type on the current node |
| `authored(Component, Authoring, node)` | Borrow another component's decoded authoring before attachment |
| `read_value(Type, reader)` | Decode a registered described value inside a compatibility reader |

A missing custom-kind registration faults `INVALID_ID` for a nonzero reference. A zero reference needs no pool. Borrowed values from `authored` and `read_value` live until the subtree read ends; validate and copy retained data before returning.

### Writer and Reader

| Type | Methods |
| --- | --- |
| `Writer` | `write_uint`, `write_int`, `write_ulong`, `write_float`, `write_bool`, `write_string`, `write_enum`, `write_vec2`, `write_vec3`, `write_vec4`, `write_quat`, `write_mat4`, `write_transform`, `write_aabb`, `write_bytes`, `written`, `finish` |
| `Reader` | `read_uint`, `read_int`, `read_ulong`, `read_float`, `read_bool`, `read_string`, `read_enum`, `read_vec2`, `read_vec3`, `read_vec4`, `read_quat`, `read_mat4`, `read_transform`, `read_aabb`, `read_bytes`, `remaining` |

Encodings: floats keep their IEEE binary32 bits. A bool is exactly 0 or 1. A string is a `u32` byte length followed by valid UTF-8 with no terminator; embedded zero bytes stay content. An enum is its `u32` ordinal and must stay stable for each shipped codec version. A quaternion is x, y, z, w. A matrix is its columns in order. A transform is position, rotation, scale. A box is min, max. Reader string and byte helpers return borrowed views; codecs copy persistent values. `Writer.finish` reports a size overflow; the writer's capacity is a programming contract after the measuring pass.

## Described values

A described type pins a field layout and a single source of semantic defaults. Binary, JSONC and the schema all derive from it.

| Function | Purpose |
| --- | --- |
| `register_described_type($Type, version, layout, defaults)` | Pin a registered description to a version, a layout fingerprint and a `DefaultsFn` |
| `register_described($Type, DescribedCodec)` | Bind a component to its own registered described type |
| `register_described_owner($Component, $Authoring, DescribedCodec)` | Bind a component through a separate authoring type. `project` and `attach` are required |
| `description_layout(descriptor)` | Compute the fingerprint to commit |
| `described_type($Type)` | Borrow a type's policy; faults `UNSUPPORTED` when unregistered |

The layout is an FNV-1a fingerprint of the schema events: field names, kinds, sizes, extents, enum labels and asset kinds. The root label is `value`, independent of the C3 type name. A missing `defaults` or a mismatched pin faults `INVALID_ARGUMENT`. Repeating a registration is idempotent; a conflicting version, layout or defaults faults `INVALID_ARGUMENT`. A changed layout needs a new committed version and pin before it registers. `DefaultsFn` initializes every field without allocating; strings and slices may borrow immutable process-lifetime storage. `register_core_value_types()` registers the shared value types.

| `DescribedCodec` field | Meaning |
| --- | --- |
| `name` | Portable name; unique, valid UTF-8 |
| `phase` | Restore phase; default `VALUE` |
| `collect` | Optional `CollectFn` |
| `project` | `ProjectFn`: borrows the authored value from a live component. Default copies the component |
| `validate` | Optional `ValidateFn`: checks decoded dependencies after node and reference resolution, before any component attaches |
| `attach` | `AttachFn`: copies the value into the component. Default adds the value; types with strings or slices must supply one |
| `binary_compatibility` | `BinaryCompatibility` entries, one per older version a reader supports |
| `text_default_versions` | Older versions whose JSONC documents read absent fields as semantic defaults |

A `BinaryCompatibility` entry holds a `version` below the current one, a `read` callback and an optional `upgrade`. A current payload needs its complete pinned layout and never fills a truncated field from a default. An older binary version reads only through its listed entry; other versions fault `UNSUPPORTED`. `ReadContext.authored` faults `UNSUPPORTED` for an older payload without an `upgrade`, so an owner that other owners inspect before attachment supplies one. `upgrade` decodes the older payload into the current authoring type, and `read` reuses it. Mesh, InstancedMesh, LodGroup and PhysicsBody supply one for every older version, so a Cloth or an Animator preflight sees the current value whatever version was stored.

Binary encoding: a described value emits every field, with no default elision, as little-endian integers, raw floating-point bits, portable references and length-delimited struct, array and slice payloads. Struct payloads carry their version and layout fingerprint. Native pointers and padding never enter the payload. Reader-owned strings and slices use fallible, aligned acquisitions that release on success and on every fault.

Binding: attachment copies retained strings and slices into the component's ordinary ownership and removal hooks. A failed attachment leaves the component absent. Duplicate portable names fault `INVALID_ARGUMENT`. Validators run once per document, and unvalidated components restore sequentially, so a later failure still rolls back earlier owners.

## Text profile

### Document shape

A document is one JSON object with comments allowed.

```json
{
  "version": 1,
  "nodes": [
    {
      "id": 0,
      "parent": null,
      "name": "cell",
      "local": { "position": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1] },
      "transform_space": "PARENT",
      "layers": 1,
      "visible": true,
      "components": {
        "app.Spinner": { "version": 1, "value": { "turns_per_second": 0.5, "axis": 2 } }
      }
    }
  ]
}
```

The reader accepts line and block comments and rejects trailing commas, duplicate object keys and trailing input. Embedded documents use a caller-extracted source span; diagnostics are relative to that span, and the reader still requires exactly one document.

### Numbers and strings

- Finite floats and doubles print with `%.9g` and `%.17g`: after rounding to nine or seventeen significant digits, exponent form is used when the decimal exponent is below -4 or at least the precision, and fixed form otherwise. Trailing fractional zeros and a bare decimal point are removed. Negative zero prints as `-0.0`.
- A finite value parses directly from its lexeme into the destination width.
- Non-finite values use a quoted `f32:` plus eight lowercase hex digits, or `f64:` plus sixteen. Finite-bit tokens and mismatched widths fault.
- Wide signed and unsigned integers use quoted decimal strings with no leading zeros and no negative zero; zero is exactly `"0"`. Narrower integers are numeric tokens with no fraction or exponent.
- Owner numeric domains apply after the representation parses.

### Export

`write_subtree_text` emits deterministic records, parent before child, with document-local ids, every authored node field and every non-transient described component field. A used binary-only component faults `UNSUPPORTED` with its node path and type name, unless `omit_binary_only` lists it in the `OmissionReport`. Diagnostics and reports clear before each call, including a failed call. Mixed text and binary-only exports restore every retained component and omit only the report entries.

### Import

- Node ids form a complete zero-based range. Records may appear in any order. Names may be empty or repeated and are not reference identities.
- The document needs one root, live in-document parent references and an acyclic connected graph. The reader checks this before it creates nodes.
- The reader creates siblings in ascending document id. Scene linking prepends each child, so the sibling list reads in descending id order, as it does for canonical binary records.
- A node restores local or world transform mode, layers and authored visibility under the requested live parent.
- Described components decode before validation, then attach in their restore phases. Validators borrow another component's decoded authoring through `ReadContext.authored`.
- The field reader initializes semantic defaults, copies default strings and slices into reader-owned storage, then overlays the fields present. Absent nested values keep parent overrides; new slice elements take their own type defaults. Completion hooks run only for entered values, children before parents. Writing and default cloning never run them.
- Fixed arrays, vectors, quaternions and matrices need their exact element counts. Unknown fields and components fault unless `skip_unknown` is set; skipped values still need valid syntax.
- Only versions a codec lists in `text_default_versions` read with defaults. Other older text versions fault.
- A failed import removes the new subtree. A supplied diagnostic keeps the JSON Pointer, source position, node record path and component name.

## Schema export

`write_schema(allocator, limits)` writes the process registry as owned JSON. `components` is sorted by portable name with each entry's version, a `binary_only` flag and its described `type`. Manual codecs carry `binary_only: true` and no fields. `types` is sorted by qualified name and lists versions, layout pins, field kinds and sizes, nested fields, array extents, enum labels, asset kinds, display names, units, numeric ranges and complete semantic defaults.

Defaults come from the same callbacks as text import. The export never runs completion hooks. Output is deterministic for the same registry, obeys the text limits and faults `CAPACITY_EXCEEDED` when the output allocation fails.

## Faults

| Fault | Meaning |
| --- | --- |
| `ASSET_FORMAT_ERROR` | Malformed header, chunks, records or counts; duplicate entries; invalid bool, enum or UTF-8; truncation; bad reference index; unconsumed payload; a document naming more than 128 types |
| `UNSUPPORTED` | Container or type version, unknown name, codec or destination store unavailable; binary-only codec in text export; a component with no policy |
| `INCOMPATIBLE_TEMPLATE` | A referenced model differs from the saved structural signature |
| `INVALID_ID` | Missing or wrong-kind asset reference, including a dead source asset |
| `INVALID_ARGUMENT` | Unkeyed source asset; node reference outside the subtree, to an omitted node or to another scene; conflicting owner claims or codec name; invalid text limits |
| `CAPACITY_EXCEEDED` | Authored nodes do not fit, the output or a count exceeds the format, or a fallible allocation fails |

`INCOMPATIBLE_TEMPLATE` is `c3d::serial::INCOMPATIBLE_TEMPLATE`; the others are `c3d` faults. Owner codecs add their declared faults, and a codec classifies invalid stored descriptors before it calls an owner API with programming preconditions. Retained diagnostics add the JSON Pointer and source position for text and the component, node and asset or model details when known.

## Component policies

### Versions and older payloads

Every built-in authored component, with its portable name, current version and restore phase. "Older payloads" lists the older versions that read and what their absent fields read as. `none` means no older version exists. Binary and JSONC read the same older versions unless the row says otherwise.

| Component | Name | Version | Phase | Older payloads |
| --- | --- | --- | --- | --- |
| `Mesh` | `c3d.Mesh` | 3 | `VALUE` | 1, 2: `trace_facing` reads `MATERIAL`. 1: `trace_only` reads false |
| `Camera` | `c3d.Camera` | 1 | `VALUE` | none |
| `Light` | `c3d.Light` | 3 | `VALUE` | 1, 2: `source_radius` and `source_angle` read 0. 1: `volumetric` reads true |
| `ProbeVolume` | `c3d.ProbeVolume` | 1 | `VALUE` | none |
| `Atmosphere` | `c3d.Atmosphere` | 1 | `VALUE` | none |
| `HeightFog` | `c3d.HeightFog` | 1 | `VALUE` | none |
| `ReflectionProbe` | `c3d.ReflectionProbe` | 1 | `VALUE` | none |
| `Decal` | `c3d.Decal` | 1 | `VALUE` | none |
| `CloudLayer` | `c3d.CloudLayer` | 1 | `VALUE` | none |
| `MediumVolume` | `c3d.MediumVolume` | 1 | `VALUE` | none |
| `InstancedMesh` | `c3d.InstancedMesh` | 4 | `VALUE` | 1: no quadtree (empty parents, `split_pixels` and `hysteresis` 0). 1, 2: `trace_sway` reads false. 1-3: `metric` reads `SPHERE_PIXELS`, with no `levels` and `morph_band` 0 |
| `BillboardBatch` | `c3d.BillboardBatch` | 2 | `VALUE` | 1: `atlas` reads off and every `frame` 0 |
| `RibbonBatch` | `c3d.RibbonBatch` | 1 | `VALUE` | none |
| `LodGroup` | `c3d.LodGroup` | 3 | `BINDINGS` | 1, 2: `trace_sway` reads false. 1: reads as a rigid group |
| `ModelInstance` | `c3d.ModelInstance` | 1 | `REFERENCES` | none |
| `SkinBinding` | `c3d.SkinBinding` | 1 | `REFERENCES` | none |
| `IkChain` | `c3d.IkChain` | 1 | `REFERENCES` | none |
| `FootIk` | `c3d.FootIk` | 2 | `REFERENCES` | 1: plant timing and sole axes read `FOOT_PLANT_DEFAULT` |
| `LookAt` | `c3d.LookAt` | 1 | `REFERENCES` | none |
| `Animator` | `c3d.Animator` | 3 | `OWNER` | 1: boolean masks, 1D spaces and `DIFFERENCE` additive scale. 1, 2: generalized root extraction off and `inertia_enabled` false |
| `AnimatedCrowd` | `c3d.AnimatedCrowd` | 4 | `OWNER` | 1: no per-instance playback and the default action and event capacities. 1, 2: boolean masks, 1D spaces and `DIFFERENCE`. 1-3: generalized root extraction off and `inertia_enabled` false |
| `PhysicsBody` | `physics_body` | 3 | `VALUE` | 2: no height-field neighbour maps. 1: no neighbour maps and a zero window |
| `PhysicsJoint` | `physics_joint` | 1 | `REFERENCES` | none |
| `Wind` | `wind` | 1 | `VALUE` | none |
| `Force` | `force` | 1 | `VALUE` | none |
| `Buoyancy` | `buoyancy` | 2 | `VALUE` | 1: `drag_coefficient` reads 0 |
| `Cloth` | `cloth` | 9 | `OWNER` | JSONC 1-8: absent fields read their `default_cloth_desc()` values. Binary older than 9 faults `UNSUPPORTED` |
| `CrowdCloth` | `crowd_cloth` | 4 | `BINDINGS` | JSONC 1-3: absent fields read zero or empty. Binary older than 4 faults `UNSUPPORTED` |
| `Ragdoll` | `ragdoll` | 1 | `OWNER` | none |
| `Breakable` | `breakable` | 2 | `OWNER` | 1: recipe kind `LEGACY_CURRENT_POSE` |
| `HeightFieldWindows` | `height_field_windows` | 2 | `OWNER` | 1: no neighbour maps |
| `NavSource` | `nav_source` | 1 | `REFERENCES` | none |
| `NavVolume` | `nav_volume` | 1 | `REFERENCES` | none |
| `NavLink` | `nav_link` | 1 | `REFERENCES` | none |
| `NavObstacle` | `nav_obstacle` | 1 | `REFERENCES` | none |
| `NavAgent` | `nav_agent` | 1 | `REFERENCES` | none |
| `Character` | `character` | 1 | `REFERENCES` | none |
| `NavDriven` | `nav_driven` | 1 | `OWNER` | none |
| `Terrain` | `terrain` | 4 | `VALUE` | 1: `slope_projection` reads `TOP`, `triplanar_sharpness` its default. 1-2: `morph_band` 0. 1-3: `trace` off |
| `TerrainSet` | `terrain_set` | 1 | `VALUE` | none |
| `TerrainTile` | `terrain_tile` | 1 | `VALUE` | none |
| `Foliage` | `foliage` | 3 | `OWNER` | 1: `rules.slope_normal` reads `FACE`. 1, 2: `trace_sway` off |
| `Water` | `water` | 5 | `OWNER` | 1: one mirror slot, view texture slot 0. 1, 2: `trace` off. 1-3: a `BODY` with `DEFAULT_WATER_DEPTH`. 1-4: `GERSTNER` with the default `simulation` and `spectrum` and no `ground` |
| `ParticleSystem` | `particle_system` | 9 | `VALUE` | 1: `saturation` reads `REFUSE`. 1, 2: no sub-emitters. 1-3: `collision` response `NONE`. 1-4: `flipbook` off. 1-5: `turbulence` off. 1-6: `trail` off. 1-7: `mesh_cast_shadow` and `mesh_trace` false. 1-8: `execution` reads `CPU` |
| `AudioEmitter` | `audio_emitter` | 1 | `VALUE` | none |
| `AudioListener` | `audio_listener` | 1 | `VALUE` | none |

The package inventory tests fail when a registered component has no classified policy, so this table covers every authored type.

### Transient components

A transient component is never written. Its package installs the policy, and some are private ownership markers.

| Owner | Transient components |
| --- | --- |
| Physics | `RigidBody`, `Joint`, `ClothOutput`, `HeightFieldWindowOwner` |
| Navigation | `NavSourceRuntime`, `NavVolumeRuntime`, `NavLinkRuntime`, `NavObstacleRuntime`, `CrowdAgentRuntime` |
| Landscape | `TerrainRuntime`, `FoliageRuntime`, `FoliageCellOwner`, `WaterRuntime`, `WaterMirror` |
| Particles | `ParticleDrawOwner` |
| Audio | `AudioVoiceLink` |

### Core values and batches

- `Mesh`, `Camera`, `Light`, `ProbeVolume`, `Atmosphere`, `HeightFog`, `ReflectionProbe`, `Decal`, `CloudLayer` and `MediumVolume` restore in `VALUE`. `Mesh` copies its morph weights into scene ownership. `Decal`'s material and `CloudLayer`'s `coverage` are asset references.
- `ProbeVolume`, `Atmosphere`, `HeightFog`, `ReflectionProbe`, `CloudLayer` and `MediumVolume` apply their owner validity predicates on export and on decoded authoring before attachment. A `Light` with a negative or non-finite extent, or an angle of `PI / 2` or more, faults `INVALID_ARGUMENT` on read and write.
- `InstancedMesh`, `BillboardBatch` and `RibbonBatch` keep their capacity and live entries in copied storage. Unused entries restart at identity transforms, white colors, `BILLBOARD_DEFAULT` and `RIBBON_POINT_DEFAULT`. Bounds caches and revisions restart.
- `InstancedMesh` keeps flags, sway, fade, bounds overrides and its quadtree: instance parents, `split_pixels`, `hysteresis`, `metric`, `morph_band` and the `levels` of a `BOX_RANGES` batch. A read attaches the batch, then calls `Scene.set_instance_quadtree` and `Scene.set_quadtree_ranges`; their faults propagate and remove the batch. Mismatched parents, a bad `split_pixels` or `hysteresis`, a traced batch, a mirrored instance, a `BOX_RANGES` payload without parents or levels, and levels or a band under `SPHERE_PIXELS` fail the read. Writing such a batch faults `INVALID_ARGUMENT`.
- `BillboardBatch` and `RibbonBatch` apply the rules of `Scene.set_billboard_atlas`, `Scene.set_billboards` and `Scene.set_ribbons` on read and write. A broken layout, a non-finite value, a negative `frame` or `width`, or an unknown flag bit faults `INVALID_ARGUMENT`.
- Writing a batch whose records the scene does not own faults `UNSUPPORTED`: an `InstanceSource` other than `TRANSFORMS`, a `BillboardSource` other than `BILLBOARDS`, a `RibbonSource` other than `POINTS`. Those records live in a renderer buffer or an owner regenerates them, as the particle package does.
- `LodGroup` restores in `BINDINGS`, after its source owners. Rigid groups keep ordered affine parts, levels, capacities, live placements, common effects and terminal impostors. Animated groups keep the source-owner reference, levels, logical part indices, geometry and material keys, template skins, morph defaults, optional bounds and common effects; a read uses the template skin and ignores the stored one. `AnimatedCrowd` owns crowd capacity, placement, colors and pose envelope. The binding rebuilds through ordinary atomic admission after `ModelInstance` or a pending `AnimatedCrowd` attaches. A read prepares no crowd, samples no pose and creates no GPU resource. Binding maps, revisions, group identity, bounds caches and renderer selection state restart.

### Models, rigs and animation

- `ModelInstance` keeps the model key, per-template-node signatures and mappings, absent slots, base poses, mesh slots, baseline morph arrays and clips. The reader validates signatures and unique node claims before any component attaches, then copies the owner arrays onto the saved graph. It does not instantiate the template or recreate removed nodes; application children and transform overrides remain. A selected template node needs its model owner in the subtree. A differing template (any ordered mesh or skin slot of a template node) faults `INCOMPATIBLE_TEMPLATE` with the model key and first differing index.
- `SkinBinding`, `IkChain`, `FootIk` and `LookAt` resolve their joints and targets before any component attaches. A `NodeReference` names a document node, or a model owner plus a template index, so a removed model slot cannot bind to a reused scene slot. Ordinary node references capture the current live entity, including retargeting after slot reuse. Skin joints alone keep the captured template identity: deleting a required template joint rejects export even when its address is reused. Foot contact state, anchors, support frames, phases and clocks restart.
- `Animator` restores in `OWNER`, after `ModelInstance` and the reference components. It keeps clips, speed, weight, layer, loop and playing flags, additive and scale mode, boolean and weighted masks, root-motion mode, root extraction, 1D and 2D space configuration and the inertia flag. Action times, space phases, events and fades restart. Export projects owned transforms and `Mesh` morph weights to the captured baselines without changing the source scene; the instance root keeps its current placement. Active fades settle at their targets, fading-out actions and spaces are omitted, and handles are newly allocated. An absent configured root slot keeps its mode and contributes zero root motion.
- `AnimatedCrowd` restores in `OWNER` as a pending crowd with no generated part nodes. It keeps the model, capacity, live placements and colors, action and event capacities, seed settings, pose bounds, trace flag, each instance's configured actions, masks and spaces, and the inertia flag. Pending and prepared crowds write the same authoring. Export omits fading-out actions and settles incoming fades without changing the live crowd. A retained standalone base action restarts at its captured start; other clocks restart. Explicitly empty playback stays empty. Sampled clocks, handles, root deltas, fired events, counters, palettes and cursors are not saved. Exporting a generated part without its owner, or adding authored components to an omitted part, faults `INVALID_ARGUMENT`. `prepare_crowd` builds the runtime; a failed preparation keeps the authoring for a retry.

### Physics

Select `c3d_physics` and `C3D_PHYSICS_SERIAL`, and call `physics::register_serial_codecs()` beside `physics::register_physics(scene)`. A read creates no native body; ordinary physics synchronization creates native state.

- `PhysicsBody` keeps `BodyDesc` and all nested collider authoring, including a height field's window and its four neighbour maps with their cell materials. It restores `PENDING` with cleared failure and revision state. A `Ragdoll` or `Breakable` that inspects an older body reads it through the body's `upgrade`.
- `HeightFieldWindows` keeps `{ window_cells, collider }`. Export omits the window nodes and their bodies after validating each node's transient `HeightFieldWindowOwner`; a load regenerates them through `add_height_field_windows`.
- `PhysicsJoint` needs a model-aware endpoint and keeps only its selected variant. `Wind`, `Force` and `Buoyancy` keep their complete values; `Buoyancy` resets the submerged fraction.
- `Cloth` and `CrowdCloth` keep the complete `ClothDesc` settings, including pin order and duplicates, seams, collider references, attachments, bend settings, cuts, tear limits, sleep thresholds and wind coefficients. Rest and hold state is runtime-only, so a restored cloth starts awake. Export projects `Mesh` records to the retained source geometry and vertex motion without changing the source scene. A prepared skinned `Cloth` projects its source `Mesh` with `project_absent_component` and omits its generated output child; a prepared `CrowdCloth` omits its per-slot output children. `ClothOutput`'s collector rejects a generated output child exported without its owner. A read keeps the `Mesh` and attaches a pending owner with no geometry, cut or solve state. Synchronize physics bodies before cloth preparation.
- `Ragdoll` restores after the model, skin, body and joint authoring. It keeps bone mappings, parents, bind frames, modes, per-bone weights and drives, the aggregate weight, the drive strength and current node placements. Weights and drive strength must be finite and nonnegative on export and import. Preflight checks references and mode, body and joint consistency before any component attaches; diagnostics carry the bone index. Body velocities persist; bone-body velocities restart at zero. Active recovery saves `SIMULATED` bone modes with `DYNAMIC` body authoring and completed recovery saves `ANIMATED` modes with `KINEMATIC` authoring. Recovery settings, captured sources and targets, observations, native identities and completion markers never reach the payload.
- `Breakable` attaches pending through the public attachment path, with no world, cooked hulls or native bodies and joints. `prepare_breakable` and `prepare_breakable_subtree` create the runtime; a failed preparation keeps the recipe for a retry. `LEGACY_CURRENT_POSE` captures root-relative frames from the current pose and projects `WORLD` piece transforms to `PARENT`; preparation regenerates contact adjacency, so touching survivors can weld again. `AUTHORED_REST` comes from an explicit `BreakableRecipeDesc` and saves rest frames, internal and anchor edges, axes, strengths and the evaluation mode; a load calls `Scene.attach_breakable_recipe`, and preparation builds an intact representation with zero velocities. Native ids, damage, measured reactions and velocities are excluded.
  - Survivors keep their relative order. Export omits edges to deleted pieces and anchors to deleted targets, then remaps piece indices. Fewer than two portable survivors faults `UNSUPPORTED`.
  - Every live anchor target must lie in the subtree with ordinary `STATIC` body authoring; otherwise export faults `INVALID_ARGUMENT`. Only verified owned bodies are omitted. Modified or unrelated bodies, conflicting owners and joints are rejected.

### Navigation and character

- Select `c3d_nav` and `C3D_NAV_SERIAL`, and call `nav::register_serial_codecs()` beside `nav::register_nav(scene)`. `NavSource`, `NavVolume`, `NavLink`, `NavObstacle` and `NavAgent` keep their complete settings, target kind and value, and driven flag. Changed flags restart false. A `NavSource` with no explicit geometry needs the node's restored `Mesh`. A read builds no navmesh, builder or crowd; `nav_sync` and `crowd_update` rebuild the runtime mirrors.
- Select `c3d_character` with `C3D_CHARACTER_SERIAL` and `C3D_PHYSICS_SERIAL`, and call `character::register_serial_codecs()`. The adapter reuses the physics value registrations. `Character` keeps its full descriptor and capsule state at the saved node pose. Velocity, movement intent, contact, jump and plane state restart. Optional push-body authoring copies fallibly and stays pending until physics synchronization; only the verified generated body is omitted.
- With `C3D_CHARACTER_NAV`, also select `c3d_nav` and `C3D_NAV_SERIAL`. The character registration then includes the navigation codecs and the `NavDriven` marker. `NavDriven` requires `Character` and `NavAgent`, resets traversal and applies `add_nav_driven` after both restore.

### Landscape

Select `c3d_landscape` and `C3D_LANDSCAPE_SERIAL`, and call `landscape::register_serial_codecs()`. Terrain restores its complete descriptor in `VALUE`, and `Water` and `Foliage` restore in `OWNER`, so a `ground` reference already carries `Terrain`. No read creates a material, batch, cell or mirror.

- `TerrainSet` and `TerrainTile` keep their authored fields; the set's neighbour links are runtime state, rebuilt when the tiles prepare.
- `Foliage` keeps its ground reference and copied scatter, sway, fade, render and optional LOD authoring. Prepare terrain before foliage, and publish world matrices before dependent preparation.
- A `Water` `ground` is a node reference to a `Terrain` node in the exported subtree; otherwise the write faults. An ocean's generated `InstancedMesh` is omitted like a body's `Mesh`, and a prepared body's medium node with its `MediumVolume` is omitted; preparation adds it again from the descriptor.
- Foliage cells, water mirrors and a terrain's trace grid are omitted only after their ownership checks out.

### Particles

Select `c3d_particle` and `C3D_PARTICLE_SERIAL`, and call `particle::register_serial_codecs()`. `ParticleSystem` keeps its descriptor and emitting flag in `VALUE`. Sub-emitter targets are same-subtree entity references. Pools, event queues, random state, counters and the draw child restart through `particle::prepare`. The collision callback is runtime-only. A generated draw or trail child selected without its owner is rejected.

### Audio

Select `c3d_audio` and `C3D_AUDIO_SERIAL`, and call `audio::register_serial_codecs()`. `AudioEmitter` and `AudioListener` are described components. The emitter saves its clip by key, bus index, volume, pitch, distances, looping and playing flag. The bus index is the entry of the reading system's `AudioDesc.buses`; a bus past that table fails the voice start and counts in `AudioStats.start_failures`. Playback position is not saved: a loaded playing emitter starts from the clip's beginning at the next `AudioSystem.update`. The reading store must register the clip kind and hold a clip under the saved key.

## Authored numeric domains

Each owner validates its numeric domain on export and import, for binary IEEE values and JSONC float-bit tokens alike. An invalid value faults `INVALID_ARGUMENT` with the component type and node path. `AnimatedCrowd` validates on import only; its runtime contracts keep exported seeds and actions in domain. Generic described floats, node transforms, crowd placements and colors keep IEEE fidelity, including non-finite values. The runtime validators that govern the `add_*` calls also govern serialization.

| Owner | Fields | Domain |
| --- | --- | --- |
| Wind | `velocity` components, `drag`, `lift`, `max_speed` | Finite; no added range restriction |
| Force | `force` and `local_point` components | Finite; no added range restriction |
| Buoyancy | `fluid_density`, `linear_drag`, `drag_coefficient` | Finite; no added range restriction |
| PhysicsBody | BodyDesc `linear_velocity` and `angular_velocity` components, `linear_damping`, `angular_damping`, `gravity_scale` | Finite; no added range restriction |
| Animator | Action `speed`; 1D and 2D blend-space coordinates, parameter and `speed` | Finite; negative speeds allowed |
| Animator | Action and blend-space `weight` | Finite and nonnegative; no upper cap |
| Animator, AnimatedCrowd | Weighted mask node values | Finite and in `[0,1]`; full captured node width |
| AnimatedCrowd | Pose `speed` and `time` | Finite; negative values allowed |
| Ragdoll | Aggregate `weight`, each `bone_weights` value, `drive_strength` | Finite and nonnegative; no upper cap |
| NavVolume | BOX `box`; CONVEX `verts[:vert_count]`, `min_y`, `max_y`; CYLINDER `base`, `radius`, `height` | Finite active fields; `min_y <= max_y`; cylinder radius and height positive |
| NavLink | `start`, `end`, `radius` | Finite; positive radius and distinct endpoints |
| NavObstacle | CYLINDER `position`, `radius`, `height`; BOX `box`; ORIENTED_BOX `position`, `half_extents` | Finite active fields; positive cylinder dimensions and oriented half-extents; nonnegative box extents |
| NavAgent | Params `radius`, `height`, `max_acceleration`, `max_speed`, `collision_query_range`, `path_optimization_range`, `separation_weight` | Finite; radius and max speed nonnegative; height positive |
| NavAgent | `target` when `target_kind == POSITION` | Finite; NONE and VELOCITY keep IEEE fidelity |

Navigation's shared predicates govern the `add_nav_*` calls and both serialization paths. The void target setters keep their contracts; serialization validates POSITION targets before it writes or attaches authoring. Inactive shape fields and unused convex vertices keep IEEE fidelity.

## See also

- [Serialization guide](serialization.md)
- [Owner readiness](owner_readiness.md)
- [Type descriptions](type_descriptions.md)
