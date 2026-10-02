# Static impostor acceptance

Verified 2026-10-02 on native Windows 11 Pro, build 26200, Intel Core i9-14900K, C3 0.8.3,
NVIDIA GeForce RTX 4090, NVIDIA driver 610.88. Vulkan validation was enabled;
the process disabled the known third-party implicit overlay only. GPU tests
run separately from CI.

## Verification

The repository build passed all examples and 1,524 CPU tests across 31 targets,
including 806 core tests. The native renderer suite passed all 178 tests with
Vulkan validation enabled and no validation errors. Generated output matched
126 core stages, 37 public-include probes, 20 package stages and 54 embedded
includes. The windowed example completed 30 frames with validation enabled.

Six CPU tests cover descriptor arithmetic, atomic installation and ownership,
frame mapping and seam ties, quantization, cell gutters and padding ownership.
Eight manual GPU tests cover the following contracts:

| Check | Observed result |
| --- | --- |
| Isolated bake | Nonzero subject transform, overlapping sibling and custom public background/view are preserved; only the subject enters the atlas. Default atlas is exactly 1024×2048 and 8 MiB. Covered texels have alpha 255 with metallic zero. |
| Cube geometry | All six directions at projected diameter 24 pixels pass Forward/Deferred with depth prepass on/off at 512×512, for both bare and strongly normal-mapped surfaces (48 cases). Coverage matches the mesh in every case; maximum view-depth error is 0.021795 versus the unchanged 0.078961 quantization-plus-one-pixel bound. |
| Fixed-light shading | Maximum RGB difference inside flat face interiors is 0.002441 for the bare surface and 0.003418 with the tilted normal map in linear space, below the 0.01 gate. The comparison excludes a one-pixel band around reference silhouette and face-normal discontinuities. Hard-normal boundaries remain filtered atlas approximations. |
| Occlusion | A thin plane in front of/behind the reconstructed cube has the expected visibility and depth in all four render paths, including camera motion and an impostor bound crossing the near plane. |
| Textured cutouts | Known mask holes remain empty. Neutral normal-map texels decode within two degrees of a cube face normal; roughness map/factor packing differs by at most one byte. |
| Transform and shadow | A reflected, nonuniformly scaled, offscreen placement with fixed HEIGHT sway casts onto a visible receiver. Camera and light directions differ. Against the base mesh, 26 of 23,438 shadow-union pixels differ beyond one-pixel tolerance (0.111%, below the unchanged 3% limit). |
| Motion and fallback | Ordinary/instanced translation agrees within 1e-4 UV. Another instance and another view do not contribute inherited motion. Frame-triplet/LOD changes reject affected pixels. Removing the atlas restores mesh rendering and the missing-atlas counter. Scene preparation uploads the atlas before use. |
| Failure cleanup | Unsupported material/deformed geometry, duplicate key and exhausted texture capacity return their named faults, without a new atlas or leaked view/target/tracked host allocation. A later supported bake succeeds. |

Reconstruction uses a projected capture-plane estimate and two corrections from
the sampled depth gradient. A failed coverage/depth check tries a second,
center-plane estimate with the same two-correction limit. Bake-time nearest
surface padding supplies depth estimates in transparent texels while preserving
coverage. Both padding and refinement are independent of shading normals. A
strongly tilted normal-map regression verifies that material normals do not
change geometry. Sway inversion and the local ray tangent are computed outside
the atlas-sample loop. The final local point is recovered separately for motion.

The test compares light-relative reconstruction against the base-mesh shadow
and an unoccluded receiver. It does not establish exact shadows for arbitrary
thin or multiply occluded geometry. The cube gate and tree images also do not
establish close-up quality or suitability for every vegetation asset.

## Reproduction

```powershell
python scripts/build.py --test
c3c test acceptance --path test/gpu/render
examples/build/lod.exe --benchmark
examples/build/lod.exe --frames 30
```

