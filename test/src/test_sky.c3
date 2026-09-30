module c3d::test::sky;

import c3d;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint REFERENCE_STEPS @local = 100_000;
const double TRANSMITTANCE_TOLERANCE @local = 0.0035; // the interview's 0.35 % worst case of the 64-step march
const double RISE_TOLERANCE @local = 1e-6;
const float DEGREE @local = (float)math::PI / 180;
const Vec3 SUN_COLOR @local = { 1, 0.9f, 0.8f };
const float SUN_INTENSITY @local = 3;
const Vec3 SECOND_COLOR @local = { 0.2f, 0.4f, 0.6f };
const float DRIFT_STEP @local = 0.09f; // degrees; five steps stay clear of the half-degree threshold, six pass it
const Vec3 FOG_ORIGIN @local = { 0, 10, 0 };

struct TransmittanceCase @local {
    float altitude;
    float cos_zenith;
}

fn double[3] reference_transmittance(Atmosphere* atmosphere, double altitude, double cos_zenith) @local {
    double ground = atmosphere.planet_radius;
    double top = ground + atmosphere.atmosphere_height;
    double radius = ground + altitude;
    double[3] zero;
    if (cos_zenith < 0 && radius * radius * (cos_zenith * cos_zenith - 1) + ground * ground >= 0) return zero;
    double length = -radius * cos_zenith + math::sqrt(radius * radius * (cos_zenith * cos_zenith - 1) + top * top);
    double step = length / REFERENCE_STEPS;
    double[3] depth;
    for (uint index = 0; index < REFERENCE_STEPS; index++) {
        double along = ((double)index + 0.5) * step;
        double height = math::sqrt(radius * radius + along * along + 2 * radius * cos_zenith * along) - ground;
        double rayleigh = math::exp(-height / atmosphere.rayleigh_scale_height);
        double mie = math::exp(-height / atmosphere.mie_scale_height);
        double ozone_offset = math::abs(height - atmosphere.ozone_center_altitude);
        double ozone = math::max(0.0, 1 - ozone_offset / atmosphere.ozone_half_width);
        for (uint channel = 0; channel < 3; channel++) {
            double extinction = (double)atmosphere.rayleigh_scattering[channel] * rayleigh
                + ((double)atmosphere.mie_scattering + atmosphere.mie_absorption) * mie
                + (double)atmosphere.ozone_absorption[channel] * ozone;
            depth[channel] += extinction * step;
        }
    }
    double[3] result;
    for (uint channel = 0; channel < 3; channel++) result[channel] = math::exp(-depth[channel]);
    return result;
}

fn Vec3 elevated(float elevation) @local {
    return { math::cos(elevation), math::sin(elevation), 0 };
}

fn float limit_from(HeightFog* fog, Vec3 direction) @local {
    return light::height_fog_limit_transmittance(
        fog:         fog,
        base_height: 0,
        origin:      FOG_ORIGIN,
        direction:   direction,
    );
}

fn float transmittance_over(HeightFog* fog, Vec3 direction, float distance) @local {
    return light::height_fog_transmittance(
        fog:         fog,
        base_height: 0,
        origin:      FOG_ORIGIN,
        direction:   direction,
        distance:    distance,
    );
}

fn bool moved(render::SkyRegeneration* generated, Atmosphere* atmosphere, Vec3 to_sun) @local {
    return render::sky_regeneration_due(
        generated:  generated,
        atmosphere: atmosphere,
        to_sun:     to_sun,
        sun_color:  SUN_COLOR,
    );
}

fn void aim_sun(Scene* scene, Node* node, Vec3 to_sun) @local {
    Vec3 up = math::abs(to_sun.y) > 0.99f ? (Vec3){ 0, 0, -1 } : (Vec3){ 0, 1, 0 };
    node.local.rotation = maths::look_rotation(-to_sun, up);
    scene.update_world();
}

fn LightExtraction extract_all(Scene* scene, AtmosphereSelection* atmosphere, LightCounts* counts) @local {
    return render::extract_lights(
        allocator:   tmem,
        scene:       scene,
        frustum:     null,
        view_layers: uint::max,
        capacity:    4,
        counts:      counts,
        atmosphere:  atmosphere,
        altitude:    0,
    );
}

