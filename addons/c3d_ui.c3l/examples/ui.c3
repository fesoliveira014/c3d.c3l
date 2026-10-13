module ui_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::ui;
import imgui;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint MEMBER_COUNT @local = 4;
const uint MEMBER_NAME_BYTES @local = 48;
const uint ITEM_CAPACITY @local = 24;
const uint STASH_COLUMNS @local = 6; // mirrored by "columns" and "rows" in inventory.jsonc
const uint STASH_ROWS @local = 4;
const uint BAG_COLUMNS @local = 6;
const uint BAG_ROWS @local = 4;
const uint STATUS_BYTES @local = 96;
const int NO_ITEM @local = -1;
const int POTION_HEAL @local = 30;
const int RATION_HEAL @local = 10;
const int DAMAGE_STEP @local = 15;
const int HEAL_STEP @local = 15;

const uint PORTRAIT_TEXTURE_SIZE @local = 32;
const uint ICON_TEXTURE_SIZE @local = 16;
const uint LIVE_PORTRAIT_SIZE @local = 128;
const uint LIVE_PORTRAIT_LAYER @local = 2; // only the portrait camera draws the cube
const float PORTRAIT_SPIN_RADIANS_PER_SECOND @local = 1.1f;
const float CUBE_SIZE @local = 1.6f;
const float BACKDROP_RADIUS @local = 1.2f;
const float CAMERA_DISTANCE @local = 5;
const Vec4 CUBE_COLOR @local = { 0.2f, 0.7f, 0.9f, 1 };
const Vec4 BACKDROP_COLOR @local = { 0.25f, 0.3f, 0.5f, 1 };

const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const uint LIST_ITEMS @local = 8192;
const uint LIST_GLYPHS @local = 16384;
const Vec2 STATS_PANEL_POSITION @local = { 360, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 260, 150 };

const uint LOG_LINES @local = 40;
const uint LOG_LINE_BYTES @local = 16;
const uint LOG_WHEEL_FRAME @local = 10;
const uint LOG_RELOAD_FRAME @local = 20;
const float LOG_WHEEL_NOTCHES @local = -3; // negative scrolls toward later lines
const float LOG_POINTER_FROM_RIGHT @local = 136; // inside the log's scroll area, in layout units
const float LOG_POINTER_Y @local = 120;
const float FIXED_STEP_SECONDS @local = 1.0f / 60; // bounded runs step by this, so frame N is reproducible
const uint SCHEDULE_TICKS_PER_SECOND @local = 60; // a bounded run ticks once per frame
const uint TOAST_FIRST_TICK @local = 100;
const uint TOAST_BEAT_TICKS @local = 120; // the toast shows, then hides, every two seconds
const uint ROW_BEAT_TICKS @local = 180;   // the last member row leaves, then returns, every three seconds

const uint WINDOW_SCRIPT_EVENTS @local = 2; // a motion and a button release in the same frame
const Vec2 STATS_PANEL_TRANSITIONS_SIZE @local = { 260, 186 }; // two more lines

const int RICH_GOLD @local = 1250;
const float RICH_GEMS @local = 3.5f;

const uint BENCHMARK_ROWS @local = 50;
const uint DEFAULT_BENCHMARK_FRAMES @local = 100;
const uint BENCHMARK_WIDTH @local = 1920;
const uint BENCHMARK_HEIGHT @local = 1080;
const uint BENCHMARK_CLICK_PERIOD @local = 8; // frames between synthetic clicks
const uint BENCHMARK_VALUE_STEPS @local = 100; // distinct formatted values: the placement cache sees hits and misses
const double NANOSECONDS_PER_MILLISECOND @local = 1000000;
const String[6] BENCHMARK_NAMES @local = { "Alder", "Birch", "Cedar", "李雷", "Elm", "Fir" };

const uint BENCHMARK_WINDOW_FRAME_ELEMENTS @local = 5; // window, title bar, title, close button and its label
const uint BENCHMARK_WINDOW_LINES @local = 15; // body labels
const uint BENCHMARK_WINDOW_ELEMENTS @local = BENCHMARK_WINDOW_FRAME_ELEMENTS + BENCHMARK_WINDOW_LINES;
const uint BENCHMARK_WINDOW_COLUMNS @local = 4;
const uint BENCHMARK_WINDOW_ROWS @local = 3; // further windows stack on the first ones
const uint BENCHMARK_WINDOW_STEP_X @local = 240; // layout units between window positions
const uint BENCHMARK_WINDOW_STEP_Y @local = 340;
const uint BENCHMARK_DRAG_PERIOD @local = 32; // frames per cycle: the drag, then the HUD sweep
const uint BENCHMARK_DRAG_FRAMES @local = 16; // a press, 14 motions and a release
const float BENCHMARK_DRAG_DISTANCE @local = 200;
const Vec2 BENCHMARK_DRAG_GRAB @local = { 950, 10 }; // on the first window's title bar: the desk starts at x 920
const uint BENCHMARK_LINE_BYTES @local = 16; // text bytes and cached glyphs reserved per label or cached line
const uint BENCHMARK_RICH_RUNS @local = 12; // pieces and cached lines reserved per rich label
const uint BENCHMARK_RICH_TEXT_BYTES @local = 160; // expanded text reserved per rich label
const uint BENCHMARK_EXIT_PERIOD @local = 30; // frames between two removals; the row returns half a period later

const String BENCHMARK_STYLES @local = `{
  "bench_text": { "font": ["ui/latin", "ui/cjk"], "font_size": 14, "text_color": "#e0e0e0ff" },
  "bench_row": { "direction": "row", "gap": 6, "height": 18, "align": ["left", "center"] },
  "bench_panel": { "fill": "#101216dd", "padding": 6, "direction": "column", "gap": 2 },
  "bench_marker": { "fill": "#f2c96bff", "size": [4, 14] },
  "bench_bar": { "fill": "#3a1010ff", "bar_fill": "#4cc45aff", "size": [80, 8] },
  "bench_button": { "fill": "#2b2b2bff", "padding": [6, 1], "hover": { "fill": "#3a3a3aff" } },
  "bench_spacer": { "width": "grow" },
  "bench_fading_row": {
    "extends": "bench_row",
    "transition": { "properties": ["fill", "opacity", "offset"], "duration": 0.15, "easing": "ease_out" },
    "hover": { "fill": "#2c313dff" },
    "hidden": { "opacity": 0, "offset": [-24, 0] }
  },
  "key": { "text_color": "#ffffffff", "text_highlight": "#3b4a6bff" },
  "warn": { "text_color": "#ff8a6bff", "underline": true },
  "gold": { "text_color": "#f2c96bff", "font_size": 18 },
  "bench_desk": { "size": [1000, 1080] },
  "bench_window": { "fill": "#1b1e27ff", "direction": "column", "size": [220, 320] },
  "bench_title": { "fill": "#2c3550ff", "padding": [6, 2], "gap": 6, "width": "grow", "align": ["left", "center"] }
}`;

