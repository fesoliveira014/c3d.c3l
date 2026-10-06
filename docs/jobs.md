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

`create_job_pool` allocates the pool state, the worker array and the run table once, then starts the workers.
It faults `c3d::CAPACITY_EXCEEDED` when an allocation fails and passes on `thread::INIT_FAILED` when the system
refuses the mutex, a condition variable or a thread; either way everything created so far is released. The
allocator is called from the worker threads, so it must be thread-safe and must not be `tmem`.

`destroy_job_pool` waits for every outstanding run, stops and joins the workers, frees everything and zeroes
the handle. A `defer` on an error path is safe while runs are in flight. `JobPool` is a value handle over
heap state: moving the handle keeps the pool running, and copies share one pool, which is destroyed once.

| `JobPoolDesc` field | Default | Meaning |
| --- | --- | --- |
| `worker_count` | logical processors minus one, at least 1 | Shared worker threads; 0 runs every frame range on the calling thread. |
| `worker_temp_bytes` | 256 KiB | Initial temp allocator of each worker. |
| `run_capacity` | 64 | Frame runs with unfinished ranges at once. |
| `background_run_capacity` | 64 | Background runs with unfinished ranges at once; 0 refuses every background run. |
| `background_workers` | `default_background_workers(worker_count)` | Shared workers that may run background ranges at once. |

`default_job_pool_desc()` fills these. A cap at or above `worker_count` does not limit, so a descriptor that
lowers `worker_count` also sets `background_workers`, usually to `job::default_background_workers(count)`:
a quarter of the workers, at least one, and none without workers. That is 1 at 4 workers, 2 at 8, 4 at 16 and 7
at 31. A quarter keeps three quarters of the workers on frame work while background ranges run. The worker
count has four caveats:

1. On Linux, `native_cpu()` is `get_nprocs_conf()`: it ignores CPU affinity and cgroup quotas, so a container
   over-reports. Set `worker_count` from the container's quota there.
