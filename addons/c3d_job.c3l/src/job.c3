module c3d::job;

import c3d;
import std::thread;

<*
 Handle to a run; stale once every range of the run has finished.
*>
typedef JobId = Id;

<*
 Work over the items [first, first + count) of one range.
*>
alias RangeFn = fn void(void* data, uint first, uint count);

<*
 Initial temp allocator of each worker, allocated once per worker.
*>
const usz DEFAULT_WORKER_TEMP_BYTES = 256 * 1024; // std's main-thread size; larger scratch allocates a page a run

<*
 Frame runs with unfinished ranges at once.
*>
const uint DEFAULT_RUN_CAPACITY = 64; // 3.5 KiB at 56 bytes a slot; a fork-join caller holds one run

<*
 Background runs with unfinished ranges at once.
*>
const uint DEFAULT_BACKGROUND_RUN_CAPACITY = 64; // 3.5 KiB at 56 bytes a slot; held until its last range finishes

const uint BACKGROUND_WORKER_SHARE @private = 4; // the default cap leaves three quarters of the workers to frame work
const uint RANGES_PER_THREAD @private = 4; // batch 0 gives this many ranges per thread; each costs one lock round trip
const uint NO_RUN @private = uint::max; // end of a class queue

tlocal JobPoolState* active_pool @private;

<*
 Scheduling class of a run.
*>
enum JobClass {
    FRAME,
    BACKGROUND,
}

<*
 Worker threads, processors, temp memory and run capacities of a job pool.
*>
struct JobPoolDesc {
    uint   worker_count;            // shared workers; 0 runs frame ranges on the calling thread
    usz    worker_temp_bytes;       // initial temp allocator of each worker
    uint   run_capacity;            // frame runs in flight at once; a frame run that does not fit runs inline
    uint   background_run_capacity; // background runs in flight at once; 0 refuses every background run
    uint   background_workers;      // shared workers that may run background ranges at once
    uint   background_only_workers; // workers that take only background ranges, outside the cap
    CpuSet worker_cpus;             // processors of the shared workers; empty leaves the system's choice
    CpuSet background_cpus;         // processors of the background-only workers; empty leaves the system's choice
}

struct JobRange @private {
    RangeFn range;
    void*   data;
    uint    first;
    uint    count;
}

struct RunSlot @private {
    RangeFn range;
    void*   data;
    uint    count;
    uint    batch;
    uint    range_count;
    uint    next_range;      // ranges below it are claimed
    uint    pending;         // unclaimed or running ranges; the slot is free at 0
    uint    generation;
    uint    previous_queued; // class queue links, valid while ranges remain unclaimed
    uint    next_queued;
    ulong   sequence;        // submission order of the run
}

struct Worker @private {
    Thread        thread;
    JobPoolState* state;
    CpuSet        cpus;            // the requested set, then the set the worker read back
    bool          background_only;
    bool          refused;         // the system refused the set or read back another one
}

struct RunQueue @private {
    uint first;
    uint last;
}

struct JobPoolState @private {
    Allocator         allocator;
    usz               worker_temp_bytes;
    Worker[]          workers; // shared workers first; Thread.create writes an entry its worker may already read, so the array never moves
    RunSlot[]         runs;    // frame slots first, then background slots
    uint              shared_workers;
    uint              frame_slots;
    uint              background_workers;
    Mutex             lock;    // guards every field below
    ConditionVariable work_available;
    ConditionVariable run_finished;
    RunQueue          frame_queue;
    RunQueue          background_queue;
    uint              running;
    uint              running_background; // background ranges on shared workers, bounded by background_workers
    ulong             next_sequence;
    ulong             inline_ranges;
    uint              reported_workers; // workers that bound and read back their processors
    bool              stopping;
}

<*
 Fixed pool of worker threads running fork-join index ranges.
*>
struct JobPool {
    JobPoolState* state;
}

<*
 Split [0, count) into ranges and queue them as a frame run.
 A run the frame partition cannot hold runs inline before the return.
 @param [inout] data : "Handed to every range; outlives the run."
 @param batch : "Items per range, the last one short; 0 lets the pool choose."
 @return "Zero when every range ran inside the call."
*>
fn JobId JobPool.run(
    &self,
    RangeFn range,
    void* data,
    uint count,
    uint batch,
) {
    JobPoolState* state = self.state;
    if (!count) return {};
    RunSlot request = run_request(
        state: state,
        range: range,
        data:  data,
        count: count,
        batch: batch,
    );
    if (!state.shared_workers || active_pool == state) {
        run_inline(state, request);
        return {};
    }

    state.lock.lock();
    JobId? id = queue_run(state, JobClass.FRAME, request);
    if (catch id) {
        state.inline_ranges += request.range_count;
        state.lock.unlock();
        run_inline(state, request);
        return {};
    }
    state.lock.unlock();
    state.work_available.broadcast();
    return id;
}

