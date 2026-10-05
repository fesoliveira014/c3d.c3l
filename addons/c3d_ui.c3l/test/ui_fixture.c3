module c3d::ui::fixture;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::platform;
import c3d::render;
import c3d::ui;
import clay;
import std::collections::list;
import std::math;

const String TEXT_SHEET = `{ "text": { "font": ["ui/latin", "ui/cjk"], "font_size": 10 } }`;

const usz RECORDED_TEXT = 64;

const FontDesc TEST_FONT_DESC = {
    .max_glyphs   = 256,
    .curve_texels = 4 * asset::FONT_TEXTURE_WIDTH,
    .band_texels  = 16 * asset::FONT_TEXTURE_WIDTH,
};

struct Member {
    String name @tag("ui", true);
    float  health @tag("ui", true);
    bool   alive @tag("ui", true);
    int    level;
}

struct Recorder {
    uint        calls;
    UiEventKind kind;
    UiScope     scope;
    UiScope     source;
    String      source_list;
    uint        cell;
    char[RECORDED_TEXT] text_bytes;
    usz         text_len;
}

struct Fixture {
    AssetStore  assets;
    Ui          ui;
    OverlayList list;
    Input       input;
    FontId      latin;
    FontId      cjk;
    TextureId   icon;
    Member[3]   members;
    Member[]    squad;
    Recorder    recorder;
    bool        gui_mouse;      // what ImGui's new_frame would set after the poll
    bool        gui_keyboard;
    bool        gui_text_input;
    float       wheel;          // notches the poll would report this frame
}

fn String Recorder.text(&self) => (String)self.text_bytes[:self.text_len];

fn void record_action(void* user, UiScope* scope, UiEvent* event) {
    Recorder* recorder = user;
    recorder.calls++;
    recorder.kind = event.kind;
    recorder.scope = *scope;
    recorder.source = event.source;
    recorder.source_list = event.source_list;
    recorder.cell = event.cell;
    recorder.text_len = event.text.len > RECORDED_TEXT ? RECORDED_TEXT : event.text.len;
    recorder.text_bytes[:recorder.text_len] = event.text[:recorder.text_len];
}

fn void create_fixture(
    Fixture* fixture,
    UiDesc desc = ui::default_ui_desc(),
    OverlayListDesc list_desc = render::default_overlay_list_desc(),
) {
    *fixture = {};
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.latin = fixture.assets.add_font(
        file: $embed("../../../test/fixtures/fonts/latin.ttf"),
        desc: TEST_FONT_DESC,
        key:  "ui/latin",
    )!!;
    fixture.cjk = fixture.assets.add_font(
        file: $embed("../../../test/fixtures/fonts/cjk.otf"),
        desc: TEST_FONT_DESC,
        key:  "ui/cjk",
    )!!;
    char[4 * 4 * 4] pixels;
    fixture.icon = fixture.assets.add_texture(material::texture_2d_desc(4, 4, RGBA8_SRGB), pixels[..], "icons/sword")!!;
    fixture.ui = ui::create_ui(mem, &fixture.assets, desc)!!;
    fixture.list = render::create_overlay_list(mem, list_desc);
    fixture.ui.load_styles({ TEXT_SHEET })!!;
    fixture.members = {
        { .name = "Beep", .health = 0.75, .alive = true },
        { .name = "Hob", .health = 0.25, .alive = false },
        { .name = "Ruka", .health = 1, .alive = true },
    };
    fixture.squad = fixture.members[..];
}

fn void destroy_fixture(Fixture* fixture) {
    render::destroy_overlay_list(&fixture.list);
    ui::destroy_ui(&fixture.ui);
    asset::destroy_asset_store(&fixture.assets);
}

fn void register_squad(Fixture* fixture) {
    fixture.ui.@bind_list(
        name:  "squad.members",
        item:  "member",
        $Type: Member,
        items: &fixture.squad,
    )!!;
    fixture.ui.on("squad.select", &record_action, &fixture.recorder)!!;
}

fn void frame(Fixture* fixture, Event[] events = {}, float scale = 1) {
    fixture.input.begin_frame();
    fixture.input.mouse_captured_by_gui = fixture.gui_mouse;
    fixture.input.keyboard_captured_by_gui = fixture.gui_keyboard;
    fixture.input.text_input_wanted_by_gui = fixture.gui_text_input;
    fixture.input.wheel = fixture.wheel;
    fixture.ui.route_input(&fixture.input, events);
    fixture.ui.update(800, 600, scale)!!;
    fixture.list.clear();
    fixture.ui.draw(&fixture.list)!!;
}

fn void point(Fixture* fixture, Vec2 at, bool held = false) {
    fixture.input.mouse_position = at;
    fixture.input.mouse_buttons[(usz)MouseButton.LEFT] = held;
}

fn Event button_down(Vec2 at, MouseButton button = LEFT) {
    return { .kind = MOUSE_BUTTON_DOWN, .button = button, .position = at };
}

fn Event button_up(Vec2 at, MouseButton button = LEFT) => { .kind = MOUSE_BUTTON_UP, .button = button, .position = at };

fn Event motion(Vec2 at) => { .kind = MOUSE_MOTION, .position = at };

fn Event key(Scancode scancode) => { .kind = KEY_DOWN, .scancode = scancode };

fn Event typed(String text) => { .kind = TEXT_INPUT, .text = text };

fn void click(Fixture* fixture, Vec2 at, MouseButton button = LEFT) {
    point(fixture, at);
    frame(fixture, { button_down(at, button), button_up(at, button) });
}

fn String[] text_lines(Fixture* fixture) {
    List{String} lines;
    lines.tinit();
    foreach (command : fixture.ui.commands.commands()) {
        if (command.command_type == TEXT) lines.push(command.render_data.text.string_contents.str().tcopy());
    }
    return lines.array_view();
}

fn bool has_line(Fixture* fixture, String line) {
    foreach (candidate : text_lines(fixture)) {
        if (candidate == line) return true;
    }
    return false;
}

fn void expect_load_fault(
    Fixture* fixture,
    String document,
    fault expected,
    String path,
) {
    if (catch excuse = fixture.ui.load_document(document)) {
        assert(excuse == expected, "fault %s, expected %s", excuse, expected);
        assert(fixture.ui.load_error_path() == path, "path '%s', expected '%s'", fixture.ui.load_error_path(), path);
        return;
    }
    unreachable("document loaded");
}

fn void expect_styles_fault(
    Fixture* fixture,
    String[] sheets,
    fault expected,
    String path,
) {
    if (catch excuse = fixture.ui.load_styles(sheets)) {
        assert(excuse == expected, "fault %s, expected %s", excuse, expected);
        assert(fixture.ui.load_error_path() == path, "path '%s', expected '%s'", fixture.ui.load_error_path(), path);
        return;
    }
    unreachable("styles loaded");
}

fn Vec4 srgb(uint rgba) => {
    (float)((rgba >> 24) & 0xff) / 255,
    (float)((rgba >> 16) & 0xff) / 255,
    (float)((rgba >> 8) & 0xff) / 255,
    (float)(rgba & 0xff) / 255,
};
