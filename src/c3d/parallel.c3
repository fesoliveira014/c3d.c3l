module c3d;

<*
 Work over items [first, first + count) of data.
*>
alias ParallelRangeFn = fn void(void* data, uint first, uint count);

<*
 Run range over [0, count) in batches of batch items, and return when every range finished.
*>
alias ParallelForFn = fn void(void* context, ParallelRangeFn range, void* data, uint count, uint batch);

<*
 Caller-supplied fork-join over index ranges; a zero value runs serially.
*>
struct ParallelFor {
    ParallelForFn run;
    void*         context;
}

<*
 Run range over [0, count) through run, or inline as one range without run.
 @param [inout] data : "Handed to every range; valid until the call returns."
*>
fn void ParallelFor.for_ranges(
    &self,
    ParallelRangeFn range,
    void* data,
    uint count,
    uint batch,
) {
    if (!self.run) {
        range(data, 0, count);
        return;
    }

    self.run(
        context: self.context,
        range:   range,
        data:    data,
        count:   count,
        batch:   batch,
    );
}
