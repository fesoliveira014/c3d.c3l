# Water reference

Reference for the `c3d::landscape::water` module: the desc rules, the API, the constants and the faults. The [water guide](water.md) explains how to use them and [wave models](water_wave_models.md) describes the three models.

## WaterDesc

`default_water_desc()` returns a clear lake with two calm crossing waves, `DEFAULT_CELL_SIZE`, no extent, the march on, one mirror slot, view texture slot 0 and no references. Its other values:

| Field | Default |
| --- | --- |
| `absorption_color`, `absorption_distance` | (0.35, 0.6, 0.75), 4 m |
| `scatter_color` | (0.02, 0.08, 0.1) |
| `roughness`, `refraction_strength`, `reflection_distortion` | 0.05, 0.02, 0.05 |
| `foam_depth`, `foam_crest`, `ripple_drift` | 0.4 m, 0.5, 0.03 |
| `depth` | `DEFAULT_WATER_DEPTH` (40 m) |
| `simulation` | `DEFAULT_WAVE_SPEED` (3 m/s), `DEFAULT_DAMPING` (0.5/s) |
| `spectrum` | `DEFAULT_SPECTRUM_SEED` (382), `DEFAULT_PATCH_SIZE` (256 m), `DEFAULT_CHOPPINESS` (1) |

`attach_water`, `add_water`, `prepare`, `prepare_subtree` and `set_desc` check every rule below and fault `INVALID_ARGUMENT` (or `INVALID_ID` for a dead id) rather than assert, because descs also come from files.