The benchmark saves `lod-far-impostor.png`, `lod-far-mesh.png`,
`lod-far-base.png`, `lod-high-detail-impostor.png` and `lod-high-detail-base.png`
after the timed rows. These compare identical placements within each case.
All five final images were inspected. The atlas follows the rounded source
canopy; the coarsest mesh uses a cone.

## Runtime measurements

The example uses 5,000 deterministic placements, default 16,384-node scene
capacity, 1280×720 output, three 1024×1024 shadow cascades and fixed sway time.
Each row warms 30 frames and records 60; values below are medians of three
runs' row means. GPU time sums recorded pass categories and excludes CPU work,
presentation, image export and the startup bake. No fallback or validation
message occurred. This is the development build on one device.

All modes retain the same atlas metadata and common bounds. Mesh-only sets its
terminal threshold below every tree's size inside the far plane; forced-base
also uses bias 20. This prevents bounds changes from confounding the comparison.
Near is `(0,5,8)` looking at `(0,2,-25)`; middle is `(0,40,90)` looking at
`(0,1,-75)`; far is `(0,240,600)` looking at `(0,1,-75)`. The far waypoint differs
from the earlier mesh-only acceptance report. Results from the two reports
must not be compared as the same workload.

Counts list mesh levels 0/1/2 followed by terminal impostor. Their triangle
counts are 672/54/12/2. Main triangles use completed visible counts, once per
placement; additional shadow/depth passes are excluded. Draw counts include
empty indirect bins. Ordinary ground contributes ten CPU-counted triangles at
near/middle and six at far.

| Waypoint / mode | Completed frames | Selected | Visible | Main triangles | Draws | CPU record ms | Extract ms | GPU passes ms |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Near / impostor | 94–153 | 2559/2441/0/0 | 1410/1289/0/0 | 1,017,126 | 66 | 1.5453 | 0.0024 | 0.3534 |
| Near / mesh | 187–246 | 2559/2441/0/0 | 1410/1289/0/0 | 1,017,126 | 66 | 1.5302 | 0.0026 | 0.3539 |
| Near / base | 280–339 | 5000/0/0/0 | 2699/0/0/0 | 1,813,728 | 66 | 1.5520 | 0.0025 | 0.5526 |
| Middle / impostor | 373–432 | 382/4616/2/0 | 382/4223/2/0 | 484,770 | 66 | 1.5164 | 0.0024 | 0.1795 |
| Middle / mesh | 466–525 | 382/4616/2/0 | 382/4223/2/0 | 484,770 | 66 | 1.5499 | 0.0027 | 0.1797 |
| Middle / base | 559–618 | 5000/0/0/0 | 4607/0/0/0 | 3,095,904 | 66 | 1.5350 | 0.0025 | 0.6605 |
| Far / impostor | 652–711 | 0/0/0/5000 | 0/0/0/5000 | 10,000 | 40 | 1.2681 | 0.0025 | 0.4186 |
| Far / mesh | 745–804 | 0/0/5000/0 | 0/0/5000/0 | 60,000 | 40 | 1.2788 | 0.0025 | 0.0696 |
| Far / base | 838–897 | 5000/0/0/0 | 5000/0/0/0 | 3,360,000 | 40 | 1.3107 | 0.0027 | 0.5721 |
| High detail / impostor | 995–1054 | 0/5000/0/0 | 0/5000/0/0 | 10,000 | 36 | 1.3135 | 0.0022 | 1.4011 |
| High detail / base | 1088–1147 | 5000/0/0/0 | 5000/0/0/0 | 48,000,000 | 36 | 1.3708 | 0.0029 | 5.2525 |

