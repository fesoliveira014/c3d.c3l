module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint[<3>] LIFETIME_PROBE_COUNTS @private = { 2, 2, 2 };
const Vec3 LIFETIME_PROBE_HALF_EXTENTS @private = { 0.25f, 0.25f, 0.25f };
const Vec3 LIFETIME_BLOCKER_AWAY @private = { 4, 0, 0 };
const Vec3 LIFETIME_SKY @private = { 0.3f, 0.5f, 0.7f };
const uint LIFETIME_WINDOW @private = 2;
const float LIFETIME_HYSTERESIS @private = 0.97f;
const float FRESH_ATLAS_TOLERANCE @private = 0.002f; // two half-float steps near unit values; stale history differs by 97 percent
const float FRESH_ATLAS_MINIMUM @private = 0.1f;
const float REACTIVATED_PROBE_ALPHA @private = 3; // private blend marker; the public class is eligible

struct ProbeLifetimeScene @private {
    Scene scene;
    Node* camera;
    Node* volume;
    Node* blocker;
}

struct ProbeLifetimeHistory @private {
    AtlasReading irradiance;
    AtlasReading visibility;
}

fn ProbeLifetimeScene? create_probe_lifetime_scene(Fixture* fixture, bool posed = false) @private {
    ProbeLifetimeScene result;
    result.scene = scene::create_scene(fixture.allocator, { .max_nodes = 8 });
    defer catch scene::destroy_scene(&result.scene);
    result.scene.environment = fixture.assets.add_environment(
        desc: light::solid_environment(LIFETIME_SKY, SMALL_PROCESSING),
    )!;
    result.scene.environment_intensity = 1;
    MaterialId surface = fixture.assets.add_material(material::standard({
        .base_color = { 0.5f, 0.5f, 0.5f, 1 },
        .roughness = 1,
    }))!;
    if (posed) {
        result.blocker = posed_attach_joint(
            fixture: fixture,
            scene: &result.scene,
            geometry: posed_box(fixture, true)!,
            material: surface,
        );
    } else {
        result.blocker = result.scene.add_mesh(fixture.box, surface)!;
    }
    result.volume = result.scene.add_node()!;
    ProbeVolume volume = light::probe_volume(LIFETIME_PROBE_HALF_EXTENTS, LIFETIME_PROBE_COUNTS, ProbeFill.SCENE);
    volume.update.probes_per_frame = LIFETIME_WINDOW;
    volume.update.hysteresis = LIFETIME_HYSTERESIS;
    result.scene.add(result.volume, volume);
    result.camera = result.scene.add_camera(camera::orthographic(4, 0.1f, 20))!;
    result.camera.local.position = { 0, 0, 3 };
    result.scene.update_world();
    fixture.renderer.prepare_scene(&result.scene)!;
    return result;
}

fn void? render_probe_lifetime_frame(
    Fixture* fixture,
    ProbeLifetimeScene* first,
    ProbeLifetimeScene* second = null,
) @private {
    first.scene.update_world();
    if (second) second.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&first.scene, first.camera, fixture.view)!;
    renderer.finish_view(fixture.view)!;
    if (second) {
        renderer.render_view(&second.scene, second.camera, fixture.second_view)!;
        renderer.finish_view(fixture.second_view)!;
    }
    renderer.end_frame()!;
}

fn ProbeLifetimeHistory? keep_probe_lifetime_history(Fixture* fixture, ProbeLifetimeScene* target) @private {
    ProbeVolumeRes* mirror = mirror_of(fixture, &target.scene, target.volume);
    ProbeLifetimeHistory result;
    result.irradiance = keep_atlas(fixture, mirror, &mirror.irradiance)!;
    defer catch alloc::free(mem, result.irradiance.texels.ptr);
    result.visibility = keep_atlas(fixture, mirror, &mirror.visibility)!;
    return result;
}

fn void free_probe_lifetime_history(ProbeLifetimeHistory* history) @private {
    alloc::free(mem, history.irradiance.texels.ptr);
    alloc::free(mem, history.visibility.texels.ptr);
}

