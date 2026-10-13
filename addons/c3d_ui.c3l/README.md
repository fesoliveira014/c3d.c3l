# c3d_ui

Game UI for c3d. Module `c3d::ui`, package `c3d_ui`. Applications build their interface from JSONC documents that
mods can edit without code: an element tree, styles with single inheritance, data bindings and named actions. Code
registers every name a document may read or trigger. Each frame the add-on lays the visible documents out with
[Clay](https://github.com/nicbarker/clay) (through `lib/clay.c3l`), routes pointer and text input against the
previous frame's layout, and appends rectangles and glyph runs to an `OverlayList` ([Overlay list](../../docs/overlay.md),
[Text](../../docs/text.md)).

Layout, skins and styles are data; behavior stays in code. ImGui stays the tool for debug panels and draws on top.

## Package and boundaries

- `c3d::ui` imports the standard library, `c3d` (the overlay list from `c3d::render`, input and events from
  `c3d::platform`, fonts and textures from `c3d::asset`) and `clay`. It never imports `gpu`, `sdl`, `imgui` or another
  add-on, and creates no GPU object.
- Core never imports it. Select it with the `c3d_ui` and `clay` dependencies.
- Targets: `ui_test` (CPU, no device), the `ui` example, and the manual `test/gpu` project with `ui_acceptance`.

## Frame order