| Waypoint / mode | Cull ms | Shadow ms | Depth ms | Forward ms | Composite ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Near / impostor | 0.0407 | 0.1923 | 0.0521 | 0.0623 | 0.0064 |
| Near / mesh | 0.0409 | 0.1925 | 0.0521 | 0.0624 | 0.0064 |
| Near / base | 0.0382 | 0.2949 | 0.1217 | 0.0934 | 0.0066 |
| Middle / impostor | 0.0405 | 0.0526 | 0.0334 | 0.0468 | 0.0065 |
| Middle / mesh | 0.0405 | 0.0528 | 0.0336 | 0.0468 | 0.0064 |
| Middle / base | 0.0380 | 0.2307 | 0.2171 | 0.1686 | 0.0067 |
| Far / impostor | 0.0353 | 0.1231 | 0.1512 | 0.1015 | 0.0068 |
| Far / mesh | 0.0362 | 0.0095 | 0.0071 | 0.0105 | 0.0061 |
| Far / base | 0.0338 | 0.1622 | 0.1628 | 0.2044 | 0.0071 |
| High detail / impostor | 0.0363 | 0.2017 | 0.6178 | 0.5423 | 0.0067 |
| High detail / base | 0.0418 | 1.8312 | 1.6783 | 1.6815 | 0.0070 |

Each column is an independent median, so pass medians need not sum exactly to
the median total. The revised far impostor result is **0.4186 ms**, versus
**4.6323 ms** before revision on the same workload (11.1× lower). It remains
slower than the 12-triangle coarse mesh at **0.0696 ms**; the 672-triangle base
measures **0.5721 ms**. Main triangles remain 10,000 / 60,000 / 3,360,000.

The additional **high-detail** case uses a separate single-level group with
9,600 source triangles per tree, the same placement algorithm, a camera at
`(0,90,200)` looking at `(0,1,-75)`, and a terminal threshold of 0.08. Both modes
retain that group's atlas and bounds. All 5,000 placements are visible. Counts
for this case use mesh level 0 / terminal / unused / unused. It measures
**1.4011 ms** for 10,000 impostor triangles and **5.2525 ms** for 48,000,000 source
triangles, a 3.75× GPU improvement at this larger projected size. The three-run
ranges are 1.3803–1.4104 ms and 5.2286–5.2613 ms. This case intentionally has no
intermediate simplified mesh; it does not replace the coarse-mesh comparison.

### Conservative-depth experiment

A temporary variant emitted the quad at the nearest depth of the reconstruction
sphere and declared `layout(depth_less)`. This is a permitted opportunity for
early rejection, not a guarantee that the driver uses it; the written depth must
satisfy the declared bound ([Khronos Vulkan Guide](https://docs.vulkan.org/guide/latest/depth.html#conservative-depth)).
Three runs of the final reconstruction gave:

| Case | Existing depth handling, median (range) ms | Conservative depth, median (range) ms |
| --- | ---: | ---: |
| Far / impostor | 0.4186 (0.4158–0.4201) | 0.4206 (0.4198–0.4360) |
| High detail / impostor | 1.4011 (1.3803–1.4104) | 1.4587 (1.4534–1.4786) |

The measured scene showed no gain. The additional bound calculation and
qualifier were omitted; the production shader retains its existing depth output.

## Bake cost and memory

The original tree prototype bake took 208.046–208.998 ms across the three runs
(median 208.739 ms); the detailed prototype took 193.170–198.193 ms (median
194.182 ms). The earlier bake, without surface padding, had a 177.203 ms median.
These are measured authoring costs, outside the runtime rows.

| Explicit allocation | Bytes |
| --- | ---: |
| Atlas texels transferred to the store | 8,388,608 |
| Private capture attachment texels | 762,048 |
| Mapped color/normal/depth readback | 254,016 |
| Capture scene peak tracked host allocation | 9,867 |
| Reusable padding scratch, 64-bit host | 262,144 |

Padding uses one scratch allocation for all frames and is freed after the bake.
The scratch size is `2 * cell_size * cell_size * usz::size`; it is separate from
the existing bake-stat categories. These categories exclude driver padding/caches,
upload rings, retained renderer mirrors and tracking metadata; they are not a process-memory delta. CPU atlas
ownership persists in the store. A prepared renderer additionally owns the
uploaded atlas image. Clear/remove of a group retains that borrowed asset.

Linux runtime, other devices, arbitrary production vegetation and interactive
operation of every GUI control were not validated in this run. CI covers CPU
and build checks; native GPU acceptance remains manual.
