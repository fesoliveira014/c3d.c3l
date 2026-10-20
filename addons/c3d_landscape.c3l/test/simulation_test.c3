module c3d_simulation_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::landscape::terrain;
import c3d::landscape::water;
import c3d::material;
import c3d::maths;
import c3d::scene;

const float POND_EXTENT @local = 32; // metres: 32 cells at the one-metre lattice
const float POND_CELL_SIZE @local = 1;
const float POND_SPEED @local = 4; // metres per second: one substep at the fixed rate
const float POND_DAMPING @local = 0.5f; // per second
const float SETTLE_EXTENT @local = 16; // metres: the smallest pond, whose slowest wave decays soonest
const float SETTLE_DAMPING @local = 1.5f; // per second: near the critical value of that pond's slowest wave
const Vec3 BUMP_CENTRE @local = { -5, 0, 3 }; // on lattice vertices
const float BUMP_RADIUS @local = 3;
const float BUMP_STRENGTH @local = 1; // metres per second
const double STEP_SECONDS @local = 1.0 / water::SIMULATION_RATE;
const double SLOW_FRAME_RATE @local = 30;
const double FAST_FRAME_RATE @local = 144;
const double SIMULATED_SECONDS @local = 1;
const double HALF_STEP @local = STEP_SECONDS / 2; // a drawn fraction inside a step, away from its boundaries
const float SAME_STATE_TOLERANCE @local = 1e-6f; // metres: the fraction differs by double rounding between schedules
const uint SETTLE_LIMIT_FRAMES @local = 60 * 30;
const uint QUIET_FRAMES @local = 30;
const uint WARM_FRAMES @local = 10;
const float FINITE_DIFFERENCE_TOLERANCE @local = 1e-3f; // metres per second; float rounding of a height difference
const float MOVING_MINIMUM @local = 0.01f; // metres per second: the sampled point visibly moves
const float NORMAL_TOLERANCE @local = 1e-5f;
const uint TERRAIN_TEXELS @local = 129; // one chunk
const float TERRAIN_HEIGHT_SCALE @local = 4;
const ushort TERRAIN_HIGH @local = 32768; // 2 m of the 4 m scale: above the pond's rest plane
const float POND_LEVEL @local = 1; // metres: ground at 2 m stands above it, ground at 0 does not
const Vec3 TERRAIN_POSITION @local = { -64, 0, -64 }; // the 128 m field centred under the pond
const uint PATCH_FIRST_COLUMN @local = 4; // lattice vertices of the dry patch; terrain texels are 48 further
const uint PATCH_FIRST_ROW @local = 2;
const uint PATCH_SIDE @local = 6;
const uint SILENT_FIRST_COLUMN @local = 20;
const uint SILENT_FIRST_ROW @local = 20;
const uint FIELD_OFFSET @local = 48; // terrain texels between the field's corner and the pond's

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    MaterialId layer;
}

fn void setup(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    terrain::register_terrain(&fixture.scene, &fixture.assets)!!;
    water::register_water(&fixture.scene, &fixture.assets)!!;
    fixture.layer = fixture.assets.add_material(material::standard({ .base_color = { 1, 1, 1, 1 }, .roughness = 1 }))!!;
}