2. On Windows it counts the current processor group only.
3. box3d's workers run only inside `PhysicsWorld.step`. The two pools oversubscribe the machine only when an
   application runs jobs during a physics step; such an application lowers `worker_count`.
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
  count))`; only the last one is short. `batch = 0` lets the pool choose about four ranges per pool thread,
  the caller included. `count = 0` runs nothing.
- **`run`** queues the ranges as a frame run and returns at once with a `JobId`. `data` is handed to every
  range and must outlive the run; it may be null.
- **`wait(id)`** returns once every range of the run has finished. Meanwhile the waiting thread runs that run's
  unclaimed ranges itself, whatever its class. Everything the ranges wrote is visible to the caller after
  `wait` returns.
- **`is_finished(id)`** reports whether every range of the run has finished, without blocking. Once it returns
  true, everything the ranges wrote is visible to the caller. A run's slot is released when its last range
  finishes, whether or not anyone waits on it or asks.
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
  workers, frame work runs on the caller as `run` does. Background runs are submitted only through `try_run`.
- **Cap.** At most `background_workers` shared workers run background ranges at once; the others take only
  frame ranges, and a worker takes a frame range before a background one. Background work therefore runs in
  frame idle time: a pool that is never idle of frame work starves it, by design. A range that has started is
  never interrupted, so a long background range delays frame work only by holding its own worker.
- **`pump(max_ranges)`** runs background ranges on the calling thread, in submission order, up to
  `max_ranges`, and returns how many ran. It runs only ranges queued before the call: a background run that a
  pumped range submits waits for the next `pump`. It ignores the cap, which limits workers and not the calling
  thread, and it never takes frame ranges.
- **Without background workers.** With zero workers or `background_workers = 0`, a background run progresses
  only through `pump`, `wait` on that run, `wait_all` or `destroy_job_pool`. A consumer that only polls
  `is_finished` on such a pool never sees the run finish.
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

- A range runs on a worker or on the thread that called `run`, `wait` or `wait_all`. It never calls the
  renderer, gpu.c3l submission or command recording, SDL or ImGui; never changes scene or ECS structure
  (adding or removing nodes or components, registering component types); never writes a store another range
  reads.
- Outputs are disjoint per item. Any reduction is gathered in index order after the wait. A consumer's result
  must not depend on how the work is split.
- A range allocates scratch only through `tmem`, which is its own thread's and reset after the range; it must
  not keep `tmem` memory beyond the range, and must not use an allocator passed in from the caller, such as a
  caller's `tmem` stored in `data`. Inline ranges on the caller follow the same rule under their own
  `@pool()`.
- A thread other than the main thread that calls `run`, `wait` or `wait_all` has its own temp allocator
  (`@pool_init`), because ranges it runs open `@pool()`.
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

### WSL, 32 logical processors (default 31 workers)

| Workers | µs per empty range | Inline ranges |
| ---: | ---: | ---: |
| 0 | 0.0076 | 0 |
| 1 | 0.0432 | 0 |
| 3 | 0.0592 | 0 |
| 31 | 0.1768 | 0 |

| Workers | Items | Batch | Ranges | Serial µs | Pooled µs | Speedup | Overhead share | Peak scratch |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 16384 | 64 | 256 | 899.5 | 467.7 | 1.93 | 0.0128 | 4 KiB |
| 1 | 16384 | 1024 | 16 | 905.6 | 473.2 | 1.99 | 0.0008 | 64 KiB |
| 1 | 16384 | 2048 | 8 | 892.6 | 461.3 | 1.94 | 0.0004 | 128 KiB |
| 1 | 65536 | 64 | 1024 | 3662.6 | 1881.9 | 1.94 | 0.0125 | 4 KiB |
| 1 | 65536 | 1024 | 64 | 3655.9 | 1815.1 | 2.00 | 0.0008 | 64 KiB |
| 1 | 65536 | 8192 | 8 | 3658.8 | 1855.1 | 1.97 | 0.0001 | 512 KiB |
| 1 | 262144 | 64 | 4096 | 15091.3 | 7586.9 | 1.99 | 0.0120 | 4 KiB |
| 1 | 262144 | 1024 | 256 | 14893.3 | 7309.3 | 2.03 | 0.0008 | 64 KiB |
| 1 | 262144 | 32768 | 8 | 14780.6 | 7390.6 | 2.00 | 0.0000 | 2 MiB |
| 3 | 16384 | 64 | 256 | 899.3 | 259.3 | 3.47 | 0.0140 | 4 KiB |
| 3 | 16384 | 1024 | 16 | 895.7 | 242.9 | 3.69 | 0.0011 | 64 KiB |
| 3 | 65536 | 64 | 1024 | 3622.2 | 1009.9 | 3.62 | 0.0169 | 4 KiB |
| 3 | 65536 | 1024 | 64 | 3623.2 | 994.4 | 3.60 | 0.0011 | 64 KiB |
| 3 | 65536 | 4096 | 16 | 3654.1 | 939.3 | 3.83 | 0.0003 | 256 KiB |
| 3 | 262144 | 64 | 4096 | 15219.9 | 3845.7 | 3.96 | 0.0163 | 4 KiB |
| 3 | 262144 | 1024 | 256 | 14884.7 | 3650.7 | 4.08 | 0.0010 | 64 KiB |
| 3 | 262144 | 16384 | 16 | 15018.2 | 3762.8 | 3.97 | 0.0001 | 1 MiB |
| 31 | 16384 | 64 | 256 | 888.5 | 305.1 | 2.83 | 0.0524 | 4 KiB |
| 31 | 16384 | 1024 | 16 | 893.4 | 264.2 | 3.35 | 0.0032 | 64 KiB |
| 31 | 16384 | 128 | 128 | 884.7 | 250.1 | 3.55 | 0.0263 | 8 KiB |
| 31 | 65536 | 64 | 1024 | 3654.8 | 739.3 | 4.97 | 0.0514 | 4 KiB |
| 31 | 65536 | 1024 | 64 | 3608.3 | 740.0 | 4.83 | 0.0032 | 64 KiB |
| 31 | 65536 | 512 | 128 | 3619.6 | 697.7 | 5.02 | 0.0065 | 32 KiB |
| 31 | 262144 | 64 | 4096 | 15169.6 | 1898.0 | 8.01 | 0.0491 | 4 KiB |
| 31 | 262144 | 1024 | 256 | 14834.5 | 1491.1 | 10.01 | 0.0031 | 64 KiB |
| 31 | 262144 | 2048 | 128 | 14912.2 | 1556.5 | 9.45 | 0.0015 | 128 KiB |

With one worker the caller doubles the throughput by running ranges while it waits. The time per empty range
grows with the worker count, since every range takes and returns one lock. At 31 workers, batch 64 costs 5 %
of the serial time; batches of 128 items or more stay under 3 %.

### Windows host, 32 logical processors (default 31 workers)

Medians of three runs, with the range of the three in parentheses; every pooled output equals its serial
output and no overhead run ran a range inline.

| Workers | µs per empty range |
| ---: | ---: |
| 0 | 0.0059 (0.0052–0.0062) |
| 1 | 0.0284 (0.0266–0.0292) |
| 3 | 0.0480 (0.0431–0.0568) |
| 31 | 0.1430 (0.1121–0.2395) |

| Workers | Items | Batch | Speedup | Overhead share |
| ---: | ---: | ---: | ---: | ---: |
| 31 | 16384 | 64 | 5.30 | 0.0545 (0.0439–0.0942) |
| 31 | 65536 | 64 | 6.69 | 0.0540 (0.0432–0.0929) |
| 31 | 262144 | 64 | 7.24 | 0.0514 (0.0416–0.0875) |
| 31 | 16384 | 1024 | 6.18 | 0.0033–0.0035 |
| 31 | 65536 | 1024 | 6.66 | 0.0033–0.0035 |
| 31 | 262144 | 1024 | 10.07 | 0.0033–0.0035 |
| 31 | 16384 | 128 | 6.41 | |
| 31 | 65536 | 512 | 7.44 | |
| 31 | 262144 | 2048 | 8.80 | |

At 3 workers the speedup is 3.5 to 4.1 with every overhead share below 0.019; at 1 worker it is 1.9 to 2.0,
apart from the runs split into 8 ranges. Peak scratch per range is 4 KiB at batch 64 and up to 2 MiB at batch
32 768 with one worker, as on WSL.

### Revisit threshold

The single-lock queue is revisited when a median exceeds 2 µs per empty range, or a kernel median overhead
share exceeds 0.05. On WSL the time per range stays under 0.18 µs, and the overhead share crosses 0.05 at 31
workers and batch 64 with 16 384 items (0.0524) and 65 536 items (0.0514). On the Windows host the time per
range stays under 0.24 µs, and the share crosses 0.05 at 31 workers and batch 64 on all three item counts
(0.051 to 0.055). Both machines therefore cross the threshold narrowly, at the finest batch with every
worker; the queue is kept, and a per-run atomic claim cursor (and `wait`'s scan of the ring for its run's
ranges) are the remedies to measure when a consumer needs that grain. With many workers, use batches of about
512 items or more: at 1024 the share is 0.003 on both machines.
