module skinned_crowd_example;

import std::io;
import std::io::path;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::gui;
import c3d::geometry;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const uint  CROWD_COLUMNS @local = 32;
const uint  CROWD_ROWS @local = 16;
const uint  CROWD_SIZE @local = CROWD_COLUMNS * CROWD_ROWS;
const float CROWD_SPACING @local = 1.5f;
const float POSE_MARGIN @local = 1; // metres around the rest bounds; limbs of the chosen clips stay inside
const float SPEED_MIN @local = 0.8f;
const float SPEED_MAX @local = 1.2f;
const uint  RANDOM_SEED @local = 20260927;
const uint  SCENE_NODES @local = 40000; // the Animator baseline instantiates every template node per instance
const float REPORT_SECONDS @local = 2;
const Vec3  CAMERA_POSITION @local = { 0, 14, 30 };
const Vec3  CAMERA_TARGET @local = { 0, 0, 0 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 390, 560 };
const uint LOD_LEVELS @local = 3; // original, half and quarter triangle subsets share the vertex layout
const uint TRIANGLE_CORNERS @local = 3;
const float[LOD_LEVELS] LOD_THRESHOLDS @local = { 0.06f, 0.025f, 0 }; // projected sizes of the whole character
const float FULL_DETAIL_BIAS @local = 16; // keeps the finite field above its finest threshold
const String CHARACTER @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String[] CLIP_NAMES @local = {
    "Walk_Loop", "Jog_Fwd_Loop", "Idle_Loop", "Sprint_Loop", "Walk_Formal_Loop", "Dance_Loop",
};

struct Random @local {
    uint state;
}

struct Showcase @local {
    Node*    crowd;
    Node*[CROWD_SIZE] animated;
    AnimationActionId[CROWD_SIZE] base_actions;
    bool     baseline;
    bool     compare;
    bool     consume_motion;
    RootMotionDelta motion;
    uint events;
    uint dropped_events;
    float lod_bias;
    bool full_detail;
    uint[LOD_LEVELS] lod_triangles;
    float    position_error;
    float    rotation_error;
    float    scale_error;
    float    morph_error;
}

