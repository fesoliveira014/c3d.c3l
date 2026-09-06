module c3d::render;

import gpu;
import std::atomic::types;
import std::io;

<*
 Characters kept from one borrowed diagnostic string.
*>
const usz DEBUG_TEXT_BYTES = 192;

<*
 Diagnostics the log keeps before overwriting the oldest.
*>
const usz DEBUG_LOG_ENTRIES = 64; // 26 KiB per renderer; a validation burst stays readable without a growing buffer

<*
 One diagnostic delivered by the backend, with its borrowed strings copied.
*>
struct DebugEntry {
    gpu::DebugMessageSeverity severity;
    gpu::DebugMessageCategory category;
    gpu::DebugResourceKind    resource_kind;
    uint                      resource_index;
    int                       validation_id_number;
    bool                      has_fault;
    fault                     public_fault;
    char[DEBUG_TEXT_BYTES]    operation;
    char[DEBUG_TEXT_BYTES]    text;
}

<*
 Fixed ring of the most recent diagnostics.
 A reader racing a backend thread can observe one half-written entry.
*>
struct DebugLog {
    DebugEntry[DEBUG_LOG_ENTRIES] entries;
    Atomic{usz}                   written;
}

<*
 Copy the most recent entries, oldest first.
 @param [&in] self : "Borrowed; its entries are overwritten by later diagnostics."
 @return "Entries written, at most the smaller of the destination and the ring."
*>
fn usz DebugLog.recent(&self, DebugEntry[] out) {
    usz written = self.written.load();
    usz available = written < DEBUG_LOG_ENTRIES ? written : DEBUG_LOG_ENTRIES;
    usz count = available < out.len ? available : out.len;
    usz first = written - count;
    for (usz index = 0; index < count; index++) {
        out[index] = self.entries[(first + index) % DEBUG_LOG_ENTRIES];
    }
    return count;
}

<*
 Copy one diagnostic into the ring, overwriting the oldest when full.
 @param [&inout] self : "Claims a slot atomically; the entry's fields are not ordered against the claim."
 @param [&in] message : "Borrowed for the call; its strings are copied."
*>
fn void DebugLog.record(&self, gpu::DebugMessage* message) {
    DebugEntry* entry = &self.entries[self.written.add(1) % DEBUG_LOG_ENTRIES];
    *entry = {
        .severity             = message.severity,
        .category             = message.category,
        .resource_kind        = message.resource.kind,
        .resource_index       = message.resource.index,
        .validation_id_number = message.validation_id_number,
        .has_fault            = message.has_fault,
        .public_fault         = message.public_fault,
    };
    copy_debug_text(entry.operation[..], message.operation);
    copy_debug_text(entry.text[..], message.backend_text ? message.backend_text : message.invariant);
}

fn void record_debug_message(gpu::DebugMessage* message, void* user) @private {
    ((DebugLog*)user).record(message);
    if (!is_routine_fault(message)) print_debug_message(message);
}

// The backend reports these at ERROR severity, but the frame boundary handles both as ordinary
// control flow, so printing them would bury a real diagnostic under one line per resize.
fn bool is_routine_fault(gpu::DebugMessage* message) @private {
    if (!message.has_fault) return false;
    return message.public_fault == gpu::SWAPCHAIN_OUT_OF_DATE
        || message.public_fault == gpu::WAIT_TIMEOUT;
}

fn void print_debug_message(gpu::DebugMessage* message) @private {
    io::eprintf("gpu %s %s", message.severity, zstring_or(message.operation, "unnamed"));
    if (message.invariant) io::eprintf(": %s", message.invariant);
    if (message.rejected_field) io::eprintf(" [%s]", message.rejected_field);
    if (message.has_fault) io::eprintf(" fault %s", message.public_fault);
    if (message.resource.kind != gpu::DebugResourceKind.NONE) {
        io::eprintf(" on %s #%d %s",
            message.resource.kind,
            message.resource.index,
            zstring_or(message.resource.debug_name, "unnamed"));
    }
    if (message.backend_text) io::eprintf(" - %s", message.backend_text);
    io::eprintn();
}

fn void copy_debug_text(char[] destination, ZString source) @private {
    usz length = 0;
    if (source) {
        String view = source.str_view();
        usz limit = destination.len - 1;
        length = view.len < limit ? view.len : limit;
        destination[:length] = view[:length];
    }
    destination[length] = 0;
}

fn ZString zstring_or(ZString value, ZString fallback) @private {
    return value ? value : fallback;
}
