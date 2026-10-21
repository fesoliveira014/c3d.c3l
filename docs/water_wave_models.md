# Water wave models

`WaterDesc.wave_model` chooses how a [water](water.md) body computes its heights: `GERSTNER` (default), `SIMULATED` or `SPECTRAL`. The model is separate from `mode`, which chooses the geometry that carries the heights, and a body keeps its model for life: `set_desc` faults `INVALID_ARGUMENT` on a change.

| Model | Computed by | Geometry | Query agreement |
| --- | --- | --- | --- |
| `GERSTNER` | Up to `MAX_WAVES` (4) waves summed in the vertex stage | Body or ocean | 1 cm |
| `SIMULATED` | A damped wave equation stepped on the CPU | Built grid of 16 to 256 cells per side | 1 cm |
| `SPECTRAL` | A wind-sea spectrum evolved and transformed on the GPU | Body or ocean | A statistical bound |

## Gerstner waves

For a rest point `p` in the node's local XZ and shader time `t`, wave `i` of `N` has a unit direction `d`, wavelength `λ`, speed `c`, amplitude `a`, steepness `s` and phase offset `φ` in cycles. The drawn surface is:

- phase `θ = 2π · fract(dot(d, p) / λ − t · c / λ + φ)`;
- height `y = Σ a · sin θ`;
- horizontal shift `D = Σ s · λ / (2π · N) · d · cos θ`;
- drawn point `(p.x + D.x, y, p.y + D.y)`, with the normal from the Jacobian `J` of that map and the crest factor `clamp(1 − det J, 0, 1)`, which drives wave foam.

The waves of a `BODY` are node-local: node scale scales wavelengths and amplitudes, node rotation turns directions. An ocean evaluates the same sum with `φ` carrying the node's absolute position, so crests stay where they are in the world when the node moves.

