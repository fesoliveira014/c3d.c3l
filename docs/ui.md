# Game UI

The `c3d::ui` module of the `c3d_ui` add-on draws game interfaces from data. An application describes a screen in a JSONC document: an element tree, styles with single inheritance, data bindings and named actions. Code registers every name a document may read or trigger. Each frame the add-on lays the visible documents out with [Clay](https://github.com/nicbarker/clay), routes pointer and text input against the previous frame's layout, and appends rectangles and glyph runs to an [`OverlayList`](overlay.md). Layout, skins and styles are data that mods can edit without code; behavior stays in code.

Use it for HUDs, menus, inventories and dialogs. ImGui stays the tool for debug panels and draws on top ([GUI overlay](gui.md)).

The module imports the standard library, core (`c3d`, including `c3d::render` for the overlay list and `c3d::platform` for input) and `clay`. It never imports `gpu`, `sdl`, `imgui` or another add-on, and creates no GPU object. Core never imports it and has no flag for it. Select `c3d_ui` and `clay` in `project.json` as [release.md](release.md) lists. The [reference](ui_reference.md) holds the document format, style properties, capacities and faults.

## Quick start

Add the fonts, register what documents may use, load styles and documents, then run the frame loop.

```c3
struct Hud {
    int gold @tag("ui", true); // exposed as hud.gold
}

fn void start_game(void* user, UiScope* scope, UiEvent* event) {
    ((Game*)user).starting = true;
}

assets.add_font(font_bytes, asset::default_font_desc(), "ui/regular")!;

Ui ui = ui::create_ui(mem, &assets, ui::default_ui_desc())!;
defer ui::destroy_ui(&ui);

ui.@bind_fields("hud", Hud, &game.hud)!;
ui.on("game.start", &start_game, &game)!;
ui.load_styles({ styles })!;
UiDocumentId hud = ui.load_document(document)!;
```

The styles and the document are JSONC strings, for example embedded with `$embed`:

```jsonc
{
  "text": { "font": "ui/regular", "font_size": 16, "text_color": "#e6dfc8ff" },
  "panel": { "fill": "#14161cdd", "radius": 6, "padding": 10, "gap": 8, "direction": "column" },
  "button": {
    "extends": "text", "fill": "#2b2b2bff", "radius": 4, "padding": [10, 5],
    "hover": { "fill": "#3a3a3aff" }
  }
}
```

```jsonc
{
  "anchor": "top_left",
  "offset": [16, 16],
  "root": { "kind": "panel", "style": "panel", "children": [
    { "kind": "label", "style": "text", "text": "Gold: {hud.gold}" },
    { "kind": "button", "style": "button", "on_click": "game.start", "children": [
      { "kind": "label", "style": "text", "text": "Start" } ] }
  ] }
}
```

Fonts and images a style or document names must be in the store when it loads. Register bindings and actions before the documents that use them. The frame loop is under [Frame order](#frame-order).

## Concepts

- **Document.** A JSONC tree of elements with an anchor, an offset and a layer. `load_document` returns a `UiDocumentId`. Documents stack by `layer`, then by load order. `set_visible` shows or hides one; a hidden document evaluates nothing.
- **Style.** A named set of properties with state blocks (`hover`, `pressed`, `disabled`, `focused`) and one `extends` parent. `load_styles` replaces the whole set from ordered sheets; loaded documents re-resolve their style names, so a reskin keeps focus, scroll and field text. Load styles before the documents that use them.
- **Binding.** A getter that code registers under a dotted name and a value kind. Documents read it as `{name}` in text and in keys such as `visible`, `value` and `items`. Getters run every frame, for declared elements only.
- **Action.** A handler that code registers under a dotted name. Documents trigger it by name from `on_click` and the other action keys.
- **Layout units.** Every number in a document is a layout unit. `update` takes the output size in pixels and `scale`, the output pixels per layout unit: pixel density times any user UI scale.
- **Previous-frame routing.** `route_input` hit-tests the pointer against the layout the last `update` produced. A document loaded this frame takes no input until the next `update`.
- **Ownership.** `Ui` is a value that allocates every table once in `create_ui`; nothing allocates per frame. It holds the asset store by pointer, so the store outlives the UI. Fonts gain outlines while `draw` runs. `Ui` is not synchronized: call it from one thread.

## Frame order

```c3
OverlayList list = render::create_overlay_list(mem, render::default_overlay_list_desc());
defer render::destroy_overlay_list(&list);

while (window.poll()) {
    gui_renderer.new_frame();                       // without ImGui: window.input.clear_gui_flags();
    ui.route_input(&window.input, window.events()); // actions fire here
    // game input reads Input; the capture flags gate it
    ui.update(
        width:         window.width,
        height:        window.height,
        scale:         window.pixel_density,
        delta_seconds: window.clock.delta,
    )!;
    gui_renderer.finish_frame();                    // without ImGui: window.set_text_input(ui.wants_text_input);

    list.clear();
    ui.draw(&list)!;
    renderer.begin_frame(info)!;
    // render views; a render target the list samples renders first
    renderer.prepare_overlay_list(&list)!;
    OverlayContext overlay = renderer.begin_overlay()!;
    overlay.draw_list(&list)!;
    gui_renderer.record(&overlay)!;
    renderer.end_overlay(&overlay)!;
    renderer.end_frame()!;
}
```

- `route_input(input, events)` takes the window's `Input` and its events of the frame. It ORs `mouse_captured_by_gui`, `keyboard_captured_by_gui` and `text_input_wanted_by_gui` into `Input` and never clears them. When ImGui already holds the mouse, the UI receives no hover, press or wheel that frame; a press there still blurs a focused field. A focused text field sets the keyboard and text-input flags, and `ui.wants_text_input` reports the same want.
- While a window drag is pending or active, `route_input` sets the mouse and keyboard flags, also when ImGui holds the mouse, and keeps following the pointer. Hover and tooltips stay empty and the wheel is ignored until the button is released or Escape cancels the drag.
- With ImGui, `GuiRenderer.new_frame` writes the flags and `finish_frame` applies the combined text-input want. Without ImGui, call `input.clear_gui_flags()` before `route_input` and apply `ui.wants_text_input` with `window.set_text_input`. [GUI overlay](gui.md#input-and-frame-order) and [platform](platform.md) state the flag contract.
- `update` evaluates bindings, expands templates and lays out every visible document. `delta_seconds` is the time since the previous update, finite and not negative; it advances every running transition. A frame that overflows a table faults `c3d::CAPACITY_EXCEEDED`, draws nothing, and the next frame retries.
- `draw` may run any time after `update` and before `prepare_overlay_list`. A load, reload, unload or style load invalidates the frame until the next `update`. Draw the list before `GuiRenderer.record`, so ImGui draws on top ([overlay list](overlay.md)).
- Game input reads `Input` after `route_input` and checks the capture flags first. In an engine, action handlers queue commands for the next simulation tick.

## Write a document

[Elements](ui_reference.md#elements) are `panel`, `label`, `image`, `button`, `bar`, `list`, `scroll`, `text_field`, `tooltip` and `grid`. Every element takes `kind`, `id`, `style`, `visible`, `enabled`, the action keys and any style property inline.

```jsonc
{
  "anchor": "bottom_left",
  "offset": [16, -16],
  "layer": 0,
  "root": { "kind": "panel", "style": "hud_panel", "direction": "column", "children": [
    { "kind": "label", "style": "title", "text": "Squad ({squad.size})" },
    { "kind": "list", "items": "{squad.members}", "template": {
        "kind": "button", "style": "member_row", "on_click": "squad.select", "enabled": "{member.alive}",
        "children": [
          { "kind": "image", "image": "{member.portrait}", "size": [48, 48] },
          { "kind": "label", "style": "body", "text": "{member.name}" },
          { "kind": "bar", "style": "health_bar", "value": "{member.health}", "size": [80, 6] }
        ] } }
  ] }
}
```

Text templates, lists, grids, tooltips, visibility, ids and text fields follow the rules in the [reference](ui_reference.md#elements). A `list` lays out one copy of its `template` per item of a LIST binding, and the item's bindings exist only inside the template. A `grid` places each item at a cell; its items are drag sources, and `on_drop` receives the dragged item and the target cell. Give an element an `id` when its layout state (a scroll offset, a window position, a transition) must survive `reload_document`.

### Windows

`"window": true` makes a `panel` a window: it floats over its parent's content, moves when its drag handle is dragged and rises above its sibling windows when pressed.

```jsonc
{ "kind": "panel", "id": "inspector", "window": true, "position": [24, 40], "on_move_end": "inspector.moved",
  "children": [
    { "kind": "panel", "drag_handle": true, "children": [
        { "kind": "label", "text": "Inspector" },
        { "kind": "button", "on_click": "inspector.close", "children": [ { "kind": "label", "text": "x" } ] } ] },
    { "kind": "label", "text": "Contents" }
  ] }
```

A window needs an `id`. `ui.window_offset(document, id)` reads its offset and `ui.set_window_offset(document, id, offset)` moves it without clamping, so an application can save and restore layouts. [Windows](ui_reference.md#windows) lists the keys and rules.

## Bind data

Tag the fields of a struct and expose them with a macro, or register getters one at a time.

```c3
struct Member {
    String     name     @tag("ui", true);
    float      health   @tag("ui", true);
    bool       alive    @tag("ui", true);
    TextureRef portrait @tag("ui", true);
    int        gold     @tag("ui", "coins"); // exposed as member.coins
    int        internal_id;                  // not exposed
}

ui.@bind_fields("leader", Member, &leader)!;               // leader.name, leader.health, ...
ui.@bind_list("squad.members", "member", Member, &squad)!;  // squad.members (LIST) and member.* per item
ui.@bind_fields("cargo", Cargo, &cargo, { "gold" })!;      // a name list for structs you cannot tag

fn UiValue squad_size(void* user, UiScope* scope) {
    return { .kind = INT, .integer = (long)((Game*)user).squad.len };
}

ui.bind(name: "squad.size", kind: INT, getter: &squad_size, user: &game)!;
```

`@bind_list` reads a slice on every update; `@bind_items` takes callbacks for nested lists and containers that are not slices. A getter returns a `UiValue` of the kind it registered and receives a `UiScope` whose `indices[scope.depth - 1]` is its item. Registration may happen at any time; a loaded document keeps the names it resolved. Getters must not load, unload or register. [Bindings and actions](ui_reference.md#bindings-and-actions) lists the kinds and the macros.

## Handle actions

```c3
fn void select_member(void* user, UiScope* scope, UiEvent* event) {
    ((Game*)user).selected = scope.indices[0];
}

ui.on("squad.select", &select_member, &game)!;
```

Handlers run inside `route_input` with the scope of the element that fired, and must not load, unload or register. A drop handler accepts by changing data and rejects by leaving it unchanged; the next frame shows the result. [Actions](ui_reference.md#actions) lists the keys and the `UiEvent` fields.

## Animate with transitions

A style's `transition` times each change of the properties it lists: a hover fade, a bar's value, a lift.

```jsonc
"member_row": {
  "fill": "#1f222bff",
  "transition": { "properties": ["fill"], "duration": 0.15, "easing": "ease_out" },
  "hover": { "fill": "#2c313dff" }
},
"health_bar": { "transition": { "properties": ["value"], "duration": 0.4 } }
```

A style whose `hidden` block sets a listed property (`"hidden": { "opacity": 0, "offset": [48, 0] }`) also enters and exits through it: the element starts at the hidden values when it appears and an exiting element animates to them before it disappears. `ui.set_reduced_motion(true)` makes `offset`, `size` and `value` changes instant. Each element with a `transition` holds an entry in a table of `UiDesc.max_transitions` entries; when it is full, the other elements snap. [Transitions](ui_reference.md#transitions) lists the keys and the enter and exit rules.

## Report loading errors

`load_document`, `reload_document` and `load_styles` check every name a file uses and fault with a named error. `reload_document` and `load_styles` are atomic: on a fault the old tree or set stays. `ui.load_error_path()` returns an RFC 6901 JSON pointer to the failing value, for example `/root/children/1/template/style`. For `load_styles` the pointer starts with the sheet index (`/1/title/extends`); when a loaded document no longer resolves against the new set, `ui.load_error_document` names it.

```c3
if (catch excuse = ui.reload_document(hud, text)) {
    io::eprintfn("%s at %s", excuse, ui.load_error_path());
}
```

[Faults](ui_reference.md#faults) lists the errors a mod author sees. Reload a document or the styles from disk while the application runs to see an edit without a restart.

## Limits

- **Text.** There is no shaping: no ligatures, complex scripts or bidirectional text. Text wraps at spaces and newlines only. A text field has no selection and no IME preedit display.
- **Capacities.** Every table has a fixed capacity from `UiDesc`. A full table faults `c3d::CAPACITY_EXCEEDED`; a frame that overflows draws nothing. Font lists are never released.
- **Layout.** Lists nest up to `UI_SCOPE_DEPTH` (4). A window is a child of a `panel` or a `scroll`, never in a list or grid template.
- **Opacity.** There is no group opacity: overlapping descendants show through each other.
- **Input.** Only the left and right mouse buttons fire actions, and one text field is focused at a time.

## See also

- [UI reference](ui_reference.md): document format, styles, transitions, capacities and faults.
- [Overlay list](overlay.md), [text](text.md), [GUI overlay](gui.md), [platform](platform.md).
- [Package README](../addons/c3d_ui.c3l/README.md). The `ui` example (`python3 scripts/build.py --example ui`) builds a HUD, an inventory with drag and drop, windows, rich text and transitions.
