module mixamo_example;

import std::io;
import std::collections::list;
import std::io::file;
import std::io::path;
import std::math;
import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::fbx;
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

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_SCALE @local = 2.5f; // starting distance in model radii; frames both instances
const float ORBIT_DISTANCE_MIN_SCALE @local = 0.5f;
const float ORBIT_DISTANCE_MAX_SCALE @local = 20;
const float INSTANCE_GAP_SCALE @local = 0.25f; // gap between instances in model widths
const float CROSS_FADE_SECONDS @local = 0.3f;
const float QUARTER_WEIGHT @local = 0.25f;
const usz CLIP_KEY_COUNT @local = 9; // keys 1 to 9
const float SECOND_SPEED @local = 0.5f;
const float LIGHT_INTENSITY @local = 2.5f;
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float STATS_PERIOD_SECONDS @local = 2;
const uint MODEL_CAPACITY @local = 4;
const String DEFAULT_MODEL @local = "../assets/mixamo/character.fbx";
const String[] DEFAULT_ANIMATIONS @local = { "../assets/mixamo/walk.fbx", "../assets/mixamo/run.fbx" };
const usz MAX_ANIMATION_FILES @local = 8;
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
    if (input.button_down(platform::MouseButton.LEFT)) {
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

struct Playback @local {
    ClipId[] stripped;
    ClipId[] kept;
    bool     keep_root_motion;
    usz      left_clip;
    usz      right_clip;
}

fn ClipId[] Playback.clips(&self) @local {
    return self.keep_root_motion ? self.kept : self.stripped;
}

fn void cross_fade_to(Animator* animator, AssetStore* assets, ClipId clip) @local {
    animator.play(assets, clip, CROSS_FADE_SECONDS)!!;
    sz last = animator.actions.len() - 1;
    if (last > 0) animator.cross_fade(&animator.actions[last - 1], &animator.actions[last], CROSS_FADE_SECONDS);
}

fn void handle_keys(
    Input* input,
    AssetStore* assets,
    Scene* scene,
    Node* left,
    Node* right,
    Playback* playback,
) @local {
    Animator* left_animator = scene.get(left, Animator);
    ClipId[] clips = playback.clips();
    for (usz digit = 0; digit < clips.len && digit < CLIP_KEY_COUNT; digit++) {
        if (!input.key_pressed((platform::Scancode)((usz)platform::Scancode.CODE_1 + digit))) continue;
        playback.left_clip = digit;
        cross_fade_to(left_animator, assets, clips[digit]);
    }
    if (input.key_pressed(platform::Scancode.R) && playback.kept.len) {
        playback.keep_root_motion = !playback.keep_root_motion;
        ClipId[] variant = playback.clips();
        cross_fade_to(left_animator, assets, variant[playback.left_clip]);
        Animator* right_animator = scene.get(right, Animator);
        float speed = right_animator.actions.len() ? right_animator.actions[right_animator.actions.len() - 1].speed : 1;
        cross_fade_to(right_animator, assets, variant[playback.right_clip]);
        right_animator.actions[right_animator.actions.len() - 1].speed = speed;
        io::printfn("root motion %s", playback.keep_root_motion ? "kept" : "stripped");
    }
    if (input.key_pressed(platform::Scancode.Q) && left_animator.actions.len()) {
        Action* action = &left_animator.actions[left_animator.actions.len() - 1];
        action.weight = action.weight == 1 ? QUARTER_WEIGHT : 1;
    }
    if (input.key_pressed(platform::Scancode.SPACE)) {
        foreach (&action : left_animator.actions) action.playing = !action.playing;
        foreach (&action : scene.get(right, Animator).actions) action.playing = !action.playing;
    }
}

fn Playback load_animations(AssetStore* assets, ModelId model, String[] paths) @local {
    List{ClipId} stripped;
    List{ClipId} kept;
    stripped.init(mem);
    kept.init(mem);
    foreach (path : paths) {
        RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.STRIP_XZ;
        ClipId[]? in_place = fbx::load_animations(mem, assets, path, model, options);
        if (catch excuse = in_place) {
            io::printfn("Loading %s failed: %s", path, excuse);
            continue;
        }
        options.root_motion = RootMotion.KEEP;
        ClipId[] moving = fbx::load_animations(mem, assets, path, model, options)!!;
        io::printfn("%s: %d clips", path, in_place.len);
        foreach (clip : in_place) stripped.push(clip);
        foreach (clip : moving) kept.push(clip);
        alloc::free(mem, in_place.ptr);
        alloc::free(mem, moving.ptr);
    }
    return { .stripped = stripped.array_view(), .kept = kept.array_view() };
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn int main(String[] args) {
    bool gpu_timings;
    String model_path;
    String[MAX_ANIMATION_FILES] animation_paths;
    usz animation_count;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            gpu_timings = true;
        } else if (!model_path.len && !argument.starts_with("--")) {
            model_path = argument;
        } else if (animation_count < MAX_ANIMATION_FILES && !argument.starts_with("--")) {
            animation_paths[animation_count++] = argument;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    if (!model_path.len) {
        model_path = example_path(DEFAULT_MODEL);
        if (!file::is_file(model_path)) {
            io::printn("Download a Mixamo character as FBX Binary with skin to examples/assets/mixamo/character.fbx,");
            io::printn("or pass the path of an FBX file followed by animation files.");
            return 1;
        }
        foreach (relative : DEFAULT_ANIMATIONS) {
            String candidate = example_path(relative);
            if (file::is_file(candidate)) animation_paths[animation_count++] = candidate;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d mixamo", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_models = MODEL_CAPACITY;
    AssetStore assets = asset::create_asset_store(mem, store_desc);
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_mixamo" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ModelId model;
    if (catch excuse = fbx::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed: %s", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }
    TextureId studio = image::load_hdr(&assets, example_path(ENVIRONMENT_FILE), "mixamo/environment_source")!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio), "mixamo/environment")!!;
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

    Playback playback = load_animations(&assets, model, animation_paths[:animation_count]);
    ClipId[] clips = playback.stripped.len ? playback.stripped : scene.get(left, ModelInstance).clips;
    anim::add_animator(&scene, left);
    anim::add_animator(&scene, right);
    if (clips.len) {
        scene.get(left, Animator).play(&assets, clips[0])!!;
        Action* second = scene.get(right, Animator).play(&assets, clips[0])!!;
        second.speed = SECOND_SPEED;
    } else {
        io::printn("no clips in this model; both instances hold their authored pose");
    }

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

    io::printn("1-9 cross-fade clip, R toggle root motion, Q quarter weight, SPACE pause");
    io::printn("drag to orbit, wheel to zoom, Escape quits");
    double last_print;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE)) break;

        handle_keys(
            input:    input,
            assets:   &assets,
            scene:    &scene,
            left:     left,
            right:    right,
            playback: &playback,
        );
        anim::update(&assets, &scene, (float)window.clock.delta);
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
