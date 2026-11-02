module c3d::serial;

import c3d;
import c3d::asset;

<*
 Read one JSONC object into a described value.
 Leaves the value partly written on a fault.
 @param [&in] type : "Registered with its defaults."
 @param [&inout] value : "Of the type's layout; OVERLAY keeps the fields the text omits."
 @param [&inout] storage : "Owns every decoded string and slice; grows until released."
 @param [in] assets : "Resolves asset keys; null faults a named asset as UNSUPPORTED."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? read_value_text(
    DescribedType* type,
    String text,
    void* value,
    SerialStorage* storage,
    ReadMode mode = RESET,
    ReadOptions options = READ_OPTIONS_DEFAULT,
    AssetStore* assets = null,
) {
    Allocator allocator = options.allocator.ptr ? options.allocator : storage.owned.allocator;
    SerialDiagnostic local = create_serial_diagnostic(allocator);
    defer destroy_serial_diagnostic(&local);
    if (!options.diagnostic) options.diagnostic = &local;

    TextDocument document = parse_text(
        allocator: allocator,
        source: text,
        limits: options.limits,
        diagnostic: options.diagnostic,
    )!;
    defer destroy_text_document(&document);

    return read_value_at(
        type: type,
        document: &document,
        token: 0,
        value: value,
        storage: storage,
        mode: mode,
        options: options,
        assets: assets,
    );
}

<*
 Read the JSONC object at one token of a parsed document into a described value.
 Leaves the value partly written on a fault.
 @param [&in] type : "Registered with its defaults."
 @param [&in] document : "Parsed by the caller."
 @param [&inout] value : "Of the type's layout; OVERLAY keeps the fields the text omits."
 @param [&inout] storage : "Owns every decoded string and slice; grows until released."
 @param options : "The limits are unused; the document is parsed."
 @param [in] assets : "Resolves asset keys; null faults a named asset as UNSUPPORTED."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require token < document.values.len
*>
fn void? read_value_at(
    DescribedType* type,
    TextDocument* document,
    uint token,
    void* value,
    SerialStorage* storage,
    ReadMode mode = RESET,
    ReadOptions options = READ_OPTIONS_DEFAULT,
    AssetStore* assets = null,
) {
    Allocator allocator = options.allocator.ptr ? options.allocator : storage.owned.allocator;
    SerialDiagnostic local = create_serial_diagnostic(allocator);
    defer destroy_serial_diagnostic(&local);
    SerialDiagnostic* diagnostic = options.diagnostic ? options.diagnostic : &local;

    ReadContext context = { .assets = assets, .allocator = allocator, .diagnostic = diagnostic };
    if (catch excuse = read_described_json(
        type: type,
        document: document,
        token: token,
        context: &context,
        owned: &storage.owned,
        diagnostic: diagnostic,
        skip_unknown: options.skip_unknown,
        value: value,
        mode: mode,
    )) {
        if (!diagnostic.cause) diagnostic.cause = excuse;
        return excuse~;
    }
}

<*
 JSONC object of every non-transient field of a described value.
 @param [&in] type : "Registered with its defaults."
 @param [&in] value : "Of the type's layout."
 @param [in] assets : "Resolves asset keys; null faults a named asset as UNSUPPORTED."
 @param options : "Omission fields are ignored."
 @return "Owned by allocator."
 @return? c3d::UNSUPPORTED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn String? write_value_text(
    Allocator allocator,
    DescribedType* type,
    void* value,
    TextWriteOptions options = TEXT_WRITE_OPTIONS_DEFAULT,
    AssetStore* assets = null,
) {
    if (options.diagnostic) clear_serial_diagnostic(options.diagnostic);

    String? text = write_value_json(
        allocator: allocator,
        type: type,
        value: value,
        options: options,
        assets: assets,
    );
    if (catch excuse = text) {
        if (options.diagnostic && !options.diagnostic.cause) options.diagnostic.cause = excuse;
        return excuse~;
    }
    return text;
}

fn String? write_value_json(
    Allocator allocator,
    DescribedType* type,
    void* value,
    TextWriteOptions options,
    AssetStore* assets,
) @local {
    if (!text_limits_valid(options.limits)) return c3d::INVALID_ARGUMENT~;

    WriteState state;
    state.keys.tinit();
    state.key_index.tinit();
    WriteContext context = { .assets = assets, .state = &state, .diagnostic = options.diagnostic };

    JsonOutput measured = { .writer = measuring_writer(), .limits = options.limits };
    emit_value_json(
        context: &context,
        output: &measured,
        type: type,
        value: value,
    )!;

    char[] bytes = alloc::new_array_try(allocator, char, (sz)measured.writer.written()) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, bytes.ptr);

    JsonOutput output = { .writer = writer_over(bytes), .limits = options.limits };
    state.filling = true;
    emit_value_json(
        context: &context,
        output: &output,
        type: type,
        value: value,
    )!;

    return (String)bytes;
}

fn void? emit_value_json(
    WriteContext* context,
    JsonOutput* output,
    DescribedType* type,
    void* value,
) @local {
    output.begin("", true)!;
    write_described_json(
        type: type,
        output: output,
        context: context,
        value: value,
        pointer_diagnostic: context.diagnostic,
    )!;
}
