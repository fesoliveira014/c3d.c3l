module c3d::test::describe_core;

import std::core::runtime;
import std::math;
import c3d;
import c3d::describe;
import c3d::ecs;

faultdef
    FIELD_REJECTED,
    HOOK_REJECTED;

struct MissingChild @private {
    float value;
}

struct MissingParent @private {
    MissingChild child;
}

struct EarlierChild @private {
    double value;
}

struct LaterParent @private {
    EarlierChild child;
}

struct ComponentFirst @private {
    int value;
}

struct StorageFirst @private {
    int value;
}

struct OrdinaryValue @private {
    int value;
}

struct ChildValue @private {
    int value;
    int derived @tag("transient", true);
}

struct ParentValue @private {
    ChildValue first;
    ChildValue second;
    int value;
    int derived @tag("transient", true);
}

struct SequenceValue @private {
    int[2] fixed;
    int[] items;
}

struct Record @private {
    uint fields;
    uint begins;
    uint ends;
    uint null_values;
    bool change;
    bool reject_field;
    bool fail_hook;
    bool skip_first;
    bool skip_root;
    int[3] storage;
    uint next;
}

uint[8] hook_order @private;
uint hook_count @private;

fn bool? record_field(Visitor* visitor, Info* info, void* value) @private {
    Record* record = visitor.user;
    record.fields++;
    if (!value) record.null_values++;
    if (visitor.mode == SCHEMA) return false;
    if (record.reject_field && info.kind == INT) return FIELD_REJECTED~;
    if (visitor.mode == READ && info.kind == INT) *(int*)value = record.fail_hook ? -9 : 0;
    if (visitor.mode == EDIT && record.change && info.kind == INT && *(int*)value == 1) {
        *(int*)value = 5;
        return true;
    }
    return false;
}

fn bool? record_begin(Visitor* visitor, Info* info, void* value) @private {
    Record* record = visitor.user;
    record.begins++;
    if (!value) record.null_values++;
    if (record.skip_root) return false;
    return !record.skip_first || info.name != "first";
}

fn void? record_end(Visitor* visitor, Info* info, void* value) @private {
    Record* record = visitor.user;
    record.ends++;
    if (!value) record.null_values++;
}

fn Visitor make_visitor(Mode mode, Record* record) @private {
    return {
        .mode = mode,
        .field = &record_field,
        .begin = &record_begin,
        .end = &record_end,
        .user = record,
    };
}

fn void? finish_child(void* raw) @private {
    ChildValue* value = raw;
    if (value.value == -9) return HOOK_REJECTED~;
    value.derived = value.value * 2;
    hook_order[hook_count++] = (uint)(10 + value.value);
}

fn void? finish_parent(void* raw) @private {
    ParentValue* value = raw;
    value.derived = value.first.derived + value.second.derived + value.value;
    hook_order[hook_count++] = 99;
}

fn bool? read_sequence_field(Visitor* visitor, Info* info, void* value) @private {
    Record* record = visitor.user;
    record.fields++;
    *(int*)value = (int)++record.next;
    return false;
}

fn bool? read_sequence_begin(Visitor* visitor, Info* info, void* value) @private {
    Record* record = visitor.user;
    record.begins++;
    if (info.kind == SLICE) {
        *(SliceRaw*)value = { .ptr = &record.storage[0], .len = record.storage.len };
    }
    return true;
}

fn bool? empty_fields(Visitor* visitor, void* raw) @private {
    return false;
}

fn bool? missing_fields(Visitor* visitor, void* raw) @private {
    MissingParent* value = raw;
    return describe::@field(visitor, "child", value.child);
}

fn bool? later_fields(Visitor* visitor, void* raw) @private {
    LaterParent* value = raw;
    return describe::@field(visitor, "child", value.child);
}

fn bool? child_fields(Visitor* visitor, void* raw) @private {
    ChildValue* value = raw;
    return describe::@field(visitor, "value", value.value);
}

fn bool? parent_fields(Visitor* visitor, void* raw) @private {
    ParentValue* value = raw;
    bool changed = describe::@field(visitor, "first", value.first)!;
    changed = describe::@field(visitor, "second", value.second)! || changed;
    return describe::@field(visitor, "value", value.value)! || changed;
}

fn bool? sequence_fields(Visitor* visitor, void* raw) @private {
    SequenceValue* value = raw;
    bool changed = describe::@field(visitor, "fixed", value.fixed)!;
    return describe::@field(visitor, "items", value.items)! || changed;
}

fn void test_missing_child_reports_qualified_type_then_validates_after_registration() @test {
    describe::register_type(MissingParent, &missing_fields)!!;
    String missing;
    if (catch excuse = describe::validate_descriptions(&missing)) {
        assert(excuse == describe::MISSING_DESCRIPTION);
        assert(missing == MissingChild::qname);
    } else {
        assert(false);
    }
    MissingParent value;
    Record record;
    Visitor visitor = make_visitor(WRITE, &record);
    if (catch excuse = describe::walk(MissingParent, &visitor, &value)) {
        assert(excuse == describe::MISSING_DESCRIPTION);
        assert(visitor.missing_type == MissingChild::qname);
        assert(record.ends == 0);
    } else {
        assert(false);
    }
    describe::register_type(MissingChild, &empty_fields)!!;
    describe::validate_descriptions(&missing)!!;
    assert(missing == "");
    describe::register_type(EarlierChild, &empty_fields)!!;
    describe::register_type(LaterParent, &later_fields)!!;
    describe::validate_descriptions(&missing)!!;
    assert(missing == "");
}