fn float Random.next(&self) @local {
    self.state = self.state * 1664525 + 1013904223;
    return (float)(self.state >> 8) / (float)(1 << 24);
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn ClipId? clip_named(AssetStore* assets, ModelTemplate* template, String name) @local {
    foreach (clip : template.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Aabb rest_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Aabb bounds = assets.geometry(template.meshes[0].geometry).data.bounds;
    foreach (&mesh : template.meshes) bounds = maths::aabb_merge(bounds, assets.geometry(mesh.geometry).data.bounds);
    Vec3 margin = { POSE_MARGIN, POSE_MARGIN, POSE_MARGIN };
    return { .min = bounds.min - margin, .max = bounds.max + margin };
}

fn Transform slot_placement(uint index, Random* random) @local {
    float x = ((float)(index % CROWD_COLUMNS) - (float)CROWD_COLUMNS * 0.5f) * CROWD_SPACING;
    float z = ((float)(index / CROWD_COLUMNS) - (float)CROWD_ROWS * 0.5f) * CROWD_SPACING;
    return {
        .position = { x, 0, z },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, random.next() * (float)math::PI * 2),
        .scale    = { 1, 1, 1 },
    };
}

fn GeometryId? triangle_subset(AssetStore* assets, GeometryId geometry_id, uint step) @local {
    Geometry source = assets.geometry(geometry_id).data;
    if (source.topology != TRIANGLES || !source.indices.len) return INVALID_ARGUMENT~;
    usz triangles = (usz)source.indices.len / TRIANGLE_CORNERS;
    usz selected = (triangles + step - 1) / step;
    uint[] indices = alloc::new_array_try(tmem, uint, (sz)(selected * TRIANGLE_CORNERS))
      ?? CAPACITY_EXCEEDED~!;

    for (usz triangle = 0; triangle < selected; triangle++) {
        usz source_corner = triangle * step * TRIANGLE_CORNERS;
        usz target_corner = triangle * TRIANGLE_CORNERS;
        indices[target_corner:TRIANGLE_CORNERS] = source.indices[source_corner:TRIANGLE_CORNERS];
    }
    source.indices = indices;

    return assets.add_geometry(&source);
}

fn void? attach_showcase_lod(
    AssetStore* assets,
    Scene* scene,
    ModelTemplate* template,
    Showcase* showcase,
) @local {
    @pool() {
        uint mesh_count = (uint)template.meshes.len;
        LodLevel[LOD_LEVELS] levels;
        AnimatedLodPart[] parts = alloc::new_array_try(tmem, AnimatedLodPart, (sz)mesh_count * LOD_LEVELS)
          ?? CAPACITY_EXCEEDED~!;

        for (uint level = 0; level < LOD_LEVELS; level++) {
            levels[level] = {
                .first_part = level * mesh_count,
                .part_count = mesh_count,
                .min_screen_size = LOD_THRESHOLDS[level],
            };

            foreach (uint mesh_index, mesh : template.meshes) {
                ModelSkin skin;
                foreach (candidate : template.skins) {
                    if (candidate.mesh_node == mesh.node) skin = candidate;
                }

                GeometryId geometry_id = level == 0
                  ? mesh.geometry : triangle_subset(assets, mesh.geometry, 1 << level)!;
                parts[level * mesh_count + mesh_index] = {
                    .draw = { .geometry = geometry_id, .material = mesh.material, .local = matrix::IDENTITY4 },
                    .mesh_index = mesh_index,
                    .skin = skin,
                    .default_morph_weights = mesh.default_morph_weights,
                };
                showcase.lod_triangles[level] += assets.geometry(geometry_id).index_count / TRIANGLE_CORNERS;
            }
        }

        AnimatedLodDesc desc = { .levels = levels[..], .parts = parts };

        model::attach_animated_lod(
            assets: assets,
            scene: scene,
            owner: showcase.crowd,
            desc: desc,
        )!;

        foreach (node : showcase.animated) {
            model::attach_animated_lod(
                assets: assets,
                scene: scene,
                owner: node,
                desc: desc,
            )!;
        }
    };
}

fn void set_baseline(Scene* scene, Showcase* showcase, bool baseline) @local {
    showcase.baseline = baseline;
    showcase.crowd.visible = !baseline;
    foreach (node : showcase.animated) node.visible = baseline;
}

fn void compare_playback(Scene* scene, Showcase* showcase) @local {
    AnimatedCrowd* crowd = scene.get(showcase.crowd, AnimatedCrowd);
    CrowdPlaybackState* playback = crowd.playback;

    showcase.position_error = 0;
    showcase.rotation_error = 0;
    showcase.scale_error = 0;
    showcase.morph_error = 0;

    foreach (usz source, node : showcase.animated) {
        ModelInstance* instance = scene.get(node, ModelInstance);
        Transform[] poses = playback.poses[source * playback.base_pose.len:playback.base_pose.len];

        foreach (uint index, pose : poses) {
            Transform reference = instance.present_node(index).local;
            float position_error = (pose.position - reference.position).length();
            float scale_error = (pose.scale - reference.scale).length();
            Quat difference = pose.rotation.mul(reference.rotation.conjugate()).normalize();
            Vec3 axis = { difference.i, difference.j, difference.k };
            float angle = 2 * math::atan2(axis.length(), math::abs(difference.l));
            showcase.position_error = math::max(showcase.position_error, position_error);
            showcase.rotation_error = math::max(showcase.rotation_error, angle);
            showcase.scale_error = math::max(showcase.scale_error, scale_error);
        }

        foreach (usz mesh_index, template_node : playback.mesh_nodes) {
            Mesh* mesh = scene.get(instance.present_node(template_node), Mesh);
            float[] weights = playback.logical_weights[source * playback.mesh_nodes.len + mesh_index];
            foreach (usz index, weight : weights) {
                showcase.morph_error = math::max(showcase.morph_error, math::abs(weight - mesh.morph_weights[index]));
            }
        }
    }
}

fn void? panel(render::Renderer* renderer, Showcase* showcase) @local {
    bool changed;

    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("AnimatedCrowd", null, {})) {
        imgui::text("Mode: %s (B toggles)", showcase.baseline ? "512 Animator instances" : "crowd");
        imgui::text("CPU record: %.3f ms", (double)renderer.stats.cpu_record_ms);
        imgui::text("Frame: %.3f ms", (double)renderer.stats.frame_ms);
        imgui::text("Draws: %u", renderer.stats.draws);
        imgui::text("Instances: %u", renderer.stats.instances);

        changed |= imgui::slider_float(
            label: "LOD bias",
            v: &showcase.lod_bias,
            v_min: -3,
            v_max: 3,
        );
        changed |= imgui::checkbox("Force full-detail meshes", &showcase.full_detail);
        imgui::text_unformatted("Triangle subsets; preview has holes.");

        if (showcase.baseline || renderer.stats.lod_counts_valid) {
            foreach (uint level, triangles : showcase.lod_triangles) {
                uint selected = showcase.baseline
                  ? renderer.stats.lod_objects_selected[level] : renderer.stats.lod_selected[level];
                uint visible = showcase.baseline
                  ? renderer.stats.lod_objects_visible[level] : renderer.stats.lod_visible[level];
                imgui::text("LOD %u: %u selected", level, selected);
                imgui::same_line();
                imgui::text("%u visible", visible);
                imgui::text("  %u triangles per character", triangles);
            }
        } else {
            imgui::text_unformatted("LOD counts await completed GPU work.");
        }

        imgui::text("Space pauses slot 0; R toggles motion application");
        imgui::text("Apply published motion: %s", showcase.consume_motion ? "on" : "off");
        double root_x = showcase.motion.translation.x;
        double root_z = showcase.motion.translation.z;
        imgui::text("Root X/Z: %.5f / %.5f", root_x, root_z);
        imgui::text("Events: %u; dropped: %u", showcase.events, showcase.dropped_events);
        if (showcase.compare) {
            imgui::text("Synchronized playback comparison");
            imgui::text("Local position: %.6g m", (double)showcase.position_error);
            imgui::text("Local rotation: %.6g rad", (double)showcase.rotation_error);
            imgui::text("Local scale: %.6g", (double)showcase.scale_error);
            imgui::text("Morph weight: %.6g", (double)showcase.morph_error);
        }
    }
    imgui::end();

    if (changed) {
        ViewDesc desc = renderer.views.get(renderer.default_view).desc;
        desc.lod_bias = showcase.full_detail ? FULL_DETAIL_BIAS : showcase.lod_bias;
        render::configure_view(renderer, renderer.default_view, desc)!;
    }
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Showcase* showcase,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(CAMERA_TARGET - CAMERA_POSITION, { 0, 1, 0 });
    anim::crowd_update(assets, scene, 0);
    anim::update(assets, scene, 0);
    scene.update_world();
    renderer.prepare_scene(scene)!;

    double last_report;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        if (input.key_pressed(Scancode.B) && !input.keyboard_captured_by_gui) {
            set_baseline(scene, showcase, !showcase.baseline);
        }

        if (input.key_pressed(Scancode.SPACE) && !input.keyboard_captured_by_gui) {
            AnimatedCrowd* crowd = scene.get(showcase.crowd, AnimatedCrowd);
            CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(0)!)!;
            Action* base = player.base_action()!;
            base.playing = !base.playing;
            Animator* animator = scene.get(showcase.animated[0], Animator);
            animator.action(showcase.base_actions[0]).playing = base.playing;
        }

        if (input.key_pressed(Scancode.R) && !input.keyboard_captured_by_gui) {
            showcase.consume_motion = !showcase.consume_motion;
        }

        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        if (showcase.baseline || showcase.compare) anim::update(assets, scene, window.clock.delta);
        if (!showcase.baseline || showcase.compare) anim::crowd_update(assets, scene, window.clock.delta);

        AnimatedCrowd* crowd = scene.get(showcase.crowd, AnimatedCrowd);
        Animator* reference = scene.get(showcase.animated[0], Animator);

        showcase.motion = showcase.baseline ? reference.root_motion : crowd.playback.slots[0].root_motion;
        showcase.events = showcase.baseline ? reference.event_count : crowd.playback.event_count;
        showcase.dropped_events = showcase.baseline ? reference.events_dropped : crowd.playback.events_dropped;

        if (showcase.consume_motion) {
            if (showcase.baseline || showcase.compare) {
                foreach (node : showcase.animated) {
                    Animator* animator = scene.get(node, Animator);
                    anim::apply_root_motion(node, animator.root_motion);
                }
            }

            if (!showcase.baseline || showcase.compare) scene.apply_crowd_root_motion(crowd);
        }

        scene.update_world();
        if (showcase.compare) compare_playback(scene, showcase);

        panel(renderer, showcase)!;
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
        if (window.clock.total - last_report >= REPORT_SECONDS) {
            last_report = window.clock.total;
            String mode = showcase.baseline ? "baseline" : "crowd";
            io::printf("%s: cpu_record %.3f ms", mode, renderer.stats.cpu_record_ms);
            io::printf(", frame %.3f ms, draws %d", renderer.stats.frame_ms, renderer.stats.draws);
            io::printfn(", instances %d", renderer.stats.instances);
        }
    }
}

