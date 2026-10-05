module c3d::ui;

import c3d;
import c3d::material;

struct UiItemSource @private {
    UiItemFn item_at;
    void*    user;
}

<*
 Expose fields of one struct instance under a prefix.
 Without a name list, the fields tagged "ui" are exposed.
 @param [in] instance : "Outlives its bindings."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
macro void? Ui.@bind_fields(&self, String prefix, $Type, instance, $fields = {}) {
    @expose_fields($Type, $fields; $field, String exposed) {
        bind_part(
            ui:     self,
            prefix: prefix,
            name:   exposed,
            kind:   @value_kind($Typeof((($Type*)null).$eval($field))),
            getter: fn UiValue (void* user, UiScope* scope) => @ui_value((($Type*)user).$eval($field)),
            user:   instance,
            list:   "",
        )!;
    }!;
}

<*
 Expose a slice of structs as a list and fields of each item.
 Without a name list, the fields tagged "ui" are exposed.
 @param [in] items : "Pointer to the slice; read on every update."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
macro void? Ui.@bind_list(&self, String name, String item, $Type, items, $fields = {}) {
    self.bind(
        name:   name,
        kind:   LIST,
        getter: fn UiValue (void* user, UiScope* scope) => { .kind = LIST, .count = (uint)(*($Type[]*)user).len },
        user:   items,
    )!;
    @expose_fields($Type, $fields; $field, String exposed) {
        bind_part(
            ui:     self,
            prefix: item,
            name:   exposed,
            kind:   @value_kind($Typeof((($Type*)null).$eval($field))),
            getter: fn UiValue (void* user, UiScope* scope) {
                $Type[]* slice = user;
                return @ui_value((*slice)[scope.indices[scope.depth - 1]].$eval($field));
            },
            user:   items,
            list:   name,
        )!;
    }!;
}

<*
 Expose a list through callbacks and fields of each item.
 Without a name list, the fields tagged "ui" are exposed.
 @param [in] user : "Passed to count and item_at unchanged."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
macro void? Ui.@bind_items(
    &self,
    String name,
    String item,
    $Type,
    UiGetterFn count,
    UiItemFn item_at,
    void* user,
    String list = "",
    $fields = {},
) {
    self.bind(
        name:   name,
        kind:   LIST,
        getter: count,
        user:   user,
        list:   list,
    )!;
    UiItemSource* source = add_item_source(self, item_at, user)!;
    @expose_fields($Type, $fields; $field, String exposed) {
        bind_part(
            ui:     self,
            prefix: item,
            name:   exposed,
            kind:   @value_kind($Typeof((($Type*)null).$eval($field))),
            getter: fn UiValue (void* user, UiScope* scope) {
                UiItemSource* items = user;
                return @ui_value((($Type*)items.item_at(items.user, scope)).$eval($field));
            },
            user:   source,
            list:   name,
        )!;
    }!;
}

<*
 Register a getter under a dotted name.
 @param list : "Owning list binding of an item binding; empty for a root binding."
 @param [in] user : "Passed to the getter unchanged."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require getter != null
*>
fn void? Ui.bind(
    &self,
    String name,
    UiValueKind kind,
    UiGetterFn getter,
    void* user,
    String list = "",
) {
    return bind_part(
        ui:     self,
        prefix: "",
        name:   name,
        kind:   kind,
        getter: getter,
        user:   user,
        list:   list,
    );
}

<*
 Register an action handler under a dotted name.
 @param [in] user : "Passed to the handler unchanged."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require handler != null
*>
fn void? Ui.on(
    &self,
    String action,
    UiActionFn handler,
    void* user,
) {
    if (!valid_name(action)) return c3d::INVALID_ARGUMENT~;
    for (uint index = 0; index < self.action_count; index++) {
        if (self.actions[index].name == action) return c3d::INVALID_ARGUMENT~;
    }
    if (self.action_count == self.actions.len) return c3d::CAPACITY_EXCEEDED~;
    String name = store_name(self, "", action)!;
    self.actions[self.action_count] = { .name = name, .handler = handler, .user = user };
    self.action_count++;
}

macro void? @expose_fields($Type, $fields; @body($field, String exposed)) @private {
    $if $fields.len == 0:
        $foreach $member : $Type::members:
            $if $member.has_tag("ui"):
                $if $Typeof($member.get_tag("ui"))::typeid == bool::typeid:
                    $if $member.get_tag("ui"):
                        @body($member.name, $member.name);
                    $endif
                $else
                    @body($member.name, $member.get_tag("ui"));
                $endif
            $endif
        $endforeach
    $else
        $foreach $field : $fields:
            @body($field, $field);
        $endforeach
    $endif
}

