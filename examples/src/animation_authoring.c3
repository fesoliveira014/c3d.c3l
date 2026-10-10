module animation_authoring_example;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::gui;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import std::io;
import std::io::path;
import std::math;

const uint ACTION_CAPACITY @local = 16; // Nine locomotion members and two overlays fit fixed owner storage.
const uint SCENE_CAPACITY @local = 512; // Two character rigs, two morph owners, camera and light.
const String[9] LOCOMOTION_NAMES @local = {
    "Jog_Bwd_L_Loop", "Jog_Bwd_Loop", "Jog_Bwd_R_Loop",
    "Jog_Left_Loop", "Idle_Loop", "Jog_Right_Loop",
    "Jog_Fwd_L_Loop", "Jog_Fwd_Loop", "Jog_Fwd_R_Loop",
};
const Vec2[9] SAMPLE_POINTS @local = {
    { -1, -1 }, { 0, -1 }, { 1, -1 },
    { -1, 0 }, { 0, 0 }, { 1, 0 },
    { -1, 1 }, { 0, 1 }, { 1, 1 },
};
const BlendTriangle[8] SAMPLE_TRIANGLES @local = {
    { .indices = { 0, 1, 3 } }, { .indices = { 1, 4, 3 } },
    { .indices = { 1, 2, 4 } }, { .indices = { 2, 5, 4 } },
    { .indices = { 3, 4, 6 } }, { .indices = { 4, 7, 6 } },
    { .indices = { 4, 5, 7 } }, { .indices = { 5, 8, 7 } },
};

struct DisplayPair @local {
    Node* crowd;
    Node* ordinary;
    BlendSpace2D* crowd_space;
    BlendSpace2D* ordinary_space;
    Action* crowd_overlay;
    Action* ordinary_overlay;
    Action* crowd_scale;
    Action* ordinary_scale;
}

struct Controls @local {
    Vec2 parameter;
    float speed;
    float upper_weight;
    float scale_weight;
    bool paused;
    float pose_error;
    float morph_error;
}

fn String asset_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn ClipId? clip_named(AssetStore* assets, ModelTemplate* template, String name) @local {
    foreach (clip : template.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }

    return NOT_FOUND~;
}

fn uint? node_named(ModelTemplate* template, String name) @local {
    foreach (index, node : template.nodes) {
        if (node.name == name) return (uint)index;
    }

    return NOT_FOUND~;
}

fn ClipId? head_scale_clip(AssetStore* assets, ModelTemplate* template) @local {
    uint head = node_named(template, "DEF-head")!;
    Vec3 rest = template.nodes[head].local.scale;
    Allocator allocator = assets.allocator;
    AnimationClip clip = {
        .duration = 2,
        .tracks = alloc::new_array(allocator, Track, 1),
        .targets = alloc::new_array(allocator, uint, 1),
    };
    defer catch asset::free_clip(allocator, &clip);

    clip.targets[0] = head;
    clip.tracks[0] = {
        .path = TargetPath.SCALE,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(allocator, float, 3),
        .values = alloc::new_array(allocator, float, 9),
    };
    float[3] times = { 0, 1, 2 };
    float[9] values = {
        rest.x, rest.y, rest.z, rest.x * 1.12f, rest.y * 1.12f, rest.z * 1.12f, rest.x, rest.y, rest.z,
    };
    clip.tracks[0].times[..] = times[..];
    clip.tracks[0].values[..] = values[..];

    return assets.add_clip_owned(&clip, "animation_authoring/head_scale");
}

