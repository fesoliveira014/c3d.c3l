module c3d::test::probe_volume;

import c3d;
import c3d::light;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import std::math;

const uint SEED @local = 0x9e3779b9;
const uint DIRECTION_CASES @local = 10000;
const float TEXEL_TOLERANCE @local = 1e-5f;
const float FIELD_TOLERANCE @local = 1e-6f;
const uint[<2>] SAMPLE_CELL @local = { 3, 2 };
const ulong FRAME @local = 100;

struct Random @local {
    uint state;
}

fn uint next_bits(Random* random) @local {
    random.state ^= random.state << 13;
    random.state ^= random.state >> 17;
    random.state ^= random.state << 5;
    return random.state;
}

fn float next_float(Random* random, float low, float high) @local {
    return low + (high - low) * (float)(next_bits(random) >> 8) / (float)(1u << 24);
}

fn Vec3 next_direction(Random* random) @local {
    while (true) {
        Vec3 candidate = { next_float(random, -1, 1), next_float(random, -1, 1), next_float(random, -1, 1) };
        float length = candidate.length();
        if (length > 0.01f && length <= 1) return candidate / length;
    }
}

fn Vec2 interior_center(uint[<2>] texel, uint cell_edge) @local {
    return ((Vec2)texel - 0.5f) / (float)(cell_edge - 2) * 2 - 1;
}

// Reflects an octahedral coordinate outside [-1, 1]^2 across the crossed edge.
fn Vec2 fold_octahedral(Vec2 point) @local {
    if (point.x < -1) {
        point = { -2 - point.x, -point.y };
    } else if (point.x > 1) {
        point = { 2 - point.x, -point.y };
    }
    if (point.y < -1) {
        point = { -point.x, -2 - point.y };
    } else if (point.y > 1) {
        point = { -point.x, 2 - point.y };
    }
    return point;
}

fn ProbeFillIdentity identity(float intensity = 1, uint revision = 1, Quat rotation = quaternion::IDENTITY) @local {
    return {
        .environment       = { .index = 1, .generation = 1 },
        .lighting_revision = revision,
        .intensity         = intensity,
        .rotation          = rotation,
    };
}

fn ProbeVolumeRes mirror_of(ulong scene, uint index, ulong last_frame) @local {
    return { .scene = scene, .entity = { .index = index, .generation = 1 }, .last_frame = last_frame };
}

fn ProbeVolumeGpu packed_box(Vec3 minimum, Vec3 maximum) @local {
    Vec3 spacing = (maximum - minimum) / 2;
    return {
        .origin_energy        = { minimum.x, minimum.y, minimum.z, 1 },
        .spacing_max_distance = { spacing.x, spacing.y, spacing.z, 1 },
        .count_x              = 3,
        .count_y              = 3,
        .count_z              = 3,
        .slices_per_row       = 3,
    };
}

fn void check_round_trip(uint[<3>] counts) @local {
    uint slices_per_row = render::probe_slices_per_row(counts);
    uint[<2>] extent = render::probe_atlas_extent(counts, 1);
    bool[] used = alloc::new_array(tmem, bool, (usz)extent.x * extent.y);
    for (uint z = 0; z < counts.z; z++) {
        for (uint y = 0; y < counts.y; y++) {
            for (uint x = 0; x < counts.x; x++) {
                uint[<3>] probe = { x, y, z };
                uint[<2>] cell = render::probe_cell(counts, slices_per_row, probe);
                assert(cell.x < extent.x && cell.y < extent.y);
                assert(render::probe_from_cell(counts, slices_per_row, cell) == probe);
                usz flat = (usz)cell.y * extent.x + cell.x;
                assert(!used[flat]);
                used[flat] = true;
            }
        }
    }
}

