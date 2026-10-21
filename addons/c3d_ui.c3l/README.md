# Game UI add-on

`c3d_ui` draws game interfaces from data. Applications describe a screen in a JSONC document: an element tree, styles with single inheritance, data bindings and named actions. Code registers every name a document may read or trigger. Each frame the add-on lays the visible documents out with [Clay](https://github.com/nicbarker/clay), routes pointer and text input against the previous frame's layout, and appends rectangles and glyph runs to an overlay list. Layout, skins and styles are data that mods can edit without code; behavior stays in code.

Use it for HUDs, menus, inventories and dialogs. Dear ImGui stays the tool for debug panels and draws on top.

## Boundaries

- Module `c3d::ui` imports the standard library, core (`c3d`, including `c3d::render` for the overlay list and `c3d::platform` for input and events) and `clay`.
- It never imports `gpu`, `sdl`, `imgui` or another add-on, and creates no GPU object.
- Core never imports it and has no flag for it; selecting the library is the gate.

## Select the package

List `c3d_ui` and `clay` next to `c3d` and core's dependencies in `project.json`. The [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names.

## Quick start

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

```c3
String styles = (String)$embed("ui/styles.jsonc"); // $embed yields bytes: cast to String
String document = (String)$embed("ui/hud.jsonc");

Ui ui = ui::create_ui(mem, &assets, ui::default_ui_desc())!;
defer ui::destroy_ui(&ui);
ui.@bind_fields("hud", Hud, &game.hud)!;       // Hud fields tagged @tag("ui", true)
ui.on("game.start", &start_game, &game)!;
ui.load_styles({ styles })!;                    // fonts the styles name are in the store
UiDocumentId hud = ui.load_document(document)!;

// every frame
ui.route_input(&window.input, window.events()); // actions fire here
ui.update(
    width:         window.width,
    height:        window.height,
    scale:         window.pixel_density,
    delta_seconds: window.clock.delta,
)!;
list.clear();
ui.draw(&list)!;                                // then prepare and draw the overlay list
```

The [UI guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/ui.md) shows the complete frame loop, the ImGui input contract, windows, bindings and transitions.

## Tests and example

| Target | Kind |
| --- | --- |
| `ui_test` | CPU tests; no device |
| `ui_acceptance` | Manual Vulkan acceptance in `test/gpu`; not part of CI |
| `ui` | Example: a HUD and an inventory with drag and drop; `--windows`, `--rich-text` and `--transitions` add windows, rich text and transitions |

```bash
c3c test ui_test --path addons/c3d_ui.c3l
python3 scripts/build.py --example ui
```

## Documentation

- [UI guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/ui.md) and [UI reference](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/ui_reference.md)
- [Overlay list](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/overlay.md) and [text](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/text.md)
- [GUI overlay](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/gui.md) and [platform input](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/platform.md)
