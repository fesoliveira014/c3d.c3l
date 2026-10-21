# Type descriptions

`c3d::describe` supplies one field walk for application data, the Scene inspector and other consumers. A reflected
description visits a struct's declared members in order; a handwritten description chooses its fields through the same
helpers. Core imports neither the GUI nor serialization to provide this contract. The Scene panel (`c3d::gui`) and the
serialization add-on (`c3d_serial`) consume it, and an application can write its own visitor.

## Quick start

Describe a component, register it once during setup and validate the registry.

```c3
import c3d;
import c3d::describe;

struct Spinner {
    bool enabled;
    float speed @tag("display", "Speed") @tag("range", { 0.0, 10.0 }) @tag("unit", "m/s");
    float speed_squared @tag("transient", true);
}

fn void? rebuild_spinner(void* raw) {
    Spinner* spinner = (Spinner*)raw;
    spinner.speed_squared = spinner.speed * spinner.speed;
}

fn void? setup_descriptions() {
    describe::register_reflected_component(Spinner, after: &rebuild_spinner)!;
    String missing_type;
    describe::validate_descriptions(&missing_type)!;
}
```

After `scene.register(Spinner)`, the Scene panel shows the component with the display name `Speed`, the `m/s` unit and a
widget clamped to 0 to 10, and omits the transient member. Editing `speed` runs `rebuild_spinner` once.

A visitor receives every field through three callbacks. This one prints a schema:

```c3
fn bool? print_field(Visitor* visitor, Info* info, void* value) {
    io::printfn("%s: %s", info.name, info.kind);
    return false;
}

fn bool? print_begin(Visitor* visitor, Info* info, void* value) {
    io::printfn("%s {", info.name);
    return true;
}

fn void? print_end(Visitor* visitor, Info* info, void* value) {
    io::printn("}");
}

Visitor visitor = { .mode = SCHEMA, .field = &print_field, .begin = &print_begin, .end = &print_end };
(void)describe::walk(Spinner, &visitor, null)!;
```

## Concepts

- **Reflected description.** `register_reflected` derives the field list from the struct, in declaration order.
- **Handwritten description.** `register_type` takes a fields callback that calls `@field` for each authored field in its
  chosen order, for a type whose complete storage cannot be reflected.
- **Component description.** `register_reflected_component` and `register_component` also bind the ECS type slot, so the
  Scene panel finds the description without a second registration. `Scene.register` still creates the component store in
  that world and may happen before or after the description registration. Non-component descriptions use no ECS slots.
- **Modes.** A visitor walks in `WRITE`, `READ`, `EDIT` or `SCHEMA` mode. Fields visit in stable declaration or authoring
  order.
- **Lifetime.** Descriptions have process lifetime. There is no reset or unregister.

## Register descriptions

Register each described struct type once during setup, including structs nested inside fields, arrays and slices. Choose
its reflected or handwritten description explicitly. A parent resolves the registered description of its child when it is
visited; it does not capture a fallback during setup. Either registration order works once both types are registered.

| Function | Meaning |
| --- | --- |
| `register_reflected(Type, after = null)` | Register a struct's reflected fields and an optional reconstruction hook. |
| `register_reflected_component(Type, after = null)` | The same, also binding the ECS slot. Faults `CAPACITY_EXCEEDED` when slots are exhausted. |
| `register_type(Type, fields, after = null)` | Register a handwritten fields callback. |
| `register_component(Type, fields, after = null)` | The same, also binding the ECS slot. |
| `register_core_components()` | Register the built-in `Mesh`, `Camera`, `Light`, `ProbeVolume`, `Atmosphere`, `HeightFog`, `ReflectionProbe`, `Decal`, `CloudLayer` and `MediumVolume` descriptions and their nested types. |
| `get(Type)`, `component(slot)` | Borrow an immutable descriptor; fields must not be modified. Fault `MISSING_DESCRIPTION`. |
| `validate_descriptions(&missing_type)` | Setup check over every registered description in schema mode. |

- Registration is single-threaded and finishes before traversal. Later concurrent walks read the registry without locks.
- Identical callbacks and reconstruction hooks make a repeat registration a no-op. A conflicting definition faults
  `DESCRIPTION_CONFLICT` and leaves the first definition authoritative. Component-slot exhaustion publishes nothing.
