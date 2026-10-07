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

InstancedMesh, BillboardBatch and LodGroup also restore in the VALUE phase through
private authoring descriptions. They retain capacity and live entries in copied
storage. Instanced batches preserve flags, sway, fade and bounds overrides; LOD
retains ordered parts with full affine matrices, level thresholds, common effects
and terminal impostor configuration. Unused transforms restart at identity,
unused colors at white and unused billboards at `BILLBOARD_DEFAULT`. Bounds caches,
revisions and logical LOD identities restart under normal owner rules.

ModelInstance, SkinBinding, IkChain, FootIk and LookAt restore in REFERENCES.
Animator and AnimatedCrowd restore in OWNER. Their captured authoring, reference
and restart contracts are detailed in the built-in policy inventory below.
Animator export projects owned transforms and Mesh morph weights to captured
baselines; ordinary Mesh values preserve their explicit weights.

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
included in `scripts/build.py --test`. It registers all 18 core policies without
constructing a Scene and verifies automatic prerequisites and repeated registration.
It then creates a Scene and walks every assigned ECS slot. Every slot must have
exactly one described, custom-codec or transient policy matching the expected table.
There is no pending list. A new core component without an expected policy fails.

ModelInstance uses the REFERENCES phase. Its payload retains the model key,
per-template-node signature and mapping, explicit absent slots, base poses,
mesh slots, baseline morph arrays and clips. The reader validates signatures and
unique node claims before any component attaches, then copies the owner arrays
onto the saved graph. It does not instantiate the template or recreate removed
nodes/components. Application children and ordinary transform overrides remain.
A selected template node requires its model owner in the selected subtree.
Template disagreement returns INCOMPATIBLE_TEMPLATE with the model key and first
differing template index. The binary NODES model fields remain reserved.
SkinBinding, IkChain, FootIk and LookAt restore in REFERENCES. Their required
joints and targets are resolved before any component attaches. NodeReference
stores an ordinary document node or a model owner plus template index; removed
model slots cannot bind to a reused scene slot. Skin joint arrays are copied into
the destination allocator. Foot ground contact and alignment state restart.
The shared NodeReference layout is registered by register_core_value_types;
SkinAuthoring exposes the decoded skeleton and required joint references to
other owner preflight callbacks. Missing binary asset keys retain the key in
SerialDiagnostic, matching JSONC diagnostics.
Animator restores in OWNER after ModelInstance and reference components. Export
projects its template nodes and Mesh morph weights to the captured baselines
without changing the source scene. The instance root retains its current placement.
Action masks, layers, clips, speed, loop/playing flags, root-motion mode and blend
space configuration persist; action times, space phases, events and fades restart.
Active fades settle at their targets; fading-out actions and spaces are omitted,
while settled zero-weight actions remain. Handles are newly allocated. An absent
configured root slot retains its mode and contributes zero root motion.
Model signatures compare every ordered mesh and skin slot per template node.
The unreleased ModelInstance layout pins change with this complete signature;
ordinary binary container fixtures remain compatible. Asset storage accepts
repeated slots, while eager instantiation retains its existing one-component-per-
node contract. The serializer can reconstruct an explicitly authored saved graph.
Ordinary pointer references capture the current live entity, including explicit
LookAt/IK retargeting after slot reuse. Skin joints alone retain captured template
identity: deleting a required template joint rejects export even if its address
was reused, rather than silently rebinding the original skin.
AnimatedCrowd restores in OWNER with its model, capacity, live placements/colors,
clip/speed/loop settings, captured start times, bounds and trace flag. Loads remain
pending with no generated part nodes; prepare_crowd builds runtime explicitly.
Generated batches are omitted only after checking the retained owner association.
Exporting a generated part without its owner, or adding authored components to an
omitted part, returns INVALID_ARGUMENT. Pending and prepared owners write the same
authoring; sampled clocks, palettes and cursors are not persisted.

## Authored numeric domains

Each owner validates its authored numeric domain on export and import, for both
binary IEEE values and JSONC float-bit tokens. Invalid values return
`INVALID_ARGUMENT` with the component type and node path. These are owner rules;
generic described floats, node transforms, crowd placements and colours retain
IEEE fidelity, including non-finite values. Runtime APIs retain their existing
contracts. Existing shared runtime validators also govern serialization.

| Owner | Fields | Domain |
| --- | --- | --- |
| Wind | `velocity` components, `drag`, `lift`, `max_speed` | Finite; no added range restriction |
| Force | `force` and `local_point` components | Finite; no added range restriction |
| Buoyancy | `fluid_density`, `linear_drag` | Finite; no added range restriction |
| PhysicsBody | BodyDesc `linear_velocity` and `angular_velocity` components, `linear_damping`, `angular_damping`, `gravity_scale` | Finite; no added range restriction |
| Animator | Action `speed`; blend-space `parameter`, `speed` | Finite; negative speeds allowed |
| Animator | Action and blend-space `weight` | Finite and nonnegative; no upper cap |
| AnimatedCrowd | Pose `speed`, captured start time | Finite; negative values allowed |
| Ragdoll | Aggregate `weight`, each `bone_weights` value, `drive_strength` | Finite and nonnegative; no upper cap |
| NavVolume | BOX `box`; CONVEX `verts[:vert_count]`, `min_y`, `max_y`; CYLINDER `base`, `radius`, `height` | Finite active fields; `min_y <= max_y`; cylinder radius and height positive |
| NavLink | `start`, `end`, `radius` | Finite; positive radius and distinct endpoints |
| NavObstacle | CYLINDER `position`, `radius`, `height`; BOX `box`; ORIENTED_BOX `position`, `half_extents` | Finite active fields; positive cylinder dimensions and oriented half-extents; nonnegative box extents |
| NavAgent | Params `radius`, `height`, `max_acceleration`, `max_speed`, `collision_query_range`, `path_optimization_range`, `separation_weight` | Finite; radius and max speed nonnegative; height positive |
| NavAgent | `target` when `target_kind == POSITION` | Finite; NONE and VELOCITY retain IEEE fidelity |

