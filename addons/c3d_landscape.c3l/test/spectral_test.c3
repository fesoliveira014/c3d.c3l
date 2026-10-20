module c3d_spectral_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::landscape::water;
import c3d::maths;
import c3d::scene;

const float LAKE_EXTENT @local = 512; // metres: a fetch long enough for a developed sea
const float LAKE_CELL_SIZE @local = 2;
const uint OTHER_SEED @local = 7;
const Vec2 STORM_WIND @local = { 18, 0 }; // metres per second
const Vec2 BREEZE_WIND @local = { 4, 0 };
const float BLEND_SECONDS @local = 2;
const double BLEND_END @local = 3; // seconds: past the blend that starts at the first update after the call
const double FIRST_UPDATE @local = 1;
const float RELATIVE_TOLERANCE @local = 1e-4f;

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
}

fn void setup(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    water::register_water(&fixture.scene, &fixture.assets)!!;
}

fn void teardown(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn WaterDesc lake_desc(uint seed) @local {
    WaterDesc desc = water::default_water_desc();
    desc.wave_model = SPECTRAL;
    desc.wave_count = 0;
    desc.extent = LAKE_EXTENT;
    desc.cell_size = LAKE_CELL_SIZE;
    desc.spectrum.seed = seed;
    return desc;
}

fn Node* add_lake(Fixture* fixture, WaterDesc desc) @local {
    Node* node = fixture.scene.add_node(name: "lake")!!;
    fixture.scene.update_world();
    water::add_water(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    )!!;
    return node;
}

fn SpectralState* state_of(Fixture* fixture, Node* node) @local {
    return fixture.scene.get(node, WaterRuntime).spectral;
}

fn void update_water(Fixture* fixture, double time) @local {
    water::update(
        scene:         &fixture.scene,
        assets:        &fixture.assets,
        wind_velocity: {},
        time:          time,
    );
}

fn void set_sea(Fixture* fixture, Node* node, Vec2 wind, float seconds) @local {
    water::set_sea_state(
        scene:              &fixture.scene,
        assets:             &fixture.assets,
        node:               node.id,
        wind_velocity:      wind,
        transition_seconds: seconds,
    )!!;
}

fn void assert_fault(fault excuse, fault expected, String what) @local {
    assert(excuse, "%s was accepted.", what);
    assert(excuse == expected, "%s faulted %s.", what, excuse);
}

fn void test_spectrum_init_is_deterministic() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* first = add_lake(&fixture, lake_desc(water::DEFAULT_SPECTRUM_SEED));
    Node* same = add_lake(&fixture, lake_desc(water::DEFAULT_SPECTRUM_SEED));
    Node* other = add_lake(&fixture, lake_desc(OTHER_SEED));

    char[] table = fixture.assets.texture(state_of(&fixture, first).table).pixels;
    char[] repeated = fixture.assets.texture(state_of(&fixture, same).table).pixels;
    char[] reseeded = fixture.assets.texture(state_of(&fixture, other).table).pixels;
    assert(table.len == repeated.len && table[..] == repeated[..], "the same seed built another spectrum");
    assert(table[..] != reseeded[..], "another seed built the same spectrum");
}

// The variance of the components outside the twin, from the table alone.
fn double omitted_variance(Fixture* fixture, SpectralState* state) @local {
    float[4]* texels = (float[4]*)fixture.assets.texture(state.table).pixels.ptr;
    double total;
    foreach (index, &texel : texels[:(usz)water::SPECTRAL_SIZE * water::SPECTRAL_SIZE]) {
        total += 2.0 * ((double)(*texel)[0] * (*texel)[0] + (double)(*texel)[1] * (*texel)[1])
            * (double)(*texel)[3] * (*texel)[3];
    }
    foreach (&wave : state.twin[:state.twin_count]) {
        float[4]* texel = &texels[wave.row * water::SPECTRAL_SIZE + wave.column];
        total -= 2.0 * ((double)(*texel)[0] * (*texel)[0] + (double)(*texel)[1] * (*texel)[1])
            * (double)(*texel)[3] * (*texel)[3];
    }
    return total;
}

