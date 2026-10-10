# FBX event fixture

`fbx-events-v1.fbx` is repository-authored ASCII FBX 7.4 under the repository MIT license. Its numeric hierarchy and translation stack derive from `../animation_contact/profile_animation_v1.fbx`; no third-party model data is included.

The hierarchy is Carrier -> Hip -> Foot, in metres and Y-up. Carrier X moves from 0 to 1 at source times 0 and 1 second. One second is 46186158000 FBX ticks. The animation-stack `c3d_events` KString stores the inner version-1 JSON object. JSON quotes are encoded as `&quot;` in ASCII FBX.

The authored event order is `(1, 4294967295), (0.5, 7), (0, 0), (0.5, 7), (0.5, 11)`. The expected stable time order is `(0, 0), (0.5, 7), (0.5, 7), (0.5, 11), (1, 4294967295)`.

`test/src/test_import_events_fbx.c3` derives variants in memory from these exact bytes: property replacement/removal, malformed schema, animation disablement, negative/zero/positive LocalStart, shifted positive key ticks, no curves, one zero-time key, and same-key replacement. The source identity and hierarchy remain unchanged unless the case explicitly removes animation objects.

Pinned ufbx trims key times only when LocalStart is positive. The positive-start variant moves LocalStart/LocalStop and both key ticks to [1,2] seconds, producing decoded keys [0,1]. Negative-start cross-path cases use LocalStart -1 and genuine translation, Y-rotation and positive uniform-scale curves with nonnegative keys [0,1], which remain unchanged. Rotation changes 0 to 10 degrees; all three scale components change 1 to 2. The nonconstant curves prevent ufbx from synthesizing unanimated channels at the negative stack start; bake-generated interior keys are required to stay ordered inside [0,1]. A separate negative-key decode case preserves keys [-1,1] and the existing profiled-import rejection; event times are never rebased. Event markers do not extend track-derived clip duration.

Fixture and recipe hashes are recorded in the change evidence from committed blobs.