- `validate_descriptions` clears its output on success and fills it with the qualified type name on `MISSING_DESCRIPTION`.
  Authored descriptions can also return their own faults during this check; those propagate unchanged. A walk also
  reports the missing-description fault if setup omitted the check. The output and `Visitor.missing_type` carry detail
  for that named fault and are not independent error signals.
- Type identities and display names are process-local, not portable wire identities. Portable names, versions and
  compatibility policy belong to the serialization consumer ([Serialization](serialization.md)).

## Fields and metadata

The supported leaf kinds are `bool`, `ichar`, `char`, `short`, `ushort`, `int`, `uint`, `long`, `ulong`, `float`,
`double`, `Vec2`, `Vec3`, `Vec4`, `uint[<3>]`, `Mat4`, `Quat`, `String`, ordinary enums, entities, explicitly typed asset
references and `CustomId{T}` references. Distinct integer types describe as their base type. Nested structs, fixed
arrays and slices are scopes. Vectors, matrices and quaternions stay leaf values.

- `ICHAR`, `CHAR`, `SHORT` and `USHORT` keep their signedness and 8-bit or 16-bit storage. Both 8-bit kinds are numbers,
  never characters.
- `UVEC3` carries exactly three unsigned 32-bit lanes; any storage padding is outside its value.
- `MAT4` carries all sixteen float coefficients in column-major order (element `4 * column + row`, column-vector
  convention, so translation occupies elements 12, 13 and 14). Each coefficient follows the consumer's `FLOAT` rules,
  including exceptional values, shear and reflection. Consumers must not decompose or normalize a matrix.
- An unrelated integer or ID typedef does not acquire reference semantics from its size.

Reflection rejects unsupported fields at compile time and names the field. Pointers, unions, `constdef`, flags and
recursive type shapes are unsupported. A transient tag is the only deliberate omission from a reflected description. A
handwritten description may expose the supported authoring fields of a type whose complete storage cannot be reflected.
The recursion check follows nested raw struct and sequence types and also rejects recursive raw storage inside a
handwritten child, even if that child's authored fields omit the recursive member. Non-recursive handwritten children may
still hide unsupported raw members, such as owned pointers.

### Tags

| Tag | Value | Effect |
| --- | --- | --- |
| `@tag("display", "Speed")` | String | Presentation name. For a container, it labels the container. |
| `@tag("range", { 0.0, 10.0 })` | Two numbers | Inclusive editing range. Ordered, finite and representable by the field's scalar type; integer endpoints are integral. Applies to numeric scalars, supported floating-point and unsigned vectors and sequences of those, not matrices or quaternions. |
| `@tag("unit", "m/s")` | String | Unit label. |
| `@tag("transient", true)` | `true` | Omit the member from the description. |
| `@tag("asset", AssetKind.GEOMETRY)` | `AssetKind` | The asset kind of a raw `Id` field. Typed asset IDs already supply their kind; a tag that contradicts one, or labels a non-asset field, is rejected. |

Reflection rejects invalid tags at compilation with the field name; handwritten fields enforce the same rules through
their metadata contract. Range metadata uses `double`, so it cannot express every 64-bit integer endpoint exactly. An
absent range leaves the widget bounded by the scalar type's limits for narrow integers and unsigned vector lanes.
Sequence elements inherit range, unit and asset-kind metadata; the display name labels the container.

An asset leaf reports its resolved kind in `Info.metadata.asset_kind` with `has_asset_kind` true, whether it came from a
typed ID or a tag. A `CustomId{T}` leaf reports `CUSTOM` and `Info.metadata.custom_slot`, the address of the kind's
process-wide slot, which stays zero until the first `AssetStore.register(T)`; consumers read it when they use the field
([Custom asset kinds](custom_assets.md)).

Each callback receives the field `name`, `kind`, storage `size` and `alignment`, and the applicable display name, range,
unit, enum choices and reference kind. Storage sizes describe C3 values, not a wire encoding. An ordinary enum uses its
actual underlying width; consumers use the supplied ordinal accessors. Metadata, enum-name arrays and field addresses are
borrowed for the synchronous callback: a consumer that retains metadata must copy it.

## Write a visitor

A `Visitor` holds a `mode`, the three required callbacks `field`, `begin` and `end`, a consumer-state `user` pointer and
`missing_type`.

