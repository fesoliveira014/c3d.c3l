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