const String BENCHMARK_ROW_OPEN @local = `{ "kind": "panel", "style": "bench_row",`;
const String BENCHMARK_FADING_ROW_OPEN @local = `{ "kind": "panel", "style": "bench_fading_row",
  "on_click": "bench.bump",`;

const String BENCHMARK_ROW_CHILDREN @local = `
  "children": [
    { "kind": "panel", "style": "bench_marker", "visible": "{row.alive}" },
    { "kind": "label", "style": "bench_text", "text": "{row.name}" },
    { "kind": "label", "style": "bench_text", "text": "HP" },
    { "kind": "label", "style": "bench_text", "text": "{row.value:1}" },
    { "kind": "bar", "style": "bench_bar", "value": "{row.fraction}" },
    { "kind": "button", "style": "bench_button", "on_click": "bench.bump", "children": [
      { "kind": "label", "style": "bench_text", "text": "+" } ] },
    { "kind": "panel", "style": "bench_spacer" },
    { "kind": "label", "style": "bench_text", "text": "x" }
  ]
}`;

const String BENCHMARK_RICH_LABEL @local = `{ "kind": "label", "style": "bench_text", "markup": true, "width": 200,
  "text": "Quest %d: press [key] E [/key] at the gate. [warn]Low ammo[/warn], [gold]{bench.score}[/gold] gold." }`;

const String BENCHMARK_WINDOW_OPEN @local = `{ "kind": "panel", "id": "window%d", "window": true,
  "style": "bench_window", "position": [%d, %d], "on_move_end": "bench.moved", "children": [
    { "kind": "panel", "style": "bench_title", "drag_handle": true, "children": [
      { "kind": "label", "style": "bench_text", "width": "grow", "text": "Window" },
      { "kind": "button", "style": "bench_button", "children": [
        { "kind": "label", "style": "bench_text", "text": "x" } ] } ] }`;
const String BENCHMARK_WINDOW_LINE @local = `{ "kind": "label", "style": "bench_text", "text": "%s" }`;

struct Options @local {
    bool benchmark;
    bool reload_scroll;
    bool windows;
    bool rich_text;
    bool transitions;
    bool reduced_motion;
    uint frames;
    uint labels;
    uint window_count;
    uint rich_labels;
}

struct Item @local {
    String               name @tag("ui", true);
    String               description @tag("ui", "tip");
    material::TextureRef icon @tag("ui", true);
    int                  cell @tag("ui", true);
    int                  width @tag("ui", true);
    int                  height @tag("ui", true);
    int                  heal;
}

struct Inventory @local {
    Item[ITEM_CAPACITY] items;
    uint                count;
    uint                columns;
    uint                rows;
}

struct Member @local {
    char[MEMBER_NAME_BYTES] name_bytes;
    String                  name @tag("ui", true);
    material::TextureRef    portrait @tag("ui", true);
    int                     hit_points @tag("ui", "hp");
    int                     max_hp @tag("ui", true);
    float                   health @tag("ui", true);
    bool                    selected @tag("ui", true);
    Inventory               bag;
}

struct LogLine @local {
    char[LOG_LINE_BYTES] bytes;
    String               text @tag("ui", true);
}

struct Hud @local {
    String status @tag("ui", true);
    String selected @tag("ui", true);
    int    member_count @tag("ui", true);
    bool   can_heal @tag("ui", true);
    bool   can_damage @tag("ui", true);
}

struct Desk @local {
    bool inspector_open @tag("ui", true);
    bool notes_open @tag("ui", true);
}

struct Loot @local {
    int   gold @tag("ui", true);
    float gems @tag("ui", true);
}

struct Toast @local {
    bool shown @tag("ui", true);
}

struct ScriptedDrag @local {
    uint press_frame;
    uint release_frame;
    Vec2 from;          // layout units
    Vec2 to;
}

// Layout units at 1280 x 720, calibrated to windows.jsonc: drag the inspector, raise the notes, drag the palette.
const ScriptedDrag[3] WINDOW_SCRIPT @local = {
    { .press_frame = 10, .release_frame = 20, .from = { 402, 446 }, .to = { 482, 462 } },
    { .press_frame = 30, .release_frame = 32, .from = { 702, 516 }, .to = { 702, 516 } },
    { .press_frame = 40, .release_frame = 55, .from = { 497, 518 }, .to = { 877, 518 } },
};

enum ScriptedAction @local {
    MOVE,
    PRESS,
    RELEASE,
}

struct ScriptedStep @local {
    uint           frame;
    ScriptedAction action;
    Vec2           at;     // layout units
}

// Layout units at 1280 x 720: hover the lift card, press and release Damage, then hover the second member's row.
const ScriptedStep[5] TRANSITION_SCRIPT @local = {
    { .frame = 10, .action = MOVE, .at = { 500, 660 } },
    { .frame = 40, .action = MOVE, .at = { 150, 353 } },
    { .frame = 44, .action = PRESS, .at = { 150, 353 } },
    { .frame = 52, .action = RELEASE, .at = { 150, 353 } },
    { .frame = 80, .action = MOVE, .at = { 150, 160 } },
};

struct Icons @local {
    material::TextureRef potion;
    material::TextureRef ration;
    material::TextureRef sword;
    material::TextureRef shield;
    material::TextureRef bow;
}

struct DocumentSource @local {
    String       file;
    UiDocumentId id;
}

struct DropTarget @local {
    Demo* demo;
    bool  bag;
}

struct Demo @local {
    platform::Window* window;
    Renderer*         renderer;
    Scene*            scene;
    Ui*               ui;
    OverlayList*      list;
    Node*             camera_node;
    Node*             portrait_camera;
    Node*             cube;
    ViewId            portrait_view;
    Member[MEMBER_COUNT] members;
    Member[]          members_view;
    Inventory         stash;
    Item[]            stash_view;
    Item[]            bag_view;
    Hud               hud;
    Icons             icons;
    uint              selected;
    char[STATUS_BYTES] status_bytes;
    DropTarget        stash_target;
    DropTarget        bag_target;
    DocumentSource[2] documents;
    LogLine[LOG_LINES] log;
    LogLine[]         log_view;
    UiDocumentId      log_document;
    bool              reload_scroll;
    bool              windows;
    bool              transitions;
    bool              reduced_motion;
    Vec2              script_pointer;
    bool              script_down;
    Desk              desk;
    Loot              loot;
    Toast             toast;
    bool              toast_loaded;
    uint              member_rows;
    Event[WINDOW_SCRIPT_EVENTS] script_events;
    bool              drew_list;
}

struct BenchmarkRow @local {
    String name @tag("ui", true);
    float  value @tag("ui", true);
    float  fraction @tag("ui", true);
    bool   alive @tag("ui", true);
}

struct Benchmark @local {
    BenchmarkRow[BENCHMARK_ROWS] rows;
    BenchmarkRow[]               view;
    int                          score @tag("ui", true);
    uint                         moves;
}

