module c3d::asset::loader;

import c3d;
import c3d::asset @public;
import c3d::asset::fbx;
import c3d::asset::gltf;
import std::thread;
import std::time::clock;

<*
 Request slots when create_async_loader gets capacity 0.
*>
const uint DEFAULT_LOAD_CAPACITY = 8; // each slot can hold a decoded document until publish: 298 MB for Sponza

<*
 Initial size of the worker's temporary pool.
*>
const usz WORKER_TEMP_POOL_BYTES = 256 * 1024; // std's main-thread size; larger files grow it via the loader allocator

<*
 Progress of one load request.
*>
enum LoadPhase {
    QUEUED,
    DECODING,
    DECODED,
    PUBLISHED,
    FAILED,
    CANCELLING,
    CANCELLED,
}

<*
 Importer a request decodes with.
*>
enum ModelFormat {
    GLTF,
    FBX,
}

<*
 File to decode, its importer and options.
*>
struct LoadRequest {
    String      path;
    ModelFormat format;
    LoadOptions options;
    ModelId     replace; // zero adds; otherwise the live model whose key is the path
    AssetRef[]  missing; // borrowed until terminal; written only by publish
}

<*
 Phase of a request with its model or fault.
*>
struct LoadStatus {
    LoadPhase          phase;
    ModelId            model;
    fault              failure;
    ModelReplaceReport report;
}

<*
 Publication item allowance; zero admits unbounded work.
*>
struct PublishLimits {
    ulong items;
}

<*
 Publication transitions and logical work charged by one call.
*>
struct PublishReport {
    uint  published;
    uint  failed;
    ulong items_used;
    ulong required_items;
    bool  required_exact;
    bool  deferred;
}

<*
 Occupied request phases and cumulative work since loader creation.
*>
struct LoaderCounters {
    uint  queued;
    uint  decoding;
    uint  decoded;
    uint  cancelling;
    uint  published;
    uint  failed;
    uint  cancelled;
    ulong publications;
    ulong decode_failures;
    ulong commit_failures;
    ulong cancellations;
    ulong publication_items;
    ulong decode_ns;
    ulong publication_ns;
}

struct LoadSlot @private {
    LoadRequest           request;
    LoadPhase             phase;
    bool                  occupied;
    uint                  generation;
    ulong                 sequence;
    PreparedModelDocument prepared;
    uint                  decoded_previous;
    uint                  decoded_next;
    ModelId               model;
    fault                 failure;
    ModelReplaceReport    report;
}

struct LoaderState @private {
    Allocator         allocator;
    Allocator         document_allocator;
    FileSource        file_source;
    AssetStore*       assets;
    Mutex             lock;
    ConditionVariable wake;
    Thread            worker; // Thread.create writes this while the worker runs; the worker never reads it
    LoadSlot[]        slots;
    uint              decoded_head;
    uint              decoded_tail;
    ulong             next_sequence;
    LoaderCounters    counters;
    bool              stopping;
}

<*
 Background decoder of model files, published on the owner thread.
*>
struct AsyncLoader {
    LoaderState* state;
}

<*
 Queue a model file for decoding, as an add or replacement.
 A target removed before publication fails with c3d::INVALID_ID.
 @param request : "Path is copied; missing is borrowed until terminal."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
 @require request.path.len > 0
*>
fn LoadId? AsyncLoader.request(&self, LoadRequest request) {
    LoaderState* state = self.state;
    if (request.replace.generation) {
        ModelAsset* target = state.assets.models.try_get(request.replace)!;
        if (target.header.key != request.path) return c3d::INVALID_ARGUMENT~;
    } else if (state.assets.keys.has_key(request.path)) {
        return c3d::INVALID_ARGUMENT~;
    }
    state.lock.lock();
    defer state.lock.unlock();
    foreach (&slot : state.slots) {
        if (slot.occupied && is_pending(slot.phase) && slot.request.path == request.path) return c3d::INVALID_ARGUMENT~;
    }
    foreach (uint index, &slot : state.slots) {
        if (slot.occupied) continue;
        request.path = request.path.copy(state.allocator);
        *slot = {
            .request    = request,
            .phase      = LoadPhase.QUEUED,
            .occupied   = true,
            .generation = slot.generation,
            .sequence   = state.next_sequence++,
        };
        state.wake.signal();
        return { .index = index, .generation = slot.generation };
    }
    return c3d::CAPACITY_EXCEEDED~;
}