fn DisplayPair? create_pair(
    AssetStore* assets,
    Scene* scene,
    ModelId model_id,
    bool morph,
) @local {
    ModelTemplate* template = &assets.model(model_id).data;
    ClipId[9] clips;
    foreach (index, name : LOCOMOTION_NAMES) {
        clips[index] = morph ? template.clips[0] : clip_named(assets, template, name)!;
    }

    CrowdInstance[1] seed = { {
        .placement = maths::TRANSFORM_IDENTITY,
        .pose = { .clip = clips[4], .speed = 0, .loop = true },
        .color = { 1, 1, 1, 1 },
    } };
    DisplayPair pair;
    pair.crowd = model::add_crowd(
        assets: assets,
        scene: scene,
        model: model_id,
        capacity: 1,
        pose_bounds: { .min = { -2, -2, -2 }, .max = { 2, 3, 2 } },
        instances: seed[..],
        actions_per_instance: ACTION_CAPACITY,
        event_capacity: 0,
    )!;
    pair.ordinary = model::instantiate(assets, scene, model_id)!;
    pair.crowd.local.position = { -1.7f, 0, morph ? -3.0f : 0.0f };
    pair.ordinary.local.position = { 1.7f, 0, morph ? -3.0f : 0.0f };
    Animator* animator = anim::add_animator(scene, pair.ordinary);
    AnimatedCrowd* crowd = scene.get(pair.crowd, AnimatedCrowd);
    CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(0)!)!;
    player.stop(player.state.slots[0].base_action)!;

    pair.crowd_space = player.add_blend_space_2d(
        assets: assets,
        clips: clips[..],
        coordinates: SAMPLE_POINTS[..],
        triangles: SAMPLE_TRIANGLES[..],
    )!;
    pair.ordinary_space = animator.add_blend_space_2d(
        assets: assets,
        clips: clips[..],
        coordinates: SAMPLE_POINTS[..],
        triangles: SAMPLE_TRIANGLES[..],
    )!;

    String[1] names = { morph ? template.nodes[template.meshes[0].node].name : "DEF-spine.001" };
    float[1] weights = { morph ? 0.5f : 0.8f };
    uint[1] depths = { morph ? 0u : 2u };
    WeightedJointMask mask = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: assets,
        model: model_id,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )!;
    defer anim::destroy_weighted_joint_mask(&mask);

    ClipId overlay = morph ? template.clips[0] : clip_named(assets, template, "Pistol_Idle_Loop")!;
    PlayDesc desc = { .layer = 1, .weighted_mask = &mask };
    pair.crowd_overlay = player.action(player.play(assets, overlay, desc)!);
    pair.ordinary_overlay = animator.action(animator.play(assets, overlay, desc)!);
    pair.crowd_overlay.speed = -0.75f;
    pair.ordinary_overlay.speed = -0.75f;

    if (!morph) {
        ClipId scale = head_scale_clip(assets, template)!;
        desc = { .layer = 2, .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
        pair.crowd_scale = player.action(player.play(assets, scale, desc)!);
        pair.ordinary_scale = animator.action(animator.play(assets, scale, desc)!);
    }

    return pair;
}

fn void apply_controls(DisplayPair* pair, Controls* controls) @local {
    foreach (space : (BlendSpace2D*[2]){ pair.crowd_space, pair.ordinary_space }) {
        space.parameter = controls.parameter;
        space.speed = controls.speed;
        space.playing = !controls.paused;
    }

    foreach (action : (Action*[2]){ pair.crowd_overlay, pair.ordinary_overlay }) {
        action.weight = controls.upper_weight;
        action.playing = !controls.paused;
    }

    if (pair.crowd_scale) {
        foreach (action : (Action*[2]){ pair.crowd_scale, pair.ordinary_scale }) {
            action.weight = controls.scale_weight;
            action.playing = !controls.paused;
        }
    }
}

fn void compare_pair(Scene* scene, DisplayPair* pair, Controls* controls) @local {
    ModelInstance* instance = scene.get(pair.ordinary, ModelInstance);
    CrowdPlaybackState* playback = scene.get(pair.crowd, AnimatedCrowd).playback;

    foreach (uint node, pose : playback.poses[:playback.base_pose.len]) {
        Transform reference = instance.present_node(node).local;
        controls.pose_error = math::max(controls.pose_error, pose.position.distance(reference.position));
        controls.pose_error = math::max(controls.pose_error, pose.scale.distance(reference.scale));
        controls.pose_error = math::max(controls.pose_error, (pose.rotation.v - reference.rotation.v).length());
    }

    foreach (mesh, node : playback.mesh_nodes) {
        float[] reference = scene.get(instance.present_node(node), Mesh).morph_weights;
        foreach (index, weight : playback.logical_weights[mesh]) {
            controls.morph_error = math::max(controls.morph_error, math::abs(weight - reference[index]));
        }
    }
}