fn void test_sun_radiance_matches_the_double_reference() @test {
    Atmosphere atmosphere = light::ATMOSPHERE_EARTH;
    Light sun = light::directional(SUN_COLOR, SUN_INTENSITY);
    TransmittanceCase[6] cases = {
        { .altitude = 0, .cos_zenith = 1 },
        { .altitude = 0, .cos_zenith = 0.5f },
        { .altitude = 0, .cos_zenith = 0.0871557f },
        { .altitude = 1_000, .cos_zenith = -0.01f },
        { .altitude = 10_000, .cos_zenith = 0.1f },
        { .altitude = 0, .cos_zenith = 0.02f },
    };
    foreach (test_case : cases) {
        Vec3 to_sun = { math::sqrt(1 - test_case.cos_zenith * test_case.cos_zenith), test_case.cos_zenith, 0 };
        Vec3 radiance = light::sun_radiance(
            atmosphere: &atmosphere,
            sun:        &sun,
            to_sun:     to_sun,
            altitude:   test_case.altitude,
        );
        double[3] reference = reference_transmittance(&atmosphere, test_case.altitude, test_case.cos_zenith);
        for (uint channel = 0; channel < 3; channel++) {
            double expected = reference[channel] * SUN_COLOR[channel] * SUN_INTENSITY;
            double error = math::abs((double)radiance[channel] - expected) / expected;
            assert(error <= TRANSMITTANCE_TOLERANCE, "altitude %f cos %f channel %d: %f", test_case.altitude,
                test_case.cos_zenith, channel, error);
        }
    }
    assert(light::atmosphere_transmittance(&atmosphere, 0, math::sin(-5 * DEGREE)) == (Vec3){});
    assert(light::atmosphere_transmittance(&atmosphere, -50, 1) == light::atmosphere_transmittance(&atmosphere, 0, 1));
}

fn void test_fog_rise_factor_matches_double_near_level_rays() @test {
    double[5] rises = { 1e-7, 1e-3, 1e-2, 1, -1e-3 };
    foreach (rise : rises) {
        double expected = (1 - math::exp(-rise)) / rise;
        double error = math::abs((double)light::fog_rise_factor((float)rise) - expected) / expected;
        assert(error <= RISE_TOLERANCE, "rise %g: %g", rise, error);
    }
    assert(light::fog_rise_factor(0) == 1);
}

fn void test_height_fog_limit_is_continuous_at_the_horizon() @test {
    HeightFog fog = { .density = 0.01f, .falloff = 0.05f, .albedo = { 1, 1, 1 }, .max_distance = 100 };
    Vec3 steep = ((Vec3){ 0, 1, 1 }).normalize();
    float limit = limit_from(&fog, steep);
    assert(math::abs(limit - transmittance_over(&fog, steep, 1e5f)) < 1e-6f && limit > 0 && limit < 1);
    assert(limit_from(&fog, ((Vec3){ 1, 1e-6f, 0 }).normalize()) < 1e-6f);
    assert(limit_from(&fog, { 1, 0, 0 }) == 0);
    assert(limit_from(&fog, ((Vec3){ 1, -1, 0 }).normalize()) == 0);

    HeightFog uniform = fog;
    uniform.falloff = 0;
    assert(limit_from(&uniform, steep) == 0);
    assert(math::abs(transmittance_over(&uniform, { 1, 0, 0 }, 100) - math::exp(-1.0f)) < 1e-6f);
    HeightFog clear = fog;
    clear.density = 0;
    assert(limit_from(&clear, { 1, 0, 0 }) == 1);
}