fn void teardown(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn WaterDesc pond_desc() @local {
    WaterDesc desc = water::default_water_desc();
    desc.wave_model = SIMULATED;
    desc.wave_count = 0;
    desc.extent = POND_EXTENT;
    desc.cell_size = POND_CELL_SIZE;
    desc.simulation = { .wave_speed = POND_SPEED, .damping = POND_DAMPING };
    return desc;
}

fn Node* add_pond(Fixture* fixture, WaterDesc desc, float level = 0) @local {
    Node* node = fixture.scene.add_node(name: "pond")!!;
    node.local.position = { 0, level, 0 };
    fixture.scene.update_world();
    try_add(fixture, node, desc)!!;
    return node;
}

fn void update_water(Fixture* fixture, double time) @local {
    water::update(
        scene:         &fixture.scene,
        assets:        &fixture.assets,
        wind_velocity: {},
        time:          time,
    );
}

fn void? try_impulse(
    Fixture* fixture,
    Entity node,
    Vec3 position = BUMP_CENTRE,
    float radius = BUMP_RADIUS,
    float strength = BUMP_STRENGTH,
) @local {
    return water::add_impulse(
        scene:          &fixture.scene,
        node:           node,
        world_position: position,
        radius:         radius,
        strength:       strength,
    );
}

fn SimulationState* state_of(Fixture* fixture, Node* node) @local {
    return fixture.scene.get(node, WaterRuntime).simulation;
}

fn uint upload_count(Fixture* fixture, SimulationState* state) @local {
    return fixture.assets.texture(state.texture).header.revision;
}

fn float drawn_height(Fixture* fixture, Node* node, float x, float z) @local {
    SurfaceView view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;
    return water::sample_surface(
        view:    &view,
        world_x: x,
        world_z: z,
        time:    0,
    )!!;
}

fn void? try_add(Fixture* fixture, Node* node, WaterDesc desc) @local {
    return water::add_water(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

fn void? try_attach(Fixture* fixture, Node* node, WaterDesc desc) @local {
    return water::attach_water(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

fn void? try_set_desc(Fixture* fixture, Node* node, WaterDesc desc) @local {
    return water::set_desc(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

fn void assert_fault(fault excuse, fault expected, String what) @local {
    assert(excuse, "%s was accepted.", what);
    assert(excuse == expected, "%s faulted %s.", what, excuse);
}

// Frames at the rate for a simulated second, then one frame half a step further.
fn void run_pond(Fixture* fixture, Node* node, double frame_rate) @local {
    for (uint frame = 0; (double)frame <= SIMULATED_SECONDS * frame_rate; frame++) {
        update_water(fixture, (double)frame / frame_rate);
        if (frame == 0) try_impulse(fixture, node.id)!!;
    }
    update_water(fixture, SIMULATED_SECONDS + HALF_STEP);
}

fn void test_simulation_does_not_depend_on_frame_rate() @test {
    Fixture slow;
    Fixture fast;
    setup(&slow);
    defer teardown(&slow);
    setup(&fast);
    defer teardown(&fast);
    Node* slow_pond = add_pond(&slow, pond_desc());
    Node* fast_pond = add_pond(&fast, pond_desc());

    run_pond(&slow, slow_pond, SLOW_FRAME_RATE);
    run_pond(&fast, fast_pond, FAST_FRAME_RATE);

    SimulationState* slow_state = state_of(&slow, slow_pond);
    SimulationState* fast_state = state_of(&fast, fast_pond);
    foreach (index, height : slow_state.height) {
        assert(height == fast_state.height[index], "step state differs at %d", index);
    }
    assert(math::abs(slow_state.fraction - 0.5f) <= SAME_STATE_TOLERANCE);
    assert(math::abs(fast_state.fraction - 0.5f) <= SAME_STATE_TOLERANCE);
    Vec2[3] points = { { -5, 3 }, { -2.25f, 0.5f }, { 7.5f, -6 } };
    foreach (point : points) {
        float slow_height = drawn_height(&slow, slow_pond, point.x, point.y);
        float fast_height = drawn_height(&fast, fast_pond, point.x, point.y);
        assert(math::abs(slow_height - fast_height) <= SAME_STATE_TOLERANCE, "%f against %f", slow_height, fast_height);
    }
    assert(math::abs(drawn_height(&slow, slow_pond, BUMP_CENTRE.x, BUMP_CENTRE.z)) > SAME_STATE_TOLERANCE);
}

fn void test_simulation_settles_and_stops_uploading() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = pond_desc();
    desc.extent = SETTLE_EXTENT;
    desc.simulation.damping = SETTLE_DAMPING;
    Node* pond = add_pond(&fixture, desc);
    SimulationState* state = state_of(&fixture, pond);
    uint resting_uploads = upload_count(&fixture, state);

    double time;
    for (uint frame = 0; frame < QUIET_FRAMES; frame++) update_water(&fixture, time += STEP_SECONDS);
    assert(upload_count(&fixture, state) == resting_uploads, "a pond at rest uploaded");

    try_impulse(&fixture, pond.id)!!;
    assert(state.awake);
    uint frames;
    while (state.awake && frames < SETTLE_LIMIT_FRAMES) {
        uint before = upload_count(&fixture, state);
        update_water(&fixture, time += STEP_SECONDS);
        frames++;
        assert(upload_count(&fixture, state) == before + 1, "an awake frame must upload once, in place");
    }
    assert(!state.awake, "the pond never settled");
    assert(frames > QUIET_FRAMES, "it settled before it rippled");

    // The last upload drew it flat, and nothing follows.
    uint settled_uploads = upload_count(&fixture, state);
    char[] pixels = fixture.assets.texture(state.texture).pixels;
    foreach (byte : pixels) assert(byte == 0, "the settled texture is not flat");
    for (uint frame = 0; frame < QUIET_FRAMES; frame++) update_water(&fixture, time += STEP_SECONDS);
    assert(upload_count(&fixture, state) == settled_uploads, "a settled pond uploaded");
    assert(drawn_height(&fixture, pond, BUMP_CENTRE.x, BUMP_CENTRE.z) == 0);

    try_impulse(&fixture, pond.id)!!;
    update_water(&fixture, time += STEP_SECONDS);
    assert(state.awake && upload_count(&fixture, state) == settled_uploads + 1, "an impulse did not wake the pond");
}

fn void test_add_impulse_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* pond = add_pond(&fixture, pond_desc());
    Node* gerstner = fixture.scene.add_node()!!;
    WaterDesc waves = pond_desc();
    waves.wave_model = GERSTNER;
    waves.wave_count = 2;
    try_add(&fixture, gerstner, waves)!!;
    Node* pending = fixture.scene.add_node()!!;
    try_attach(&fixture, pending, pond_desc())!!;
    Node* plain = fixture.scene.add_node()!!;
    Node* removed = fixture.scene.add_node()!!;
    Entity dead = removed.id;
    fixture.scene.remove(removed);

    assert_fault(@catch(try_impulse(&fixture, dead)), c3d::INVALID_ID, "A dead node");
    assert_fault(@catch(try_impulse(&fixture, plain.id)), c3d::INVALID_ID, "A node without water");
    assert_fault(@catch(try_impulse(&fixture, gerstner.id)), c3d::INVALID_ID, "A Gerstner body");
    assert_fault(@catch(try_impulse(&fixture, pending.id)), c3d::INVALID_ID, "A pending body");
    Vec3[2] positions = { { float::nan, 0, 0 }, { 0, float::inf, 0 } };
    foreach (position : positions) {
        assert_fault(@catch(try_impulse(&fixture, pond.id, position: position)), c3d::INVALID_ARGUMENT, "A position");
    }
    float[4] radii = { 0, -1, float::nan, float::inf };
    foreach (radius : radii) {
        assert_fault(@catch(try_impulse(&fixture, pond.id, radius: radius)), c3d::INVALID_ARGUMENT, "A radius");
    }
    float[3] strengths = { -0.5f, float::nan, float::inf };
    foreach (strength : strengths) {
        assert_fault(@catch(try_impulse(&fixture, pond.id, strength: strength)), c3d::INVALID_ARGUMENT, "A strength");
    }
    assert(!state_of(&fixture, pond).awake, "a rejected impulse woke the pond");

    try_impulse(&fixture, pond.id, position: { 400, 0, 0 })!!;
    assert(!state_of(&fixture, pond).awake, "an impulse outside the grid woke the pond");
}

fn void test_impulse_conserves_volume() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* pond = add_pond(&fixture, pond_desc());
    SimulationState* state = state_of(&fixture, pond);
    try_impulse(&fixture, pond.id)!!;

    double total_speed;
    float lowest;
    foreach (speed : state.speed) {
        total_speed += (double)speed;
        lowest = min(lowest, speed);
    }
    assert(math::abs(total_speed) <= 1e-3, "the push left %f of net velocity", total_speed);
    assert(lowest < -0.95f * BUMP_STRENGTH && lowest > -BUMP_STRENGTH, "the centre falls at %f", -lowest);
}

fn TextureId add_ground(Fixture* fixture, Node* node) @local {
    TextureId height_map;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)TERRAIN_TEXELS * TERRAIN_TEXELS * ushort::size);
        TextureDesc texture = material::texture_2d_desc(TERRAIN_TEXELS, TERRAIN_TEXELS, R16_UINT);
        texture.generate_mips = false;
        height_map = fixture.assets.add_texture(texture, pixels)!!;
    };
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = height_map;
    desc.cell_size = 1;
    desc.height_scale = TERRAIN_HEIGHT_SCALE;
    desc.layers[0] = fixture.layer;
    node.local.position = TERRAIN_POSITION;
    fixture.scene.update_world();
    terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    )!!;
    return height_map;
}