fn void assert_probe_lifetime_frozen(
    Fixture* fixture,
    ProbeLifetimeScene* target,
    ProbeLifetimeHistory* before,
) @private {
    ProbeVolumeRes* mirror = mirror_of(fixture, &target.scene, target.volume);
    @pool() {
        Vec4f[] irradiance = read_atlas(fixture, &mirror.irradiance)!!;
        Vec4f[] visibility = read_atlas(fixture, &mirror.visibility)!!;
        assert(irradiance.len == before.irradiance.texels.len);
        assert(visibility.len == before.visibility.texels.len);
        foreach (index, value : irradiance) assert(value == before.irradiance.texels[index]);
        foreach (index, value : visibility) assert(value == before.visibility.texels[index]);
    };
}

fn void assert_probe_lifetime_classes(
    Fixture* fixture,
    ProbeLifetimeScene* target,
    uint first_count,
    uint first_class,
    uint remaining_class,
) @private {
    ProbeVolumeRes* mirror = mirror_of(fixture, &target.scene, target.volume);
    uint[<3>] counts = mirror.counts;
    uint count = counts.x * counts.y * counts.z;
    uint edge = shader::PROBE_IRRADIANCE_CELL;
    @pool() {
        Vec4f[] texels = read_atlas(fixture, &mirror.irradiance)!!;
        assert_finite(texels);
        for (uint probe = 0; probe < count; probe++) {
            uint[<3>] coordinate = { probe % counts.x, probe / counts.x % counts.y, probe / (counts.x * counts.y) };
            uint[<2>] cell = render::probe_cell(counts, mirror.slices_per_row, coordinate);
            uint expected = probe < first_count ? first_class : remaining_class;
            for (uint y = 0; y < edge; y++) {
                for (uint x = 0; x < edge; x++) {
                    usz index = (usz)(cell.y * edge + y) * mirror.irradiance.width + (usz)(cell.x * edge + x);
                    float alpha = texels[index].w;
                    if (alpha == REACTIVATED_PROBE_ALPHA) alpha = (float)shader::PROBE_CLASS_ELIGIBLE;
                    assert(alpha == (float)expected);
                }
            }
        }
    };
}

fn void assert_probe_lifetime_fresh(
    AtlasReading* actual,
    AtlasReading* reference,
    uint edge,
    uint channels,
) @private {
    float peak;
    for (uint y = 1; y + 1 < edge; y++) {
        for (uint x = 1; x + 1 < edge; x++) {
            usz actual_texel = (usz)y * actual.width + x;
            usz reference_texel = (usz)y * reference.width + x;
            for (uint channel = 0; channel < channels; channel++) {
                float expected = reference.texels[reference_texel][channel];
                float value = actual.texels[actual_texel][channel];
                assert(math::is_finite(value) && math::is_finite(expected));
                assert(math::abs(value - expected) <= FRESH_ATLAS_TOLERANCE * math::max(1.0f, math::abs(expected)));
                peak = math::max(peak, expected);
            }
        }
    }
    assert(peak > FRESH_ATLAS_MINIMUM);
}

