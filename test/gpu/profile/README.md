# Profiler GPU acceptance

Manual Vulkan acceptance for GPU profiling ([profiling](../../../docs/profiling.md#capture-gpu-work)). The tests render
a small headless workload with two views and custom compute dispatches, and check that GPU captures and `Stats` keep the
right view, pass, shadow and shader identities through aborts, rejected shader replacements, history pressure, capture
toggling, resize and teardown. They need graphics timestamp support and fail when the device lacks it.

## Run

```bash
python3 scripts/build.py --target profile_gpu
c3c test acceptance --path test/gpu/profile
```

- The project does not run under `python3 scripts/build.py --test` or in CI. It creates real Vulkan devices with
  validation enabled.
- The project compiles shaders in process, so the shaderc shared library must sit beside the test executable in
  `build/profile_gpu`. `build.py` copies it there when it builds the default set or `--target profile_gpu`.
- For software Vulkan and WSL, see [Headless and WSL runs](../../../docs/development.md#headless-and-wsl-runs).

## Capture to JSON

The `profile_gpu` example runs the same kind of workload and prints an owned JSON capture after renderer teardown:

```bash
./examples/build/profile_gpu > capture.json
```

Use `profile_gpu.exe` on Windows.

## Limits

- The cases are headless. A presentation failure after submission, and a physical device without graphics timestamps,
  need separate hardware observations.
- The neutral data tests of `addons/c3d_profile.c3l` cover pending publication after an aborted CPU capture.
- Validation is on, so timings are not an instrumentation-overhead measurement.