// Writes the square of lattice vertices of the pond, as terrain texels, without telling the terrain.
fn void write_patch(
    Fixture* fixture,
    TextureId height_map,
    uint first_column,
    uint first_row,
    ushort value,
) @local {
    ushort* texels = (ushort*)fixture.assets.texture(height_map).pixels.ptr;
    for (uint row = 0; row < PATCH_SIDE; row++) {
        for (uint column = 0; column < PATCH_SIDE; column++) {
            texels[(FIELD_OFFSET + first_row + row) * TERRAIN_TEXELS + FIELD_OFFSET + first_column + column] = value;
        }
    }
}

fn void report_patch(Fixture* fixture, Node* ground, uint first_column, uint first_row) @local {
    terrain::mark_dirty(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   ground,
        rect:   {
            .x       = FIELD_OFFSET + first_column,
            .z       = FIELD_OFFSET + first_row,
            .columns = PATCH_SIDE,
            .rows    = PATCH_SIDE,
        },
    )!!;
    terrain::update(&fixture.scene, &fixture.assets)!!;
}

fn bool in_patch(SimulationState* state, usz index, uint first_column, uint first_row) @local {
    uint column = (uint)(index % state.texels);
    uint row = (uint)(index / state.texels);
    return column >= first_column && column < first_column + PATCH_SIDE
        && row >= first_row && row < first_row + PATCH_SIDE;
}