fn void panel(Controls* controls) @local {
    imgui::set_next_window_pos({ 16, 16 }, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Animation authoring", null, {})) {
        imgui::text("Left: crowd; right: ordinary Animator reference");
        imgui::text("Nine explicit locomotion samples; lower pair: MorphCube");
        imgui::slider_float2(
            label: "Direction",
            v: (float*)&controls.parameter,
            v_min: -1.5f,
            v_max: 1.5f,
        );
        imgui::slider_float(
            label: "Playback speed",
            v: &controls.speed,
            v_min: -2,
            v_max: 2,
        );
        imgui::slider_float(
            label: "Upper body / morph layer",
            v: &controls.upper_weight,
            v_min: 0,
            v_max: 1,
        );
        imgui::slider_float(
            label: "Multiplicative head scale",
            v: &controls.scale_weight,
            v_min: 0,
            v_max: 1,
        );

        imgui::checkbox("Pause", &controls.paused);

        imgui::text("Maximum pose difference: %.6g", (double)controls.pose_error);
        imgui::text("Maximum morph difference: %.6g", (double)controls.morph_error);
        imgui::text("16 fixed action slots; copied mask and 2D layout rows");
    }
    imgui::end();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    DisplayPair* character,
    DisplayPair* morph,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f))!;
    camera_node.local.position = { 0, 3, 10 };
    camera_node.local.rotation = maths::look_rotation((Vec3){ 0, 1, -1 } - camera_node.local.position, { 0, 1, 0 });

    Controls controls = { .speed = 1, .upper_weight = 0.6f, .scale_weight = 0.5f };

    anim::update(assets, scene, 0);
    anim::crowd_update(assets, scene, 0);
    scene.update_world();
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        if (window.input.key_released(platform::Scancode.ESCAPE) && !window.input.keyboard_captured_by_gui) break;

        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        panel(&controls);
        apply_controls(character, &controls);
        apply_controls(morph, &controls);

        anim::update(assets, scene, window.clock.delta);
        anim::crowd_update(assets, scene, window.clock.delta);
        scene.update_world();

        compare_pair(scene, character, &controls);
        compare_pair(scene, morph, &controls);

        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);

        renderer.begin_frame({ .time = window.clock.total, .delta = window.clock.delta })!;
        defer catch render::abort_frame(renderer);

        if (renderer.has_output) {
            renderer.render_view(scene, camera_node, renderer.default_view)!;
            renderer.finish_view(renderer.default_view)!;

            OverlayContext overlay = renderer.begin_overlay()!;
            gui_renderer.record(&overlay)!;
            renderer.end_overlay(&overlay)!;
        }

        renderer.end_frame()!;
    }
}

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d animation authoring", 1280, 720),
    )!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "c3d_animation_authoring" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ModelId character_model = gltf::load_model(
        assets: &assets,
        path: asset_path("../assets/quaternius/AnimationLibrary_Godot.glb"),
    )!!;
    ModelId morph_model = gltf::load_model(&assets, asset_path("../assets/gltf/AnimatedMorphCube.glb"))!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_CAPACITY });
    defer scene::destroy_scene(&scene);

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3, false))!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    DisplayPair character = create_pair(
        assets: &assets,
        scene: &scene,
        model_id: character_model,
        morph: false,
    )!!;
    DisplayPair morph = create_pair(
        assets: &assets,
        scene: &scene,
        model_id: morph_model,
        morph: true,
    )!!;

    if (catch excuse = run(
        window: &window,
        renderer: &renderer,
        assets: &assets,
        scene: &scene,
        character: &character,
        morph: &morph,
    )) {
        io::eprintfn("Animation authoring example failed: %s", excuse);
        return 1;
    }

    return 0;
}
