module c3d::describe;

import c3d::ecs;
import c3d::describe::typed @public;

struct Entry @private {
    Descriptor descriptor;
    Entry* next;
}

Entry* registered_first @private;
Entry* registered_last @private;
Descriptor*[ecs::MAX_COMPONENT_TYPES] component_descriptions @private;

<*
 Register authored fields and an optional reconstruction hook.
 Single-threaded setup must finish before traversal.
 @param fields : "Receives null value storage during schema."
 @param after : "Optional reconstruction callback for this type."
 @return? DESCRIPTION_CONFLICT
 @require fields != null
*>
macro void? register_type($Type, FieldsFn fields, FinishFn after = null) {
    $assert $Type::kind == STRUCT : "Descriptions register struct types.";
    Entry* entry = &typed::entry{$Type};
    check_registration(entry, fields, after)!;
    publish(entry, fields, after);
}

<*
 Register authored fields and bind their process-wide component slot.
 Allocates no world store; registration is single-threaded before traversal.
 @param fields : "Receives null value storage during schema."
 @param after : "Optional reconstruction callback for this type."
 @return? DESCRIPTION_CONFLICT, c3d::CAPACITY_EXCEEDED
 @require fields != null
*>
macro void? register_component($Type, FieldsFn fields, FinishFn after = null) {
    $assert $Type::kind == STRUCT : "Descriptions register struct types.";
    Entry* entry = &typed::entry{$Type};
    check_registration(entry, fields, after)!;
    uint slot = ecs::slot_of($Type)!;
    publish(entry, fields, after);
    component_descriptions[slot] = &entry.descriptor;
}

<*
 Borrow an immutable, process-lifetime description.
 @return? MISSING_DESCRIPTION
*>
macro Descriptor*? get($Type) {
    Descriptor* descriptor = &typed::entry{$Type}.descriptor;
    if (!descriptor.fields) return MISSING_DESCRIPTION~;
    return descriptor;
}

<*
 Borrow a component slot's immutable description.
 @return? MISSING_DESCRIPTION
 @require slot < ecs::MAX_COMPONENT_TYPES
*>
fn Descriptor*? component(uint slot) {
    Descriptor* descriptor = component_descriptions[slot];
    if (!descriptor) return MISSING_DESCRIPTION~;
    return descriptor;
}

<*
 Check registered descriptions for missing nested types.
 @param [&out] missing_type : "Type-name detail when MISSING_DESCRIPTION is returned."
 @return "Success or an unchanged description or consumer fault."
 @return? MISSING_DESCRIPTION
*>
fn void? validate_descriptions(String* missing_type) {
    *missing_type = "";
    Visitor visitor = {
        .mode = SCHEMA,
        .field = &schema_field,
        .begin = &schema_begin,
        .end = &schema_end,
    };
    for (Entry* entry = registered_first; entry; entry = entry.next) {
        if (catch excuse = walk_descriptor(&entry.descriptor, &visitor, null)) {
            *missing_type = visitor.missing_type;
            return excuse~;
        }
    }
}

fn void? check_registration(Entry* entry, FieldsFn fields, FinishFn after) @private {
    if (entry.descriptor.fields
        && (entry.descriptor.fields != fields || entry.descriptor.after != after)) {
        return DESCRIPTION_CONFLICT~;
    }
}

fn void publish(Entry* entry, FieldsFn fields, FinishFn after) @private {
    if (entry.descriptor.fields) return;
    entry.descriptor.fields = fields;
    entry.descriptor.after = after;
    if (registered_last) {
        registered_last.next = entry;
    } else {
        registered_first = entry;
    }
    registered_last = entry;
}

fn bool? schema_field(Visitor* visitor, Info* info, void* value) @private {
    return false;
}

fn bool? schema_begin(Visitor* visitor, Info* info, void* value) @private {
    return true;
}

fn void? schema_end(Visitor* visitor, Info* info, void* value) @private {}

module c3d::describe::typed <Type> @private;

import c3d::describe @public;

Entry entry = {
    .descriptor = {
        .name = Type::qname,
        .identity = Type::typeid,
        .size = Type::size,
        .alignment = Type::alignment,
    },
};