fn void test_probe_cell_round_trips() @test {
    @pool() {
        assert(render::probe_slices_per_row({ 3, 4, 5 }) == 5);
        assert(render::probe_slices_per_row({ 32, 3, 32 }) == 8);
        assert(render::probe_slices_per_row({ 17, 4, 20 }) == 15);
        check_round_trip({ 3, 4, 5 });
        check_round_trip({ 32, 3, 32 });
        check_round_trip({ 17, 4, 20 });
    };
}

fn void test_atlas_extent_fits_the_guaranteed_image_size() @test {
    for (uint z = light::PROBE_COUNT_MIN; z <= light::PROBE_COUNT_MAX; z++) {
        for (uint y = light::PROBE_COUNT_MIN; y <= light::PROBE_COUNT_MAX; y++) {
            for (uint x = light::PROBE_COUNT_MIN; x <= light::PROBE_COUNT_MAX; x++) {
                uint[<3>] counts = { x, y, z };
                uint[<2>] visibility = render::probe_atlas_extent(counts, shader::PROBE_VISIBILITY_CELL);
                uint[<2>] irradiance = render::probe_atlas_extent(counts, shader::PROBE_IRRADIANCE_CELL);
                assert(visibility.x <= 4096 && visibility.y <= 4096);
                assert(irradiance.x <= 4096 && irradiance.y <= 4096);
                uint[<2>] last = render::probe_cell(counts, render::probe_slices_per_row(counts), counts - 1);
                uint[<2>] far_texel = (last + 1) * shader::PROBE_VISIBILITY_CELL;
                assert(far_texel.x <= visibility.x && far_texel.y <= visibility.y);
            }
        }
    }
}

fn void test_atlas_texel_stays_inside_the_interior() @test {
    Random random = { .state = SEED };
    uint[2] edges = { shader::PROBE_IRRADIANCE_CELL, shader::PROBE_VISIBILITY_CELL };
    for (uint index = 0; index < DIRECTION_CASES; index++) {
        Vec3 direction = next_direction(&random);
        foreach (edge : edges) {
            Vec2 texel = render::probe_atlas_texel(SAMPLE_CELL, edge, direction);
            Vec2 low = (Vec2)(SAMPLE_CELL * edge) + 1;
            Vec2 high = (Vec2)(SAMPLE_CELL * edge) + (float)(edge - 1);
            assert(texel.x >= low.x && texel.y >= low.y && texel.x <= high.x && texel.y <= high.y);
        }
    }
}

fn void test_octahedral_border_maps_to_the_opposite_edge() @test {
    assert(render::probe_border_source(8, { 0, 3 }) == (uint[<2>]){ 1, 4 });
    assert(render::probe_border_source(8, { 3, 0 }) == (uint[<2>]){ 4, 1 });
    assert(render::probe_border_source(8, { 7, 5 }) == (uint[<2>]){ 6, 2 });
    assert(render::probe_border_source(8, { 5, 7 }) == (uint[<2>]){ 2, 6 });
    assert(render::probe_border_source(8, { 0, 0 }) == (uint[<2>]){ 6, 6 });
    assert(render::probe_border_source(8, { 7, 0 }) == (uint[<2>]){ 1, 6 });
    assert(render::probe_border_source(8, { 0, 7 }) == (uint[<2>]){ 6, 1 });
    assert(render::probe_border_source(8, { 7, 7 }) == (uint[<2>]){ 1, 1 });

    uint[2] edges = { shader::PROBE_IRRADIANCE_CELL, shader::PROBE_VISIBILITY_CELL };
    foreach (edge : edges) {
        for (uint y = 0; y < edge; y++) {
            for (uint x = 0; x < edge; x++) {
                uint[<2>] texel = { x, y };
                bool border = x == 0 || y == 0 || x == edge - 1 || y == edge - 1;
                if (!border) continue;
                uint[<2>] source = render::probe_border_source(edge, texel);
                assert(source.x >= 1 && source.y >= 1 && source.x <= edge - 2 && source.y <= edge - 2);
                Vec2 folded = fold_octahedral(interior_center(texel, edge));
                Vec2 expected = interior_center(source, edge);
                assert(math::abs(folded.x - expected.x) <= TEXEL_TOLERANCE);
                assert(math::abs(folded.y - expected.y) <= TEXEL_TOLERANCE);
            }
        }
    }
}