fn void test_sky_regeneration_follows_sun_altitude_and_air() @test {
    Atmosphere atmosphere = light::ATMOSPHERE_EARTH;
    float start = 30 * DEGREE;
    render::SkyRegeneration generated;
    assert(moved(&generated, &atmosphere, elevated(start)));
    generated = { .atmosphere = atmosphere, .to_sun = elevated(start), .sun_color = SUN_COLOR, .valid = true };

    assert(!moved(&generated, &atmosphere, elevated(start + 0.4f * DEGREE)));
    assert(moved(&generated, &atmosphere, elevated(start + 0.6f * DEGREE)));
    for (uint step = 1; step <= 6; step++) {
        bool due = moved(&generated, &atmosphere, elevated(start + step * DRIFT_STEP * DEGREE));
        assert(due == (step == 6), "step %d", step);
    }

    Atmosphere raised = atmosphere;
    raised.observer_altitude = 499;
    assert(!moved(&generated, &raised, elevated(start)));
    raised.observer_altitude = 501;
    assert(moved(&generated, &raised, elevated(start)));

    Atmosphere hazier = atmosphere;
    hazier.mie_scattering *= 2;
    assert(moved(&generated, &hazier, elevated(start)));
    bool recoloured = render::sky_regeneration_due(
        generated:  &generated,
        atmosphere: &atmosphere,
        to_sun:     elevated(start),
        sun_color:  { 1, 0.5f, 0.2f },
    );
    assert(recoloured);
}

fn void test_extract_lights_attenuates_only_the_atmosphere_sun() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* sun = scene.add_light(light::directional(SUN_COLOR, SUN_INTENSITY), name: "sun")!!;
    scene.add(sun, light::ATMOSPHERE_EARTH);
    scene.add_light(light::directional(SECOND_COLOR, 2, false), name: "second")!!;
    aim_sun(&scene, sun, { 0, 1, 0 });
    AtmosphereSelection atmosphere = render::select_atmosphere(&scene);
    assert(c3d::same_id(atmosphere.entity, sun.id));

    LightCounts counts;
    @pool() {
        LightExtraction zenith = render::extract_lights(
            allocator:   tmem,
            scene:       &scene,
            frustum:     null,
            view_layers: uint::max,
            capacity:    4,
            counts:      &counts,
            atmosphere:  &atmosphere,
            altitude:    0,
        );
        assert(zenith.lights.len == 2 && zenith.shadows.len == 1);
        assert(zenith.sun_light == 1);
        Vec4 sun_packed = zenith.lights[0].color_intensity;
        for (uint channel = 0; channel < 3; channel++) {
            float full = SUN_COLOR[channel] * SUN_INTENSITY;
            assert(sun_packed[channel] * sun_packed.w > 0.75f * full && sun_packed[channel] * sun_packed.w < full);
        }
        assert(zenith.lights[1].color_intensity == (Vec4){ SECOND_COLOR.x, SECOND_COLOR.y, SECOND_COLOR.z, 2 });
    };

    aim_sun(&scene, sun, elevated(-5 * DEGREE));
    @pool() {
        LightExtraction night = render::extract_lights(
            allocator:   tmem,
            scene:       &scene,
            frustum:     null,
            view_layers: uint::max,
            capacity:    4,
            counts:      &counts,
            atmosphere:  &atmosphere,
            altitude:    0,
        );
        assert(night.lights.len == 1 && night.shadows.len == 0 && counts.culled == 1);
        assert(night.sun_light == 0);
        assert(night.lights[0].color_intensity == (Vec4){ SECOND_COLOR.x, SECOND_COLOR.y, SECOND_COLOR.z, 2 });

        ShadowRequest[] prepared = render::collect_shadow_requests(
            allocator:   tmem,
            scene:       &scene,
            packed:      {},
            frustum:     null,
            view_layers: uint::max,
            capacity:    scene.count(Light),
            counts:      &counts,
        );
        assert(prepared.len == 1 && prepared[0].light.index == sun.id.index);
    };
}