fn void? add_fonts(AssetStore* assets) @local {
    assets.add_font(
        file: $embed("../../../examples/assets/fonts/NotoSans-Regular.ttf"),
        desc: asset::default_font_desc(),
        key:  "ui/latin",
    )!;
    assets.add_font(
        file: $embed("../../../examples/assets/fonts/NotoSansCJKsc-Regular-GB2312-L1.otf"),
        desc: asset::default_font_desc(),
        key:  "ui/cjk",
    )!;
}

fn material::TextureRef? add_swatch(
    AssetStore* assets,
    String key,
    uint size,
    char[3] color,
    bool portrait,
) @local {
    char[] pixels = mem::new_array(char, (usz)size * size * 4);
    defer mem::free(pixels);
    float half = (float)size / 2;
    for (uint y = 0; y < size; y++) {
        for (uint x = 0; x < size; x++) {
            float dx = (float)x + 0.5f - half;
            float head_dy = (float)y + 0.5f - (float)size * 0.4f;
            float body_dy = (float)y + 0.5f - (float)size;
            float head = math::sqrt(dx * dx + head_dy * head_dy);
            float body = math::sqrt(dx * dx / 2.2f + body_dy * body_dy);
            bool border = x == 0 || y == 0 || x == size - 1 || y == size - 1;
            bool inside = portrait ? (head < (float)size * 0.22f || body < (float)size * 0.42f) : !border;
            char[3] shade = inside ? color : (char[3]){ color[0] / 4, color[1] / 4, color[2] / 4 };
            pixels[(y * size + x) * 4 + 0] = shade[0];
            pixels[(y * size + x) * 4 + 1] = shade[1];
            pixels[(y * size + x) * 4 + 2] = shade[2];
            pixels[(y * size + x) * 4 + 3] = 255;
        }
    }
    TextureId texture = assets.add_texture(material::texture_2d_desc(size, size, RGBA8_SRGB), pixels, key)!;
    return { .kind = ASSET, .asset = texture };
}

fn Icons? add_icons(AssetStore* assets) @local {
    return {
        .potion = add_swatch(
            assets:   assets,
            key:      "icons/potion",
            size:     ICON_TEXTURE_SIZE,
            color:    { 200, 50, 60 },
            portrait: false,
        )!,
        .ration = add_swatch(
            assets:   assets,
            key:      "icons/ration",
            size:     ICON_TEXTURE_SIZE,
            color:    { 210, 140, 60 },
            portrait: false,
        )!,
        .sword  = add_swatch(
            assets:   assets,
            key:      "icons/sword",
            size:     ICON_TEXTURE_SIZE,
            color:    { 170, 175, 185 },
            portrait: false,
        )!,
        .shield = add_swatch(
            assets:   assets,
            key:      "icons/shield",
            size:     ICON_TEXTURE_SIZE,
            color:    { 70, 110, 190 },
            portrait: false,
        )!,
        .bow    = add_swatch(
            assets:   assets,
            key:      "icons/bow",
            size:     ICON_TEXTURE_SIZE,
            color:    { 90, 170, 90 },
            portrait: false,
        )!,
    };
}

fn void set_name(Member* member, String name) @local {
    usz length = math::min((usz)name.len, (usz)member.name_bytes.len);
    member.name_bytes[:length] = name[:length];
    member.name = (String)member.name_bytes[:length];
}

fn void set_status(Demo* demo, String text) @local {
    usz length = math::min((usz)text.len, (usz)demo.status_bytes.len);
    demo.status_bytes[:length] = text[:length];
    demo.hud.status = (String)demo.status_bytes[:length];
}

fn void add_item(Inventory* inventory, Item item) @local {
    inventory.items[inventory.count] = item;
    inventory.count++;
}

fn void sync_member(Member* member) @local {
    member.health = member.max_hp ? (float)member.hit_points / (float)member.max_hp : 0;
}

fn void refresh_views(Demo* demo) @local {
    demo.members_view = demo.members[:demo.member_rows];
    demo.stash_view = demo.stash.items[:demo.stash.count];
    Inventory* bag = &demo.members[demo.selected].bag;
    demo.bag_view = bag.items[:bag.count];
}

fn void refresh_hud(Demo* demo) @local {
    Member* member = &demo.members[demo.selected];
    demo.hud.selected = member.name;
    demo.hud.member_count = (int)demo.member_rows;
    demo.hud.can_heal = member.hit_points < member.max_hp;
    demo.hud.can_damage = member.hit_points > 0;
}

fn void select_member(Demo* demo, uint index) @local {
    demo.selected = index;
    foreach (member_index, &member : demo.members) member.selected = member_index == index;
    refresh_views(demo);
    refresh_hud(demo);
}

fn bool cells_overlap(Item* first, Item* second, uint columns) @local {
    uint first_column = (uint)first.cell % columns;
    uint first_row = (uint)first.cell / columns;
    uint second_column = (uint)second.cell % columns;
    uint second_row = (uint)second.cell / columns;
    bool apart_x = first_column + (uint)first.width <= second_column
        || second_column + (uint)second.width <= first_column;
    bool apart_y = first_row + (uint)first.height <= second_row
        || second_row + (uint)second.height <= first_row;
    return !apart_x && !apart_y;
}

fn bool fits(Inventory* inventory, Item* item, uint ignored) @local {
    if (item.cell < 0) return false;
    uint column = (uint)item.cell % inventory.columns;
    uint row = (uint)item.cell / inventory.columns;
    if (column + (uint)item.width > inventory.columns || row + (uint)item.height > inventory.rows) return false;
    for (uint index = 0; index < inventory.count; index++) {
        if (index == ignored) continue;
        if (cells_overlap(item, &inventory.items[index], inventory.columns)) return false;
    }
    return true;
}

fn void remove_item(Inventory* inventory, uint index) @local {
    for (uint next = index + 1; next < inventory.count; next++) inventory.items[next - 1] = inventory.items[next];
    inventory.count--;
}

fn Inventory* source_inventory(Demo* demo, String list) @local {
    return list == "stash.items" ? &demo.stash : &demo.members[demo.selected].bag;
}

fn void on_select(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    select_member(demo, scope.indices[0]);
}

fn void on_heal(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    Member* member = &demo.members[demo.selected];
    member.hit_points = math::min(member.hit_points + HEAL_STEP, member.max_hp);
    sync_member(member);
    refresh_hud(demo);
}

fn void on_damage(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    Member* member = &demo.members[demo.selected];
    member.hit_points = math::max(member.hit_points - DAMAGE_STEP, 0);
    sync_member(member);
    refresh_hud(demo);
}

fn void on_rename(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    if (!event.text.len || event.text.len > MEMBER_NAME_BYTES) return;
    set_name(&demo.members[demo.selected], event.text);
    refresh_hud(demo);
}

