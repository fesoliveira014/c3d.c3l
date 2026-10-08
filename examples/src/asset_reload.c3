module asset_reload_example;

import std::io;
import std::io::file;
import std::math;
import std::time;
import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;

const String RELOAD_DIRECTORY @local = "../assets/reload";
const String SCENE_FILE @local = "../assets/reload/scene.gltf";
const String PANEL_FILE @local = "../assets/reload/panel.png";
const String PANEL_KEY @local = "reload/panel";
const double POLL_INTERVAL_SECONDS @local = 0.5; // one stat per file per half second; keeps the loop free of file I/O
const uint DISC_SLOW_SEGMENTS @local = 16;
const uint DISC_FAST_SEGMENTS @local = 64;
const float DISC_RADIUS @local = 0.7f;
const float DISC_THICKNESS @local = 0.1f;
const float CAMERA_DISTANCE @local = 9;

struct Watched @local {
    String path;
    Time   seen;
}

struct Variant @local {
    String file;
    String label;
}

fn Time modified_or_zero(String path) @local {
    return file::last_modified(path) ?? (Time)0;
}

fn bool has_changed(Watched* watched) @local {
    return modified_or_zero(watched.path) != watched.seen;
}

fn void report_model(String label, fault failure, ModelReplaceReport report) @local {
    if (failure) {
        io::printfn("%s: %s; keeping the previous content", label, failure);
        return;
    }
    io::printfn(
        "%s: replaced %d, added %d, missing %d",
        label,
        report.replaced,
        report.added,
        report.missing,
    );
}

fn void reload_scene_file(AssetStore* assets, ModelId model, Watched* watched) @local {
    watched.seen = modified_or_zero(watched.path);
    ModelReplaceReport? report = gltf::replace_model(assets, model, SCENE_FILE);
    report_model(watched.path, @catch(report), report ?? (ModelReplaceReport){});
}

fn void apply_variant(AssetStore* assets, ModelId model, Variant variant) @local {
    @pool() {
        String path = (String)path::tnew(RELOAD_DIRECTORY)!!.tappend(variant.file)!!;
        char[]? bytes = file::load_temp(path);
        if (catch excuse = bytes) {
            io::printfn("%s: %s", variant.label, excuse);
            return;
        }
        ModelReplaceReport? report = gltf::replace_model_memory(
            assets:   assets,
            model:    model,
            bytes:    bytes,
            base_dir: RELOAD_DIRECTORY,
            key:      SCENE_FILE,
        );
        report_model(variant.label, @catch(report), report ?? (ModelReplaceReport){});
    };
}

fn void reload_panel(AssetStore* assets, TextureId panel, Watched* watched) @local {
    watched.seen = modified_or_zero(watched.path);
    Image? decoded = image::load_image(mem, PANEL_FILE);
    if (catch excuse = decoded) {
        io::printfn("%s: %s; keeping the previous texture", PANEL_FILE, excuse);
        return;
    }
    defer image::destroy_image(&decoded);
    TextureDesc desc = material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB);
    if (catch excuse = assets.replace_texture(panel, desc, decoded.pixels)) {
        io::printfn("%s: %s; keeping the previous texture", PANEL_FILE, excuse);
        return;
    }
    io::printfn("%s: replaced, revision %d", PANEL_FILE, assets.texture(panel).header.revision);
}

fn void toggle_disc(AssetStore* assets, GeometryId disc, bool* fine) @local {
    *fine = !*fine;
    @pool() {
        Geometry next = geometry::cylinder(
            allocator:     tmem,
            radius_top:    DISC_RADIUS,
            radius_bottom: DISC_RADIUS,
            height:        DISC_THICKNESS,
            slices:        *fine ? DISC_FAST_SEGMENTS : DISC_SLOW_SEGMENTS,
        );
        if (catch excuse = assets.replace_geometry(disc, &next)) {
            io::printfn("disc: %s; keeping the previous geometry", excuse);
            return;
        }
    };
    GeometryAsset* record = assets.geometry(disc);
    io::printfn("disc: %d vertices, revision %d", record.vertex_count, record.header.revision);
}

fn void toggle_material(AssetStore* assets, MaterialId target, bool* physical) @local {
    *physical = !*physical;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.9f, 0.5f, 0.2f, 1 };
    params.roughness = 0.4f;
    params.metallic = 0;
    if (*physical) {
        PhysicalParams advanced = material::PHYSICAL_PARAMS_DEFAULT;
        advanced.standard = params;
        assets.replace_material(target, material::physical(advanced));
    } else {
        assets.replace_material(target, material::standard(params));
    }
    io::printfn(
        "disc material: %s, revision %d",
        *physical ? "PHYSICAL" : "STANDARD",
        assets.material(target).header.revision,
    );
}

