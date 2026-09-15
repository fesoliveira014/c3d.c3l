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
    assert(!history.has_previous(first));
    MeshCandidate[2] candidates = candidates_of(first, second);
    history.commit(mem, &scene, candidates[..], camera);
    assert(history.valid && history.view_proj == camera);
    assert(history.has_previous(first) && history.previous_model(first) == first.world);
    assert(history.has_previous(second));

    Entity old_id = first.id;
    scene.remove(first);
    Node* reused = scene.add_node(name: "reused")!!;
    assert(reused.id.index == old_id.index && reused.id.generation != old_id.generation);
    assert(!history.has_previous(reused));
    assert(history.has_previous(second));
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
    history.valid = false;
    assert(!history.has_previous(first) && !history.has_previous(second));

    history.commit(mem, &scene, candidates[..], matrix::IDENTITY4);
    assert(history.has_previous(first));
}