fn void on_drop(void* user, UiScope* scope, UiEvent* event) @local {
    DropTarget* target = user;
    Demo* demo = target.demo;
    if (event.cell == ui::UI_NO_CELL) return;

    Inventory* source = source_inventory(demo, event.source_list);
    Inventory* destination = target.bag ? &demo.members[demo.selected].bag : &demo.stash;
    uint index = event.source.indices[0];
    Item item = source.items[index];
    item.cell = (int)event.cell;
    uint ignored = source == destination ? index : (uint)ITEM_CAPACITY;
    if (!fits(destination, &item, ignored)) return;

    if (source == destination) {
        destination.items[index] = item;
    } else {
        remove_item(source, index);
        add_item(destination, item);
    }
    refresh_views(demo);
}

fn void use_item(Demo* demo, Inventory* inventory, uint index) @local {
    @pool() {
        Member* member = &demo.members[demo.selected];
        Item item = inventory.items[index];
        if (item.heal == 0) {
            set_status(demo, string::tformat("%s has no use", item.name));
        } else if (member.hit_points >= member.max_hp) {
            set_status(demo, string::tformat("%s is at full health", member.name));
        } else {
            member.hit_points = math::min(member.hit_points + item.heal, member.max_hp);
            sync_member(member);
            remove_item(inventory, index);
            set_status(demo, string::tformat("%s used %s", member.name, item.name));
        }
    };
    refresh_views(demo);
    refresh_hud(demo);
}

fn void on_use_stash(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    use_item(demo, &demo.stash, scope.indices[0]);
}

fn void on_use_bag(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    use_item(demo, &demo.members[demo.selected].bag, scope.indices[0]);
}

fn void? create_squad(Demo* demo, AssetStore* assets, RenderTargetId portrait) @local {
    demo.icons = add_icons(assets)!;
    String[MEMBER_COUNT] names = { "Beep", "Hob", "Ruka", "李雷" };
    char[3][MEMBER_COUNT] tints = { { 0, 0, 0 }, { 200, 110, 90 }, { 90, 170, 120 }, { 190, 160, 80 } };
    foreach (index, &member : demo.members) {
        set_name(member, names[index]);
        member.max_hp = 100;
        member.hit_points = 100 - (int)index * 20;
        sync_member(member);
        member.bag.columns = BAG_COLUMNS;
        member.bag.rows = BAG_ROWS;
        if (index == 0) {
            member.portrait = { .kind = RENDER_TARGET, .target = portrait };
        } else {
            member.portrait = add_swatch(
                assets:   assets,
                key:      string::tformat("portraits/member_%d", index),
                size:     PORTRAIT_TEXTURE_SIZE,
                color:    tints[index],
                portrait: true,
            )!;
        }
    }
    demo.stash.columns = STASH_COLUMNS;
    demo.stash.rows = STASH_ROWS;

    Icons* icons = &demo.icons;
    add_item(&demo.stash, {
        .name        = "Potion",
        .description = "Restores 30 health",
        .icon        = icons.potion,
        .cell        = 0,
        .width       = 1,
        .height      = 1,
        .heal        = POTION_HEAL,
    });
    add_item(&demo.stash, {
        .name        = "Ration",
        .description = "Restores 10 health",
        .icon        = icons.ration,
        .cell        = 1,
        .width       = 1,
        .height      = 1,
        .heal        = RATION_HEAL,
    });
    add_item(&demo.stash, {
        .name        = "Sword",
        .description = "A plain blade",
        .icon        = icons.sword,
        .cell        = 6,
        .width       = 2,
        .height      = 1,
        .heal        = 0,
    });
    add_item(&demo.stash, {
        .name        = "Shield",
        .description = "Heavy and sturdy",
        .icon        = icons.shield,
        .cell        = 12,
        .width       = 2,
        .height      = 2,
        .heal        = 0,
    });
    add_item(&demo.stash, {
        .name        = "Bow",
        .description = "Needs arrows",
        .icon        = icons.bow,
        .cell        = 14,
        .width       = 2,
        .height      = 1,
        .heal        = 0,
    });
    add_item(&demo.stash, {
        .name        = "Potion",
        .description = "Restores 30 health",
        .icon        = icons.potion,
        .cell        = 2,
        .width       = 1,
        .height      = 1,
        .heal        = POTION_HEAL,
    });
    add_item(&demo.members[0].bag, {
        .name        = "Ration",
        .description = "Restores 10 health",
        .icon        = icons.ration,
        .cell        = 0,
        .width       = 1,
        .height      = 1,
        .heal        = RATION_HEAL,
    });
    add_item(&demo.members[1].bag, {
        .name        = "Sword",
        .description = "A plain blade",
        .icon        = icons.sword,
        .cell        = 0,
        .width       = 2,
        .height      = 1,
        .heal        = 0,
    });
    add_item(&demo.members[2].bag, {
        .name        = "Bow",
        .description = "Needs arrows",
        .icon        = icons.bow,
        .cell        = 7,
        .width       = 2,
        .height      = 1,
        .heal        = 0,
    });
    demo.stash_target = { .demo = demo, .bag = false };
    demo.bag_target = { .demo = demo, .bag = true };
    set_status(demo, "Select a member");
    select_member(demo, 0);
}

fn void? register_squad(Demo* demo) @local {
    Ui* ui = demo.ui;
    ui.@bind_list(
        name:  "squad.members",
        item:  "member",
        $Type: Member,
        items: &demo.members_view,
    )!;
    ui.@bind_list(
        name:  "stash.items",
        item:  "stash_item",
        $Type: Item,
        items: &demo.stash_view,
    )!;
    ui.@bind_list(
        name:  "bag.items",
        item:  "bag_item",
        $Type: Item,
        items: &demo.bag_view,
    )!;
    ui.@bind_fields(prefix: "hud", $Type: Hud, instance: &demo.hud)!;
    ui.on("squad.select", &on_select, demo)!;
    ui.on("squad.heal", &on_heal, demo)!;
    ui.on("squad.damage", &on_damage, demo)!;
    ui.on("squad.rename", &on_rename, demo)!;
    ui.on("inventory.drop_stash", &on_drop, &demo.stash_target)!;
    ui.on("inventory.drop_bag", &on_drop, &demo.bag_target)!;
    ui.on("inventory.use_stash", &on_use_stash, demo)!;
    ui.on("inventory.use_bag", &on_use_bag, demo)!;
}

fn void? load_embedded(Demo* demo) @local {
    Ui* ui = demo.ui;
    char[] styles = $embed("ui/hud.styles.jsonc");
    char[] hud = $embed("ui/hud.jsonc");
    char[] inventory = $embed("ui/inventory.jsonc");
    ui.load_styles({ (String)styles })!;
    demo.documents[0] = { .file = "hud.jsonc", .id = ui.load_document((String)hud)! };
    demo.documents[1] = { .file = "inventory.jsonc", .id = ui.load_document((String)inventory)! };
}

fn void? load_log(Demo* demo) @local {
    Ui* ui = demo.ui;
    foreach (number, &line : demo.log) {
        line.text = string::bformat(line.bytes[..], "Entry %d", number + 1);
    }

    demo.log_view = demo.log[..];

    ui.@bind_list(
        name:  "log.lines",
        item:  "log_line",
        $Type: LogLine,
        items: &demo.log_view,
    )!;

    char[] document = $embed("ui/log.jsonc");
    demo.log_document = ui.load_document((String)document)!;
}

