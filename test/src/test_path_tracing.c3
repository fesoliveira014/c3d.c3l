module c3d::test::path_tracing;

import c3d;
import c3d::maths;
import c3d::render @public;
import std::math;

fn Mat4 test_view_proj() @local {
    return maths::perspective_reverse_z(1.0f, 16.0f / 9.0f, 0.1f);
}

fn void test_sbt_layout_respects_alignments() @test {
    SbtLayout layout = render::sbt_layout(32, 64, 256);
    assert(layout.record_stride == 64);
    assert(layout.miss_offset == 256);
    assert(layout.hit_offset == 512);
    assert(layout.total_bytes == 576);

    layout = render::sbt_layout(32, 32, 64);
    assert(layout.record_stride == 32);
    assert(layout.miss_offset == 64);
    assert(layout.hit_offset == 128);
    assert(layout.total_bytes == 160);

    layout = render::sbt_layout(48, 16, 64);
    assert(layout.record_stride == 48);
    assert(layout.miss_offset == 64);
    assert(layout.hit_offset == 128);
    assert(layout.total_bytes == 176);
}

fn void test_accumulation_resets_on_camera_scene_and_trace_changes() @test {
    Mat4 view_proj = test_view_proj();
    ViewHistory history = { .valid = true, .scene = 7, .trace_revision = 3, .view_proj = view_proj };
    assert(!render::accumulation_reset_needed(&history, 7, 3, view_proj));

    history.valid = false;
    assert(render::accumulation_reset_needed(&history, 7, 3, view_proj));
    history.valid = true;

    assert(render::accumulation_reset_needed(&history, 8, 3, view_proj));
    assert(render::accumulation_reset_needed(&history, 7, 4, view_proj));
    Mat4 moved = view_proj;
    moved.m03 += 1e-6;
    assert(render::accumulation_reset_needed(&history, 7, 3, moved));
}

fn void test_publish_carries_the_accumulated_samples() @test {
    Mat4 view_proj = test_view_proj();
    ViewHistory history;
    history.commit_accumulation(7, 3, view_proj, 5);
    history.publish();
    assert(history.valid);
    assert(!history.pending);
    assert(history.accumulated_samples == 5);

    history.commit_accumulation(7, 3, view_proj, 9);
    history.discard();
    assert(!history.valid);
    assert(history.accumulated_samples == 5);

    history.publish();
    assert(!history.valid);
    assert(history.accumulated_samples == 5);
}