<*
 Phase and result of a request.
 @return "FAILED with c3d::INVALID_ID for a stale id."
*>
fn LoadStatus AsyncLoader.status(&self, LoadId id) {
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    LoadSlot*? slot = live_slot(state, id);
    if (catch excuse = slot) return { .phase = LoadPhase.FAILED, .failure = excuse };
    return { .phase = slot.phase, .model = slot.model, .failure = slot.failure, .report = slot.report };
}

<*
 Publish all decoded requests in FIFO order without an allowance.
 @return "Requests this call moved to PUBLISHED or FAILED."
*>
fn uint AsyncLoader.publish(&self) {
    PublishReport report = self.publish_within({});
    return report.published + report.failed;
}

<*
 Publish FIFO requests within a logical item allowance.
 @return "Current-call work and the deferred head's requirement."
*>
fn PublishReport AsyncLoader.publish_within(&self, PublishLimits limits) {
    std::time::Clock started = clock::now();
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    PublishReport report;
    bool bounded = limits.items != 0;
    while (state.decoded_head) {
        uint index = state.decoded_head - 1;
        LoadSlot* slot = &state.slots[index];
        ulong remaining = bounded ? limits.items - report.items_used : 0;
        PublicationEstimate estimate = asset::estimate_model_publication(
            store:     state.assets,
            prepared:  &slot.prepared,
            model:     slot.request.replace,
            allowance: remaining,
            bounded:   bounded,
        );
        report.items_used = add_saturated(report.items_used, estimate.items_used);
        if (!estimate.admitted) {
            report.required_items = estimate.required_items;
            report.required_exact = estimate.required_exact;
            report.deferred = true;
            break;
        }
        report.items_used = add_saturated(report.items_used, estimate.required_items - estimate.items_used);
        remove_decoded(state, index);
        publish_slot(state.assets, slot);
        asset::destroy_prepared_model_document(&slot.prepared);
        if (slot.phase == LoadPhase.PUBLISHED) {
            report.published++;
            state.counters.publications = add_saturated(state.counters.publications, 1);
        } else {
            report.failed++;
            state.counters.commit_failures = add_saturated(state.counters.commit_failures, 1);
        }
    }
    state.counters.publication_items = add_saturated(state.counters.publication_items, report.items_used);
    state.counters.publication_ns = add_saturated(state.counters.publication_ns, (ulong)started.to_now());
    return report;
}

<*
 Abandon a request; active decoding acknowledges cancellation after disposal.
 Decoded cleanup is outside the publication allowance.
 @return? c3d::INVALID_ID
*>
fn void? AsyncLoader.cancel(&self, LoadId id) {
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    LoadSlot* slot = live_slot(state, id)!;
    switch (slot.phase) {
        case QUEUED:
            finish_cancel(state, slot);
        case DECODING:
            slot.phase = LoadPhase.CANCELLING;
        case DECODED:
            remove_decoded(state, id.index);
            asset::destroy_prepared_model_document(&slot.prepared);
            finish_cancel(state, slot);
        case CANCELLING:
        case PUBLISHED:
        case FAILED:
        case CANCELLED:
            return;
    }
}

<*
 Snapshot occupied phases and cumulative decode/publication accounts.
*>
fn LoaderCounters AsyncLoader.counters(&self) {
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    LoaderCounters counters = state.counters;
    foreach (&slot : state.slots) {
        if (!slot.occupied) continue;
        switch (slot.phase) {
            case QUEUED: counters.queued++;
            case DECODING: counters.decoding++;
            case DECODED: counters.decoded++;
            case CANCELLING: counters.cancelling++;
            case PUBLISHED: counters.published++;
            case FAILED: counters.failed++;
            case CANCELLED: counters.cancelled++;
        }
    }
    return counters;
}

<*
 Free a terminal request slot.
 @return? c3d::INVALID_ID
 @require !holds_pending(self.state, id)