fn void? replay_log(Demo* demo, uint frame) @local {
    platform::Window* window = demo.window;

    if (frame == LOG_WHEEL_FRAME) {
        window.input.mouse_position = {
            (float)window.width - LOG_POINTER_FROM_RIGHT * window.pixel_density,
            LOG_POINTER_Y * window.pixel_density,
        };
        window.input.wheel = LOG_WHEEL_NOTCHES;
    }

    if (frame == LOG_RELOAD_FRAME) {
        char[] titled = $embed("ui/log_titled.jsonc");
        demo.ui.reload_document(demo.log_document, (String)titled)!;
    }
}

fn void on_window_moved(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    @pool() {
        set_status(demo, string::tformat("Moved a window to %d, %d", (int)event.offset.x, (int)event.offset.y));
    };
}

fn void on_close_inspector(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    demo.desk.inspector_open = false;
}

fn void on_close_notes(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    demo.desk.notes_open = false;
}

fn void on_reset_windows(void* user, UiScope* scope, UiEvent* event) @local {
    Demo* demo = user;
    demo.desk = { .inspector_open = true, .notes_open = true };
}

fn void? load_windows(Demo* demo) @local {
    Ui* ui = demo.ui;
    demo.desk = { .inspector_open = true, .notes_open = true };
    ui.@bind_fields(prefix: "desk", $Type: Desk, instance: &demo.desk)!;
    ui.on("windows.moved", &on_window_moved, demo)!;
    ui.on("windows.close_inspector", &on_close_inspector, demo)!;
    ui.on("windows.close_notes", &on_close_notes, demo)!;
    ui.on("windows.reset", &on_reset_windows, demo)!;

    char[] document = $embed("ui/windows.jsonc");
    ui.load_document((String)document)!;
}

fn void? load_rich_text(Demo* demo) @local {
    Ui* ui = demo.ui;
    demo.loot = { .gold = RICH_GOLD, .gems = RICH_GEMS };
    ui.@bind_fields(prefix: "loot", $Type: Loot, instance: &demo.loot)!;

    char[] document = $embed("ui/rich.jsonc");
    ui.load_document((String)document)!;
}

fn void? load_transitions(Demo* demo) @local {
    char[] document = $embed("ui/transitions.jsonc");
    demo.ui.load_document((String)document)!;
    demo.ui.@bind_fields(prefix: "toast", $Type: Toast, instance: &demo.toast)!;
}

fn void animate_transitions(Demo* demo, uint tick) @local {
    // The toast document loads one update before it first shows, so that its first update is not an entry.
    if (!demo.toast_loaded && tick + 1 >= TOAST_FIRST_TICK) {
        char[] document = $embed("ui/toast.jsonc");
        demo.ui.load_document((String)document)!!;
        demo.toast_loaded = true;
    }

    demo.toast.shown = tick >= TOAST_FIRST_TICK && ((tick - TOAST_FIRST_TICK) / TOAST_BEAT_TICKS) % 2 == 0;
    demo.member_rows = (tick / ROW_BEAT_TICKS) % 2 == 1 ? MEMBER_COUNT - 1 : MEMBER_COUNT;
    refresh_views(demo);
}

fn Event[] replay_transitions(Demo* demo, uint frame) @local {
    uint count;
    foreach (&step : TRANSITION_SCRIPT) {
        if (step.frame != frame) continue;

        demo.script_pointer = step.at * demo.window.pixel_density;
        Vec2 at = demo.script_pointer;

        switch (step.action) {
            case MOVE:
                demo.script_events[count++] = { .kind = MOUSE_MOTION, .position = at };
            case PRESS:
                demo.script_down = true;
                demo.script_events[count++] = { .kind = MOUSE_MOTION, .position = at };
                demo.script_events[count++] = { .kind = MOUSE_BUTTON_DOWN, .button = LEFT, .position = at };
            case RELEASE:
                demo.script_down = false;
                demo.script_events[count++] = { .kind = MOUSE_BUTTON_UP, .button = LEFT, .position = at };
        }
    }

    Input* input = &demo.window.input;
    input.mouse_position = demo.script_pointer;
    input.mouse_buttons[(usz)platform::MouseButton.LEFT] = demo.script_down;

    return demo.script_events[:count];
}

fn Event[] replay_windows(Demo* demo, uint frame) @local {
    Input* input = &demo.window.input;
    uint count;
    foreach (&drag : WINDOW_SCRIPT) {
        if (frame < drag.press_frame || frame > drag.release_frame) continue;

        float progress = (float)(frame - drag.press_frame) / (float)(drag.release_frame - drag.press_frame);
        Vec2 at = (drag.from + (drag.to - drag.from) * progress) * demo.window.pixel_density;
        input.mouse_position = at;
        input.mouse_buttons[(usz)platform::MouseButton.LEFT] = frame != drag.release_frame;

        if (frame == drag.press_frame) {
            demo.script_events[count++] = { .kind = MOUSE_BUTTON_DOWN, .button = LEFT, .position = at };
            continue;
        }

        demo.script_events[count++] = { .kind = MOUSE_MOTION, .position = at };
        if (frame == drag.release_frame) {
            demo.script_events[count++] = { .kind = MOUSE_BUTTON_UP, .button = LEFT, .position = at };
        }
    }

    return demo.script_events[:count];
}

fn String source_directory() @local {
    String path = $$FILEPATH;
    usz end = path.len;
    while (end > 0 && path[end - 1] != '/' && path[end - 1] != '\\') end--;
    return string::tformat("%sui/", path[:end]);
}

fn void report_reload_fault(Ui* ui, String file, fault excuse) @local {
    io::eprintfn("Reload of %s failed: %s at '%s'; the previous UI stays.", file, excuse, ui.load_error_path());
}

fn void reload_from_disk(Demo* demo) @local {
    Ui* ui = demo.ui;
    @pool() {
        String directory = source_directory();
        String styles_path = string::tformat("%shud.styles.jsonc", directory);
        char[]? styles = file::load_temp(styles_path);
        if (catch excuse = styles) {
            io::eprintfn("Cannot read %s: %s", styles_path, excuse);
            return;
        }
        if (catch excuse = ui.load_styles({ (String)styles })) {
            report_reload_fault(ui, "hud.styles.jsonc", excuse);
            return;
        }
        bool reloaded = true;
        foreach (&source : demo.documents) {
            String path = string::tformat("%s%s", directory, source.file);
            char[]? text = file::load_temp(path);
            if (catch excuse = text) {
                io::eprintfn("Cannot read %s: %s", path, excuse);
                reloaded = false;
                continue;
            }
            if (catch excuse = ui.reload_document(source.id, (String)text)) {
                report_reload_fault(ui, source.file, excuse);
                reloaded = false;
            }
        }
        if (reloaded) io::printfn("Reloaded the documents and styles from %s", directory);
    };
}

