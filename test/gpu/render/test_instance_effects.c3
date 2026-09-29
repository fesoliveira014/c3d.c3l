module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::math;

const float SWAY_REACH @private = 4 * LINE_STEP; // moves the centre box about two pixels along +X
const float MARGIN_SWAY @private = 0.3f; // brings LINE_CENTER + 3, 0.05 outside the right plane, into view
const float SWAY_FREQUENCY @private = 0.5f;
const double SWAY_PERIOD @private = 1.0 / SWAY_FREQUENCY;
const InstanceFade FADE_BEYOND @private = { .start = 0.1f, .end = 0.2f }; // every anchor lies about 3 from the camera
const InstanceFade FADE_AHEAD @private = { .start = 100, .end = 200 };
const Vec2 SIDE_UV @private = { 0.609375f, 0.5f }; // (0.35, 0, 0.2): background, then the centre box moved 0.2
const Vec2 REACHING_UV @private = { 0.953125f, 0.5f }; // (1.6, 0, -0.06): LINE_CENTER + 3's -X face swayed 0.3
const Vec3 WALL_POSITION @private = { 0, 0, -1 };
const Vec3 WALL_SCALE @private = { 6, 3, 0.05f };
const Vec3 WALL_SUN_DIRECTION @private = { 0, -0.5f, -1 }; // lays the line's shadows on the wall below the boxes
const float WALL_SHADOW_DISTANCE @private = 5; // one cascade covering the wall at about 4 from the camera
const float SHADOW_ROW_V @private = 0.609375f; // y = -0.5 on the wall, below every box
const float SHADOW_ROW_U_START @private = 0.359375f; // x = -0.65 on the wall, inside the shadow of LINE_CENTER - 1
const uint SHADOW_ROW_SAMPLES @private = 11; // across the shadows of LINE_CENTER - 1 to LINE_CENTER + 1

// The uncoloured box weighs 1 under VERTEX_ALPHA, so the sway translates every instance by its amplitude.
const InstanceSway RIGID_SWAY @private = {
    .direction = { 1, 0, 0 },
    .lean      = 1,
    .weight    = SwayWeight.VERTEX_ALPHA,
};

struct RigidSamples @private {
    uint at_rest;
    uint swayed;
    uint moved;
}

fn DeformedScene? create_wall_scene(Fixture* fixture, MaterialId material) @private {
    DeformedScene result = create_line_scene(fixture, material)!;
    defer catch scene::destroy_scene(&result.scene);
    StandardParams matte = material::STANDARD_PARAMS_DEFAULT;
    matte.metallic = 0;
    MaterialId wall_material = fixture.assets.add_material(material::standard(matte))!;
    Node* wall = result.scene.add_mesh(fixture.box, wall_material)!;
    wall.local.position = WALL_POSITION;
    wall.local.scale = WALL_SCALE;
    Light sunlight = light::directional({ 1, 1, 1 }, 2);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = WALL_SHADOW_DISTANCE;
    Node* sun = result.scene.add_light(sunlight)!;
    sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, WALL_SUN_DIRECTION.normalize());
    result.scene.update_world();
    return result;
}

fn DeformedScene? create_faded_batch_scene(Fixture* fixture) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    Transform[1] origin = { maths::TRANSFORM_IDENTITY };
    result.mesh = result.scene.add_instanced_mesh(fixture.faded_box, fixture.masked, 1, origin[..])!;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn void? sample_row(Fixture* fixture, DeformedScene* target, uint[] pixels) @private {
    foreach (index, &pixel : pixels) {
        Vec2 uv = { SHADOW_ROW_U_START + (float)index / TARGET_SIZE, SHADOW_ROW_V };
        *pixel = render_scene_and_sample(fixture, target, uv)!;
    }
}

fn bool pixels_differ(uint first, uint second) @private {
    for (uint channel = 0; channel < 4; channel++) {
        if (channel_difference(first, second, channel) > CHANNEL_TOLERANCE) return true;
    }
    return false;
}

fn RigidSamples? sample_rigid_sway(Fixture* fixture, DeformedScene* line, Vec2 uv) @private {
    InstancedMesh* batch = line.scene.get(line.mesh, InstancedMesh);
    RigidSamples samples = { .at_rest = settle_and_sample(fixture, line, uv)! };
    batch.sway = RIGID_SWAY;
    batch.sway.amplitude = SWAY_REACH;
    samples.swayed = settle_and_sample(fixture, line, uv)!;
    batch.sway = {};
    line.mesh.local.position.x = SWAY_REACH;
    samples.moved = settle_and_sample(fixture, line, uv)!;
    line.mesh.local.position.x = 0;
    return samples;
}

