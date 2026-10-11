module c3d::test::describe_light;

import c3d::describe;
import c3d::ecs;
import c3d::light;

struct ShadowDescriptionFields @private {
    uint colored_fields;
    uint bool_fields;
    bool edit;
}

fn bool? shadow_description_field(Visitor* visitor, Info* info, void* value) @private {
    ShadowDescriptionFields* fields = visitor.user;
    if (info.kind == BOOL) fields.bool_fields++;
    if (info.name != "colored_transmission") return false;

    assert(info.kind == BOOL && info.size == bool::size);
    fields.colored_fields++;
    if (visitor.mode == SCHEMA) {
        assert(value == null);
        return false;
    }
    if (fields.edit) {
        *(bool*)value = true;
        return true;
    }
    assert(!*(bool*)value);
    return false;
}

fn bool? shadow_description_begin(Visitor* visitor, Info* info, void* value) @private {
    return true;
}

fn void? shadow_description_end(Visitor* visitor, Info* info, void* value) @private {}

fn void test_light_description_exposes_one_colored_transmission_field_and_edits_authoring() @test {
    describe::register_core_components()!!;
    uint slot = ecs::assigned_slot(Light)!!;
    Descriptor* descriptor = describe::get(Light)!!;
    describe::register_core_components()!!;
    assert(ecs::assigned_slot(Light)!! == slot && describe::get(Light)!! == descriptor);
    Light light = light::directional({ 1, 1, 1 }, 1);
    assert(!light.shadow.colored_transmission && !light::SHADOW_SETTINGS_DEFAULT.colored_transmission);
    ShadowDescriptionFields fields;
    Visitor visitor = {
        .mode = SCHEMA,
        .field = &shadow_description_field,
        .begin = &shadow_description_begin,
        .end = &shadow_description_end,
        .user = &fields,
    };
    assert(!describe::walk(Light, &visitor, null)!!);
    assert(fields.colored_fields == 1 && fields.bool_fields == 3);
    fields = {};
    visitor.mode = WRITE;
    assert(!describe::walk(Light, &visitor, &light)!!);
    assert(fields.colored_fields == 1 && !light.shadow.colored_transmission);
    fields = { .edit = true };
    visitor.mode = EDIT;
    assert(describe::walk(Light, &visitor, &light)!!);
    assert(fields.colored_fields == 1 && light.shadow.colored_transmission);
}
