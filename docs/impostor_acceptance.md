# Static impostor acceptance

Verified 2026-10-02 on native Windows 11 Pro, build 26200, Intel Core i9-14900K, C3 0.8.3,
NVIDIA GeForce RTX 4090, NVIDIA driver 610.88. Vulkan validation was enabled;
the process disabled the known third-party implicit overlay only. GPU tests
run separately from CI.

## Verification

The repository build passed all examples and 1,523 CPU tests across 31 targets,
including 805 core tests. The final example edit was rebuilt and all CPU targets
were rerun. The native renderer suite passed all 177 tests with no validation
errors. Generated output matched 126 core shader stages, 37 public-include
probes, 20 package stages and 54 embedded includes. The windowed `lod` example
completed 30 frames with validation enabled.

Five CPU tests cover descriptor arithmetic, atomic installation and ownership,
frame mapping and seam ties, quantization, and cell gutters. Seven manual GPU
tests cover the following contracts:

| Check | Observed result |
| --- | --- |
| Isolated bake | Nonzero subject transform, overlapping sibling and custom public background/view are preserved; only the subject enters the atlas. Default atlas is exactly 1024×2048 and 8 MiB. Covered texels have alpha 255 with metallic zero. |
| Cube geometry | All six directions at projected diameter 24 pixels pass Forward/Deferred with depth prepass on/off at 512×512. Maximum coverage difference is 0.309% of union; maximum view-depth error is 0.007608 versus the 0.078961 quantization-plus-one-pixel bound. |
| Fixed-light shading | Maximum RGB difference inside flat face interiors is 0.002441 in linear space, below the 0.01 gate. The comparison excludes a one-pixel band around reference silhouette and face-normal discontinuities. Hard-normal boundaries remain filtered atlas approximations. |
| Occlusion | A thin plane in front of/behind the reconstructed cube has the expected visibility and depth in all four render paths, including camera motion. |
| Textured cutouts | Known mask holes remain empty. Neutral normal-map texels decode within two degrees of a cube face normal; roughness map/factor packing differs by at most one byte. |
| Transform and shadow | A reflected, nonuniformly scaled, offscreen placement with fixed HEIGHT sway casts onto a visible receiver. Camera and light directions differ. Against the base mesh, 587 of 23,382 shadow-union pixels differ beyond one-pixel tolerance (2.51%, below 3%). |
| Motion and fallback | Ordinary/instanced translation agrees within 1e-4 UV. Another instance and another view do not contribute inherited motion. Frame-triplet/LOD changes reject affected pixels. Removing the atlas restores mesh rendering and the missing-atlas counter. Scene preparation uploads the atlas before use. |
| Failure cleanup | Unsupported material/deformed geometry, duplicate key and exhausted texture capacity return their named faults, without a new atlas or leaked view/target/tracked host allocation. A later supported bake succeeds. |

The shadow comparison exposed undersampling with eight surface-search brackets:
2,377 of 23,382 pixels differed beyond one-pixel tolerance. The implementation
retains 32 brackets and eight refinements per contributing direction. Failure
masks and diagnostic logs were retained during validation; the geometric gate
was not relaxed.

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

The benchmark saves `lod-far-impostor.png`, `lod-far-mesh.png` and
`lod-far-base.png` in the current directory after the timed runs. The three
1280×720 images were inspected: all retain the same field placement; the
impostor follows the rounded base canopy, while the coarse mesh uses a cone.
These images show a distant field, not close-up detail.

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
| Near / impostor | 94–153 | 2559/2441/0/0 | 1410/1289/0/0 | 1,017,126 | 66 | 1.5643 | 0.0026 | 0.3531 |
| Near / mesh | 187–246 | 2559/2441/0/0 | 1410/1289/0/0 | 1,017,126 | 66 | 1.5643 | 0.0025 | 0.3523 |
| Near / base | 280–339 | 5000/0/0/0 | 2699/0/0/0 | 1,813,728 | 66 | 1.5565 | 0.0025 | 0.5707 |
| Middle / impostor | 373–432 | 382/4616/2/0 | 382/4223/2/0 | 484,770 | 66 | 1.5378 | 0.0025 | 0.1787 |
| Middle / mesh | 466–525 | 382/4616/2/0 | 382/4223/2/0 | 484,770 | 66 | 1.5420 | 0.0025 | 0.1783 |
| Middle / base | 559–618 | 5000/0/0/0 | 4607/0/0/0 | 3,095,904 | 66 | 1.5362 | 0.0024 | 0.6347 |
| Far / impostor | 652–711 | 0/0/0/5000 | 0/0/0/5000 | 10,000 | 40 | 1.3820 | 0.0031 | 4.6323 |
| Far / mesh | 745–804 | 0/0/5000/0 | 0/0/5000/0 | 60,000 | 40 | 1.2488 | 0.0024 | 0.0686 |
| Far / base | 838–897 | 5000/0/0/0 | 5000/0/0/0 | 3,360,000 | 40 | 1.3007 | 0.0024 | 0.5363 |

| Waypoint / mode | Cull ms | Shadow ms | Depth ms | Forward ms | Composite ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Near / impostor | 0.0412 | 0.1937 | 0.0515 | 0.0609 | 0.0064 |
| Near / mesh | 0.0411 | 0.1932 | 0.0514 | 0.0610 | 0.0065 |
| Near / base | 0.0384 | 0.2968 | 0.1162 | 0.0938 | 0.0066 |
| Middle / impostor | 0.0409 | 0.0536 | 0.0331 | 0.0453 | 0.0065 |
| Middle / mesh | 0.0410 | 0.0538 | 0.0331 | 0.0449 | 0.0064 |
| Middle / base | 0.0394 | 0.2373 | 0.1946 | 0.1538 | 0.0065 |
| Far / impostor | 0.0362 | 1.3500 | 1.4954 | 1.7627 | 0.0071 |
| Far / mesh | 0.0357 | 0.0091 | 0.0068 | 0.0106 | 0.0061 |
| Far / base | 0.0333 | 0.1558 | 0.1545 | 0.1859 | 0.0074 |

Each column is an independent median, so per-pass medians need not sum exactly
to the median total. The terminal choice reduces far main-view triangles by
83.3% versus the coarsest mesh and 99.7% versus base. It increases GPU time:
4.6323 ms versus 0.0686 ms and 0.5363 ms. Reconstruction dominates shadow,
depth and forward passes. This implementation demonstrates the atlas contract
and geometric acceptance; it is not a performance improvement for this scene.

## Bake cost and memory

The prototype bake took 176.528–181.920 ms across the three benchmark runs;
the median was 177.203 ms. The separate windowed startup took 188.965 ms.

| Explicit allocation | Bytes |
| --- | ---: |
| Atlas texels transferred to the store | 8,388,608 |
| Private capture attachment texels | 762,048 |
| Mapped color/normal/depth readback | 254,016 |
| Capture scene peak tracked host allocation | 9,867 |

These categories exclude driver padding/caches, upload rings, retained renderer
mirrors and tracking metadata; they are not a process-memory delta. CPU atlas
ownership persists in the store. A prepared renderer additionally owns the
uploaded atlas image. Clear/remove of a group retains that borrowed asset.

Linux runtime, other devices, arbitrary production vegetation and interactive
operation of every GUI control were not validated in this run. CI covers CPU
and build checks; native GPU acceptance remains manual.