fn void test_dry_cells_follow_ground_edits() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = fixture.scene.add_node(name: "ground")!!;
    TextureId height_map = add_ground(&fixture, ground);
    WaterDesc desc = pond_desc();
    desc.ground = ground.id;
    Node* pond = add_pond(&fixture, desc, POND_LEVEL);
    SimulationState* state = state_of(&fixture, pond);
    usz vertices = state.height.len;
    assert(state.wet_count == vertices, "flat ground under the rest plane left dry cells");

    double time;
    update_water(&fixture, time);
    try_impulse(&fixture, pond.id)!!;
    for (uint frame = 0; frame < WARM_FRAMES; frame++) update_water(&fixture, time += STEP_SECONDS);
    float[] before = alloc::new_array(mem, float, (sz)vertices);
    defer alloc::free(mem, before.ptr);
    before[..] = state.height[..];

    // An edit that is reported dries its vertices and nothing else; one that is not reported stays wet.
    write_patch(&fixture, height_map, PATCH_FIRST_COLUMN, PATCH_FIRST_ROW, TERRAIN_HIGH);
    write_patch(&fixture, height_map, SILENT_FIRST_COLUMN, SILENT_FIRST_ROW, TERRAIN_HIGH);
    report_patch(&fixture, ground, PATCH_FIRST_COLUMN, PATCH_FIRST_ROW);
    update_water(&fixture, time);
    assert(state.wet_count == vertices - PATCH_SIDE * PATCH_SIDE, "dry cells: %d", vertices - state.wet_count);
    foreach (index, wet : state.wet) {
        bool dried = in_patch(state, (usz)index, PATCH_FIRST_COLUMN, PATCH_FIRST_ROW);
        assert(wet != dried, "vertex %d is %s", index, wet ? "wet" : "dry");
        float expected = dried ? 0 : before[index];
        assert(state.height[index] == expected, "vertex %d moved by the mask", index);
    }

    // A revision no refresh accounts for re-masks the whole grid, which finds the unreported edit too.
    fixture.assets.mark_texture_dirty(height_map);
    terrain::update(&fixture.scene, &fixture.assets)!!;
    update_water(&fixture, time);
    assert(state.wet_count == vertices - 2 * PATCH_SIDE * PATCH_SIDE, "dry cells: %d", vertices - state.wet_count);

    // Lowering the ground wets its vertices again.
    write_patch(&fixture, height_map, PATCH_FIRST_COLUMN, PATCH_FIRST_ROW, 0);
    report_patch(&fixture, ground, PATCH_FIRST_COLUMN, PATCH_FIRST_ROW);
    update_water(&fixture, time);
    assert(state.wet_count == vertices - PATCH_SIDE * PATCH_SIDE);

    // Without its ground the pond is wet everywhere.
    fixture.scene.remove(ground);
    update_water(&fixture, time);
    assert(state.wet_count == vertices && !state.masked, "a removed ground left a mask");
}

fn void test_ground_must_be_a_terrain_node() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* plain = fixture.scene.add_node()!!;
    Node* removed = fixture.scene.add_node()!!;
    Entity dead = removed.id;
    fixture.scene.remove(removed);
    Node* node = fixture.scene.add_node()!!;

    WaterDesc without_terrain = pond_desc();
    without_terrain.ground = plain.id;
    assert_fault(@catch(try_add(&fixture, node, without_terrain)), c3d::INVALID_ARGUMENT, "A ground without a terrain");
    WaterDesc dead_ground = pond_desc();
    dead_ground.ground = dead;
    assert_fault(@catch(try_add(&fixture, node, dead_ground)), c3d::INVALID_ID, "A dead ground");
    assert(!fixture.scene.has(node, Water));
}