fn void test_probe_classification_partial_sweep_restart_and_recreation() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeLifetimeScene target = create_probe_lifetime_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);

    render_probe_lifetime_frame(&fixture, &target)!!;
    ProbeVolumeRes* mirror = mirror_of(&fixture, &target.scene, target.volume);
    assert(mirror.fill.cursor == LIFETIME_WINDOW && !mirror.fill.scene_swept);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: LIFETIME_WINDOW,
        first_class: shader::PROBE_CLASS_EXCLUDED,
        remaining_class: shader::PROBE_CLASS_PROVISIONAL,
    );
    for (uint frame = 0; frame < 3; frame++) render_probe_lifetime_frame(&fixture, &target)!!;
    assert(mirror.fill.scene_swept && mirror.fill.cursor == 0);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: 0,
        first_class: shader::PROBE_CLASS_EXCLUDED,
        remaining_class: shader::PROBE_CLASS_EXCLUDED,
    );

    target.volume.local.position = LIFETIME_BLOCKER_AWAY;
    render_probe_lifetime_frame(&fixture, &target)!!;
    assert(mirror.fill.cursor == LIFETIME_WINDOW && !mirror.fill.scene_swept);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: LIFETIME_WINDOW,
        first_class: shader::PROBE_CLASS_ELIGIBLE,
        remaining_class: shader::PROBE_CLASS_PROVISIONAL,
    );

    target.scene.get(target.volume, ProbeVolume).counts.x = 3;
    render_probe_lifetime_frame(&fixture, &target)!!;
    assert(mirror.counts == (uint[<3>]){ 3, 2, 2 });
    assert(mirror.fill.cursor == LIFETIME_WINDOW && !mirror.fill.scene_swept);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: LIFETIME_WINDOW,
        first_class: shader::PROBE_CLASS_ELIGIBLE,
        remaining_class: shader::PROBE_CLASS_PROVISIONAL,
    );
    check_validation(&fixture.renderer);
}

fn void test_probe_classification_fill_switch_and_hidden_freeze() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeLifetimeScene target = create_probe_lifetime_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    ProbeVolume* volume = target.scene.get(target.volume, ProbeVolume);
    volume.fill = ProbeFill.ENVIRONMENT;
    render_probe_lifetime_frame(&fixture, &target)!!;
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: 0,
        first_class: shader::PROBE_CLASS_PROVISIONAL,
        remaining_class: shader::PROBE_CLASS_PROVISIONAL,
    );

    volume.fill = ProbeFill.SCENE;
    render_probe_lifetime_frame(&fixture, &target)!!;
    ProbeVolumeRes* mirror = mirror_of(&fixture, &target.scene, target.volume);
    assert(mirror.fill.cursor == LIFETIME_WINDOW && mirror.fill.scene_swept);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: LIFETIME_WINDOW,
        first_class: shader::PROBE_CLASS_EXCLUDED,
        remaining_class: shader::PROBE_CLASS_PROVISIONAL,
    );
    ProbeLifetimeHistory frozen = keep_probe_lifetime_history(&fixture, &target)!!;
    defer free_probe_lifetime_history(&frozen);
    volume.fill = ProbeFill.NONE;
    target.blocker.local.position = LIFETIME_BLOCKER_AWAY;
    render_probe_lifetime_frame(&fixture, &target)!!;
    assert(fixture.renderer.stats.probe_updates == 0);
    assert(mirror.fill.cursor == LIFETIME_WINDOW && mirror.fill.scene_swept);
    assert_probe_lifetime_frozen(&fixture, &target, &frozen);

    volume.fill = ProbeFill.SCENE;
    target.volume.visible = false;
    render_probe_lifetime_frame(&fixture, &target)!!;
    assert(fixture.renderer.stats.probe_updates == 0);
    assert(mirror.fill.cursor == LIFETIME_WINDOW && mirror.fill.scene_swept);
    assert_probe_lifetime_frozen(&fixture, &target, &frozen);
    target.volume.visible = true;
    render_probe_lifetime_frame(&fixture, &target)!!;
    assert(mirror.fill.cursor == 2 * LIFETIME_WINDOW);
    // The frozen first window is revisited after the remaining sweep.
    for (uint frame = 0; frame < 3; frame++) render_probe_lifetime_frame(&fixture, &target)!!;
    assert(mirror.fill.cursor == LIFETIME_WINDOW);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: 0,
        first_class: shader::PROBE_CLASS_ELIGIBLE,
        remaining_class: shader::PROBE_CLASS_ELIGIBLE,
    );
    check_validation(&fixture.renderer);
}

