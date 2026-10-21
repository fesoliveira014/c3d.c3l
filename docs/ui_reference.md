# UI reference

Reference for the `c3d::ui` module of the `c3d_ui` add-on: the document format, style properties, transitions, text rules, the API, capacities and faults. The [UI guide](ui.md) explains how to use them.

## Document

A document is a JSONC object. Keys are checked in sorted order, so a document with several errors reports the same one every time. Any key not listed faults `UNKNOWN_PROPERTY`.

| Key | Value |
| --- | --- |
| `root` | Required. The root element |
| `anchor` | `top_left` (default), `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`. The root's anchor point sits on the screen's matching point |
| `offset` | `[x, y]`, signed layout units from the anchor. Default `[0, 0]` |
| `layer` | Integer from -1000 to 1000. A higher layer draws and takes the pointer first; equal layers stack by load order. Default 0 |

A loaded document is visible.

## Elements

| Kind | Children | Own keys |
| --- | --- | --- |
| `panel` | `children` | `window`, `position`, `drag_bounds`, `on_move_start`, `on_move_end` |
| `label` | none | `text`, `markup` |
| `image` | none | `image` (an asset key or `{IMAGE}`), `uv` (`[u0, v0, u1, v1]`) |
| `button` | `children` | none |
| `bar` | none | `value` (a number, `{INT}` or `{FLOAT}`), `bar_direction`: `left_to_right` (default), `right_to_left`, `bottom_to_top`, `top_to_bottom` |
| `list` | `template` | `items` (`{LIST}`) |
| `scroll` | `children` | `scroll`: `vertical` (default), `horizontal`, `both` |
| `text_field` | none | `value` (`{TEXT}`), `placeholder` (a text template), `on_change`, `on_submit` |
| `tooltip` | `children` | none |
| `grid` | `template` | `items` (`{LIST}`), `columns`, `rows`, `cell_size`, `item_cell`, `item_span` |

Every element also takes `kind` (required), `id`, `style`, `visible` and `enabled` (a literal or `{BOOL}`, default true), the actions `on_click`, `on_secondary_click` and `on_drop`, `drag_handle` inside a window, and any style property inline, which applies after the style.

- A `list` lays its items out like a panel, one template copy per item.
- A `tooltip` is the child of another element, never the root and never a template root (`c3d::ASSET_FORMAT_ERROR`). It shows while the pointer is over its parent, floats below it above everything and never takes the pointer.
- A `grid` needs `columns` and `rows` (integers from 1 to 256) and a positive `cell_size` (`[width, height]`); its size is fixed from them plus padding. `item_cell` is an item's row-major cell (integer or `{INT}`, default 0) and `item_span` its `[width, height]` in cells (default `[1, 1]`). Items with a negative cell, a span below 1 or no room in the grid are skipped. A drag ends without a drop when its item is no longer laid out, and other buttons are ignored while a drag is active.
- An `image` sizes to its asset texture in texels when `width` or `height` is `fit`. An image bound to a render target needs both. A `bar` clamps its value to [0, 1].
- `visible: false` collapses a subtree: no layout and no getter calls. `enabled: false` disables the element and its descendants, and they fire no actions.
- Interactive elements are buttons, text fields, grid items and any element with an action other than `on_move_start` and `on_move_end`. Hover, press and disabled states apply to the interactive element and its descendants; an interactive descendant takes its own hover and press. Focus applies to the focused field.
- A `label` or `text_field` needs a font from its style or inline, or it faults `UNKNOWN_ASSET` at `font`.

### Ids

