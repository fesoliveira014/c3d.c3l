# Described value policies

Register each serialized struct with `register_described_type(Type, version,
layout, defaults)` after registering its field description. Registration is
single-threaded and process-lifetime. The layout is a committed FNV-1a fingerprint
of SCHEMA events, field names, kinds, sizes, extents, enum labels and asset kinds;
the root label is `value`, independent of the C3 qualified type name.

Missing defaults or a mismatched pin return `INVALID_ARGUMENT`. Repeating the
same registration is idempotent; conflicting version, layout or defaults return
`INVALID_ARGUMENT`, matching the existing component-codec conflict fault.
Changed layouts need a new committed version and pin before registration.
`DefaultsFn` initializes every field without allocating; strings and slices may
borrow immutable process-lifetime storage. Shared scene policies are registered
explicitly with `register_core_value_types()`.

The internal binary visitor emits every described field, without default
elision. It writes little-endian integers, raw floating-point bits, portable
references and length-delimited struct/array/slice payloads. Struct payloads
carry their version and layout fingerprint. Native pointers and padding never
enter the payload. Readers require complete current-version payloads: truncated
fields are format faults and never filled from defaults.

Reader-owned strings and slices use fallible, aligned acquisitions. Every caller
releases its acquisition list after copying retained values or after a failure.
Generated component binding and container attachment build on these visitors;
they are delivered separately from this field-level policy.

## Component binding and binary restoration

`register_described` binds a component to its registered value policy.
`register_described_owner` binds a component through a separate authoring type.
Projection borrows authored values synchronously. Attachment copies all retained
strings and slices into the component's ordinary ownership and removal hooks;
dynamic descriptions require an explicit copying attachment callback. Failed
attachment leaves that component absent. Duplicate portable names return
`INVALID_ARGUMENT`, matching manual codec registration.

An optional validator runs after node/reference resolution and before any
component attaches. `ReadContext.authored(Component, Authoring, node)` borrows a
referenced component's decoded authoring from this document. Cached values live
through attachment; validators run once. Unvalidated components retain sequential
decoding, so a later failure still rolls back earlier attached owners. New reader
acquisitions use `ReadOptions.allocator`, defaulting to the destination allocator,
and are released on success and every returned fault.

An older binary version is accepted only through its listed `BinaryCompatibility`
reader; other versions fail with `UNSUPPORTED`. Current payloads require their
complete pinned layout and never fill truncated fields from defaults. The tests
pin a version-1 manual-codec container captured before generated binding.
Manual `ComponentCodec` registration remains supported.

## JSON field values

The field reader initializes semantic defaults, copies default strings and slices
into reader-owned storage, then overlays fields present in the input. Absent
nested values retain parent overrides. New slice elements receive their own type
defaults. READ completion hooks run only for entered values, with child hooks
before their parent; cloning defaults and writing never invoke them.

Writers emit every described field, including values equal to defaults. Fixed
arrays, vectors, quaternions and matrices require their exact element counts.
Unknown fields are format errors unless skipping is explicitly enabled; parsing
still validates the complete JSONC input. Field failures retain JSON Pointer and
text position. The caller releases the acquisition chain after success or failure.
These visitors support the later public text-subtree and schema entry points.
