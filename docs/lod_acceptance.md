# Mesh LOD acceptance

Baseline: `d04b457dfc44f2c5db97846691823d2b8b074bca`. Native Windows, C3 0.8.3,
NVIDIA GeForce RTX 4090, NVIDIA driver 610.88. Output: 1280×720. Vulkan validation
enabled; the process disabled the known third-party implicit overlay only.

The example has 5,000 deterministic placements. Levels contain 672, 54 and 12
triangles. Measurements use the development build, fixed sway time, 30 warmup
frames and 60 measured frames per row. GPU time sums recorded pass categories;
it excludes presentation and CPU work. CPU values are arithmetic means.
No fallback or validation message occurred.

| Waypoint / mode | Completed frames | Selected 0 / 1 / 2 | Visible 0 / 1 / 2 | Main LOD triangles | CPU record ms | Extraction ms | GPU passes ms | Cull ms |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Near / LOD | 30–89 | 717 / 3793 / 490 | 413 / 1928 / 263 | 384,804 | 2.5929 | 0.4501 | 0.2082 | 0.0436 |
| Near / base | 123–182 | 5000 / 0 / 0 | 2604 / 0 / 0 | 1,749,888 | 2.5067 | 0.4455 | 0.5305 | 0.0421 |
| Middle / LOD | 216–275 | 0 / 1928 / 3072 | 0 / 1687 / 2880 | 125,658 | 2.4930 | 0.4438 | 0.1240 | 0.0433 |
| Middle / base | 309–368 | 5000 / 0 / 0 | 4567 / 0 / 0 | 3,069,024 | 2.4950 | 0.4395 | 0.5257 | 0.0422 |
| Far / LOD | 402–461 | 0 / 0 / 5000 | 0 / 0 / 5000 | 60,000 | 2.4504 | 0.4523 | 0.0877 | 0.0415 |
| Far / base | 495–554 | 5000 / 0 / 0 | 5000 / 0 / 0 | 3,360,000 | 2.3604 | 0.4428 | 0.4668 | 0.0385 |

Near camera: `(0,5,8)`, looking at `(0,2,-25)`. Middle: `(0,40,90)`, looking at
`(0,1,-75)`. Far: `(0,140,280)`, looking at `(0,1,-75)`. LOD bias is zero; the
reference uses bias 20. Near and middle record 56 draw commands; far records 46,
including empty indirect bins. Both modes use the same command counts. Main LOD
triangles are calculated from completed visible counts, once per placement,
excluding additional depth/shadow passes. CPU-counted triangles are 10 in each
row and cover ordinary ground draws only.

The far row reduces main LOD triangle work by 98.2%. This workload reduced GPU
pass time; it did not reduce CPU recording time. These results apply to this
device, scene and build.

Eight manual LOD tests cover shared lists with different part geometry counts,
parity, independent views and offscreen shadows, whole-group overflow alongside
a fitting group, slot history and aborted frames, identity reuse, temporal
rejection, shared transparency sorting, part transforms with sway/fade, and
history retirement after mode changes or removal of the last group.
Color, depth and shadow comparisons use equivalent reference geometry at 512×512
with one-texel tolerance. The full renderer suite passed 169 tests. The full
repository build/test passed, including 799 core CPU tests and all add-on targets. The interactive
example completed 30 frames without validation messages. Linux and visual
interaction with every control were not tested in this run.
