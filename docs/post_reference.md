# Post reference

Fields, defaults, ranges, faults and statistics of the display-processing stack. [Display processing](post.md) explains
how the stages behave; [anti-aliasing](anti_aliasing.md) explains FXAA, TAA, velocity and history. All types live in
`c3d::render::post`.

## PostStack

`ViewDesc.post` is a `PostStack`. `post::default_post_stack()` returns the defaults below. A zeroed `PostStack` is not
neutral: it has an empty LUT domain and zero parameters.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `grade` | `GradeParams` | neutral, ACES | Exposure-independent grade, tone mapping and LUT |
| `anti_aliasing` | `AntiAliasing` | `FXAA` | `NONE`, `FXAA` or `TAA` |
| `taa_params` | `TaaParams` | see below | Read only while `anti_aliasing == TAA` |
| `bloom` | bool | false | Enables bloom |
| `bloom_params` | `BloomParams` | see below | Read only while `bloom` is set |
| `depth_of_field` | bool | false | Enables depth of field |
| `dof_params` | `DofParams` | see below | Read only while `depth_of_field` is set |
| `motion_blur` | bool | false | Enables motion blur |
| `motion_blur_params` | `MotionBlurParams` | see below | Read only while `motion_blur` is set |
| `auto_exposure` | bool | false | Enables automatic exposure on `DISPLAY_LDR` views |
| `auto_exposure_params` | `AutoExposureParams` | `AUTO_EXPOSURE_DEFAULT` | Read only while `auto_exposure` is set |

### GradeParams

| Field | Default | Meaning |
| --- | --- | --- |
| `tonemap` | `ACES` | `NONE` (clamp to `[0, 1]`), `ACES`, `AGX` or `REINHARD` |
| `contrast` | 1 | Scale about linear mid-gray 0.18 |
| `saturation` | 1 | Scale about Rec.709 luma |
| `temperature` | 0 | White balance, blue to amber, `[-1, 1]` |
| `tint` | 0 | White balance, green to magenta, `[-1, 1]` |
| `lift` | `{ 0, 0, 0 }` | Per-channel lift |
| `gamma` | `{ 1, 1, 1 }` | Per-channel gamma |
| `gain` | `{ 1, 1, 1 }` | Per-channel gain |
| `lut` | none | `TextureId` of a single-mip RGBA8 3D texture; a null id selects no LUT |
| `lut_domain_min` | `{ 0, 0, 0 }` | Lower color bound the LUT covers, per channel |
| `lut_domain_max` | `{ 1, 1, 1 }` | Upper color bound; every channel above the minimum and finite |

The lookup maps `(c - min) / (max - min)` before the texel-center mapping `lut_scale(n) = (n - 1) / n`,
`lut_offset(n) = 0.5 / n`. The renderer folds the domain into those two values on the CPU. A unit domain gives the same
values as no domain.

### BloomParams

| Field | Default | Constraint |
| --- | --- | --- |
| `threshold` | 1 | Brightness where the glow starts; auto-exposed units under auto exposure |
| `knee` | 0.5 | Softness of the threshold |
| `intensity` | 0.05 | Scale of the added glow; bloom records only when positive |
| `levels` | 5 | 1 to `BLOOM_MAX_LEVELS` (8) |

### DofParams

| Field | Default | Constraint |
| --- | --- | --- |
| `focus_distance` | 5 | Meters; beyond `focal_length`. The focus in `MANUAL` mode and before `AUTO` meters anything |
| `focal_length` | 0.05 | Meters; positive |
| `aperture` | 2.8 | F-number; positive |
| `max_coc` | 16 | Half-resolution pixel radius; positive |
| `focus_mode` | `MANUAL` | `MANUAL` or `AUTO` |
| `focus_point` | `{ 0.5, 0.5 }` | Normalized image position, top-left origin; each axis in `[0, 1]` |
| `focus_radius` | 16 | Pixels metered around `focus_point`; finite and not negative; 0 reads one texel |
| `focus_time` | 0.25 | Seconds; finite and not negative; 0 snaps |

### MotionBlurParams

| Field | Default | Constraint |
| --- | --- | --- |
| `shutter` | 0.5 | Fraction of the rendered interval; not negative |
| `samples` | 12 | Taps per pixel, 1 to `MOTION_BLUR_MAX_SAMPLES` (32) |
| `max_velocity` | 32 | Pixels; positive |

### TaaParams

| Field | Default | Constraint |
| --- | --- | --- |
| `current_weight` | 0.1 | In `(0, 1]` |
| `clip_gamma` | 1 | Positive; width of the neighborhood variance box |
| `depth_tolerance` | 0.05 | Positive; relative to linear depth |
| `velocity_threshold` | 2 | Positive; pixels at which history starts to be rejected |
| `mip_bias` | -1 | In `[TAA_MIP_BIAS_MIN, 0]` (minimum -2); built-in material texture bias |
| `debug` | `NONE` | `VELOCITY`, `REJECTION` or `HISTORY_WEIGHT` shows a diagnostic image instead of color |