fn void test_simulated_twin_reads_the_grid() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* pond = add_pond(&fixture, pond_desc(), POND_LEVEL);
    SimulationState* state = state_of(&fixture, pond);
    double time;
    update_water(&fixture, time);
    try_impulse(&fixture, pond.id, position: { -5, POND_LEVEL, 3 })!!;
    for (uint frame = 0; frame < WARM_FRAMES; frame++) update_water(&fixture, time += STEP_SECONDS);
    update_water(&fixture, time += HALF_STEP);
    SurfaceView view = water::surface_view(&fixture.scene, &fixture.assets, pond.id)!!;
    float fraction = state.fraction;
    assert(fraction > 0.4f && fraction < 0.6f);

    // The cell at (-5, 3) has vertices the bump moved unevenly, so its two diagonals differ.
    uint column = (uint)(-5 - state.origin);
    uint row = (uint)(3 - state.origin);
    usz corner_00 = (usz)row * state.texels + column;
    usz corner_10 = corner_00 + 1;
    usz corner_01 = corner_00 + state.texels;
    usz corner_11 = corner_01 + 1;
    float h_00 = POND_LEVEL + drawn(state, corner_00);
    float h_10 = POND_LEVEL + drawn(state, corner_10);
    float h_01 = POND_LEVEL + drawn(state, corner_01);
    float h_11 = POND_LEVEL + drawn(state, corner_11);

    // On the lattice the query is the vertex; inside the cell it follows the triangle on the diagonal (x + 1, z) to
    // (x, z + 1).
    assert(math::abs(sample(&view, -5, 3) - h_00) <= SAME_STATE_TOLERANCE);
    float lower = sample(&view, -4.75f, 3.125f);
    float lower_expected = h_00 + 0.25f * (h_10 - h_00) + 0.125f * (h_01 - h_00);
    assert(math::abs(lower - lower_expected) <= SAME_STATE_TOLERANCE, "%f against %f", lower, lower_expected);
    float upper = sample(&view, -4.25f, 3.5f);
    float upper_expected = h_11 + 0.25f * (h_01 - h_11) + 0.5f * (h_10 - h_11);
    assert(math::abs(upper - upper_expected) <= SAME_STATE_TOLERANCE, "%f against %f", upper, upper_expected);
    float bilinear = (h_00 * 0.75f + h_10 * 0.25f) * 0.5f + (h_01 * 0.75f + h_11 * 0.25f) * 0.5f;
    assert(math::abs(upper - bilinear) > 10 * SAME_STATE_TOLERANCE, "the twin interpolates on the wrong diagonal");

    // The detail's height is the query's, and the normal is the vertices' central differences, blended.
    WaterSample detail = detail_at(&view, -4.75f, 3.125f);
    assert(detail.height == lower && detail.residual == 0);
    assert(math::abs(detail.normal.length() - 1) <= NORMAL_TOLERANCE);
    Vec3 vertex_normal = grid_normal(state, column, row);
    Vec3 at_vertex = detail_at(&view, -5, 3).normal;
    assert((at_vertex - vertex_normal).length() <= NORMAL_TOLERANCE, "the normal is not the vertex's");

    // The velocity is the slope in time of the drawn height, which moves linearly between steps.
    float climb = detail_at(&view, -4.75f, 3.125f).velocity.y;
    double later = time + STEP_SECONDS / 8;
    update_water(&fixture, later);
    float rise = drawn_height(&fixture, pond, -4.75f, 3.125f) - lower;
    float measured = rise / (float)(STEP_SECONDS / 8);
    assert(math::abs(measured - climb) <= FINITE_DIFFERENCE_TOLERANCE, "%f against %f", measured, climb);
    assert(math::abs(climb) > MOVING_MINIMUM, "the sampled point does not move");

    float? off_grid = water::sample_surface(
        view:    &view,
        world_x: 40,
        world_z: 0,
        time:    0,
    );
    assert_fault(@catch(off_grid), NOT_FOUND, "A point off the grid");
}

fn float drawn(SimulationState* state, usz index) @local {
    return state.prior[index] + (state.height[index] - state.prior[index]) * state.fraction;
}

