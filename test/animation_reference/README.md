# Ordinary Animator reference capture

This manual C3 target records ordinary Animator controls and observable field bits. It does not implement sampling, clocks, blending, root motion or event selection. Existing test sources and the production evaluator are inputs to the external capture record, not copied or changed by this tool.

The target captures the authored exact fixture and selected samples from the unmodified CC0 Quaternius and AnimatedMorphCube repository assets. The complete frozen-reference gate also requires the unchanged Animator/motion regression tests and externally recorded source/input hashes.

## Run and replay

Run from the repository root after canonical dependency/shader setup:

    c3c build animation_reference --path test/animation_reference

Execute the resulting program with an output filename and an optional frozen reference filename:

    test/animation_reference/build/animation_reference.exe OUTPUT.bin [REFERENCE.bin] [REPOSITORY_ROOT]

Use the platform's executable suffix. The caller creates the output directory. REPOSITORY_ROOT defaults to the source file's repository root; supply it explicitly when relocating the source or executable. The caller owns baseline/candidate paths, fixture/source hashes, compiler/options, tested commit and evidence. Freeze the baseline before evaluator extraction, using the approved source tree and default safe settings. A second identical run must produce the same bytes. Later run the unchanged control sources against the candidate evaluator and supply the frozen output as REFERENCE.bin.

Capture always writes OUTPUT.bin. Reference equality exits 0; a difference or operational failure exits 1; bad arguments exit 2. A comparison reports the first differing field-word offset, case, sample and operation. Compiler optimization is an explicitly separate capture and must not be compared across options.

## Exact fixture and controls

The source recipe constructs five template nodes, two full two-weight morph meshes, one two-joint skin and five shared clips. The root-motion joint has a nonzero horizontal pivot and tilt, beneath a static yawed ancestor with positive uniform scale. Morph defaults are nonzero. Clip data includes LINEAR motion/rotations, antipodal overlay keys, a CUBICSPLINE additive translation with nonzero tangent fields, additive scale/rotation/morph tracks and a STEP morph clip. Two motion clips have different durations and explicit seam/quarter/half events. Arrays are published through ordinary AssetStore APIs, then instantiated through model::instantiate.

Cases, all driven through public Animator and scene APIs:

| Case | Script |
| --- | --- |
| 1 | Base play; seek and zero-step; forward wrap; pause; speed zero; reverse wrap; lower and upper non-looping clamps; multi-loop event overflow; backward seek; stop and baseline restoration. |
| 2 | Four layer indices; copied named mask after input edit; above-unit regular weight; additive reference/time zero; STEP morph; fade-in/crossfade; fade-out removal; missing-channel/default restoration; absent nonjoint target. |
| 3 | Two 1D groups; different member durations; endpoints/interior/outside-range parameters; phase edit; reverse clock; paused posing; group fade; layered additive group; member removal. |
| 4 | Weighted/layered EXTRACT with yaw, post-blend offset pivot through static scaled/yawed ancestry, weighted KEEP contribution, application-consumed motion, reverse multi-loop and seek/zero-step. |
| 5 | CC0 Quaternius Walk_Loop/Jog_Fwd_Loop/Idle_Loop: selected phases, forward/reverse travel, regular crossfade and quarter-weight playback, stop/baseline restoration; all 57 loaded template locals and complete mesh weights recorded. |
| 6 | CC0 Khronos AnimatedMorphCube: defaults, phase samples, non-looping speed, additive morph reference/delta, reverse additive clock, fade removal and full-vector default restoration across its two loaded template nodes. |

Each control operation and update records a snapshot. Compound edits between snapshots are one documented EDIT_ACTION or EDIT_SPACE operation. Script action labels are stable semantic IDs: 10/11 base/outgoing-incoming, 20 overlay/extractor, 30 additive or KEEP, 40/41 STEP, and 50/51 or 60/61 space members. Labels are resolved through captured generational action IDs, never pointer/slot identity. Clip labels are indices in the fixture's frozen clip list.

## Binary word format, version 1

All words are unsigned 32-bit little-endian. Float fields use their IEEE float bits. Double fields use low then high IEEE words. Booleans are 0 or 1. No pointer, padding, allocator address, entity ID, raw clip ID or raw action ID is written.

File header: AREF magic (0x46455241), version 1, snapshot count.

Snapshot header: SNAP magic (0x50414e53), case ID, case-local sample number, operation ordinal, update dt bits (zero for control operations), payload word count.

Operation ordinals follow CaptureOperation: BASELINE, PLAY, EDIT_ACTION, UPDATE, STOP, CROSS_FADE, ADD_SPACE, EDIT_SPACE, STOP_SPACE, APPLY_MOTION, REMOVE_TARGET, starting at zero.

Payload order:

1. Synthetic root local transform: position xyz, quaternion xyzw, scale xyz; configured root-node index; template node count.
2. For every template index: present flag, followed by its complete local transform when present.
3. Mesh count; for each mesh: template-node index, present-Mesh flag, full logical weight count, every weight bit.
4. Published root-motion translation xyz and quaternion xyzw.
5. Live action count; actions in play order. Each writes scripted action label, normalized clip label, layer, RootMotion ordinal, additive/loop/playing/root-yaw flags; time/speed/weight/fade-target/fade-rate/published-time float bits; previous-time/clock-delta/clock-time double bits; blend-space slot tag; mask count/members; additive-reference count/values.
6. Space slot count; for each: member count. Active slots then write parameter/weight/fade-target/fade-rate float bits, phase double bits, speed float bits, playing flag, and each normalized member label/position pair.
7. Fired-event count and dropped count; event order then writes scripted action label, normalized clip label, authored event ID, authored time bits.

Variable counts delimit full vectors and absent state. Sampling cursors and memory layout are excluded: the compared outputs are meaningful controls and complete public pose/morph/motion/event values. These sources are rerun unchanged after extraction. The ordinary frozen baseline, rather than two consumers of a new shared evaluator, is the reference.

## Real input provenance

Inputs are loaded from examples/assets/quaternius/AnimationLibrary_Godot.glb and examples/assets/gltf/AnimatedMorphCube.glb. Their repository README/license notices remain unchanged. Expected immutable input SHA256 values are respectively 272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c and 214ee56160a50dbf22543a1d66dbf860986e87f0efac3d89feac1359d0e6aeab. The external capture manifest verifies these before loading and records the tool/source/executable hashes. The output itself records numeric state only and does not claim a provenance check.
