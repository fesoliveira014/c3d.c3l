# Light version 1 streams

These binary and JSONC subtree streams were exported with C3 0.8.3 from
`ea60ff89cb59a815494ec2ffaeeddd9a07c70bea`, before colored transmission became a
Light authoring field. The producer uses `serial::register_core_codecs()` and
the ordinary binary/text subtree writers. It does not patch a later stream.

The one node is named `light`. Its SPOT Light has color `(0.25, 0.5, 1)`,
intensity `2.5`, range `15`, inner/outer cones `0.125`/`0.5`, and receiver layers
`0x80000001`. Shadows are enabled, priority `-7`, bias `0.003`, directional
normal bias `3.5`, punctual normal bias `0.02`, three cascades, lambda `0.6`,
blend `0.125`, maximum distance `23.5`, and ray tracing enabled.

The component and nested ShadowSettings descriptions are version 1. Their
fingerprints are `0xa41c0d2284b8d046` and `0x79ccc384defd9804`, respectively.
Reading them with the current codec preserves every stored field and defaults
`colored_transmission` to false.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| light-v1.bin | 297 | `96c290b5267c3798e27aeb7fb4ece28439ad61c23deabadcb131e296cee3a96c` |
| light-v1.jsonc | 1249 | `f5ac4114d3ebc8ac1a030f160d24c1b15c436cb4c7283e865ab9954cae012c03` |

The producer source and export receipt belong to the change artifacts. The
committed test checks both file hashes before exercising backward reads.
