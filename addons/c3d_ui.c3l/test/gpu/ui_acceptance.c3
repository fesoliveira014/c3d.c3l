module c3d::ui::ui_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::ui;
import gpu;

const uint FRAMES @private = 3;
const uint LIST_ITEMS @private = 8192;
const uint LIST_GLYPHS @private = 16384;
const uint PORTRAIT_SIZE @private = 64;
const uint PORTRAIT_LAYER @private = 2;

struct Member @private {
    String               name @tag("ui", true);
    material::TextureRef portrait @tag("ui", true);
    int                  hit_points @tag("ui", "hp");
    int                  max_hp @tag("ui", true);
    float                health @tag("ui", true);
    bool                 selected @tag("ui", true);
}

struct Item @private {
    String               name @tag("ui", true);
    String               description @tag("ui", "tip");
    material::TextureRef icon @tag("ui", true);
    int                  cell @tag("ui", true);
    int                  width @tag("ui", true);
    int                  height @tag("ui", true);
}

struct Hud @private {
    String status @tag("ui", true);
    String selected @tag("ui", true);
    int    member_count @tag("ui", true);
    bool   can_heal @tag("ui", true);
    bool   can_damage @tag("ui", true);
}

fn void ignore_action(void* user, UiScope* scope, UiEvent* event) @private {}

fn void check_validation(Renderer* renderer) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        assert(!(entry.category.backend && entry.category.validation
            && entry.severity == gpu::DebugMessageSeverity.ERROR));
    }
}

fn void test_documents_draw_with_a_render_target_portrait() @test {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d ui acceptance", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_ui_acceptance" },
    )!!;
    defer render::destroy_renderer(&renderer);

    assets.add_font(
        file: $embed("../../../../examples/assets/fonts/NotoSans-Regular.ttf"),
        desc: asset::default_font_desc(),
        key:  "ui/latin",
    )!!;
    assets.add_font(
        file: $embed("../../../../examples/assets/fonts/NotoSansCJKsc-Regular-GB2312-L1.otf"),
        desc: asset::default_font_desc(),
        key:  "ui/cjk",
    )!!;
    char[4 * 4 * 4] pixels;
    TextureId icon = assets.add_texture(material::texture_2d_desc(4, 4, RGBA8_SRGB), pixels[..], "icons/test")!!;

    GeometryId box;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, 1.6f, 1.6f, 1.6f);
        box = assets.add_geometry(&box_geometry, "ui/box")!!;
    };
    MaterialId cube_material = assets.add_material(material::basic({ .color = { 0.2f, 0.7f, 0.9f, 1 } }), "ui/cube")!!;
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 0, 5 };
    scene.get(camera_node, camera::Camera).layers = camera::ALL_LAYERS & ~PORTRAIT_LAYER;
    Node* portrait_camera = scene.add_camera(camera::perspective_deg(40, 0.1f), name: "portrait")!!;
    portrait_camera.local.position = { 0, 0, 5 };
    scene.get(portrait_camera, camera::Camera).layers = PORTRAIT_LAYER;
    Node* cube = scene.add_mesh(box, cube_material, name: "cube")!!;
    cube.layers = PORTRAIT_LAYER;
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    RenderTargetId portrait = render::create_render_target(
        &renderer,
        render::render_target_desc(PORTRAIT_SIZE, PORTRAIT_SIZE, material::PixelFormat.RGBA8_SRGB),
    )!!;
    defer (void)render::destroy_render_target(&renderer, portrait);
    ViewId portrait_view = render::create_view(
        &renderer,
        render::texture_view_desc(portrait, OutputMode.DISPLAY_LDR),
    )!!;
    defer (void)render::destroy_view(&renderer, portrait_view);

    Ui ui = ui::create_ui(mem, &assets, ui::default_ui_desc())!!;
    defer ui::destroy_ui(&ui);
    OverlayList list = render::create_overlay_list(mem, {
        .max_items  = LIST_ITEMS,
        .max_clips  = render::OVERLAY_LIST_DEFAULT_CLIPS,
        .max_glyphs = LIST_GLYPHS,
    });
    defer render::destroy_overlay_list(&list);

    Member[2] members = {
        { .name = "Beep", .portrait = { .kind = RENDER_TARGET, .target = portrait }, .hit_points = 50, .max_hp = 100,
          .health = 0.5f, .selected = true },
        { .name = "李雷", .portrait = { .kind = ASSET, .asset = icon }, .hit_points = 100, .max_hp = 100, .health = 1 },
    };
    Member[] member_view = members[..];
    Item[2] stash = {
        { .name = "Potion", .description = "Restores health", .icon = { .kind = ASSET, .asset = icon },
          .cell = 0, .width = 1, .height = 1 },
        { .name = "Shield", .description = "Heavy and sturdy", .icon = { .kind = ASSET, .asset = icon },
          .cell = 6, .width = 2, .height = 2 },
    };
    Item[] stash_view = stash[..];
    Item[] bag_view = stash[:1];
    Hud hud = { .status = "Ready", .selected = "Beep", .member_count = 2, .can_heal = true, .can_damage = true };

    ui.@bind_list(name: "squad.members", item: "member", $Type: Member, items: &member_view)!!;
    ui.@bind_list(name: "stash.items", item: "stash_item", $Type: Item, items: &stash_view)!!;
    ui.@bind_list(name: "bag.items", item: "bag_item", $Type: Item, items: &bag_view)!!;
    ui.@bind_fields(prefix: "hud", $Type: Hud, instance: &hud)!!;
    String[8] actions = {
        "squad.select", "squad.heal", "squad.damage", "squad.rename",
        "inventory.drop_stash", "inventory.drop_bag", "inventory.use_stash", "inventory.use_bag",
    };
    foreach (action : actions) ui.on(action, &ignore_action, null)!!;

    char[] styles = $embed("../../examples/ui/hud.styles.jsonc");
    char[] hud_document = $embed("../../examples/ui/hud.jsonc");
    char[] inventory_document = $embed("../../examples/ui/inventory.jsonc");
    ui.load_styles({ (String)styles })!!;
    ui.load_document((String)hud_document)!!;
    ui.load_document((String)inventory_document)!!;

    uint overlay_draws;
    for (uint frame = 0; frame < FRAMES; frame++) {
        window.poll();
        platform::sync_window(&window, &renderer);
        window.input.clear_gui_flags();
        ui.route_input(&window.input, window.events());
        ui.update(window.width, window.height, window.pixel_density)!!;
        list.clear();
        ui.draw(&list)!!;
        assert(list.item_count > 0);

        renderer.begin_frame({ .time = window.clock.total, .delta = window.clock.delta })!!;
        renderer.render_view(&scene, portrait_camera, portrait_view)!!;
        renderer.finish_view(portrait_view)!!;
        renderer.render_view(&scene, camera_node, renderer.default_view)!!;
        renderer.finish_view(renderer.default_view)!!;
        renderer.prepare_overlay_list(&list)!!;
        OverlayContext overlay = renderer.begin_overlay()!!;
        uint draws_before = renderer.stats.draws;
        overlay.draw_list(&list)!!;
        overlay_draws += renderer.stats.draws - draws_before;
        renderer.end_overlay(&overlay)!!;
        renderer.end_frame()!!;
    }
    assert(overlay_draws > 0);
    check_validation(&renderer);
}
