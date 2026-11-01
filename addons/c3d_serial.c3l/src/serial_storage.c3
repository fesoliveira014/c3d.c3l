module c3d::serial;

<*
 Owner of the strings and slices that value reads decode.
*>
struct SerialStorage {
    Acquisitions owned;
}

<*
 Free every decoded string and slice; the storage stays usable.
 Values read into it must not be used afterwards.
*>
fn void SerialStorage.release(&self) {
    self.owned.release();
}

<*
 Create empty storage that allocates through the allocator.
 @require allocator.ptr != null
*>
fn SerialStorage create_serial_storage(Allocator allocator) {
    return { .owned = { .allocator = allocator } };
}

<*
 Free the storage and every string and slice it owns.
 @param [&inout] storage : "Cleared afterward."
*>
fn void destroy_serial_storage(SerialStorage* storage) {
    storage.release();
    *storage = {};
}
