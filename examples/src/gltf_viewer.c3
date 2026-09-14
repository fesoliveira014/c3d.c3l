module gltf_viewer_example;

import std::io;
import std::io::path;
import std::math;
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
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_SCALE @local = 2.5f; // starting distance in model radii; frames both instances
const float ORBIT_DISTANCE_MIN_SCALE @local = 0.5f;
const float ORBIT_DISTANCE_MAX_SCALE @local = 20;
const float INSTANCE_GAP_SCALE @local = 0.25f; // gap between instances in model widths
const float SPIN_RADIANS_PER_SECOND @local = 0.4f;
const float LIGHT_INTENSITY @local = 2.5f;
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float STATS_PERIOD_SECONDS @local = 2;
const uint MODEL_CAPACITY @local = 4;
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index
const String DEFAULT_MODEL @local = "../assets/gltf/BoxTextured.glb";
const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";

struct Orbit @local {
    Vec3  target;
    float distance;
    float minimum;
    float maximum;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (input.mouse_buttons[MOUSE_BUTTON_LEFT]) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (input.wheel != 0) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, orbit.minimum, orbit.maximum);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn Aabb template_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Mat4[] node_matrices = alloc::new_array(tmem, Mat4, template.nodes.len);
    foreach (index, &node : template.nodes) {
        Mat4 local = node.local.to_mat4();
        node_matrices[index] = node.parent < 0 ? local : node_matrices[node.parent].mul(local);
    }
    Aabb bounds = { .min = { 0, 0, 0 }, .max = { 0, 0, 0 } };
    foreach (index, &mesh : template.meshes) {
        Aabb mesh_bounds = maths::aabb_transform(assets.geometry(mesh.geometry).data.bounds, node_matrices[mesh.node]);
        bounds = index == 0 ? mesh_bounds : maths::aabb_merge(bounds, mesh_bounds);
    }
    return bounds;
}

fn usz skeleton_count(ModelTemplate* template) @local {
    usz count;
    foreach (usz index, &skin : template.skins) {
        bool seen;
        for (usz earlier = 0; earlier < index && !seen; earlier++) {
            seen = template.skins[earlier].skeleton.index == skin.skeleton.index;
        }
        if (!seen) count++;
    }
    return count;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn int main(String[] args) {
    bool gpu_timings;
    String model_path;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            gpu_timings = true;
        } else if (!model_path.len && !argument.starts_with("--")) {
            model_path = argument;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d glTF viewer", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_models = MODEL_CAPACITY;
    AssetStore assets = asset::create_asset_store(mem, store_desc);
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_gltf_viewer" },
    )!!;
    defer render::destroy_renderer(&renderer);

    if (!model_path.len) model_path = example_path(DEFAULT_MODEL);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed: %s", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }
    TextureId studio = image::load_hdr(&assets, example_path(ENVIRONMENT_FILE), "gltf_viewer/environment_source")!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio), "gltf_viewer/environment")!!;
    renderer.upload_environment(environment)!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    ModelTemplate* template = &assets.model(model).data;
    Aabb bounds = template_bounds(&assets, template);
    Vec3 extent = bounds.max - bounds.min;
    Vec3 center = (bounds.min + bounds.max) * 0.5f;
    float radius = math::max(extent.length() * 0.5f, 0.001f);
    float spacing = extent.x * (1 + INSTANCE_GAP_SCALE);

    Node* left = model::instantiate(&assets, &scene, model, name: "left")!!;
    Node* right = model::instantiate(&assets, &scene, model, name: "right")!!;
    left.local.position = { -spacing * 0.5f, 0, 0 };
    right.local.position = { spacing * 0.5f, 0, 0 };
    io::printfn("%s: %d nodes, %d meshes, %d cameras, %d lights, %d skeletons, %d skins, %d clips",
        model_path, template.nodes.len, template.meshes.len, template.cameras.len, template.lights.len,
        skeleton_count(template), template.skins.len, template.clips.len);

    Light sun = light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY);
    Node* sun_node = scene.add_light(sun, name: "sun")!!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, radius * 0.05f), name: "camera")!!;
    Orbit orbit = {
        .target   = center,
        .distance = radius * ORBIT_DISTANCE_SCALE + spacing,
        .minimum  = radius * ORBIT_DISTANCE_MIN_SCALE,
        .maximum  = (radius + spacing) * ORBIT_DISTANCE_MAX_SCALE,
        .yaw      = 0.6f,
        .pitch    = 0.35f,
    };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("drag to orbit, wheel to zoom, Escape release quits");
    double last_print;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) break;

        right.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 },
            (float)window.clock.total * SPIN_RADIANS_PER_SECOND);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;

        if (window.clock.total - last_print >= STATS_PERIOD_SECONDS) {
            last_print = window.clock.total;
            io::printfn("draws %d, triangles %d, culled %d, frame %.2f ms",
                renderer.stats.draws, renderer.stats.triangles, renderer.stats.culled, renderer.stats.frame_ms);
        }
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
