module transparency_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;

const char[*] GLOW_FRAGMENT_SOURCE @local = $embed("../shaders/custom/glow.frag.glsl");
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const double STATS_PERIOD_SECONDS @local = 1.0;
const float[4] ROUGHNESS_STEPS @local = { 0, 0.25f, 0.5f, 1 };
const float GLASS_IOR @local = 1.5f;
const float GLASS_THICKNESS @local = 0.2f;
const Vec3 SLAB_SIZE @local = { 2.4f, 1.6f, 0.2f };
const Vec3 SLAB_POSITION @local = { 0, 0.9f, 0 };
const Vec3 REAR_SLAB_SIZE @local = { 1.8f, 1.2f, 0.2f };
const Vec3 REAR_SLAB_POSITION @local = { 0.8f, 1.1f, -0.7f }; // offset so the panes overlap partly on screen
const Vec4 REAR_GLASS_TINT @local = { 0.45f, 0.75f, 1, 1 };
const Vec3 BACKDROP_POSITION @local = { 0, 1, -1.5f };
const Vec3 BACKDROP_SCALE @local = { 7, 1, 4.5f };
const Vec2 BACKDROP_TILES @local = { 8, 5 };
const float PROP_RADIUS @local = 0.35f;
const float PROP_SPACING @local = 1.6f;
const float PROP_DEPTH @local = -1.1f;
const Vec3 CROSS_POSITION @local = { -3, 0.9f, 0 };
const Vec3 CROSS_QUAD_SCALE @local = { 1.8f, 1, 1.8f };
const float CROSS_QUAD_ANGLE @local = 0.6f; // radians either side of facing the camera, so the quads intersect
const Vec4 CROSS_FIRST_COLOR @local = { 0.95f, 0.2f, 0.15f, 0.55f };
const Vec4 CROSS_SECOND_COLOR @local = { 0.15f, 0.4f, 0.95f, 0.55f };
const Vec3 BATCH_POSITION @local = { 3, 0.9f, 0 };
const Vec3 BATCH_PANEL_SCALE @local = { 1.2f, 1, 1.8f };
const float BATCH_PANEL_OFFSET @local = 0.7f; // panels sit this far in front of and behind the sweeping sphere
const Vec4 BATCH_COLOR @local = { 0.2f, 0.8f, 0.35f, 0.5f };
const Vec4 SWEEP_COLOR @local = { 1, 0.6f, 0.1f, 0.6f };
const float SWEEP_AMPLITUDE @local = 0.8f;
const Vec3 GLOW_OFFSET @local = { 0, 0.2f, 0.15f }; // off the quads' shared axis, so the planes meet apart
const Vec3 GLOW_QUAD_SCALE @local = { 1.3f, 1, 1.3f };
const Vec4 GLOW_COLOR @local = { 0.95f, 0.85f, 0.2f, 0.6f };
const Vec3 SUN_TRAVEL @local = { -0.6f, -0.3f, -1 }; // toward the backdrop, so the glass shadows land beside the panes
const Vec3 AMBER_PANE_POSITION @local = { -1.9f, 1.3f, 0.9f };
const Vec3 AMBER_PANE_SCALE @local = { 0.9f, 1, 1.3f };
const Vec4 AMBER_PANE_COLOR @local = { 1, 0.55f, 0.15f, 0.65f };
const Vec3 ABSORBER_SIZE @local = { 0.8f, 1.3f, 0.5f };
const Vec3 ABSORBER_POSITION @local = { 1.9f, 0.85f, 0.9f };
const Vec4 ABSORBER_COLOR @local = { 0.9f, 1, 0.9f, 1 };
const float ABSORBER_THICKNESS @local = 1.0f;
const float ABSORBER_ATTENUATION_DISTANCE @local = 0.5f;
const Vec3 ABSORBER_ATTENUATION_COLOR @local = { 0.15f, 0.7f, 0.35f };

