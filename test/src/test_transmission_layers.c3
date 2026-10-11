module c3d::test::transmission_layers;

import c3d;
import c3d::camera;
import c3d::maths;
import c3d::render @public;
import std::math;

const float TOLERANCE @local = 0.0005f;
const Vec2 VIEWPORT @local = { 100, 100 };

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn ScreenRect span(float first, float last) @local {
    return { .min = { first, -0.5f }, .max = { last, 0.5f } };
}

fn Mat4 forward_view_proj() @local {
    Camera lens = camera::perspective_deg(90, 0.1f);
    Transform origin = { .position = {}, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } };
    return camera::derive_matrices(lens, origin.to_mat4(), VIEWPORT).view_proj;
}

fn Aabb box_ahead(float center_x, float half_width, float near_depth, float far_depth) @local {
    return {
        .min = { center_x - half_width, -half_width, -far_depth },
        .max = { center_x + half_width, half_width, -near_depth },
    };
}

fn void test_disjoint_rectangles_all_stay_in_the_first_layer() @test {
    ScreenRect[4] rects = { span(-0.9f, -0.6f), span(-0.4f, -0.1f), span(0.1f, 0.4f), span(0.6f, 0.9f) };
    uint[4] layers = { 9, 9, 9, 9 };
    render::assign_transmission_layers(rects[..], 4, layers[..]);
    foreach (layer : layers) assert(layer == 0);
}

fn void test_touching_edges_do_not_overlap() @test {
    ScreenRect[2] rects = { span(-0.5f, 0), span(0, 0.5f) };
    uint[2] layers;
    render::assign_transmission_layers(rects[..], 4, layers[..]);
    assert(layers[0] == 0 && layers[1] == 0);
}

fn void test_a_chain_of_overlaps_climbs_then_clamps_at_the_last_layer() @test {
    ScreenRect[5] rects = {
        span(-0.9f, -0.5f),
        span(-0.6f, -0.2f),
        span(-0.3f, 0.1f),
        span(0, 0.4f),
        span(0.3f, 0.7f),
    };
    uint[5] layers;
    render::assign_transmission_layers(rects[..], 4, layers[..]);
    assert(layers[0] == 0 && layers[1] == 1 && layers[2] == 2 && layers[3] == 3 && layers[4] == 3);

    render::assign_transmission_layers(rects[..], 2, layers[..]);
    assert(layers[0] == 0 && layers[1] == 1 && layers[2] == 1 && layers[3] == 1 && layers[4] == 1);

    render::assign_transmission_layers(rects[..], 1, layers[..]);
    foreach (layer : layers) assert(layer == 0);
}

fn void test_a_draw_overlapping_only_a_distant_earlier_draw_sits_above_it() @test {
    ScreenRect[3] rects = { span(-0.9f, 0), span(0.2f, 0.9f), span(-0.2f, 0.1f) };
    uint[3] layers;
    render::assign_transmission_layers(rects[..], 4, layers[..]);
    assert(layers[0] == 0 && layers[1] == 0 && layers[2] == 1);
}

fn void test_a_full_screen_rectangle_puts_every_later_overlapping_draw_above_it() @test {
    ScreenRect full = { .min = { -1, -1 }, .max = { 1, 1 } };
    ScreenRect[4] rects = { full, span(-0.9f, -0.6f), span(0.6f, 0.9f), full };
    uint[4] layers;
    render::assign_transmission_layers(rects[..], 4, layers[..]);
    assert(layers[0] == 0 && layers[1] == 1 && layers[2] == 1 && layers[3] == 2);
}

fn void test_a_box_crossing_the_near_plane_covers_the_screen() @test {
    Mat4 view_proj = forward_view_proj();
    Aabb crossing = box_ahead(30, 0.5f, 0.05f, 4);
    ScreenRect rect = render::project_bounds_to_screen_rect(view_proj, crossing);
    assert(close(rect.min.x, -1) && close(rect.max.x, 1) && close(rect.min.y, -1) && close(rect.max.y, 1));

    Aabb behind = box_ahead(30, 0.5f, -3, -2);
    rect = render::project_bounds_to_screen_rect(view_proj, behind);
    assert(close(rect.min.x, -1) && close(rect.max.x, 1) && close(rect.min.y, -1) && close(rect.max.y, 1));
}

fn DrawItem draw_item(MeshCandidate* candidate, ulong rank) @local {
    return { .sort_key = rank, .candidate = candidate };
}

fn void test_reordering_keeps_back_to_front_order_within_each_layer() @test {
    MeshCandidate[5] candidates;
    Aabb[5] bounds = {
        box_ahead(-1.0f, 0.4f, 5, 5.2f),
        box_ahead(-0.6f, 0.4f, 4, 4.2f),
        box_ahead(2.0f, 0.4f, 3, 3.2f),
        box_ahead(1.6f, 0.4f, 2.5f, 2.7f),
        box_ahead(-0.8f, 0.4f, 2, 2.2f),
    };
    DrawItem[5] items;
    foreach (index, &candidate : candidates) {
        candidate.world_bounds = bounds[index];
        items[index] = draw_item(candidate, (ulong)index);
    }

    SceneReadLayers split = render::split_scene_reads_by_layer(items[..], forward_view_proj(), 3);
    assert(split.count == 3);
    assert(split.ends[0] == 2 && split.ends[1] == 4 && split.ends[2] == 5);
    assert(items[0].sort_key == 0 && items[1].sort_key == 2);
    assert(items[2].sort_key == 1 && items[3].sort_key == 3);
    assert(items[4].sort_key == 4);
}

fn void expect_view_desc_fault(Renderer* renderer, ViewDesc* desc, fault expected) @local {
    fault excuse = @catch(render::validate_view_desc(renderer, desc));
    assert(excuse == expected);
}

fn void test_view_desc_accepts_zero_to_the_cap_and_rejects_above_it() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    ViewDesc desc = render::default_view_desc();

    desc.transmission_layers = 0;
    render::validate_view_desc(renderer, &desc)!!;
    for (uint layers = 1; layers <= render::MAX_TRANSMISSION_LAYERS; layers++) {
        desc.transmission_layers = layers;
        render::validate_view_desc(renderer, &desc)!!;
    }

    desc.transmission_layers = render::MAX_TRANSMISSION_LAYERS + 1;
    expect_view_desc_fault(renderer, &desc, c3d::INVALID_ARGUMENT);
}
