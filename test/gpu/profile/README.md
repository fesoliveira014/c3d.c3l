# Manual GPU profiling acceptance

Build the repository's generated shaders and the profiler example, then invoke
this project separately:

```bash
python3 scripts/build.py --target profile_gpu
c3c test acceptance --path test/gpu/profile
```

These tests create real Vulkan devices with validation enabled. They do not run
in the root test matrix or CI. They require graphics timestamps and fail clearly
when that capability is absent; an unavailable device is not a passed hardware
check. On Windows, the build step places the shader compiler DLL beside this
project's executable in `build/profile_gpu`.

The workload renders two views, samples a rendered pixel through custom compute,
and reads back that pixel plus a compute-written counter. It checks interleaved
view finishes, frame-wide Stats, original shadow/view identities, successful and
rejected shader replacement, aborts, empty recordings, tiny query/label budgets,
history pressure, capture toggling, slot reuse, resize, preparation and teardown.
The rejected shader deliberately violates the unsigned compute-root header ABI.

The automated manual cases are headless. A real presentation failure after
submission and a physical device without graphics timestamps require separate
hardware observations; passing this suite does not establish either case. The
neutral data tests cover pending publication after an aborted CPU capture.

The headless example prints an owned JSON capture after renderer teardown:

```bash
./examples/build/profile_gpu > capture.json
```

Use `profile_gpu.exe` on Windows. Correctness runs use validation; their timing
values are not an instrumentation-overhead benchmark.
