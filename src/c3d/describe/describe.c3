module c3d::describe;

import c3d;

<*
 Visit a leaf and report an actual edit.
 @param [&inout] visitor : "Consumer-owned state."
 @param [&in] info : "Borrowed for this callback."
 @param [inout] value : "Null for schema; otherwise actual field storage."
 @return "Actual edits, or the consumer's unchanged fault."
*>
alias FieldFn = fn bool? (Visitor* visitor, Info* info, void* value);

<*
 Enter a scope or skip its children and completion.
 @param [&inout] visitor : "Consumer-owned state."
 @param [&in] info : "Borrowed for this callback."
 @param [inout] value : "Null for schema; otherwise actual scope storage."
 @return "Whether to enter, or the consumer's unchanged fault."
*>
alias BeginFn = fn bool? (Visitor* visitor, Info* info, void* value);

<*
 Complete a scope after its children succeed.
 @param [&inout] visitor : "Consumer-owned state."
 @param [&in] info : "Borrowed for this callback."
 @param [inout] value : "Null for schema; otherwise actual scope storage."
 @return "Success or the consumer's unchanged fault."
*>
alias EndFn = fn void? (Visitor* visitor, Info* info, void* value);

<*
 Visit authored fields and aggregate actual edits.
 @param [&inout] visitor : "Consumer-owned state."
 @param [inout] value : "Null for schema; otherwise the described struct."
 @return "Actual edits, or the consumer's unchanged fault."
*>
alias FieldsFn = fn bool? (Visitor* visitor, void* value);

<*
 Rebuild idempotent, value-local derived state.
 Publishes nothing externally and changes no ownership during edits.
 @param [&inout] value : "Successfully visited value."
 @return "Success or the hook's unchanged fault."
*>
alias FinishFn = fn void? (void* value);

<*
 Read an ordinary enum's ordinal from its actual storage.
 @param [&in] value : "Live value of the described enum."
*>
alias EnumReadFn = fn ulong (void* value);

<*
 Store an ordinary enum's ordinal in its actual storage.
 @param [&inout] value : "Live value of the described enum."
 @return? c3d::INVALID_ARGUMENT
*>
alias EnumWriteFn = fn void? (void* value, ulong ordinal);

<*
 Purpose of one synchronous traversal.
*>
enum Mode {
    WRITE,
    READ,
    EDIT,
    SCHEMA,
}

<* Supported leaves and scopes in a description. *>
enum Kind {
    BOOL,
    INT,
    UINT,
    LONG,
    ULONG,
    FLOAT,
    DOUBLE,
    VEC2,
    VEC3,
    VEC4,
    QUAT,
    STRING,
    ENUM,
    ENTITY,
    ASSET,
    STRUCT,
    ARRAY,
    SLICE,
}

<* Optional inclusive limits for numeric editing. *>
struct Range {
    bool enabled;
    double min;
    double max;
}

<*
 Presentation and explicit asset semantics for one field.
*>
struct Metadata {
    String display_name;
    Range range;
    String unit;
    bool has_asset_kind;
    AssetKind asset_kind;
}

<*
 Field metadata with a resolved asset kind.
 Valid only during its callback.
*>
struct Info {
    String name;
    Kind kind;
    usz size;
    usz alignment;
    typeid identity;
    Metadata metadata;
    String[] enum_names;
    EnumReadFn read_enum;
    EnumWriteFn write_enum;
    Kind element_kind;
    usz element_size;
    usz element_alignment;
    usz extent;
}

<*
 Consumer-owned walk state with required leaf, entry and exit callbacks.
 missing_type supplies type-name detail only for MISSING_DESCRIPTION.
*>
struct Visitor {
    Mode mode;
    FieldFn field;
    BeginFn begin;
    EndFn end;
    void* user;
    String missing_type;
}

<*
 Description callbacks and process-local type identity.
 Registry borrows are immutable; caller-owned copies may select callbacks.
*>
struct Descriptor {
    String name;
    typeid identity;
    usz size;
    usz alignment;
    FieldsFn fields;
    FinishFn after;
}