`"id": "log.view"` names an element of any kind. An id is a dotted lowercase name ([Names](#names)), unique within its document. Inside a list or grid template the id names the template's element in every item. A repeated id, a bad name, or two ids with equal 32-bit FNV-1a hashes fault `c3d::ASSET_FORMAT_ERROR` at the later `id`.

Layout state follows an element's id. A `scroll` with an id keeps its offset across `reload_document` while the new tree has a scroll with that id. A scroll without an id keeps its offset only while its position in the tree stays.

### Windows

`"window": true` makes a `panel` a window: it floats over its parent's content, takes a runtime offset and moves when its drag handle is dragged.

| Key | On | Value |
| --- | --- | --- |
| `window` | `panel` | `true` for a window. A window needs an `id` |
| `position` | window | `[x, y]`, signed layout units from the parent's top left; the starting offset. Default `[0, 0]` |
| `drag_bounds` | window | `parent` (default): inside the parent's padding box. `viewport`: inside the layout area. `none` |
| `drag_handle` | window or descendant | `true` marks the region that drags the nearest enclosing window |
| `on_move_start`, `on_move_end` | window | Actions fired when a drag starts and ends; `event.offset` is the window offset |

- A window's parent is a `panel` or a `scroll`. A window is not the root and not inside a list or grid template. Windows nest. A `window` that breaks these rules faults `c3d::ASSET_FORMAT_ERROR`; the window keys off a window, and `drag_handle` outside every window, fault `UNKNOWN_PROPERTY`.
- A press anywhere in a window raises it and the windows around it above their siblings. The nearest enclosing `scroll` clips a window; a window directly in a `scroll` scrolls with the content. Hover, press and wheel reach only the topmost window under the pointer.
- A press on a handle starts a drag after `UI_DRAG_THRESHOLD` layout units of travel. An interactive element between the press and the handle, such as a close button, keeps the press. The offset follows the pointer and is clamped to `drag_bounds` against the previous layout. Escape cancels a drag: the offset returns to its start and `on_move_end` does not fire. A drag also cancels when the window or all of its handles are not laid out in an `update`.
- Offsets and raise order belong to the window's `id`. `reload_document` keeps them for ids the new tree still has and drops the rest; `unload_document` drops the document's windows. `update` faults `c3d::CAPACITY_EXCEEDED` when the windows' z layers reach the tooltip layer.

## Styles

`load_styles(sheets)` takes an array of JSONC objects, each mapping style names to style objects. A later sheet replaces a style of the same name from an earlier one, and `extends` resolves across sheets.

| Property | Value |
| --- | --- |
| `fill`, `text_color`, `bar_fill`, `highlight`, `text_highlight` | `"#rrggbb"` or `"#rrggbbaa"`, sRGB with straight alpha |
| `border` | `{ "width": n or [l, t, r, b], "color": color }` |
| `radius` | n, or `[top left, top right, bottom right, bottom left]` |
| `padding` | n, `[x, y]` or `[l, t, r, b]` |
| `gap` | n |
| `width`, `height` | n (fixed), `"fit"` (default), `"grow"` or `"NN%"` (0 to 100) |
| `size` | `[width, height]`, each as above |
| `min_width`, `min_height`, `max_width`, `max_height` | n |
| `direction` | `row` (default) or `column` |
| `align` | `[x, y]`: `left`, `center`, `right`; `top`, `center`, `bottom` |
| `font` | A font key from the store, or a list of 1 to `UI_FONT_FALLBACKS` (4) keys |
| `font_size` | n, rounded to whole layout units |
| `line_height` | n. 0 (default) uses the first font's ascent, descent and line gap |
| `wrap` | `words` (default), `newlines`, `none` |
| `text_align` | `left` (default), `center`, `right` |
| `underline` | `true` or `false` (default) |
| `skin`, `bar_skin` | `{ "image": key, "slice": n or [l, t, r, b] }`, nine-slice margins in texels. `image` is required |
| `transition` | `{ "properties": [...], "duration": s, "delay": s, "easing": e }` ([Transitions](#transitions)) |
| `opacity` | 0 to 1 (default 1). Multiplies the alpha of everything the element and its descendants draw |
| `offset` | `[x, y]`, signed. Moves a floating element: a document root, window, grid item or tooltip |

Lengths (n) are non-negative numbers in layout units. Defaults: transparent fill, white text, `font_size` 16, opacity 1, and no underline, text highlight, border, radius, padding, transition or offset. An image multiplies its texture by `fill`, white when the fill is transparent. `highlight` colors a grid's drop footprint. A bar draws `bar_fill` or `bar_skin` over its content box.

- **`extends`.** A style names one parent; the chain flattens. A cycle faults `STYLE_CYCLE` at the closing `extends`; an unknown parent faults `UNKNOWN_STYLE`.
- **State blocks.** `hover`, `pressed`, `disabled` and `focused` take properties only. Effective properties are the flattened base, then the active state blocks in the order focused, hover, pressed, disabled (later wins), then the element's inline properties.
- **`hidden` block.** Holds the values an element has while it is not shown; no state flag activates it ([Enter and exit](#enter-and-exit)). It takes `fill`, `border`, `text_color`, `opacity`, `offset` and a `width`, `height` or `size` of fixed numbers. Any other key faults `UNKNOWN_PROPERTY` and a size that is not a number `c3d::ASSET_FORMAT_ERROR`.
- A set holds at most `UiDesc.max_styles` styles across its sheets. `load_styles` is atomic.

## Transitions

A style's `transition` times each change of the properties it lists, whether the change comes from a state block, a style reload or a bar's bound value.

| Key | Value |
| --- | --- |
| `properties` | Required. A non-empty list of distinct names: `fill`, `border` (color and widths), `text_color`, `opacity`, `offset`, `size`, `value` (a bar's fill fraction) |
| `duration` | Required. Seconds, not negative |
| `delay` | Seconds, not negative. Default 0 |
| `easing` | `linear` (default), `ease_in`, `ease_out`, `ease_in_out` |

A bad value faults `c3d::ASSET_FORMAT_ERROR` at its pointer and an unknown key `UNKNOWN_PROPERTY`.

- The transition of the state an element changes to times the change. A `transition` in the base style times both directions of a hover; one in the `hover` block times only the way in.
- `update` advances each running transition by `delta_seconds`. A delta of 0 advances nothing and a large one finishes the transition in that update. A change shows its start value in the `update` that notices it.
- A change that interrupts a running transition starts from the current value, and the duration scales by the share of the old distance that remains. A property the new state's `transition` does not list snaps.
- `size` animates only while `width` and `height` are fixed numbers before and after the change; any other size snaps. `offset` moves floating elements only, so an in-flow element cannot lift on hover.
- Each element whose inline properties or style blocks set a `transition` holds one entry in a table of `UiDesc.max_transitions` entries. An element that is not laid out in an `update` loses its entry, unless it is exiting. When the table is full, changes of elements without an entry snap. An element with an `id` keeps its entry across `reload_document` and `load_styles` and retargets from its current value.
- `set_reduced_motion(true)` makes `offset`, `size` and `value` changes instant and snaps running ones at the next `update`. Fades still run.

### Enter and exit

An element whose `transition` lists a property that its style's `hidden` block sets is shown and hidden through that property.

- **Enter.** The element enters when it is laid out with no entry: those properties start at their hidden values and run to their targets. That is a list item at a position the list did not have, an element whose `visible` binding turns true and every element of a document that `set_visible(document, true)` shows. The first `update` after `load_document`, `reload_document` or `load_styles` enters nothing.
- **Exit.** The element exits when it was laid out in the previous `update` and is not laid out now, and its parent is laid out now or it is a document root: a `visible` binding turned false, its list lost a position, or `set_visible(document, false)` hid its document. `unload_document` exits nothing. An element with no such property disappears at once.
- **Lists.** List items are keyed by position, so only the last position of a list exits and only an item added at the end enters. Removing an item from the middle shifts the later items up and fades out the old last position, which shows the former last item.
- **Snapshot.** An exiting element leaves the flow at once and draws as a floating snapshot of its last frame until each of those properties reaches its hidden value. It takes no hover, press or click and calls no getter. An element laid out again while exiting retargets and does not enter again. A snapshot counts against `max_instances`, `text_bytes` and `max_text_pieces`.
- Under reduced motion an exit whose properties are all motion ends at once. `load_document`, `reload_document`, `unload_document`, `load_styles` and an `update` that faults end every exit at once.

## Text templates and markup

`"text": "Squad ({squad.size}): {squad.gold:0} gold"` inserts bindings into a label's text, a text field's `placeholder` and span text.

- `{name}` inserts a BOOL, INT, FLOAT or TEXT binding; `{{` and `}}` insert braces. An IMAGE or LIST binding faults `BINDING_KIND_MISMATCH`.
- INT prints as decimal. FLOAT prints with up to 2 decimals, trailing zeros and the point trimmed. `{name:N}` prints an INT or FLOAT with N fixed decimals, N from 0 to 6. BOOL prints `true` or `false`.
- Text that expands to invalid UTF-8 faults `c3d::INVALID_ARGUMENT` in `update`.
- Other keys write a binding as a whole string in braces: `"enabled": "{member.alive}"`, `"image": "{member.portrait}"`. A string without braces in `image` is an asset key.

`"markup": true` turns on span tags in a label's `text`: `"[title]Wave 3[/title] holds. Press [key] E [/key] to [warn]open[/warn]."`

- `[name]` opens a span and `[/name]` closes it; `name` is a style of the set. A span style may set only `font`, `font_size`, `text_color`, `underline` and `text_highlight`, in its base and its state blocks, which apply with the label's state. A span overrides the label's own properties for the text it covers.
- Spans nest up to `UI_SPAN_DEPTH` (4), with at most `UI_MAX_SPANS` (16) per label.
- `[[` inserts `[` and a lone `]` is literal. Any other `[` sequence faults. Without `"markup": true`, brackets are literal; `markup` on any other kind faults `UNKNOWN_PROPERTY`. A value inserted by `{name}` is never read as markup.
- Malformed text faults at the label's `text`: `c3d::ASSET_FORMAT_ERROR` for an unclosed span, a close tag that matches no open span, a malformed tag, nesting past `UI_SPAN_DEPTH` or more than `UI_MAX_SPANS` spans; `UNKNOWN_STYLE` for a name that is no style; `UNKNOWN_PROPERTY` for a span style that sets another property. `load_styles` re-resolves every span name with the same faults, atomically, and names the document.

## Text layout

[Text](text.md) owns font loading, line placement and the limits of shaping. The UI adds these rules.

- A style's `font` lists up to four fonts. Each line splits where an earlier font lacks a glyph; each run uses one font and kerning does not cross runs. Text wraps at spaces and newlines only, so CJK text without spaces wraps only at authored newlines.
- Placements of unchanged lines come from a fixed cache keyed by font list and line bytes (`UiDesc.cache_lines`, `cache_glyphs`). A full cache clears and refills, counted in `ui.stats.placement_clears`.
- A label with spans lays its text out itself. Each run that shares its spans resolves its properties (the label's, then each enclosing span's, outermost first). Breaks fall at spaces and newlines, also across span boundaries, and never inside a word: `wrap: words` breaks at both, `newlines` only at newlines and `none` never breaks. A line is as tall as its tallest run, or `line_height` when the label sets one, and all runs on a line share one baseline.
- A rich label wraps at its fixed `width`, or at `max_width` when its width is not fixed, and at nothing else: it never wraps against the width a `grow` or percent panel gives it. Give a rich label in such a panel a `max_width`. It sizes its `fit` width and height to the text it laid out.
- Each run on each line is one piece; `UiDesc.max_text_pieces` bounds the pieces of a frame and `ui.stats.text_pieces` counts them. A label without spans uses none.
- A focused text field owns an edit buffer of `UiDesc.field_bytes`, seeded from `value` on focus. Backspace, Delete, Left, Right, Home and End work per code point, Ctrl+V pastes, Return fires `on_submit` and Escape blurs. There is no selection and no IME preedit display.

## Bindings and actions

### Names

Binding, action and id names are dotted lowercase identifiers: letters `a` to `z`, digits and `_` in non-empty segments separated by single dots. Duplicate names fault `c3d::INVALID_ARGUMENT`.

### Binding kinds

| `UiValueKind` | Field types exposed by `@bind_fields` | `UiValue` field |
| --- | --- | --- |
| `BOOL` | `bool` | `boolean` |
| `INT` | signed and unsigned integers | `integer` (`long`) |
| `FLOAT` | `float`, `double` | `number` (`double`) |
| `TEXT` | `String` | `text`, borrowed until the getter's next call |
| `IMAGE` | `TextureRef` | `image` |
| `LIST` | a slice | `count` |

Any other field type is a compile error. `visible` and `enabled` take BOOL, a `bar` `value` INT or FLOAT, a `text_field` `value` TEXT, `image` IMAGE, `items` LIST, and grid `item_cell` and `item_span` INT. A getter returns the kind it registered, runs every frame for declared elements only and must not load, unload or register.

`UiScope.indices` holds the item indices of the enclosing lists, outermost first, and `depth` their count. A getter receives the scope truncated to its own list level: `indices[depth - 1]` is its item, outer indices stay readable, and root bindings get depth 0. Item bindings exist only inside their list's template. Lists nest up to `UI_SCOPE_DEPTH` (4); a deeper template faults `c3d::CAPACITY_EXCEEDED` at load.

### Registration

| Function | Purpose |
| --- | --- |
| `bind(name, kind, getter, user, list = "")` | One getter under a name. `list` names the owning LIST binding of an item binding |
| `@bind_fields(prefix, $Type, instance, $fields = {})` | The fields of one struct instance as `prefix.<field>` |
| `@bind_list(name, item, $Type, items, $fields = {})` | A slice of structs as the LIST `name` and `item.<field>` per item. `items` points to the slice, read on every update |
| `@bind_items(name, item, $Type, count, item_at, user, list = "", $fields = {})` | A list through callbacks, for nested lists or containers that are not slices. `list` names the enclosing list when this list is itself an item of another |
| `on(action, handler, user)` | An action handler under a name |

Without a name list, the macros expose the fields tagged `"ui"`: `@tag("ui", true)` exposes a field under its own name and `@tag("ui", "coins")` under another. A name list (`{ "gold" }`) exposes the named fields of a struct you cannot tag. Registration may happen at any time; a loaded document keeps the names it resolved.

### Actions

A handler is `fn void (void* user, UiScope* scope, UiEvent* event)`. It runs inside `route_input` with the scope of the element that fired and must not load, unload or register. `event.text` is borrowed during the handler.

| Key | `UiEventKind` | Fires |
| --- | --- | --- |
| `on_click` | `CLICK` | Left press and release on the same element |
| `on_secondary_click` | `SECONDARY_CLICK` | Right press and release on the same element |
| `on_change` | `CHANGE` | Each edit of a focused text field. `event.text` is the field text |
| `on_submit` | `SUBMIT` | Return in a focused text field, which then blurs. `event.text` is the field text |
| `on_drop` | `DROP` | A grid item released over the element. `event.source` and `event.source_list` name the item, `event.cell` the target grid cell (`UI_NO_CELL` outside a grid) |
| `on_move_start` | `MOVE_START` | A window drag began. `event.offset` is the window's offset |
| `on_move_end` | `MOVE_END` | A window drag was released. `event.offset` is the final offset. Escape and a disappearing window cancel without it |

## Public state

`ui.wants_text_input` is true while a text field is focused. `ui.stats` (`UiStats`) holds `instances`, `getter_calls`, `text_bytes`, `placement_hits`, `placement_misses`, `placement_clears`, `text_pieces`, `transitions` and `exiting` for the last update and draw. `ui.load_error_document` names the document a failed `load_styles` could not re-resolve, else it is zero. `update` requires `scale > 0` and a finite, non-negative `delta_seconds`.

## Capacities

| `UiDesc` field | Default | Holds |
| --- | --- | --- |
| `max_documents` | 16 | Loaded documents |
| `max_styles` | 256 | Styles of one set, across its sheets |
| `max_font_sets` | 64 | Distinct font lists; never released |
| `max_bindings` | 1,024 | Registered bindings |
| `max_actions` | 256 | Registered actions |
| `max_item_sources` | 64 | `@bind_items` registrations |
| `name_bytes` | 32 KiB | Binding and action names |
| `max_instances` | 4,096 | Elements laid out per frame |
| `text_bytes` | 64 KiB | Expanded text per frame |
| `cache_lines` | 2,048 | Placement cache entries |
| `cache_glyphs` | 32,768 | Placements the cache holds |
| `field_bytes` | 256 | The focused field's edit buffer |
| `max_windows` | 64 | Window elements across the loaded documents. Zero holds none |
| `max_text_pieces` | 1,024 | Rich label pieces per frame. Zero holds none |
| `max_transitions` | 128 | Elements holding transition state. Zero holds none and keeps no exit buffers |

- Every table is allocated once in `create_ui`; documents and style sets allocate once when they load. Nothing allocates per frame.
- A transition entry is 452 bytes and the table has two slots per entry, so the default 128 entries take 113 KiB of the `create_ui` storage.
- A non-zero `max_transitions` also keeps the previous update's instance, link, text and rich-text piece tables, sized by `max_instances`, `text_bytes` and `max_text_pieces`, so that a removed element can exit. With `max_transitions` 0 none of it is allocated.
- A load or reload whose windows do not fit the table faults `c3d::CAPACITY_EXCEEDED` and changes nothing. A frame that overflows `max_instances`, `text_bytes` or `max_text_pieces` faults in `update`, draws nothing, and the next frame retries. Padding and gaps clamp to 65,535 layout units.

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `UI_SCOPE_DEPTH` | 4 | List nesting a binding scope records |
| `UI_FONT_FALLBACKS` | 4 | Fonts one style may list |
| `UI_NO_CELL` | `uint::max` | `UiEvent.cell` of a drop outside any grid |
| `UI_WHEEL_STEP` | 4 | Layout units one wheel notch scrolls, before Clay's scaling by 10 |
| `UI_DRAG_THRESHOLD` | 4 | Pointer travel in layout units that turns a press on a grid item or window handle into a drag |
| `UI_SPAN_DEPTH` | 4 | Span nesting a rich label may open |
| `UI_MAX_SPANS` | 16 | Spans one rich label may open |

## Faults

Loading faults name the failing value with an RFC 6901 JSON pointer, read with `ui.load_error_path()`, for example `/root/children/1/template/style`. For `load_styles` the pointer starts with the sheet index (`/1/title/extends`). When a loaded document no longer resolves against the new set, `ui.load_error_document` names it and the pointer points into it. The standard parser reports no line or column for syntax errors; the error path is then empty.

| Fault | Meaning |
| --- | --- |
| `UNKNOWN_ELEMENT_KIND` | `kind` names no element kind, or is missing |
| `UNKNOWN_PROPERTY` | A key the document, element kind, style, state block or `transition` does not take; a span style that sets a property other than the five of a span |
| `UNKNOWN_STYLE` | `style`, `extends` or a span tag names no style of the set |
| `STYLE_CYCLE` | An `extends` chain returns to a style it left; the pointer is the closing `extends` |
| `UNKNOWN_BINDING` | A binding no registration provides in that scope |
| `BINDING_KIND_MISMATCH` | A binding of a kind the key does not take |
| `UNKNOWN_ACTION` | An action nothing registered with `Ui.on` |
| `UNKNOWN_ASSET` | An image, skin or font key the store lacks; a text element without a font |
| `c3d::ASSET_FORMAT_ERROR` | A value of the wrong JSON type or out of range, including a `transition` without `properties` or `duration`; an `id` that is not a valid name, repeats or collides; a `window` without an `id`, on the root, in a template or under a parent that is not a `panel` or `scroll`; a `tooltip` as the root or in a template; a `grid` without `columns`, `rows` or a positive `cell_size`; malformed span markup |
| `c3d::CAPACITY_EXCEEDED` | A UI table full, including the window table and the font sets; lists nested deeper than `UI_SCOPE_DEPTH`; a frame past its instance, text or piece capacity |
| `c3d::INVALID_ARGUMENT` | A zero required capacity in `create_ui`; a duplicate or malformed binding or action name; text that is not UTF-8; a layout error reported by Clay; `window_offset` or `set_window_offset` with an id that names no window |
| `c3d::INVALID_ID` | A dead document id |
| `json::*`, `io::EOF` | Syntax errors from `std::encoding::json` |

## See also

- [UI guide](ui.md), [overlay list](overlay.md), [text](text.md), [GUI overlay](gui.md), [platform](platform.md).