struct GlowParams @local {
    Vec4 color;
}
$assert GlowParams::size == 16;

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(
                x:     orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                lower: -ORBIT_PITCH_LIMIT,
                upper: ORBIT_PITCH_LIMIT,
            );
        }

        if (input.wheel != 0) {
            float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
            orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn Material glass_material(float roughness, Vec4 tint = { 1, 1, 1, 1 }) @local {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = tint;
    params.standard.metallic = 0;
    params.standard.roughness = roughness;
    params.transmission = 1;
    params.ior = GLASS_IOR;
    params.thickness = GLASS_THICKNESS;
    return material::physical(params);
}

fn Material amber_pane_material() @local {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = AMBER_PANE_COLOR;
    params.standard.metallic = 0;
    params.standard.roughness = 0.05f;
    params.transmission = 1;
    params.ior = GLASS_IOR;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    return material::physical(params, common);
}

fn Material absorber_material() @local {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = ABSORBER_COLOR;
    params.standard.metallic = 0;
    params.standard.roughness = 0.05f;
    params.transmission = 1;
    params.ior = GLASS_IOR;
    params.thickness = ABSORBER_THICKNESS;
    params.attenuation_distance = ABSORBER_ATTENUATION_DISTANCE;
    params.attenuation_color = ABSORBER_ATTENUATION_COLOR;
    return material::physical(params);
}

fn Material blended_material(Vec4 color) @local {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    return material::basic({ .color = color }, common);
}

fn char[]? compile_glow_stage(String[] defines = {}) @local {
    String log;
    char[]? spirv = compile::compile_glsl(
        allocator:  tmem,
        source:     (String)GLOW_FRAGMENT_SOURCE[..],
        stage:      ShaderStage.FRAGMENT,
        defines:    defines,
        debug_name: "glow",
        log:        &log,
    );
    if (log.len) io::printfn("%s", log);
    return spirv;
}

fn ShaderId? add_glow_shader(AssetStore* assets) @local {
    @pool() {
        ShaderDesc desc = {
            .fragment          = compile_glow_stage()!,
            .weighted_fragment = { .shaded = compile_glow_stage({ "WEIGHTED_BLEND" })! },
            .param_block_size  = GlowParams::size,
        };
        return assets.add_shader(&desc, "shader/transparency/glow");
    };
}

fn Quaternionf upright_plane_rotation(float yaw) @local {
    Quaternionf upright = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    return quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw) * upright;
}

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d transparency", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_transparency" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId plane;
    GeometryId slab;
    GeometryId rear_slab;
    GeometryId ball;
    GeometryId absorber_slab;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry, "transparency/plane")!!;

        Geometry slab_geometry = geometry::box(tmem, SLAB_SIZE.x, SLAB_SIZE.y, SLAB_SIZE.z);
        slab = assets.add_geometry(&slab_geometry, "transparency/slab")!!;

        Geometry rear_slab_geometry = geometry::box(tmem, REAR_SLAB_SIZE.x, REAR_SLAB_SIZE.y, REAR_SLAB_SIZE.z);
        rear_slab = assets.add_geometry(&rear_slab_geometry, "transparency/rear_slab")!!;

        Geometry ball_geometry = geometry::sphere(tmem, PROP_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "transparency/ball")!!;

        Geometry absorber_geometry = geometry::box(tmem, ABSORBER_SIZE.x, ABSORBER_SIZE.y, ABSORBER_SIZE.z);
        absorber_slab = assets.add_geometry(&absorber_geometry, "transparency/absorber")!!;
    };

    MaterialId glass = assets.add_material(glass_material(ROUGHNESS_STEPS[0]), "transparency/glass")!!;
    MaterialId rear_glass = assets.add_material(glass_material(0, REAR_GLASS_TINT), "transparency/rear_glass")!!;
    MaterialId amber_pane = assets.add_material(amber_pane_material(), "transparency/amber_pane")!!;
    MaterialId absorber = assets.add_material(absorber_material(), "transparency/absorber")!!;
    MaterialId backdrop_material = assets.add_material(material::standard({
        .base_color     = { 1, 1, 1, 1 },
        .base_color_map = material::texture_slot(
            texture:   asset::TEXTURE_CHECKER,
            sampler:   asset::SAMPLER_NEAREST,
            uv_set:    0,
            transform: { .scale = BACKDROP_TILES },
        ),
        .metallic       = 0,
        .roughness      = 1,
    }), "transparency/backdrop")!!;
    MaterialId cross_first = assets.add_material(blended_material(CROSS_FIRST_COLOR), "transparency/cross_first")!!;
    MaterialId cross_second = assets.add_material(blended_material(CROSS_SECOND_COLOR), "transparency/cross_second")!!;
    MaterialId batch_material = assets.add_material(blended_material(BATCH_COLOR), "transparency/batch")!!;
    MaterialId sweep_material = assets.add_material(blended_material(SWEEP_COLOR), "transparency/sweep")!!;
    ShaderId glow_shader = add_glow_shader(&assets)!!;
    MaterialCommon glow_common = material::MATERIAL_COMMON_DEFAULT;
    glow_common.alpha_mode = AlphaMode.BLEND;
    glow_common.double_sided = true;
    glow_common.depth_write = false;
    GlowParams glow_params = { .color = GLOW_COLOR };
    MaterialId glow_material = assets.add_material(
        material::custom(glow_shader, material::@as_bytes(glow_params), common: glow_common),
        "transparency/glow",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Node* backdrop = scene.add_mesh(plane, backdrop_material, name: "backdrop")!!;
    backdrop.local.position = BACKDROP_POSITION;
    backdrop.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    backdrop.local.scale = BACKDROP_SCALE;

    Vec4[3] prop_colors = { { 0.85f, 0.15f, 0.1f, 1 }, { 0.1f, 0.6f, 0.2f, 1 }, { 0.15f, 0.3f, 0.9f, 1 } };
    foreach (index, color : prop_colors) {
        MaterialId prop_material = assets.add_material(material::standard({
            .base_color = color,
            .metallic   = 0,
            .roughness  = 0.5f,
        }))!!;
        Node* prop = scene.add_mesh(ball, prop_material, name: "prop")!!;
        prop.local.position = { ((float)index - 1) * PROP_SPACING, SLAB_POSITION.y, PROP_DEPTH };
    }

    Node* pane = scene.add_mesh(slab, glass, name: "glass")!!;
    pane.local.position = SLAB_POSITION;
    Node* rear_pane = scene.add_mesh(rear_slab, rear_glass, name: "rear glass")!!;
    rear_pane.local.position = REAR_SLAB_POSITION;
    Node* amber = scene.add_mesh(plane, amber_pane, name: "amber pane")!!;
    amber.local.position = AMBER_PANE_POSITION;
    amber.local.rotation = upright_plane_rotation(0);
    amber.local.scale = AMBER_PANE_SCALE;
    Node* absorbing_slab = scene.add_mesh(absorber_slab, absorber, name: "absorbing slab")!!;
    absorbing_slab.local.position = ABSORBER_POSITION;

    float[2] cross_angles = { CROSS_QUAD_ANGLE, -CROSS_QUAD_ANGLE };
    MaterialId[2] cross_materials = { cross_first, cross_second };
    foreach (index, angle : cross_angles) {
        Node* quad = scene.add_mesh(plane, cross_materials[index], name: "cross quad")!!;
        quad.local.position = CROSS_POSITION;
        quad.local.rotation = upright_plane_rotation(angle);
        quad.local.scale = CROSS_QUAD_SCALE;
    }

    Node* glow_quad = scene.add_mesh(plane, glow_material, name: "glow quad")!!;
    glow_quad.local.position = CROSS_POSITION + GLOW_OFFSET;
    glow_quad.local.rotation = upright_plane_rotation(0);
    glow_quad.local.scale = GLOW_QUAD_SCALE;

    Transform[2] panels = {
        {
            .position = { 0, 0, BATCH_PANEL_OFFSET },
            .rotation = upright_plane_rotation(0),
            .scale    = BATCH_PANEL_SCALE,
        },
        {
            .position = { 0, 0, -BATCH_PANEL_OFFSET },
            .rotation = upright_plane_rotation(0),
            .scale    = BATCH_PANEL_SCALE,
        },
    };
    Node* panel_batch = scene.add_instanced_mesh(
        geometry:   plane,
        material:   batch_material,
        capacity:   panels.len,
        transforms: panels[..],
        name:       "panels",
    )!!;
    panel_batch.local.position = BATCH_POSITION;
    Node* sweeper = scene.add_mesh(ball, sweep_material, name: "sweeper")!!;

    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation(SUN_TRAVEL.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .target = { 0, 0.9f, -0.4f }, .distance = 5, .yaw = 0.1f, .pitch = 0.1f };
    usz roughness_step;
    ViewDesc view_desc = render::default_view_desc();
    view_desc.transmission_layers = 1;
    bool colored_shadows;
    double last_print;

    renderer.prepare_scene(&scene)!!;

    io::printn("drag to orbit, wheel to zoom, R steps the glass roughness, L toggles the transmission layers, "
        "T toggles sorted and weighted transparency, C toggles colored shadows, Escape release quits");

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE)) break;

        if (input.key_pressed(platform::Scancode.R) && !input.keyboard_captured_by_gui) {
            roughness_step = (roughness_step + 1) % ROUGHNESS_STEPS.len;
            assets.replace_material(glass, glass_material(ROUGHNESS_STEPS[roughness_step]));
            io::printfn("glass roughness %.2f", ROUGHNESS_STEPS[roughness_step]);
        }

        bool view_changed;
        if (input.key_pressed(platform::Scancode.L) && !input.keyboard_captured_by_gui) {
            view_desc.transmission_layers = view_desc.transmission_layers == 1 ? 2 : 1;
            view_changed = true;
            io::printfn("transmission layers %d", view_desc.transmission_layers);
        }
        if (input.key_pressed(platform::Scancode.T) && !input.keyboard_captured_by_gui) {
            view_desc.transparency = view_desc.transparency == TransparencyMode.SORTED
              ? TransparencyMode.WEIGHTED : TransparencyMode.SORTED;
            view_changed = true;
            io::printfn("transparency %s", view_desc.transparency == TransparencyMode.WEIGHTED ? "weighted" : "sorted");
        }

        if (input.key_pressed(platform::Scancode.C) && !input.keyboard_captured_by_gui) {
            colored_shadows = !colored_shadows;
            renderer.set_colored_shadows(colored_shadows);
            io::printfn("colored shadows %s", colored_shadows ? "on" : "off");
        }

        float sweep = SWEEP_AMPLITUDE * math::sin((float)window.clock.total);
        sweeper.local.position = BATCH_POSITION + (Vec3){ sweep, 0, 0 };
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        if (view_changed) render::configure_view(&renderer, renderer.default_view, view_desc)!!;
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;

        if (window.clock.total - last_print >= STATS_PERIOD_SECONDS) {
            last_print = window.clock.total;
            io::printfn("layers %d, %s, colored shadows %s, draws %d, scene snapshots %d, frame %.2f ms at %dx%d",
                view_desc.transmission_layers,
                view_desc.transparency == TransparencyMode.WEIGHTED ? "weighted" : "sorted",
                colored_shadows ? "on" : "off",
                renderer.stats.draws, renderer.stats.scene_snapshots,
                renderer.stats.frame_ms, renderer.output_width, renderer.output_height);
        }
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