fn void test_fog_sun_prefers_the_atmosphere_sun() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    scene.add_light(light::point(SECOND_COLOR, 2, 10), name: "lamp")!!;
    Node* moon = scene.add_light(light::directional(SECOND_COLOR, 2, false), name: "moon")!!;
    Node* sun = scene.add_light(light::directional(SUN_COLOR, SUN_INTENSITY), name: "sun")!!;
    scene.add(sun, light::ATMOSPHERE_EARTH);
    aim_sun(&scene, sun, { 0, 1, 0 });
    AtmosphereSelection atmosphere = render::select_atmosphere(&scene);
    AtmosphereSelection none;
    LightCounts counts;

    @pool() {
        LightExtraction day = extract_all(&scene, &atmosphere, &counts);
        assert(day.sun_light == 3 && render::fog_sun_light(&day, true) == 3);
        LightExtraction plain = extract_all(&scene, &none, &counts);
        assert(plain.sun_light == 0 && render::fog_sun_light(&plain, false) == 2);
    };

    aim_sun(&scene, sun, elevated(-5 * DEGREE));
    @pool() {
        LightExtraction night = extract_all(&scene, &atmosphere, &counts);
        assert(night.sun_light == 0 && render::fog_sun_light(&night, true) == 0);
    };

    scene.remove(sun);
    scene.remove(moon);
    @pool() {
        LightExtraction lamp_only = extract_all(&scene, &none, &counts);
        assert(render::fog_sun_light(&lamp_only, false) == 0);
    };
}

fn void test_atmosphere_resolver_takes_the_first_valid_one_with_a_sun() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* bare = scene.add_node(name: "bare")!!;
    scene.add(bare, light::ATMOSPHERE_EARTH);
    Node* lamp = scene.add_light(light::point({ 1, 1, 1 }, 1), name: "lamp")!!;
    scene.add(lamp, light::ATMOSPHERE_EARTH);
    Node* broken = scene.add_light(light::directional({ 1, 1, 1 }, 1), name: "broken")!!;
    Atmosphere invalid = light::ATMOSPHERE_EARTH;
    invalid.atmosphere_height = -1;
    scene.add(broken, invalid);
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 1), name: "sun")!!;
    scene.add(sun, light::ATMOSPHERE_EARTH);
    Node* second = scene.add_light(light::directional({ 1, 1, 1 }, 1), name: "second")!!;
    scene.add(second, light::ATMOSPHERE_EARTH);

    AtmosphereSelection selection = render::select_atmosphere(&scene);
    assert(c3d::same_id(selection.entity, sun.id) && selection.ignored == 4);
    assert(selection.sun == scene.get(sun, Light) && selection.node == sun);

    scene.remove(sun);
    selection = render::select_atmosphere(&scene);
    assert(c3d::same_id(selection.entity, second.id) && selection.ignored == 3);
}

fn void test_height_fog_resolver_skips_hidden_layers_and_invalid_fogs() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* minimap = scene.add_node(name: "minimap_fog")!!;
    minimap.layers = 2;
    scene.add(minimap, light::HEIGHT_FOG_DEFAULT);
    Node* broken = scene.add_node(name: "broken")!!;
    HeightFog invalid = light::HEIGHT_FOG_DEFAULT;
    invalid.density = -1;
    scene.add(broken, invalid);
    Node* valley = scene.add_node(name: "valley")!!;
    valley.local.position = { 0, 120, 0 };
    scene.add(valley, light::HEIGHT_FOG_DEFAULT);
    Node* extra = scene.add_node(name: "extra")!!;
    scene.add(extra, light::HEIGHT_FOG_DEFAULT);
    scene.update_world();

    FogSelection main_view = render::select_height_fog(&scene, 1);
    assert(c3d::same_id(main_view.entity, valley.id) && main_view.ignored == 2);
    assert(main_view.base_height == 120);
    FogSelection minimap_view = render::select_height_fog(&scene, 2);
    assert(c3d::same_id(minimap_view.entity, minimap.id) && minimap_view.ignored == 0);
}