*>
fn void? AsyncLoader.release(&self, LoadId id) {
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    LoadSlot* slot = live_slot(state, id)!;
    alloc::free(state.allocator, slot.request.path.ptr);
    *slot = { .generation = slot.generation == uint::max ? 1 : slot.generation + 1 };
}

<*
 Start model decoding over fixed request slots.
 Allocators and the file source are used by the worker.
 @param [&in] assets : "Publication target; outlives the loader."
 @param capacity : "Request slots; zero selects DEFAULT_LOAD_CAPACITY."
 @return? thread::INIT_FAILED
 @require allocator != tmem, assets.allocator != tmem
*>
fn AsyncLoader? create_async_loader(Allocator allocator, AssetStore* assets, uint capacity = 0) {
    LoaderState* state = alloc::new(allocator, LoaderState);
    defer catch alloc::free(allocator, state);
    *state = {
        .allocator          = allocator,
        .document_allocator = assets.allocator,
        .file_source        = assets.file_source,
        .assets             = assets,
        .slots              = alloc::new_array(allocator, LoadSlot, (sz)(capacity ? capacity : DEFAULT_LOAD_CAPACITY)),
        .next_sequence      = 1,
    };
    defer catch alloc::free(allocator, state.slots.ptr);
    foreach (&slot : state.slots) slot.generation = 1;
    state.lock.init()!;
    defer catch state.lock.destroy();
    state.wake.init()!;
    defer catch state.wake.destroy();
    state.worker.create(&run_worker, state)!;
    return { .state = state };
}

<*
 Join the worker and free unpublished documents and requests.
 @param [&inout] loader : "Destroyed before its store; left zeroed."
*>
fn void destroy_async_loader(AsyncLoader* loader) {
    LoaderState* state = loader.state;
    state.lock.lock();
    state.stopping = true;
    state.wake.broadcast();
    state.lock.unlock();
    // The worker uses both allocators until joined; earlier frees would race it.
    state.worker.join()!!;
    foreach (&slot : state.slots) {
        if (!slot.occupied) continue;
        if (slot.phase == LoadPhase.DECODED) asset::destroy_prepared_model_document(&slot.prepared);
        alloc::free(state.allocator, slot.request.path.ptr);
    }
    state.wake.destroy();
    state.lock.destroy();
    Allocator allocator = state.allocator;
    alloc::free(allocator, state.slots.ptr);
    alloc::free(allocator, state);
    *loader = {};
}

fn ulong add_saturated(ulong first, ulong second) @private => second > ulong::max - first ? ulong::max : first + second;

fn void finish_cancel(LoaderState* state, LoadSlot* slot) @private {
    slot.phase = LoadPhase.CANCELLED;
    state.counters.cancellations = add_saturated(state.counters.cancellations, 1);
}

fn void append_decoded(LoaderState* state, uint index) @private {
    LoadSlot* slot = &state.slots[index];
    slot.decoded_previous = state.decoded_tail;
    if (state.decoded_tail) {
        state.slots[state.decoded_tail - 1].decoded_next = index + 1;
    } else {
        state.decoded_head = index + 1;
    }
    state.decoded_tail = index + 1;
}

fn void remove_decoded(LoaderState* state, uint index) @private {
    LoadSlot* slot = &state.slots[index];
    if (slot.decoded_previous) {
        state.slots[slot.decoded_previous - 1].decoded_next = slot.decoded_next;
    } else {
        state.decoded_head = slot.decoded_next;
    }
    if (slot.decoded_next) {
        state.slots[slot.decoded_next - 1].decoded_previous = slot.decoded_previous;
    } else {
        state.decoded_tail = slot.decoded_previous;
    }
    slot.decoded_previous = 0;
    slot.decoded_next = 0;
}

