# Serialization example

Build and run `serialize` through `python3 scripts/build.py --example serialize`.
It loads the bundled Fox asset, makes two instances (one animated), a 1,024-instance
box batch and eight point lights. Startup checks repeated writes and binary/text
read-write identity, removes the original subtree and displays a restored copy.
The panel prints sizes, node/component counts, binary bytes per node and CPU
write/read times. `R` or the button reloads the original snapshot in the selected
format; animation restarts. The camera, sun and Scene settings remain outside
the saved cell.

```bash
c3c build serialize --path examples -O3
./examples/build/serialize --cpu-only
./examples/build/serialize --cpu-only --models=128
./examples/build/serialize --acceptance --frames=180
./examples/build/serialize --original --acceptance --frames=60
./examples/build/serialize --cpu-only --export=cell
```

`--models=128` adds model-heavy CPU export/restoration coverage; the default
remains two instances. Timings are observations for the running host, not a
performance budget.

The last command writes `cell.bin`, `cell.jsonc` and `cell.schema.json` in the
current directory. Direct builds that link shaderc need its shared library next
to the executable; the repository build script supplies it. CPU-only mode does
not create a window or device. Acceptance mode reloads JSONC at frame 60 and
binary at frame 120 with a fixed animation timestep and Vulkan validation.

`--original` keeps the authored cell for visual comparison while running the
round-trip checks in a separate temporary Scene. Reload then switches to the
restored snapshot. Use the same fixed acceptance frame to compare the original
and restored display.
