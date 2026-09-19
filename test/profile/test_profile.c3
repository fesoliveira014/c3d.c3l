module c3d::test::profile_integration;

import c3d::profile;
import c3d::scene;
import std::math;

fn void test_scene_scopes_follow_application_capture_selection() @test {
    Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 2,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
        .label_bytes_per_frame = 128,
    })!!;
    defer profile::destroy_recorder(&recorder);

    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* parent = scene.add_node()!!;
    Node* child = scene.add_node(parent)!!;
    parent.local.position = { 1, 0, 0 };
    child.local.position = { 0, 2, 0 };

    profile::@capture(&recorder, 0) {
        profile::@scope("simulation") {
            scene.update_world();
        };
    };

    assert(child.world_position() == (Vec3){ 1, 2, 0 });
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu_state == CaptureState.READY);
    assert(!frame.truncated && frame.dropped_cpu_scopes == 0);
    assert(frame.cpu[0].label == "simulation");
    assert(frame.cpu[0].origin == ScopeOrigin.APPLICATION);
    assert(!frame.cpu[0].has_parent && frame.cpu[0].self_complete);
    $if $feat(C3D_PROFILE_INTERNAL):
        assert(frame.cpu.len == 2);
        assert(frame.cpu[1].label == "scene.update_world");
        assert(frame.cpu[1].origin == ScopeOrigin.LIBRARY);
        assert(frame.cpu[1].has_parent && frame.cpu[1].parent_index == 0);
        assert(frame.cpu[1].self_complete);
    $else
        assert(frame.cpu.len == 1);
    $endif

    child.local.position = { 0, 3, 0 };
    scene.update_world();
    assert(child.world_position() == (Vec3){ 1, 3, 0 });
    assert(recorder.frame(0)!!.cpu.len == frame.cpu.len);

    recorder.set_enabled(false);
    profile::@capture(&recorder, 1) {
        scene.update_world();
    };
    if (catch excuse = recorder.frame(1)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        assert(false);
    }
}