<*
 Queue a run of a class, or refuse it when the class partition is full.
 Runs no range inside the call, except frame work on a pool without workers.
 @param [inout] data : "Handed to every range; outlives the run."
 @param batch : "Items per range, the last one short; 0 lets the pool choose."
 @return "Zero when every range ran inside the call."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn JobId? JobPool.try_run(
    &self,
    JobClass job_class,
    RangeFn range,
    void* data,
    uint count,
    uint batch,
) {
    JobPoolState* state = self.state;
    if (!count) return {};
    RunSlot request = run_request(
        state: state,
        range: range,
        data:  data,
        count: count,
        batch: batch,
    );
    if (job_class == FRAME && !state.shared_workers) {
        run_inline(state, request);
        return {};
    }

    state.lock.lock();
    JobId? id = queue_run(state, job_class, request);
    state.lock.unlock();
    if (catch excuse = id) return excuse~;
    state.work_available.broadcast();
    return id;
}

<*
 Whether every range of the run has finished, without blocking.
 Range writes are visible to the caller once it returns true.
 @require id.index < self.state.runs.len : "The id came from this pool."
*>
fn bool JobPool.is_finished(&self, JobId id) {
    JobPoolState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    return state.runs[id.index].generation != id.generation;
}

<*
 Run background ranges queued before the call on this thread, oldest first.
 @param max_ranges : "Most ranges this call runs."
 @return "Ranges run."
 @require active_pool != self.state : "Not called from a range of this pool."
*>
fn uint JobPool.pump(&self, uint max_ranges = uint::max) {
    JobPoolState* state = self.state;
    state.lock.lock();
    ulong queued_before = state.next_sequence;
    uint ran;
    for (; ran < max_ranges; ran++) {
        uint run_slot = state.background_queue.first;
        if (run_slot == NO_RUN || state.runs[run_slot].sequence >= queued_before) break;
        run_claimed(state, run_slot);
    }
    state.lock.unlock();
    return ran;
}

<*
 Block until the run has finished, running its unclaimed ranges meanwhile.
 @require id.index < self.state.runs.len : "The id came from this pool."
 @require active_pool != self.state || id.generation == 0 : "From a range of this pool, only a nested run's zero id."
*>
fn void JobPool.wait(&self, JobId id) {
    JobPoolState* state = self.state;
    state.lock.lock();
    RunSlot* slot = &state.runs[id.index];
    while (slot.generation == id.generation) {
        if (slot.next_range < slot.range_count) {
            run_claimed(state, id.index);
            continue;
        }
        state.run_finished.wait(&state.lock);
    }
    state.lock.unlock();
}

<*
 Block until no run of either class is unfinished, running unclaimed ranges meanwhile.
 @require active_pool != self.state : "Not called from a range of this pool."
*>
fn void JobPool.wait_all(&self) {
    JobPoolState* state = self.state;
    state.lock.lock();
    while (true) {
        if (state.frame_queue.first != NO_RUN) {
            run_claimed(state, state.frame_queue.first);
            continue;
        }
        if (state.background_queue.first != NO_RUN) {
            run_claimed(state, state.background_queue.first);
            continue;
        }
        if (!state.running) break;
        state.run_finished.wait(&state.lock);
    }
    state.lock.unlock();
}

<*
 Cumulative ranges `run` executed inline because the frame partition was full.
*>
fn ulong JobPool.inline_ranges(&self) {
    JobPoolState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    return state.inline_ranges;
}

<*
 Processors a worker read back when it started.
 @param worker : "Shared workers first, then background-only workers."
 @require worker < self.state.workers.len
*>
fn CpuSet JobPool.worker_cpus(&self, uint worker) => self.state.workers[worker].cpus;

<*
 Background cap for a worker count: a quarter, at least one, none without workers.
*>
fn uint default_background_workers(uint worker_count) {
    if (!worker_count) return 0;
    return max(worker_count / BACKGROUND_WORKER_SHARE, 1u);
}

<*
 Workers for the available processors within the quota, less one and at least one.
*>
fn JobPoolDesc default_job_pool_desc() {
    uint worker_count = worker_count_for(available_cpus().cardinality(), cpu_quota() ?? uint::max);
    return {
        .worker_count            = worker_count,
        .worker_temp_bytes       = DEFAULT_WORKER_TEMP_BYTES,
        .run_capacity            = DEFAULT_RUN_CAPACITY,
        .background_run_capacity = DEFAULT_BACKGROUND_RUN_CAPACITY,
        .background_workers      = default_background_workers(worker_count),
    };
}

