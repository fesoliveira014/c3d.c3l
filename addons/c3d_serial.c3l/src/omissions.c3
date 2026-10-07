module c3d::serial;

import c3d;

<* One binary-only component excluded from a text export. *>
struct OmittedComponent {
    String node_path;
    String type_name;
}

<* Owned list of every explicit text-export omission. *>
struct OmissionReport {
    Allocator allocator;
    OmittedComponent[] components;
}

<* Default text export policy and bounds. *>
const TextWriteOptions TEXT_WRITE_OPTIONS_DEFAULT = { .limits = TEXT_LIMITS_DEFAULT };

<* Per-call text output, diagnostics and explicit binary-only omissions. *>
struct TextWriteOptions {
    TextLimits limits;
    SerialDiagnostic* diagnostic;
    bool omit_binary_only;
    OmissionReport* omissions;
}

<*
 Create an empty omission report without allocating storage.
 @require allocator.ptr != null
*>
fn OmissionReport create_omission_report(Allocator allocator) {
    return { .allocator = allocator };
}

<*
 Release every omission and clear its report.
 @param [&inout] report : "Owns its strings and entry array."
*>
fn void destroy_omission_report(OmissionReport* report) {
    clear_omission_report(report);
    *report = {};
}

fn void clear_omission_report(OmissionReport* report) @private {
    foreach (entry : report.components) {
        alloc::free(report.allocator, entry.node_path.ptr);
        alloc::free(report.allocator, entry.type_name.ptr);
    }
    alloc::free(report.allocator, report.components.ptr);
    report.components = {};
}
