module c3d::describe;

import c3d::describe::typed @public;
import c3d::describe::value @public;

<*
 Visit one registered value and report actual edits.

 @param [&inout] visitor : "Setup complete; borrowed for this synchronous walk."
 @param [inout] value : "Fresh for reads; unused for schema."
 @return "Actual edits; propagates consumer and hook faults unchanged."
 @return? MISSING_DESCRIPTION
 @require visitor.mode == SCHEMA || value != null
 @require visitor.field != null, visitor.begin != null, visitor.end != null
*>
macro bool? walk($Type, Visitor* visitor, void* value) {
    Descriptor* descriptor = &typed::entry{$Type}.descriptor;
    visitor.missing_type = "";
    if (!descriptor.fields) {
        visitor.missing_type = $Type::qname;
        return MISSING_DESCRIPTION~;
    }
    return walk_descriptor(descriptor, visitor, value);
}

<*
 Visit a descriptor's value and report actual edits.

 @param [&in] descriptor : "Borrow or copy matching the value's type and layout."
 @param [&inout] visitor : "Setup complete; borrowed for this synchronous walk."
 @param [inout] value : "Fresh for reads; unused for schema."
 @param name : "Root scope name; empty uses the type name."
 @return "Actual edits; propagates consumer and hook faults unchanged."
 @return? MISSING_DESCRIPTION
 @require descriptor.fields != null
 @require visitor.mode == SCHEMA || value != null
 @require visitor.field != null, visitor.begin != null, visitor.end != null
*>
fn bool? walk_descriptor(
    Descriptor* descriptor,
    Visitor* visitor,
    void* value,
    String name = "",
) {
    visitor.missing_type = "";
    Info info = {
        .name = name.len ? name : descriptor.name,
        .kind = STRUCT,
        .size = descriptor.size,
        .alignment = descriptor.alignment,
        .identity = descriptor.identity,
    };
    return visit_struct(descriptor, visitor, &info, visitor.mode == SCHEMA ? null : value);
}

<*
 Visit one authored field without accessing values in schema mode.
 Requires an explicit asset kind for otherwise untyped Id storage.
 @param [&inout] visitor : "Setup complete; borrowed for this synchronous walk."
 @return "Actual edits; propagates consumer and hook faults unchanged."
 @return? MISSING_DESCRIPTION
 @require visitor.field != null, visitor.begin != null, visitor.end != null
 @require @metadata_valid($Typeof(#field), metadata)
*>
macro bool? @field(
    Visitor* visitor,
    String name,
    #field,
    Metadata metadata = {},
) {
    var $Type = $Typeof(#field);
    void* pointer = null;
    if (visitor.mode != SCHEMA) pointer = &#field;
    return value::visit{$Type}(
        visitor: visitor,
        name: name,
        raw: pointer,
        metadata: metadata,
    );
}

fn bool? visit_struct(
    Descriptor* descriptor,
    Visitor* visitor,
    Info* info,
    void* value,
) @private {
    if (!visitor.begin(visitor, info, value)!) return false;
    bool changed = descriptor.fields(visitor, value)!;
    visitor.end(visitor, info, value)!;
    if (descriptor.after && (visitor.mode == READ || (visitor.mode == EDIT && changed))) {
        descriptor.after(value)!;
    }
    return visitor.mode == EDIT && changed;
}
