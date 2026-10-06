module c3d::test::shadow_sets;

import c3d;
import c3d::camera;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::math;

const Vec2 MAIN_VIEWPORT @local = { 320, 180 };
const Vec2 HALF_VIEWPORT @local = { 160, 90 }; // the main extent at render scale 0.5: the same aspect
const Vec2 SQUARE_VIEWPORT @local = { 180, 180 };
const ulong FRAME @local = 7;
const uint WATER_LAYER @local = 1 << 4;
const Plane WATER_PLANE @local = { .normal = { 0, 1, 0 }, .d = 0 };
const Vec3 MAIN_POSITION @local = { 0, 2, 4 };

fn Node* add_main_camera(Scene* scene) @local {
    Node* node = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    node.local.position = MAIN_POSITION;
    node.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::deg_to_rad(-8.0f));
    scene.update_world();
    return node;
}

fn Node* add_mirror_camera(Scene* scene, Node* main) @local {
    Node* node = scene.add_camera(*scene.get(main, Camera))!!;
    Mat4 mirrored = maths::reflection_matrix(WATER_PLANE).mul(main.local.to_mat4());
    node.local = maths::transform_from_affine(mirrored)!!;
    scene.get(node, Camera).layers &= ~WATER_LAYER;
    scene.update_world();
    return node;
}

fn ShadowSetKey key_of(
    Scene* scene,
    Node* camera_node,
    Node* shadow_camera = null,
    Vec2 viewport = MAIN_VIEWPORT,
    ulong frame = FRAME,
    bool ray_traced = false,
) @local {
    ShadowCamera shadow_view = render::shadow_camera_of(
        scene:         scene,
        camera_node:   camera_node,
        shadow_camera: shadow_camera,
        viewport:      viewport,
        origin:        {},
    )!!;
    return render::shadow_set_key(
        scene:              scene,
        frame:              frame,
        shadow_view:        &shadow_view,
        ray_traced_shadows: ray_traced,
    );
}

fn bool claim(
    ShadowSet* set,
    Stats* stats,
    ShadowSetKey key,
    bool share = true,
) @local {
    return render::claim_shadow_set(
        set:   set,
        key:   &key,
        share: share,
        stats: stats,
    );
}

fn void test_every_key_input_records_a_new_set() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Scene other = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&other);
    Node* main = add_main_camera(&scene);
    ShadowSetKey base = key_of(&scene, main);
    ShadowSetKey[7] variants;

    variants[0] = base;
    variants[0].scene_identity = other.identity;
    variants[1] = key_of(scene: &scene, camera_node: main, frame: FRAME + 1);
    main.local.position.x += 0.001f;
    scene.update_world();
    variants[2] = key_of(&scene, main);
    main.local.position = MAIN_POSITION;
    scene.update_world();
    scene.get(main, Camera).fov_y += 0.001f;
    variants[3] = key_of(&scene, main);
    scene.get(main, Camera).fov_y -= 0.001f;
    scene.get(main, Camera).layers &= ~WATER_LAYER;
    variants[4] = key_of(&scene, main);
    scene.get(main, Camera).layers |= WATER_LAYER;
    variants[5] = key_of(scene: &scene, camera_node: main, viewport: SQUARE_VIEWPORT);
    variants[6] = key_of(scene: &scene, camera_node: main, ray_traced: true);

    foreach (variant : variants) {
        ShadowSet set;
        Stats stats;
        assert(!claim(&set, &stats, base));
        assert(!claim(&set, &stats, variant));
        assert(stats.shadow_sets_recorded == 2 && stats.shadow_sets_shared == 0);
    }
    ShadowSet set;
    Stats stats;
    claim(&set, &stats, base);
    assert(claim(&set, &stats, key_of(&scene, main)));
    assert(stats.shadow_sets_recorded == 1 && stats.shadow_sets_shared == 1);
}

fn void test_two_cameras_with_identical_values_share_one_set() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* first = add_main_camera(&scene);
    Node* second = add_main_camera(&scene);
    ShadowSet set;
    Stats stats;

    assert(!claim(&set, &stats, key_of(&scene, first)));
    assert(claim(&set, &stats, key_of(&scene, second)));
    assert(stats.shadow_sets_recorded == 1 && stats.shadow_sets_shared == 1);
}

fn void test_a_camera_moved_between_two_views_records_twice() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* main = add_main_camera(&scene);
    ShadowSet set;
    Stats stats;

    assert(!claim(&set, &stats, key_of(&scene, main)));
    main.local.position.z -= 1;
    scene.update_world();
    assert(!claim(&set, &stats, key_of(&scene, main)));
    assert(stats.shadow_sets_recorded == 2 && stats.shadow_sets_shared == 0);
}

fn void test_same_camera_views_share_only_at_equal_aspect() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* main = add_main_camera(&scene);
    ShadowSet set;
    Stats stats;

    assert(!claim(&set, &stats, key_of(&scene, main)));
    assert(claim(&set, &stats, key_of(scene: &scene, camera_node: main, viewport: HALF_VIEWPORT)));
    assert(!claim(&set, &stats, key_of(scene: &scene, camera_node: main, viewport: SQUARE_VIEWPORT)));
    assert(stats.shadow_sets_recorded == 2 && stats.shadow_sets_shared == 1);

    scene.get(main, Camera).aspect = MAIN_VIEWPORT.x / MAIN_VIEWPORT.y;
    assert(!claim(&set, &stats, key_of(&scene, main)));
    assert(claim(&set, &stats, key_of(scene: &scene, camera_node: main, viewport: SQUARE_VIEWPORT)));
    assert(stats.shadow_sets_recorded == 3 && stats.shadow_sets_shared == 2);
}