fn void test_rigid_sway_draws_like_a_moved_node() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&line.scene);

    bool[2] culling_modes = { true, false };
    foreach (culling : culling_modes) {
        set_view_culling(&fixture, culling)!!;
        RigidSamples centre = sample_rigid_sway(&fixture, &line, CENTER_UV)!!;
        RigidSamples side = sample_rigid_sway(&fixture, &line, SIDE_UV)!!;
        check_near_pixel(centre.swayed, centre.moved);
        check_near_pixel(side.swayed, side.moved);
        assert(pixels_differ(side.swayed, side.at_rest));
    }
    check_validation(&fixture.renderer);
}

fn void test_rigid_sway_moves_the_shadow() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene walled = create_wall_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&walled.scene);
    InstancedMesh* batch = walled.scene.get(walled.mesh, InstancedMesh);
    uint[SHADOW_ROW_SAMPLES] still;
    uint[SHADOW_ROW_SAMPLES] swayed;
    uint[SHADOW_ROW_SAMPLES] moved;

    sample_row(&fixture, &walled, still[..])!!;
    batch.sway = RIGID_SWAY;
    batch.sway.amplitude = SWAY_REACH;
    sample_row(&fixture, &walled, swayed[..])!!;
    batch.sway = {};
    walled.mesh.local.position.x = SWAY_REACH;
    sample_row(&fixture, &walled, moved[..])!!;

    bool edge_in_row;
    bool shadow_moved;
    foreach (index, pixel : swayed) {
        edge_in_row |= pixels_differ(still[index], still[0]);
        shadow_moved |= pixels_differ(pixel, still[index]);
        check_near_pixel(pixel, moved[index]);
    }
    assert(edge_in_row && shadow_moved);
    check_validation(&fixture.renderer);
}

fn void test_sway_amplitude_step_matches_node_velocity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene moved = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&moved.scene);
    DeformedScene swayed = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&swayed.scene);
    InstancedMesh* batch = swayed.scene.get(swayed.mesh, InstancedMesh);

    uint node_velocity = move_line_node(&fixture, &moved, false)!!;
    batch.sway = RIGID_SWAY;
    uint sway_velocity;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        batch.sway.amplitude += LINE_STEP;
        sway_velocity = render_scene_and_sample(&fixture, &swayed)!!;
    }
    uint background_velocity = render_scene_and_sample(&fixture, &swayed, BACKGROUND_UV)!!;

    check_near_pixel(sway_velocity, node_velocity);
    assert(pixels_differ(sway_velocity, background_velocity));
    check_validation(&fixture.renderer);
}

fn void test_sway_velocity_follows_the_previous_phase() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&line.scene);
    line.scene.get(line.mesh, InstancedMesh).sway = {
        .direction = { 1, 0, 0 },
        .amplitude = SWAY_REACH,
        .frequency = SWAY_FREQUENCY,
        .weight    = SwayWeight.VERTEX_ALPHA,
    };
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint whole_centre;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        whole_centre = render_at(
            fixture: &fixture,
            target:  &line,
            view:    fixture.view,
            time:    (double)frame * SWAY_PERIOD,
        )!!;
    }
    uint background = render_at(
        fixture: &fixture,
        target:  &line,
        view:    fixture.view,
        time:    (double)SETTLE_FRAMES * SWAY_PERIOD,
        uv:      BACKGROUND_UV,
    )!!;
    assert(whole_centre == background);

    uint half_centre;
    for (uint frame = 1; frame <= SETTLE_FRAMES; frame++) {
        half_centre = render_at(
            fixture: &fixture,
            target:  &line,
            view:    fixture.view,
            time:    ((double)SETTLE_FRAMES + (double)frame / 2) * SWAY_PERIOD,
        )!!;
    }
    assert(pixels_differ(half_centre, background));
    check_validation(&fixture.renderer);
}

