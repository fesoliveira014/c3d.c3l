module c3d::gui;

import c3d::describe;
import imgui;
import std::math;

const float DESCRIPTION_DRAG_SPEED @local = 0.1f; // Fine-grained edits for unit-scaled fields.

struct DescriptionInspector @private {
    usz open_scopes;
}

fn bool? inspect_description(describe::Descriptor* descriptor, void* value) @private {
    DescriptionInspector state;
    defer {
        while (state.open_scopes) {
            imgui::tree_pop();
            imgui::pop_id();
            state.open_scopes--;
        }
    }
    describe::Visitor visitor = {
        .mode = EDIT,
        .field = &description_field,
        .begin = &description_begin,
        .end = &description_end,
        .user = &state,
    };
    return describe::walk_descriptor(descriptor, &visitor, value);
}

fn bool? description_begin(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    DescriptionInspector* state = (DescriptionInspector*)visitor.user;
    imgui::push_id_ptr(value);
    String label = description_label(info);
    imgui::TreeNodeFlags flags = { .default_open = true, .framed = state.open_scopes == 0 };
    bool open = imgui::tree_node_ex_str(
        "##scope",
        flags,
        "%.*s",
        (int)label.len,
        label.ptr,
    );
    if (!open) {
        imgui::pop_id();
        return false;
    }
    state.open_scopes++;
    return true;
}

fn void? description_end(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    DescriptionInspector* state = (DescriptionInspector*)visitor.user;
    imgui::tree_pop();
    imgui::pop_id();
    state.open_scopes--;
}

fn bool? description_field(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    imgui::push_id_ptr(value);
    defer imgui::pop_id();

    bool changed;
    switch (info.kind) {
        case BOOL:
            changed = imgui::checkbox("##value", (bool*)value);
        case ICHAR:
            changed = @description_numeric(
                $Type: ichar,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_S8,
            );
        case CHAR:
            changed = @description_numeric(
                $Type: char,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_U8,
            );
        case SHORT:
            changed = @description_numeric(
                $Type: short,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_S16,
            );
        case USHORT:
            changed = @description_numeric(
                $Type: ushort,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_U16,
            );
        case INT:
            changed = @description_numeric(
                $Type: int,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_S32,
            );
        case UINT:
            changed = @description_numeric(
                $Type: uint,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_U32,
            );
        case LONG:
            changed = @description_numeric(
                $Type: long,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_S64,
            );
        case ULONG:
            changed = @description_numeric(
                $Type: ulong,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_U64,
            );
        case FLOAT:
            changed = @description_numeric(
                $Type: float,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_FLOAT,
            );
        case DOUBLE:
            changed = @description_numeric(
                $Type: double,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_DOUBLE,
            );
        case VEC2:
            changed = @description_numeric(
                $Type: float,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_FLOAT,
                components: 2,
            );
        case VEC3:
            changed = @description_numeric(
                $Type: float,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_FLOAT,
                components: 3,
            );
        case VEC4:
            changed = @description_numeric(
                $Type: float,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_FLOAT,
                components: 4,
            );
        case UVEC3:
            changed = @description_numeric(
                $Type: uint,
                info: info,
                value: value,
                data_type: imgui::DATA_TYPE_U32,
                components: 3,
            );
        case MAT4:
            imgui::begin_group();
            for (int column = 0; column < 4; column++) {
                imgui::push_id_int(column);
                changed = @description_numeric(
                    $Type: float,
                    info: info,
                    value: (float*)value + column * 4,
                    data_type: imgui::DATA_TYPE_FLOAT,
                    components: 4,
                ) || changed;
                imgui::pop_id();
            }
            imgui::end_group();
        case QUAT:
            changed = quat_widget("##value", (Quat*)value);
        case ENUM:
            changed = description_enum(info, value)!;
        case STRING:
            description_text(*(String*)value);
        case ENTITY:
            c3d::Id id = *(c3d::Id*)value;
            imgui::text("Entity %u:%u", id.index, id.generation);
        case ASSET:
            c3d::Id id = *(c3d::Id*)value;
            imgui::text("%s %u:%u", @enum_name(AssetKind, info.metadata.asset_kind), id.index, id.generation);
        case STRUCT:
        case ARRAY:
        case SLICE:
            unreachable();
    }
    imgui::same_line();
    description_text(description_label(info));
    if (info.metadata.unit.len) {
        imgui::same_line();
        description_text(info.metadata.unit);
    }
    return changed;
}

