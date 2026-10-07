# Portable scene subtrees

c3d_serial is a consumer-selected add-on. It imports core scene/asset APIs and the standard library. Core has no serialization import or feature flag. No read creates a GPU device, renderer resource, physics world or navigation system, and AssetStore is never modified.

## Current coverage

The container handles ordinary nodes and application-registered component codecs. Node name, local transform, transform space, layers, visibility, hierarchy and insertion order are portable. World matrices and effective visibility are derived during load, relative to a parent whose world matrix is current.

Node transform values pass through unchanged, matching direct `node.local` assignment. The container does not reject non-finite position/rotation/scale values or a zero quaternion; those values can propagate into the derived world matrix. Component codecs define and validate their own numeric constraints before invoking owner APIs. `ASSET_FORMAT_ERROR` covers invalid wire representations. Component codecs report invalid authored values through their declared owner faults; the container adds no universal float-validity rule.

`register_core_codecs()` installs described version-1 policies for Mesh, Camera,
Light, ProbeVolume, Atmosphere, HeightFog, ReflectionProbe and Decal, all in the
VALUE phase. Mesh copies its morph-weight array into ordinary Scene ownership.
The other value components use fixed-size copying attachment. ProbeVolume,
Atmosphere, HeightFog and ReflectionProbe use their existing owner validity
predicates on both export and decoded authoring before attachment.

ModelInstance and the remaining owners have no policy in this delivery and return
UNSUPPORTED. Animated Mesh baseline projection arrives with the Animator adapter;
ordinary Mesh values currently preserve their explicit weights.

Asset payloads, scene-wide ambient/background/environment settings and cross-subtree references are outside this format. Saving Scene.root creates an ordinary new node on read; it does not overwrite destination scene settings.

## Registration and callbacks

Call `serial::register_core_codecs()` during single-threaded setup to install the
supported built-in codecs. It idempotently registers both description and semantic
default prerequisites; no prior description call is required. Repeating it adds no
slots and retains the same policies. `describe::register_core_components()` alone
registers field descriptions for inspection without selecting serialization.

Register the destination's component stores and removal hooks through its owner APIs before reading. Then call serial::register_codec(Type, codec) or register_transient(Type) during single-threaded setup. Codec registration assigns a process slot without allocating any Scene store. `ecs::assigned_slot(Type)` queries that zero-based slot without assigning one and returns `NOT_FOUND` when absent. The shared ECS limit is 128 component types ([components](scene.md#components)); a file naming more fails `ASSET_FORMAT_ERROR`.

ComponentCodec contains a static-lifetime name, positive version, RestorePhase and collect/write/read callbacks. Names must be unique across types. Registering a type again replaces its policy; a conflicting name fails without replacing the existing entry. Neither registration order nor C3 module/type names enter the stream.

- collect is optional. It runs once before record numbering and declares owner-generated nodes/components through omit_node and omit_component. set_local supplies a captured authored transform. Claims affect scratch only; the source scene is unchanged. Conflicting owners/transform overrides fail INVALID_ARGUMENT.
- write runs twice, for measuring and filling. It must emit identical bytes against the same fixed scene state. It writes field-wise values and uses context helpers for references.
- read receives exactly one bounded payload and attaches its registered component to context.node through the owner API/hook. It must consume the entire payload, retain no blob/context pointers, and free allocations not yet transferred if it fails. It may attach explicitly owned authoring components, but cannot create/reparent/remove nodes, mutate AssetStore or change unrelated scene state.

RestorePhase.VALUE runs before REFERENCES, then OWNER. Every node exists before these phases. The application owns codec dependencies; this is not a scheduler. ReadContext.has_component(Type) reports whether the file independently restores that type on the current node, so an owner can reject conflicting stored components before invoking a no-duplicate owner API.

Omitting a component does not omit its node. An omitted generated node must have all its non-transient components explicitly claimed; every omitted descendant must also be claimed. Unrelated authored children/components cannot disappear silently. A saved reference to an omitted node fails INVALID_ARGUMENT.

## Entry points and lifetimes

write_subtree(allocator, scene, assets, root) allocates one exact-sized result. The caller frees it with that allocator. Scene and assets must remain fixed for the operation. The root must be live in the source scene.

read_subtree(scene, assets, bytes, parent = null) returns a new root. Null parent selects Scene.root; another parent must be live in that scene with current world matrices. Persistent strings/arrays are copied into owner storage using scene.allocator; the blob can be released after success.

Both operations use tmem scratch and require an enclosing @pool(). Neither opens an inner pool, so an output allocated with tmem survives until the caller's pool ends. The container is a load/save operation and allocates scratch; it is not a per-frame system.

On a fault after creation, the reader removes all newly created nodes/components through their hooks. Existing authored values, component/node counts, asset counts/revisions and free node capacity remain unchanged. Entity generations/free-list ordering and borrowed ECS component addresses are not rollback identities.

The reader resolves all key names and codec names before creating nodes, and checks authored node capacity. A typed asset-kind mismatch can be detected later by a payload helper; that failure uses the same rollback. Owner-specific runtime reconstruction after a successful read is a separate explicit operation with its own resource failures.

## References and values

Node pointers and Entity values use u32 record indices. The all-zero Entity or null node maps to INDEX_NONE (0xffffffff). A pointer must name the actual source scene node, not merely a matching entity index/generation from another scene.

Built-in helpers cover geometry, texture, sampler, material, model, clip, skeleton, environment, shader and compute-shader IDs. Custom-kind helpers use M58's typed custom IDs. Missing custom-kind registration on the selected AssetStore is INVALID_ID for a nonzero reference; a zero reference needs no pool. Assets must be live and have nonempty keys. Each distinct key is stored once.

