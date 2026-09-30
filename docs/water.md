# Water

The `c3d_landscape` add-on's `c3d::landscape::water` module draws water bodies. A `Water` component on a node
is a Gerstner surface of up to four waves in the node's local XZ, drawn by the package's shader through a
custom material the library owns. The vertex stage displaces a grid and supplies the depth and velocity forms;
the fragment stage reads the scene's colour and depth snapshots after opaque (a scene-read material, see
[custom shaders](custom_shaders.md)), refracts and absorbs what lies behind the surface, reflects from a
planar mirror target, else a screen-space march over the snapshot, else the environment or the frame's
ambient, adds lit foam, and shades sun glints through the public Standard parts. Ripple normals and foam colour
come from referenced Standard materials; the application's wind scrolls the ripples. A CPU twin of the stage
answers world-space height queries, and `update` places one mirror camera per water body for the view the
application renders the reflection with.

The module imports the standard library, core (`c3d`), `c3d::landscape` (its SPIR-V) and
`c3d::landscape::terrain` (a query predicate); it never imports `gpu`, `c3d::render` or `c3d::physics`.
Buoyancy lives in the physics add-on ([buoyancy](buoyancy.md)); the application connects the two with the
adapter under [Buoyancy](#buoyancy). Core never imports the module.

```bash
python3 scripts/build.py --example water
```

## Select the package

Select `c3d_landscape` as for [terrain](terrain.md#select-the-package). Water needs nothing else; the example
and the buoyancy adapter also select `c3d_physics` and `b3`.

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
physics.set_fluid_surface(&lake_height, &lake_surface);

// every frame, after moving the camera
scene.update_world();
// terrain::update(...) and foliage::update(...) as their docs order them
water::update(
    scene:          &scene,
    assets:         &assets,
    viewing_camera: camera.id,
    wind_velocity:  wind,
    time:           now,
)!;
// the mirror view's clip plane (The mirror)
lake_surface = { .view = water::surface_view(&scene, &assets, lake.id)!, .time = now };
physics.update(delta);
scene.update_world();
// the mirror view first, then the main view
```

- `register_water` runs once per scene. It registers `Water`, `WaterRuntime` and `WaterMirror` and installs
  the runtime's remove hook with the store; the store outlives the scene.
- `add_water` attaches a water body to a node without `Mesh`, `Water` or `WaterRuntime` whose world matrix is
  current. It checks the desc, finds or adds the shared shader, finds or builds the grid, adds the owned
  material, a mirror camera node and the node's `Mesh`, all or nothing: a fault leaves the node, the scene's
  free nodes and the store's free materials as they were.
- `set_desc` is the only way to change a water body. It checks the new desc before it writes anything: a fault
  keeps the old desc, the payload, the material revision, the mesh and the grid. `WaterRuntime.desc` holds the
  checked copy; `update`, the mirror and the queries read it, so an edit of `Water.desc` itself has no effect
  until it goes through `set_desc`.
- `update` runs every frame with the `FrameInfo.time` the frame renders with. It reads the viewing camera's
  `local`, which must be a root node, so it may run before or after `update_world`; each water node's world
  matrix is read as the last `update_world` left it. It tears down removed water bodies, places every mirror
  camera and scrolls the ripples.
- `surface_view` copies a water body's waves and pose; take it after `update` and `set_desc`, before
  `physics.update`, so buoyancy follows a desc edit in the same frame.

## WaterDesc

`default_water_desc()` is a clear lake with two calm crossing waves (0.12 m at 6 m, 1.2 m/s along x; 0.07 m at
3.5 m, 0.9 m/s along (0.6, 0.8); steepness 0.5 each), `DEFAULT_CELL_SIZE`, no extent, the march on and no
references. Every rule below is a fault, not a contract: descs come from files as well as code.

| Field | Rule |
| --- | --- |
| `waves`, `wave_count` | At most `MAX_WAVES` (4). Per wave: amplitude ≥ 0, wavelength > 0, finite speed, a unit direction within 0.001, steepness ≥ 0 |
| steepness | Σ steepness < `wave_count`: the mean steepness stays below 1 (one wave may pass 1 when others are lower) |
| `geometry` | Zero builds a grid; else a live geometry whose bounds lie at y = 0 |
| `extent`, `cell_size` | A built grid only: both positive and finite, at most `MAX_GRID_CELLS` (512) cells per side, every wavelength at least two cells |
| `absorption_color`, `absorption_distance` | Transmittance after the distance, each channel in (0, 1]; the distance positive and finite |
| `scatter_color` | Non-negative and finite: the albedo of the water body under ambient and indirect light |
| `roughness` | In [0, 1] |
| `refraction_strength`, `reflection_distortion` | Non-negative: screen uv per unit of normal tilt |
| `foam_depth` | Non-negative metres of water under which shore foam shows; 0 turns shore foam off |
| `foam_crest` | In [0, 1): the crest factor above which wave foam shows |
| `ripple_drift` | Non-negative: ripple scroll in m/s per m/s of wind |
| `ripples`, `foam` | Zero, or a live `STANDARD` material |
| `march_reflections` | The screen-space march where the planar sample is missing |

## Surface geometry

A built grid has `ceil(extent / cell_size)` cells per side centred on the node, positions only, two
counter-clockwise triangles per cell facing +Y, and is shared per shape through the store key
`c3d_landscape/water_grid/<extent>/<cell_size>` with both values as exact hex floats (120 m at 1.25 m is
`c3d_landscape/water_grid/0x1.ep+6/0x1.4p+0`). A grid stays in the store for the store's lifetime when no body
uses it any more. Past 254 cells per side (65,535 vertices) the renderer switches to 32-bit indices: 120 m at
1.25 m is 9,409 vertices and 55,296 16-bit indices.

Application geometry rests at y = 0; its topology and UVs are its own, and it follows the aliasing rule
(shortest wavelength at least twice its edge length) by itself. Either way the stage writes `uv0` and `uv1` as
the rest position in metres.

`Mesh.local_bounds` is the rest bounds grown by the total amplitude in y and by the sum of the waves'
horizontal crest shifts in x and z, always as a bounds override, which also keeps the water out of every trace
([scene trace](scene_trace.md)). The mesh casts no shadow and receives shadows.

## Waves

For a rest point `p` in the node's local XZ and shader time `t`, per wave `i` with unit direction `d`,
wavelength `λ`, speed `c`, amplitude `a` and steepness `s` over `N` waves:

- `θ = 2π · fract(dot(d, p) / λ − t · c / λ)`: the phase is reduced to one cycle before `sin` and `cos`, whose
  precision GLSL specifies only near [−π, π];
- height `y = Σ a · sin θ`; horizontal shift `D = Σ s · λ / (2π · N) · d · cos θ`;
- drawn point `(p.x + D.x, y, p.y + D.y)`; the normal from the Jacobian of that map; the crest factor
  `clamp(1 − det J, 0, 1)` feeds wave foam.

The waves are node-local: node scale scales wavelengths and amplitudes, node rotation turns the directions.

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
vertical through a point: it inverts the horizontal shift with `WAVE_INVERSION_ITERATIONS` (3) fixed-point steps
`p ← q − D(p)`, which converge while the mean steepness stays below 1, then evaluates the height with the stage's
float operations. A point whose rest position falls outside the rest rectangle is `NOT_FOUND`. The view is a
value: several threads may query it.

Error against 64 iterations, maximum over a 256² grid of points over 64 m at 8 times (c3c 0.8.3 `-O3`, WSL,
one thread):

| Wave set | Total amplitude | No inversion | 1 | 2 | 3 iterations |
| --- | --- | --- | --- | --- | --- |
| Calm: 2 waves, 6 m and 3.5 m, steepness 0.5 | 0.19 m | 74.6 mm | 14.3 mm | 3.6 mm | 1.04 mm |
| Choppy: 4 waves, 12 m to 2 m, steepness 0.8 | 0.73 m | 331 mm | 71.6 mm | 20.3 mm | 6.66 mm |
| Choppy at steepness 0.95 | 0.73 m | 390 mm | 103 mm | 35.1 mm | 13.9 mm |

The test bounds are 1.1 mm (calm) and 6.8 mm (choppy); the device test checks the drawn surface against
`sample_surface` within 1 cm. One sample of the choppy set costs 91 to 109 ns with three iterations.

## Time

The stage reads `FrameInfo.time` as a float (`frame.jitter_time.z`, and `frame.previous_time` in the velocity
form). `sample_surface` and `update` take the same `double` time and narrow it exactly as the frame root does,
so queries see the time the surface is drawn at. From 65,536 s (about 18 h) a float time rounds to within
1/256 s and consecutive times differ by up to 1/128 s; an application that runs that long wraps its clock and
calls `render::reset_view_history` at the wrap. The phase reduction keeps the waves exact at any time.

## Ripples and wind

The ripple reference is a `STANDARD` material whose normal map the stage samples twice at `uv0` plus two
scroll offsets, through the reference's UV transform, sampler and `normal_scale`, and sums the two
perturbations of the wave normal. Its other maps cost their fetches and are ignored. `update` turns the wind
into two node-local scroll velocities: the wind in the node's frame times `ripple_drift`, and the same turned
by `RIPPLE_CROSS_ANGLE`. The stage computes `offset = scroll_origin + scroll_velocity · (time − scroll_time)`;
when the velocities change, `update` starts a new segment at the frame time whose origin is the old segment's
offset there, wrapped to whole texture periods, so the ripples never jump. A steady wind and a still node write
nothing: a steady frame uploads nothing for water. Wind never touches the waves or buoyancy.

## Shading

The fragment stage composes public parts only: `prepare_surface` with an F0 of 0.02, `fresnel_schlick` for the
reflection weight, `evaluate_standard_lights` for sun glints and lit foam, `indirect_diffuse_irradiance` and
`standard_ambient_fill` for the water body and the foam, and the scene snapshot reads:

```
color      = evaluate_standard_lights(surface) + F · reflection
           + (1 − F) · ((1 − foam) · refraction + ambient(foam albedo) + E · foam albedo / π)
refraction = snapshot · T + scatter · (1 − T),  T = absorption_color ^ (path / absorption_distance)
scatter    = ambient(scatter_color) + E · scatter_color / π
foam       = max(crest ramp above foam_crest, 1 − depth gap / foam_depth), with a foam reference only
```

The refraction sample shifts by the normal's tilt in view space times `refraction_strength`, scaled by the
water behind the surface up to 1 m, and falls back to the direct sample when the shifted one lands in front of
the water; a background texel has no bed and absorbs everything. The reflection is the only specular
environment term. Traced forms of the fragment stage let a traced sun shadow the water.

## Reflections

| Condition | Varies | Branch |
| --- | --- | --- |
| The reflection slot is present | per draw | planar tried |
| The planar uv (screen uv plus the tilt offset, clamped to 0.05) lies inside the frame | per pixel | planar sample |
| `march_reflections` | per draw | march tried |
| The march hits: a sample lies behind the snapshot surface by less than two steps | per pixel | snapshot colour |
| Otherwise | | the environment's specular cube at mip 0 times its intensity, else `frame.ambient` |

The march steps 24 times along the reflected ray over four times the pixel's view distance, spaced
quadratically; a sample behind the camera or outside the frame ends it as a miss, and background texels never
hit. The per-pixel branches read with an explicit level of detail. A dead reflection target is an absent slot:
the stage marches, then falls back to the environment.

## The mirror

The library places the mirror; the application renders it. For every water body, `update` sets the mirror
camera node's `local` to the viewing camera's reflected across the image of the node's local XZ plane, gives it
the viewing camera's lens with the water node's layers removed, and writes `WaterRuntime.clip_plane`: the rest
plane lowered by the total amplitude, so everything above the deepest trough stays. The application owns the
target, the view and the order. The example renders the mirror at

```c3
const float MIRROR_RENDER_SCALE = 0.5f; // a quarter of the pixels; --mirror-scale 1 measures the saving
```

as `render_scale`, with these lines of its code, kept identical by hand:

```c3
// Once, after add_water and a first water::update.
RenderTargetId mirror_target = render::create_render_target(
    renderer,
    render::render_target_desc(output_size.x, output_size.y),
)!;
ViewDesc mirror_desc = render::texture_view_desc(mirror_target);
mirror_desc.render_scale = render_scale;
mirror_desc.post.anti_aliasing = AntiAliasing.NONE;
mirror_desc.clip_plane = scene.get(lake, WaterRuntime).clip_plane;
ViewId mirror_view = render::create_view(renderer, mirror_desc)!;
water::set_reflection_target(
    scene:  scene,
    assets: assets,
    node:   lake,
    target: mirror_target,
);

// Every frame, after water::update and before begin_frame: set_desc and a moved lake move the plane.
Plane clip_plane = scene.get(lake, WaterRuntime).clip_plane;
ViewDesc current = renderer.views.get(mirror_view).desc;
if (clip_plane.normal != current.clip_plane.normal || clip_plane.d != current.clip_plane.d) {
    current.clip_plane = clip_plane;
    render::configure_view(renderer, mirror_view, current)!;
}

// In the frame: the mirror before the view that shows the water.
Node* mirror = scene.node(scene.get(lake, WaterRuntime).mirror);
renderer.render_view(scene, mirror, mirror_view)!;
renderer.finish_view(mirror_view)!;
```

- The clip plane changes when the lake node moves or `set_desc` changes the amplitude; `configure_view` resets
  that view's history, and the lines do nothing otherwise.
- A window resize resizes the target: `resize_render_target` keeps the id and the material repacks through the
  target's revision, so `set_reflection_target` is needed only for a new target. Zero removes the slot.
- One mirror view per water plane and viewing camera; lakes at two levels need two mirrors, and the cost scales
  with them.
- A second view that sees the water reflects the mirror camera of the first. Leave the water node's layer out
  of that view's camera layers (the example's `--capture`).

## Buoyancy

The physics add-on's `Buoyancy` component samples a fluid surface the application installs per world
([buoyancy](buoyancy.md)). The adapter over one water body, kept identical by hand in the example; the device
test runs the same function over its own context struct:

```c3
struct LakeSurface {
    SurfaceView view;
    double      time; // the FrameInfo.time of the physics update's first step
}

fn float? lake_height(
    void* context,
    float x,
    float z,
    float step_offset,
) {
    LakeSurface* lake = context;
    return water::sample_surface(
        view:    &lake.view,
        world_x: x,
        world_z: z,
        time:    lake.time + step_offset,
    );
}
```

Several water bodies: hold one view per body and return the first that does not fault; `NOT_FOUND` outside
each body's extent means no fluid there.

## Removal

Remove `Water`, or the node. The runtime's remove hook removes the owned material; the next `update` removes
the node's `Mesh` and `WaterRuntime` and every mirror camera node whose water body is gone. Removing
`WaterRuntime` or the mirror node directly is unsupported; call `update` between removing and adding a water
body on the same node. Destroy the scene before the store.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_water` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_water`, `set_desc` | `c3d::INVALID_ARGUMENT` | A desc value outside its rule (NaN included); application geometry off y = 0; a reference that is not `STANDARD`; a shared key naming another asset kind |
| `add_water`, `set_desc` | `c3d::INVALID_ID` | A dead geometry or reference |
| `add_water`, `set_desc` | `c3d::CAPACITY_EXCEEDED` | A store pool full, or no scene node left for the mirror |
| `update` | `c3d::INVALID_ARGUMENT` | The viewing camera's local transform is not finite |
| `surface_view` | `c3d::INVALID_ID` | Dead entity, no water body, the owned material removed |
| `sample_surface` | `NOT_FOUND` | The point's rest position lies outside the rest rectangle |

## Limits

- **Not traced.** The bounds override keeps water out of every trace: under ray-traced reflections and in
  path-traced views the water surface is absent, not merely unreflected (the lake bed shows through, reflections
  show no water); probe updates see through it; traced shadows ignore it (it casts none). Traced shadows on the
  water work.
- **One mirror per plane and viewing camera**; the viewing camera is a root node. A second view that sees the
  water reflects the mirror camera of the first; leave the water node's layer out of that view's camera layers.
  The mirror view renders its own shadow atlas.
- **Clip plane at the deepest trough**: geometry between a trough and the local surface can appear in the
  reflection; the amplitude bounds the error.
- **Screen-space march**: opaque, masked and sky from this view only; no blends, nothing off-screen or behind
  the camera; 24 steps over four times the pixel's view distance.
- **Blends under the surface are hidden**: the water writes depth and readers never see ordinary blends.
- **SSGI views**: readers keep camera-only velocity ([screen-space GI](screen_space_gi.md)), so moving waves
  smear under TAA there; readers get no AO and no SSGI terms.
- **Wave edits** give one rendering of wrong wave motion vectors: the velocity form evaluates the new waves at
  the previous time. Queries follow once `surface_view` is retaken.
- **Long sessions**: core's float time limit; wrap the clock and call `render::reset_view_history`.
- **Query accuracy**: three inversions: 1.05 mm on the calm set, 6.7 mm at mean steepness 0.8, 13.9 mm at 0.95.
- **Transforms**: drawing takes any node transform (waves scale and rotate with the node; the mirror reflects
  across the image of the local XZ plane); queries require translation plus rotation about Y.
- **One body per lake**: waves are node-local, so two water nodes do not match at a shared edge.
- **Grids** are shared per shape and live for the store's lifetime; application geometry rests at y = 0 and
  follows the aliasing rule by itself.
- **References**: the ripple material contributes its normal map only; foam shows only with a foam reference;
  `uv0` is the rest position in metres.
- **Lighting**: the sun lights glints and foam, not the water body; scatter takes ambient and indirect light.
- **Seen from below** the surface is culled; underwater views are out of scope.
- **No fog** on the water.
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
tiling ripple normal map (4 m tiles) and a generated foam colour, on its own layer bit. The mirror view renders
at `MIRROR_RENDER_SCALE` with the lines above. `--crates 16|256` drops 1 m crates (density 600, drag
3000 N·s/m) over the middle 40 m, each with `Buoyancy` over the adapter above.

Right drag looks, WASD moves, F flies, B raises the ground under the camera (the ground collider re-cooks when
the key lifts). The panel switches the reflection source, the mirror's resolution, the waves (calm or zero),
the ripples, the wind heading and speed, and shows the crates' mean submerged fraction, the physics step time,
scene snapshots and upload bytes; the view stats table shows each view's passes with `--gpu-timings`, and the
targets panel previews the mirror and capture targets.

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
view's passes with `--gpu-timings`, the frame time, `buoyancy_us` (the physics step time per fixed step in
`waves`, at the crate count) and the still segment's upload bytes. Two gates exit 1 when they fail:

- `gate steady_uploads`: the still segment uploads nothing after its first frame (water, foliage and crates
  included);
- `gate crates_at_density_line`: every crate's submerged fraction over the settle segment's last 60 frames lies
  within 0.02 of 0.6.

Switches: `--gpu-timings` (build with `python3 scripts/build.py --target water --opt O3 --define
C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile`), `--validation`, `--shading
forward|deferred`, `--size 1025|2049|4097`, `--reflection planar|march|env` (march: no target; env: no target
and the march off), `--mirror-scale 0.5|1`, `--crates 16|256`, `--ssgi` (SSGI on the main view),
`--traced` (the main view path-traced: the water is absent), `--capture` (a second view on a 384² target whose
camera leaves out the water's layer), `--ripples on|off` and `--width W --height H` (2560 × 1440 by default in
benchmark mode). Interactive runs always validate.

## Measured cost

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
