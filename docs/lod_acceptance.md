# Mesh LOD acceptance

Review recheck: 2026-10-02, against PR #194's original head
`6af8c163cdd424c250b560ce02608bda25e1b274`. Native Windows, C3 0.8.3,
NVIDIA GeForce RTX 4090, NVIDIA driver 610.88. Output: 1280×720. Vulkan validation
enabled; the process disabled the known third-party implicit overlay only.

The example has 5,000 deterministic placements. Levels contain 672, 54 and 12
triangles. Measurements use the development build, fixed sway time, 30 warmup
frames and 60 measured frames per row, with the default 16,384-node scene
capacity. The table reports the median of three runs' per-row arithmetic means.
GPU time sums recorded pass categories; it excludes presentation and CPU work.
No fallback or validation message occurred.

| Waypoint / mode | Completed frames | Selected 0 / 1 / 2 | Visible 0 / 1 / 2 | Main LOD triangles | CPU record ms | Extraction ms | GPU passes ms | Cull ms |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Near / LOD | 30–89 | 717 / 3793 / 490 | 413 / 1928 / 263 | 384,804 | 1.5282 | 0.0026 | 0.2154 | 0.0431 |
| Near / base | 123–182 | 5000 / 0 / 0 | 2604 / 0 / 0 | 1,749,888 | 1.6406 | 0.0029 | 0.5903 | 0.0412 |
| Middle / LOD | 216–275 | 0 / 1928 / 3072 | 0 / 1687 / 2880 | 125,658 | 1.5703 | 0.0027 | 0.1195 | 0.0436 |
| Middle / base | 309–368 | 5000 / 0 / 0 | 4567 / 0 / 0 | 3,069,024 | 1.6295 | 0.0031 | 0.6545 | 0.0418 |
| Far / LOD | 402–461 | 0 / 0 / 5000 | 0 / 0 / 5000 | 60,000 | 1.4813 | 0.0029 | 0.0834 | 0.0405 |
| Far / base | 495–554 | 5000 / 0 / 0 | 5000 / 0 / 0 | 3,360,000 | 1.4436 | 0.0027 | 0.5396 | 0.0378 |

Near camera: `(0,5,8)`, looking at `(0,2,-25)`. Middle: `(0,40,90)`, looking at
`(0,1,-75)`. Far: `(0,140,280)`, looking at `(0,1,-75)`. LOD bias is zero; the
reference uses bias 20. Near and middle record 56 draw commands; far records 46,
including empty indirect bins. Both modes use the same command counts. Main LOD
triangles are calculated from completed visible counts, once per placement,
excluding additional depth/shadow passes. CPU-counted triangles are 10 in each
row and cover ordinary ground draws only.

The far row reduces main LOD triangle work by 98.2%. Across all rows and runs,
CPU recording took 1.4190–1.7000 ms and extraction took 0.0024–0.0047 ms.
The original-head benchmark recorded 2.3604–2.5929 ms and 0.4395–0.4523 ms,
respectively. Dense selections and active-entry history traversal remove the
per-frame scans of unused entity slots. The persistent CPU history allocation
still scales with scene capacity. These measurements apply to this device,
scene and development build; GPU timing varies between runs.

Nine manual LOD tests cover shared lists with different part geometry counts,
parity, independent views and offscreen shadows, whole-group overflow alongside
a fitting group, slot history and aborted frames, identity reuse, temporal
rejection, shared transparency sorting, part transforms with sway/fade, and
history retirement after mode changes or removal of the last group, and zero
placement-upload bytes during repeated wind edits after warmup. The bin test
also verifies one dense selection in the default-capacity scene.
Color, depth and shadow comparisons use equivalent reference geometry at 512×512
with one-texel tolerance. The full renderer suite passed 170 tests. The full
repository build/test passed 1,518 tests across 31 targets, including 800 core
CPU tests and all add-on targets. The interactive
example completed 30 frames without validation messages. Linux and visual
interaction with every control were not tested in this run.