fn void test_probe_classification_discard_publishes_no_state() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeLifetimeScene target = create_probe_lifetime_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    ProbeVolume* volume = target.scene.get(target.volume, ProbeVolume);
    volume.update.probes_per_frame = 0;
    render_probe_lifetime_frame(&fixture, &target)!!;
    ProbeLifetimeHistory before = keep_probe_lifetime_history(&fixture, &target)!!;
    defer free_probe_lifetime_history(&before);

    volume.update.probes_per_frame = LIFETIME_WINDOW;
    target.blocker.local.position = LIFETIME_BLOCKER_AWAY;
    target.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!!;
    renderer.render_view(&target.scene, target.camera, fixture.view)!!;
    render::abort_frame(renderer);
    ProbeVolumeRes* mirror = mirror_of(&fixture, &target.scene, target.volume);
    assert(mirror.fill.cursor == 0 && mirror.fill.scene_swept);
    assert_probe_lifetime_frozen(&fixture, &target, &before);

    render_probe_lifetime_frame(&fixture, &target)!!;
    assert(mirror.fill.cursor == LIFETIME_WINDOW);
    assert_probe_lifetime_classes(
        fixture: &fixture,
        target: &target,
        first_count: LIFETIME_WINDOW,
        first_class: shader::PROBE_CLASS_ELIGIBLE,
        remaining_class: shader::PROBE_CLASS_EXCLUDED,
    );
    check_validation(renderer);
}

fn void test_probe_classification_uncovering_replaces_both_histories() @test {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (bool posed : { false, true }) {
            Fixture fixture;
            create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
            defer destroy_fixture(&fixture);
            ProbeLifetimeScene target = create_probe_lifetime_scene(&fixture, posed)!!;
            defer scene::destroy_scene(&target.scene);
            ProbeLifetimeScene reference = create_probe_lifetime_scene(&fixture, posed)!!;
            defer scene::destroy_scene(&reference.scene);
            ProbeVolume* volume = target.scene.get(target.volume, ProbeVolume);
            ProbeVolume* reference_volume = reference.scene.get(reference.volume, ProbeVolume);
            volume.update.probes_per_frame = 0;
            reference_volume.update.probes_per_frame = 0;
            reference_volume.update.hysteresis = 0;
            render_probe_lifetime_frame(&fixture, &target, &reference)!!;
            assert_probe_lifetime_classes(
                fixture: &fixture,
                target: &target,
                first_count: 0,
                first_class: shader::PROBE_CLASS_EXCLUDED,
                remaining_class: shader::PROBE_CLASS_EXCLUDED,
            );
            if (posed) assert(fixture.renderer.posed_trace.bytes > 0);

            volume.update.probes_per_frame = 1;
            reference_volume.update.probes_per_frame = 1;
            target.blocker.local.position = LIFETIME_BLOCKER_AWAY;
            reference.blocker.local.position = LIFETIME_BLOCKER_AWAY;
            // Both scenes share one frame's rotated rays; only hysteresis differs.
            render_probe_lifetime_frame(&fixture, &target, &reference)!!;
            ProbeVolumeRes* mirror = mirror_of(&fixture, &target.scene, target.volume);
            assert(mirror.fill.scene_swept && mirror.fill.cursor == 1);
            assert_probe_lifetime_classes(
                fixture: &fixture,
                target: &target,
                first_count: 1,
                first_class: shader::PROBE_CLASS_ELIGIBLE,
                remaining_class: shader::PROBE_CLASS_EXCLUDED,
            );
            ProbeLifetimeHistory actual = keep_probe_lifetime_history(&fixture, &target)!!;
            defer free_probe_lifetime_history(&actual);
            ProbeLifetimeHistory expected = keep_probe_lifetime_history(&fixture, &reference)!!;
            defer free_probe_lifetime_history(&expected);
            assert_probe_lifetime_fresh(
                actual: &actual.irradiance,
                reference: &expected.irradiance,
                edge: shader::PROBE_IRRADIANCE_CELL,
                channels: 3,
            );
            assert_probe_lifetime_fresh(
                actual: &actual.visibility,
                reference: &expected.visibility,
                edge: shader::PROBE_VISIBILITY_CELL,
                channels: 2,
            );
            check_validation(&fixture.renderer);
        }
    }
}
