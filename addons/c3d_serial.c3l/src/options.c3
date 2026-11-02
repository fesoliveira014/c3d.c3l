module c3d::serial;

<* Field-level application of a JSONC object onto a described value. *>
enum ReadMode : char {
    <* The type's defaults first, then the keys present. *>
    RESET,
    <* The keys present only; fields not named keep their contents. *>
    OVERLAY,
}

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