fn void test_spacing_and_probe_positions_span_the_extent() @test {
    ProbeVolume volume = light::probe_volume({ 1, 2, 3 }, { 2, 3, 4 });
    Vec3 center = { 5, 0, -1 };
    assert(volume.spacing() == (Vec3){ 2, 2, 2 });
    assert(volume.probe_position(center, { 0, 0, 0 }) == center - volume.half_extents);
    assert(volume.probe_position(center, { 1, 2, 3 }) == center + volume.half_extents);
    assert(volume.probe_count() == 24);
}

fn void test_probe_volume_constructor_derives_biases() @test {
    ProbeVolume volume = light::probe_volume({ 4, 4, 4 }, { 5, 5, 5 });
    assert(volume.spacing() == (Vec3){ 2, 2, 2 });
    assert(math::abs(volume.normal_bias - 0.1f) <= FIELD_TOLERANCE);
    assert(math::abs(volume.view_bias - 0.2f) <= FIELD_TOLERANCE);
    assert(math::abs(volume.max_distance - 3) <= FIELD_TOLERANCE);
    assert(volume.energy == 1);
    assert(volume.fill == ProbeFill.ENVIRONMENT);
    assert(light::probe_volume_valid(&volume));
    ProbeVolume zeroed;
    assert(!light::probe_volume_valid(&zeroed));
}

fn void test_probe_fill_follows_the_identities() @test {
    ProbeFillIdentity current = identity();
    ProbeFillState state;
    ProbeFillWork work = render::plan_probe_fill(&state, ENVIRONMENT, &current, 3);
    assert(work.irradiance && work.visibility);
    assert(state.filled());

    work = render::plan_probe_fill(&state, ENVIRONMENT, &current, 3);
    assert(!work.irradiance && !work.visibility);

    ProbeFillIdentity turned = identity(rotation: quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2));
    work = render::plan_probe_fill(&state, ENVIRONMENT, &turned, 3);
    assert(work.irradiance && !work.visibility);

    ProbeFillIdentity brighter = identity(intensity: 2, rotation: turned.rotation);
    work = render::plan_probe_fill(&state, ENVIRONMENT, &brighter, 3);
    assert(work.irradiance && !work.visibility);

    ProbeFillIdentity relit = identity(intensity: 2, revision: 2, rotation: turned.rotation);
    work = render::plan_probe_fill(&state, ENVIRONMENT, &relit, 3);
    assert(work.irradiance && !work.visibility);

    work = render::plan_probe_fill(&state, ENVIRONMENT, &relit, 4);
    assert(!work.irradiance && work.visibility);

    work = render::plan_probe_fill(&state, ENVIRONMENT, null, 4);
    assert(!work.irradiance && !work.visibility);
    assert(!state.filled());
    assert(state.visibility_filled);

    ProbeFillState frozen;
    render::plan_probe_fill(&frozen, ENVIRONMENT, &current, 3);
    work = render::plan_probe_fill(&frozen, NONE, null, 3);
    assert(!work.irradiance && !work.visibility);
    assert(frozen.filled());

    ProbeFillState empty;
    work = render::plan_probe_fill(&empty, NONE, &current, 3);
    assert(!work.irradiance && !work.visibility);
    assert(!empty.filled());
}