<*
 Start the workers over a fixed run table, each bound to its processors.
 The allocator is called from worker threads.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, thread::INIT_FAILED
 @require allocator != tmem, desc.run_capacity > 0
*>
fn JobPool? create_job_pool(Allocator allocator, JobPoolDesc desc) {
    CpuSet available = available_cpus();
    CpuSet worker_cpus = bound_cpus(desc.worker_cpus, available)!;
    CpuSet background_cpus = bound_cpus(desc.background_cpus, available)!;
    uint worker_total = desc.worker_count + desc.background_only_workers;

    JobPoolState*? state = alloc::new_try(allocator, JobPoolState, {
        .allocator          = allocator,
        .worker_temp_bytes  = desc.worker_temp_bytes,
        .shared_workers     = desc.worker_count,
        .frame_slots        = desc.run_capacity,
        .background_workers = desc.background_workers,
        .frame_queue        = { .first = NO_RUN, .last = NO_RUN },
        .background_queue   = { .first = NO_RUN, .last = NO_RUN },
    });
    if (catch state) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, state);

    Worker[]? workers = alloc::new_array_try(allocator, Worker, worker_total);
    if (catch workers) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, workers.ptr);
    foreach (index, &worker : workers) {
        worker.state = state;
        worker.background_only = index >= desc.worker_count;
        worker.cpus = worker.background_only ? background_cpus : worker_cpus;
    }
    RunSlot[]? runs = alloc::new_array_try(allocator, RunSlot, (usz)desc.run_capacity + desc.background_run_capacity);
    if (catch runs) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, runs.ptr);
    foreach (&slot : runs) slot.generation = 1;
    state.workers = workers;
    state.runs = runs;

    state.lock.init()!;
    defer catch state.lock.destroy();
    state.work_available.init()!;
    defer catch state.work_available.destroy();
    state.run_finished.init()!;
    defer catch state.run_finished.destroy();

    uint started;
    defer catch stop_workers(state, started);
    for (; started < worker_total; started++) {
        state.workers[started].thread.create(&run_worker, &state.workers[started])!;
    }
    wait_for_reports(state)!;
    return { .state = state };
}

<*
 Stop the workers and free the pool.
 Waits for every outstanding run of either class.
 @param [&inout] pool : "Left zeroed."
 @require active_pool != pool.state : "Not called from a range of this pool."
*>
fn void destroy_job_pool(JobPool* pool) {
    JobPoolState* state = pool.state;
    pool.wait_all();
    stop_workers(state, (uint)state.workers.len);
    state.run_finished.destroy();
    state.work_available.destroy();
    state.lock.destroy();

    Allocator allocator = state.allocator;
    alloc::free(allocator, state.runs.ptr);
    alloc::free(allocator, state.workers.ptr);
    alloc::free(allocator, state);
    *pool = {};
}

fn uint auto_batch(JobPoolState* state, uint count) @private {
    uint ranges = (state.shared_workers + 1) * RANGES_PER_THREAD;
    return (count - 1) / ranges + 1;
}

fn RunSlot run_request(
    JobPoolState* state,
    RangeFn range,
    void* data,
    uint count,
    uint batch,
) @private {
    uint batch_size = batch ? batch : auto_batch(state, count);
    return {
        .range       = range,
        .data        = data,
        .count       = count,
        .batch       = batch_size,
        .range_count = (count - 1) / batch_size + 1,
    };
}

fn JobRange range_at(RunSlot* request, uint index) @private {
    uint first = index * request.batch;
    return {
        .range = request.range,
        .data  = request.data,
        .first = first,
        .count = min(request.batch, request.count - first),
    };
}

fn void run_range(JobPoolState* state, JobRange range) @private {
    JobPoolState* enclosing = active_pool;
    active_pool = state;
    @pool() {
        range.range(range.data, range.first, range.count);
    };
    active_pool = enclosing;
}

fn void run_inline(JobPoolState* state, RunSlot request) @private {
    for (uint index = 0; index < request.range_count; index++) run_range(state, range_at(&request, index));
}

fn bool is_background_slot(JobPoolState* state, uint run_slot) @private => run_slot >= state.frame_slots;

fn RunQueue* queue_of(JobPoolState* state, uint run_slot) @private {
    return is_background_slot(state, run_slot) ? &state.background_queue : &state.frame_queue;
}

