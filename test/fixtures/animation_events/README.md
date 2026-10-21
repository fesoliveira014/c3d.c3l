# Animation event specimens

Two repository-authored specimens carry animation events in a one-second translation clip. The import tests
(`test/src/test_import_events_gltf.c3` and `test_import_events_fbx.c3`) derive their variants in memory from these exact
bytes. `SHA256SUMS` records the file bytes.

| File | License | Holds |
| --- | --- | --- |
| `gltf-events-v1.gltf` | CC0 1.0 | One node `carrier`, two keys at times `[0, 1]`, translations `(0, 0, 0)` and `(1, 2, 3)`, and the events in the animation's `extras.c3d_events`. |
| `fbx-events-v1.fbx` | MIT (repository) | ASCII FBX 7.4 with the hierarchy Carrier -> Hip -> Foot in metres, Y up, and Carrier X moving from 0 to 1 at 0 and 1 second. Its numeric hierarchy and stack derive from `../animation_contact/profile_animation_v1.fbx`. The animation stack's `c3d_events` KString holds the event JSON, with `"` written as `&quot;`. |

One second is 46186158000 FBX ticks. Both specimens use event payload version 1.

The glTF events are authored as `(time, id)` in the order `(1, 9)`, `(0, 0)`, `(0.5, 4294967295)`, `(0.5, 3)`, `(0.5,
3)`, and the importer returns `(0, 0)`, `(0.5, 4294967295)`, `(0.5, 3)`, `(0.5, 3)`, `(1, 9)`. The FBX events are
authored as `(1, 4294967295)`, `(0.5, 7)`, `(0, 0)`, `(0.5, 7)`, `(0.5, 11)` and return `(0, 0)`, `(0.5, 7)`, `(0.5,
7)`, `(0.5, 11)`, `(1, 4294967295)`. Equal times keep their authored order. Event markers do not extend a track-derived
clip duration, and event times are never rebased.
