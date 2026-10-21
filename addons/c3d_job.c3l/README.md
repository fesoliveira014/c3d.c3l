# Job add-on

`c3d_job` runs a function over index ranges on a fixed pool of worker threads. It is fork-join: `run` splits `[0, count)` into ranges, `wait` returns once they have finished, and `is_finished` reports it without blocking. Runs are frame work or background work, with a cap on the workers that take background ranges. With zero workers every frame range runs on the calling thread. The pool also sets the processors its workers bind to.

## Boundaries

`c3d::job` imports the standard library and core (`c3d`). It never imports `gpu`, `sdl`, `imgui`, `b3` or another add-on, except `c3d::profile` in `src/profile.c3` alone under `C3D_PROFILE_CPU`. Core never imports it and has no job flag. Its platform files `src/affinity_linux.c3` and `src/affinity_win32.c3` declare `@private` externs for the libc and kernel32 processor-affinity calls the standard library already links, with their native structs pinned by `$assert`; no other module declares system externs.

## Select the package

List `c3d_job` next to `c3d` and core's dependencies in `project.json`; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names.

| Feature | Effect | Also select |
| --- | --- | --- |
| `C3D_PROFILE_CPU` | Records the ranges each worker ran and forwards them to a profiler recorder | `c3d_profile` |

## Quick start

```c3
JobPool pool = job::create_job_pool(mem, job::default_job_pool_desc())!;
defer job::destroy_job_pool(&pool);

fn void integrate_range(void* data, uint first, uint count) {
    Particles* particles = data;
    for (uint item = first; item < first + count; item++) {
        particles.positions[item] += particles.velocities[item] * particles.dt;
    }
}

JobId id = pool.run(
    range: &integrate_range,
    data:  &particles,
    count: (uint)particles.positions.len,
    batch: 256,
);
pool.wait(id);
```

The ranges of one run must write disjoint data. Add-ons that take a `ParallelFor` hook (core declares it) run on a pool through a short function the application writes.

## Targets and examples

| Target | Kind |
| --- | --- |
| `job_test` | CPU tests |
| `job_profile_test` | CPU tests under `C3D_PROFILE_CPU` |
| `job_bench` | Example; `python3 scripts/build.py --example job_bench` |

```bash
c3c test job_test --path addons/c3d_job.c3l
```

## Guides

- [Job pool](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/jobs.md): descriptor, runs, background work, processors and profiling.
- [Profiling](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/profiling.md) for the recorder that receives worker ranges.
