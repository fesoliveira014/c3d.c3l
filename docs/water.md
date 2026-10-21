# Water

Water uses the shared [frame origin](large_world.md), including mirror cameras,
scene-depth reconstruction, reflection marching and velocity. Supply the viewing
camera's absolute position in `FrameInfo.reference_position` before rendering
the mirror and main views. Wave evaluation and CPU surface queries keep their
existing local/absolute contracts; no simulation coordinates are shifted.

The `c3d_landscape` add-on's `c3d::landscape::water` module draws water bodies. A `Water` component on a node
is a Gerstner surface of up to four waves in the node's local XZ, drawn by the package's shader through a
custom material the library owns. The vertex stage displaces a grid and supplies the depth and velocity forms, and a
compute twin poses the grid for [scene traces](#scene-traces);
the fragment stage reads the scene's colour and depth snapshots after opaque (a scene-read material, see
[custom shaders](custom_shaders.md)), refracts what lies behind the surface, reflects from a
planar mirror target, else a screen-space march over the snapshot, else the environment or the frame's
ambient, adds lit foam, and shades sun glints through the public Standard parts. The body writes a core
[medium volume](sky.md#medium-volumes) that absorbs and scatters the light in the water, from above and from below,
and the surface seen from under it shows Snell's window and total internal reflection ([Underwater](#underwater)).
Ripple normals and foam colour
come from referenced Standard materials; the application's wind scrolls the ripples, and `set_sea_state` turns a
wind into the waves ([Sea state](#sea-state)). A CPU twin of the stage answers world-space height queries, and
`update_mirror` places a mirror camera per water body and viewing view for the reflection the application renders.
`WaterDesc.mode = OCEAN` draws the surface as a quadtree of chunks that each view selects, with waves anchored to the
world instead of the node ([Ocean](#ocean)). `WaterDesc.wave_model` chooses how a body's heights are computed:
`GERSTNER` by default, `SIMULATED` for a damped wave equation stepped on the CPU that ripples when the application drops
an impulse ([Simulated surface](#simulated-surface)), and `SPECTRAL` for a wind sea's spectrum, which a GPU module
evolves and transforms every frame ([Spectral surface](#spectral-surface)).

The module imports the standard library, core (`c3d`), `c3d::landscape` (its SPIR-V and hash helpers) and
`c3d::landscape::terrain` (a query predicate); it never imports `gpu`, `c3d::render` or `c3d::physics`. A second module
of the package, `c3d::landscape::water_gpu`, exists only under the `C3D_LANDSCAPE_GPU` feature and imports `c3d::render`
to record the spectral surface's passes ([Spectral surface](#spectral-surface)).
Buoyancy lives in the physics add-on ([buoyancy](buoyancy.md)); the application connects the two by installing
`fluid_sample` ([Buoyancy](#buoyancy)). Core never imports the module.

```bash
python3 scripts/build.py --example water
```

## Pending authoring

`attach_water(scene, assets, node, desc)` validates and attaches `Water` without
creating assets, a mesh or a mirror camera. It leaves the owner pending and
produces no generated draw. `is_prepared(scene, node)` reports readiness;
`prepare(scene, assets, node)` installs runtime atomically, and
`prepare_subtree(scene, assets, root = null)` attempts every pending water body
under the selected root. Publish world matrices before preparation.

Ordinary `update` skips pending water. `set_desc`, mirror placement and
runtime surface queries apply after preparation. `add_water` remains the combined
attachment-and-preparation entry. See the [landscape preparation contract](../addons/c3d_landscape.c3l/README.md#pending-authoring-and-preparation)
for failure, retry and shared-asset ownership.

## Select the package

Select `c3d_landscape` as for [terrain](terrain.md#select-the-package). Water needs nothing else; the example
and an application that installs `fluid_sample` on a physics world also select `c3d_physics` and `b3`. A `SPECTRAL`
body also needs the `C3D_LANDSCAPE_GPU` feature (`-D C3D_LANDSCAPE_GPU`) and the GPU dependencies the package's
other targets list; without it `prepare` faults `UNSUPPORTED` and water stays scene-layer code.

## Calling order

```c3
water::register_water(&scene, &assets)!;
physics::register_physics(&scene)!;
// ... the ground, then the lake node at the water level with a layer bit of its own ...
lake.layers = WATER_LAYER;
scene.update_world();
water::add_water(
    scene:  &scene,
    assets: &assets,
    node:   lake,
    desc:   desc,
)!;
physics.set_fluid_sampler(&water::fluid_sample, &lake_fluid);
// when the weather changes: the waves follow the wind over four seconds
water::set_sea_state(
    scene:              &scene,
    assets:             &assets,
    node:               lake.id,
    wind_velocity:      { wind.x, wind.z },
    transition_seconds: 4,
)!;

// every frame, after moving the cameras
scene.update_world();
// terrain::update(...) and foliage::update(...) as their docs order them
water::update(
    scene:         &scene,
    assets:        &assets,
    wind_velocity: wind,
    time:          now,
);
// with C3D_LANDSCAPE_GPU, inside the open frame, before prepare_scene_trace and any view that draws the water
renderer.begin_frame(info)!;
water_gpu::update(&renderer, &scene, &assets)!;
MirrorState mirror_state = water::update_mirror(
    scene:          &scene,
    body:           lake.id,
    slot:           0,
    viewing_camera: camera.id,
)!;
// the mirror view's clip plane, and no mirror view while mirror_state is BELOW (The mirror)
lake_fluid = { .view = water::surface_view(&scene, &assets, lake.id)!, .time = now, .current = current };
physics.update(delta);
scene.update_world();
// the mirror view first, then the view that shows the water (The mirror)
```

- `register_water` runs once per scene. It registers `Water`, `WaterRuntime` and `WaterMirror` and installs
  the runtime's remove hook with the store; the store outlives the scene.
- `add_water` attaches a water body to a node without `Mesh`, `Water` or `WaterRuntime` whose world matrix is
  current. It checks the desc, finds or adds the shared shader, finds or builds the grid, adds the owned
  material (double-sided, its reflection slot a view texture at `reflection_view_slot`), the child node of its
  [medium](#underwater), `max_mirrors` mirror camera nodes and the node's `Mesh` (an `InstancedMesh` for an
  [ocean](#ocean)), all or nothing: a fault leaves the node, the scene's free nodes and the store's free materials as
  they were.
- `set_desc` is the only way to change a water body. It checks the new desc before it writes anything: a fault
  keeps the old desc, the payload, the material revision, the mesh and the grid. `WaterRuntime.desc` holds the
  checked copy; `update`, the mirror and the queries read it, so an edit of `Water.desc` itself has no effect
  until it goes through `set_desc`. It ends a running sea-state blend, applies the desc's waves at once and writes
  the [medium](#underwater) again. An ocean keeps its `mode`, `extent` and `cell_size`, a simulated or spectral body its
  `extent` and `cell_size`, a spectral body its `spectrum` and every body its `wave_model`: a change faults
  `INVALID_ARGUMENT` and leaves the body as it was.
- `set_sea_state(scene, assets, node, wind_velocity, transition_seconds)` sets the waves from a wind
  ([Sea state](#sea-state)). It writes the target into `Water.desc` and `WaterRuntime.desc` and returns; the
  next `update` starts the blend. A `SPECTRAL` body takes it as a new spectrum ([Spectral surface](#spectral-surface)),
  after `prepare` only. It faults `UNSUPPORTED` for a `SIMULATED` body and for pending `SPECTRAL` water.
- `add_impulse(scene, node, world_position, radius, strength)` pushes a simulated body's surface down at a point
  ([Impulses](#impulses)).
- `update` runs every frame with the `FrameInfo.time` the frame renders with. It tears down removed water
  bodies, with their mirror cameras and medium nodes, scrolls the ripples, keeps each medium node on its body's layers,
  advances sea-state blends, steps simulated bodies, moves the clock and blend of spectral ones and re-anchors oceans
  whose node moved. It places no mirror and takes no camera; the material reads its reflection from a view texture,
  so no target is set on the body.
- `update_mirror(scene, body, slot, viewing_camera)` places the mirror camera of one slot of one body for one
  viewing camera ([The mirror](#the-mirror)) and returns `PLACED`, or `BELOW` when the viewing camera is under the rest
  plane and the mirror is not needed. It reads the camera's `local`, which must be a root node, so it
  may run before or after `update_world`; the body's world matrix is read as the last `update_world` left it.
- `release_mirror(scene, body, slot)` frees the slot's camera node, for a viewing view that goes away. The next
  `update_mirror` of that slot adds the camera again.
- `water_gpu::update(renderer, scene, assets)` records every spectral body's evolution and transforms into the open
  frame ([Spectral surface](#spectral-surface)). It exists under `C3D_LANDSCAPE_GPU`.
- `surface_view` copies a water body's waves and pose; take it after `update` and `set_desc`, before
  `physics.update`, so buoyancy follows a desc edit in the same frame.

## WaterDesc

`default_water_desc()` is a clear lake with two calm crossing waves (0.12 m at 6 m, 1.2 m/s along x; 0.07 m at
3.5 m, 0.9 m/s along (0.6, 0.8); steepness 0.5 each), `DEFAULT_CELL_SIZE`, no extent, the march on, one mirror slot, view texture 0 and no
references. Its `simulation` is `DEFAULT_WAVE_SPEED` (3 m/s) and `DEFAULT_DAMPING` (0.5/s), and its `spectrum` is
`DEFAULT_SPECTRUM_SEED`, `DEFAULT_PATCH_SIZE` (256 m) and `DEFAULT_CHOPPINESS` (1). Every rule below is a fault, not a contract: descs come from files as well as code.

| Field | Rule |
| --- | --- |
| `waves`, `wave_count` | At most `MAX_WAVES` (4). Per wave: amplitude ≥ 0, wavelength > 0, finite speed, a unit direction within 0.001, steepness ≥ 0. A `SIMULATED` or `SPECTRAL` body draws none of them |
| steepness | Σ steepness < `wave_count`: the mean steepness stays below 1 (one wave may pass 1 when others are lower) |
| `geometry` | Zero builds a grid; else a live geometry whose bounds lie at y = 0. An ocean takes none |
| `extent`, `cell_size` | A built grid only: both positive and finite, at most `MAX_GRID_CELLS` (512) cells per side, every wavelength at least two cells (a `SIMULATED` or `SPECTRAL` body has no wavelengths to check). An ocean: both positive and finite, at most `MAX_OCEAN_CHUNKS` (256) chunks of `cell_size * OCEAN_CHUNK_CELLS` per side, every wavelength at least four cells of the finest level (a `SPECTRAL` body has none to check) |
| `absorption_color`, `absorption_distance` | Transmittance after the distance, each channel in (0, 1]; the distance positive and finite. They set the [medium](#underwater)'s absorption; 1 on every channel is clear water, with no medium |
| `scatter_color` | Non-negative and finite: the single-scattering albedo of the medium, clamped to `MAX_SCATTER_ALBEDO` (0.98) |
| `roughness` | In [0, 1] |
| `refraction_strength`, `reflection_distortion` | Non-negative: screen uv per unit of normal tilt |
| `foam_depth` | Non-negative metres of water under which shore foam shows; 0 turns shore foam off |
| `foam_crest` | In [0, 1): the crest factor above which wave foam shows |
| `ripple_drift` | Non-negative: ripple scroll in m/s per m/s of wind |
| `ripples`, `foam` | Zero, or a live `STANDARD` material |
| `march_reflections` | The screen-space march in views that provide no reflection slot |
| `max_mirrors` | At least 1 and at most `MAX_MIRRORS` (8): the mirror slots, one per viewing view |
| `reflection_view_slot` | Below `material::MAX_VIEW_TEXTURES` (4): the [view texture](views.md#view-textures) the material samples |
| `trace` | Scene traces see the displaced surface, posed every frame ([Scene traces](#scene-traces)); off by default; an ocean cannot trace |
| `mode` | `BODY` (default) or `OCEAN` ([Ocean](#ocean)) |
| `depth` | Positive and finite metres below the rest plane (`DEFAULT_WATER_DEPTH`, 40 m, by default): where the [medium](#underwater)'s box ends. Water not deeper than its troughs has no medium |
| `wave_model` | `GERSTNER` (default), `SIMULATED` or `SPECTRAL` ([Wave models](#wave-models)). Without `C3D_LANDSCAPE_GPU`, `prepare` faults `UNSUPPORTED` for `SPECTRAL` |
| `simulation` | Read by `SIMULATED`: `wave_speed` in m/s and `damping` in 1/s, each positive and finite. `SIMULATED` is refused (`INVALID_ARGUMENT`) with `OCEAN`, with application geometry, with fewer than `MIN_SIMULATION_CELLS` (16) or more than `MAX_SIMULATION_CELLS` (256) cells per side, and where `wave_speed` needs more than `MAX_SIMULATION_SUBSTEPS` (8) substeps per fixed step ([Stepping](#stepping)) |
| `spectrum` | Read by `SPECTRAL`: `patch_size` positive and finite metres per tile, `choppiness` non-negative and finite, and a `seed` of any value ([Spectral surface](#spectral-surface)) |
| `ground` | Zero, or a node carrying `Terrain`: the terrain whose high ground a `SIMULATED` body treats as dry ([Dry cells](#dry-cells)). A dead node faults `INVALID_ID`, a node without `Terrain` `INVALID_ARGUMENT` |

## Surface geometry

A built grid has `ceil(extent / cell_size)` cells per side centred on the node, a position and a +Y normal per
vertex, two counter-clockwise triangles per cell facing +Y (the material draws both faces), and is shared per shape
through the store key `c3d_landscape/water_grid/<extent>/<cell_size>` with both values as exact hex floats (120 m at 1.25 m is
`c3d_landscape/water_grid/0x1.ep+6/0x1.4p+0`). A grid stays in the store for the store's lifetime when no body
uses it any more. Past 254 cells per side (65,535 vertices) the renderer switches to 32-bit indices: 120 m at
1.25 m is 9,409 vertices and 55,296 16-bit indices. The normals stream is not read by the drawn surface, which
computes its own; it carries the posed normals of a [traced](#scene-traces) body.

Application geometry rests at y = 0; its topology and UVs are its own, and it follows the aliasing rule
(shortest wavelength at least twice its edge length) by itself. Either way the stage writes `uv0` and `uv1` as
the rest position in metres.

An [ocean](#ocean) draws instances of one shared unit chunk instead of a grid. For a body, `Mesh.local_bounds` is the
rest bounds grown by the total amplitude in y and by the sum of the waves' horizontal crest shifts in x and z, always
as a bounds override; a `SIMULATED` body grows it by `SIMULATION_MAX_HEIGHT` in y alone, and a `SPECTRAL` body by its
envelope in y and its choppiness times the envelope in x and z ([Bounds and the twin](#bounds-and-the-twin)). The mesh casts no shadow, receives shadows and
traces only with `WaterDesc.trace` ([Scene traces](#scene-traces)).

## Wave models

`WaterDesc.wave_model` says how the surface's heights are computed. It is separate from `mode`, which says which
geometry carries them, and a body keeps its model: `set_desc` faults `INVALID_ARGUMENT` on a change.

| Model | Surface | Agrees with its CPU twin within |
| --- | --- | --- |
| `GERSTNER` | `waves`, summed in the vertex stage ([Waves](#waves)) | 1 cm, `residual` reporting the inversion's remaining step |
| `SIMULATED` | A damped wave equation over the built grid ([Simulated surface](#simulated-surface)) | 1 cm: the twin reads the grid the stage draws, so only float rounding separates them, and `residual` is 0 |
| `SPECTRAL` | A JONSWAP sea, evolved and inverse-transformed on the GPU ([Spectral surface](#spectral-surface)) | The bound `WaterRuntime.spectral_bound` reports, a statistical contract: exceeded at about 0.3 % of points |

A `SPECTRAL` body is accepted as pending authoring without the `C3D_LANDSCAPE_GPU` feature, and its `spectrum` fields
are kept, saved and loaded, but `prepare` faults `UNSUPPORTED` there. `waves` stays the `GERSTNER` array: the other
models ignore it.

## Waves

For a rest point `p` in the node's local XZ and shader time `t`, per wave `i` with unit direction `d`,
wavelength `λ`, speed `c`, amplitude `a` and steepness `s` over `N` waves:

- `θ = 2π · fract(dot(d, p) / λ − t · c / λ + φ)`: the phase is reduced to one cycle before `sin` and `cos`, whose
  precision GLSL specifies only near [−π, π]; `φ` is the wave's phase offset in cycles, zero until a
  [sea state](#sea-state) sets one;
- height `y = Σ a · sin θ`; horizontal shift `D = Σ s · λ / (2π · N) · d · cos θ`;
- drawn point `(p.x + D.x, y, p.y + D.y)`; the normal from the Jacobian of that map; the crest factor
  `clamp(1 − det J, 0, 1)` feeds wave foam.

The waves of a `BODY` are node-local: node scale scales wavelengths and amplitudes, node rotation turns the
directions. An [ocean](#ocean) evaluates the same sum on the node-local rest position, with `φ` carrying the node's
absolute position, so its crests stay where they are in the world when the node moves.

## Height queries

```c3
SurfaceView view = water::surface_view(&scene, &assets, lake.id)!;
float height = water::sample_surface(
    view:    &view,
    world_x: x,
    world_z: z,
    time:    now,
)!;
```

`surface_view` copies the packed waves the stage reads, bit for bit, and the node's pose; it faults
`INVALID_ID` for a dead node, a node without a water body or a removed owned material, and requires a node with
translation and rotation about Y only. `sample_surface` returns the world height of the drawn surface on the
vertical through a point: it inverts the horizontal shift with fixed-point steps `p ← q − D(p)` until a step is
shorter than `WATER_QUERY_TOLERANCE` (0.1 mm) or `MAX_INVERSION_ITERATIONS` (8) steps have run, then evaluates
the height with the stage's float operations. A point whose rest position falls outside the rest rectangle is
`NOT_FOUND`. The view is a value: several threads may query it.

The steps converge while the mean steepness stays below 1, which validation enforces. With `k` the mean
steepness, the rest point a query returns is within `residual · k / (1 − k)` of the true one, and the height
within the waves' height slope `Σ a · 2π / λ` times that. `WaterSample.residual` is the length of the last step
in metres. Any query can stop at the cap before it reaches the tolerance, whatever the steepness; its residual
then says how far it stopped, and the bound above covers both cases. The drawn surface of a `GERSTNER` body agrees
with `sample_surface` within 1 cm; the device test checks it.

## Surface detail

```c3
WaterSample sample = water::sample_surface_detail(
    view:    &view,
    world_x: x,
    world_z: z,
    time:    now,
)!;
```

`sample_surface_detail` returns, with the same inversion and the same faults as `sample_surface`, the world
`height` (equal to `sample_surface` bit for bit), the unit `normal`, the `velocity` of the surface point in
metres per second and the inversion's `residual`. The normal and the velocity are analytic derivatives of the
drawn map at the inverted rest point `p`, in the node's frame turned to world space: the tangents are `∂P/∂p.x`
and `∂P/∂p.y`, the normal is the normalised cross product of the second with the first, as the stage computes
it, and the velocity is `∂P/∂t` at fixed `p`, the orbital velocity of the water at that point. For a wave with
phase rate `ω = 2π · c / λ`, the point moves by `(s · λ / (2π · N) · d · sin θ · ω, −a · cos θ · ω)` per second.

The kinematic condition `velocity.y − velocity.xz · ∇h = ∂h/∂t` holds against central differences of
`sample_surface`, and the normal is parallel to `(−∂h/∂x, 1, −∂h/∂z)`. During a sea-state blend the velocity is
that of the blended waves at the frame, not the rate at which the blend itself reshapes the surface.

## Time

The stage reads `FrameInfo.time` as a float (`frame.jitter_time.z`, and `frame.previous_time` in the velocity
form). `sample_surface` and `update` take the same `double` time and narrow it exactly as the frame root does,
so queries see the time the surface is drawn at. From 65,536 s (about 18 h) a float time rounds to within
1/256 s and consecutive times differ by up to 1/128 s; an application that runs that long wraps its clock and
calls `render::reset_view_history` at the wrap. The phase reduction keeps the waves exact at any time. The phase
itself is `t · c / λ` in float, so the waves' motion at large times has the float spacing of that product: at 1,000 s
and 0.1 cycles per second the phase is good to about 8 × 10⁻⁶ cycles. A core frame time split would lift this limit;
the stage, the queries and the offsets of a [sea state](#sea-state) all carry it.

## Ripples and wind

The ripple reference is a `STANDARD` material whose normal map the stage samples twice, through the reference's UV
transform, sampler and `normal_scale`, and sums the two perturbations of the wave normal. Its other maps cost their
fetches and are ignored. The first layer samples at `uv0` plus its scroll offset. The second samples at
`RIPPLE_SECOND_SCALE · R(RIPPLE_CROSS_ANGLE) · uv0` plus its scroll offset: `uv0` turned by `RIPPLE_CROSS_ANGLE` and
scaled by the golden ratio, so the two tilings never realign and the map's repeat shows no lattice. The second layer's
mip level follows its finer tiling. `update` turns the wind into two node-local scroll velocities. The first is the
wind in the node's frame times `ripple_drift`. The second makes the second layer's pattern move at the first's speed
in metres, along the first's direction turned by `RIPPLE_CROSS_ANGLE`: it is the first velocity turned by twice
`RIPPLE_CROSS_ANGLE` and scaled by `RIPPLE_SECOND_SCALE`. The stage computes
`offset = scroll_origin + scroll_velocity · (time − scroll_time)`; when the velocities change, `update` starts a new
segment at the frame time whose origin is the old segment's offset there, wrapped to whole texture periods, so the
ripples never jump. A steady wind and a still node write nothing: a steady frame uploads nothing for water.
`update`'s wind scrolls the ripples only; the waves follow `set_sea_state`, and buoyancy follows the waves.

**Roughness from the map's mips.** A minified ripple map averages slopes that the specular lobe would otherwise alias
into specks, so the stage widens the lobe by what the mip filter averaged away. For each layer it reads the normal map a
second time, raw, through the same slot, UV transform and sampler, so the hardware picks the same mip, and takes the
length `ℓ` of `2 · rgb − 1`, clamped to (0, 1]. A mip of diverging normals decodes shorter than 1, and the shortening
estimates the slope variance the filter removed (Toksvig's filter through `s = 2 / α² − 2`). With `α` the GGX alpha of
`roughness` (`roughness²`), each layer adds `2 · (1 − ℓ) / ℓ · normal_scale²` to `α²`:

- `normal_scale` squares because the stage scales the tangent slope by it, and a slope scaled by `k` has `k²` the
  variance;
- the layers add because `normalize(first + second − wave_normal)` sums their tangent slopes to first order, and they
  sample the map at incommensurate scales and turns, so their variances are independent.

The specular roughness becomes `(α² + variance)^¼`, at most 1, for the lights and the environment specular. The foam
keeps its own roughness, and refraction, reflection distortion and the wave normal are unchanged. A body without a
ripple reference, or one whose `normal_scale` is 0, widens nothing. The cost is two more fetches per fragment at the
texels the ripple fetches read, and about a dozen arithmetic operations.

What the map must be: the length exists only in the stored vectors, so the ripple map has `COLOR` semantics (the
example's does, by design) with a linear encoding of `0.5 + 0.5 · n`, in `RGBA16_FLOAT` or `RGBA32_FLOAT`.

- A `NORMAL_RGB` map renormalizes its mips and a `NORMAL_RG` map rebuilds the third component, so both read `ℓ = 1` and
  widen nothing: that is why a `NORMAL_*` ripple map sparkles more than a `COLOR` one.
- An sRGB map is not a valid ripple map: the sampler decodes it non-linearly before the stage reads it.
- `RGBA8_UNORM` cannot carry the length. Rounding the third component moves it by up to `2 / 255`, which reads as a
  shortening of 0.8% in random texels at every mip, a variance of up to 0.016 per layer and a roughness of up to 0.35,
  and the real shortening of gentle ripples is smaller than that: the example's map shortens by about 0.3% where it
  is fully minified. `NORMAL_RGB` semantics renormalize its mips, so minification shortens nothing, but the stored
  vectors are still rounded to 8 bits and that rounding remains: the format does not suit a ripple map under either
  semantics.
- A shortening under `RIPPLE_LENGTH_TOLERANCE` in `water.frag.glsl`, 0.0005 or one half-float step of the decoded
  vector, reads as none, so the rounding of a half-float map adds nothing at the finest mips.

## Sea state

`set_sea_state(scene, assets, node, wind_velocity, transition_seconds)` sets a water body's four waves to the sea a
wind raises. `wind_velocity` is world metres per second along x and z, and the waves travel along it. It faults
`INVALID_ID` for a dead node, a node without `Water`, or pending water whose application geometry was removed, and
`INVALID_ARGUMENT` for a non-finite wind or a negative or non-finite transition. A zero transition switches at the
next `update`. The call needs no time: it writes the target into `Water.desc.waves` and `WaterRuntime.desc.waves`
(`wave_count` becomes `MAX_WAVES`) and marks the blend as starting. The store resolves the rest rectangle of pending
water, so a pending body gets the same sea as its prepared twin. Water that is still pending only receives the target
in `Water.desc`. A saved scene keeps the target; the blend is not saved, so a loaded body starts at its target.

**The table.** The sea is fetch-limited. The fetch `F` is the length of the rest rectangle through its centre along
the wind, in world metres with the node's scale included; the rectangle is the built grid's or the application
geometry's. With `U` the wind speed (clamped to 25 m/s) and `g` = 9.81 m/s², the standard
JONSWAP relations give the significant height `Hs` and the peak period `Tp`, each capped at its fully developed
Pierson-Moskowitz value:

- `g · Hs / U² = min(1.6 × 10⁻³ · (g · F / U²)^½, 0.21)`;
- `g · Tp / U = min(0.286 · (g · F / U²)^⅓, 2π / 0.877)`;
- the peak wavelength is the deep-water `λp = g · Tp² / 2π`.

The caps are reached at `g · F / U²` of about 17,000 and 16,000: at 14 m/s a fetch of about 340 km. A 120 m lake at
14 m/s has `Hs` 0.08 m and `λp` 0.9 m, and a 2 km body `Hs` 0.32 m and `λp` 5.6 m. Four bands sit relative to
`Hs` and `λp`:

| Band | Wavelength | Amplitude | Direction off the wind |
| ---: | ---: | ---: | ---: |
| 0 | 1 × peak | 0.25 × height | 0° |
| 1 | 0.5 × peak | 0.18 × height | +20° |
| 2 | 0.25 × peak | 0.12 × height | −30° |
| 3 | 0.125 × peak | 0.08 × height | +45° |

The squares of the amplitude shares sum to 0.116, near the 1/8 four sine waves carry of a sea of that height. Each wave
runs at the deep-water speed `√(g λ / 2π)` and has the steepness that makes its crest shift twice its amplitude, the
ratio of the default calm waves, at most 0.9 so the mean steepness stays below 1 at any fetch. Wavelengths floor at two
cells of a built grid, four cells of an ocean's finest level, else at 1 m, so the written target is always a valid
desc. A band whose wavelength falls below the floor is drawn at the floor and keeps its amplitude, so a small body
gets waves of the grid's shortest length and a few centimetres of height. The sea is sized in world metres: the node's
scale is divided out of the written lengths and amplitudes, so a scaled node draws the same sea. The heading is the
wind in the node's frame.

**The blend.** `update` advances it. Amplitude, wavelength, speed and steepness blend linearly from the set drawn
when `set_sea_state` ran, with each direction turned along the shorter arc. The mean steepness of the blend stays
below 1 because it is a convex combination of two valid sets. A body with fewer than four waves blends to four:
the waves it did not have start at amplitude 0, and the leaving waves' steepness is rescaled by `4 / wave_count` so
the crest shift they carry, which `1 / wave_count` bakes in, does not jump. A second call during a blend starts a
new one from the set drawn then. `Mesh.local_bounds` and the mirror clip plane follow the largest of the leaving and
target values per wave while a blend runs, and the target's own when it ends.

**Phase continuity.** The stage evaluates each wave's phase as `dot(d, p) / λ − t · c / λ + φ`, with `φ` the wave's
`phase_offset`. Outside a blend `φ` is constant, nothing uploads, and the precision is that of a body without a sea
state. During a blend a changing speed and wavelength would jump a phase that is an absolute `t · c / λ`, so `update`
integrates each wave's phase in double, `phase += dt · (c / λ)` averaged over the step, and uploads the blended
waves with the `φ` that makes the stage's phase at the frame time equal the integrated one. When the blend ends the
last `φ` stays: it continues the integrated phase at the target speed, so the time phase never jumps. The integration
starts from the phase the stage draws at the first `update` of the blend. Queries read the same `φ` and time, so a
sample at `time + step_offset` extrapolates linearly from the frame's waves, as the stage would draw it. The traced
surface runs the stage's code and agrees in and out of a blend.

The stretch limit: a changing wavelength stretches the pattern about the node origin, because `dot(d, p) / λ` scales
with the distance. An [ocean](#ocean) keeps its pattern anchored at its node through a blend, so the stretch centres on
the node and not on the world origin. A point at distance `r` sees `r · |1/λ_from − 1/λ_to|` extra crests pass during
the blend, so the per-frame height step grows with the distance from the node origin, and a longer
`transition_seconds` spreads it over more frames. Near the origin the step is the motion of the waves themselves. The
wavelength blends linearly: blending `1/λ` linearly steps further.

**Motion vectors.** `WaterParams` also holds the waves of the update before, and the velocity form draws a rest
point at the previous frame's time with them: during a blend the vectors are the reprojection of the surface that
was drawn, not of the new waves at the old time. Outside a blend the two sets are equal. A view that is not
rendered every frame reads a previous set newer than its previous time, for the frames of a blend only.

**Uploads.** An `update` uploads the block while a blend runs, including its first, and once more after the frame
that reaches the target, so the previous waves catch up with the current ones. After that a steady frame uploads
nothing for water ([Ripples and wind](#ripples-and-wind)). `set_desc` ends a blend: it applies the desc's waves at
once, keeps each wave's `φ`, and copies the waves into the previous set.

## Simulated surface

`wave_model = SIMULATED` draws the heights `u` of a damped wave equation `u_tt = c² ∇²u − γ u_t` on the vertices of
the built grid, with `c` the `simulation.wave_speed` and `γ` the `simulation.damping`. The heights are node-local
metres above the rest plane, stepped on the CPU, so buoyancy and queries read exactly what is drawn.

```c3
WaterDesc desc = water::default_water_desc();
desc.wave_model = SIMULATED;
desc.wave_count = 0;
desc.extent = 120;
desc.cell_size = 1.25f;
desc.simulation = { .wave_speed = 8, .damping = 0.3f };
desc.ground = ground.id; // optional: the terrain whose high ground is dry
water::add_water(
    scene:  &scene,
    assets: &assets,
    node:   lake,
    desc:   desc,
)!;
// at any point of the frame: a push at a world point
water::add_impulse(
    scene:          &scene,
    node:           lake.id,
    world_position: point,
    radius:         3,
    strength:       10,
)!;
// once per frame, as for every body: it steps the grid and uploads it
water::update(
    scene:         &scene,
    assets:        &assets,
    wind_velocity: wind,
    time:          now,
);
```

- **Grid.** The lattice is the built grid's vertices: `ceil(extent / cell_size)` cells per side, at least
  `MIN_SIMULATION_CELLS` (16) and at most `MAX_SIMULATION_CELLS` (256), at `extent / cells` metres. A simulated body takes
  no ocean and no application geometry. The state is allocated at `prepare` and freed with the body: three float
  arrays and a mask, 66,049 vertices at most.
- **Stepping.** `update` accumulates the frame's time and runs whole fixed steps of `1 / SIMULATION_RATE` (60 Hz), so
  the stepped state follows the simulated time and not the frame rate. A step runs the substeps the CFL bound needs,
  `ceil(c / (SIMULATION_RATE · CFL_LIMIT · spacing))` with `CFL_LIMIT` 0.5 under the five-point stencil's stability
  limit of 0.707; `check_desc` refuses a speed or a spacing that needs more than `MAX_SIMULATION_SUBSTEPS` (8). Each
  substep adds the stencil's force to every wet vertex's speed, scales the speed by `exp(−γ · dt)` and moves the height
  by the speed (leapfrog). At most `MAX_SIMULATION_STEPS_PER_UPDATE` (4) steps run per update and the time beyond them
  is dropped, so a hitch slows the ripple and cannot spiral. The first `update` of a body only reads the time.
- **Drawn heights.** The stage draws the last two steps interpolated by the share of a step the accumulator holds:
  `prior + (height − prior) · fraction`. They go to an `RGBA32_FLOAT` store texture of `(cells + 1)²` texels that the body
  owns, the red channel this frame's drawn heights and the green channel the previous frame's, so motion vectors are
  per frame (the store has no two-channel float format; blue and alpha are unused). An awake frame rewrites the texture
  in place and marks it dirty, 16 bytes per vertex: 150,544 bytes for the 120 m lake at the default cell size and
  1,056,784 at 256 cells. The GPU image is created once.
- **Vertex stage.** A simulated vertex `texelFetch`es its own texel, found from its vertex index, with no filtering.
  Its normal is the normalised `(−∂u/∂x, 1, −∂u/∂z)` of the neighbouring texels' central differences, one-sided at the
  grid's edges, and its previous position comes from the green channel. There is no crest factor, so no wave foam;
  shore foam works as for any body. The [trace pose](#scene-traces) fetches the same texture, so a traced body follows
  the ripple.
- **Walls.** The grid's edges and its dry cells reflect like the walls of a pool: a wet vertex counts a neighbour that is
  past the edge or dry as its own height. There is no sponge layer.
- **Bound and reach.** Heights are clamped to `±SIMULATION_MAX_HEIGHT` (1 m), and that clamp takes the place of the
  Gerstner amplitude in `Mesh.local_bounds`. The [medium](#underwater)'s offset and the mirror's clip plane follow the
  body's reach instead: the largest height magnitude since it woke (`SimulationState.reach`), 0 for a calm pond and again
  after it settles. A step that raises the reach writes the medium node again, so a calm pond is fogged from its
  surface, and a ripple moves the box's top and the clip plane down to the deepest trough it has drawn and no further.

### Dry cells

With `ground` set, a vertex is dry where the terrain's height under it is at or above the body's rest plane (the world
height of the node), and a vertex off the terrain's extent is wet. A dry vertex holds zero height and speed, draws
flat under the ground and acts as a wall. The mask is built at `prepare` from `terrain::height_view`, so the terrain
is prepared first; a body prepared before its ground gets the mask on the first `update` that finds the terrain
prepared. `update` follows edits: it re-masks only the vertices a `terrain::refreshed_since` rectangle covers (reported
through `terrain::mark_dirty`), and the whole grid when the terrain gives no rectangle for the revision or when either
node moved. A `ground` that has died, lost its `Terrain` or `TerrainRuntime`, or tilted drops the mask: every vertex is
wet again until a usable ground returns. Wet vertices keep their heights through a re-mask; the ones that turn dry are
zeroed.

### Settling

A body settles when every wet vertex has `|u| < SETTLED_HEIGHT` (0.5 mm) and `|u_t| < SETTLED_SPEED` (2 mm/s). The
grid then snaps to rest, one more upload draws it exactly flat, and stepping and uploads stop: a settled body costs
the ground check per `update` and uploads nothing, and `add_impulse` wakes it. Damping above `2π · c / extent`, the lowest
standing wave's critical value, slows the decay of the long waves instead of speeding it: a pond settles fastest near
that value.

### Impulses

`add_impulse(scene, node, world_position, radius, strength)` lowers the speed of the wet vertices within `radius`
metres of the point by `strength · (1 − q²)²` m/s, with `q` the distance over the radius, so `strength` is the downward
speed at the centre of a smooth bump. The sum of the push is returned to the rest of the surface as a uniform rise in
speed, so the body returns to its rest level instead of keeping a dent. It wakes the body. It faults `INVALID_ID` for a
dead node, a node without prepared water or a body that is not `SIMULATED`, and `INVALID_ARGUMENT` for a position that is
not finite, a radius that is not finite and positive or a strength that is not finite or is negative. A point whose
bump meets no wet vertex, and a strength of 0, do nothing. The node carries no scale: radii are world metres.

### Queries

`surface_view` of a simulated body borrows its grid: the view answers the surface of the last `update` until the body
is removed, so take it after `update` and use it on the thread that steps, unlike the value views of the other
models. `sample_surface` and `sample_surface_detail` ignore `time`. They interpolate the drawn heights on the
mesh's own triangles, the diagonal from `(x + 1, z)` to `(x, z + 1)` of each cell, so the answer is the drawn surface.
`normal` blends the three vertices' normals as the rasteriser does, `velocity` is vertical and is the slope in time of
the interpolation, `(u − prior) / dt`, and `residual` is 0. A point off the grid is `NOT_FOUND`. `fluid_sample` works
unchanged.

## Spectral surface

`wave_model = SPECTRAL` draws a wind sea from a spectrum of waves. The heights come from a field of `SPECTRAL_SIZE²`
(256²) texels that the GPU evolves to the frame's time and inverse-transforms, so every texel is a sum of up to 65,536
waves, and the vertex stage samples the field, tiled across the body. The module that records the passes,
`c3d::landscape::water_gpu`, exists under the `C3D_LANDSCAPE_GPU` feature; the scene-layer module keeps the spectrum, the
CPU twin and the bounds, and never imports `gpu` or `c3d::render`.

```c3
// build with -D C3D_LANDSCAPE_GPU
WaterDesc desc = water::default_water_desc();
desc.wave_model = SPECTRAL;
desc.wave_count = 0;
desc.mode = OCEAN;
desc.extent = 20000;
desc.spectrum = { .seed = 7, .patch_size = 256, .choppiness = 1 };
water::add_water(
    scene:  &scene,
    assets: &assets,
    node:   sea,
    desc:   desc,
)!;
water::set_sea_state(
    scene:              &scene,
    assets:             &assets,
    node:               sea.id,
    wind_velocity:      { 12, 0 },
    transition_seconds: 4,
)!;
// every frame: water::update(...) first, then inside the open frame
renderer.begin_frame(info)!;
water_gpu::update(&renderer, &scene, &assets)!;
// prepare_scene_trace, then the views that draw the water
```

- **Spectrum.** The sea follows the wind and fetch relations of the [sea state](#sea-state): the same `Hs` and `Tp` for a
  wind over the rest rectangle's chord, which is the built grid's, an ocean's or the application geometry's bounds. Its
  frequency shape is JONSWAP (peak enhancement 3.3, widths 0.07 and 0.09) normalised to `Hs / 4` of height deviation,
  spread by cosine squared about the wind over the half plane it travels into, with deep-water dispersion
  `ω = √(g k)`. The spectrum is built on the lattice of wave vectors `2π · (n, m) / patch_size`, in the node's local
  frame: its heading is the wind in that frame and node scale scales the surface with it. The lattice samples a narrow
  peak coarsely, so the amplitudes are scaled until their variance is the share of the sea's that the lattice and the cut
  leave in band: the height deviation stays `Hs / 4` however the patch falls on the peak. A fetch the body's size limits
  gives a small sea, as for the four waves: a 120 m lake at 20 m/s has `Hs` 0.11 m and `λp` 1 m.
- **Band.** Components with a wavelength under four texels (`patch_size / 256` each) are dropped, because the field's
  bilinear sampling holds them badly; a built grid also drops wavelengths under two cells, an ocean under four cells of
  its finest level, so a drawn vertex never carries a wave its lattice aliases. The default `patch_size` of 256 m keeps
  waves from 4 m, and a patch should hold several peak wavelengths.
- **Gaussians and the seed.** Each texel's amplitude is a pair of unit normal values from `spectrum.seed` by a PCG hash
  and Box-Muller, times the amplitude the spectrum gives it, so the same seed always draws the same sea and another
  seed another. The pairs are uploaded once, in a 1 MiB `RGBA32_FLOAT` table image; its other two channels hold the
  amplitudes of the spectrum a blend leaves and of the one it reaches.
- **Time.** A component's frequency is rounded to a whole number of cycles of `SPECTRAL_PERIOD` (1,000 s), so the field
  repeats exactly after it and the phase of any time is `fract(steps · fract(t / 1000 s))`, good to a milliradian at any
  time and with no float growth. The rounding moves a frequency by at most 3 mrad/s.
- **Passes.** `water_gpu::update` records `DISPATCHES_PER_BODY` (18) compute dispatches for each spectral body, once per
  frame, whatever the number of views: the evolution `h(k, t) = h0(k) e^(−iωt) + conj(h0(−k)) e^(iωt)` and its derived
  fields; an inverse radix-2 Stockham transform of three complex fields, eight dispatches along x and eight along z;
  and a split into the displacement `(dx, dy, dz)` with choppiness `λ`, the slope along x and z and the displacement of
  the frame before. The fields pack as `height + i·dx`, `dz + i·slope_x` and `slope_z`, so three complex transforms
  carry the five real ones. The stages are one set of compute shaders per store, added on the first call under
  `c3d_landscape/water_spectrum_*`.
- **Images.** The body owns seven store textures made at `prepare`: the table, the displacement, its previous frame and
  the slope as `RGBA16_FLOAT` 256² images of 0.5 MiB each, and four `RGBA32_FLOAT` 1 MiB work images. That is 6.5 MiB
  of device memory a body; the store has no one-channel float format, so the table and the work images spend four
  channels. The displacement image is rewritten in place and its previous frame kept by the split pass, so no material
  slot swaps.
- **Vertex stage.** A vertex samples the displacement and slope at `local_xz / patch_size` (plus half a texel, so a
  texel centre is its lattice point) with a repeating linear sampler, so the tiles of the field meet at the patch edge
  and a body or an ocean wider than the patch repeats it. The drawn point is `(x + dx, dy, z + dz)`; the normal is
  `(−slope_x, 1, −slope_z)` normalised, without the horizontal map's Jacobian; the motion vector comes from the
  previous image sampled at the same coordinates. There is no crest factor, so no wave foam. The [trace
  pose](#scene-traces) samples the same images, so a traced surface follows the field and the frame's passes run before
  `prepare_scene_trace`.
- **Ocean.** An [ocean](#ocean) samples the field at coordinates anchored to the world: the fraction of
  `inverse(node) · position / patch_size`, folded in a double each time the node moves, so crests stay in the world as
  the node follows the camera, as for the four waves. Every level samples the finest field: a vertex coarser than the
  waves it samples under-resolves them, and the farthest levels shimmer where the four-wave stage fades its short waves
  by level.
- **Sea state.** `set_sea_state` builds the amplitudes of the new wind and fetch from the same Gaussians. The spectrum
  reached so far (the blend of the two sides by its share now) becomes the left side of the table, the new one the right,
  the share restarts at zero and the 1 MiB table is uploaded once. Every frame the evolution mixes the two sides by the
  share, which `update` advances over `transition_seconds`, so a transition is continuous, phase-consistent and costs
  no upload per frame: the alternative of rebuilding the spectrum on the CPU each frame would upload 1 MiB a frame
  for a transition's length. A second call during a transition starts from the state drawn then. Without a sea state the
  wind is `DEFAULT_SPECTRAL_WIND` (8 m/s along local +X); the call needs prepared water and faults `UNSUPPORTED` on pending
  water, since the wind lives in the prepared state.
- **First frame.** The images hold nothing until the first `water_gpu::update` writes them. Call it before the first view
  that draws or traces the body; its first frame has no motion (the previous image is the current).

### Bounds and the twin

The CPU twin keeps the `SPECTRAL_TWIN_WAVES` (64) strongest components of the spectrum, ranked by the variance each
adds, as Gerstner terms: a component with wave vector `k`, amplitude `A`, phase `φ` and choppiness `λ` draws
`A cos(k·x − ωt + φ)` and shifts the point by `−λ A sin(…) · k̂`, which is a wave of the Gerstner form with the crest shift
`λ A`. `surface_view` copies them into the view, so `sample_surface`, `sample_surface_detail` and `fluid_sample` run the
converged inversion of [Height queries](#height-queries) over them, with the repeat period folding the time. A query
sums 64 components in each of up to eight inversion steps, so it costs about the ratio of the component counts more than
the four waves'; `SPECTRAL_TWIN_WAVES` is the lever, and a smaller count also widens the bound. A
`SurfaceView` therefore holds 64 waves of 32 bytes and is 2,208 bytes for every model, and stays a value several threads
may query. The normal is the twin's Jacobian normal, a little steeper than the drawn slope-only normal.

`WaterRuntime.spectral_bound` is the standard deviation of the omitted components' height, which the twin does not
carry, times `SPECTRAL_BOUND_SIGMAS` (3). It is computed at `prepare` from the realised amplitudes and again at each
`set_sea_state` (over the larger of the two sides, so it bounds every state of the blend) and when a blend ends, and it is
zero for another model. **The contract is statistical**: the drawn surface differs from `sample_surface` by more than
the bound at about 0.3 % of points, where the omitted waves add up against the twin, and by less than the bound plus the
resolution of the field (half-float storage, bilinear sampling and the triangles between vertices) elsewhere. The
`GERSTNER` and `SIMULATED` contract of 1 cm is not kept: sixty-four components of a sea over a 65,536-texel lattice
carry its larger part and no more, so the bound is the honest measure and it grows with the sea; narrower spectra
(a patch near the peak wavelength, a cut that leaves few lattice vectors) leave a small bound, and a wholly represented
spectrum reports 0.

`SPECTRAL_ENVELOPE_SIGMAS` (5) times the spectrum's height deviation is the envelope of the height: the bound of
`Mesh.local_bounds` and of an ocean's node boxes (with its choppiness times it in x and z), and the reach that sets the
[medium](#underwater)'s offset and the mirror's clip plane. It follows the spectrum the way the sea state does: while a
blend runs it spans the larger of the two sides, and when the blend ends it falls to the new sea's, so a calm sea after
a storm leaves the medium's top `MEDIUM_SKIN` under the rest plane and not under the storm's troughs. The field repeats,
so its 65,536 texels are every height the body draws (a bilinear sample stays between them), and the deepest of that many
Gaussian samples is about `√(2 ln 65,536)` = 4.7 deviations: five spans it, though a seed whose deepest texel lies past
five can pass the envelope. `Mesh.local_bounds` are what culling and shadows read.

## Ocean

`WaterDesc.mode = OCEAN` draws a sea that reaches the horizon. The body is an `InstancedMesh` quadtree under
[box ranges](instancing.md#box-ranges), like the [terrain](terrain.md) of the same package: every node is an instance
of one shared unit chunk of `OCEAN_CHUNK_CELLS` (64) cells per side, and each view selects the nodes it draws. The
node's local XZ plane is the rest plane, as for a body, and mirrors, the clip plane, `surface_view`, the queries and
`fluid_sample` work on it as before.

```c3
WaterDesc desc = water::default_water_desc();
desc.mode = OCEAN;
desc.extent = 20000;   // metres
desc.cell_size = 1.25f;
desc.depth = 200;
desc.wave_count = 0;   // flat until water::set_sea_state: the default's 3.5 m wave is under the four-cell floor
water::add_water(
    scene:  &scene,
    assets: &assets,
    node:   sea,
    desc:   desc,
)!;
// every frame, before water::update: follow the view in whole steps
float step = water::ocean_snap_step(&desc);
sea.local.position.x = math::round(camera_position.x / step) * step;
sea.local.position.z = math::round(camera_position.z / step) * step;
scene.update_world();
```

- **Extent.** A chunk is `cell_size * OCEAN_CHUNK_CELLS` metres wide at the finest level and twice that at each level
  above. The tree has the next power of two of chunks per side at or above `extent / chunk` (at most `MAX_OCEAN_CHUNKS`,
  256), so the body covers up to twice the requested extent, centred on the node; `WaterRuntime.rest_min` and `rest_max`
  hold what it covers, and queries outside answer `NOT_FOUND`. At the default 1.25 m cell a chunk is 80 m: 128 chunks
  cover 10 km and 256 cover 20 km. A 10 km sea has eight levels and 21,845 nodes. The largest tree has nine levels and
  87,381 nodes: 4.9 MiB of instance records on the CPU, 11 MiB on the device, 1.4 MB of selection state shared by the
  views and 0.7 MB more for each ([instancing](instancing.md#quadtree-selection)).
- **Chunk size.** The box ranges of a level grow with its chunk's diagonal, so large chunks draw their finest cells far
  past the distance where a cell is a pixel. A chunk of 64 cells keeps that reach short. The price is four times the
  nodes for an extent that 128-cell chunks would cover, and half the extent at the cap for a cell size.
- **Per-view levels.** The split threshold is 512 px, the hysteresis 0.25 and the morph band 0.25, constants of the
  package (the terrain's defaults). An application tunes the threshold in place on the node's
  `InstancedMesh.quadtree.split_pixels` ([tuning in place](instancing.md#quadtree-selection)); it survives `set_desc`.
  Each view selects its own levels. Adjacent chunks differ by at most one level. The body casts no shadow.
- **Morph.** A vertex at an odd lattice position moves toward the mean of its two parent-lattice neighbours' points
  over the last quarter of its level's range: the full displaced position, the normal and the crest factor, not a
  height. At the end of the range it lies on the segment the coarser level draws, so a level change leaves neither a
  crack nor a pop. Lattice coordinates are integers, so a coarse vertex and the fine neighbour compute the same float.
- **Bounds.** Each node's box is its rest footprint grown by the total amplitude in y and the largest crest shift in x
  and z, the growth `Mesh.local_bounds` has for a body. The records and the box ranges are rewritten when that growth
  changes (`set_desc`, the start and the end of a sea-state blend, which bounds the blend by the larger of both sets)
  and uploaded once; a frame without such a change writes and uploads nothing for them.
- **Filtering.** A wave far from the camera is shorter than the lattice can show. At a vertex whose effective cell is
  `c` metres (the level's cell size times `2^morph`, so it is continuous in the morph), a wave of wavelength `λ`
  keeps its full amplitude and crest shift at `λ ≥ 4c`, loses them linearly and is gone at `λ ≤ 2c`. Far levels
  therefore draw a filtered surface, calm of the shortest waves. **CPU queries return the unfiltered surface.** The
  drawn and the queried surface agree within 1 cm where every wave of the sum is at least four cells of the vertex's
  level long. Validation asks for four cells of the finest level, and the sea-state table floors its wavelengths
  there, so the finest level draws every wave whole and buoyancy sees what the viewer sees near the camera; a body
  keeps its two-cell rule.
- **Far-field regularity.** A sea of four waves is four sine terms, and where its crests cross the far levels draw a
  regular grid. It is clean at a wind of 2 m/s, faint at 6 and visible at 12 to 18. A `SPECTRAL` ocean shows none at
  any wind ([Spectral surface](#spectral-surface)); use it for an ocean seen at high wind.
- **Anchoring.** An ocean's waves are anchored to the world. The stage evaluates `dot(d, p) / λ` on the node-local rest
  position `p`, as for a body; the CPU adds the node's absolute position `A` to `φ`: `φ += dot(g, A) / λ`, with `g`
  the gradient of the local phase in world space, `(M⁻¹)ᵀ d` for the node's world matrix `M` (the direction itself for a
  node with neither turn nor scale). `A` is the world translation plus `Scene.world_shift`, summed in double, and
  only `fract` of the cycles reaches the float block, so the precision is that of the node-local phase at any
  distance. `update` re-folds when `A` differs from the last fold: the node moved, or the world shifted without it. A
  consistent `shift_origin` moves both and uploads nothing. A move adds the fold
  to both the current and the previous wave set, so the velocity form, which transforms the previous point with
  the current node matrix, shows the surface's own motion and not the node's. A move writes the material block once,
  and an unmoved ocean writes none. A node's turn about Y turns its waves and is not re-folded.
  The CPU queries read the same offsets and the same node matrix, so the twin holds across a move.
  `set_desc` keeps the offsets of waves whose direction and wavelength it leaves, and anchors a changed wave from phase
  zero. The ripple scroll takes the local image of the move as well, in each layer's own coordinates, so the ripples
  stay put in the world.
- **Blend and drift.** A sea-state blend integrates each wave's phase in double ([Sea state](#sea-state)); a move
  during a blend subtracts `dot(g, A_new − A_old) / λ(t)` from that phase with the frame's blended direction and
  wavelength, so the pattern is continuous across the move. A changing wavelength stretches the pattern about `A`, the
  node: a wave of amplitude `a` at distance `r` from `A` adds up to `2π · a · r · |dλ/dt| / λ²` metres per second to the
  height's rate of change, and `r · |1/λ_from − 1/λ_to|` crests pass over the blend. A node that follows the view keeps
  `r` within the distance from the camera plus one snap step, so the drift near the view is that of a lake of the
  same size.
  **Two oceans with different anchors drift apart during a blend and keep the difference afterwards;** they agree again
  only if they blend identically. One ocean per scene is the expected use.
- **Following the view.** The body is finite, so the application moves the node with the camera. Move it by multiples
  of `ocean_snap_step(&desc)`, which is `cell_size` times the chunks per side, the cell size of the root level and a
  multiple of every finer one: each level's vertices keep their world positions, so the surface does not swim. A move by
  any other amount is correct and makes the vertex lattice slide under the waves.
- **Rebasing.** `Scene.shift_origin` moves the node and `world_shift` together, so `A` is unchanged: heights at a
  fixed absolute point stay put and nothing uploads. The renderer's shift needs nothing more
  ([large worlds](large_world.md)).
- **No tracing.** An ocean is not traced: the quadtree forbids `trace` and a posed 40 km grid every frame would cost
  more than it shows. `check_desc` faults `INVALID_ARGUMENT` for `trace` on an ocean. Mirrors reflect across the rest
  plane as for a body.
- **Removal.** Remove `Water`, or the node; `update` removes the `InstancedMesh` as it removes a body's `Mesh`.

## Shading

The fragment stage composes public parts only: `prepare_surface` with an F0 of 0.02, `fresnel_schlick` for the
reflection weight, `evaluate_standard_lights` for sun glints and lit foam, `indirect_diffuse_irradiance` and
`standard_ambient_fill` for the foam, the scene snapshot reads and `apply_fog_refracted`. Seen from above:

```
color = evaluate_standard_lights(surface) + F · reflection + (1 − F) · (ambient(foam albedo) + E · foam albedo / π)
      + (1 − F) · (1 − foam) · fog_behind(snapshot)
foam  = max(crest ramp above foam_crest, 1 − depth gap / foam_depth), with a foam reference only
```

`fog_behind` is the view's fog from the surface to the depth of the refracted sample: the [medium](#underwater) and
any air fog. The water has no absorption of its own. The refraction sample shifts by the normal's tilt in view
space times `refraction_strength`, scaled by the water behind the surface up to 1 m, and falls back to the direct
sample when the shifted one lands in front of the water; a background texel has no bed, so the medium takes the ray as
far as its box reaches ([Underwater](#underwater)).
The reflection is the only specular environment term. Traced forms of the fragment stage let a traced sun shadow the
water. The sun lights glints and foam; the water's own colour is the medium's in-scatter.

## Underwater

A water body owns one child node, `WaterRuntime.medium_node`, named `water_medium`, that carries one core
[`MediumVolume`](sky.md#medium-volumes), so the view's fog pass absorbs and scatters through the water and a camera can
stand in it.

- **Mapping.** Per colour channel, from the desc:
  - `absorption = −ln(absorption_color) / absorption_distance`, per metre;
  - `scattering = absorption · a / (1 − a)` with `a = min(scatter_color, MAX_SCATTER_ALBEDO)` read as single-scattering
    albedo, so the medium's own albedo `scattering / (absorption + scattering)` is `a`;
  - `anisotropy = MEDIUM_ANISOTROPY` (0.6): the Henyey-Greenstein `g` of the sun term, forward-leaning as suspended
    particles are, though not as sharply as real water, which would show the sun term only toward the sun;
  - `center` and `half_extent` are the middle and half sizes of the rest rectangle in the node's XZ
    (`WaterRuntime.rest_min` and `rest_max`): the built grid's, the application geometry's bounds, or an ocean's whole
    tree.
- **Placement.** The fog pass applies a medium to every surface it fogs, and cannot tell water from a submerged rock.
  The box's top is therefore not the rest plane: the medium node hangs `offset = total amplitude + MEDIUM_SKIN` under it
  in the body's frame, with the bounding total amplitude of a running sea-state blend as the mirror's clip plane uses,
  so no drawn surface falls inside the box, a trough or flat water a depth-precision sliver low included. The node's
  `depth` is the desc's less `offset`, so the box's bottom stays `WaterDesc.depth` under the rest plane. Water not
  deeper than `offset` has no medium. Absorption and scattering are per world metre; the extents, the depth and the
  offset are in the node's frame. The water between the surface and the box's top is not absorbed: a bed seen through a
  crest misses up to about twice the amplitude of absorption.
- **Layers.** The medium node carries the body's layers, and `update` and `set_desc` copy them again, so a view that
  does not see the body does not take its medium. Node layers do not inherit; the copy is the library's.
- **Clear water.** `absorption_color` of 1 on every channel writes no medium, and `scatter_color` does nothing then.
- **Lifecycle.** `add_water` and `prepare` add the node and write the medium. `set_desc` writes it again, adding the
  `MediumVolume` when the water turns murky and removing it when the water turns clear; a sea-state blend writes it
  when it starts and when it ends. The `update` that removes the body's `Mesh` removes the node. The medium node is the
  library's: do not edit or remove it. A `MediumVolume` the application put on the body's own node is its own: it adds
  to the water's where they overlap and stays when the body goes. The serialization adapter omits the medium node, and
  the loaded body adds it when it is prepared.
- **Absorbed once.** The fragment stage has no absorption of its own. The view's fog pass fogs the path from the camera
  to the surface, and the refracted sample goes through `apply_fog_refracted`, which fogs the path from the surface to
  what lies behind it along the view ray to the depth of that sample. The bed is absorbed by the medium once, with the
  camera above or below the surface.
- **Where the medium applies.** Main, split and mirror views that keep the node (its layers meet the view's) take it,
  and the nearest four media of a view are kept ([medium volumes](sky.md#medium-volumes)). A mirror view clips it at its
  plane, so a mirror camera inside the box is not darkened by it. The mirror cameras leave out the body's own layer, so
  the body's medium is not in its own mirror either way. Probe updates, reflection captures and the path tracer take no
  media: a water surface they draw shows what lies behind it unabsorbed.

**From below.** The material is double-sided. A back face shades from below when the viewing camera is under the
body's rest plane, the test of the mirror ([The mirror](#the-mirror)), and draws nothing otherwise: seen from above, a
back face is the far side of a triangle showing through a gap between quads. A front face is unchanged for any
camera. A back face seen from under the plane shades as follows:

- The camera ray refracts with the index ratio 1.33 to 1. Inside the critical angle (48.75° from the normal) the
  refracted direction leaves the water. It is projected into the view: the scene snapshot there shows what lies above
  the surface (Snell's window), and a direction outside the frame or behind the camera shows the environment in that
  direction. The sample is fogged by `apply_fog_refracted` as above, over the air.
- Outside the critical angle the ray reflects back into the water (total internal reflection). The reflected ray marches
  the snapshot when `march_reflections` is on, else it reads the environment, and the medium fogs it from the surface to
  the hit, or to the end of the medium for a miss. The planar mirror is not used.
- The weight of the reflection is Schlick's fit on the refracted angle, which reaches 1 at the critical angle, so the
  window's edge fades into the reflection.
- Sun glints, lit foam and the surface's own lighting do not run from below: the surface shows only what it passes and
  what it reflects, fogged by the medium on the way to the camera.

The waves bend the window and the reflection with the surface normal, ripples included.

## Reflections

| Condition | Varies | Branch |
| --- | --- | --- |
| The viewing view provides the reflection slot | per draw | planar sample |
| Otherwise, `march_reflections` | per draw | march tried |
| The march hits: a sample lies behind the snapshot surface by less than two steps | per pixel | snapshot colour |
| Otherwise | | the environment's specular cube at mip 0 times its intensity, else `frame.ambient` |

The planar sample is never rejected. Its uv is the screen uv plus the tilt offset, clamped to 0.05, then clamped half
a texel inside the slot's own texture, whose size follows the mirror target's `render_scale`. An outward offset at the
frame edge reads the edge texels, so the surface does not fall back to the environment there, and the margin keeps the
read off the opposite edge under any address mode. The slot's sampler is linear with clamp-to-edge addressing.

The march steps 24 times along the reflected ray over four times the pixel's view distance, spaced
quadratically; a sample behind the camera or outside the frame ends it as a miss, and background texels never
hit. The per-pixel branches read with an explicit level of detail. A view that provides nothing at the slot, or
whose target was destroyed, reads it as absent: the stage marches, then falls back to the environment.

## The mirror

The library places the mirror cameras; the application renders them. A water body holds `max_mirrors` mirror
slots. Each viewing view owns one slot of every body it sees, and gives the body's material its mirror's target as
a [view texture](views.md#view-textures) at the body's `reflection_view_slot`, so every view reflects its own
mirror.

`update_mirror(scene, body, slot, viewing_camera)` sets the slot's camera node's `local` to the viewing camera's
reflected across the image of the node's local XZ plane, gives it the viewing camera's lens with the water node's
layers removed, and writes `WaterRuntime.clip_plane`: the rest plane lowered by the total amplitude (a simulated
body's reach), so everything above the deepest trough stays. The plane belongs to the body, so every slot of it is the
same. The application owns the targets, the views and the order.

**Bodies do not reflect each other.** A mirror camera is the viewing camera reflected across its body's rest plane, so
it looks from under that plane, and the clip plane keeps only what lies above it. Another level body is then either
below the plane and clipped, or above it and seen from its underside, never from the side that reflects, and the
mirror view is given no view textures. Level water cannot reflect another level body's top surface, so a mirror
never holds another body's reflection: the library builds no chain of mirrors, no depth cap and no cycle check.

A viewing camera under the rest plane has nothing to reflect: the surface seen from under the water reads no mirror
([Underwater](#underwater)). `update_mirror` then returns `BELOW`, leaves the slot's camera pose and
`WaterRuntime.clip_plane` as they were and puts the camera on no layer. The application skips that mirror view, which
saves its cost, and clears the viewing view's texture at the body's slot, as the lines below do. The next
`update_mirror` with the camera above the plane places the slot again and returns `PLACED`. The test is the rest plane,
not the waves: a camera within the amplitude of it takes the plane's side ([Limits](#limits)).

The example renders a mirror at

```c3
// A quarter of the pixels: on an RTX 4090 at 2560 x 1440 the mirror view takes 0.721 against 0.815 ms still,
// 0.796 against 0.922 ms in orbit, and the frame 2.236 against 2.331 ms.
const float MIRROR_RENDER_SCALE = 0.5f;
```

as `render_scale`, with these lines of its code, kept identical by hand:

```c3
// Once per viewing view and body, after add_water and a first update_mirror of the view's slot.
RenderTargetId mirror_target = render::create_render_target(
    renderer,
    render::render_target_desc(viewer_size.x, viewer_size.y),
)!;
ViewDesc mirror_desc = render::texture_view_desc(mirror_target);
mirror_desc.render_scale = render_scale;
mirror_desc.post.anti_aliasing = AntiAliasing.NONE;
mirror_desc.clip_plane = scene.get(lake, WaterRuntime).clip_plane;
ViewId mirror_view = render::create_view(renderer, mirror_desc)!;

// Every frame, after update_mirror and before begin_frame: set_desc and a moved lake move the plane.
Plane clip_plane = scene.get(lake, WaterRuntime).clip_plane;
ViewDesc current = renderer.views.get(mirror_view).desc;
if (clip_plane.normal != current.clip_plane.normal || clip_plane.d != current.clip_plane.d) {
    current.clip_plane = clip_plane;
    render::configure_view(renderer, mirror_view, current)!;
}

// Once, and when the viewer's output size changes: the mirror's projection at its scaled extent matches the viewer's.
scene.get(viewing_camera, Camera).aspect = (float)viewer_size.x / (float)viewer_size.y;

// In the frame, for each viewing view: the mirror, fitted to the viewing camera, its texture, then the view.
// A viewer under the water (BELOW) renders no mirror and gets no texture at the slot.
RenderTargetId target;
if (mirror_state == MirrorState.PLACED) {
    Node* mirror = scene.node(scene.get(lake, WaterRuntime).mirrors[slot]);
    renderer.render_view(
        scene:         scene,
        camera_node:   mirror,
        view:          mirror_view,
        shadow_camera: viewing_camera,
    )!;
    renderer.finish_view(mirror_view)!;
    target = mirror_target;
}
renderer.set_view_texture(view, lake_desc.reflection_view_slot, target)!;
renderer.render_view(scene, viewing_camera, view)!;
renderer.finish_view(view)!;
```

- The clip plane changes when the lake node moves or `set_desc` changes the amplitude; `configure_view` resets
  that view's history, and the lines do nothing otherwise.
- A window resize resizes the target: `resize_render_target` keeps the id, and the view texture and the material
  follow the target's revision. A viewing view needs `set_view_texture` again only for a new target; zero clears
  the slot.
- **Per view.** Give each viewing view a mirror slot of its own on every body it sees, a mirror view and target
  per slot, and provide each target to its own viewing view. A view given another view's target shows that
  view's reflection. A view that is given none reads the slot as absent: the stage marches, then falls back to
  the environment. The example's `--capture` view has no mirror, so it leaves the water's layer out of its camera.
- **Several bodies in one view.** Bodies a view sees need distinct `reflection_view_slot` values, so one view
  reflects at most `MAX_VIEW_TEXTURES` (4) bodies. Each body has its own plane, so each needs a mirror view of its
  own: bodies at two levels in one view cost two mirrors. The mirror cameras leave out the layers of the body they
  reflect, so give bodies one layer bit each to see one body in another's mirror.
- **Cost.** One mirror view per viewing view and body, with a target at the viewer's extent scaled by
  `render_scale`.
- **Order.** Render a viewing view's mirrors, then the view, then the next viewing view's mirrors. The renderer
  holds one shadow set at a time: the first mirror records the set fitted to the viewing camera, and the others
  and the viewing view bind it ([shadow sets](shadows.md#shadow-sets)). A view with another camera between a
  mirror and its viewing view records over the mirror's set.
- Set the viewing camera's `Camera.aspect` to the viewer's extent (the example's `follow_viewports`), so the
  mirror's projection at its scaled extent equals the viewer's.

## Scene traces

`WaterDesc.trace` puts the displaced grid of a `BODY` in [scene traces](scene_trace.md); an [ocean](#ocean) is not
traced. Ray-traced reflections and ambient occlusion, path-traced views, probe updates and global illumination then
see the water surface, not the bed under it. `add_water` and `set_desc` write it to `Mesh.trace`. The mesh is the
drawn one, not a [trace proxy](scene_trace.md#trace-proxies): `Mesh.trace_only` stays false, so the proxy skip height
does not apply and the row carries `TRACE_MASK_ALL`.

- **The stage.** The water shader carries a `trace_pose.single` form, `water_trace_pose.comp.glsl`
  ([trace pose](custom_shaders.md#trace-pose)). It runs the vertex stage's `water_surface_point` over each rest
  vertex at `TraceCustomPoseRoot.time`, the frame time narrowed to a float like `frame.jitter_time.z`, so the traced
  surface is the one drawn in the same frame. It writes the position and, when the geometry has a normals stream, the
  normal; the tangent keeps `w = 1`, as the vertex stage writes it. A built grid carries a normals stream; application
  geometry without one traces with face normals.
- **Every frame.** The stage reads the time (`reads_time`), so a frame whose time moved poses the grid again and
  refits it: the software kind refits the tree and the hardware kind updates the bottom level in place, after the
  first frame builds it. A frame at an unchanged time poses nothing.
- **Cost.** One posed slot, one dispatch of one thread per vertex and one refit or bottom-level update per traced body
  each frame. The posed streams hold 24 B per vertex (position and normal): 226 kB for the 120 m lake at the default
  cell size (9,409 vertices) and 6.3 MB at the largest built grid (263,169). The software kind adds a copy of the
  tree's nodes (about 328 kB for the lake) and the hardware kind a bottom level; `Stats.trace_posed_bytes` totals
  the slot. The cost follows the vertex count, so `cell_size` is its lever. A body that finds no posed slot is left
  out of the trace and counted in `Stats.trace_deform_overflow` ([capacity](scene_trace.md#custom-trace-poses)).
- **Shadows.** The mesh casts no shadow, and a trace row carries `TRACE_MASK_SHADOW_CASTER` only for a mesh with
  `cast_shadow`: traced sun shadows ignore the water, as the shadow atlas does, and the bed under a lake is lit alike in
  both. Traced shadows on the water work as before.
- **Hits.** A hit on the water shades as any custom material hit does, grey under Lambert lighting; foam, refraction,
  reflection and ripples do not run there.
- **From below.** The material is double-sided so that the surface draws from underwater, but `add_water` and
  `set_desc` set `Mesh.trace_facing` to `FRONT` ([facing](scene_trace.md#facing)), so the trace row has front faces
  only. Raster is unaffected. For a traced body, a ray from under the surface passes through it: ray-traced ambient
  occlusion of a submerged bed does not see the surface as an occluder, ray-traced reflections from underwater
  surfaces do not reflect it, and a path-traced view from under the water does not see it. A [probe](probe_volumes.md)
  under the rest plane hits the surface's back face and reads it as inside geometry, so it is excluded when more than
  a quarter of its rays do. Shadow rays are unchanged, because the water casts none. Untraced water has no row, so
  none of this applies.
- **Bounds.** The pose stays inside `Mesh.local_bounds`, the rest bounds grown by the total amplitude and the crest
  shift ([Surface geometry](#surface-geometry)).

## Buoyancy

The physics add-on's `Buoyancy` component samples a fluid the application installs per world
([buoyancy](buoyancy.md)). `fluid_sample` is a ready sampler over one water body, with the physics add-on's
`FluidSampleFn` signature and no import of it:

```c3
WaterFluid lake_fluid = { .view = view, .time = now, .current = { 0.5f, 0, 0 } };
physics.set_fluid_sampler(&water::fluid_sample, &lake_fluid);
```

`WaterFluid` holds the `SurfaceView`, the `FrameInfo.time` of the physics update's first step and a uniform
current in metres per second. `fluid_sample` returns the height `sample_surface_detail` finds at
`time + step_offset`, so every fixed step samples its own time, and writes the orbital velocity plus the
current. Outside the body's rest rectangle it is `NOT_FOUND`: no fluid there.

Each frame, after `water::update` and `set_desc`, take the view again, set the time and current, then call
`physics.update`. Take the view again after an origin shift as well: a stale view answers for the old position.
Several water bodies: hold one `WaterFluid` per body and a sampler of your own that returns the first body that
does not fault.

## Removal

Remove `Water`, or the node. The runtime's remove hook removes the owned material; the next `update` removes
the node's `Mesh` (`InstancedMesh` for an ocean), its medium node and `WaterRuntime` and every mirror camera node
whose water body is gone. Removing `WaterRuntime` or a mirror node directly is unsupported (`release_mirror` frees one
slot's camera); call `update` between removing and adding a water body on the same node. Destroy the scene before the
store.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_water` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_water`, `set_desc` | `c3d::INVALID_ARGUMENT` | A desc value outside its rule (NaN included, `max_mirrors` outside [1, `MAX_MIRRORS`], `reflection_view_slot` at `MAX_VIEW_TEXTURES` or above, a `depth` that is not positive and finite); application geometry off y = 0; an ocean with geometry, with `trace`, wider than `MAX_OCEAN_CHUNKS` chunks, or with a wave under four finest cells; a reference that is not `STANDARD`; a shared key naming another asset kind |
| `set_desc` | `c3d::INVALID_ARGUMENT` | A `mode`, and for an ocean an `extent` or `cell_size`, that differs from the prepared body's |
| `add_water`, `set_desc` | `c3d::INVALID_ARGUMENT` | `SIMULATED` with an ocean or application geometry, outside 16 to 256 cells per side, with a speed or damping that is not positive and finite, or with a speed that needs more than `MAX_SIMULATION_SUBSTEPS`; a `ground` without `Terrain` |
| `add_water`, `set_desc` | `c3d::INVALID_ARGUMENT` | `SPECTRAL` with a `patch_size` that is not positive and finite, or a `choppiness` that is negative or not finite |
| `add_water`, `set_desc` | `c3d::INVALID_ID` | A dead geometry, reference or `ground` |
| `add_water`, `prepare` | `c3d::UNSUPPORTED` | A `SPECTRAL` body in a build without `C3D_LANDSCAPE_GPU` |
| `set_desc` | `c3d::INVALID_ARGUMENT` | A `wave_model`, a spectral body's `spectrum`, and for a simulated or spectral body an `extent` or `cell_size`, that differs from the prepared body's |
| `add_impulse` | `c3d::INVALID_ID` | A dead node, a node without prepared water, or a body that is not `SIMULATED` |
| `add_impulse` | `c3d::INVALID_ARGUMENT` | A position that is not finite, a radius that is not finite and positive, a strength that is not finite or is negative |
| `add_water`, `set_desc` | `c3d::CAPACITY_EXCEEDED` | A store pool full, or no scene node left for the medium's node or the mirrors |
| `update_mirror` | `c3d::INVALID_ID` | A dead body, a node without prepared water or a dead viewing camera |
| `update_mirror` | `c3d::INVALID_ARGUMENT` | The viewing camera's local transform is not finite |
| `update_mirror` | `c3d::CAPACITY_EXCEEDED` | No scene node left to add the camera of a slot freed by `release_mirror` |
| `set_sea_state` | `c3d::INVALID_ID` | A dead entity, no `Water`, or pending water whose geometry was removed |
| `set_sea_state` | `c3d::INVALID_ARGUMENT` | A non-finite wind, a negative or non-finite transition |
| `set_sea_state` | `c3d::UNSUPPORTED` | A `SIMULATED` body, or `SPECTRAL` water that is still pending |
| `water_gpu::update` | `c3d::CAPACITY_EXCEEDED` | The store has no room for the three compute stages |
| `water_gpu::update` | those of `AssetStore.add_compute_shader` and `Renderer.dispatch` | Inherited unchanged, the `gpu::` faults among them |
| `surface_view` | `c3d::INVALID_ID` | Dead entity, no water body, the owned material removed |
| `sample_surface`, `sample_surface_detail`, `fluid_sample` | `NOT_FOUND` | The point's rest position lies outside the rest rectangle |

## Limits

- **Tracing is opt-in.** Without `trace` the water is absent from every trace: under ray-traced reflections and in
  path-traced views the lake bed shows through and reflections show no water; probe updates see through it. With
  it the water hits shade grey, and its cost is a pose and a refit per frame ([Scene traces](#scene-traces)).
  Traced shadows ignore the water either way (it casts none); traced shadows on the water work.
- **One mirror per body and viewing view**, at most `MAX_MIRRORS` (8) slots on a body; the viewing camera is a
  root node. One view reflects at most `MAX_VIEW_TEXTURES` (4) bodies. The first mirror of a viewing view records
  the frame's only shadow atlas, fitted to the viewing camera, and the rest bind it
  ([shadow sets](shadows.md#shadow-sets)). Reflected receivers outside the viewing camera's cascades read
  unshadowed.
- **Clip plane at the deepest trough**: geometry between a trough and the local surface can appear in the
  reflection; the amplitude bounds the error.
- **Screen-space march**: opaque, masked and sky from this view only; no blends, nothing off-screen or behind
  the camera; 24 steps over four times the pixel's view distance.
- **Blends under the surface are hidden**: the water writes depth and readers never see ordinary blends.
- **SSGI and temporal AO views**: readers keep camera-only velocity ([screen-space GI](screen_space_gi.md),
  [temporal AO](ambient_occlusion.md#temporal)), so moving waves smear under TAA there; readers get no AO and
  no SSGI terms.
- **Wave edits** through `set_desc` give one rendering of wrong wave motion vectors: the velocity form evaluates
  the new waves at the previous time. Queries follow once `surface_view` is retaken. A `set_sea_state` blend has
  exact vectors ([Sea state](#sea-state)).
- **Sea-state stretch**: a blend that changes wavelengths stretches the pattern about the node origin, so the
  per-frame height step grows with the distance from it; a longer transition spreads it
  ([Phase continuity](#sea-state)). An ocean stretches about its node instead ([Blend and drift](#ocean)).
- **Ocean**: finite, 20 km at most at the default cell size, and the application moves it with the view; far levels
  draw a filtered surface that queries do not; no tracing, no depth read yet; two oceans drift apart during a blend
  ([Ocean](#ocean)).
- **Long sessions**: core's float time limit; wrap the clock and call `render::reset_view_history`. The wave phase
  is `t · c / λ` in float ([Time](#time)); a sea state's offsets carry the same limit.
- **Query accuracy**: the inversion stops at 0.1 mm or after 8 steps; `residual` reports where it stopped, and
  the drawn surface agrees within 1 cm.
- **Simulated surface**: a built grid of 16 to 256 cells per side, with no ocean, no horizontal motion and no wave foam;
  walls reflect and there is no sponge, so a ripple returns from the edges; `SIMULATION_MAX_HEIGHT` bounds the heights
  and the mesh's bounds, and the medium and the clip plane follow the reach; the view borrows the grid; the dry mask
  follows reported terrain edits only ([Dry cells](#dry-cells)); at most four steps run per update. Each awake frame
  uploads the whole texture ([Simulated surface](#simulated-surface)).
- **Spectral surface**: a 256² field per body (6.5 MiB of device memory and 18 dispatches a frame), a spectrum that is
  fixed for the body's life, a sea built from the body's fetch (a lake's is centimetres), no wave foam, and a drawn
  surface that agrees with its twin by a statistical bound instead of 1 cm ([Bounds and the twin](#bounds-and-the-twin)).
  Waves under four texels or under the lattice's cells are dropped, and the finest field is sampled by every ocean
  level. The wind and the spectrum are node-local, node scale scales the sea, and a spectral body needs the
  `C3D_LANDSCAPE_GPU` build and one `water_gpu::update` a frame ([Spectral surface](#spectral-surface)).
- **Transforms**: drawing takes any node transform (waves scale and rotate with the node; the mirror reflects
  across the image of the local XZ plane); queries require translation plus rotation about Y.
- **One body per lake**: the waves of a `BODY` are node-local, so two bodies do not match at a shared edge. Two
  oceans match in phase at a shared edge outside a blend.
- **Grids** are shared per shape and live for the store's lifetime; application geometry rests at y = 0 and
  follows the aliasing rule by itself.
- **References**: the ripple material contributes its normal map only; foam shows only with a foam reference;
  `uv0` is the rest position in metres.
- **Lighting**: the sun lights glints and foam. The water body's own colour is the medium's in-scatter: the ambient
  and the sun through the column above each point, with no occluder shadowing and no indirect light. A bed that
  receives shadows takes the sun through the water from the box's top ([sun on surfaces](sky.md#medium-volumes)); the
  band between the surface and the top is not counted.
- **Waterline**: the medium's top lies `total amplitude + MEDIUM_SKIN` under the rest plane, under the deepest trough,
  and the mirror's side test is the rest plane. A camera in the band from the box's top to a crest (`amplitude + skin`
  under the rest plane to `amplitude` over it) can stand under the water and outside the medium, unfogged, and its mirror
  follows the plane's side, not the waves'. The water between the surface and the box's top is not absorbed: a bed seen
  through a crest misses up to about twice the amplitude of absorption. A simulated body's amplitude is its reach, the
  largest height magnitude since it woke: the box's top is `MEDIUM_SKIN` under the rest plane while the pond is calm.
- **Camera side**: the surface's from-below test is the rest plane, as the mirror's, so a camera within the wave reach
  of it takes the plane's side. Over the plane and under a crest, the crest's underside draws nothing; under the plane
  and over a trough, back faces shade from below and front faces as from above.
- **Underwater views**: no light shafts and no caustics. The window and the reflection show this view's snapshot and the
  environment elsewhere, so near the frame's edge the window changes from the snapshot to the environment. The surface
  shows no glints or foam from below.
- **Frames without media** (probe updates, reflection captures, the path tracer) show the bed through the water
  unabsorbed.
- **Tracing from below**: the trace row has front faces only, so rays from under the surface pass through it
  ([Scene traces](#scene-traces)).
- **Buoyancy**: eight cells over the colliders' box; a tilted body is approximated; a floating body at rest may
  sleep for one step each 0.5 s and wakes on the next; rendered crates lag the simulation by up to one fixed
  step (pose interpolation), visible as a bob offset on fast waves.
- **Removal**: remove `Water` or the node; removing `WaterRuntime` or the mirror node directly is unsupported.

## The example

`python3 scripts/build.py --example water` builds the [terrain](terrain.md#the-example) example's ground with
the [vegetation](vegetation.md#the-example) example's grass and trees, then a lake. It picks the flattest
120 m square of a 13 × 13 search grid, sets the water 0.5 m under the lowest ground on the square's edges, and
carves a cosine bowl 6 m deep and 55 m in radius into the height map before the terrain collider cooks it; no
grass or tree grows under 0.3 m above the water. The sky is a generated equirectangular gradient with a sun
disc, the scene's environment and background. The lake is `default_water_desc()` at 120 m with a generated
tiling ripple normal map of eight non-aligned sine terms (4 m tiles), stored `RGBA16_FLOAT` with `COLOR` semantics for
[its mip length](#ripples-and-wind), and a generated foam colour, on its own layer
bit. The mirror view renders at `MIRROR_RENDER_SCALE` with the lines above. `--crates 16|256` drops 1 m crates
(density 600, drag 3000 N·s/m, well under the 36,000 N·s/m at which the drag limit binds, drag coefficient 1) over the
middle 40 m, each with `Buoyancy` over `fluid_sample`; they bob on the orbital motion of the waves, and
`--current X,Z` adds a uniform current in m/s that carries them (not with `--benchmark`, whose settle gate
expects still water).

Right drag looks, WASD moves, F flies, B raises the ground under the camera (the ground collider re-cooks when
the key lifts), and with `--waves simulated` (without `--dive`) R drops a ripple where the camera looks. The panel switches the reflection source, the mirror's resolution, the waves (calm or zero),
the ripples, the wind heading and speed, and shows the crates' mean submerged fraction, the physics step time,
scene snapshots and upload bytes; the view stats table shows each view's passes with `--gpu-timings`, and the
targets panel previews the mirror and capture targets.

`--sea-state` makes the wind controls drive the waves: the sea state of the initial wind is set at once, and a
change of the heading or speed calls `set_sea_state` with a four-second blend for every body. The calm-waves switch
is not shown then, and the benchmark and `--shot` apply the sea state of `--wind` before their first frame, so the
benchmark's still segment checks that a sea state leaves no uploads behind. `--wind SPEED` sets the initial wind
speed in m/s (6 by default, at most 20), for the ripples, the foliage and, with `--sea-state`, the waves. The 120 m
lake limits the sea to centimetres at any wind in that range, so the ripples carry the look of the wind there.
`--shot FILE.png` renders eight frames offscreen with the still camera of the benchmark and writes the last as a PNG
at `--width` by `--height`; it needs no window.

`--dive [SHARE]` replaces the fly camera with a path that crosses the surface, 18 m from the lake's centre, looking
along +X: it descends from 2 m over the water, looking across the lake, to 3 m under it, looking 52° up, with a
smoothstep ease. Interactively it loops, down and up, in 16 s; with `--shot`, `SHARE` in [0, 1] is the point of the
descent the shot stands at (0 above, 1 below; 0 by default). The mirror view is not rendered
while the camera is under the rest plane ([The mirror](#the-mirror)). It does not combine with `--benchmark`, whose
gates assume the still camera.

`--ocean` replaces the lake with an [ocean](#ocean): the ground sinks until its highest point lies 12 m under the sea,
and the sea is a 20 km body (256 chunks of 80 m, 87,381 nodes) at the default cell size and a depth of 200 m, on its
own layer bit like the lake. Each frame its node follows the camera in steps of `ocean_snap_step`. It implies
`--sea-state`, so the waves are the JONSWAP sea of `--wind` (the 20 km body has a fully developed sea; try `--wind
12`) and the wind controls blend them in four seconds. There is no basin, grass, tree or crate, and no `--split` or
`--traced`. `--shot FILE.png --size 1025` renders it headless, and `--benchmark` runs the segments over the sea. In
the gated `water_gpu` build the ocean defaults to `--waves spectral`, because the four-wave sea shows
[far-field regularity](#ocean) at high wind; `--waves gerstner` selects the four-wave sea there. The `water` build draws
the four-wave sea, and the lake keeps `gerstner` as its default in both builds.

`--waves simulated` (default `gerstner`) makes every body [simulated](#simulated-surface). The 120 m lake is 96 cells
per side at the default cell size, with wave speed 8 m/s, damping 0.3/s, the terrain as its `ground` so the shore
reflects ripples, and `reflection_distortion` 0.4 and `refraction_strength` 0.1 so the gentle slopes of a ripple bend
the reflection and the bed. It does not combine with `--ocean` or `--sea-state`, and the calm-waves switch is not shown.
R drops a ripple of 3 m radius and 10 m/s where the camera looks, on every body the ray meets; the ground brush
(B) dries and wets cells as it moves the shore. With `--shot FILE.png`, a ripple falls 40 m west of the lake's centre on
the first frame, the camera stands 12 m west of the centre at 3 m looking west, and `--ripple-age SECONDS` (at most
30, 0 by default) lets that much simulated time pass before the eight frames the shot renders.

`--waves spectral` makes every body [spectral](#spectral-surface). It needs the gated build, `python3 scripts/build.py
--example water_gpu` (the `water` target faults at the option with that hint), which adds `-D C3D_LANDSCAPE_GPU` and one
call of `water_gpu::update` inside each frame before its views. In that build it is the default of `--ocean`. It implies `--sea-state`, so `--wind` and the panel's
wind controls set the spectrum, blended over four seconds. The lake is 0.5 m cells with a 32 m patch, because the fetch of
a 120 m lake raises waves of a metre at most: `--wind 20` is its storm (`Hs` 0.11 m, `λp` 1.1 m), and the default 6 m/s
sea lies almost wholly under the lattice's cut and draws nearly flat. With `--ocean` the body is the 20 km sea at the
default cell size and a 256 m patch, where `--wind 3` and `--wind 20` are the calm and the storm. The panel shows the twin's bound. `--shot FILE.png` writes the frame; it combines with `--ocean`,
`--dive` and `--traced` (not with an ocean).

`--split` draws two viewing cameras side by side in the same output, each with its own viewport, terrain levels,
mirror views and targets, and adds a second water body: a 60 m pool on the flattest ground whose water lies at
least 3 m under the lake's and 110 m or more from it, carved a 27 m bowl like the lake. The lake takes view
texture slot 0 and the pool slot 1, and each has `max_mirrors` 2, one slot per viewer. The left viewer is the fly
camera over the lake. The right one is fixed, 24 m back from the pool's centre and 6 m above its water, facing
it. Each frame renders each viewer's mirror of the lake, its mirror of the pool, then the viewer: four mirror
views and targets, each at the viewer's half of the output. The panel's reflection, mirror-resolution, wave and
ripple switches apply to both bodies. With `--benchmark` the second viewer is a second texture view on the same
target; the timings and gates stay those of the first viewer and the lake.

`--benchmark [frames]` renders offscreen without a window: 60 warm-up frames, then four segments of `frames`
steps (default 300) at 1/60 s with a steady 6 m/s wind; the settle segment runs at least 300 frames, the time
the crates' bob needs to decay.

| Segment | Camera and scene |
| --- | --- |
| still | 6 m above the water, 48 m from the centre, looking across the lake |
| orbit | one circle 80 m from the centre and 30 m above the water, looking at the centre |
| waves | still camera, the calm set |
| settle | still camera; `set_desc` zeroes the amplitudes at the segment start |

It prints the header, `sample_ns` (100,000 `sample_surface` calls before the segments), and per segment the
mirror view's summed passes, shadow atlas and shadow share of the frame (planar, still and orbit), the main
view's passes with `--gpu-timings`, `FOG` among them because the water's medium turns the fog pass on (with `--traced`,
also the frame's `TRACE_POSE` and `ACCELERATION_BUILD` passes as `gpu_ms view=frame`), the frame time, `shadow_sets segment=<name> recorded=<n> shared=<n>` (the
last frame's shadow sets), `buoyancy_us` (the physics step time per fixed step in
`waves`, at the crate count) and the still segment's upload bytes. Two gates exit 1 when they fail:

- `gate steady_uploads`: the still segment uploads nothing after its first frame (water, foliage and crates
  included);
- `gate crates_at_density_line`: every crate's submerged fraction over the settle segment's last 60 frames lies
  within 0.02 of 0.6. With no crates (`--ocean`) it prints `skipped: no crates` and does not fail the run.

With `--waves spectral` the waves segment sets the storm wind (18 m/s, blended over four seconds) and the settle segment a
zero wind (over one second), so the table uploads twice; the header adds `# spectrum sigma envelope bound twin_waves`, each
segment prints `spectral segment=<name> dispatches=<n> record_us median=<m> p99=<p> table_upload_frames=<n>
table_upload_bytes=<b>` (the dispatches of the last frame, the CPU time `water_gpu::update` took to record them, and the
frames and bytes of the table's uploads), and with `--gpu-timings` `gpu_ms view=frame pass=CUSTOM_COMPUTE`, the field's
passes. `gate spectral_dispatches` exits 1 when a frame records other than 18 dispatches a body.

With `--waves simulated` the waves segment starts with a ripple dropped at the lake's centre, and the settle segment
raises the pond's wave speed to 60 m/s and its damping to 3.2/s through `set_desc`, so the ripple rings out inside the
segment. Each segment prints `simulation segment=<name> upload_frames=<n> update_us median=<m> p99=<p> upload_bytes=<b>`:
the frames that uploaded the simulation's texture, the CPU time of `water::update` on those frames and the bytes of one
upload. `gate steady_uploads` holds as before (the still segment has no ripple, so the body is asleep), and a third
gate exits 1 when it fails:

- `gate simulation_uploads_stop_once_settled`: after the waves segment starts, the body reports settled in some frame
  and every later frame uploads nothing for the simulation.

Switches: `--split`, `--waves gerstner|simulated|spectral`, `--ripple-age SECONDS`, `--gpu-timings` (build with `python3 scripts/build.py --target water --opt O3 --define
C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile`), `--validation`, `--shading
forward|deferred`, `--size 1025|2049|4097`, `--reflection planar|march|env` (march: no target; env: no target
and the march off), `--mirror-scale 0.5|1`, `--crates 16|256`, `--ssgi` (SSGI on the main view),
`--traced` (the main view path-traced, with the water traced: a grey surface that follows the waves; without
`trace` it is absent), `--capture` (a second view on a 384² target whose
camera leaves out the water's layer and has no mirror), `--ripples on|off`, `--sea-state`, `--wind SPEED`,
`--ocean`, `--dive [SHARE]`, `--shot FILE.png`, `--width W --height H` (2560 × 1440 by default in benchmark and shot modes) and `--sky`
(an [atmosphere](sky.md) on the sun, which replaces the generated sky, and a haze
pooling in the valleys, off by default; with `--gpu-timings` the main and mirror views print `SKY_VIEW`,
`AERIAL_PERSPECTIVE` and `FOG`) and, with `--sky`, `--volumetric-fog` (a [froxel volume](sky.md#volumetric-fog)
for the main and mirror views; the pass lines add `FOG_SCATTERING` and `FOG_INTEGRATION`). Interactive runs always validate. Under `--sky` the water needs no fog code:
the view's fog pass fogs its surface at its depth, its medium covers the path to the bed, and the mirror
view fogs only the path behind its clip plane ([sky](sky.md#where-fog-applies)).

## Measured cost

### RTX 4090, driver 610.88, 2560 × 1440

Windows host, `--opt O3` with GPU timings, eight cases × three runs; medians of three runs, still segment, main
view unless named, ms. Both gates pass in all 24 runs: still-segment uploads are 0, the settle mean is 0.5999
and the worst 0.5996 against 0.6 (0.5981 at 256 crates). `--benchmark 60 --validation` runs with `--traced`
and `--capture` are validation-clean with both gates.

| | planar | march | env | planar, ripples off | mirror scale 1 | 256 crates | deferred | `--ssgi` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `FORWARD_OPAQUE` | 0.397 | 0.398 | 0.397 | 0.397 | 0.398 | 0.390 | `GBUFFER` 0.255, `LIGHTING` 0.118 | 0.423 |
| `SCENE_SNAPSHOT` | 0.030 | 0.029 | 0.029 | 0.030 | 0.030 | 0.030 | 0.035 | 0.032 |
| `SCENE_READ` (water) | 0.144 | 0.485 | 0.155 | 0.110 | 0.144 | 0.138 | 0.144 | 0.144 |
| `SHADOW_ATLAS` | 0.480 | 0.482 | 0.483 | 0.480 | 0.481 | 0.485 | 0.479 | 0.481 |
| mirror total | 0.721 | none | none | 0.721 | 0.815 | 0.733 | 0.721 | 0.722 |
| mirror shadow atlas | 0.482 | none | none | 0.482 | 0.482 | 0.488 | 0.483 | 0.483 |
| mirror shadow share | 21.9 % | none | none | 22.3 % | 21.0 % | 22.1 % | 22.1 % | 14.8 % |
| `frame_ms` still | 2.236 | 1.855 | 1.521 | 2.197 | 2.331 | 2.240 | 2.222 | 3.297 |
| `frame_ms` orbit | 2.366 | 1.704 | 1.582 | 2.351 | 2.507 | 2.382 | 2.359 | 3.512 |

- **Water pass.** The march costs 0.33 ms over the environment fallback; the planar sample next to nothing; the
  ripples 0.034 ms.
- **The mirror** costs about 0.7 ms of frame time, 0.48 ms of it in its own shadow atlas: 21.9 % of the frame's
  GPU time in the still segment and 21.6 % in orbit, 21 to 22 % in every planar case and 14.8 % with `--ssgi`,
  whose frame is longer. The half-resolution mirror saves 0.09 ms (still, 0.815 to 0.721) to 0.13 ms (orbit,
  0.922 to 0.796) of mirror time and 0.095 ms of frame (2.331 to 2.236) against a full-resolution one.
- **Shadow sets, after:** the mirror records the frame's only atlas and the main view binds it. Planar, still and
  orbit, same-session runs with the before re-measured (ms): mirror total 0.733 and 0.812, mirror `SHADOW_ATLAS`
  0.479, main `SHADOW_ATLAS` none, `frame_ms` 1.784 and 1.953 against 2.327 and 2.507 before. The benchmark prints
  main passes only: main `FORWARD_OPAQUE` 0.396 before and 0.418 after, `SCENE_READ` 0.142 before and 0.141 after.
  `shadow_sets` reads recorded 1, shared 1; with `--capture` recorded 2, shared 1.
- **Buoyancy:** `buoyancy_us` 25.4 µs (25.1 to 25.5) at 16 crates and 304.8 µs (302.6 to 323.3) at 256 per
  fixed step; `sample_ns` 98.8, so 2,048 samples cost about 0.2 ms of the 256-crate step.
- **SSGI:** with `--ssgi` and a still camera the ripples stay as crisp as without it; readers' camera-only
  velocity shows no visible smear here.

### WSL, llvmpipe

llvmpipe is a CPU Vulkan implementation: frame and pass times there are environment only. A full benchmark run
takes longer than the environment's 30 s budget per run, so the CPU lines below come from `--opt O3` runs of
`--benchmark 30 --size 1025 --width 160 --height 90` with the grass and tree targets cut to 2,000 and 200 and
the settle segment to 20 frames, three runs each (i9-14900K):

| Line | 16 crates | 256 crates |
| --- | ---: | ---: |
| `sample_ns` median | 82.4 to 85.6 | 82.6 to 82.9 |
| `buoyancy_us` median (the whole physics step) | 34.8 to 36.2 | 279.1 to 284.5 |

The device test's four cases pass validation-clean in 2.4 s. The steady-upload gate passed in every run; a
full-length settle segment in the same configuration passed the density gate (mean 0.599, worst 0.604).

Preparation order and pending draw behavior are listed in the [owner readiness table](owner_readiness.md).