`TAA_SAMPLE_COUNT` (8) is the jitter cycle length. `TAA_HISTORY_SLOTS` (2) is the number of history images of each kind.

### AutoExposureParams

| Field | Default | Constraint |
| --- | --- | --- |
| `compensation_ev` | 0 | Stops added to the target |
| `min_ev` | -10 | Lower bound of the adaptation, stops; not above `max_ev` |
| `max_ev` | 10 | Upper bound, stops |
| `brightening_time` | 0.5 | Seconds; not negative. Time constant when the scene gets brighter |
| `darkening_time` | 2 | Seconds; not negative. Time constant when the scene gets darker |
| `low_percentile` | 0.1 | Lower edge of the metered window; below `high_percentile` |
| `high_percentile` | 0.9 | Upper edge, at most 1 |

Every field is finite. The metered log2 luminance that maps to each bound, `log2(0.18) + compensation_ev - ev`, stays inside
the histogram range, log2 -18 to 14.

## Faults

`create_view` and `configure_view` return these for the post stack.

| Fault | Cause |
| --- | --- |
| `INVALID_ARGUMENT` | `LINEAR_HDR` on a window view |
| `INVALID_ARGUMENT` | `LINEAR_HDR` on a target that is not `RGBA16_FLOAT` or `RGBA32_FLOAT` |
| `INVALID_ARGUMENT` | A selected LUT that is not a single-mip RGBA8 3D texture with one layer, or whose domain is not finite with minimum below maximum in every channel |
| `INVALID_ARGUMENT` | An enabled effect, or TAA while selected, with a parameter outside its constraint above |
| `INVALID_ARGUMENT` | `pre_exposure_override` that is neither zero nor a power of two within 2^-16 to 2^16 |
| `INVALID_ID` | A dead view, target or LUT |

Parameters of an effect that is off are not checked. `UNSUPPORTED` for multisampling and the other view-level faults are in
[views reference](views_reference.md#faults).

## Statistics

| Field | Meaning |
| --- | --- |
| `Stats.post_dispatches` | Compute dispatches of the post effects this frame |
| `Stats.gpu_post_stage_ms` | Completed time of each `PostStage`, summed over the frame's views |
| `Stats.vertex_history_bytes` | Previous vertex positions written for temporal views this frame |
| `ViewStats.exposure` | Applied exposure multiplier, `FRAMES_IN_FLIGHT` frames old under auto exposure |
| `ViewStats.pre_exposure` | Radiance scale of the last rendering's stored images |
| `ViewStats.focus_distance` | Applied depth-of-field focus in meters, `FRAMES_IN_FLIGHT` frames old under `AUTO` |

## Timings

With GPU timings, `Pass.POST_CHAIN` times the effects that run before the display composite. Related passes are
`Pass.EXPOSURE` (auto-exposure metering), `Pass.VELOCITY`, `Pass.TEMPORAL_AA` and `Pass.COMPOSITE`. The FXAA fragment pass
is timed under `COMPOSITE`.

With internal scopes, `POST_CHAIN` also has one stage scope per effect: `post.bloom`, `post.depth_of_field` and
`post.motion_blur`. `Stats.gpu_post_stage_ms`, indexed by `PostStage`, holds their completed times. They are parts of the
`POST_CHAIN` bucket and are not added to it. The grade, FXAA and identity-composite dispatches belong to the pass alone.
The depth-of-field stage covers its auto-focus metering and tile reduction, and the motion-blur stage its tile reduction.
See [benchmarking](benchmarking.md) and [profiling](profiling.md) for capture and the `effects --gpu-timings --benchmark`
mode.

Dispatch counts per effect:

| Effect | Dispatches |
| --- | --- |
| Bloom | `2 * levels - 1` |
| Depth of field | 6, plus 2 under `AUTO` focus |
| Motion blur | 3 |
| Auto exposure | 2 |
| Grade with FXAA | 1 on the direct route, 2 on the fallback route |

## Constants

| Constant | Value |
| --- | --- |
| `BLOOM_MAX_LEVELS` | 8 |
| `MOTION_BLUR_MAX_SAMPLES` | 32 |
| `TAA_SAMPLE_COUNT` | 8 |
| `TAA_HISTORY_SLOTS` | 2 |
| `TAA_MIP_BIAS_MIN` | -2 |
| `image::MAX_LUT_SIZE` | 64 |

## See also

- [Display processing](post.md).
- [Anti-aliasing](anti_aliasing.md).
- [Views reference](views_reference.md) for `ViewDesc`, view faults and counters.