fn void test_faded_batch_leaves_view_shadow_and_cull_lists() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene walled = create_wall_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&walled.scene);
    InstancedMesh* batch = walled.scene.get(walled.mesh, InstancedMesh);
    uint[SHADOW_ROW_SAMPLES] hidden_row;
    uint[SHADOW_ROW_SAMPLES] faded_row;
    uint[SHADOW_ROW_SAMPLES] shown_row;
    uint[SHADOW_ROW_SAMPLES] ahead_row;

    walled.mesh.visible = false;
    uint hidden_centre = settle_and_sample(&fixture, &walled)!!;
    sample_row(&fixture, &walled, hidden_row[..])!!;
    walled.mesh.visible = true;
    uint shown_centre = settle_and_sample(&fixture, &walled)!!;
    sample_row(&fixture, &walled, shown_row[..])!!;
    bool shadowed;
    foreach (index, pixel : shown_row) shadowed |= pixels_differ(pixel, hidden_row[index]);
    assert(shadowed && pixels_differ(shown_centre, hidden_centre));

    batch.fade = FADE_BEYOND;
    bool[2] culling_modes = { true, false };
    foreach (culling : culling_modes) {
        set_view_culling(&fixture, culling)!!;
        sample_row(&fixture, &walled, faded_row[..])!!;
        foreach (index, pixel : faded_row) assert(pixel == hidden_row[index]);
        assert(settle_and_sample(&fixture, &walled)!! == hidden_centre);
        if (culling) assert(renderer.stats.instances_visible == 0 && renderer.stats.instances_tested > 0);
    }

    set_view_culling(&fixture, true)!!;
    batch.fade = FADE_AHEAD;
    sample_row(&fixture, &walled, ahead_row[..])!!;
    foreach (index, pixel : ahead_row) assert(pixel == shown_row[index]);
    assert(settle_and_sample(&fixture, &walled)!! == shown_centre);
    check_validation(renderer);
}

fn void test_sway_margin_keeps_instances_reaching_into_view() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&line.scene);
    InstancedMesh* batch = line.scene.get(line.mesh, InstancedMesh);
    batch.colors[LINE_CENTER + 3] = GREEN;
    line.scene.mark_instances_dirty(line.mesh);

    uint unswayed = settle_and_sample(&fixture, &line, REACHING_UV)!!;
    batch.sway = {
        .direction = { -1, 0, 0 },
        .amplitude = MARGIN_SWAY,
        .lean      = 1,
        .weight    = SwayWeight.VERTEX_ALPHA,
    };
    uint culled = settle_and_sample(&fixture, &line, REACHING_UV)!!;
    uint reaching = line_survivors(&fixture, &line, margin: MARGIN_SWAY);
    assert(reaching > line_survivors(&fixture, &line));
    assert(renderer.stats.instances_visible == VIEW_CULLING_PASSES * reaching);

    set_view_culling(&fixture, false)!!;
    uint unculled = settle_and_sample(&fixture, &line, REACHING_UV)!!;
    assert(culled == unculled);
    assert(pixels_differ(culled, unswayed));
    check_validation(renderer);
}

fn void test_custom_vertex_batch_sways_through_write_mesh_outputs() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ShaderId pulse;
    @pool() {
        pulse = add_pulse_shader(&fixture)!!;
    };
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    MaterialId custom = fixture.assets.add_material(material::custom(pulse, material::@as_bytes(still)))!!;
    DeformedScene line = create_line_scene(&fixture, custom)!!;
    defer scene::destroy_scene(&line.scene);
    line.scene.ambient_intensity = 1;

    RigidSamples centre = sample_rigid_sway(&fixture, &line, CENTER_UV)!!;
    RigidSamples side = sample_rigid_sway(&fixture, &line, SIDE_UV)!!;
    check_near_pixel(centre.swayed, centre.moved);
    check_near_pixel(side.swayed, side.moved);
    assert(pixels_differ(side.swayed, side.at_rest));
    check_validation(&fixture.renderer);
}

fn void test_vertex_alpha_weight_keeps_masked_coverage() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene faded = create_faded_batch_scene(&fixture)!!;
    defer scene::destroy_scene(&faded.scene);
    InstancedMesh* batch = faded.scene.get(faded.mesh, InstancedMesh);

    uint background = settle_and_sample(&fixture, &faded, BACKGROUND_UV)!!;
    batch.sway = { .weight = SwayWeight.VERTEX_ALPHA };
    uint consumed = settle_and_sample(&fixture, &faded)!!;
    check_opaque_color(consumed);
    assert(pixels_differ(consumed, background));

    batch.sway = { .weight = SwayWeight.HEIGHT };
    assert(settle_and_sample(&fixture, &faded)!! == background);
    check_validation(&fixture.renderer);
}