fn WaterSample detail_at(SurfaceView* view, float x, float z) @local {
    return water::sample_surface_detail(
        view:    view,
        world_x: x,
        world_z: z,
        time:    0,
    )!!;
}

fn float sample(SurfaceView* view, float x, float z) @local {
    return water::sample_surface(
        view:    view,
        world_x: x,
        world_z: z,
        time:    0,
    )!!;
}

fn Vec3 grid_normal(SimulationState* state, uint column, uint row) @local {
    usz at = (usz)row * state.texels + column;
    float across = (drawn(state, at + 1) - drawn(state, at - 1)) / (2 * state.spacing);
    float down = (drawn(state, at + state.texels) - drawn(state, at - state.texels)) / (2 * state.spacing);
    Vec3 normal = { -across, 1, -down };
    return normal.normalize();
}

fn void test_simulated_reach_is_the_height_clamp() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* pond = add_pond(&fixture, pond_desc(), POND_LEVEL);
    WaterRuntime* runtime = fixture.scene.get(pond, WaterRuntime);

    Aabb bounds = fixture.scene.get(pond, Mesh).local_bounds;
    assert(bounds.min.y == -water::SIMULATION_MAX_HEIGHT && bounds.max.y == water::SIMULATION_MAX_HEIGHT);
    assert(bounds.min.x == -POND_EXTENT / 2 && bounds.max.x == POND_EXTENT / 2);
    assert(math::abs(runtime.clip_plane.d - (water::SIMULATION_MAX_HEIGHT - POND_LEVEL)) <= 1e-6f);
    Node* medium = fixture.scene.node(runtime.medium_node);
    assert(math::abs(medium.local.position.y + water::SIMULATION_MAX_HEIGHT + water::MEDIUM_SKIN) <= 1e-6f);

    // Only the clamp bounds a simulated height, whatever the push.
    SimulationState* state = runtime.simulation;
    foreach (&speed : state.speed) *speed = -1000;
    state.awake = true;
    double time;
    update_water(&fixture, time);
    for (uint frame = 0; frame < WARM_FRAMES; frame++) update_water(&fixture, time += STEP_SECONDS);
    float lowest;
    foreach (height : state.height) lowest = min(lowest, height);
    assert(lowest == -water::SIMULATION_MAX_HEIGHT, "the lowest height is %f", lowest);
}

fn void test_simulated_set_desc_keeps_its_grid() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* pond = add_pond(&fixture, pond_desc());
    SimulationState* state = state_of(&fixture, pond);

    WaterDesc edited = fixture.scene.get(pond, Water).desc;
    edited.simulation.wave_speed *= 2;
    try_set_desc(&fixture, pond, edited)!!;
    assert(state_of(&fixture, pond) == state);
    assert(fixture.scene.get(pond, WaterRuntime).desc.simulation.wave_speed == 2 * POND_SPEED);

    WaterDesc wider = edited;
    wider.extent *= 2;
    assert_fault(@catch(try_set_desc(&fixture, pond, wider)), c3d::INVALID_ARGUMENT, "An extent change");
    WaterDesc gerstner = edited;
    gerstner.wave_model = GERSTNER;
    assert_fault(@catch(try_set_desc(&fixture, pond, gerstner)), c3d::INVALID_ARGUMENT, "A wave model change");
    WaterDesc fast = edited;
    fast.simulation.wave_speed = 1000;
    assert_fault(@catch(try_set_desc(&fixture, pond, fast)), c3d::INVALID_ARGUMENT, "A speed past the substep cap");

    fault sea_state = @catch(water::set_sea_state(
        scene:              &fixture.scene,
        assets:             &fixture.assets,
        node:               pond.id,
        wind_velocity:      { 5, 0 },
        transition_seconds: 1,
    ));
    assert_fault(sea_state, c3d::UNSUPPORTED, "A sea state on a simulated body");
}

fn void test_spectral_water_waits_for_its_surface() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = water::default_water_desc();
    desc.wave_model = SPECTRAL;
    desc.extent = 64;
    desc.cell_size = 1;
    Node* node = fixture.scene.add_node()!!;
    uint materials = fixture.assets.materials.free_count;

    try_attach(&fixture, node, desc)!!;
    assert_fault(@catch(water::prepare(&fixture.scene, &fixture.assets, node)), c3d::UNSUPPORTED, "A spectral surface");
    assert(!water::is_prepared(&fixture.scene, node) && fixture.assets.materials.free_count == materials);
}