Writer/Reader support u32/i32/u64, float, bool, strings, enums, Vec2/Vec3/Vec4, Quat, Mat4, Transform and Aabb. Scalars are little-endian; float preserves IEEE binary32 bits. Bools are exactly 0 or 1. Strings have a u32 byte length followed by valid UTF-8 without a terminator. Embedded zero bytes remain string content. Quaternions use x/y/z/w; matrices use columns in order; Transform uses position/rotation/scale; Aabb uses min/max. Enum ordinals must stay stable for each shipped codec version.

Reader string/byte helpers return borrowed views. Codec readers copy persistent values. Writer.finish reports a bounded-size overflow; the output format is limited to uint::max bytes. A storing Writer's capacity is a programming contract after measurement.

## Container version 1

All fields below are written separately; native struct padding/endian layout is never serialized.

Header: six u32 values: magic 0x53443343 (C3DS bytes), version, byte_count, node_count, key_count, chunk_count. Header size is 24 bytes.

Each chunk-table entry is three u32 values: kind, offset from blob start, size. Entries are 12 bytes. `MAX_CHUNKS` limits the table to 64 entries; larger counts return `ASSET_FORMAT_ERROR` before scanning the table. This bounds pairwise overlap validation to 2,016 comparisons without allocation. Required kinds are KEYS=0, TYPES=1, NODES=2 and COMPONENTS=3. Each appears exactly once. Chunks must fit the blob, start after the table and not overlap. Bounded unknown kinds are skipped. Empty chunks can share an offset.

KEYS contains key_count unique, nonempty strings. TYPES contains a u32 count followed by (name string, version u32) pairs. Component names are sorted lexicographically by the writer.

Each NODES record contains:

1. Parent record u32; INDEX_NONE only for record zero.
2. Owning model-root record, template index and model key index, all u32.
3. Template-signature byte length u32 and its bytes.
4. Name string.
5. Transform, transform-space u32, layers u32 and visible u8.

The model fields are reserved in this delivery: references are INDEX_NONE and signature length is zero; model-bearing input is UNSUPPORTED. An ordinary node record is at least 73 bytes. Parent records precede their children. Canonical order is depth-first insertion order.

COMPONENTS contains group_count u32, then each group's type_index and count (u32). Every entry contains node_record u32, payload_size u32 and exactly that payload. Type groups and node/type pairs are unique. Empty component payloads are valid. Required stores must already exist in the destination.

The writer discovers keys in canonical traversal order and emits one payload group per used codec. Two writes of fixed authored state and save-load-save produce identical bytes. Runtime/process identities and registration order do not affect output.

## Versions and faults

The container currently supports version 1. A codec receives its stored version in ReadContext.version; it explicitly implements older shipped layouts and defaults new fields. Newer versions are UNSUPPORTED. Unknown names are UNSUPPORTED even if the type currently has only a transient policy. Payload framing prevents a decoder from reading into another component.

| Fault | Meaning |
| --- | --- |
| ASSET_FORMAT_ERROR | Malformed header/chunks/records/counts, duplicate entries, invalid boolean/enum/UTF-8, truncation, bad reference index or unconsumed payload |
| UNSUPPORTED | Container/type version, codec, destination store or model support unavailable |
| INVALID_ID | Missing or wrong-kind asset reference, including a dead source asset |
| INVALID_ARGUMENT | Unkeyed source asset, outside/omitted/foreign-scene node reference, conflicting owner claims or codec name |
| CAPACITY_EXCEEDED | Authored nodes do not fit, output/count cannot fit the bounded format, or a fallible owner/output allocation fails |

Operational faults from owner codecs propagate according to their declared contracts. A codec should classify invalid stored descriptors before calling an owner API with programming preconditions. Registering transient state explicitly is required; unknown components are never silently dropped.

## Owner readiness

The [owner readiness table](owner_readiness.md) defines application preparation
order after authoring attachment. Codec availability remains as listed in this
document's coverage section.

## Per-call options and diagnostics

Binary `write_subtree` and `read_subtree` accept trailing defaulted
`WriteOptions` and `ReadOptions`. Their existing calls remain valid. A reader
allocator defaults to the destination Scene allocator and is supplied to codec
callbacks through `ReadContext`. Existing Scene and owner constructors retain
their allocation contracts.

Create a reusable diagnostic with `create_serial_diagnostic(allocator)` and pass
its pointer in the options. Each call clears previous details. Collection and
component faults retain the component type and `/nodes/<record>` path, alongside
owner-supplied details such as an asset key. Reader details survive subtree
rollback. Binary diagnostics have no text position. Failed diagnostic allocation
returns `CAPACITY_EXCEEDED` and clears incomplete details. Release retained strings
with `destroy_serial_diagnostic` after use.

## Built-in policy inventory

`serial_core_policy_test` runs separately from application fixture tests and is
included in `scripts/build.py --test`. It registers the currently supported core
set without constructing a Scene and verifies automatic prerequisites and repeated
registration. It then creates a Scene and walks every assigned ECS slot. Every slot
must have exactly one described, custom-codec or transient policy matching the
expected table, or no policy and one explicit `PENDING_CORE_POLICIES` entry.
Any unclassified core component fails immediately.

Each adapter addition moves its types from pending to expected in the same change.
The pending list becomes empty when all core policies are implemented and is then
removed. Unimplemented types are never marked transient to satisfy the test.