fn void animate(Demo* demo, float time) @local {
    Quat spin = quaternion::from_axis_angle{float}({ 0, 1, 0 }, time * PORTRAIT_SPIN_RADIANS_PER_SECOND);
    Quat tilt = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.5f);
    demo.cube.local.rotation = spin.mul(tilt).normalize();
    demo.scene.update_world();
}

fn void? draw_frame(Demo* demo, GuiRenderer* gui_renderer, FrameInfo info) @local {
    Renderer* renderer = demo.renderer;
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(demo.scene, demo.portrait_camera, demo.portrait_view)!;
        renderer.finish_view(demo.portrait_view)!;
        renderer.render_view(demo.scene, demo.camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        demo.drew_list = true;
        if (catch excuse = renderer.prepare_overlay_list(demo.list)) {
            bool reference_fault = excuse == c3d::INVALID_ID
                || excuse == c3d::INVALID_ARGUMENT
                || excuse == c3d::UNSUPPORTED;
            if (!reference_fault) return excuse~;
            io::eprintfn("The UI list was skipped for this frame: %s", excuse);
            demo.drew_list = false;
        }

        OverlayContext overlay = renderer.begin_overlay()!;
        if (demo.drew_list) overlay.draw_list(demo.list)!;
        if (gui_renderer) gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void? run_interactive(Demo* demo, uint frame_limit) @local {
    platform::Window* window = demo.window;
    Renderer* renderer = demo.renderer;
    Ui* ui = demo.ui;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    uint frames;
    bool escape_captured;
    while (window.poll()) {
        if (frame_limit && frames >= frame_limit) break;

        gui_renderer.new_frame();
        defer if (gui_renderer.frame_open) gui_renderer.finish_frame();

        if (demo.reload_scroll) replay_log(demo, frames)!;

        Event[] events = window.events();
        if (demo.windows && frame_limit) events = replay_windows(demo, frames);
        if (demo.transitions && frame_limit) events = replay_transitions(demo, frames);

        Input* input = &window.input;
        // A field blurs and a window drag cancels on Escape down, so the release that follows must not quit.
        bool typing = ui.wants_text_input || input.keyboard_captured_by_gui;
        ui.route_input(input, events);
        if (input.key_pressed(platform::Scancode.ESCAPE)) escape_captured = typing || input.keyboard_captured_by_gui;
        if (input.key_released(platform::Scancode.ESCAPE)) {
            if (!escape_captured && !typing) break;
            escape_captured = false;
        }

        if (!input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.F5)) {
            reload_from_disk(demo);
        }

        if (!input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.M)) {
            demo.reduced_motion = !demo.reduced_motion;
            ui.set_reduced_motion(demo.reduced_motion);
        }

        animate(demo, (float)window.clock.total);
        platform::sync_window(window, renderer);
        if (demo.transitions) {
            animate_transitions(demo, frame_limit ? frames : (uint)(window.clock.total * SCHEDULE_TICKS_PER_SECOND));
        }

        refresh_hud(demo);

        bool drawable = renderer.output_width && renderer.output_height;
        if (drawable) {
            ui.update(
                width:         window.width,
                height:        window.height,
                scale:         window.pixel_density,
                delta_seconds: frame_limit ? FIXED_STEP_SECONDS : window.clock.delta,
            )!;
        }

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(
            demo.transitions ? STATS_PANEL_TRANSITIONS_SIZE : STATS_PANEL_SIZE,
            imgui::COND_FIRST_USE_EVER,
        );
        if (imgui::begin("UI", null, {})) {
            imgui::text("Instances: %u", ui.stats.instances);
            imgui::text("Getter calls: %u", ui.stats.getter_calls);
            imgui::text("Text bytes: %u", ui.stats.text_bytes);
            imgui::text("Placement hits: %u", ui.stats.placement_hits);
            imgui::text("Placement misses: %u", ui.stats.placement_misses);
            imgui::text("Overlay items: %u glyphs: %u", demo.list.item_count, demo.list.glyph_count);
            if (demo.transitions) {
                imgui::text("Transitions running: %u", ui.stats.transitions);
                imgui::text("Reduced motion (M): %s", demo.reduced_motion ? "on" : "off");
            }
        }
        imgui::end();
        gui_renderer.finish_frame();

        if (drawable) {
            demo.list.clear();
            ui.draw(demo.list)!;
            draw_frame(
                demo:         demo,
                gui_renderer: &gui_renderer,
                info:         { .time = window.clock.total, .delta = window.clock.delta },
            )!;
        }
        frames++;
    }
}

fn void benchmark_bump(void* user, UiScope* scope, UiEvent* event) @local {
    Benchmark* benchmark = user;
    benchmark.rows[scope.indices[0]].value += 0.5f;
}

fn void benchmark_moved(void* user, UiScope* scope, UiEvent* event) @local {
    Benchmark* benchmark = user;
    benchmark.moves++;
}

fn String benchmark_hud_document(bool fading) @local {
    DString document = dstring::temp_with_capacity(2048);
    document.append_string(`{ "anchor": "top_left", "root": { "kind": "scroll", "style": "bench_panel",
  "size": [900, 1080], "scroll": "vertical", "children": [
    { "kind": "list", "items": "{bench.rows}", "direction": "column", "template": `);
    document.append_string(fading ? BENCHMARK_FADING_ROW_OPEN : BENCHMARK_ROW_OPEN);
    document.append_string(BENCHMARK_ROW_CHILDREN);
    document.append_string(` } ] } }`);
    return document.str_view();
}

fn String benchmark_labels_document(uint labels) @local {
    DString document = dstring::temp_with_capacity((sz)(64 + labels * 64));
    document.append_string(`{ "anchor": "top_right", "root": { "kind": "scroll", "style": "bench_panel",
  "size": [300, 1080], "scroll": "vertical", "children": [`);
    for (uint label = 0; label < labels; label++) {
        if (label) document.append_char(',');
        document.appendf(`{ "kind": "label", "style": "bench_text", "text": "Label %d" }`, label)!!;
    }
    document.append_string(`] } }`);
    return document.str_view();
}

fn String benchmark_rich_document(uint labels) @local {
    DString document = dstring::temp_with_capacity((sz)(64 + labels * BENCHMARK_RICH_LABEL.len));
    document.append_string(`{ "anchor": "top_right", "root": { "kind": "scroll", "style": "bench_panel",
  "size": [300, 1080], "scroll": "vertical", "children": [`);
    for (uint label = 0; label < labels; label++) {
        if (label) document.append_char(',');
        document.appendf(BENCHMARK_RICH_LABEL, label)!!;
    }
    document.append_string(`] } }`);
    return document.str_view();
}