macro bool @description_numeric(
    $Type,
    describe::Info* info,
    void* value,
    imgui::DataType data_type,
    int components = 1,
) @local {
    $Type minimum;
    $Type maximum;
    void* minimum_pointer;
    void* maximum_pointer;
    bool bounded;
    $if $Type::typeid == ichar::typeid || $Type::typeid == char::typeid
        || $Type::typeid == short::typeid || $Type::typeid == ushort::typeid
        || $Type::typeid == uint::typeid:
        minimum = $Type::min;
        maximum = $Type::max;
        minimum_pointer = &minimum;
        maximum_pointer = &maximum;
        bounded = true;
    $endif
    if (info.metadata.range.enabled) {
        minimum = ($Type)info.metadata.range.min;
        maximum = ($Type)info.metadata.range.max;
        minimum_pointer = &minimum;
        maximum_pointer = &maximum;
        bounded = true;
    }
    bool changed = imgui::drag_scalar_n_ex(
        label: "##value",
        data_type: data_type,
        p_data: value,
        components: components,
        v_speed: DESCRIPTION_DRAG_SPEED,
        p_min: minimum_pointer,
        p_max: maximum_pointer,
        format: null,
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    );
    if (changed && bounded) {
        $Type* elements = ($Type*)value;
        for (int index = 0; index < components; index++) {
            elements[index] = math::clamp(elements[index], minimum, maximum);
        }
    }
    return changed;
}

fn bool? description_enum(describe::Info* info, void* value) @private {
    ulong ordinal = info.read_enum(value);
    bool changed;
    imgui::set_next_item_width(imgui::get_frame_height());
    if (imgui::begin_combo("##value", "", 0)) {
        defer imgui::end_combo();
        foreach (index, name : info.enum_names) {
            imgui::push_id_int((int)index);
            defer imgui::pop_id();
            if (description_choice(name, ordinal == (ulong)index) && ordinal != (ulong)index) {
                info.write_enum(value, (ulong)index)!;
                ordinal = (ulong)index;
                changed = true;
            }
        }
    }
    imgui::same_line();
    description_text(info.enum_names[(usz)ordinal]);
    return changed;
}

fn bool description_choice(String name, bool selected) @local {
    imgui::Vec2 position = imgui::get_cursor_screen_pos();
    imgui::Vec2 size = imgui::calc_text_size_ex(
        text: (ZString)name.ptr,
        text_end: (ZString)(name.ptr + name.len),
        hide_text_after_double_hash: false,
        wrap_width: -1,
    );
    bool chosen = imgui::selectable_ex(
        label: "##choice",
        selected: selected,
        flags: {},
        size: size,
    );
    if (selected) imgui::set_item_default_focus();
    imgui::Vec2 next = imgui::get_cursor_screen_pos();
    imgui::set_cursor_screen_pos(position);
    description_text(name);
    imgui::set_cursor_screen_pos(next);
    imgui::dummy({ 0, 0 });
    return chosen;
}

fn String description_label(describe::Info* info) @local {
    if (info.metadata.display_name.len) return info.metadata.display_name;
    return info.name.len ? info.name : "Element";
}

fn void description_text(String text) @private {
    if (!text.len) {
        imgui::text_unformatted("");
        return;
    }
    imgui::text_unformatted_ex((ZString)text.ptr, (ZString)(text.ptr + text.len));
}

fn void description_fault_text(fault excuse) @private {
    imgui::text_unformatted("Edit failed:");
    imgui::same_line();
    description_text(excuse.short_name());
}
