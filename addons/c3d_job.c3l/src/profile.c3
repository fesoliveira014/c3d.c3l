module c3d::job @feat(C3D_PROFILE_CPU);

import c3d::profile;
import std::time::clock;

<*
 Worker range records a pool holds between drains.
*>
const uint DEFAULT_RECORD_CAPACITY = 4096; // 160 KiB at 40 bytes a record; four runs of 1024 worker ranges between drains

const usz FORWARD_BATCH @private = 64; // records copied per lock hold; 2.5 KiB of stack

<*
 One range a worker ran, timed on the profiler's clock.
*>
struct JobRangeRecord {
    String name;     // the run's name, borrowed from the submitter until the drain
    uint   worker;   // shared workers first, then background-only workers
    ulong  start_ns; // clock::now() before the range
    ulong  end_ns;   // clock::now() after the range
}

<*
 Records one drain moved out of a pool.
*>
struct JobRecordDrain {
    usz   count;   // records written
    ulong dropped; // worker ranges lost to a full record ring since the previous drain
}

<*
 Record worker ranges from each worker's next claim, or stop recording.
*>
fn void JobPool.set_recording(&self, bool recording) {
    JobPoolState* state = self.state;
    state.lock.lock();
    state.recording = recording;
    state.lock.unlock();
}

<*
 Move the oldest worker range records out of the pool.
 @param [out] records : "Receives at most its length of records."
 @return "Records written and drops since the previous drain."
*>
fn JobRecordDrain JobPool.take_records(&self, JobRangeRecord[] records) {
    JobPoolState* state = self.state;
    state.lock.lock();
    defer state.lock.unlock();
    uint capacity = (uint)state.records.len;
    uint count = min((uint)records.len, state.record_count);
    for (uint index = 0; index < count; index++) records[index] = state.records[(state.record_head + index) % capacity];
    if (count) state.record_head = (state.record_head + count) % capacity;
    state.record_count -= count;
    JobRecordDrain drain = { .count = count, .dropped = state.dropped_records };
    state.dropped_records = 0;
    return drain;
}

<*
 Move the records held at the call into the recorder's open capture.
 Records drained outside a recording capture are discarded.
 @param [&inout] recorder : "Recorder on its owning thread."
 @return "Records drained."
*>
fn usz JobPool.forward_records(&self, profile::Recorder* recorder) {
    JobRangeRecord[FORWARD_BATCH] batch;
    usz held = held_records(self.state);
    usz forwarded;
    while (true) {
        JobRecordDrain drain = self.take_records(batch[:min(FORWARD_BATCH, held - forwarded)]);
        if (drain.dropped) recorder.add_dropped_worker_intervals(drain.dropped);
        foreach (record : batch[:drain.count]) {
            recorder.add_worker_interval(
                lane:     record.worker,
                label:    record.name,
                start_ns: record.start_ns,
                end_ns:   record.end_ns,
            );
        }
        forwarded += drain.count;
        if (forwarded == held || !drain.count) return forwarded;
    }
}

fn usz held_records(JobPoolState* state) @private {
    state.lock.lock();
    defer state.lock.unlock();
    return state.record_count;
}

fn ulong range_clock() @private => (ulong)clock::now();

fn void push_record(JobPoolState* state, JobRangeRecord record) @private {
    uint capacity = (uint)state.records.len;
    if (state.record_count == capacity) {
        state.dropped_records++;
        return;
    }
    state.records[(state.record_head + state.record_count) % capacity] = record;
    state.record_count++;
}
