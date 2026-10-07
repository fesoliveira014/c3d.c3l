# Type descriptions

`c3d::describe` supplies one field walk for application data, the Scene inspector
and other consumers. A reflected description visits declared members in order;
a handwritten description chooses its fields through the same helpers. Core
imports neither the GUI nor serialization to provide this contract.

Binary, JSONC and schema visitors in the acceptance tests demonstrate the shared
walk. They are test fixtures, not a production serialization format. The
serialization add-on retains its existing codec registration and wire format.

## Registration

Register each described struct type once during setup, including structs nested
inside fields, arrays and slices. Choose its reflected or handwritten description
explicitly. A parent resolves the registered description of its child when it is
visited; it does not capture a fallback during setup. Either registration order
works once both types are registered.

Component registration publishes the same description and binds its ECS type
slot. No additional inspector registration is needed. Scene/World registration
still creates the component store in that world and may happen before or after
description registration. Non-component descriptions consume no ECS slots.

Registration is single-threaded and finishes before traversal. Later concurrent
walks read the registry without locks. Descriptions have process lifetime; there
is no reset or unregister operation. Identical callbacks and reconstruction hooks
make repeat registration a no-op. A conflicting definition faults and leaves the
first definition authoritative. Component-slot exhaustion publishes nothing.

Use `register_reflected(Type, after: hook)` or
`register_type(Type, fields, after: hook)` for ordinary structs; the
`register_reflected_component` and `register_component` forms also bind the ECS
slot. The hook defaults to `null`. `get(Type)` and `component(slot)` return
borrowed descriptors whose fields callers must not modify.

Run the setup-completion check after registration. It walks every description in
schema mode and reports the first missing nested description and its type name.
A walk also reports the missing-description fault if setup omitted this check.
`validate_descriptions(&missing_type)` clears the output on success and fills it
with the qualified type name on `MISSING_DESCRIPTION`. Authored descriptions can
also return their own faults during this check; those propagate unchanged.
The output and `Visitor.missing_type` carry details for that named fault; neither
is an independent error signal.

Type identities and display names are process-local. They are not portable wire
identities. Portable names, versions and compatibility policy belong to the
serialization consumer; see [serialization.md](serialization.md).

## Fields and metadata

The supported leaf kinds are `bool`, `ichar`, `char`, `short`, `ushort`, `int`,
`uint`, `long`, `ulong`, `float`, `double`, `Vec2`, `Vec3`, `Vec4`, `uint[<3>]`,
`Mat4`, `Quat`, `String`, ordinary enums, entities and explicitly typed asset
references. Nested structs, fixed arrays and slices are scopes. Vectors,
matrices and quaternions remain leaf values.

`ICHAR`, `CHAR`, `SHORT` and `USHORT` preserve their signedness and 8-bit or
16-bit storage. Both 8-bit kinds are numbers, never characters. `UVEC3` carries exactly three unsigned 32-bit lanes; any vector
storage padding is outside its value. `MAT4` carries all sixteen float
coefficients in column-major order: element `4 * column + row` follows the
column-vector convention, so translation occupies elements 12, 13 and 14.
Each coefficient follows the consumer's FLOAT rules, including exceptional
values. This includes shear and reflection. Consumers
must not decompose a matrix into translation, rotation and scale or normalize
its coefficients.

Reflection rejects unsupported fields at compile time and names the field.
Pointers, unions, `constdef`, flags and recursive type shapes are unsupported.
A transient tag is the only deliberate omission from a reflected description.
A handwritten description may expose the supported authoring fields of a type
whose complete storage cannot be reflected.

The reflected recursion check follows nested raw struct and sequence types. It
also rejects recursive raw storage inside a handwritten child, even if that
child's authored fields omit the recursive member. Non-recursive handwritten
children may still hide unsupported raw members, such as owned pointers.

Each callback receives the field name, kind, storage size and alignment, plus
applicable display name, inclusive numeric range, unit, enum choices and reference
kind. Storage sizes describe C3 values, not a wire encoding. An ordinary enum uses
its actual underlying width; consumers use the supplied ordinal accessors.
An unrelated integer or ID typedef does not acquire reference semantics from its
size.

Reflected members use `@tag("display", "Speed")`,
`@tag("range", { 0.0, 10.0 })`, `@tag("unit", "m/s")` and
`@tag("transient", true)`. A raw `Id` requires an explicit
`@tag("asset", AssetKind.GEOMETRY)`; typed asset IDs already supply their kind.
An asset tag that contradicts a typed ID, or labels a non-asset field, is rejected.
An asset leaf reports its single resolved kind in `Info.metadata.asset_kind`,
with `has_asset_kind` true, whether it came from a typed ID or an explicit tag.
Sequence elements inherit range, unit and asset-kind metadata; the display name
labels the container. Handwritten fields supply the corresponding `Metadata`
through `@field` and obey the same asset-kind preconditions.

