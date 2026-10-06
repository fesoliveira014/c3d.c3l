# Job pool

The `c3d_job` add-on (`addons/c3d_job.c3l`, module `c3d::job`) runs a function over index ranges on a fixed
pool of worker threads. It is fork-join: `run` splits `[0, count)` into ranges and queues them, `wait`
returns once every range of that run has finished, and `is_finished` reports it without blocking. A run is
either frame work or background work; frame ranges are taken first, and a cap bounds how many workers run
background ranges at once. With zero workers every frame range runs on the calling thread. The package imports
only the standard library and `c3d`; core never imports it and has no job feature flag.

```bash
python3 scripts/build.py --example job_bench
```

## Select the package

List `c3d_job` before `c3d` in the application's `project.json`, with c3d's own dependencies:

```json
{
  "dependency-search-paths": [ "path/to/c3d.c3l/lib" ],
  "dependencies": [ "c3d_job", "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "cgltf", "ufbx", "shaderc" ]
}
```

## Create and destroy

```c3
JobPool pool = job::create_job_pool(mem, job::default_job_pool_desc())!;
defer job::destroy_job_pool(&pool);
```

`create_job_pool` allocates the pool state, the worker array and the run table once, then starts the workers
and returns once each has bound itself to its processors. It faults `c3d::CAPACITY_EXCEEDED` when an allocation
fails, `c3d::INVALID_ARGUMENT` or `c3d::UNSUPPORTED` for a processor set it cannot apply
([Processors](#processors)), and passes on `thread::INIT_FAILED` when the system refuses the mutex, a condition
variable or a thread; either way everything created so far is released. The allocator is called from the
worker threads, so it must be thread-safe and must not be `tmem`.

`destroy_job_pool` waits for every outstanding run, stops and joins the workers, frees everything and zeroes
the handle. A `defer` on an error path is safe while runs are in flight. `JobPool` is a value handle over
heap state: moving the handle keeps the pool running, and copies share one pool, which is destroyed once.

| `JobPoolDesc` field | Default | Meaning |
| --- | --- | --- |
| `worker_count` | available processors within the quota, minus one, at least 1 | Shared worker threads; 0 runs every frame range on the calling thread. |
| `worker_temp_bytes` | 256 KiB | Initial temp allocator of each worker. |
| `run_capacity` | 64 | Frame runs with unfinished ranges at once. |
| `background_run_capacity` | 64 | Background runs with unfinished ranges at once; 0 refuses every background run. |
| `background_workers` | `default_background_workers(worker_count)` | Shared workers that may run background ranges at once. |
| `background_only_workers` | 0 | Further workers that take only background ranges, outside the cap. |
| `worker_cpus` | empty | Processors of the shared workers; empty leaves the system's choice. |
| `background_cpus` | empty | Processors of the background-only workers; empty leaves the system's choice. |

`default_job_pool_desc()` fills these. A cap at or above `worker_count` does not limit, so a descriptor that
lowers `worker_count` also sets `background_workers`, usually to `job::default_background_workers(count)`:
a quarter of the workers, at least one, and none without workers. That is 1 at 4 workers, 2 at 8, 4 at 16 and 7
at 31. A quarter keeps three quarters of the workers on frame work while background ranges run.

The default `worker_count` is one less than the processors the pool may use, and at least one:
`max(min(available, quota) - 1, 1)`, where `available` counts `job::available_cpus()` and `quota` is
`job::cpu_quota()` when it returns one.

| Host | `available` | `quota` | Default workers |
| --- | ---: | ---: | ---: |
| 32 logical processors, unrestricted | 32 | none | 31 |
| the same under `taskset -c 0-3` | 4 | none | 3 |
| the same in a container with a 2.5-processor quota (`cpu.max` `250000 100000`) | 32 | 3 | 2 |

The count has four caveats:

1. On Windows `available_cpus()` covers the calling thread's processor group only, and `cpu_quota()` never
   returns a quota: job-object rate limits are not read.
2. box3d's workers run only inside `PhysicsWorld.step`. The two pools oversubscribe the machine only when an
   application runs jobs during a physics step; such an application lowers `worker_count`.
3. Processors numbered 1024 and up are not represented.
4. There is no upper limit; none has been measured to be needed.

## Run and wait

```c3
struct Particles {
    Vec3[] positions;
    Vec3[] velocities;
    float  dt;
}

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
// other work on this thread
pool.wait(id);
```

- **Split.** A run of `count` items at `batch = b` has `ceil(count / b)` ranges, `[i * b, min((i + 1) * b,
  count))`; only the last one is short. `batch = 0` lets the pool choose about four ranges per shared worker,
  the caller included; background-only workers do not count. `count = 0` runs nothing.
- **`run`** queues the ranges as a frame run and returns at once with a `JobId`. `data` is handed to every
  range and must outlive the run; it may be null.
- **`wait(id)`** returns once every range of the run has finished. Meanwhile the waiting thread runs that run's
  unclaimed ranges itself, whatever its class. Everything the ranges wrote is visible to the caller after
  `wait` returns.
- **`is_finished(id)`** reports whether every range of the run has finished, without blocking. Once it returns
  true, everything the ranges wrote is visible to the caller. A run's slot is released when its last range
  finishes, whether or not anyone waits on it or asks. Polling alone never finishes a background run on a pool
  with no worker that takes background ranges; see [Background runs](#background-runs).
- **Zero and stale ids.** `run` returns the zero id when every range ran inside the call. An id goes stale when
  its run finishes; its slot is reused only after that. `wait` on a zero or stale id returns at once and never
  waits on a later run in the same slot, and `is_finished` reports both as finished. A slot's generation wraps
  after 2^32 - 1 runs, so an id that old may name a later run.
- **`wait_all`** returns once no run of either class is unfinished, running any unclaimed range meanwhile.
- **Inline mode.** With `worker_count = 0`, `run` runs every range on the calling thread, in ascending order,
  and returns the zero id. Results equal the pooled results when ranges follow the rules below.
- **Nesting.** A range may call `run` on its own pool. The nested run executes inline on the range's thread,
  so nesting never deadlocks, and returns the zero id; `wait` on it returns at once. This holds for ranges on
  a worker and for ranges the caller runs while it waits. A nested `try_run` queues instead; the range never
  waits on that run.

Workers claim ranges in this order: the oldest frame run first, then the oldest background run while the cap
allows, and within a run in ascending index order. Completion order between ranges and between runs is not a
guarantee.

## Background runs

```c3
JobId streaming = pool.try_run(
    job_class: BACKGROUND,
    range:     &decode_range,
    data:      &decode,
    count:     (uint)decode.blocks.len,
    batch:     1,
)!; // c3d::CAPACITY_EXCEEDED when every background slot is held

// a later frame, on the submitting thread
if (pool.is_finished(streaming)) publish(&decode);
```

- **`try_run(job_class, ...)`** queues a run of either class, or faults `c3d::CAPACITY_EXCEEDED` when that
  class's partition of the run table is full. A refused run queues nothing and runs nothing, and
  `inline_ranges` does not move. It never runs a range inside the call, with one exception: on a pool without
  shared workers, frame work runs on the caller as `run` does. Background runs are submitted only through
  `try_run`.
- **Cap.** At most `background_workers` shared workers run background ranges at once; the others take only
  frame ranges, and a worker takes a frame range before a background one. Background work therefore runs in
  frame idle time: a pool that is never idle of frame work starves it, by design. A range that has started is
  never interrupted, so a long background range delays frame work only by holding its own worker.
- **`pump(max_ranges)`** runs background ranges on the calling thread, in submission order, up to
  `max_ranges`, and returns how many ran. It runs only ranges queued before the call: a background run that a
  pumped range submits waits for the next `pump`. It ignores the cap, which limits workers and not the calling
  thread, and it never takes frame ranges.
- **Background-only workers.** `background_only_workers` adds workers that take only background ranges, in the
  same order, and do not count against the cap. They never take frame ranges, so a pool with zero shared
  workers and some background-only workers runs frame work inline and background work on its workers.
- **Without background workers.** With no background-only worker and either zero workers or
  `background_workers = 0`, a background run progresses only through `pump`, `wait` on that run, `wait_all` or
  `destroy_job_pool`. A consumer that polls `is_finished` alone on such a pool never sees the run finish.
- **Capacity.** `background_run_capacity` slots hold background runs and `run_capacity` slots hold frame runs,
  in one table. Each class fills only its own slots, so background runs that span frames never push frame runs
  inline, and a full frame partition never refuses a background run. A background slot holds its run until
  the last range finishes, across frames.

## Run capacity

Each run with unfinished ranges holds one slot of its class, whatever its range count; a slot keeps the
request and the index of the next unclaimed range, so the number of ranges queued at once has no limit of its
own.

`run` never faults and never blocks. A frame run that finds no free frame slot runs inline entirely on the
caller before `run` returns, and `run` returns the zero id; no run is split between the pool and the caller.
`JobPool.inline_ranges()` counts those ranges since the pool was created. A count that grows is the sign that
`run_capacity` is too small. Nested runs and inline mode are inline by design and are not counted. `try_run`
refuses instead of running inline.

### Changes from v0.1.0

`JobPoolDesc.ring_capacity` and `DEFAULT_RING_CAPACITY` are gone: the pool queues runs, not ranges. Remove both
from descriptors.

## Processors

`job::CpuSet` is the standard library's `BitSet{1024}`, indexed by logical processor. On Windows the index
numbers processor groups consecutively: group 1 starts after the active processors of group 0.

- **`available_cpus()`** returns the processors the calling thread may run on: on Linux its affinity mask,
  which `taskset` and cgroup cpusets narrow; on Windows its affinity within its processor group. Linux has no
  process-wide mask, so `default_job_pool_desc` and `create_job_pool` read it on the creating thread: create
  the pool before binding that thread.
- **`cpu_quota()`** returns the Linux cgroup CPU quota in whole processors, rounded up: cgroup v2 `cpu.max`
  under `/sys/fs/cgroup`, cgroup v1 `cpu.cfs_quota_us` and `cpu.cfs_period_us` under `/sys/fs/cgroup/cpu`,
  for the process's cgroup and every ancestor, the tightest one winning. An unlimited, missing or malformed
  quota returns `NOT_FOUND`, as Windows always does. Other mount points are not searched.
- **`core_types()`** splits `available_cpus()` into the fastest core type (`performance`) and the rest
  (`efficiency`): Windows ranks cores by `EfficiencyClass`; Linux reads `/sys/devices/cpu_core/cpus` on Intel
  hybrid processors, otherwise each processor's `cpu_capacity`. Where neither exists, or every core ranks the
  same, `performance` holds every available processor and `efficiency` is empty.

`worker_cpus` binds the shared workers and `background_cpus` the background-only workers. A requested set is
first intersected with the creating thread's `available_cpus()`, so a worker never widens its own mask; a
worker binds itself when it starts, reads its mask back, and `create_job_pool` returns once every worker has
reported. `JobPool.worker_cpus(worker)` returns what each one read back, shared workers first.

| Request | Result |
| --- | --- |
| empty | the worker keeps the system's choice: on Linux the creating thread's mask, on Windows the process's affinity |
| partly outside `available_cpus()` | bound to the intersection |
| entirely outside `available_cpus()` | `c3d::INVALID_ARGUMENT` |
| spanning two Windows processor groups | `c3d::UNSUPPORTED` |
| refused by the system, or read back as another set | `c3d::UNSUPPORTED` |

On a hybrid processor, keep frame work on the performance cores and background work on the efficiency cores:

```c3
CoreTypes types = job::core_types();
JobPoolDesc desc = job::default_job_pool_desc();
desc.worker_count = (uint)types.performance.cardinality() - 1;
desc.background_workers = 0;
desc.background_only_workers = (uint)types.efficiency.cardinality();
desc.worker_cpus = types.performance;
desc.background_cpus = types.efficiency;
JobPool pool = job::create_job_pool(mem, desc)!;
```

On an i9-14900K under Windows, `performance` is processors 0-15 (eight cores with two threads each) and
`efficiency` 16-31. The pool does not bind the calling thread. An application that binds it, for the ranges it
runs in `wait`, does so after `create_job_pool`; bound first, it would narrow every worker's set to its own.

## Temp memory

Every range runs inside its own `@pool()` on the thread that runs it, so `tmem` inside a range is that
thread's and is reset after the range. Each worker creates its temp allocator once, `worker_temp_bytes` from
the pool's allocator. A range whose scratch exceeds `worker_temp_bytes` allocates and frees a page each time it
runs; size it to the largest range's scratch. Each range's `@pool()` also needs about 17 KiB of it (the
standard library's 16 KiB minimum plus a 1 KiB reserve), so at 16 KiB or less every range allocates, empty
or not.

`job_bench`'s kernel holds 64 bytes of scratch per item: 4 KiB per range at batch 64, 64 KiB at 1024, and up
to 2 MiB at its coarsest batch (32 768 items), which exceeds the default and allocates a page per range.

## Thread-affinity and memory rules

The pool does not check these; a range that breaks them races.

- A range runs on a worker or on the thread that called `run`, `try_run`, `wait`, `wait_all`, `pump` or
  `destroy_job_pool`. It never calls the renderer, gpu.c3l submission or command recording, SDL or ImGui;
  never changes scene or ECS structure (adding or removing nodes or components, registering component types);
  never writes a store another range reads.
- Outputs are disjoint per item. Any reduction is gathered in index order after the wait. A consumer's result
  must not depend on how the work is split.
- A range allocates scratch only through `tmem`, which is its own thread's and reset after the range; it must
  not keep `tmem` memory beyond the range, and must not use an allocator passed in from the caller, such as a
  caller's `tmem` stored in `data`. Inline ranges on the caller follow the same rule under their own
  `@pool()`.
- A thread other than the main thread that calls `run`, `try_run`, `wait`, `wait_all`, `pump` or
  `destroy_job_pool` has its own temp allocator (`@pool_init`), because ranges it runs open `@pool()`.
- A range may call `run` on its own pool (it runs inline) and `wait` on the zero id it gets. It may call
  `try_run` (the run queues) and `is_finished`. A range never calls `wait_all`, `pump` or `destroy_job_pool`
  on its own pool, and never waits on any other run of its own pool (its own run, an outer run, a run it
  queued with `try_run`, or a run that waits on it): these are contracts, so the deadlock fires as a contract
  failure instead of hanging. Waiting on another pool's run is not detected.

## Profiling

The pool records no profiler scopes. The profiler's recorder is per thread, so ranges on workers are never
recorded; only the caller's thread records. Wrap `run` and `wait` in application scopes to see submission
and waiting, including the ranges the caller runs while it waits. `job_bench` measures with its own timer.

## Measured cost

`job_bench` (built with `python3 scripts/build.py --target job_bench --opt O3`) prints one CSV line per
configuration. Overhead lines time one run of 1024 empty ranges at batch 1; the time per range is the median
of eleven passes divided by 1024. Kernel lines run 16 `Mat4` multiplies per item against a shared chain;
serial is the same run on a zero-worker pool (the same split, on the caller), and the overhead share is
`ranges * us_per_range / serial_us` with the overhead line of the same worker count. Every pooled output
equals its serial output bit for bit. The tables hold the median of three process runs per line.

Background lines time one background run of 1024 empty ranges at batch 1, from `try_run` until its last range
has run, on the capped workers alone; the caller only polls. Loaded lines time the 65 536-item kernel at batch
1024 once idle and once while a background run of 16 384 ranges of about 15 µs keeps the default cap of
workers busy; the ratio is the median loaded time over the median idle time, and every run's background
work outlasted the timing.

### WSL, 32 logical processors (default 31 workers)

| Workers | µs per empty range | Inline ranges |
| ---: | ---: | ---: |
| 0 | 0.0078 | 0 |
| 1 | 0.0488 | 0 |
| 3 | 0.0581 | 0 |
| 31 | 0.1907 | 0 |

| Workers | Items | Batch | Ranges | Serial µs | Pooled µs | Speedup | Overhead share | Peak scratch |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 16384 | 64 | 256 | 971.3 | 514.1 | 1.88 | 0.0130 | 4 KiB |
| 1 | 16384 | 1024 | 16 | 974.9 | 493.1 | 1.97 | 0.0008 | 64 KiB |
| 1 | 16384 | 2048 | 8 | 941.4 | 465.7 | 2.00 | 0.0004 | 128 KiB |
| 1 | 65536 | 64 | 1024 | 3980.9 | 1988.8 | 2.01 | 0.0114 | 4 KiB |
| 1 | 65536 | 1024 | 64 | 3792.7 | 1900.4 | 2.00 | 0.0008 | 64 KiB |
| 1 | 65536 | 8192 | 8 | 3858.7 | 1857.8 | 2.06 | 0.0001 | 512 KiB |
| 1 | 262144 | 64 | 4096 | 15619.3 | 8053.7 | 1.91 | 0.0129 | 4 KiB |
| 1 | 262144 | 1024 | 256 | 15701.6 | 8753.3 | 1.81 | 0.0008 | 64 KiB |
| 1 | 262144 | 32768 | 8 | 15790.5 | 8146.9 | 1.96 | 0.0000 | 2 MiB |
| 3 | 16384 | 64 | 256 | 920.9 | 299.6 | 3.07 | 0.0167 | 4 KiB |
| 3 | 16384 | 1024 | 16 | 929.8 | 264.4 | 3.58 | 0.0010 | 64 KiB |
| 3 | 65536 | 64 | 1024 | 3807.2 | 1149.3 | 3.35 | 0.0159 | 4 KiB |
| 3 | 65536 | 1024 | 64 | 3785.8 | 985.8 | 3.84 | 0.0010 | 64 KiB |
| 3 | 65536 | 4096 | 16 | 3763.5 | 978.7 | 3.82 | 0.0003 | 256 KiB |
| 3 | 262144 | 64 | 4096 | 15717.7 | 4738.2 | 3.32 | 0.0154 | 4 KiB |
| 3 | 262144 | 1024 | 256 | 17799.9 | 5498.3 | 3.32 | 0.0009 | 64 KiB |
| 3 | 262144 | 16384 | 16 | 18407.0 | 4610.4 | 3.59 | 0.0001 | 1 MiB |
| 31 | 16384 | 64 | 256 | 934.3 | 327.3 | 2.85 | 0.0523 | 4 KiB |
| 31 | 16384 | 1024 | 16 | 934.7 | 338.4 | 2.79 | 0.0032 | 64 KiB |
| 31 | 16384 | 128 | 128 | 931.2 | 305.2 | 3.05 | 0.0264 | 8 KiB |
| 31 | 65536 | 64 | 1024 | 4198.5 | 728.7 | 5.54 | 0.0465 | 4 KiB |
| 31 | 65536 | 1024 | 64 | 3853.0 | 574.5 | 6.71 | 0.0032 | 64 KiB |
| 31 | 65536 | 512 | 128 | 3811.7 | 541.6 | 7.04 | 0.0064 | 32 KiB |
| 31 | 262144 | 64 | 4096 | 16076.0 | 2216.5 | 7.25 | 0.0486 | 4 KiB |
| 31 | 262144 | 1024 | 256 | 15685.0 | 1626.1 | 9.69 | 0.0031 | 64 KiB |
| 31 | 262144 | 2048 | 128 | 15628.1 | 1502.5 | 10.46 | 0.0015 | 128 KiB |

With one worker the caller doubles the throughput by running ranges while it waits. The time per empty range
grows with the worker count, since every range is one claim and one completion under the pool lock. At 31
workers, batch 64 costs 5 % of the serial time; batches of 128 items or more stay under 3 %.

Background runs, capped workers only:

| Workers | Background cap | µs per empty background range |
| ---: | ---: | ---: |
| 1 | 1 | 0.0325 |
| 3 | 1 | 0.0337 |
| 31 | 7 | 0.1911 |

Kernel time with and without a background run holding the cap (medians of three runs; the ratio is the
ratio of the two medians):

| Workers | Background cap | Idle µs | Loaded µs | Ratio |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1982.6 | 1930.2 | 0.97 |
| 3 | 1 | 968.1 | 943.0 | 0.97 |
| 31 | 7 | 587.6 | 645.0 | 1.10 |

With one and three workers the loaded kernel stays within 3 % of idle. At 31 workers the loaded median is 10 %
above idle; the per-run ratios are 0.95, 0.99 and 1.22, so a background run holding the cap of 7 workers can slow
the frame kernel there.

### Windows host, 32 logical processors (default 31 workers)

Pending: the overhead, kernel, background and loaded tables of this pool on the Windows host, medians of three
runs with the range of the three, and for 31 workers the minimum, median and maximum.

### Revisit threshold

The single lock is kept while no median exceeds 2 µs per empty range. Each range is one claim and one completion under the pool lock; `wait` claims its own
run's ranges directly. On WSL the time per range stays under 0.2 µs and the kernel median overhead share at 31
workers and batch 64 is 0.0523, 0.0465 and 0.0486 for 16 384, 65 536 and 262 144 items. The lock-free design is
carried forward with this measurement as its trigger: it is taken up when the share at 31 workers and batch 64
rises above this change's recorded value (0.0523 on WSL; the Windows value is pending the reviewer's run) on
either host. The design is a per-run atomic claim cursor and completion count, with the lock kept for queue
membership and sleep. With many workers, use batches of about 512 items or more: at 1024 the share is
0.003 on WSL.