fn void test_spectral_twin_reports_its_bound() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* lake = add_lake(&fixture, lake_desc(water::DEFAULT_SPECTRUM_SEED));
    SpectralState* state = state_of(&fixture, lake);
    WaterRuntime* runtime = fixture.scene.get(lake, WaterRuntime);

    assert(state.twin_count == water::SPECTRAL_TWIN_WAVES);
    double expected = water::SPECTRAL_BOUND_SIGMAS * math::sqrt(omitted_variance(&fixture, state));
    assert(runtime.spectral_bound > 0);
    assert(math::abs((double)runtime.spectral_bound - expected) <= expected * RELATIVE_TOLERANCE);
    assert(state.envelope == water::SPECTRAL_ENVELOPE_SIGMAS * state.sigma);

    // No component left out is stronger than one the twin keeps.
    float[4]* texels = (float[4]*)fixture.assets.texture(state.table).pixels.ptr;
    double weakest = double::max;
    foreach (&wave : state.twin[:state.twin_count]) weakest = min(weakest, (double)wave.gauss_magnitude * wave.right);
    foreach (index, &texel : texels[:(usz)water::SPECTRAL_SIZE * water::SPECTRAL_SIZE]) {
        bool kept;
        foreach (&wave : state.twin[:state.twin_count]) {
            if ((usz)(wave.row * water::SPECTRAL_SIZE + wave.column) == (usz)index) kept = true;
        }
        double strength = math::sqrt((double)(*texel)[0] * (*texel)[0] + (double)(*texel)[1] * (*texel)[1])
            * (double)(*texel)[3];
        assert(kept || strength <= weakest, "a stronger component was left out");
    }
}

fn void test_spectral_bounds_follow_the_sea_state() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* lake = add_lake(&fixture, lake_desc(water::DEFAULT_SPECTRUM_SEED));
    SpectralState* state = state_of(&fixture, lake);
    WaterRuntime* runtime = fixture.scene.get(lake, WaterRuntime);

    set_sea(&fixture, lake, STORM_WIND, 0);
    update_water(&fixture, 0);
    float storm = state.envelope;
    float storm_offset = -fixture.scene.node(runtime.medium_node).local.position.y;
    assert(storm_offset == storm + water::MEDIUM_SKIN, "the medium does not sit under the envelope");

    set_sea(&fixture, lake, BREEZE_WIND, BLEND_SECONDS);
    update_water(&fixture, FIRST_UPDATE);
    assert(state.envelope >= storm, "the bounds shrank while the storm was still blending out");
    update_water(&fixture, BLEND_END);
    assert(state.stage == SpectralStage.IDLE);
    assert(state.envelope < storm / 2, "a calm sea kept the storm's bounds");
    float calm_offset = -fixture.scene.node(runtime.medium_node).local.position.y;
    assert(calm_offset == state.envelope + water::MEDIUM_SKIN, "the medium did not follow the calm sea");
}

fn void test_spectral_spectrum_is_fixed_for_the_life_of_the_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* lake = add_lake(&fixture, lake_desc(water::DEFAULT_SPECTRUM_SEED));

    WaterDesc choppier = lake_desc(water::DEFAULT_SPECTRUM_SEED);
    choppier.spectrum.choppiness *= 2;
    fault edit = @catch(water::set_desc(&fixture.scene, &fixture.assets, lake, choppier));
    assert_fault(edit, c3d::INVALID_ARGUMENT, "A spectrum edit");

    WaterDesc rougher = lake_desc(water::DEFAULT_SPECTRUM_SEED);
    rougher.roughness = 0.2f;
    water::set_desc(&fixture.scene, &fixture.assets, lake, rougher)!!;
}

fn void test_spectral_spectrum_is_checked() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;

    WaterDesc flat = lake_desc(water::DEFAULT_SPECTRUM_SEED);
    flat.spectrum.patch_size = 0;
    assert_fault(
        @catch(water::attach_water(&fixture.scene, &fixture.assets, node, flat)),
        c3d::INVALID_ARGUMENT,
        "A patch of no size",
    );
    WaterDesc inverted = lake_desc(water::DEFAULT_SPECTRUM_SEED);
    inverted.spectrum.choppiness = -1;
    assert_fault(
        @catch(water::attach_water(&fixture.scene, &fixture.assets, node, inverted)),
        c3d::INVALID_ARGUMENT,
        "A negative choppiness",
    );
}

fn void test_spectral_sea_state_needs_a_prepared_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;
    water::attach_water(&fixture.scene, &fixture.assets, node, lake_desc(water::DEFAULT_SPECTRUM_SEED))!!;

    fault pending = @catch(water::set_sea_state(
        scene:              &fixture.scene,
        assets:             &fixture.assets,
        node:               node.id,
        wind_velocity:      STORM_WIND,
        transition_seconds: 0,
    ));
    assert_fault(pending, c3d::UNSUPPORTED, "A sea state on a pending spectral body");
}