fn int main(String[] args) {
    bool baseline;
    bool compare;
    foreach (argument : args[1..]) {
        if (argument == "--baseline") {
            baseline = true;
        } else if (argument == "--compare") {
            compare = true;
        } else {
            io::eprintfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d crowd", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_crowd" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ModelId model = gltf::load_model(&assets, example_path(CHARACTER))!!;
    ModelTemplate* template = &assets.model(model).data;
    ClipId[CLIP_NAMES.len] clips;
    foreach (index, name : CLIP_NAMES) clips[index] = clip_named(&assets, template, name)!!;

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODES });
    defer scene::destroy_scene(&scene);
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });

    Random random = { .state = RANDOM_SEED };
    CrowdInstance[CROWD_SIZE] instances;
    Showcase showcase = { .compare = compare };
    foreach (uint index, &instance : instances) {
        ClipId clip = clips[index % clips.len];
        float duration = assets.clip(clip).data.duration;
        *instance = {
            .placement = slot_placement(index, &random),
            .pose      = {
                .clip  = clip,
                .time  = random.next() * duration,
                .speed = SPEED_MIN + (SPEED_MAX - SPEED_MIN) * random.next(),
                .loop  = true,
            },
            .color     = { 1, 1, 1, 1 },
        };
        Node* animated = model::instantiate(&assets, &scene, model, name: "baseline")!!;
        animated.local = instance.placement;
        Animator* animator = anim::add_animator(&scene, animated);
        AnimationActionId action_id = animator.play(&assets, clip)!!;
        showcase.base_actions[index] = action_id;
        Action* action = animator.action(action_id);
        action.time = instance.pose.time;
        action.speed = instance.pose.speed;
        showcase.animated[index] = animated;
    }
    showcase.crowd = model::add_crowd(
        assets:      &assets,
        scene:       &scene,
        model:       model,
        capacity:    CROWD_SIZE,
        pose_bounds: rest_bounds(&assets, template),
        instances:   instances[..],
        name:        "crowd",
    )!!;
    attach_showcase_lod(&assets, &scene, template, &showcase)!!;
    set_baseline(&scene, &showcase, baseline);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        showcase: &showcase,
    )) {
        io::eprintfn("crowd example failed: %s", excuse);
        return 1;
    }
    return 0;
}
