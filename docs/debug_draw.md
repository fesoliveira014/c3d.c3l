# Debug lines

`debug::DebugDraw` is the line list an application fills each frame and hands to a view through
`render_view(..., debug: &sink)`. Every helper (`aabb`, `box`, `circle`, `capsule`, `axes`, `frustum`, the
light, joint and probe helpers, and the physics and character packages' `debug_draw`) writes through
`DebugDraw.line`, one segment at a time.

## Capacity and dropped segments

`create_debug_draw(allocator, capacity = DEBUG_LINE_CAPACITY)` preallocates the sink. The capacity is in
segments; each segment is two 16-byte vertices, so the default 16384 segments take 512 KiB at creation.
The renderer uploads whatever the sink holds through the frame's upload ring and has no cap of its own.

A full sink refuses further segments and counts them in `DebugDraw.dropped`, which `clear` resets. What is
drawn first survives a full sink, so draw what matters most first. `Stats.debug_lines` counts the segments
each view drew; `Stats.debug_dropped` is the largest dropped count of a sink drawn this frame, and the stats
panel prints both.

## Sizing a sink

Run the heaviest frame the application reaches with every flag it offers, read
`vertices.len() / 2 + dropped` (the segments it asked for), and add a margin. The physics inspector example
peaked at 28935 segments with every physics draw flag and an open replay over 256 boxes and sizes its sink at
36864 segments (1.1 MiB).