```c3
Ui ui = ui::create_ui(mem, &assets, ui::default_ui_desc())!;
defer ui::destroy_ui(&ui);

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

- `route_input` hit-tests the pointer against the previous `update`'s layout. It ORs `mouse_captured_by_gui`,
  `keyboard_captured_by_gui` and `text_input_wanted_by_gui` into `Input` and never clears them. When ImGui already
  holds the mouse, the UI receives no hover, press or wheel that frame; a press there still blurs a focused field.
- While a window drag is pending or active, `route_input` sets `mouse_captured_by_gui` and `keyboard_captured_by_gui`,
  also when ImGui holds the mouse, and keeps following the pointer. Hover and tooltips stay empty and the wheel is
  ignored until the button is released or Escape cancels the drag. Before the first `update` after a load, a drag
  still ends on release and cancels on Escape.
- With ImGui, `GuiRenderer.new_frame` writes the three flags and `finish_frame` applies the combined text input want.
  Without ImGui, call `input.clear_gui_flags()` before `route_input` and apply `ui.wants_text_input` yourself.
- `update` takes the output size in pixels and `scale`, the output pixels per layout unit: pixel density times any
  user UI scale. Every number in a document is a layout unit. `delta_seconds` is the time since the previous update,
  finite and not negative; `ui.delta_seconds` holds the last value.
- `draw` may run any time after `update` and before `prepare_overlay_list`. A load, reload, unload or style load
  invalidates the frame until the next `update`.

## Documents

```jsonc
{
  "anchor": "bottom_left",   // top_left (default), top, top_right, left, center, right, bottom_left, bottom, bottom_right
  "offset": [16, -16],       // layout units from the anchor
  "layer": 0,                // higher draws and takes the pointer first; equal layers stack by load order
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

The root's anchor point sits on the screen's matching point; `offset` moves it. `ui.load_document(jsonc)` returns a
`UiDocumentId`; `reload_document(id, jsonc)`, `unload_document(id)` and `set_visible(id, visible)` take it.
`reload_document` and `load_styles` are atomic: on a fault the old tree or set stays.

### Elements

| Kind | Children | Own keys |
| --- | --- | --- |
| `panel` | `children` | `window`, `position`, `drag_bounds`, `on_move_start`, `on_move_end` (see Windows) |
| `label` | | `text`, `markup` (see Text templates) |
| `image` | | `image` (asset key or `{IMAGE}`), `uv` [u0, v0, u1, v1] |
| `button` | `children` | |
| `bar` | | `value` (number or `{INT}`/`{FLOAT}`), `bar_direction`: `left_to_right` (default), `right_to_left`, `bottom_to_top`, `top_to_bottom` |
| `list` | `template` | `items` (`{LIST}`) |
| `scroll` | `children` | `scroll`: `vertical` (default), `horizontal`, `both` |
| `text_field` | | `value` (`{TEXT}`), `placeholder` (a template), `on_change`, `on_submit` |
| `tooltip` | `children` | |
| `grid` | `template` | `items` (`{LIST}`), `columns`, `rows`, `cell_size` [w, h], `item_cell` (`{INT}`), `item_span` [w, h] (numbers or `{INT}`) |

Every element takes `kind`, `id`, `style`, `visible` and `enabled` (a literal or `{BOOL}`), the actions `on_click`,
`on_secondary_click` and `on_drop`, `drag_handle` inside a window, and every style property inline.

- `list` lays its items out like a panel, one template copy per item.
- A `tooltip` shows while the pointer is over its parent, interactive or not, floating below it above everything,
  and never takes the pointer.
- A `grid` places each item's template at `item_cell` (row-major) with the size `item_span * cell_size`; items that
  do not fit the grid are skipped. Grid items are drag sources. A drag ends without a drop when its item is no longer
  laid out (the application removed it), and other buttons are ignored while a drag is active.
- An image sizes to its asset texture in texels when `width` or `height` is `fit`; a render-target image needs both.
- `visible: false` collapses a subtree: no layout and no getter calls. `enabled: false` gives the disabled state to
  the element and its descendants, and they fire no actions.
- Interactive elements are buttons, text fields, grid items and any element with an action. Hover, press and
  disabled states apply to the interactive element and its descendants, except that an interactive descendant takes
  its own hover and press; focus applies to the focused field.

### Windows

`"window": true` makes a `panel` a window: it floats over its parent's content, takes a runtime offset and moves when
its drag handle is dragged.

```jsonc
{ "kind": "panel", "id": "inspector", "window": true, "position": [24, 40], "on_move_end": "inspector.moved",
  "children": [
    { "kind": "panel", "drag_handle": true, "children": [
        { "kind": "label", "text": "Inspector" },
        { "kind": "button", "on_click": "inspector.close", "children": [ { "kind": "label", "text": "x" } ] } ] },
    { "kind": "label", "text": "Contents" }
  ] }
```

| Key | On | Value |
| --- | --- | --- |
| `window` | `panel` | `true` for a window; it needs an `id` |
| `position` | window | [x, y], signed layout units from the parent's top left; the offset a window starts at (default [0, 0]) |
| `drag_bounds` | window | `parent` (default): the window stays inside its parent's padding box; `viewport`: inside the layout area; `none` |
| `drag_handle` | the window or a descendant | `true` marks the region that drags the nearest enclosing window |
| `on_move_start`, `on_move_end` | window | actions fired when a drag starts and ends; `event.offset` is the window offset |

- A window's parent is a `panel` or a `scroll`. A window is not the root and not inside a list or grid template.
  Windows nest. A window with a `window` key that breaks these rules faults `c3d::ASSET_FORMAT_ERROR` at its `window`;
  `window` on another kind, and `position`, `drag_bounds`, `on_move_start` and `on_move_end` off a window, fault
  `UNKNOWN_PROPERTY`, as does `drag_handle` outside every window.
- A parent declares its other children first, in document order, then its windows from the lowest raise order to the
  highest. A press anywhere in a window raises it and every window around it above their sibling windows. The
  nearest enclosing `scroll` clips a window, and a window directly in a `scroll` scrolls with the content. Hover,
  press and wheel reach only the topmost window under the pointer.
- A press on a handle starts a drag after `UI_DRAG_THRESHOLD` layout units of travel. An interactive element between
  the press and the handle, such as a close button on the title bar, keeps the press. A press on an interactive
  handle that never moves is still a click. `on_move_start` fires when the drag starts, and `on_move_end` on release
  with the final offset.
- The offset follows the pointer's travel since the press, in layout units, and is clamped to `drag_bounds` against
  the previous layout. Escape cancels a drag: the offset returns to its start and no `on_move_end` fires. A drag also
  cancels, without `on_move_end`, when the window or all of its handles are not laid out in an `update`.
- `ui.window_offset(document, id)` reads a window's offset; `ui.set_window_offset(document, id, offset)` moves a
  window without clamping and cancels a drag of it.
- Offsets and raise order belong to the window's `id`. `reload_document` keeps them for ids the new tree still has and
  drops the rest; a drag continues if the new tree has the window and one of its handles, and cancels otherwise.
  `load_styles` and the load of another document change nothing, and `unload_document` drops the document's windows.
- A document without windows lays out and draws as before. Each window takes two layers above its document's root
  and grid items, so documents keep their order; `update` faults `c3d::CAPACITY_EXCEEDED` when the layers reach the
  tooltips.
- `ui --windows` loads `examples/ui/windows.jsonc`; with `--frames N` it replays a scripted drag, raise and nested
  drag.

### Ids

`"id": "log.view"` names an element of any kind. An id is a dotted lowercase name, the rule of binding names, and is
unique within its document. Inside a list or grid template the id names the template's element in every item.

- A repeated id faults `c3d::ASSET_FORMAT_ERROR` at the `id` of the later element in document order, as does a name
  that breaks the rule.
- Layout state follows an element's id. A `scroll` element with an id keeps its offset across `reload_document` while
  the new tree has a scroll with that id, wherever the tree moved it. A scroll without an id is keyed by its position
  in the tree, so it keeps its offset only while its position stays.
- An element's layout id hashes its document, its id and its item scope; an element without an id hashes its position
  instead, tagged apart so the two inputs never coincide. Two different ids whose 32-bit FNV-1a hashes are equal
  would share a layout id, so they fault `c3d::ASSET_FORMAT_ERROR` at the later `id`, like a repeated id. Rename one.

### Text templates

`"text": "Squad ({squad.size}): {squad.gold:0} gold"`. `{name}` inserts a BOOL, INT, FLOAT or TEXT binding; `{{`
and `}}` insert braces. INT prints as decimal. FLOAT prints with up to 2 decimals, trailing zeros and point trimmed.
`{name:N}` prints an INT or FLOAT with N fixed decimals, N from 0 to 6. BOOL prints `true` or `false`.

`"markup": true` turns on span tags in a label's `text`, so one label can mix fonts, sizes, colors, underlines and
highlights:

```jsonc
{ "kind": "label", "style": "text", "markup": true,
  "text": "[title]Wave 3[/title] holds for [caption]02:41[/caption]. Press [key] E [/key] to [warn]open[/warn]." }
```

- `[name]` opens a span and `[/name]` closes it; `name` is a style of the set. A span style may set only `font`,
  `font_size`, `text_color`, `underline` and `text_highlight`, in its base and its state blocks; the state blocks apply
  with the label's state. A span overrides the label's own properties for the text it covers.
- Spans nest up to `UI_SPAN_DEPTH` (4), with at most `UI_MAX_SPANS` (16) per label.
- `[[` inserts `[` and a lone `]` is literal. Any other `[` sequence faults. Without `"markup": true`, brackets are
  literal; `markup` on any other kind faults `UNKNOWN_PROPERTY`.
- A value inserted by `{name}` goes into the open span verbatim and is never read as markup.
- Malformed text faults at the label's `text`: `c3d::ASSET_FORMAT_ERROR` for an unclosed span, a close tag that
  matches no open span, a malformed tag, nesting past `UI_SPAN_DEPTH` or more than `UI_MAX_SPANS` spans;
  `UNKNOWN_STYLE` for a name that is no style; `UNKNOWN_PROPERTY` for a span style that sets another property.
  `load_styles` re-resolves every span name with the same faults, atomically, and names the document.

Every other binding reference is written in braces too: `"enabled": "{member.alive}"`, `"image": "{member.portrait}"`.
A string without braces in `image` is an asset key.

## Styles

`ui.load_styles(sheets)` replaces the whole style set with ordered sheets; a later sheet overrides a style of the same
name, and `extends` resolves across sheets. Loaded documents re-resolve their style names, so a reskin keeps focus,
scroll and field text. Load styles before the documents that use them.

```jsonc
{
  "button": {
    "fill": "#2b2b2bff", "radius": 4, "padding": [6, 4],
    "font": ["ui/latin", "ui/cjk"], "font_size": 16, "text_color": "#e0d8c0ff",
    "hover": { "fill": "#3a3a3aff" },
    "disabled": { "text_color": "#7a7466ff" }
  },
  "member_row": { "extends": "button", "fill": "#00000000", "border": { "width": 1, "color": "#5a4a30ff" } }
}
```

| Property | Value |
| --- | --- |
| `fill`, `text_color`, `bar_fill`, `highlight` | `"#rrggbb"` or `"#rrggbbaa"`, sRGB |
| `border` | `{ "width": n or [l, t, r, b], "color": color }` |
| `radius` | n or [top left, top right, bottom right, bottom left] |
| `padding` | n, [x, y] or [l, t, r, b] |
| `gap` | n |
| `width`, `height` | n (fixed), `"fit"` (default), `"grow"`, `"NN%"` |
| `size` | [width, height], each as above |
| `min_width`, `min_height`, `max_width`, `max_height` | n |
| `direction` | `row` (default) or `column` |
| `align` | [x, y]: `left`, `center`, `right`; `top`, `center`, `bottom` |
| `font` | a store key or a list of up to 4 keys |
| `font_size` | n, whole layout units |
| `line_height` | n; 0 (default) uses the first font's ascent, descent and line gap |
| `wrap` | `words` (default), `newlines`, `none` |
| `text_align` | `left` (default), `center`, `right` |
| `underline` | `true` or `false` (default); a line under the text |
| `text_highlight` | color (default transparent) behind the text |
| `skin`, `bar_skin` | `{ "image": key, "slice": [l, t, r, b] }`, nine-slice margins in texels |

The state blocks `hover`, `pressed`, `disabled` and `focused` take properties only. Effective properties are the
flattened base, then the active state blocks in the order focused, hover, pressed, disabled (later wins), then the
element's inline properties. Defaults: transparent fill, white text, `font_size` 16, no underline or text highlight, no
border, radius or padding.
An image multiplies its texture by `fill`, white when the fill is transparent; `highlight` colors a grid's drop
footprint; a bar draws `bar_fill` or `bar_skin` over its content box. `underline` and `text_highlight` apply to
label, field and placeholder text, and inside spans.

## Bindings

```c3
struct Member {
    String     name     @tag("ui", true);
    float      health   @tag("ui", true);
    bool       alive    @tag("ui", true);
    TextureRef portrait @tag("ui", true);
    int        gold     @tag("ui", "coins"); // exposed as member.coins
    int        internal_id;                  // not exposed
}

ui.@bind_fields("leader", Member, &leader)!;              // leader.name, leader.health, ...
ui.@bind_list("squad.members", "member", Member, &squad)!; // squad.members (LIST) and member.* per item
ui.@bind_fields("cargo", Cargo, &cargo, { "gold" })!;     // a name list for structs you cannot tag
ui.bind(name: "squad.size", kind: INT, getter: &squad_size, user: &game)!;
```

- Field kinds: `bool` BOOL; signed and unsigned integers INT; `float`, `double` FLOAT; `String` TEXT; `TextureRef`
  IMAGE; a slice LIST (its length). Any other field type is a compile error.
- `@bind_list` takes a pointer to a slice and reads it on every update. `@bind_items(name, item, $Type, count,
  item_at, user, list)` takes callbacks instead, for nested lists or containers that are not slices; its `list` names
  the enclosing list when the list is itself an item of another.
- Item bindings exist only inside their list's template. A getter receives the scope truncated to its own list
  level: `scope.indices[scope.depth - 1]` is its item, outer indices stay readable; root bindings get depth 0.
- Names are dotted lowercase identifiers. Registration may happen at any time; a loaded document keeps the names it
  resolved. Getters run every frame for declared elements only; a getter returns values of its registered kind and
  must not load, unload or register.

## Actions

```c3
fn void select_member(void* user, UiScope* scope, UiEvent* event) {
    ((Game*)user).selected = scope.indices[0];
}

ui.on("squad.select", &select_member, &game)!;
```

| Key | Fires |
| --- | --- |
| `on_click` | left press and release on the same element |
| `on_secondary_click` | right press and release on the same element |
| `on_change` | each edit of a focused text field; `event.text` is the field text |
| `on_submit` | Enter in a focused text field, which then blurs |
| `on_drop` | a grid item released over the element; `event.source` and `event.source_list` name the item, `event.cell` the target grid cell (`UI_NO_CELL` outside a grid) |
| `on_move_start` | a window drag began; `event.offset` is the window's offset |
| `on_move_end` | a window drag was released; `event.offset` is the final offset. Escape and a disappearing window cancel without it |

Handlers run inside `route_input` with the scope of the element that fired. In an engine they queue commands for the
next simulation tick. A drop handler accepts by changing data and rejects by leaving it unchanged; the next frame
shows the result. Handlers must not load, unload or register.

Text fields own an edit buffer (`UiDesc.field_bytes`) seeded from `value` on focus: Backspace, Delete, Left, Right,
Home and End work per code point, Ctrl+V pastes, Escape blurs and the field shows its bound value again. There is no
selection and no IME preedit display; committed IME text arrives as text input.

## Errors for mod authors

Loading faults name the failing value with an RFC 6901 JSON pointer, read with `ui.load_error_path()`, for example
`/root/children/1/template/style`. For `load_styles` the pointer starts with the sheet index (`/1/title/extends`);
when a loaded document no longer resolves against the new set, `ui.load_error_document` names it and the pointer
points into it.

| Fault | Meaning |
| --- | --- |
| `UNKNOWN_ELEMENT_KIND` | `kind` names no element kind, or is missing |
| `UNKNOWN_PROPERTY` | a key the element kind, style or state block does not take; a span style that sets a property other than the five of a span |
| `UNKNOWN_STYLE` | `style`, `extends` or a span tag names no style of the set |
| `STYLE_CYCLE` | an `extends` chain returns to a style it left; the pointer is the closing `extends` |
| `UNKNOWN_BINDING` | a binding no registration provides in that scope |
| `BINDING_KIND_MISMATCH` | a binding of a kind the key does not take |
| `UNKNOWN_ACTION` | an action nothing registered with `Ui.on` |
| `UNKNOWN_ASSET` | an image or font key the store lacks; a text element without a font |
| `c3d::ASSET_FORMAT_ERROR` | a value of the wrong JSON type or out of range; an `id` that is not a valid name, repeats or collides; a `window` without an `id`, on the root, in a template or under a parent that is not a `panel` or `scroll`; malformed span markup |
| `c3d::CAPACITY_EXCEEDED` | a UI table full, including the window table; lists nested deeper than `UI_SCOPE_DEPTH` |
| `json::*`, `io::EOF` | syntax errors from `std::encoding::json`; the error path is empty |

The std parser reports no line or column for syntax errors. Keys are checked in sorted order, so a document with
several errors reports the same one every time.

## Text

- A style's `font` lists up to four fonts. Each line splits where an earlier font lacks a glyph; each run uses one
  font and kerning does not cross runs.
- Text wraps at spaces and newlines only, so CJK text without spaces wraps only at authored newlines. There is no
  shaping: no ligatures, contextual forms, complex scripts or bidirectional text.
- Placements of unchanged lines come from a fixed cache keyed by font list and line bytes (`UiDesc.cache_lines`,
  `cache_glyphs`); a full cache clears and refills, counted in `ui.stats.placement_clears`.
- A label with at least one span lays its text out itself; every other label keeps the plain path above. Each run of
  text that shares its spans resolves its properties (the label's, then each enclosing span's, outermost first) and is
  measured once; a run that does not fit the line is split at spaces. Breaks fall at spaces and newlines, also across
  span boundaries, and never inside a word: `wrap: words` breaks at both, `newlines` only at newlines and `none` never
  breaks. A break consumes the space it breaks at.
- A line is as tall as its tallest run, or `line_height` when the label sets one, and all runs on a line share one
  baseline. `text_align` positions each line within the label's content width. A rich label sizes its `fit` width and
  height to the text it laid out.
- A rich label wraps at its fixed `width`, or at `max_width` when its width is not fixed, and at nothing else: it
  never wraps against the width a `grow` or `percent` panel gives it. Give a rich label in such a panel a `max_width`.
- `underline` sits 0.12 em below the baseline and is 0.06 em thick, at least one pixel; fonts carry no underline
  metrics. Each piece of text draws its highlight, then its glyphs, then its underline.
- Each run on each line is one piece; `UiDesc.max_text_pieces` bounds the pieces of a frame and `ui.stats.text_pieces`
  counts them. A label without spans uses none.
- `ui --rich-text` loads `examples/ui/rich.jsonc`: mixed sizes on one baseline, a highlighted key and an underlined
  warning, a bound value in a span, CJK text through the font fallback and a paragraph wrapped at `max_width`.

## Capacities

`default_ui_desc()`: 16 documents, 256 styles, 64 font sets, 1,024 bindings, 256 actions, 64 item sources, 32 KiB of
names, 4,096 laid-out elements per frame, 64 KiB of expanded text per frame, 2,048 cached lines with 32,768 cached
glyphs, a 256-byte field buffer, 64 windows (60 bytes each) across the loaded documents and 1,024 rich text pieces per
frame (76 bytes each); `max_windows` and `max_text_pieces` may be 0, which holds none. Every table is allocated once
in `create_ui`; documents and style sets allocate once when they load. Nothing allocates per frame. A load or reload
whose windows do not fit the table faults `CAPACITY_EXCEEDED` and changes nothing. `update` faults
`CAPACITY_EXCEEDED` when a frame overflows, including a frame whose rich labels need more pieces than the table holds;
that frame draws nothing and the next frame retries.

## Measured costs

`ui --benchmark --frames F [--labels N]` needs no window or device. It lays out a HUD of 50 rows (485 elements, 200
bound values: a name, a formatted number, a bar fraction and a visibility flag per row) at 1920 x 1080, moves a
synthetic pointer across it, clicks every 8th frame, changes one row's values every frame, and prints the mean CPU
time per frame of `route_input`, `update` and `draw` after F warm-up frames. `--labels N` adds a document of N labels
in a scroll area; Clay culls the labels outside the window, so they cost layout but few glyphs.

Measured on an Intel i9-14900K under WSL, c3c 0.8.3, `--opt O3`, `--frames 200`:

| Case | route_ms | update_ms | draw_ms | instances | glyphs | placement hits / misses |
| --- | --- | --- | --- | --- | --- | --- |
| HUD | 0.0187 | 0.2019 | 0.0061 | 485 | 544 | 250 / 0 |
| HUD and 1,000 labels | 0.0678 | 0.7765 | 0.0083 | 1,486 | 898 | 302 / 0 |

The same benchmark natively on Windows (i9-14900K, c3c 0.8.3, `--opt O3`, MSVC `cl` 19.44 for Clay, median of three
runs): HUD route 0.0203, update 0.2695, draw 0.0059 ms; HUD and 1,000 labels route 0.0726, update 1.0399, draw
0.0079 ms. `update` runs about a third slower there; routing and drawing match.

`update` dominates: binding evaluation, template expansion, Clay declaration and layout. Text placement is cached,
so `draw` stays near 6 µs. `update` costs about 0.4 µs per laid-out element for the HUD and 0.5 µs with the extra
labels; the getter calls were not timed apart from the rest of `update`. The unoptimized build measured 0.30 ms and
1.07 ms for `update`.