fn String benchmark_windows_document(uint windows) @local {
    DString document = dstring::temp_with_capacity((sz)(64 + windows * BENCHMARK_WINDOW_OPEN.len * 2));
    document.append_string(`{ "anchor": "top_right", "root": { "kind": "panel", "style": "bench_desk", "children": [`);
    for (uint window = 0; window < windows; window++) {
        uint column = window % BENCHMARK_WINDOW_COLUMNS;
        uint row = window / BENCHMARK_WINDOW_COLUMNS % BENCHMARK_WINDOW_ROWS;

        if (window) document.append_char(',');
        document.appendf(
            BENCHMARK_WINDOW_OPEN,
            window,
            column * BENCHMARK_WINDOW_STEP_X,
            row * BENCHMARK_WINDOW_STEP_Y,
        )!!;
        for (uint line = 0; line < BENCHMARK_WINDOW_LINES; line++) {
            document.append_char(',');
            document.appendf(BENCHMARK_WINDOW_LINE, line % 2 ? "{bench.score}" : "Stat")!!;
        }

        document.append_string(`] }`);
    }
    document.append_string(`] } }`);
    return document.str_view();
}

fn UiDesc benchmark_desc(Options* options) @local {
    UiDesc desc = ui::default_ui_desc();
    uint window_elements = options.window_count * BENCHMARK_WINDOW_ELEMENTS;
    uint rich_runs = options.rich_labels * BENCHMARK_RICH_RUNS;

    desc.max_instances += options.labels * 2 + window_elements + options.rich_labels;
    desc.text_bytes += (options.labels + window_elements) * BENCHMARK_LINE_BYTES;
    desc.text_bytes += options.rich_labels * BENCHMARK_RICH_TEXT_BYTES;
    desc.cache_lines += options.labels + window_elements + rich_runs;
    desc.cache_glyphs += (options.labels + window_elements + rich_runs) * BENCHMARK_LINE_BYTES;
    desc.max_windows = math::max(desc.max_windows, options.window_count);
    desc.max_text_pieces += rich_runs;
    return desc;
}

fn void benchmark_input(Input* input, Event[] events, uint frame, uint period, uint* count) @local {
    Vec2 pointer = {
        40 + (float)((frame * 37) % 800),
        40 + (float)((frame * 53) % 1000),
    };
    input.mouse_position = pointer;
    events[0] = { .kind = MOUSE_MOTION, .position = pointer };
    *count = 1;
    if (frame % period == 0) {
        events[1] = { .kind = MOUSE_BUTTON_DOWN, .button = LEFT, .position = pointer };
        events[2] = { .kind = MOUSE_BUTTON_UP, .button = LEFT, .position = pointer };
        *count = 3;
    }
}

fn bool benchmark_drag(Input* input, Event[] events, uint frame, uint* count) @local {
    uint phase = frame % BENCHMARK_DRAG_PERIOD;
    if (phase >= BENCHMARK_DRAG_FRAMES) return false;

    bool back = (frame / BENCHMARK_DRAG_PERIOD) % 2 == 1;
    bool release = phase == BENCHMARK_DRAG_FRAMES - 1;
    float travel = (float)phase / (float)(BENCHMARK_DRAG_FRAMES - 1) * BENCHMARK_DRAG_DISTANCE;
    Vec2 at = {
        BENCHMARK_DRAG_GRAB.x + (back ? BENCHMARK_DRAG_DISTANCE - travel : travel),
        BENCHMARK_DRAG_GRAB.y,
    };

    input.mouse_position = at;
    input.mouse_buttons[(usz)platform::MouseButton.LEFT] = !release;

    if (phase == 0) {
        events[0] = { .kind = MOUSE_BUTTON_DOWN, .button = LEFT, .position = at };
        *count = 1;
        return true;
    }

    events[0] = { .kind = MOUSE_MOTION, .position = at };
    *count = 1;
    if (release) {
        events[1] = { .kind = MOUSE_BUTTON_UP, .button = LEFT, .position = at };
        *count = 2;
    }

    return true;
}

fn uint benchmark_visible_rows(uint frame) @local {
    bool leaving = frame % BENCHMARK_EXIT_PERIOD >= BENCHMARK_EXIT_PERIOD / 2;
    return leaving ? BENCHMARK_ROWS - 1 : BENCHMARK_ROWS;
}

fn double elapsed_ms(time::Clock started) @local => (double)started.to_now() / NANOSECONDS_PER_MILLISECOND;

fn void? run_benchmark(Options* options) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    add_fonts(&assets)!;

    UiDesc desc = benchmark_desc(options);
    Ui ui = ui::create_ui(&tracker, &assets, desc)!;
    defer ui::destroy_ui(&ui);
    OverlayList list = render::create_overlay_list(&tracker, {
        .max_items  = desc.max_instances * 4,
        .max_clips  = render::OVERLAY_LIST_DEFAULT_CLIPS,
        .max_glyphs = desc.cache_glyphs,
    });
    defer render::destroy_overlay_list(&list);

    Benchmark benchmark;
    foreach (index, &row : benchmark.rows) {
        *row = {
            .name     = BENCHMARK_NAMES[index % BENCHMARK_NAMES.len],
            .value    = (float)(index % 10),
            .fraction = (float)(index % 10) / 10,
            .alive    = index % 3 != 0,
        };
    }
    benchmark.view = benchmark.rows[..];
    ui.@bind_list(
        name:  "bench.rows",
        item:  "row",
        $Type: BenchmarkRow,
        items: &benchmark.view,
    )!;
    ui.@bind_fields(prefix: "bench", $Type: Benchmark, instance: &benchmark)!;
    ui.on("bench.bump", &benchmark_bump, &benchmark)!;
    ui.on("bench.moved", &benchmark_moved, &benchmark)!;
    ui.load_styles({ BENCHMARK_STYLES })!;
    @pool() {
        ui.load_document(benchmark_hud_document(options.transitions))!;
        if (options.labels) ui.load_document(benchmark_labels_document(options.labels))!;
        if (options.rich_labels) ui.load_document(benchmark_rich_document(options.rich_labels))!;
        if (options.window_count) ui.load_document(benchmark_windows_document(options.window_count))!;
    };

    Input input;
    Event[3] events;
    double route_ms;
    double update_ms;
    double draw_ms;
    uint peak_transitions;
    uint peak_exiting;
    sz allocations_before;
    for (uint frame = 0; frame < options.frames * 2; frame++) {
        BenchmarkRow* row = &benchmark.rows[frame % BENCHMARK_ROWS];
        row.value = (float)(frame % BENCHMARK_VALUE_STEPS) / 10;
        row.fraction = (float)(frame % 10) / 10;
        benchmark.score = (int)(frame % BENCHMARK_VALUE_STEPS);
        if (options.transitions) benchmark.view = benchmark.rows[:benchmark_visible_rows(frame)];

        input.begin_frame();
        input.clear_gui_flags();

        uint event_count;
        bool dragging = options.window_count > 0 && benchmark_drag(&input, events[..], frame, &event_count);
        if (!dragging) {
            benchmark_input(
                input:  &input,
                events: events[..],
                frame:  frame,
                period: BENCHMARK_CLICK_PERIOD,
                count:  &event_count,
            );
        }

        bool measured = frame >= options.frames;
        if (frame == options.frames) {
            benchmark.moves = 0;
            allocations_before = tracker.total_allocation_count();
        }

        time::Clock started = clock::now();
        ui.route_input(&input, events[:event_count]);
        if (measured) route_ms += elapsed_ms(started);

        started = clock::now();
        ui.update(
            width:         BENCHMARK_WIDTH,
            height:        BENCHMARK_HEIGHT,
            scale:         1,
            delta_seconds: FIXED_STEP_SECONDS,
        )!;
        if (measured) update_ms += elapsed_ms(started);

        started = clock::now();
        list.clear();
        ui.draw(&list)!;
        if (measured) draw_ms += elapsed_ms(started);

        if (measured) {
            peak_transitions = math::max(peak_transitions, ui.stats.transitions);
            peak_exiting = math::max(peak_exiting, ui.stats.exiting);
        }
    }

    double frames = (double)options.frames;
    io::printfn(
        "frames=%d labels=%d windows=%d rich=%d route_ms=%.4f update_ms=%.4f draw_ms=%.4f instances=%d glyphs=%d "
        "placement_hits=%d placement_misses=%d text_pieces=%d transitions=%d exiting=%d moves=%d "
        "resident_bytes=%d allocations=%d",
        options.frames,
        options.labels,
        options.window_count,
        options.rich_labels,
        route_ms / frames,
        update_ms / frames,
        draw_ms / frames,
        ui.stats.instances,
        list.glyph_count,
        ui.stats.placement_hits,
        ui.stats.placement_misses,
        ui.stats.text_pieces,
        peak_transitions,
        peak_exiting,
        benchmark.moves,
        ui.storage.len + ui.clay_memory.len,
        tracker.total_allocation_count() - allocations_before,
    );
}