`default_water_desc()` sets two calm crossing waves (0.12 m at 6 m, 1.2 m/s along x; 0.07 m at 3.5 m, 0.9 m/s along (0.6, 0.8); steepness 0.5 each). Use `set_sea_state` ([water](water.md#set-the-sea-state)) to derive waves from a wind.

## Simulated surface

`wave_model = SIMULATED` draws the heights `u` of the damped wave equation `u_tt = c² ∇²u − γ u_t` on the vertices of the built grid, with `c = simulation.wave_speed` and `γ = simulation.damping`. The CPU steps the heights, so queries and buoyancy read exactly what is drawn. The body ripples when the application drops an impulse.

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

- **Grid.** The lattice is the built grid's vertices: `ceil(extent / cell_size)` cells per side, between `MIN_SIMULATION_CELLS` (16) and `MAX_SIMULATION_CELLS` (256). A simulated body takes no ocean and no application geometry. The state is allocated at `prepare` and freed with the body.
- **Stepping.** `update` accumulates the frame's time and runs whole fixed steps of `1 / SIMULATION_RATE` (60 Hz), so the state follows simulated time, not frame rate. Each step runs the substeps the stability bound needs. A wave speed and spacing that need more than `MAX_SIMULATION_SUBSTEPS` (8) are refused. At most `MAX_SIMULATION_STEPS_PER_UPDATE` (4) steps run per update and the rest of a hitch's time is dropped, so a hitch slows the ripple and cannot spiral. The first `update` of a body only reads the time.
- **Drawn heights.** The stage draws the last two steps interpolated by the share of a step the accumulator holds. Each awake frame rewrites the body's height texture in place and uploads all of it, 16 bytes per vertex: about 150 KB for the 120 m lake at the default cell size and 1 MiB at 256 cells. A settled body uploads nothing.
- **Normals and foam.** Normals come from the neighbouring heights. There is no crest factor, so a simulated surface has no wave foam; shore foam works as for any body. A [traced](water.md#scene-traces) body follows the ripple.
- **Walls.** The grid's edges and its dry cells reflect like the walls of a pool. There is no sponge layer, so a ripple returns from the edges.
- **Bounds and reach.** Heights are clamped to `±SIMULATION_MAX_HEIGHT` (1 m), which also sizes `Mesh.local_bounds`. The medium's offset and the mirror's clip plane follow the body's reach instead: the largest height magnitude since it woke, which is 0 for a calm pond and again after it settles.

### Dry cells

With `ground` set to a node carrying `Terrain`, a vertex is dry where the terrain's height under it is at or above the body's rest plane (the node's world height). A dry vertex holds zero height and speed, draws flat under the ground and acts as a wall. A vertex off the terrain's extent is wet.

The mask is built at `prepare` from `terrain::height_view`, so prepare the terrain first; a body prepared before its ground gets the mask on the first `update` that finds the terrain prepared. `update` follows terrain edits that the application reports with `terrain::mark_dirty`: it re-masks only the covered vertices, or the whole grid when the terrain reports no rectangle or either node moved. A `ground` that dies, loses its `Terrain` or tilts drops the mask until a usable ground returns. Wet vertices keep their heights through a re-mask; vertices that turn dry are zeroed.

### Settling

A body settles when every wet vertex has `|u| < SETTLED_HEIGHT` (0.5 mm) and `|u_t| < SETTLED_SPEED` (2 mm/s). The grid then snaps to rest, one more upload draws it flat, and stepping and uploads stop. A settled body costs the ground check per `update`, and `add_impulse` wakes it. A pond settles fastest with damping near `2π · c / extent`; more damping slows the decay of long waves.

### Impulses

`add_impulse(scene, node, world_position, radius, strength)` lowers the speed of the wet vertices within `radius` metres of the point by `strength · (1 − q²)²` m/s, with `q` the distance over the radius. `strength` is therefore the downward speed at the centre of a smooth bump. The push is returned to the rest of the surface as a uniform rise in speed, so the body returns to its rest level. The node carries no scale: radii are world metres. A bump that meets no wet vertex, and a strength of 0, do nothing.

It faults `INVALID_ID` for a dead node, a node without prepared water or a body that is not `SIMULATED`, and `INVALID_ARGUMENT` for a position that is not finite, a radius that is not finite and positive, or a strength that is negative or not finite.

### Queries

`sample_surface` and `sample_surface_detail` ignore `time` and interpolate the drawn heights on the mesh's own triangles (the diagonal from `(x + 1, z)` to `(x, z + 1)` of each cell). `normal` blends the vertex normals as the rasteriser does, `velocity` is vertical, and `residual` is 0. A point off the grid faults `NOT_FOUND`. `fluid_sample` works unchanged. The view borrows the grid, as [water](water.md#query-the-surface) describes.

## Spectral surface

`wave_model = SPECTRAL` draws a wind sea from a spectrum of waves. The GPU evolves a field of `SPECTRAL_SIZE²` (256²) texels to the frame's time and inverse-transforms it; the vertex stage samples the field, tiled across the body. Every texel is a sum of up to 65,536 waves.

The scene-layer module keeps the spectrum, the CPU twin and the bounds. The module `c3d::landscape::water_gpu`, present under the `C3D_LANDSCAPE_GPU` feature, records the passes. Without the feature, `prepare` faults `UNSUPPORTED`. A `SPECTRAL` body is still accepted as pending authoring, and its `spectrum` fields are kept, saved and loaded.

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

- **Frame order.** `water_gpu::update(renderer, scene, assets)` runs once per frame, after `water::update`, inside the open frame and before `prepare_scene_trace` and any view that draws or traces the water. It records `DISPATCHES_PER_BODY` (18) compute dispatches per spectral body, whatever the number of views. The images are empty until the first call writes them, and the first frame has no motion. It returns the faults of `AssetStore.add_compute_shader` and `Renderer.dispatch`, and `CAPACITY_EXCEEDED` when the store has no room for its three compute stages.
- **Spectrum.** `WaterDesc.spectrum` holds the `seed`, the `patch_size` in metres per tile and the `choppiness` (horizontal displacement scale). The sea follows the wind and fetch of the [sea state](water.md#set-the-sea-state): JONSWAP in frequency, spread by cosine squared about the wind, with deep-water dispersion. Without a sea state the wind is `DEFAULT_SPECTRAL_WIND` (8 m/s along local +X). The spectrum lives in the node's local frame, so node scale scales the surface. The same `seed` always draws the same sea.
- **Sea state.** `set_sea_state` needs prepared water. It blends to the new wind over `transition_seconds` on the GPU, phase-consistent and without a per-frame upload.
- **Band.** Waves shorter than four texels (`patch_size / 256` each) are dropped, because the field's bilinear sampling holds them badly. A built grid also drops waves under two cells, an ocean under four cells of its finest level. The default `patch_size` of 256 m keeps waves from 4 m; a patch should hold several peak wavelengths.
- **Time.** Frequencies are whole cycles of `SPECTRAL_PERIOD` (1,000 s), so the field repeats exactly after it and phases stay accurate at any time.
- **Cost.** Each spectral body owns 6.5 MiB of device memory and costs the 18 dispatches a frame. The field is a fixed 256² per body whatever the extent.
- **Tiling.** The vertex stage samples the field with a repeating sampler at `local_xz / patch_size`, so a body or ocean wider than the patch repeats it. An ocean samples at world-anchored coordinates, so crests stay in the world as the node follows the camera. Every ocean level samples the finest field.
- **Foam.** A spectral surface has no wave foam. Shore foam works as for any body.
- **Fetch.** A fetch the body's size limits gives a small sea, as for the four waves: a 120 m lake at 20 m/s has a significant height of 0.11 m.

### Bounds and the twin

The CPU twin keeps the `SPECTRAL_TWIN_WAVES` (64) strongest components of the spectrum as Gerstner terms. `surface_view` copies them into the view, so `sample_surface`, `sample_surface_detail` and `fluid_sample` run the same inversion as for a Gerstner body. A query sums 64 components in each of up to eight inversion steps, which costs more than the four waves of a Gerstner body. A `SurfaceView` is the same size for every model and stays a value several threads may query. The twin's normal is a little steeper than the drawn slope-only normal.

`WaterRuntime.spectral_bound` is the standard deviation of the omitted components' height times `SPECTRAL_BOUND_SIGMAS` (3). It is computed at `prepare`, at each `set_sea_state` and when a blend ends, and is zero for another model. **The contract is statistical**: the drawn surface differs from `sample_surface` by more than the bound at about 0.3 % of points, and by less than the bound plus the field's resolution elsewhere. The 1 cm agreement of the other models does not hold. A narrow spectrum leaves a small bound, and a wholly represented spectrum reports 0.

`SPECTRAL_ENVELOPE_SIGMAS` (5) times the spectrum's height deviation is the envelope of the height. It sets `Mesh.local_bounds`, an ocean's node boxes, the [medium](water.md#underwater)'s offset and the mirror's clip plane. While a blend runs it spans the larger of the two spectra; when the blend ends it falls to the new sea's. A seed whose deepest texel lies past five deviations can pass the envelope.

## See also

- [Water](water.md): creating, querying and rendering a body.
- [Reference](water_reference.md): `WaterDesc`, constants and faults.
