# Camera-relative rendering

The scene keeps absolute float transforms. The renderer subtracts one shared
origin before composing GPU models, bounds, camera matrices and trace data.
Choose a reference near the cameras whose precision matters for this frame:

```c3
scene.update_world();
FrameInfo info = {
    .time = time,
    .delta = delta,
    .reference_position = camera_node.world_position(),
};
renderer.begin_frame(info)!;
renderer.prepare_scene_trace(&scene)!;
renderer.render_view(&scene, mirror_camera, mirror_view)!;
renderer.finish_view(mirror_view)!;
renderer.render_view(&scene, camera_node, main_view)!;
renderer.finish_view(main_view)!;
renderer.end_frame()!;
```

`Renderer.render` and `render_to` accept the same `FrameInfo`. Its default zero
reference preserves the original near-origin behavior. A nonfinite reference
faults `c3d::INVALID_ARGUMENT` before changing frame state.

## Origin selection

`render::frame_origin_for` rounds each reference coordinate to the nearest
multiple of 256 metres. Half-cell ties go toward positive infinity: 128 selects
256 and -128 selects zero. Double intermediates avoid an integer cell-index
limit. The selected `Renderer.frame_origin` stays fixed from `begin_frame`
through submission or abort. The first frame and camera cuts use the current
explicit reference; view order does not select it.

Every view, shadow camera, producer view, trace preparation and probe update in
the frame uses that origin. Cameras far apart still share one origin. Select a
reference appropriate for the intended views; this API provides no independent
coordinate space per view.

## Coordinate contract

| Values | Space |
| --- | --- |
| Scene nodes, asset data, CPU picking, spatial queries, simulation | Existing absolute world or declared local space |
| `FrameInfo.reference_position`, `ViewDesc.clip_plane`, debug line endpoints | Absolute world |
| `FrameRoot.origin.xyz` | Absolute origin; `w` is zero |
| Current draw models, GPU instance models, frame camera/light/probe positions, trace rows and rays | Absolute world minus the frame origin |
| Current view/projection matrices, clip plane, reconstructed scene positions | Same relative space |
| Geometry, joint palettes, morphs, instance placement sources, water waves | Existing local spaces |
| Previous models and previous view projection | The origin recorded with that view's previous rendering |

The renderer converts before transforming retained local bounds and composing
local instance placements. Subtracting the origin from an already rounded
absolute AABB or composed instance matrix cannot recover lost detail.
`maths::rebase` preserves an affine matrix's basis, scale and homogeneous row.
Spatial bound helpers accept an optional origin; omitting it retains their
absolute-world result.

The shader ABI appends `FrameRoot.origin` at byte 512; the root is 528 bytes.
Rebuild consumer shader packages against the current generated headers.
Custom stages using the published mesh, lighting, fog, scene-read and trace
helpers receive compatible relative values. Application-provided absolute
positions in custom payloads must be converted before combining them with these
values. Add `frame.origin.xyz` only when an absolute value is required; doing so
reintroduces float precision limits. Directions and local positions do not
receive this offset. Do not subtract it again from core-packed models.

## Persistent data and history

Resident mesh, billboard and LOD records carry the origin used to pack them.
An unchanged batch reuses its allocation and data within a cell. Crossing a
cell rewrites each consumed batch once, shared by all views. Abort invalidates
unsubmitted uploads through the existing upload protocol.

Raster history records its origin with its view projection and pose. A reference
change preserves valid temporal history; previous models and camera
reprojection account for the origin difference. Camera velocity combines the
clip-to-clip mapping in double precision on the CPU before narrowing it for the
shader, avoiding repeated subtraction of distant translations per pixel.
Finite-far backgrounds retain directional reprojection. LOD placement history has an
independent origin because its last rendering need not match another view.
Rejected LOD history uses current geometry mapped to the previous projection's
space. Aborting a staged view invalidates that history, as before.

Path accumulation resets when the packing origin changes, then resumes on
subsequent unchanged frames. This avoids mixing samples from different trace
transforms.

`prepare_scene_trace` called inside a frame uses its selected origin. Called
between frames, it uses the most recently selected origin, initially zero. A
later frame with a different origin rewrites the top-level data before use.
Local acceleration data remains reusable. The root address is stable; its
contents and coordinate space can change. Custom dispatches must express rays
in the space of the preparation they consume.

## Shadows, effects and add-ons

Directional cascades fit relative camera and caster bounds while retaining a
world-fixed shadow texel lattice. Changing only the render reference preserves
that lattice. Physically translating the whole scene can change its phase
against the lattice and therefore the sampled shadow edge.

Sway compensates for the origin in its packed phase, including previous-frame
sway. Distance fade compares relative anchors and cameras. Height fog converts
its base height with the camera; atmosphere cache identity retains absolute
physical altitude. Probe movement tracking remains absolute, so reference
changes preserve atlas storage and partial sweep progress.

Terrain, water, foliage and particle rendering use the same core contract.
Their CPU simulation, authoring coordinates, seeds and local wave functions
remain unchanged. Impostor baking selects a reference for its capture scene.
Physics, character, navigation and particle simulation have no origin-shift API
from this feature.

## Precision limits and acceptance

This improves calculations after the scene has accepted float inputs. It does
not restore precision lost when storing absolute positions, updating a distant
hierarchy or running a simulation. Nearby local placements retain more detail
when their parent translation is removed before composition. The caller still
owns simulation precision and scene-coordinate policy.

CPU acceptance compares float raster math with double inverse/product results
from the same accepted float matrices at 0, 10, 50 and 100 km. The conditioned
perspective and orthographic fixtures require NDC x/y error at most `1e-5` and
strict improvement for the perspective fixture at 50 km. This is a fixture
bound, not a global error guarantee for arbitrary inputs or distant views.

Run the CPU and shader suite with `python3 scripts/build.py --test`. Vulkan
acceptance stays outside CI:

```text
c3c test acceptance --path test/gpu/render
c3c test terrain_acceptance --path addons/c3d_landscape.c3l/test/gpu
c3c test water_acceptance --path addons/c3d_landscape.c3l/test/gpu
c3c test particle_acceptance --path addons/c3d_particle.c3l/test/gpu
python3 scripts/build.py --example shadows
```

The shadows example's offset control moves the fixture from its retained local
poses. It displays the selected frame origin and the first cascade's movement
at the solid box in texels per frame. Hold the camera, light and scene still to
check stability; camera or light motion may legitimately move the grid.

## Origin-policy benchmark

`test/gpu/render/bench_origin.c3` renders a static shadow fixture or a 2,048-instance
batch with four 1024-pixel cascades, a 512-pixel target, hardware trace preparation
and validation. It discards 32 warm-up frames and prints 128 measured frames;
GPU pass totals are matched by completed renderer frame index. CPU recording
includes extraction, packing, trace preparation and submission. It excludes the
wait at `begin_frame`. The exact-reference mode is a benchmark experiment; it
does not add a renderer option.

```text
c3c build origin_bench --path test/gpu/render -O3
build/render_acceptance/origin_bench.exe zero shadows
build/render_acceptance/origin_bench.exe zero population
build/render_acceptance/origin_bench.exe grid population
build/render_acceptance/origin_bench.exe exact population
```

For grid/exact comparison, the scene is at `(65536, 0, 65536)` and the reference
advances four metres per frame while the camera stays fixed. This isolates the
cost of changing packing coordinates. Compare before/after builds with the
`zero` mode and identical settings. Hardware, driver, build mode and validation
affect timings; counters and the measured scene size belong with reported times.
