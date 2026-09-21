module c3d::test::view_history;

import c3d;
import c3d::render;
import c3d::scene;
import std::math;

const uint NODE_CAPACITY @local = 4;

fn MeshCandidate[2] candidates_of(Node* first, Node* second) @local {
    return { { .node = first }, { .node = second } };
}

fn void test_view_history_reports_previous_model_only_for_matching_owner() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    Node* second = scene.add_node(name: "second")!!;
    first.local.position = { 1, 2, 3 };
    scene.update_world();
    Mat4 camera = matrix::IDENTITY4.translate({ 0, 0, -5 });

    ViewHistory history;
    defer render::free_view_history(mem, &history);
    assert(!history.has_previous(&scene, first));
    MeshCandidate[2] candidates = candidates_of(first, second);
    history.commit(mem, &scene, candidates[..], camera);
    history.publish();
    assert(history.valid && history.view_proj == camera);
    assert(history.has_previous(&scene, first) && history.previous_model(&scene, first) == first.world);
    assert(history.has_previous(&scene, second));

    Entity old_id = first.id;
    scene.remove(first);
    Node* reused = scene.add_node(name: "reused")!!;
    assert(reused.id.index == old_id.index && reused.id.generation != old_id.generation);
    assert(!history.has_previous(&scene, reused));
    assert(history.has_previous(&scene, second));
}

fn void test_view_history_reset_forgets_everything() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    Node* second = scene.add_node(name: "second")!!;
    scene.update_world();

    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[2] candidates = candidates_of(first, second);
    history.commit(mem, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    history.valid = false;
    assert(!history.has_previous(&scene, first) && !history.has_previous(&scene, second));

    history.commit(mem, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&scene, first));
}

fn void test_view_history_membership_follows_the_last_published_rendering() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    Node* second = scene.add_node(name: "second")!!;
    scene.update_world();
    ViewHistory history;
    defer render::free_view_history(mem, &history);

    MeshCandidate[2] both = candidates_of(first, second);
    history.commit(mem, &scene, both[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&scene, first) && history.has_previous(&scene, second));

    MeshCandidate[1] only_first = { { .node = first } };
    history.commit(mem, &scene, only_first[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&scene, first));
    assert(!history.has_previous(&scene, second));

    second.local.position = { 4, 0, 0 };
    scene.update_world();
    history.commit(mem, &scene, both[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&scene, second) && history.previous_model(&scene, second) == second.world);
}

fn void test_view_history_ignores_a_scene_with_matching_ids() @test {
    Scene first_scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&first_scene);
    Scene second_scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&second_scene);
    assert(first_scene.identity != 0 && second_scene.identity != 0);
    assert(first_scene.identity != second_scene.identity);
    Node* first = first_scene.add_node(name: "mesh")!!;
    Node* second = second_scene.add_node(name: "mesh")!!;
    assert(first.id.index == second.id.index && first.id.generation == second.id.generation);
    first_scene.update_world();
    second_scene.update_world();
    ViewHistory history;
    defer render::free_view_history(mem, &history);

    MeshCandidate[1] candidates = { { .node = first } };
    history.commit(mem, &first_scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&first_scene, first));
    assert(!history.has_previous(&second_scene, second));
}

fn void test_view_history_pending_rendering_is_not_previous_until_published() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    scene.update_world();
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = first } };

    history.commit(mem, &scene, candidates[..], matrix::IDENTITY4);
    assert(history.pending && !history.valid && !history.has_previous(&scene, first));
    history.publish();
    assert(history.valid && !history.pending && history.has_previous(&scene, first));

    history.commit(mem, &scene, candidates[..], matrix::IDENTITY4);
    history.discard();
    assert(!history.valid && !history.pending && !history.has_previous(&scene, first));

    history.publish();
    assert(!history.valid);
}
