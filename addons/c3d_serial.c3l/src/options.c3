module c3d::serial;

<* Default reader behavior and JSONC bounds. *>
const ReadOptions READ_OPTIONS_DEFAULT = { .limits = TEXT_LIMITS_DEFAULT };

<* Per-call allocation, text compatibility and retained diagnostics. *>
struct ReadOptions {
    Allocator allocator;
    TextLimits limits;
    SerialDiagnostic* diagnostic;
    bool skip_unknown;
}

<* Optional retained diagnostics for binary output. *>
struct WriteOptions {
    SerialDiagnostic* diagnostic;
}