Navigation's shared predicates govern runtime `add_nav_*` calls and both
serialization paths. The void target setters retain their existing contracts;
serialization validates POSITION targets before writing or attaching authoring.
Inactive shape fields and unused convex vertices retain IEEE fidelity.

See the [serialization example](serialization_example.md) for binary/JSONC reloads,
schema export and reproducible CPU-only or Vulkan runs.

## Physics adapter

Select `c3d_serial`, enable `C3D_PHYSICS_SERIAL`, and call
`physics::register_serial_codecs()` alongside `physics::register_physics(scene)`.
The plain physics manifest has no serialization dependency. PhysicsBody persists
BodyDesc and all nested collider authoring with copied arrays and strings. It
restores PENDING with cleared failure/revision state; no native body is created.
PhysicsJoint restores in REFERENCES with a required model-aware endpoint and
only its selected variant. Wind and Force persist their complete values; Buoyancy
persists density and drag and resets submerged fraction. RigidBody and Joint are
explicitly transient. Ordinary physics synchronization creates the native state.
The package inventory discovers every physics slot through normal registration;
All ten normally registered physics component types have explicit policies;
new unclassified physics components fail the package inventory.

## Navigation adapter

Select `c3d_serial`, enable `C3D_NAV_SERIAL`, and call
`nav::register_serial_codecs()` alongside `nav::register_nav(scene)`. The plain
navigation manifest has no serialization dependency. NavSource, NavVolume,
NavLink, NavObstacle and NavAgent restore in REFERENCES with their complete
settings, target kind/value and driven flag. Changed flags restart false. A
NavSource with no explicit geometry requires the node's restored Mesh. The
five runtime mirrors are explicitly transient; no builder, crowd or navmesh is
created during read. Ordinary nav_sync and crowd_update rebuild those mirrors.
The independent package inventory checks all ten normally registered types.

## Cloth adapter

Physics registration also installs the Cloth OWNER policy. Export projects its
ordinary Mesh record to retained source geometry and vertex-motion, preserving
all other Mesh fields and leaving the source scene untouched. The Cloth payload
retains complete settings, requested pin order/duplicates and required collider
references. Reads retain that Mesh and attach pending Cloth without private
geometry or solve state. Synchronize physics bodies before cloth preparation.
The explicit navigation composition test proves a NavSource with no geometry
can use the restored Mesh before ordinary navigation synchronization.

Owner collection may call `WriteContext.project_component(node, value)` to
project an existing component through its ordinary codec. Borrowed dynamic data
must outlive the synchronous export. Duplicate projections, competing owners,
projection/omission conflicts and transient ownership claims are rejected.

## Ragdoll adapter

Ragdoll restores in OWNER after model/skin and body/joint authoring. Bone mappings,
parents, bind frames, modes, per-bone weights and captured drives, aggregate weight,
drive strength and current node placements persist. Weights and drive strength
must be finite and nonnegative, with no upper cap, on both export and import.
Preflight checks required references and mode/body/joint consistency before any
component attaches; diagnostics include the bone index and model details when
applicable. Restored owner arrays are independent copies. Joint order/ownership
are recomputed, frozen recovery poses start at loaded skin-joint locals, and
scratch/counters/recovery result reset. Bone-body velocities restart at zero.
Ragdoll collection projects only its listed bodies; ordinary body velocities
persist and source values are unchanged. Normal physics sync creates native state.

## Breakable adapter

Breakable restores in OWNER as a pending copied recipe with no bodies, welds or
cooked runtime resources. A prepared export retains ordered surviving pieces and
hulls, captures current root-relative frames, and projects WORLD piece transforms
to PARENT while preserving world placement and authored render descendants.
Fewer than two prepared survivors returns UNSUPPORTED with root/type diagnostics.
A pending export preserves its exact recipe and saved placements, including a
mismatch that explicit preparation must still report. Normal world preparation
rebuilds the graph from current contacts; touching survivors can weld again.
Only verified owned body components are omitted; modified or unrelated bodies,
conflicting owners and joints are rejected. Source nodes and assets are unchanged.
`WriteContext.set_transform` projects transform and coordinate space together.

## Character adapter

Select `c3d_serial`, enable `C3D_CHARACTER_SERIAL` and `C3D_PHYSICS_SERIAL`,
and call `character::register_serial_codecs()`. The adapter reuses physics value
registrations. Register ordinary physics and character stores before reading.
Character restores in REFERENCES with its full descriptor and capsule state at
the saved node pose. Velocity, movement intent, contact, jump and plane state
restart. Optional push-body authoring is copied fallibly and remains pending
until normal physics synchronization; only the verified generated body is omitted.
The plain character manifest has no serialization dependency.

With `C3D_CHARACTER_NAV`, also select `c3d_nav` and enable `C3D_NAV_SERIAL`.
Character codec registration includes navigation codecs and the NavDriven OWNER
marker. It requires Character and NavAgent, resets traversal and applies normal
add_nav_driven behavior after both components restore. Independent policy targets
check ordinary registration with and without navigation.
