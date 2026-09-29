module c3d::job;

import c3d;
import std::thread;
import std::thread::cpu;

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
const usz DEFAULT_WORKER_TEMP_BYTES = 256 * 1024; // std's main-thread size; a range whose scratch exceeds it allocates and frees a page each time it runs

<*
 Ranges queued at once across every run.
*>
const uint DEFAULT_RING_CAPACITY = 4096; // 128 KiB at 32 bytes a range; a run takes ceil(count / batch) entries, so 262 144 items in batches of 64 fit

<*
 Runs with queued or running ranges at once.
*>
const uint DEFAULT_RUN_CAPACITY = 64; // 512 bytes; a fork-join caller holds one run at a time

const uint RANGES_PER_THREAD @private = 4; // batch 0 splits a run into this many ranges per pool thread; each range costs one queue round trip

tlocal JobPoolState* active_pool @private;

<*
 Worker threads, temp memory and queue capacities of a job pool.
*>
struct JobPoolDesc {
    uint worker_count;      // 0 runs every range on the calling thread
    usz  worker_temp_bytes; // initial temp allocator of each worker
    uint ring_capacity;     // ranges queued at once; a range that does not fit runs inline
    uint run_capacity;      // runs in flight at once; a run that does not fit runs inline
}

struct JobRange @private {
    RangeFn range;
    void*   data;
    uint    first;
    uint    count;
    uint    run_slot;
}

struct RunSlot @private {
    uint generation;
    uint pending; // queued or running ranges; the slot is free at 0
}

struct RunRequest @private {
    RangeFn range;
    void*   data;
    uint    count;
    uint    batch;
}

struct JobPoolState @private {
    Allocator         allocator;
    usz               worker_temp_bytes;
    Thread[]          workers; // Thread.create writes an entry its worker may already read, so the array never moves
    JobRange[]        ring;
    RunSlot[]         runs;
    Mutex             lock; // guards every field below
    ConditionVariable work_available;
    ConditionVariable run_finished;
    uint              head;
    uint              queued;
    uint              running;
    ulong             inline_ranges;
    bool              stopping;
}

<*
 Fixed pool of worker threads running fork-join index ranges.
*>
struct JobPool {
    JobPoolState* state;
}

<*
 Split [0, count) into ranges and queue them for the pool's threads.
 Ranges the ring or the run table cannot hold run inline before the return.
 @param [inout] data : "Handed to every range; outlives the wait."
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
    RunRequest request = {
        .range = range,
        .data  = data,
        .count = count,
        .batch = batch ? batch : auto_batch(state, count),
    };
    uint range_count = (count - 1) / request.batch + 1;
    if (!state.workers.len || active_pool == state) {
        run_inline(state, request, 0);
        return {};
    }

    state.lock.lock();
    JobId id;
    uint queued_ranges = min(range_count, (uint)state.ring.len - state.queued);
    if (queued_ranges) {
        if (try run_slot = free_run_slot(state)) {
            id = queue_ranges(
                state:       state,
                request:     request,
                run_slot:    run_slot,
                range_count: queued_ranges,
            );
        } else {
            queued_ranges = 0;
        }
    }
    state.inline_ranges += (ulong)(range_count - queued_ranges);
    state.lock.unlock();

    if (queued_ranges) state.work_available.broadcast();
    run_inline(state, request, queued_ranges);
    return id;
}

<*
 Block until the run has finished, running its queued ranges meanwhile.
 @require id.index < self.state.runs.len : "The id came from this pool."
 @require active_pool != self.state || id.generation == 0 : "From a range of this pool, only a nested run's zero id."
*>
fn void JobPool.wait(&self, JobId id) {
    JobPoolState* state = self.state;
    state.lock.lock();
    while (state.runs[id.index].generation == id.generation) {
        if (try position = queued_position(state, id.index)) {
            run_taken(state, position);
            continue;
        }
        state.run_finished.wait(&state.lock);
    }
    state.lock.unlock();
}

<*
 Block until nothing is queued or running, running any queued range meanwhile.
 @require active_pool != self.state : "Not called from a range of this pool."
*>
fn void JobPool.wait_all(&self) {
    JobPoolState* state = self.state;
    state.lock.lock();
    while (state.queued || state.running) {
        if (state.queued) {
            run_taken(state, state.head);
            continue;
        }
        state.run_finished.wait(&state.lock);
    }
    state.lock.unlock();
}

<*
 Cumulative ranges run inline because the ring or the run table was full.
*>
fn ulong JobPool.inline_ranges(&self) {
    JobPoolState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    return state.inline_ranges;
}

<*
 One worker per logical processor but one, and the default capacities.
*>
fn JobPoolDesc default_job_pool_desc() {
    return {
        .worker_count      = (uint)max(cpu::native_cpu() - 1, 1),
        .worker_temp_bytes = DEFAULT_WORKER_TEMP_BYTES,
        .ring_capacity     = DEFAULT_RING_CAPACITY,
        .run_capacity      = DEFAULT_RUN_CAPACITY,
    };
}