| Field | Rule |
| --- | --- |
| `waves`, `wave_count` | At most `MAX_WAVES` (4). Per wave: amplitude ≥ 0, wavelength > 0, finite speed, a unit direction within 0.001, steepness ≥ 0. A `SIMULATED` or `SPECTRAL` body draws none of them |
| steepness | Σ steepness < `wave_count`: the mean steepness stays below 1 (one wave may pass 1 when others are lower) |
| `geometry` | Zero builds a grid; else a live geometry whose bounds lie at y = 0. An ocean takes none |
| `extent`, `cell_size` | A built grid: both positive and finite, at most `MAX_GRID_CELLS` (512) cells per side, every wavelength at least two cells (a `SIMULATED` or `SPECTRAL` body has no wavelengths to check). An ocean: both positive and finite, at most `MAX_OCEAN_CHUNKS` (256) chunks of `cell_size * OCEAN_CHUNK_CELLS` per side, every wavelength at least four cells of the finest level (a `SPECTRAL` body has none to check) |
| `absorption_color`, `absorption_distance` | Transmittance after the distance, each channel in (0, 1]; the distance positive and finite. 1 on every channel is clear water, with no medium |
| `scatter_color` | Non-negative and finite: the single-scattering albedo of the medium, clamped to `MAX_SCATTER_ALBEDO` (0.98) |
| `roughness` | In [0, 1] |
| `refraction_strength`, `reflection_distortion` | Non-negative: screen uv per unit of normal tilt |
| `foam_depth` | Non-negative metres of water under which shore foam shows; 0 turns shore foam off |
| `foam_crest` | In [0, 1): the crest factor above which wave foam shows. The crest factor of the Gerstner map is `clamp(1 − det J, 0, 1)`, with `J` the Jacobian of the horizontal shift; simulated and spectral surfaces have none |
| `ripple_drift` | Non-negative: ripple scroll in m/s per m/s of wind |
| `ripples`, `foam` | Zero, or a live `STANDARD` material |
| `march_reflections` | The screen-space march in views that provide no reflection slot |
| `max_mirrors` | In [1, `MAX_MIRRORS` (8)]: the mirror slots, one per viewing view |
| `reflection_view_slot` | Below `material::MAX_VIEW_TEXTURES` (4): the [view texture](views.md#view-textures) the material samples |
| `trace` | Scene traces see the displaced surface, posed every frame; off by default; an ocean cannot trace |
| `mode` | `BODY` (default) or `OCEAN` |
| `depth` | Positive and finite metres below the rest plane: where the [medium](water.md#underwater)'s box ends. Water not deeper than its troughs has no medium |
| `wave_model` | `GERSTNER` (default), `SIMULATED` or `SPECTRAL`. `prepare` faults `UNSUPPORTED` for `SPECTRAL` without `C3D_LANDSCAPE_GPU` |
| `simulation` | Read by `SIMULATED`: `wave_speed` in m/s and `damping` in 1/s, each positive and finite. `SIMULATED` is refused with `OCEAN`, with application geometry, with fewer than `MIN_SIMULATION_CELLS` (16) or more than `MAX_SIMULATION_CELLS` (256) cells per side, and where `wave_speed` needs more than `MAX_SIMULATION_SUBSTEPS` (8) substeps per fixed step |
| `spectrum` | Read by `SPECTRAL`: `patch_size` positive and finite metres per tile, `choppiness` non-negative and finite, and a `seed` of any value |
| `ground` | Zero, or a node carrying `Terrain`: the terrain whose high ground a `SIMULATED` body treats as dry. A dead node faults `INVALID_ID`, a node without `Terrain` `INVALID_ARGUMENT` |

Application geometry rests at y = 0 and keeps its own topology and UVs. It follows the aliasing rule (shortest wavelength at least twice its edge length) itself. The shader writes `uv0` and `uv1` as the rest position in metres.

A built grid has two counter-clockwise triangles per cell facing +Y, and is shared per shape through the store key `c3d_landscape/water_grid/<extent>/<cell_size>` with both values as exact hex floats. It stays in the store for the store's lifetime. Past 254 cells per side the renderer switches to 32-bit indices. For a body, `Mesh.local_bounds` is the rest bounds grown by the total amplitude in y and by the crest shifts in x and z. A simulated body grows it by `SIMULATION_MAX_HEIGHT`; a spectral body by its envelope. The mesh casts no shadow and receives shadows.

## Components

| Type | Role |
| --- | --- |
| `Water` | Authored component: `desc`. Edit through `set_desc` |
| `WaterRuntime` | Written by the library: the checked `desc`, the owned `material`, the `grid` (shared per shape, or the desc's geometry), `mirrors` by slot, `medium_node`, `clip_plane`, `rest_min` and `rest_max`, and `spectral_bound` |
| `WaterMirror` | Marks a mirror camera node the library owns; names its water node and slot |

`WaterRuntime.rest_min` and `rest_max` are the node-local XZ extent of the rest surface.

## Functions

| Function | Purpose |
| --- | --- |
| `register_water(scene, assets)` | Register the three components and the remove hook, once per scene |
| `default_water_desc()` | A clear lake with two calm waves |
| `add_water(scene, assets, node, desc)` | Attach and prepare a body |
| `attach_water(scene, assets, node, desc)` | Validate and attach pending authoring |
| `is_prepared(scene, node)` | Whether `WaterRuntime` exists |
| `prepare(scene, assets, node)`, `prepare_subtree(scene, assets, root = null)` | Complete pending water; prepared water is unchanged |
| `set_desc(scene, assets, node, desc)` | Replace a prepared body's desc |
| `update(scene, assets, wind_velocity, time)` | Per-frame upkeep: ripples, blends, simulation, oceans, removed bodies |
| `set_sea_state(scene, assets, node, wind_velocity, transition_seconds)` | Set the waves from a wind. `node` is an `Entity`, `wind_velocity` a `Vec2` |
| `add_impulse(scene, node, world_position, radius, strength)` | Push a simulated surface down at a world point |
| `update_mirror(scene, body, slot, viewing_camera)` | Place one slot's mirror camera; returns `PLACED` or `BELOW` |
| `release_mirror(scene, body, slot)` | Free one slot's camera node |
| `surface_view(scene, assets, node)` | Copy a body's waves and pose into a `SurfaceView` |
| `sample_surface(view, world_x, world_z, time)` | World height of the drawn surface |
| `sample_surface_detail(view, world_x, world_z, time)` | Height, normal, velocity and residual as a `WaterSample` |
| `fluid_sample(context, x, z, step_offset, velocity)` | Buoyancy sampler over a `WaterFluid` |
| `ocean_snap_step(desc)` | Metres an ocean node moves by to keep vertices on their world positions |
| `water_gpu::update(renderer, scene, assets)` | Record the spectral passes; needs `C3D_LANDSCAPE_GPU` |

`surface_view` and `sample_surface` require translation and rotation about Y only.

A `WaterSample` holds `height`, `normal`, `velocity` and `residual`. For a Gerstner body the query's rest point is within `residual · k / (1 − k)` of the true one, with `k` the mean steepness, and the height is within the waves' height slope times that.

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `MAX_WAVES` | 4 | Gerstner waves per body |
| `MAX_GRID_CELLS` | 512 | Cells per side of a built grid |
| `MAX_MIRRORS` | 8 | Mirror slots per body |
| `DEFAULT_CELL_SIZE` | 1.25 m | Built-grid vertex spacing at the default |
| `OCEAN_CHUNK_CELLS` | 64 | Cells per chunk edge of an ocean |
| `MAX_OCEAN_CHUNKS` | 256 | Chunks per side of an ocean's finest level |
| `DEFAULT_WATER_DEPTH` | 40 m | Medium depth at the default |
| `WATER_QUERY_TOLERANCE` | 0.0001 m | Inversion step under which a query stops |
| `MAX_INVERSION_ITERATIONS` | 8 | Inversion steps per query, at most |
| `RIPPLE_CROSS_ANGLE`, `RIPPLE_SECOND_SCALE` | 0.6 rad, 1.618034 | Turn and scale of the second ripple layer |
| `MEDIUM_ANISOTROPY` | 0.6 | Henyey-Greenstein `g` of the medium |
| `MAX_SCATTER_ALBEDO` | 0.98 | Clamp of the scattering albedo |
| `MEDIUM_SKIN` | 0.02 m | Gap between the deepest trough and the medium's top |
| `SIMULATION_RATE` | 60 | Fixed simulation steps per second |
| `CFL_LIMIT` | 0.5 | Largest wave speed times substep over spacing |
| `MAX_SIMULATION_SUBSTEPS` | 8 | Substeps per fixed step |
| `MAX_SIMULATION_STEPS_PER_UPDATE` | 4 | Fixed steps per `update`; excess time is dropped |
| `MIN_SIMULATION_CELLS`, `MAX_SIMULATION_CELLS` | 16, 256 | Cells per side of a simulated body |
| `SIMULATION_MAX_HEIGHT` | 1 m | Clamp of simulated heights |
| `SETTLED_HEIGHT`, `SETTLED_SPEED` | 0.5 mm, 2 mm/s | Thresholds under which a body settles |
| `DEFAULT_WAVE_SPEED`, `DEFAULT_DAMPING` | 3 m/s, 0.5/s | Simulation defaults |
| `SPECTRAL_SIZE` | 256 | Texels per side of the field |
| `SPECTRAL_TWIN_WAVES` | 64 | Components the CPU twin evaluates |
| `SPECTRAL_ENVELOPE_SIGMAS`, `SPECTRAL_BOUND_SIGMAS` | 5, 3 | Deviations the envelope and the twin bound span |
| `SPECTRAL_PERIOD` | 1000 s | Repeat period of the field |
| `DEFAULT_SPECTRAL_WIND` | (8, 0) m/s | Wind before a sea state is set |
| `DEFAULT_SPECTRUM_SEED`, `DEFAULT_PATCH_SIZE`, `DEFAULT_CHOPPINESS` | 382, 256 m, 1 | Spectrum defaults |
| `water_gpu::DISPATCHES_PER_BODY` | 18 | Compute dispatches `water_gpu::update` records per spectral body; exists under `C3D_LANDSCAPE_GPU` |

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_water` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `attach_water`, `add_water`, `prepare`, `prepare_subtree`, `set_desc` | `c3d::INVALID_ARGUMENT` | A desc value outside its rule (NaN included); application geometry off y = 0; an ocean with geometry, with `trace`, wider than `MAX_OCEAN_CHUNKS` chunks, or with a wave under four finest cells; a reference that is not `STANDARD` |
| same | `c3d::INVALID_ARGUMENT` | `SIMULATED` with an ocean or application geometry, outside 16 to 256 cells per side, with a speed or damping that is not positive and finite, or a speed that needs more than `MAX_SIMULATION_SUBSTEPS`; a `ground` without `Terrain`; `SPECTRAL` with a bad `patch_size` or `choppiness` |
| same | `c3d::INVALID_ID` | A dead geometry, reference or `ground` |
| `add_water`, `prepare`, `prepare_subtree`, `set_desc` | `c3d::INVALID_ARGUMENT` | A shared key (the shader or a built grid) that names another asset kind |
| `add_water`, `prepare`, `prepare_subtree` | `c3d::UNSUPPORTED` | A `SPECTRAL` body in a build without `C3D_LANDSCAPE_GPU` |
| `add_water`, `prepare`, `prepare_subtree` | `c3d::CAPACITY_EXCEEDED` | A store pool is full, or no scene node is left for the medium or the mirrors |
| `set_desc` | `c3d::CAPACITY_EXCEEDED` | A changed shape needs a new grid and the store is full |
| `set_desc` | `c3d::INVALID_ARGUMENT` | A `mode` or `wave_model`, an ocean's, simulated body's or spectral body's `extent` or `cell_size`, or a spectral body's `spectrum` that differs from the prepared body's |
| `set_sea_state` | `c3d::INVALID_ID` | A dead entity, no `Water`, or pending water whose geometry was removed |
| `set_sea_state` | `c3d::INVALID_ARGUMENT` | A non-finite wind, or a negative or non-finite transition |
| `set_sea_state` | `c3d::UNSUPPORTED` | A `SIMULATED` body, or `SPECTRAL` water that is still pending |
| `add_impulse` | `c3d::INVALID_ID` | A dead node, a node without prepared water, or a body that is not `SIMULATED` |
| `add_impulse` | `c3d::INVALID_ARGUMENT` | A position that is not finite, a radius that is not finite and positive, a strength that is negative or not finite |
| `update_mirror` | `c3d::INVALID_ID` | A dead body, a node without prepared water or a dead viewing camera |
| `update_mirror` | `c3d::INVALID_ARGUMENT` | The viewing camera's local transform is not finite |
| `update_mirror` | `c3d::CAPACITY_EXCEEDED` | No scene node left for the camera of a slot freed by `release_mirror` |
| `surface_view` | `c3d::INVALID_ID` | A dead entity, no prepared water, or the owned material removed |
| `sample_surface`, `sample_surface_detail`, `fluid_sample` | `NOT_FOUND` | The point's rest position lies outside the rest rectangle |
| `water_gpu::update` | `c3d::CAPACITY_EXCEEDED` | The store has no room for the three compute stages |
| `water_gpu::update` | those of `AssetStore.add_compute_shader` and `Renderer.dispatch` | Inherited unchanged |

## See also

- [Water](water.md) and [wave models](water_wave_models.md).
- [Landscape package](../addons/c3d_landscape.c3l/README.md).