Numeric ranges are ordered, finite and representable by the field's scalar type.
Integer endpoints must be integral. Reflection rejects invalid tags at compilation
with the field name; handwritten fields enforce the same rules through their
metadata contract. Ranges apply to numeric scalars, supported floating-point
and unsigned vectors, and sequences of those values, excluding matrices and
quaternions. Range metadata uses `double`, so it cannot express every 64-bit
integer endpoint exactly. An absent range leaves the native typed widget
bounded only by the scalar type's representable limits for narrow integers
and unsigned vector lanes.

Field metadata, enum-name arrays and field addresses are borrowed for the
synchronous callback. A consumer that retains metadata must copy it. The walker
does not retain the visitor or its consumer-state pointer.

## Traversal

The visitor chooses write, read, edit or schema mode. Fields are visited in stable
declaration or authoring order. Scope entry can skip a value, for example a missing
text field or a collapsed inspector section. A skipped value runs neither its
children, its exit callback nor its reconstruction hook.

`walk(Type, &visitor, &value)` resolves the registered description;
`walk_descriptor(descriptor, &visitor, &value)` accepts a valid descriptor
directly. Supply `null` for the value in schema mode. Every mode can emit leaf,
scope-entry and scope-exit events, so all three callbacks are required. The leaf
callback reports an actual edit; scope entry returns whether to visit the value.
Only edit mode uses the aggregated change result. An authored fields callback
calls `@field` in its chosen order and combines each returned change flag without
short-circuiting later visits.

Scope exit means that all visited children succeeded. It is not a cleanup callback.
A fault stops the walk immediately and propagates unchanged. Later fields, the
failed scope's exit and that value's reconstruction do not run. Earlier writes and
completed sibling hooks may remain; traversal promises no rollback.

Callback fault sets are open. C3 0.8.3 cannot express arbitrary function-pointer
faults in `@return?`; callback aliases document the consumer's fault in return
prose, and traversal docstrings list their own named faults alongside that rule.

Fixed-array extent is immutable. A slice supplies its current header and element
layout. A reading consumer can install fresh initialized storage during scope
entry, before elements are visited. Neither a sequence nor an ancestor sequence
may move while its elements are being visited.

Schema mode needs no live instance. It visits declared fields and one element
shape per sequence, including empty slices, without accessing storage or running
reconstruction. Runtime slice length is not part of a type's schema.

## Reading and ownership

A generic reading consumer starts with a fresh zero-initialized value. It chooses
the allocator, initializes new elements and owns every acquisition until explicit
transfer. Reading into an already-owned live value is outside this contract;
its owner needs a custom description or handwritten codec.

Persistent strings and slices copy the encoded input. Before acquiring storage,
readers validate encoded lengths against remaining input, element limits and their
allocation budget, including size multiplication. Invalid lengths return a named
consumer fault; allocation failure propagates `mem::OUT_OF_MEMORY`.

On failure, the consumer frees every acquired allocation and discards the partial
value. The walker never infers ownership from a slice and never allocates, resizes
or frees implicitly. Its callbacks may allocate according to their own contracts.

## Reconstruction

An optional hook reconstructs a value's own derived state after a successful read
or an actual edit. A changed value runs it once after its field writes; nested
values finish before their parents. Unchanged inspection, writing and schema
listing run no hooks.

The hook is idempotent and publishes no external changes. Successful local
traversal does not commit an enclosing load: later validation or another value may
still fail. During inspector edits the hook must not acquire, release or replace
slice ownership. Types that need scene/asset dirty marks, revision updates or
reallocation retain a custom inspector.

Hook faults propagate through the same consumer failure path. A failed fresh read
is discarded. A failed in-place inspector edit stays in the value and the Scene
panel reports the fault inline; it does not roll back the edit.

## Scene inspector

An explicit custom inspector wins over a registered description. A description
wins over an exposed reflection-based default. Existing built-in inspectors retain
their registration paths and output.

The described inspector displays presentation names and units, clamps numeric
widgets to their declared ranges, selects enum choices and labels typed references
with their kind. Transient members are absent. Nested values, fixed arrays and
slice elements can be edited in place; sequence lengths do not change. Strings
and references are displayed read-only. A string slice does not promise spare
capacity for the terminator required by an editable text widget.

The traversal and described inspector perform no C3 allocation. ImGui context,
font and frame setup retain their own native-library lifetime requirements.

## Example

Run `python scripts/build.py --example described_components` from the repository
root. The selected box has a `DescribedComponent` registered once for the Scene
panel and the acceptance visitors. Change its speed, motion mode and offset to
observe application behavior driven by the edited values.

The demo deliberately rejects Speed 10 with `INVALID_ARGUMENT` to show an inline
reconstruction failure. The edit remains stored and the previous derived value
remains; reducing Speed triggers successful reconstruction and clears the error.
This rejection belongs to the demo component, not the generic description API.
Check that Speed is clamped to 0–10, its `m/s` unit is shown, enum choices work,
references show their kinds without editing, and the transient derived member is
absent.