fn void test_component_description_and_world_storage_accept_either_order() @test {
    World world = ecs::create_world(mem, 4);
    defer ecs::destroy_world(&world);

    describe::register_component(ComponentFirst, &empty_fields)!!;
    assert(!world.is_registered(ComponentFirst));
    world.register(ComponentFirst)!!;
    assert(world.is_registered(ComponentFirst));
    assert(describe::component(ecs::slot_of(ComponentFirst)!!)!! == describe::get(ComponentFirst)!!);

    world.register(StorageFirst)!!;
    uint slot = ecs::slot_of(StorageFirst)!!;
    if (catch excuse = describe::component(slot)) {
        assert(excuse == describe::MISSING_DESCRIPTION);
    } else {
        assert(false);
    }
    describe::register_component(StorageFirst, &empty_fields)!!;
    assert(describe::component(slot)!! == describe::get(StorageFirst)!!);

    describe::register_type(OrdinaryValue, &empty_fields)!!;
    assert(!world.is_registered(OrdinaryValue));
}

fn void test_reconstruction_runs_after_reads_and_changed_children_only() @test {
    describe::register_type(ChildValue, &child_fields, &finish_child)!!;
    describe::register_type(ParentValue, &parent_fields, &finish_parent)!!;
    ParentValue value = { .first = { .value = 1 }, .second = { .value = 2 }, .value = 3 };
    Record record;
    Visitor visitor = make_visitor(WRITE, &record);
    hook_count = 0;
    assert(!describe::walk(ParentValue, &visitor, &value)!!);
    assert(hook_count == 0);
    visitor.mode = SCHEMA;
    assert(!describe::walk(ParentValue, &visitor, null)!!);
    assert(hook_count == 0);
    visitor.mode = EDIT;
    assert(!describe::walk(ParentValue, &visitor, &value)!!);
    assert(hook_count == 0);

    record.change = true;
    assert(describe::walk(ParentValue, &visitor, &value)!!);
    assert(hook_count == 2 && hook_order[0] == 15 && hook_order[1] == 99);
    assert(value.first.derived == 10 && value.second.derived == 0 && value.derived == 13);

    hook_count = 0;
    value = {};
    visitor.mode = READ;
    assert(!describe::walk(ParentValue, &visitor, &value)!!);
    assert(hook_count == 3 && hook_order[0] == 10 && hook_order[1] == 10 && hook_order[2] == 99);
    assert(value.derived == 0);
}

fn void test_skips_and_faults_suppress_unfinished_exits_and_hooks() @test {
    describe::register_type(ChildValue, &child_fields, &finish_child)!!;
    describe::register_type(ParentValue, &parent_fields, &finish_parent)!!;
    ParentValue value;
    Record record = { .skip_first = true };
    Visitor visitor = make_visitor(READ, &record);
    hook_count = 0;
    describe::walk(ParentValue, &visitor, &value)!!;
    assert(record.begins == 3 && record.ends == 2 && record.fields == 2);
    assert(hook_count == 2 && hook_order[0] == 10 && hook_order[1] == 99);

    hook_count = 0;
    value = {};
    record = { .reject_field = true };
    if (catch excuse = describe::walk(ParentValue, &visitor, &value)) {
        assert(excuse == FIELD_REJECTED);
        assert(record.fields == 1 && record.ends == 0 && hook_count == 0);
    } else {
        assert(false);
    }

    record = { .fail_hook = true };
    value = {};
    if (catch excuse = describe::walk(ParentValue, &visitor, &value)) {
        assert(excuse == HOOK_REJECTED);
        assert(record.fields == 1 && record.ends == 1 && hook_count == 0);
    } else {
        assert(false);
    }

    value = {};
    record = { .skip_root = true };
    describe::walk(ParentValue, &visitor, &value)!!;
    assert(record.begins == 1 && record.fields == 0 && record.ends == 0 && hook_count == 0);
}

fn void test_slice_storage_is_installed_before_visiting_and_schema_visits_each_shape_once() @test {
    describe::register_type(SequenceValue, &sequence_fields)!!;
    SequenceValue value;
    Record record;
    Visitor visitor = {
        .mode = READ,
        .field = &read_sequence_field,
        .begin = &read_sequence_begin,
        .end = &record_end,
        .user = &record,
    };
    assert(!describe::walk(SequenceValue, &visitor, &value)!!);
    assert(value.fixed[0] == 1 && value.fixed[1] == 2);
    assert(value.items.len == 3 && value.items[0] == 3 && value.items[2] == 5);
    assert(record.fields == 5 && record.begins == 3 && record.ends == 3);

    record = {};
    visitor = make_visitor(SCHEMA, &record);
    assert(!describe::walk(SequenceValue, &visitor, null)!!);
    assert(record.fields == 2 && record.begins == 3 && record.ends == 3);
    assert(record.null_values == 8);
}