| Call | Meaning |
| --- | --- |
| `walk(Type, &visitor, &value)` | Walk a registered description. Faults `MISSING_DESCRIPTION`. |
| `walk_descriptor(descriptor, &visitor, &value, name = "")` | Walk a valid descriptor directly. |
| `@field(visitor, name, field, metadata = {})` | Visit one authored field inside a handwritten fields callback. |

Pass `null` as the value in schema mode.

- **Callbacks.** Every mode can emit leaf, scope-entry and scope-exit events, so all three callbacks are required. The
  leaf callback reports an actual edit. Scope entry returns whether to visit the value; a skipped value runs neither its
  children, its exit callback nor its reconstruction hook. Only edit mode uses the aggregated change result.
- **Handwritten fields.** A fields callback calls `@field` in its chosen order and combines each returned change flag
  without short-circuiting later visits: `changed = describe::@field(visitor, "speed", value.speed)! || changed;`.
- **Faults.** Scope exit means that every visited child succeeded; it is not a cleanup callback. A fault stops the walk
  immediately and propagates unchanged. Later fields, the failed scope's exit and that value's reconstruction do not run.
  Earlier writes and completed sibling hooks may remain; traversal promises no rollback. Callback fault sets are open:
  callback aliases document the consumer's fault in return prose, because C3 0.8.3 cannot express arbitrary
  function-pointer faults in `@return?`.
- **Sequences.** A fixed-array extent is immutable. A slice supplies its current header and element layout. A reading
  consumer can install fresh initialized storage during scope entry, before elements are visited. Neither a sequence nor
  an ancestor sequence may move while its elements are visited.
- **Schema.** Schema mode needs no live instance. It visits declared fields and one element shape per sequence, including
  empty slices, without accessing storage or running reconstruction. Runtime slice length is not part of a type's schema.
- **Retention.** The walker does not retain the visitor or its consumer-state pointer.

### Reading and ownership

A generic reading consumer starts with a fresh zero-initialized value. It chooses the allocator, initializes new elements
and owns every acquisition until explicit transfer. Reading into an already-owned live value is outside this contract;
its owner needs a custom description or handwritten codec.

Persistent strings and slices copy the encoded input. Before acquiring storage, readers validate encoded lengths against
remaining input, element limits and their allocation budget, including size multiplication. An invalid length returns a
named consumer fault; allocation failure propagates `mem::OUT_OF_MEMORY`. On failure, the consumer frees every
acquisition and discards the partial value. The walker never infers ownership from a slice and never allocates, resizes
or frees implicitly; its callbacks may allocate according to their own contracts.

### Reconstruction

An optional `after` hook reconstructs a value's own derived state after a successful read or an actual edit. A changed
value runs it once after its field writes, and nested values finish before their parents. Unchanged inspection, writing
and schema listing run no hooks.

The hook is idempotent and publishes no external changes. Successful local traversal does not commit an enclosing load:
later validation or another value may still fail. During inspector edits the hook must not acquire, release or replace
slice ownership; types that need scene or asset dirty marks, revision updates or reallocation keep a custom inspector.
Hook faults propagate through the same consumer failure path. A failed fresh read is discarded; a failed in-place
inspector edit stays in the value, and the Scene panel reports the fault inline without rolling the edit back.

## Scene inspector

An explicit custom inspector wins over a registered description, and a description wins over an exposed reflection-based
default. The described inspector shows presentation names and units, clamps numeric widgets to their declared ranges,
selects enum choices and labels typed references with their kind. Transient members are absent. Nested values, fixed
arrays and slice elements edit in place, and sequence lengths do not change. Strings and references are read-only. A
string slice does not promise spare capacity for the terminator an editable text widget needs. The traversal and the
described inspector perform no C3 allocation. See [GUI](gui.md).

## Run the example

```bash
python3 scripts/build.py --example described_components
```

The selected box carries a `DescribedComponent`, registered once for the Scene panel. Change its speed, motion mode and
offset to see application behavior follow the edited values. The component's hook rejects speed 10 with
`INVALID_ARGUMENT` to show an inline reconstruction failure; reducing the speed clears it.

## Limits

- Pointers, unions, `constdef`, flags and recursive type shapes cannot be described by reflection.
- Descriptions cannot be unregistered, and type identities are not portable across processes.
- A walk promises no rollback after a fault.
- The Scene panel does not change sequence lengths.

## See also

- [Serialization](serialization.md) for the consumer that saves described values.
- [GUI](gui.md) for the Scene panel.
- [Custom asset kinds](custom_assets.md) for `CustomId{T}` references.