fn void publish_slot(AssetStore* assets, LoadSlot* slot) @private {
    if (!slot.request.replace.generation) {
        ModelId? model = asset::publish_prepared_model_document(assets, &slot.prepared);
        if (catch excuse = model) {
            slot.phase = LoadPhase.FAILED;
            slot.failure = excuse;
        } else {
            slot.phase = LoadPhase.PUBLISHED;
            slot.model = model;
        }
        return;
    }
    ModelReplaceReport? report = asset::replace_prepared_model_document(
        store:    assets,
        model:    slot.request.replace,
        prepared: &slot.prepared,
        missing:  slot.request.missing,
    );
    if (catch excuse = report) {
        slot.phase = LoadPhase.FAILED;
        slot.failure = excuse;
    } else {
        slot.phase = LoadPhase.PUBLISHED;
        slot.model = slot.request.replace;
        slot.report = report;
    }
}

fn bool holds_pending(LoaderState* state, LoadId id) @private {
    state.lock.lock();
    defer state.lock.unlock();
    LoadSlot*? slot = live_slot(state, id);
    if (catch excuse = slot) return false;
    return is_pending(slot.phase);
}

fn LoadSlot*? live_slot(LoaderState* state, LoadId id) @private {
    if (id.index >= state.slots.len) return c3d::INVALID_ID~;
    LoadSlot* slot = &state.slots[id.index];
    if (!slot.occupied || slot.generation != id.generation) return c3d::INVALID_ID~;
    return slot;
}

fn bool is_pending(LoadPhase phase) @private {
    return phase == LoadPhase.QUEUED || phase == LoadPhase.DECODING
        || phase == LoadPhase.DECODED || phase == LoadPhase.CANCELLING;
}

fn usz? oldest_queued(LoaderState* state) @private {
    usz? oldest = NOT_FOUND~;
    foreach (usz index, &slot : state.slots) {
        if (!slot.occupied || slot.phase != LoadPhase.QUEUED) continue;
        if (try current = oldest) {
            if (state.slots[current].sequence < slot.sequence) continue;
        }
        oldest = index;
    }
    return oldest;
}

fn usz? next_decode(LoaderState* state) @private {
    state.lock.lock();
    defer state.lock.unlock();
    while (!state.stopping) {
        if (try index = oldest_queued(state)) {
            state.slots[index].phase = LoadPhase.DECODING;
            return index;
        }
        state.wake.wait(&state.lock);
    }
    return NOT_FOUND~;
}

fn void decode_slot(LoaderState* state, usz index) @private {
    std::time::Clock started = clock::now();
    // Pending requests are immutable until release, including while CANCELLING.
    PreparedModelDocument? prepared = decode_prepared_request(
        allocator:   state.document_allocator,
        file_source: state.file_source,
        request:     state.slots[index].request,
    );
    ulong elapsed_ns = (ulong)started.to_now();
    state.lock.lock();
    defer state.lock.unlock();
    state.counters.decode_ns = add_saturated(state.counters.decode_ns, elapsed_ns);
    LoadSlot* slot = &state.slots[index];
    if (slot.phase == LoadPhase.CANCELLING) {
        if (try result = prepared) asset::destroy_prepared_model_document(&result);
        finish_cancel(state, slot);
        return;
    }
    if (catch excuse = prepared) {
        slot.phase = LoadPhase.FAILED;
        slot.failure = excuse;
        state.counters.decode_failures = add_saturated(state.counters.decode_failures, 1);
        return;
    }
    slot.prepared = prepared;
    slot.phase = LoadPhase.DECODED;
    append_decoded(state, (uint)index);
}

fn PreparedModelDocument? decode_prepared_request(
    Allocator allocator,
    FileSource file_source,
    LoadRequest request,
) @private {
    ModelDocument document = decode_request(allocator, file_source, request)!;
    defer asset::destroy_model_document(&document);
    return asset::prepare_model_document(&document);
}

fn ModelDocument? decode_request(Allocator allocator, FileSource file_source, LoadRequest request) @private {
    switch (request.format) {
        case GLTF: return gltf::decode_model(allocator, request.path, request.options, file_source);
        case FBX: return fbx::decode_model(allocator, request.path, request.options, file_source);
    }
}

fn int run_worker(void* argument) @private {
    LoaderState* state = argument;
    @pool_init(state.allocator, WORKER_TEMP_POOL_BYTES) {
        while (try index = next_decode(state)) decode_slot(state, index);
    };
    return 0;
}
