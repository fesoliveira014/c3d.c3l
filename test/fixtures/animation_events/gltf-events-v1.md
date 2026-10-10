# glTF event specimen

This CC0 authored specimen has one node and a one-second translation clip.
The two keys are `[0, 1]`; translations are `(0, 0, 0)` and `(1, 2, 3)`.
The embedded buffer is the little-endian float sequence
`[0, 1, 0, 0, 0, 1, 2, 3]` encoded as base64.

`test_import_events_gltf.c3` reconstructs that buffer from an aligned C3
float array and checks the source payload before applying metadata-only
recipes. Expected event order is literal: `(0,0)`, `(0.5,4294967295)`,
`(0.5,3)`, `(0.5,3)`, `(1,9)`, written as `(time,id)`.

SHA-256 of the LF source: `5d91c50f54c92519119529e729f3ec06490e238841c1e25e1a9ff8969535797a`.
