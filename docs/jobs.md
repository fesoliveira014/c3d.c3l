# Job pool

The `c3d_job` add-on (`addons/c3d_job.c3l`, module `c3d::job`) runs a function over index ranges on a fixed pool of
worker threads. It is fork-join: `run` splits `[0, count)` into ranges and queues them, `wait` returns once every range
of that run has finished, and `is_finished` reports it without blocking. A run is frame work or background work. Frame
ranges are taken first, and a cap bounds how many workers run background ranges at once. With zero workers every frame
range runs on the calling thread. The package binds workers to processors on Linux and Windows and imports only the
standard library and `c3d`, plus `c3d::profile` under `C3D_PROFILE_CPU`. Core never imports it and has no job feature
flag.

This page also owns the [`ParallelFor` hook](#parallelfor-hook) that the cloth, physics and particle packages accept, so
an application can drive them from a job pool without those packages importing it.

## Quick start

Add `c3d_job` to the dependencies of `project.json` beside c3d's own ([release.md](release.md) lists the names):

```json
{
  "dependency-search-paths": [ "path/to/c3d.c3l/lib" ],
  "dependencies": [ "c3d_job", "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "cgltf", "ufbx", "shaderc" ]
}
```

Create a pool, run a function over a range of items, and wait:

```c3
import c3d::job;

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

JobPool pool = job::create_job_pool(mem, job::default_job_pool_desc())!;
defer job::destroy_job_pool(&pool);

JobId id = pool.run(
    range: &integrate_range,
    data:  &particles,
    count: (uint)particles.positions.len,
    batch: 256,
);
// other work on this thread
pool.wait(id);
```

`python3 scripts/build.py --example job_bench` builds and runs the package's benchmark example.

## Concepts

- **Run and range.** A run of `count` items at `batch = b` has `ceil(count / b)` ranges, `[i * b, min((i + 1) * b,
  count))`; only the last is short. Each range is one call of the function.
- **Class.** A run is `FRAME` or `BACKGROUND`. Workers take frame ranges first. Background work runs in frame idle time,
  so a pool that is never idle of frame work starves it, by design.
- **Inline mode.** With `worker_count = 0`, `run` runs every range on the calling thread in ascending order and returns
  the zero id. Results equal the pooled results when the ranges follow [the rules](#rules-for-ranges).
- **Ids.** `JobId` names a run until its last range finishes. After that the id is stale.
- **Value handle.** `JobPool` is a value handle over heap state. Moving it keeps the pool running, and copies share one
  pool, which is destroyed once.

## Create and destroy

`create_job_pool(allocator, desc)` allocates the pool state, the worker array and the run table once, then starts the
workers and returns when each has bound itself to its processors. It faults `c3d::CAPACITY_EXCEEDED` when an allocation
fails, `c3d::INVALID_ARGUMENT` or `c3d::UNSUPPORTED` for a processor set it cannot apply ([Processors](#processors)),
and passes on `thread::INIT_FAILED` when the system refuses a mutex, condition variable or thread. On any fault
everything created so far is released. The allocator is called from the worker threads, so it must be thread-safe and
must not be `tmem`.

`destroy_job_pool` waits for every outstanding run, stops and joins the workers, frees everything and zeroes the handle.
A `defer` on an error path is safe while runs are in flight.

| `JobPoolDesc` field | Default | Meaning |
| --- | --- | --- |
| `worker_count` | available processors within the quota, minus one, at least 1 | Shared worker threads. 0 runs every frame range on the calling thread. |
| `worker_temp_bytes` | 256 KiB | Initial temp allocator of each worker. |
| `run_capacity` | 64 | Frame runs with unfinished ranges at once. Must be above 0. |
| `background_run_capacity` | 64 | Background runs with unfinished ranges at once. 0 refuses every background run. |
| `background_workers` | `default_background_workers(worker_count)` | Shared workers that may run background ranges at once. |
| `background_only_workers` | 0 | Further workers that take only background ranges, outside the cap. |
| `worker_cpus` | empty | Processors of the shared workers. Empty leaves the system's choice. |
| `background_cpus` | empty | Processors of the background-only workers. Empty leaves the system's choice. |
| `power_throttling_opt_out` | false | Windows: each worker, and the caller in `bind_caller`, asks the scheduler not to throttle it. Ignored elsewhere. |
| `record_capacity` | 4096 | Worker range records held between drains (`C3D_PROFILE_CPU` only). |

`default_job_pool_desc()` fills these. A cap at or above `worker_count` does not limit, so a descriptor that lowers
`worker_count` also sets `background_workers`, usually to `job::default_background_workers(count)`: a quarter of the
workers, at least one, and none without workers (1 at 4 workers, 2 at 8, 4 at 16, 7 at 31). A quarter keeps three
quarters of the workers on frame work while background ranges run.

The default `worker_count` is `max(min(available, quota) - 1, 1)`. `available` is the size of `job::available_cpus()`,
and `quota` is `job::cpu_quota()` when it returns one:

| Host | `available` | `quota` | Default workers |
| --- | ---: | ---: | ---: |
| 32 logical processors, unrestricted | 32 | none | 31 |
| the same under `taskset -c 0-3` | 4 | none | 3 |
| the same in a container with a 2.5-processor quota (`cpu.max` `250000 100000`) | 32 | 3 | 2 |

On Windows `available_cpus()` covers the calling thread's processor group only, and `cpu_quota()` never returns a quota
(job-object rate limits are not read). Processors numbered 1024 and up are not represented. The count has no upper
limit. box3d runs its own worker threads (`PhysicsDesc.worker_count`, 1 by default) inside `PhysicsWorld.step`; an
application that runs jobs during a step and also uses several box3d workers lowers the job pool's `worker_count` to
avoid oversubscription.

## Run and wait

- **`run(range, data, count, batch, name)`** queues the ranges as a frame run and returns a `JobId` at once. `data` goes
  to every range, must outlive the run and may be null. `batch = 0` lets the pool choose about four ranges per shared
  worker, the caller included; background-only workers do not count. `count = 0` runs nothing.
- **`wait(id)`** returns once every range of the run has finished. Meanwhile the waiting thread runs that run's
  unclaimed ranges itself, whatever the class. Everything the ranges wrote is visible to the caller after `wait`
  returns.
- **`is_finished(id)`** reports whether every range has finished, without blocking. Once it returns true, everything the
  ranges wrote is visible to the caller. A run's slot is released when its last range finishes, whether or not anyone
  waits or asks.
- **`wait_all()`** returns once no run of either class is unfinished, running any unclaimed range meanwhile.
- **Zero and stale ids.** `run` returns the zero id when every range ran inside the call. `wait` on a zero or stale id
  returns at once and never waits on a later run in the same slot. `is_finished` reports both as finished. A slot's
  generation wraps after 2^32 - 1 runs, so an id that old may name a later run.
- **Nesting.** A range may call `run` on its own pool. The nested run executes inline on the range's thread, so nesting
  never deadlocks, and returns the zero id; `wait` on it returns at once. This holds for ranges on a worker and for
  ranges the caller runs while it waits. A nested `try_run` queues instead, and the range never waits on that run.

Workers claim ranges in this order: the oldest frame run first, then the oldest background run while the cap allows, and
within a run in ascending index order. Completion order between ranges and between runs is not guaranteed.

## Capacity

Each run with unfinished ranges holds one slot of its class, whatever its range count, so the number of ranges queued at
once has no limit of its own. Frame and background runs fill separate partitions of one table: background runs that span
frames never push frame runs inline, and a full frame partition never refuses a background run.

`run` never faults and never waits for a slot. A frame run that finds no free frame slot runs entirely inline on the
caller before `run` returns, and returns the zero id; no run is split between the pool and the caller.
`JobPool.inline_ranges()` counts those ranges since the pool was created. A count that grows means `run_capacity` is too
small. Nested runs and inline mode are inline by design and are not counted. `try_run` refuses instead of running
inline.

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

- **`try_run(job_class, ...)`** queues a run of either class, or faults `c3d::CAPACITY_EXCEEDED` when that class's
  partition is full. A refused run queues and runs nothing, and `inline_ranges` does not move. It never runs a range
  inside the call, except that on a pool without shared workers frame work runs on the caller as `run` does. Background
  runs are submitted only through `try_run`. A background slot holds its run until the last range finishes, across
  frames.
- **Cap.** At most `background_workers` shared workers run background ranges at once. The others take only frame ranges,
  and a worker takes a frame range before a background one. A range that has started is never interrupted, so a long
  background range delays frame work only by holding its own worker.
- **`pump(max_ranges)`** runs background ranges on the calling thread, in submission order, and returns how many ran. It
  runs only ranges queued before the call, so a background run that a pumped range submits waits for the next `pump`. It
  ignores the cap and never takes frame ranges.
- **Background-only workers.** `background_only_workers` adds workers that take only background ranges, in the same
  order, outside the cap. They never take frame ranges, so a pool with zero shared workers and some background-only
  workers runs frame work inline and background work on its workers.
- **Without background workers.** With no background-only worker and either zero workers or `background_workers = 0`, a
  background run progresses only through `pump`, `wait` on that run, `wait_all` or `destroy_job_pool`. A consumer that
  polls `is_finished` alone on such a pool never sees the run finish.

## Processors

`job::CpuSet` is the standard library's `BitSet{1024}`, indexed by logical processor. On Windows the index numbers
processor groups consecutively: group 1 starts after the active processors of group 0.

- **`available_cpus()`** returns the processors the calling thread may run on: on Linux its affinity mask, which
  `taskset` and cgroup cpusets narrow; on Windows its affinity within its processor group. Linux has no process-wide
  mask, so `default_job_pool_desc` and `create_job_pool` read it on the creating thread. Create the pool before binding
  that thread.
- **`cpu_quota()`** returns the Linux cgroup CPU quota in whole processors, rounded up: cgroup v2 `cpu.max` under
  `/sys/fs/cgroup`, or cgroup v1 `cpu.cfs_quota_us` and `cpu.cfs_period_us` under `/sys/fs/cgroup/cpu`, for the
  process's cgroup and every ancestor, the tightest winning. An unlimited, missing or malformed quota faults
  `NOT_FOUND`, as Windows always does. Other mount points are not searched.
- **`core_types()`** splits `available_cpus()` into the fastest core type (`performance`) and the rest (`efficiency`).
  Windows ranks cores by their efficiency class. Linux reads `/sys/devices/cpu_core/cpus` on Intel hybrid processors,
  otherwise each processor's `cpu_capacity`. Where neither exists, or every core ranks the same, `performance` holds
  every available processor and `efficiency` is empty.

`worker_cpus` binds the shared workers and `background_cpus` the background-only workers. A requested set is first
intersected with the creating thread's `available_cpus()`, so a worker never widens its own mask. Each worker binds
itself when it starts and reads its mask back, and `create_job_pool` returns once every worker has reported.
`JobPool.worker_cpus(worker)` returns what each one read back, shared workers first.

| Request | Result |
| --- | --- |
| empty | The worker keeps the system's choice: on Linux the creating thread's mask, on Windows the process's affinity. |
| partly outside `available_cpus()` | Bound to the intersection. |
| entirely outside `available_cpus()` | `c3d::INVALID_ARGUMENT`. |
| spanning two Windows processor groups | `c3d::UNSUPPORTED`. |
| refused by the system, or read back as another set | `c3d::UNSUPPORTED`. |

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

Binding the frame workers to the performance cores isolates them from background work. It does not add throughput. Size
the frame worker count from the physical performance cores, because logical processors that share a core add little, and
unbound workers also use the efficiency cores.

### Calling thread

The pool does not bind the calling thread. That thread runs ranges in `wait` and `wait_all`, and on a hybrid processor
the system can schedule it onto an efficiency core while it waits. `JobPool.bind_caller(cpus)` binds it the way a worker
is bound:

```c3
CoreTypes types = job::core_types();
JobPool pool = job::create_job_pool(mem, desc)!;
defer job::destroy_job_pool(&pool);
pool.bind_caller(types.performance)!;
```

- It pins the calling thread to the given set; on a hybrid processor that set should be `core_types().performance`.
- An empty argument selects the pool's `worker_cpus`. When that is empty too, nothing is bound.
- It faults `c3d::UNSUPPORTED` when the system refuses the set or reads back another one, and for a set that spans two
  Windows processor groups. It does not intersect the set with `available_cpus()`.
- Call it once from the owner thread after `create_job_pool`. Bound first, that thread would narrow every worker's set.

With `power_throttling_opt_out`, on Windows each worker asks the scheduler not to throttle it when it starts, and
`bind_caller` does the same for the calling thread before it binds. The request switches the thread's execution-speed
power throttling off (`SetThreadInformation` with `ThreadPowerThrottling`). A Windows release without the setting
refuses it, and the thread keeps the system's policy without a fault. Other platforms ignore the field.

## Temp memory

Every range runs inside its own `@pool()` on the thread that runs it, so `tmem` inside a range is that thread's and
resets after the range. Each worker creates its temp allocator once, `worker_temp_bytes` from the pool's allocator. A
range whose scratch exceeds `worker_temp_bytes` allocates and frees a page each time it runs, so size it to the largest
range's scratch. Each range's `@pool()` also needs about 17 KiB of it (the standard library's 16 KiB minimum plus a 1
KiB reserve). At 16 KiB or less every range allocates, empty or not.

## Rules for ranges

The pool does not check these. A range that breaks them races.

- A range runs on a worker or on the thread that called `run`, `try_run`, `wait`, `wait_all`, `pump` or
  `destroy_job_pool`. It never calls the renderer, gpu.c3l submission or command recording, SDL or ImGui. It never
  changes scene or ECS structure (adding or removing nodes or components, registering component types), and never writes
  a store another range reads.
- Outputs are disjoint per item. Gather any reduction in index order after the wait. A result must not depend on how the
  work is split.
- A range allocates scratch only through `tmem`, which is its own thread's and resets after the range. It must not keep
  `tmem` memory beyond the range, and must not use an allocator passed in from the caller, such as the caller's `tmem`
  stored in `data`. Inline ranges on the caller follow the same rule under their own `@pool()`.
- A thread other than the main thread that calls `run`, `try_run`, `wait`, `wait_all`, `pump` or `destroy_job_pool`
  needs its own temp allocator (`@pool_init`), because the ranges it runs open `@pool()`.
- A range may call `run` on its own pool (it runs inline) and `wait` on the zero id it gets. It may call `try_run` (the
  run queues) and `is_finished`. It never calls `wait_all`, `pump` or `destroy_job_pool` on its own pool, and never
  waits on another run of its own pool (its own run, an outer run, a run it queued with `try_run`, or a run that waits
  on it). These are contracts, so the deadlock fires as a contract failure instead of hanging. Waiting on another pool's
  run is not detected.

## ParallelFor hook

Core declares `c3d::ParallelFor` (`src/c3d/parallel.c3`), a caller-supplied fork-join over index ranges. Packages that
parallelize their own work take a `ParallelFor`: `PhysicsWorld.set_parallel` stages [cloth](cloth.md),
and `particle::update` and `particle::step` take a trailing parameter ([particles](particles.md)). Those
packages import no job library; the hook is their only coupling.

| Item | Meaning |
| --- | --- |
| `ParallelFor.run` | `fn void(void* context, ParallelRangeFn range, void* data, uint count, uint batch)`. Calls `range(data, first, count)` over `[0, count)` in batches of `batch` items and returns only after every range finished. |
| `ParallelFor.context` | Passed to `run` unchanged. |
| `ParallelRangeFn` | `fn void(void* data, uint first, uint count)`, the signature of `c3d::job::RangeFn`. |
| `ParallelFor.for_ranges(range, data, count, batch)` | Runs through `run`, or as one range `range(data, 0, count)` when `run` is null. |

A zero `ParallelFor` runs every range inline on the calling thread. The ranges of a pooled `run` may execute in any
order and concurrently, and `data` stays valid until the call returns. A consumer therefore writes disjoint outputs per
range and follows [the rules for ranges](#rules-for-ranges).

A `JobPool` adapter is a few lines:

```c3
fn void run_on_pool(
    void* context,
    ParallelRangeFn range,
    void* data,
    uint count,
    uint batch,
) {
    JobPool* pool = context;
    pool.wait(pool.run(
        range: range,
        data:  data,
        count: count,
        batch: batch,
    ));
}

ParallelFor parallel = { .run = &run_on_pool, .context = &pool };
physics.set_parallel(parallel);
```

Pass the same value to `particle::update`. Keep the pool alive for as long as any package holds the hook.

## Profiling

Ranges that run on workers appear in a `c3d_profile` capture under the name given at submission. The support is compiled
only under `C3D_PROFILE_CPU`; a consumer that enables the feature also selects `c3d_profile`
([profiling](profiling.md#worker-ranges)).

```c3
pool.set_recording(true);
profile::@capture(&recorder, frame_id) {
    pool.wait(pool.run(
        range: &integrate_range,
        data:  &particles,
        count: (uint)particles.positions.len,
        batch: 256,
        name:  "integrate",
    ));
    pool.forward_records(&recorder);
};
```

- **Names.** `run` and `try_run` take a `name`. The pool keeps the `String` until its records are drained, so it must
  outlive the drain; string literals and static strings do.
- **Recording.** `set_recording(true)` makes each worker time every range it claims from then on: two `clock::now()`
  reads around the range and one record written under the lock the worker already takes at completion. Ranges the
  calling thread runs (inline, in `wait`, `wait_all` or `pump`) are not recorded; wrap those calls in application
  scopes.
- **Ring.** Records wait in a ring of `record_capacity` entries (4096 by default). A full ring drops new records and
  counts them; the next drain reports the count.
- **Drain.** `take_records(records)` moves the oldest records out, on any thread, with the drop count since the previous
  drain. `forward_records(&recorder)` drains the records held at the call into the recorder's open capture through
  `Recorder.add_worker_interval` and forwards the drop count. Records that workers add while it runs wait for the next
  call, and records drained outside a recording capture are discarded. A record is in the ring before its run reports
  finished, so forwarding after `wait` or a true `is_finished` includes the whole run.
- **Frame attribution.** A record belongs to the capture open when it is drained. A range that began before that
  capture's origin keeps a negative start offset and appears left of the axis origin. Forward after the run. Records
  forwarded at the start of a capture can fill its label storage; see [Worker ranges](profiling.md#worker-ranges).
- **Cost.** Without `C3D_PROFILE_CPU` the pool compiles no clock read, ring or branch. With the feature and recording
  off, each claim tests one flag under the lock.

## Benchmark

`job_bench` (`python3 scripts/build.py --target job_bench --opt O3`) prints one CSV block per measurement, with a `#
<name>,...` header line each:

- `overhead`: the time per range of one run of 1024 empty ranges at batch 1, per worker count, with `inline_ranges`.
- `kernel`: 16 `Mat4` multiplies per item against a shared chain, for several worker counts, item counts and batches. It
  prints the serial time (the same split on a zero-worker pool, on the caller), the pooled time, the speedup, the
  overhead share (`ranges * us_per_range / serial_us`), the peak scratch bytes and whether the pooled output equals the
  serial output bit for bit. The exit status is 1 when any pooled output differs.
- `background`: one background run of 1024 empty ranges at batch 1, from `try_run` until its last range has run, on the
  capped workers alone.
- `loaded`: the same kernel idle and while a long background run keeps the default cap of workers busy.
- `pinned`: the kernel with the frame workers bound to the performance cores against unbound, on a hybrid processor.
- `recording`: the overhead workload with `set_recording(true)`, when built with `--define C3D_PROFILE_CPU --lib
  c3d_profile`.

`job_bench --crowd COUNT [--shared-phases] [--compress]` times an animated crowd instead. It loads the Quaternius
character, creates COUNT instances with six looping clips at random phases and speeds, and per frame runs `advance` on
the caller, `sample_range` over the pool, then `publish_crowd_pose` on the caller. One line per path prints the median
stage times; the `update` line is the serial `CrowdPlaybackState.update`. Every line's per-frame digest of poses, morph
weights, root motion and events must equal the `update` line's, or the exit status is 1. `--shared-phases` also runs the
crowd with instances in twelve groups that share a clip and a time, and adds the hit rate and the sample and CPU time
saved. `--compress` quantizes the clips first and prints their bytes and the largest error per path. See
[benchmarking](benchmarking.md) for how to read and compare timings.

## Limits

- Linux and Windows only; the package asserts the platform at compile time.
- Processors numbered 1024 and up are not represented.
- On Windows, `available_cpus()` covers one processor group, and a worker set cannot span two groups.
- `cpu_quota()` reads Linux cgroups only.
- A pool that never idles of frame work starves background runs.
- The pool uses one lock. Each range costs one claim and one completion under it, so very small batches on many workers
  spend a visible share of the time in the lock; batches of a few hundred items or more keep that share small.

## See also

- [Profiling](profiling.md): the recorder that receives worker ranges.
- [Cloth](cloth.md) and [particles](particles.md): consumers of the `ParallelFor` hook.
- [Benchmarking](benchmarking.md): the runner and the profiling configurations.
- [Development](development.md#test-targets): the `job_test` and `job_profile_test` targets.
