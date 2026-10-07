module c3d::test::describe_core;

import std::math;
import c3d;
import c3d::describe;

struct SchemaValue @private {
    int amount;
    String text;
    Quat rotation;
}

struct ConflictValue @private {
    uint value;
}

struct HookConflict @private {
    bool enabled;
}

struct OpaqueChild @private {
    int* payload;
}

struct OpaqueParent @private {
    OpaqueChild child;
}

struct MetadataSequences @private {
    Id[2] fixed @tag("asset", AssetKind.TEXTURE);
    Id[] dynamic @tag("asset", AssetKind.GEOMETRY);
    float[2] weights @tag("display", "Weights") @tag("range", {0.0, 1.0}) @tag("unit", "kg");
    TextureId texture;
}

struct MetadataRecord @private {
    AssetKind expected;
    uint assets;
    uint weights;
}

struct ExplicitAsset @private {
    Id asset @tag("asset", AssetKind.GEOMETRY);
}

fn bool? conflict_fields(Visitor* visitor, void* raw) @private {
    ConflictValue* value = raw;
    return describe::@field(visitor, "value", value.value);
}

fn void? first_hook(void* raw) @private {}

fn void? second_hook(void* raw) @private {}

fn bool? opaque_fields(Visitor* visitor, void* raw) @private {
    OpaqueChild* value = raw;
    return describe::@field(visitor, "payload", *value.payload);
}

fn bool? metadata_begin(Visitor* visitor, Info* info, void* value) @private {
    MetadataRecord* record = visitor.user;
    if (info.name == "fixed") record.expected = TEXTURE;
    if (info.name == "dynamic") record.expected = GEOMETRY;
    if (info.name == "weights") {
        assert(info.metadata.display_name == "Weights");
        assert(info.metadata.range.enabled && info.metadata.range.min == 0 && info.metadata.range.max == 1);
        assert(info.metadata.unit == "kg");
    }
    return true;
}

fn bool? metadata_field(Visitor* visitor, Info* info, void* value) @private {
    MetadataRecord* record = visitor.user;
    assert(info.metadata.display_name == "");
    assert(info.kind == ASSET || info.kind == FLOAT);
    if (info.kind == ASSET) {
        assert(info.metadata.has_asset_kind);
        if (info.identity == TextureId::typeid) {
            assert(info.name == "texture" && info.metadata.asset_kind == TEXTURE);
        } else {
            assert(info.name == "" && info.identity == Id::typeid);
            assert(info.metadata.asset_kind == record.expected);
        }
        record.assets++;
    } else {
        assert(info.name == "");
        assert(info.metadata.range.enabled && info.metadata.range.min == 0 && info.metadata.range.max == 1);
        assert(info.metadata.unit == "kg");
        record.weights++;
    }
    return false;
}

fn void? metadata_end(Visitor* visitor, Info* info, void* value) @private {}

fn void test_registered_schema_never_accesses_a_value() @test {
    describe::register_reflected(SchemaValue)!!;
    Record record;
    Visitor visitor = make_visitor(SCHEMA, &record);
    assert(!describe::walk(SchemaValue, &visitor, null)!!);
    assert(record.fields == 3 && record.begins == 1 && record.ends == 1);
    assert(record.null_values == 5);
}

fn void test_registration_is_idempotent_and_conflicts_preserve_the_first_description() @test {
    describe::register_reflected(ConflictValue)!!;
    Descriptor* original = describe::get(ConflictValue)!!;
    FieldsFn original_fields = original.fields;
    describe::register_reflected(ConflictValue)!!;
    assert(describe::get(ConflictValue)!! == original);
    if (catch excuse = describe::register_type(ConflictValue, &conflict_fields)) {
        assert(excuse == describe::DESCRIPTION_CONFLICT);
    } else {
        assert(false);
    }
    assert(original.fields == original_fields);
    describe::register_reflected(HookConflict, &first_hook)!!;
    if (catch excuse = describe::register_reflected(HookConflict, &second_hook)) {
        assert(excuse == describe::DESCRIPTION_CONFLICT);
    } else {
        assert(false);
    }
    assert((describe::get(HookConflict)!!).after == &first_hook);
}

fn void test_custom_child_prevents_automatic_reflection_of_its_pointer() @test {
    describe::register_reflected(OpaqueParent)!!;
    describe::register_type(OpaqueChild, &opaque_fields)!!;
    int payload = 1;
    OpaqueParent value = { .child = { .payload = &payload } };
    Record record = { .change = true };
    Visitor visitor = make_visitor(EDIT, &record);
    assert(describe::walk(OpaqueParent, &visitor, &value)!!);
    assert(payload == 5 && record.fields == 1);
    record = {};
    visitor = make_visitor(SCHEMA, &record);
    assert(!describe::walk(OpaqueParent, &visitor, null)!!);
    assert(record.fields == 1 && record.null_values == 5);
}

fn void test_sequence_elements_inherit_reference_and_numeric_metadata() @test {
    describe::register_reflected(MetadataSequences)!!;
    Id[3] dynamic;
    MetadataSequences value = { .dynamic = dynamic[..] };
    MetadataRecord record;
    Visitor visitor = {
        .mode = WRITE,
        .field = &metadata_field,
        .begin = &metadata_begin,
        .end = &metadata_end,
        .user = &record,
    };
    describe::walk(MetadataSequences, &visitor, &value)!!;
    assert(record.assets == 6 && record.weights == 2);
    record = {};
    visitor.mode = SCHEMA;
    describe::walk(MetadataSequences, &visitor, null)!!;
    assert(record.assets == 3 && record.weights == 1);
}

fn bool? asset_field(Visitor* visitor, Info* info, void* value) @private {
    assert(info.kind == ASSET);
    assert(info.metadata.has_asset_kind && info.metadata.asset_kind == GEOMETRY);
    assert(info.identity == Id::typeid);
    assert(info.size == Id::size);
    if (visitor.mode == EDIT) {
        *(Id*)value = { .index = 7, .generation = 2 };
        return true;
    }
    return false;
}

fn bool? explicit_fields(Visitor* visitor, void* raw) @private {
    ExplicitAsset* value = raw;
    return describe::@field(
        visitor: visitor,
        name: "asset",
        #field: value.asset,
        metadata: { .has_asset_kind = true, .asset_kind = GEOMETRY },
    );
}

fn void test_explicit_asset_metadata_preserves_actual_untyped_id_storage() @test {
    describe::register_type(ExplicitAsset, &explicit_fields)!!;
    ExplicitAsset value;
    Record record;
    Visitor visitor = make_visitor(EDIT, &record);
    visitor.field = &asset_field;
    assert(describe::walk(ExplicitAsset, &visitor, &value)!!);
    assert(value.asset.index == 7 && value.asset.generation == 2);
    visitor.mode = SCHEMA;
    assert(!describe::walk(ExplicitAsset, &visitor, null)!!);
}