macro UiValueKind @value_kind($FieldType) @private {
    $switch:
        $case $FieldType::typeid == bool::typeid: return BOOL;
        $case $FieldType::typeid == String::typeid: return TEXT;
        $case $FieldType::typeid == TextureRef::typeid: return IMAGE;
        $case $FieldType::kind == SIGNED_INT || $FieldType::kind == UNSIGNED_INT: return INT;
        $case $FieldType::kind == FLOAT: return FLOAT;
        $case $FieldType::kind == SLICE: return LIST;
        $default: $error "A UI field is bool, an integer, a float, String, TextureRef or a slice.";
    $endswitch
}

macro UiValue @ui_value(value) @private {
    $switch:
        $case $Typeof(value)::typeid == bool::typeid: return { .kind = BOOL, .boolean = value };
        $case $Typeof(value)::typeid == String::typeid: return { .kind = TEXT, .text = value };
        $case $Typeof(value)::typeid == TextureRef::typeid: return { .kind = IMAGE, .image = value };
        $case $Typeof(value)::kind == SIGNED_INT || $Typeof(value)::kind == UNSIGNED_INT:
            return { .kind = INT, .integer = (long)value };
        $case $Typeof(value)::kind == FLOAT: return { .kind = FLOAT, .number = (double)value };
        $default: return { .kind = LIST, .count = (uint)value.len };
    $endswitch
}

fn void? bind_part(
    Ui* ui,
    String prefix,
    String name,
    UiValueKind kind,
    UiGetterFn getter,
    void* user,
    String list,
) @private {
    if (ui.binding_count == ui.bindings.len) return c3d::CAPACITY_EXCEEDED~;
    if (!valid_name(name) || (prefix.len && !valid_name(prefix))) return c3d::INVALID_ARGUMENT~;
    uint owner = UI_NONE;
    uint level;
    if (list.len) {
        owner = find_binding(ui, list);
        if (owner == UI_NONE || ui.bindings[owner].kind != LIST) return c3d::INVALID_ARGUMENT~;
        level = ui.bindings[owner].level + 1;
        if (level > UI_SCOPE_DEPTH) return c3d::INVALID_ARGUMENT~;
    }
    String full = store_name(ui, prefix, name)!;
    if (find_binding(ui, full) != UI_NONE) {
        ui.names_used -= (uint)full.len;
        return c3d::INVALID_ARGUMENT~;
    }
    ui.bindings[ui.binding_count] = {
        .name   = full,
        .kind   = kind,
        .getter = getter,
        .user   = user,
        .list   = owner,
        .level  = level,
    };
    ui.binding_count++;
}

fn UiItemSource*? add_item_source(Ui* ui, UiItemFn item_at, void* user) @private {
    if (ui.item_source_count == ui.item_sources.len) return c3d::CAPACITY_EXCEEDED~;
    UiItemSource* source = &ui.item_sources[ui.item_source_count];
    *source = { .item_at = item_at, .user = user };
    ui.item_source_count++;
    return source;
}

fn uint find_binding(Ui* ui, String name) @private {
    for (uint index = 0; index < ui.binding_count; index++) {
        if (ui.bindings[index].name == name) return index;
    }
    return UI_NONE;
}

fn String? store_name(Ui* ui, String prefix, String name) @private {
    usz length = prefix.len ? prefix.len + 1 + name.len : name.len;
    if (length > ui.names.len - ui.names_used) return c3d::CAPACITY_EXCEEDED~;
    char[] slot = ui.names[ui.names_used : length];
    if (prefix.len) {
        slot[:prefix.len] = prefix[..];
        slot[prefix.len] = '.';
        slot[prefix.len + 1..] = name[..];
    } else {
        slot[..] = name[..];
    }
    ui.names_used += (uint)length;
    return (String)slot;
}

fn bool valid_name(String name) @private {
    if (!name.len || name[0] == '.' || name[^1] == '.') return false;
    char previous;
    foreach (character : name) {
        bool letter = character >= 'a' && character <= 'z';
        bool word = letter || (character >= '0' && character <= '9') || character == '_';
        if (!word && character != '.') return false;
        if (character == '.' && previous == '.') return false;
        previous = character;
    }
    return true;
}