fn Node* add_panel(
    Scene* scene,
    AssetStore* assets,
    GeometryId quad,
    TextureId panel,
    Vec3 position,
    String name,
) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = 0.8f;
    params.base_color_map = material::texture_slot(panel);
    MaterialId panel_material = assets.add_material(material::standard(params))!!;
    Node* node = scene.add_mesh(quad, panel_material, name: name)!!;
    node.local.position = position;
    return node;
}

fn int main() {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    ModelId? loaded = gltf::load_model(&assets, SCENE_FILE);
    if (catch excuse = loaded) {
        io::printfn("%s: %s; run from examples/build so ../assets resolves", SCENE_FILE, excuse);
        return 1;
    }
    ModelId model = loaded;

    Image panel_image = image::load_image(mem, PANEL_FILE)!!;
    defer image::destroy_image(&panel_image);
    TextureId panel = assets.add_texture(
        material::texture_2d_desc(panel_image.width, panel_image.height, RGBA8_SRGB),
        panel_image.pixels,
        PANEL_KEY,
    )!!;

    GeometryId quad;
    GeometryId disc;
    @pool() {
        Geometry quad_geometry = geometry::plane(tmem, 1.6f, 1.6f);
        quad = assets.add_geometry(&quad_geometry)!!;
        Geometry disc_geometry = geometry::cylinder(
            allocator:     tmem,
            radius_top:    DISC_RADIUS,
            radius_bottom: DISC_RADIUS,
            height:        DISC_THICKNESS,
            slices:        DISC_SLOW_SEGMENTS,
        );
        disc = assets.add_geometry(&disc_geometry)!!;
    };
    StandardParams disc_params = material::STANDARD_PARAMS_DEFAULT;
    disc_params.base_color = { 0.9f, 0.5f, 0.2f, 1 };
    disc_params.metallic = 0;
    disc_params.roughness = 0.4f;
    MaterialId disc_material = assets.add_material(material::standard(disc_params))!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* first = model::instantiate(&assets, &scene, model, name: "first")!!;
    first.local.position = { -3.5f, 0.8f, 0 };
    Node* second;
    Node* panel_a = add_panel(&scene, &assets, quad, panel, { 1.5f, 1, 0 }, "panel_a");
    panel_a.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    Node* panel_b = add_panel(&scene, &assets, quad, panel, { 3.5f, 1, 0 }, "panel_b");
    panel_b.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    Node* disc_node = scene.add_mesh(disc, disc_material, name: "disc")!!;
    disc_node.local.position = { 2.5f, -1.5f, 0 };
    disc_node.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);

    Node* sun = scene.add_light(light::directional({ 1, 0.97f, 0.9f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.2f, -0.3f, -1 }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.4f;
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 0, CAMERA_DISTANCE };
    scene.update_world();

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d asset reload", 1280, 720))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_asset_reload" },
    )!!;
    defer render::destroy_renderer(&renderer);
    renderer.prepare_scene(&scene)!!;

    Watched scene_watch = { .path = SCENE_FILE, .seen = modified_or_zero(SCENE_FILE) };
    Watched panel_watch = { .path = PANEL_FILE, .seen = modified_or_zero(PANEL_FILE) };
    Variant[3] variants = {
        { .file = "scene_content.gltf", .label = "content variant" },
        { .file = "scene_structural.gltf", .label = "structural variant" },
        { .file = "scene_broken.gltf", .label = "broken variant" },
    };
    io::printn("Edit examples/assets/reload/scene.gltf or panel.png and save: the scene reloads; R forces a reload");
    io::printn("1 content, 2 structural, 3 broken variant of the scene; G toggles the disc detail, M its material");
    io::printn("Escape release quits");

    bool fine_disc;
    bool physical_disc;
    double next_poll = POLL_INTERVAL_SECONDS;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE)) break;

        bool forced = input.key_pressed(platform::Scancode.R);
        if (window.clock.total >= next_poll || forced) {
            next_poll = window.clock.total + POLL_INTERVAL_SECONDS;
            if (forced || has_changed(&scene_watch)) {
                reload_scene_file(&assets, model, &scene_watch);
                if (!second) {
                    second = model::instantiate(&assets, &scene, model, name: "second")!!;
                    second.local.position = { -3.5f, -2.2f, 0 };
                }
            }
            if (forced || has_changed(&panel_watch)) reload_panel(&assets, panel, &panel_watch);
        }
        foreach (usz index, variant : variants) {
            platform::Scancode key = (platform::Scancode)((usz)platform::Scancode.CODE_1 + index);
            if (input.key_pressed(key)) apply_variant(&assets, model, variant);
        }
        if (input.key_pressed(platform::Scancode.G)) toggle_disc(&assets, disc, &fine_disc);
        if (input.key_pressed(platform::Scancode.M)) toggle_material(&assets, disc_material, &physical_disc);

        scene.update_world();
        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
    }

    return 0;
}