fn void test_probe_slot_choice_evicts_only_absent_mirrors_of_other_scenes() @test {
    ProbeVolumeRes[4] mirrors = {
        mirror_of(2, 1, 90),
        mirror_of(2, 2, 80),
        {},
        mirror_of(2, 3, 70),
    };
    assert(render::choose_probe_slot(&mirrors, 1, FRAME)!! == 2);

    mirrors[2] = mirror_of(2, 4, 90);
    assert(render::choose_probe_slot(&mirrors, 1, FRAME)!! == 3);

    mirrors[3] = mirror_of(2, 3, 80);
    assert(render::choose_probe_slot(&mirrors, 1, FRAME)!! == 1);

    ulong recent = FRAME - render::PROBE_MIRROR_ABSENCE_FRAMES;
    foreach (index, &mirror : mirrors) *mirror = mirror_of(2, (uint)index + 1, recent);
    assert(@catch(render::choose_probe_slot(&mirrors, 1, FRAME)) == render::NO_PROBE_SLOT);

    foreach (index, &mirror : mirrors) *mirror = mirror_of(1, (uint)index + 1, 0);
    assert(@catch(render::choose_probe_slot(&mirrors, 1, FRAME)) == render::NO_PROBE_SLOT);
}

fn void test_probe_volume_selection_prefers_the_smallest_containing_box() @test {
    ProbeVolumeSetGpu set = {
        .count   = 2,
        .volumes = { [0] = packed_box({ 0, 0, 0 }, { 2, 2, 2 }), [1] = packed_box({ -4, -4, -4 }, { 4, 4, 4 }) },
    };
    assert(render::probe_volume_at(&set, { 1, 1, 1 })!! == 0);
    assert(render::probe_volume_at(&set, { 3, 1, 1 })!! == 1);
    assert(@catch(render::probe_volume_at(&set, { 5, 1, 1 })) == render::NO_PROBE_VOLUME);
    assert(render::probe_volume_at(&set, { 0.01f, 1, 1 })!! == 0);

    ProbeVolumeSetGpu equal = {
        .count   = 2,
        .volumes = { [0] = packed_box({ 0, 0, 0 }, { 2, 2, 2 }), [1] = packed_box({ 0, 0, 0 }, { 2, 2, 2 }) },
    };
    assert(render::probe_volume_at(&equal, { 1, 1, 1 })!! == 0);
}

fn void test_view_probe_volumes_skip_hidden_masked_and_unfilled() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    Node* large = scene.add_node(name: "large")!!;
    Node* small = scene.add_node(name: "small")!!;
    Node* masked = scene.add_node(name: "masked")!!;
    Node* hidden_parent = scene.add_node(name: "hidden_parent")!!;
    Node* hidden = scene.add_node(hidden_parent, "hidden")!!;
    Node* unfilled = scene.add_node(name: "unfilled")!!;
    masked.layers = 2;
    hidden_parent.visible = false;
    Node*[5] nodes = { large, small, masked, hidden, unfilled };
    Vec3[5] half_extents = { { 1, 2, 4 }, { 0.5f, 1, 2 }, { 0.1f, 0.1f, 0.1f }, { 0.1f, 0.1f, 0.1f }, { 0.1f, 0.1f, 0.1f } };
    foreach (index, node : nodes) scene.add(node, light::probe_volume(half_extents[index], { 2, 2, 2 }));
    scene.update_world();

    ProbeFillIdentity current = identity();
    ProbeVolumeRes[shader::PROBE_VOLUME_CAPACITY] mirrors;
    foreach (index, node : nodes) {
        mirrors[index] = { .scene = scene.identity, .entity = node.id };
        if (node != unfilled) render::plan_probe_fill(&mirrors[index].fill, ENVIRONMENT, &current, 1);
    }
    mirrors[5] = { .scene = scene.identity + 1, .entity = large.id };
    render::plan_probe_fill(&mirrors[5].fill, ENVIRONMENT, &current, 1);

    usz[shader::PROBE_VOLUME_CAPACITY] order;
    usz count = render::order_view_probe_volumes(&mirrors, &scene, 1, &order);
    assert(count == 2);
    assert(order[0] == 1);
    assert(order[1] == 0);
}