fn uint? free_run_slot(JobPoolState* state, JobClass job_class) @private {
    uint first = job_class == FRAME ? 0 : state.frame_slots;
    uint end = job_class == FRAME ? state.frame_slots : (uint)state.runs.len;
    for (uint index = first; index < end; index++) {
        if (!state.runs[index].pending) return index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

fn JobId? queue_run(JobPoolState* state, JobClass job_class, RunSlot request) @private {
    uint run_slot = free_run_slot(state, job_class)!;
    RunSlot* slot = &state.runs[run_slot];
    request.generation = slot.generation;
    request.pending = request.range_count;
    request.sequence = state.next_sequence++;
    *slot = request;

    RunQueue* queue = queue_of(state, run_slot);
    slot.previous_queued = queue.last;
    slot.next_queued = NO_RUN;
    if (queue.last == NO_RUN) {
        queue.first = run_slot;
    } else {
        state.runs[queue.last].next_queued = run_slot;
    }
    queue.last = run_slot;
    return { .index = run_slot, .generation = slot.generation };
}

fn void unlink_run(JobPoolState* state, uint run_slot) @private {
    RunSlot* slot = &state.runs[run_slot];
    RunQueue* queue = queue_of(state, run_slot);
    if (slot.previous_queued == NO_RUN) {
        queue.first = slot.next_queued;
    } else {
        state.runs[slot.previous_queued].next_queued = slot.next_queued;
    }
    if (slot.next_queued == NO_RUN) {
        queue.last = slot.previous_queued;
    } else {
        state.runs[slot.next_queued].previous_queued = slot.previous_queued;
    }
}

// Called with the lock held on a run with an unclaimed range; the lock is released while the range runs.
fn void run_claimed(JobPoolState* state, uint run_slot, Worker* worker = null) @private {
    RunSlot* slot = &state.runs[run_slot];
    bool capped = worker && !worker.background_only && is_background_slot(state, run_slot);
    JobRange range = range_at(slot, slot.next_range++);
    if (slot.next_range == slot.range_count) unlink_run(state, run_slot);
    state.running++;
    if (capped) state.running_background++;
    state.lock.unlock();

    run_range(state, range);

    state.lock.lock();
    state.running--;
    // Sleepers saw no frame run and no free place; later frame work woke them, else this thread takes the freed place.
    if (capped) state.running_background--;
    slot.pending--;
    if (slot.pending) return;
    // Generation 0 belongs to the zero id, which never names a run.
    slot.generation = slot.generation == uint::max ? 1 : slot.generation + 1;
    state.run_finished.broadcast();
}

fn uint? shared_worker_run(JobPoolState* state) @private {
    if (state.frame_queue.first != NO_RUN) return state.frame_queue.first;
    if (state.background_queue.first != NO_RUN && state.running_background < state.background_workers) {
        return state.background_queue.first;
    }
    return NOT_FOUND~;
}

fn uint? background_worker_run(JobPoolState* state) @private {
    if (state.background_queue.first != NO_RUN) return state.background_queue.first;
    return NOT_FOUND~;
}

fn void stop_workers(JobPoolState* state, uint count) @private {
    state.lock.lock();
    state.stopping = true;
    state.lock.unlock();
    state.work_available.broadcast();
    foreach (worker : state.workers[:count]) worker.thread.join()!!;
}

<*
 @return? c3d::UNSUPPORTED
*>
fn void? wait_for_reports(JobPoolState* state) @private {
    state.lock.lock();
    defer state.lock.unlock();
    // Reports share the completion signal; every waiter re-checks its own condition.
    while (state.reported_workers < state.workers.len) state.run_finished.wait(&state.lock);
    foreach (worker : state.workers) {
        if (worker.refused) return c3d::UNSUPPORTED~;
    }
}

fn void bind_worker(Worker* worker) @private {
    bool requested = worker.cpus.cardinality() > 0;
    bool refused = requested && !@ok(native_bind_thread(worker.cpus));
    CpuSet observed = native_thread_cpus();
    JobPoolState* state = worker.state;
    state.lock.lock();
    worker.refused = refused || (requested && observed.data != worker.cpus.data);
    worker.cpus = observed;
    state.reported_workers++;
    state.lock.unlock();
    state.run_finished.broadcast();
}

fn int run_worker(void* argument) @private {
    Worker* worker = argument;
    JobPoolState* state = worker.state;
    bind_worker(worker);
    @pool_init(state.allocator, (sz)state.worker_temp_bytes) {
        state.lock.lock();
        while (true) {
            uint? run_slot = worker.background_only ? background_worker_run(state) : shared_worker_run(state);
            if (try run_slot) {
                run_claimed(state, run_slot, worker);
                continue;
            }
            if (state.stopping) break;
            state.work_available.wait(&state.lock);
        }
        state.lock.unlock();
    };
    return 0;
}