<*
 Start the workers over a fixed range ring and run table.
 The allocator is called from worker threads.
 @return? c3d::CAPACITY_EXCEEDED, thread::INIT_FAILED
 @require allocator != tmem, desc.ring_capacity > 0, desc.run_capacity > 0
*>
fn JobPool? create_job_pool(Allocator allocator, JobPoolDesc desc) {
    JobPoolState*? state = alloc::new_try(allocator, JobPoolState, {
        .allocator         = allocator,
        .worker_temp_bytes = desc.worker_temp_bytes,
    });
    if (catch state) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, state);

    Thread[]? workers = alloc::new_array_try(allocator, Thread, desc.worker_count);
    if (catch workers) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, workers.ptr);
    JobRange[]? ring = alloc::new_array_try(allocator, JobRange, desc.ring_capacity);
    if (catch ring) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, ring.ptr);
    RunSlot[]? runs = alloc::new_array_try(allocator, RunSlot, desc.run_capacity);
    if (catch runs) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, runs.ptr);
    foreach (&slot : runs) slot.generation = 1;
    state.workers = workers;
    state.ring = ring;
    state.runs = runs;

    state.lock.init()!;
    defer catch state.lock.destroy();
    state.work_available.init()!;
    defer catch state.work_available.destroy();
    state.run_finished.init()!;
    defer catch state.run_finished.destroy();

    uint started;
    defer catch stop_workers(state, started);
    for (; started < desc.worker_count; started++) {
        state.workers[started].create(&run_worker, state)!;
    }
    return { .state = state };
}

<*
 Stop the workers and free the pool.
 Waits for every outstanding run.
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
    alloc::free(allocator, state.ring.ptr);
    alloc::free(allocator, state.runs.ptr);
    alloc::free(allocator, state.workers.ptr);
    alloc::free(allocator, state);
    *pool = {};
}

fn uint auto_batch(JobPoolState* state, uint count) @private {
    uint ranges = ((uint)state.workers.len + 1) * RANGES_PER_THREAD;
    return (count - 1) / ranges + 1;
}

fn JobRange range_at(RunRequest request, uint index, uint run_slot = 0) @private {
    uint first = index * request.batch;
    return {
        .range    = request.range,
        .data     = request.data,
        .first    = first,
        .count    = min(request.batch, request.count - first),
        .run_slot = run_slot,
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

fn void run_inline(JobPoolState* state, RunRequest request, uint first_range) @private {
    uint range_count = (request.count - 1) / request.batch + 1;
    for (uint index = first_range; index < range_count; index++) run_range(state, range_at(request, index));
}

fn uint? free_run_slot(JobPoolState* state) @private {
    foreach (uint index, slot : state.runs) {
        if (!slot.pending) return index;
    }
    return NOT_FOUND~;
}

fn JobId queue_ranges(
    JobPoolState* state,
    RunRequest request,
    uint run_slot,
    uint range_count,
) @private {
    uint capacity = (uint)state.ring.len;
    for (uint index = 0; index < range_count; index++) {
        state.ring[(state.head + state.queued + index) % capacity] = range_at(request, index, run_slot);
    }
    state.queued += range_count;
    RunSlot* slot = &state.runs[run_slot];
    slot.pending = range_count;
    return { .index = run_slot, .generation = slot.generation };
}

fn uint? queued_position(JobPoolState* state, uint run_slot) @private {
    uint capacity = (uint)state.ring.len;
    for (uint offset = 0; offset < state.queued; offset++) {
        uint position = (state.head + offset) % capacity;
        if (state.ring[position].run_slot == run_slot) return position;
    }
    return NOT_FOUND~;
}

// Called with the lock held; the lock is released while the range runs.
fn void run_taken(JobPoolState* state, uint position) @private {
    JobRange range = state.ring[position];
    state.ring[position] = state.ring[state.head];
    state.head = (state.head + 1) % (uint)state.ring.len;
    state.queued--;
    state.running++;
    state.lock.unlock();

    run_range(state, range);

    state.lock.lock();
    state.running--;
    RunSlot* slot = &state.runs[range.run_slot];
    slot.pending--;
    if (slot.pending) return;
    // Generation 0 belongs to the zero id, which never names a run.
    slot.generation = slot.generation == uint::max ? 1 : slot.generation + 1;
    state.run_finished.broadcast();
}

fn void stop_workers(JobPoolState* state, uint count) @private {
    state.lock.lock();
    state.stopping = true;
    state.lock.unlock();
    state.work_available.broadcast();
    foreach (worker : state.workers[:count]) worker.join()!!;
}

fn int run_worker(void* argument) @private {
    JobPoolState* state = argument;
    @pool_init(state.allocator, (sz)state.worker_temp_bytes) {
        state.lock.lock();
        while (state.queued || !state.stopping) {
            if (state.queued) {
                run_taken(state, state.head);
                continue;
            }
            state.work_available.wait(&state.lock);
        }
        state.lock.unlock();
    };
    return 0;
}