fn void test_an_opted_out_view_records_and_never_publishes() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* main = add_main_camera(&scene);
    Node* mirror = add_mirror_camera(&scene, main);
    ShadowSetKey key = key_of(&scene, main);
    ShadowSet set;
    Stats stats;

    assert(!claim(set: &set, stats: &stats, key: key, share: false));
    assert(!claim(&set, &stats, key));
    assert(!claim(set: &set, stats: &stats, key: key, share: false));
    assert(stats.shadow_sets_recorded == 3 && stats.shadow_sets_shared == 0);

    ShadowSetKey borrowed = key_of(scene: &scene, camera_node: mirror, shadow_camera: main);
    assert(!claim(set: &set, stats: &stats, key: borrowed, share: false));
    assert(render::same_shadow_key(&set.key, &key));
    assert(!set.published);
}

fn void test_water_frame_binds_the_mirror_set_in_main() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* main = add_main_camera(&scene);
    Node* mirror = add_mirror_camera(&scene, main);
    Node* capture = add_main_camera(&scene);
    capture.local.position = { 20, 5, 0 };
    scene.update_world();
    ShadowSetKey mirror_key = key_of(
        scene:         &scene,
        camera_node:   mirror,
        shadow_camera: main,
        viewport:      HALF_VIEWPORT,
    );
    ShadowSetKey main_key = key_of(&scene, main);
    ShadowSetKey capture_key = key_of(&scene, capture);
    ShadowSetKey mirror_own_key = key_of(scene: &scene, camera_node: mirror, viewport: HALF_VIEWPORT);
    assert(render::same_shadow_key(&mirror_key, &main_key));
    assert(!render::same_shadow_key(&mirror_key, &mirror_own_key));

    ShadowSet set;
    Stats stats;
    assert(!claim(&set, &stats, mirror_key));
    assert(claim(&set, &stats, main_key));
    assert(!claim(&set, &stats, capture_key));
    assert(stats.shadow_sets_recorded == 2 && stats.shadow_sets_shared == 1);

    // One set at a time: a recording between mirror and main replaces the mirror's set.
    set = {};
    stats = {};
    assert(!claim(&set, &stats, mirror_key));
    assert(!claim(&set, &stats, capture_key));
    assert(!claim(&set, &stats, main_key));
    assert(stats.shadow_sets_recorded == 3 && stats.shadow_sets_shared == 0);
}

fn void test_bound_set_gives_layers_by_light_entity() @test {
    ShadowSetLight[2] entries = {
        { .light = { .index = 1, .generation = 1 }, .first_layer = 0, .layer_count = 4 },
        { .light = { .index = 2, .generation = 3 }, .first_layer = 4, .layer_count = 1 },
    };
    ShadowSet set = { .lights = entries[..], .light_count = 2 };
    LightGpu[4] lights;
    ShadowRequest[4] requests = {
        { .light = { .index = 2, .generation = 3 }, .light_index = 0, .layer_count = 1 },
        { .light = { .index = 5, .generation = 1 }, .light_index = 1, .layer_count = 6 },
        { .light = { .index = 1, .generation = 1 }, .light_index = 2, .layer_count = 4 },
        { .light = { .index = 2, .generation = 4 }, .light_index = 3, .layer_count = 1 },
    };
    LightExtraction extraction = { .lights = lights[..], .shadows = requests[..] };

    uint unmatched = render::bind_shadow_set(&set, &extraction);

    assert(unmatched == 2);
    assert(lights[0].shadow_first == 4 && lights[0].shadow_count == 1);
    assert(lights[1].shadow_count == 0);
    assert(lights[2].shadow_first == 0 && lights[2].shadow_count == 4);
    assert(lights[3].shadow_count == 0);
}

fn void test_shadow_camera_without_a_camera_faults() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* main = add_main_camera(&scene);
    Node* empty = scene.add_node()!!;
    scene.update_world();

    ShadowCamera? shadow_view = render::shadow_camera_of(
        scene:         &scene,
        camera_node:   main,
        shadow_camera: empty,
        viewport:      MAIN_VIEWPORT,
        origin:        {},
    );
    if (catch excuse = shadow_view) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
}

fn void test_an_empty_set_leaves_every_light_without_layers() @test {
    ShadowSet set;
    LightGpu[1] lights;
    ShadowRequest[1] requests = {
        { .light = { .index = 1, .generation = 1 }, .light_index = 0, .layer_count = 4 },
    };
    LightExtraction extraction = { .lights = lights[..], .shadows = requests[..] };

    uint unmatched = render::bind_shadow_set(&set, &extraction);

    assert(unmatched == 1);
    assert(lights[0].shadow_first == 0 && lights[0].shadow_count == 0);
    LightExtraction unshadowed = { .lights = lights[..] };
    assert(render::bind_shadow_set(&set, &unshadowed) == 0);
    assert(lights[0].shadow_count == 0);
}