fn int main(String[] args) {
    Options options;
    bool frames_given;
    for (usz index = 1; index < args.len; index++) {
        String argument = args[index];
        bool has_value = index + 1 < args.len;
        if (argument == "--benchmark") {
            options.benchmark = true;
        } else if (argument == "--frames" && has_value) {
            options.frames = args[++index].to_uint() ?? 0;
            frames_given = true;
            if (!options.frames) return 1;
        } else if (argument == "--labels" && has_value) {
            options.labels = args[++index].to_uint() ?? 0;
        } else if (argument == "--reload-scroll") {
            options.reload_scroll = true;
        } else if (argument == "--windows") {
            options.windows = true;
            options.window_count = has_value ? (args[index + 1].to_uint() ?? 0) : 0;
            if (options.window_count) index++;
        } else if (argument == "--rich" && has_value) {
            options.rich_labels = args[++index].to_uint() ?? 0;
        } else if (argument == "--rich-text") {
            options.rich_text = true;
        } else if (argument == "--transitions") {
            options.transitions = true;
        } else if (argument == "--reduced-motion") {
            options.reduced_motion = true;
        } else {
            io::eprintn("Use ui [--frames N] [--reload-scroll] [--windows] [--rich-text] [--transitions]");
            io::eprintn("       [--reduced-motion] [--benchmark --frames F [--labels N] [--windows N] [--rich N]");
            io::eprintn("       [--transitions]].");
            return 1;
        }
    }

    if (options.benchmark) {
        if (!frames_given) options.frames = DEFAULT_BENCHMARK_FRAMES;
        if (catch excuse = run_benchmark(&options)) {
            io::eprintfn("UI benchmark failed: %s", excuse);
            return 1;
        }
        return 0;
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d ui", WINDOW_WIDTH, WINDOW_HEIGHT))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_ui" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    GeometryId ball;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "ui/box")!!;
        Geometry ball_geometry = geometry::sphere(tmem, BACKDROP_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "ui/sphere")!!;
    };
    MaterialId cube_material = assets.add_material(material::basic({ .color = CUBE_COLOR }), "ui/cube")!!;
    MaterialId backdrop_material = assets.add_material(material::basic({ .color = BACKDROP_COLOR }), "ui/backdrop")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 0, CAMERA_DISTANCE };
    scene.get(camera_node, camera::Camera).layers = camera::ALL_LAYERS & ~LIVE_PORTRAIT_LAYER;
    Node* portrait_camera = scene.add_camera(camera::perspective_deg(40, 0.1f), name: "portrait")!!;
    portrait_camera.local.position = { 0, 0, CAMERA_DISTANCE };
    scene.get(portrait_camera, camera::Camera).layers = LIVE_PORTRAIT_LAYER;
    Node* cube = scene.add_mesh(box, cube_material, name: "cube")!!;
    cube.layers = LIVE_PORTRAIT_LAYER;
    scene.add_mesh(ball, backdrop_material, name: "backdrop")!!;
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    RenderTargetId portrait = render::create_render_target(
        &renderer,
        render::render_target_desc(LIVE_PORTRAIT_SIZE, LIVE_PORTRAIT_SIZE, material::PixelFormat.RGBA8_SRGB),
    )!!;
    defer (void)render::destroy_render_target(&renderer, portrait);
    ViewId portrait_view = render::create_view(
        &renderer,
        render::texture_view_desc(portrait, OutputMode.DISPLAY_LDR),
    )!!;
    defer (void)render::destroy_view(&renderer, portrait_view);

    add_fonts(&assets)!!;
    Ui ui = ui::create_ui(mem, &assets, ui::default_ui_desc())!!;
    defer ui::destroy_ui(&ui);
    OverlayList list = render::create_overlay_list(mem, {
        .max_items  = LIST_ITEMS,
        .max_clips  = render::OVERLAY_LIST_DEFAULT_CLIPS,
        .max_glyphs = LIST_GLYPHS,
    });
    defer render::destroy_overlay_list(&list);

    Demo demo = {
        .window          = &window,
        .renderer        = &renderer,
        .scene           = &scene,
        .ui              = &ui,
        .list            = &list,
        .camera_node     = camera_node,
        .portrait_camera = portrait_camera,
        .cube            = cube,
        .portrait_view   = portrait_view,
        .reload_scroll   = options.reload_scroll,
        .windows         = options.windows,
        .transitions     = options.transitions,
        .reduced_motion  = options.reduced_motion,
        .member_rows     = MEMBER_COUNT,
    };
    create_squad(&demo, &assets, portrait)!!;
    register_squad(&demo)!!;
    load_embedded(&demo)!!;
    if (options.reload_scroll) load_log(&demo)!!;
    if (options.windows) load_windows(&demo)!!;
    if (options.rich_text) load_rich_text(&demo)!!;
    if (options.transitions) load_transitions(&demo)!!;
    ui.set_reduced_motion(options.reduced_motion);

    if (catch excuse = run_interactive(&demo, options.frames)) {
        io::eprintfn("UI example failed: %s", excuse);
        return 1;
    }
    if (catch renderer.log.check_validation()) {
        io::eprintn("Validation reported errors.");
        return 1;
    }
    return 0;
}
