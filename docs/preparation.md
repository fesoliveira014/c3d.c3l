# Preparation

Preparation uploads assets and builds pipelines before the first frame that needs them, so that frame does not stall.
`Renderer.prepare_scene` and `Renderer.prepare_model` do it all at once and wait. The budgeted API
(`begin_prepare_model`, `advance_prepares_within`) spreads one model's preparation over frames within per-call limits.
All of it lives in `c3d::render`.

## Quick start

Prepare everything a loaded scene references, between frames:

```c3
renderer.prepare_scene(&scene)!;
```

Prepare a model before instantiating it, in bounded steps across frames:

```c3
PrepareId prepare = renderer.begin_prepare_model(model)!;

// Each frame, while the preparation is open:
renderer.begin_frame()!;
defer catch render::abort_frame(&renderer);
PrepareReport report = renderer.advance_prepares_within({
    .staged_bytes = render::PREPARE_FRAME_BUDGET_BYTES,
    .generated_texels = 1 << 20,
    .pipelines = 1,
    .time_ns = 2_000_000,
})!;
renderer.end_frame()!;

PrepareProgress progress = renderer.prepare_progress(prepare);
if (progress.state == PrepareState.READY) {
    model::instantiate(&assets, &scene, model)!;
    renderer.end_prepare(prepare)!;
}
```

## One-shot preparation

- `prepare_scene(scene)` uploads every asset the scene references, creates the mesh, shadow and snapshot pipelines,
  and the display and effect pipelines of every live view, then waits.
- `prepare_model(model)` does the same for a stored model (`ModelId`) before it is instantiated, and prepares the
  depth-only variants unconditionally.
- Both must run with no frame open.
- Views created afterwards prepare their pipelines on first render.

A mesh's pipelines follow the live views, so configure the views before preparing. The forms prepared per view are:

- the `RT_SHADOWS` forms of a view with traced shadows (with `SCENE_TRACE_BVH` on the software path), hard-only unless
  the scene has a traced light with a [source extent](ray_traced_shadows.md#soft-shadows);
- the `WEIGHTED_BLEND` forms and the composite of a `WEIGHTED` view;
- the thin reflection prepass pair of a forward view with traced reflections.

`Stats.pipelines_created` counts the pipelines the cache built in a frame, prepared ones included. A first frame that
draws only prepared configurations reports zero.

## Budgeted preparation

### Open a preparation

`begin_prepare_model(model)` lists the model's dependencies synchronously and returns a `PrepareId`. It faults
`c3d::INVALID_ID` for a dead model and `c3d::CAPACITY_EXCEEDED` when `PREPARE_CAPACITY` (4) preparations are already
open. Referenced material layers, samplers, custom shader data and texture demand are dependencies of their parent
material. View targets and unrelated view resources are outside model preparation.

### Advance within limits

`advance_prepares_within(limits)` needs an open frame. `PrepareLimits` has four axes, each per call:

| Field | Limit |
| --- | --- |
| `staged_bytes` | Bytes staged for GPU upload |
| `generated_texels` | Texels written while generating mip levels |
| `pipelines` | Pipeline creation calls |
| `time_ns` | A cooperative time target in nanoseconds |

- A zero axis is unbounded. All-zero limits drain every pending preparation.
- Every call has a fresh allowance, shared across open preparations in the order they began. Pause by not calling.
- A step that does not fit stops the call. `PrepareReport.reason` (`PrepareStopReason`) names the axis and
  `PrepareReport.required` the bytes, texels or pipeline calls that step needs; raise that allowance in a later
  call. A depleted finite allowance never becomes unbounded.
- `PREPARE_FRAME_BUDGET_BYTES` (1 MiB) is a staged-byte allowance suited to one call per frame. An allowance below the
  smallest legal step blocks that step until a call raises it.
- Uploads split into legal texture row and block bands and aligned geometry ranges. Mip generation splits into
  destination row bands. A complete mip chain costs its generated texel count, twice with threshold coverage.
  CPU-only shader copies are reported separately as `copied_bytes`.
- A normal pipeline miss creates one pipeline per step. Adopting a custom shader atomically can need several cached
  pipelines: a bounded call defers it until the whole creation count fits, and an unbounded call admits it.
- The time target is checked between bounded spans and indivisible steps, after the first step of each call, so a
  target below the fixed per-call overhead still advances one step per call. A span, an allocation or a texture's
  creation can overrun it. `PrepareReport` reports elapsed time, overrun, generation time and pipeline driver time
  separately.
- `Stats` sums each frame's staged bytes, generated texels, pipeline calls and times as `prepare_*` fields. Ordinary
  residency raises keep their own pacing.

### Read progress

`prepare_progress(id)` returns a `PrepareProgress`: `state`, `phase`, fixed totals (`bytes_total`, `texels_total`,
`units_total`), the completed counts, `restarts` and `failure`.

| `PrepareState` | Meaning |
| --- | --- |
| `PENDING` | Work remains |
| `SUBMITTED` | The final work was submitted |
| `READY` | The covering submission completed; the model's resources are usable |
| `FAILED` | `failure` holds the fault |

- Poll `prepare_progress` on later frames to see `SUBMITTED` become `READY`.
- Dependencies that are already current or removed advance their byte progress without staging. Generated-texel
  progress counts only generation performed or skipped, so it can stay below the fixed total. Removed dependencies
  count as dangling.
- A stale `PrepareId` or a removed model reports `FAILED` with `c3d::INVALID_ID`.

### Publication

Partial work stays private. The frame that records a preparation's final copy installs the complete mirror, usable
later on the same queue. An aborted frame restores the previous mirror and the last committed progress. Advancing
never submits a frame itself, and a submission stays committed after a later presentation fault.

Each step reacquires its source by identity and revision, and a relevant change restarts the record. A restart
recomputes and resets the totals, so a progress display must not cache them; repeated mutation can prevent
completion. Released required source data fails the record with `c3d::ASSET_DATA_UNAVAILABLE` unless the
job already owns everything it still needs. Ordinary draws or synchronous uploads can make a mirror current and
supersede a private candidate.

Record-local asset and shader faults fail that record. Device and capacity faults propagate from
`advance_prepares_within`; abort the frame with `render::abort_frame`.

### Finish

`end_prepare(id)` must run with no frame open. It cancels the preparation, frees its CPU data and retires unpublished
candidates after their last submission completes. Published mirrors stay cached. It faults `c3d::INVALID_ID` for a
stale id.

## Limits

- One model per preparation; four preparations open at a time.
- `prepare_scene` and `prepare_model` wait for the device; they are for load screens, not per-frame use.
- Views created or reconfigured after preparation can still build their own pipelines on first use.

## See also

- [Views](views.md) for views and frames.
- [Models](models.md) for loading and instantiating models.
- [Textures](textures.md) for upload and residency budgets.
- [GUI panels](gui_panels.md#preparation-counters) for the preparation counters.
