module c3d::asset::loader;

import c3d;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::gltf;
import std::thread;

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
    AssetRef[]  missing; // borrowed until PUBLISHED or FAILED; written only by publish
}

<*
 Phase of a request with its model or fault.
*>
struct LoadStatus {
    LoadPhase          phase;
    ModelId            model;
    fault              failure;
    ModelReplaceReport report; // zero for an add
}

struct LoadSlot @private {
    LoadRequest   request;
    LoadPhase     phase;
    bool          occupied;
    uint          generation;
    ulong         sequence;
    ModelDocument document;
    ModelId       model;
    fault         failure;
    ModelReplaceReport report;
}

struct LoaderState @private {
    Allocator         allocator;
    Allocator         document_allocator;
    FileSource        file_source;
    AssetStore*       assets;
    Mutex             lock;
    ConditionVariable wake;
    Thread            worker; // written by Thread.create while the worker may run; the worker never reads it
    LoadSlot[]        slots;
    ulong             next_sequence;
    bool              stopping;
}

<*
 Background decoder of model files, published into a store on the owner thread.
*>
struct AsyncLoader {
    LoaderState* state;
}

<*
 Queue a model file for decoding on the worker, as an add or as a replacement.
 A replacement target removed before publish fails the request with c3d::INVALID_ID.
 @param request : "The path is copied; the missing slice is borrowed until the request ends."
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
 @return "FAILED with c3d::INVALID_ID for a released or stale id."
*>
fn LoadStatus AsyncLoader.status(&self, LoadId id) {
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    LoadSlot*? slot = live_slot(state, id);
    if (catch slot) return { .phase = LoadPhase.FAILED, .failure = c3d::INVALID_ID };
    return { .phase = slot.phase, .model = slot.model, .failure = slot.failure, .report = slot.report };
}

<*
 Publish every decoded document into the store in request order.
 @return "Requests this call moved to PUBLISHED or FAILED."
*>
fn uint AsyncLoader.publish(&self) {
    LoaderState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    uint transitions;
    while (try index = oldest_in_phase(state, LoadPhase.DECODED)) {
        LoadSlot* slot = &state.slots[index];
        publish_slot(state.assets, slot);
        asset::destroy_model_document(&slot.document);
        transitions++;
    }
    return transitions;
}

<*
 Free the slot of a PUBLISHED or FAILED request.
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
 Start the worker thread over a table of request slots.
 The store allocator, the loader allocator and the store's file source are used from the worker thread.
 @param [&in] assets : "Publication target; outlives the loader."
 @param capacity : "Request slots; 0 selects DEFAULT_LOAD_CAPACITY."
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
 Stop the worker and free every unpublished document and request.
 Blocks until the decode in progress ends.
 @param [&inout] loader : "Destroyed before its asset store; left zeroed."
*>
fn void destroy_async_loader(AsyncLoader* loader) {
    LoaderState* state = loader.state;
    state.lock.lock();
    state.stopping = true;
    state.wake.broadcast();
    state.lock.unlock();
    // The worker allocates from both allocators until it has joined; freeing earlier would race it.
    state.worker.join()!!;
    foreach (&slot : state.slots) {
        if (!slot.occupied) continue;
        if (slot.phase == LoadPhase.DECODED) asset::destroy_model_document(&slot.document);
        alloc::free(state.allocator, slot.request.path.ptr);
    }
    state.wake.destroy();
    state.lock.destroy();
    Allocator allocator = state.allocator;
    alloc::free(allocator, state.slots.ptr);
    alloc::free(allocator, state);
    *loader = {};
}

fn void publish_slot(AssetStore* assets, LoadSlot* slot) @private {
    if (!slot.request.replace.generation) {
        ModelId? model = assets.publish_document(&slot.document);
        if (catch excuse = model) {
            slot.phase = LoadPhase.FAILED;
            slot.failure = excuse;
        } else {
            slot.phase = LoadPhase.PUBLISHED;
            slot.model = model;
        }
        return;
    }
    if (!assets.models.is_live(slot.request.replace)) {
        slot.phase = LoadPhase.FAILED;
        slot.failure = c3d::INVALID_ID;
        return;
    }
    ModelReplaceReport? report = assets.replace_document(slot.request.replace, &slot.document, slot.request.missing);
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
    if (catch slot) return false;
    return is_pending(slot.phase);
}

fn LoadSlot*? live_slot(LoaderState* state, LoadId id) @private {
    if (id.index >= state.slots.len) return c3d::INVALID_ID~;
    LoadSlot* slot = &state.slots[id.index];
    if (!slot.occupied || slot.generation != id.generation) return c3d::INVALID_ID~;
    return slot;
}

fn bool is_pending(LoadPhase phase) @private {
    return phase == LoadPhase.QUEUED || phase == LoadPhase.DECODING || phase == LoadPhase.DECODED;
}

fn usz? oldest_in_phase(LoaderState* state, LoadPhase phase) @private {
    usz? oldest = NOT_FOUND~;
    foreach (usz index, &slot : state.slots) {
        if (!slot.occupied || slot.phase != phase) continue;
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
        if (try index = oldest_in_phase(state, LoadPhase.QUEUED)) {
            state.slots[index].phase = LoadPhase.DECODING;
            return index;
        }
        state.wake.wait(&state.lock);
    }
    return NOT_FOUND~;
}

fn void decode_slot(LoaderState* state, usz index) @private {
    // A pending slot's request is written before QUEUED and never changes until release.
    ModelDocument? document = decode_request(
        allocator:   state.document_allocator,
        file_source: state.file_source,
        request:     state.slots[index].request,
    );
    state.lock.lock();
    defer state.lock.unlock();
    LoadSlot* slot = &state.slots[index];
    if (catch excuse = document) {
        slot.phase = LoadPhase.FAILED;
        slot.failure = excuse;
        return;
    }
    slot.document = document;
    slot.phase = LoadPhase.DECODED;
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