fn void test_atmosphere_and_fog_validity_reject_each_arm() @test {
    Atmosphere earth = light::ATMOSPHERE_EARTH;
    assert(light::atmosphere_valid(&earth));
    Atmosphere[8] invalid = { earth, earth, earth, earth, earth, earth, earth, earth };
    invalid[0].planet_radius = 0;
    invalid[1].mie_scale_height = -1;
    invalid[2].rayleigh_scattering.y = float::nan;
    invalid[3].mie_anisotropy = 1;
    invalid[4].ground_albedo.x = 1.5f;
    invalid[5].observer_altitude = earth.atmosphere_height;
    invalid[6].observer_altitude = -1;
    invalid[7].sun_angular_radius = 0;
    foreach (index, &atmosphere : invalid) assert(!light::atmosphere_valid(atmosphere), "arm %d", index);

    HeightFog fog = light::HEIGHT_FOG_DEFAULT;
    assert(light::height_fog_valid(&fog));
    HeightFog uniform = fog;
    uniform.falloff = 0;
    assert(light::height_fog_valid(&uniform));
    HeightFog[8] broken = { fog, fog, fog, fog, fog, fog, fog, fog };
    broken[0].density = -0.1f;
    broken[1].falloff = -0.1f;
    broken[2].albedo.z = float::nan;
    broken[3].max_distance = 0;
    broken[4].density = float::inf;
    broken[5].anisotropy = 1;
    broken[6].anisotropy = -1;
    broken[7].anisotropy = float::nan;
    foreach (index, &medium : broken) assert(!light::height_fog_valid(medium), "arm %d", index);
    HeightFog backward = fog;
    backward.anisotropy = -0.99f;
    assert(light::height_fog_valid(&backward));
}

fn void test_sky_fog_block_packs_the_atmosphere_and_the_fog() @test {
    Atmosphere atmosphere = light::ATMOSPHERE_EARTH;
    HeightFog medium = light::HEIGHT_FOG_DEFAULT;
    FogSelection fog = { .fog = &medium, .base_height = 40 };
    SkyFogGpu block;
    render::write_sky_fog(
        root:            &block,
        atmosphere:      &atmosphere,
        to_sun:          { 0, 1, 0 },
        sun_illuminance: { 3, 2, 1 },
        altitude:        -25,
        fog:             &fog,
        tables:          {
            .transmittance = (gpu::TextureIndex)5,
            .sky_view      = (gpu::TextureIndex)7,
            .fog_volume    = (gpu::TextureIndex)9,
        },
    );
    assert(block.flags == (shader::SKY_FOG_ATMOSPHERE | shader::SKY_FOG_HEIGHT_FOG));
    assert(block.camera_altitude == 0 && block.planet_radius == 6_360_000 && block.top_radius == 6_460_000);
    assert(block.sun_illuminance == (Vec4f){ 3, 2, 1, 0 } && block.sun_direction_cos_radius.y == 1);
    assert(block.rayleigh_scattering_height.w == 8_000 && block.mie.z == 1_200 && block.mie.w == 0.8f);
    assert(block.fog_base_height == 40 && block.fog_albedo_density.w == medium.density);
    assert(block.transmittance_lut == (gpu::TextureIndex)5 && block.sky_view_lut == (gpu::TextureIndex)7);
    assert(block.aerial_perspective_distance == render::AERIAL_PERSPECTIVE_DISTANCE);
    assert(block.fog_volume == (gpu::TextureIndex)9 && block.fog_anisotropy == medium.anisotropy);

    FogSelection no_fog;
    render::write_sky_fog(
        root:            &block,
        atmosphere:      null,
        to_sun:          { 0, 1, 0 },
        sun_illuminance: {},
        altitude:        0,
        fog:             &no_fog,
        tables:          {},
    );
    assert(block.flags == 0 && block.top_radius == 0);
}

fn void test_probe_fill_follows_the_atmosphere_revision() @test {
    Entity atmosphere = { .index = 3, .generation = 1 };
    render::ProbeFillIdentity current = { .atmosphere = atmosphere, .lighting_revision = 4, .intensity = 3 };
    render::ProbeFillState state;
    render::ProbeFillWork first = render::plan_probe_fill(&state, ProbeFill.ENVIRONMENT, &current, 2);
    assert(first.irradiance && state.filled());
    render::ProbeFillWork steady = render::plan_probe_fill(&state, ProbeFill.ENVIRONMENT, &current, 2);
    assert(!steady.irradiance);
    current.lighting_revision = 5;
    render::ProbeFillWork refreshed = render::plan_probe_fill(&state, ProbeFill.ENVIRONMENT, &current, 2);
    assert(refreshed.irradiance && !refreshed.visibility);
}
