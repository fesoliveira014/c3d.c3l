module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::light;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::test::transparency_fixtures;
import std::math;
import std::io;

const float LAYERED_FOG_BACKDROP_DISTANCE @private = 8.5f;
const float LAYERED_FOG_FRONT_DISTANCE @private = 3;
const float LAYERED_FOG_REAR_DISTANCE @private = 5;
const double LAYERED_FOG_DENSE_EXTINCTION @private = 4;
const Vec3 LAYERED_FOG_FRONT_TINT @private = { 0.8f, 0.6f, 0.4f };
const Vec3 LAYERED_FOG_REAR_TINT @private = { 0.5f, 0.75f, 1 };
const Vec3 LAYERED_FOG_FRONT_ABSORPTION @private = { 0.5f, 0.25f, 0.125f };
const Vec3 LAYERED_FOG_REAR_ABSORPTION @private = { 0.75f, 0.5f, 0.25f };
const transparency_fixtures::Color LAYERED_FOG_EDGE_RIGHT_COLOR @private = { 0.8, 0.6, 0.4 };
const float LAYERED_FOG_EDGE_REAR_DISTANCE @private = 4;
const float LAYERED_FOG_EDGE_LEFT_DISTANCE @private = 5;
const uint LAYERED_FOG_EDGE_LEFT_COLUMNS @private = LAYERED_ROUGH_WIDTH / 2;

fn Node*? add_layered_height_fog(LayeredScene* target, double extinction) @private {
    target.scene.ambient_color = { 1, 1, 1 };
    target.scene.ambient_intensity = 1;
    Node* fog = target.scene.add_node()!;
    target.scene.add(fog, (HeightFog){
        .density = (float)extinction,
        .falloff = 0,
        .albedo = { 0.1f, 0.2f, 0.4f },
        .max_distance = 9,
    });
    return fog;
}

fn FilterFogTerms layered_fog_terms(
    double distance,
    double extinction = transparency_fixtures::FOG_EXTINCTION,
) @private {
    FilterFogCase medium = { .density = extinction };
    return filter_fog_expected(medium, distance);
}

fn transparency_fixtures::Color layered_fog_connect(
    transparency_fixtures::Color radiance,
    double near_distance,
    double far_distance,
    double extinction = transparency_fixtures::FOG_EXTINCTION,
) @private {
    FilterFogTerms near = layered_fog_terms(near_distance, extinction);
    FilterFogTerms far = layered_fog_terms(far_distance, extinction);
    transparency_fixtures::Color denominator;
    for (uint channel = 0; channel < 3; channel++) {
        denominator[channel] = math::max(near.attenuation[channel], FILTER_FOG_DENOMINATOR_FLOOR);
    }
    return (far.attenuation * radiance + far.scattering - near.scattering) / denominator;
}

fn transparency_fixtures::Color layered_fog_observe(
    transparency_fixtures::Color radiance,
    double distance,
    double extinction = transparency_fixtures::FOG_EXTINCTION,
) @private {
    FilterFogTerms medium = layered_fog_terms(distance, extinction);
    return medium.attenuation * radiance + medium.scattering;
}

fn transparency_fixtures::Color layered_fog_optical_factor(
    Vec3 tint,
    Vec3 absorption,
    float thickness,
    float attenuation_distance,
) @private {
    transparency_fixtures::Color result;
    for (uint channel = 0; channel < 3; channel++) {
        double optical_distance = (double)thickness / attenuation_distance;
        result[channel] = (double)tint[channel]
          * math::exp(math::ln((double)absorption[channel]) * optical_distance);
    }
    return result;
}

fn MaterialId? add_layered_fog_glass(
    Fixture* fixture,
    Vec3 tint,
    Vec3 absorption,
    float thickness,
    float attenuation_distance,
    float coverage = 1,
) @private {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = { tint.x, tint.y, tint.z, coverage };
    params.standard.metallic = 0;
    params.standard.roughness = 0;
    params.ior = 1;
    params.specular = 0;
    params.transmission = 1;
    params.thickness = thickness;
    params.attenuation_color = absorption;
    params.attenuation_distance = attenuation_distance;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    common.depth_write = false;
    return fixture.assets.add_material(material::physical(params, common));
}

fn GeometryId? add_layered_fog_sheet(Fixture* fixture, float distance) @private {
    return add_layered_sheet_geometry(fixture, (9 - distance) / 8);
}

fn void test_layered_fog_one_and_two_physical_sheets_apply_authored_absorption_once() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (sheet_count : (uint[2]){ 1, 2 }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
        LayeredView view = create_layered_view(&fixture, 2)!!;
        defer destroy_layered_view(&fixture, &view);
        MaterialId front = add_layered_fog_glass(
            fixture: &fixture,
            tint: LAYERED_FOG_FRONT_TINT,
            absorption: LAYERED_FOG_FRONT_ABSORPTION,
            thickness: 0.5f,
            attenuation_distance: 2,
        )!!;
        target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!, front)!!;
        transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
        double continuation = LAYERED_FOG_BACKDROP_DISTANCE;
        if (sheet_count == 2) {
            MaterialId rear = add_layered_fog_glass(
                fixture: &fixture,
                tint: LAYERED_FOG_REAR_TINT,
                absorption: LAYERED_FOG_REAR_ABSORPTION,
                thickness: 1,
                attenuation_distance: 2,
            )!!;
            target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_REAR_DISTANCE)!!, rear)!!;
            expected = layered_fog_connect(expected, LAYERED_FOG_REAR_DISTANCE, continuation);
            expected *= layered_fog_optical_factor(
                tint: LAYERED_FOG_REAR_TINT,
                absorption: LAYERED_FOG_REAR_ABSORPTION,
                thickness: 1,
                attenuation_distance: 2,
            );
            continuation = LAYERED_FOG_REAR_DISTANCE;
        }
        expected = layered_fog_connect(expected, LAYERED_FOG_FRONT_DISTANCE, continuation);
        expected *= layered_fog_optical_factor(
            tint: LAYERED_FOG_FRONT_TINT,
            absorption: LAYERED_FOG_FRONT_ABSORPTION,
            thickness: 0.5f,
            attenuation_distance: 2,
        );
        expected = layered_fog_observe(expected, LAYERED_FOG_FRONT_DISTANCE);
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, expected);
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_fog_front_glass_preserves_the_sorted_remainder_handoff_at_each_capacity() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (capacity : (uint[2]){ 1, 2 }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
        LayeredView view = create_layered_view(&fixture, capacity)!!;
        defer destroy_layered_view(&fixture, &view);
        MaterialId rear = add_layered_basic(&fixture, { 0.25f, 0.5f, 1, 0.375f })!!;
        target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_REAR_DISTANCE)!!, rear)!!;
        MaterialId front = add_layered_fog_glass(
            fixture: &fixture,
            tint: LAYERED_FOG_FRONT_TINT,
            absorption: LAYERED_FOG_FRONT_ABSORPTION,
            thickness: 0.5f,
            attenuation_distance: 2,
        )!!;
        target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!, front)!!;
        transparency_fixtures::Color rear_local = layered_fog_connect(
            transparency_fixtures::PLANAR_BACKGROUND,
            LAYERED_FOG_REAR_DISTANCE,
            LAYERED_FOG_BACKDROP_DISTANCE,
        );
        rear_local = transparency_fixtures::compose_over(rear_local, { 0.25, 0.5, 1 }, 0.375);
        transparency_fixtures::Color expected = layered_fog_connect(
            rear_local,
            LAYERED_FOG_FRONT_DISTANCE,
            LAYERED_FOG_REAR_DISTANCE,
        );
        expected *= layered_fog_optical_factor(
            tint: LAYERED_FOG_FRONT_TINT,
            absorption: LAYERED_FOG_FRONT_ABSORPTION,
            thickness: 0.5f,
            attenuation_distance: 2,
        );
        expected = layered_fog_observe(expected, LAYERED_FOG_FRONT_DISTANCE);
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, expected);
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_fog_over_and_additive_match_sorted_without_duplicate_inscatter() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (additive : (bool[2]){ false, true }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
        LayeredView view = create_layered_view(&fixture, 1)!!;
        defer destroy_layered_view(&fixture, &view);
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.alpha_mode = AlphaMode.BLEND;
        common.blend_mode = additive ? BlendMode.ADDITIVE : BlendMode.PREMULTIPLIED_ALPHA;
        common.double_sided = true;
        BasicParams params = { .color = { 0.25f, 0.5f, 1, 0.375f } };
        MaterialId surface = fixture.assets.add_material(material::basic(params, common))!!;
        target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!, surface)!!;
        transparency_fixtures::Color expected = layered_fog_observe(
            transparency_fixtures::PLANAR_BACKGROUND,
            LAYERED_FOG_BACKDROP_DISTANCE,
        );
        FilterFogTerms near = layered_fog_terms(LAYERED_FOG_FRONT_DISTANCE);
        transparency_fixtures::Color radiance = near.attenuation * (transparency_fixtures::Color){ 0.25, 0.5, 1 };
        if (additive) {
            expected = transparency_fixtures::compose_additive(expected, radiance, 0.375);
        } else {
            expected = transparency_fixtures::compose_over(expected, radiance + near.scattering, 0.375);
        }
        foreach (mode : (TransparencyMode[2]){ SORTED, LAYERED }) {
            ViewDesc desc = fixture.renderer.views.get(view.view).desc;
            desc.transparency = mode == LAYERED
              ? (TransparencyDesc){ .mode = LAYERED, .layer_capacity = 1 } : (TransparencyDesc){};
            render::configure_view(&fixture.renderer, view.view, desc)!!;
            Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
            defer free(pixels);
            check_layered_interior(pixels, expected);
        }
    }
    check_validation(&fixture.renderer);
}

fn void check_layered_fog_reference_pixels(Vec4[] actual, Vec4[] expected) @private {
    assert(actual.len == expected.len);
    for (uint row = LAYERED_INTERIOR_BEGIN; row < LAYERED_INTERIOR_END; row++) {
        for (uint column = LAYERED_INTERIOR_BEGIN; column < LAYERED_INTERIOR_END; column++) {
            usz pixel = (usz)row * LAYERED_IMAGE_SIZE + column;
            check_layered_color(actual[pixel], {
                (double)expected[pixel].x,
                (double)expected[pixel].y,
                (double)expected[pixel].z,
            });
        }
    }
}

fn Node*? add_layered_absorbing_atmosphere(LayeredScene* target) @private {
    Node* sun = target.scene.add_light(light::directional({ 1, 1, 1 }, 0, false))!;
    Atmosphere atmosphere = light::ATMOSPHERE_EARTH;
    atmosphere.rayleigh_scattering = {};
    atmosphere.mie_scattering = 0;
    atmosphere.mie_absorption = 0.05f;
    atmosphere.ozone_absorption = {};
    atmosphere.ground_albedo = {};
    target.scene.add(sun, atmosphere);
    return sun;
}

fn void test_layered_fog_neutral_retained_sheets_preserve_real_height_and_aerial_media_with_clipping() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) {
        foreach (combined : (bool[2]){ false, true }) {
            foreach (volumetric : (bool[2]){ false, true }) {
                LayeredScene target = create_layered_scene(&fixture)!!;
                defer scene::destroy_scene(&target.scene);
                add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
                if (combined) add_layered_absorbing_atmosphere(&target)!!;
                LayeredView view = create_layered_view(&fixture, 2, shading)!!;
                defer destroy_layered_view(&fixture, &view);
                ViewDesc desc = fixture.renderer.views.get(view.view).desc;
                desc.volumetric_fog = volumetric;
                desc.clip_plane = { .normal = { 0, 0, -1 }, .d = -2 };
                render::configure_view(&fixture.renderer, view.view, desc)!!;
                Vec4[] baseline = render_layered_pixels(&fixture, &target, &view)!!;
                defer free(baseline);
                MaterialId neutral = add_layered_fog_glass(
                    fixture: &fixture,
                    tint: { 1, 1, 1 },
                    absorption: { 1, 1, 1 },
                    thickness: 0,
                    attenuation_distance: 0,
                )!!;
                target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_REAR_DISTANCE)!!, neutral)!!;
                MaterialId zero_coverage = add_layered_fog_glass(
                    fixture: &fixture,
                    tint: LAYERED_FOG_FRONT_TINT,
                    absorption: LAYERED_FOG_FRONT_ABSORPTION,
                    thickness: 0.5f,
                    attenuation_distance: 2,
                    coverage: 0,
                )!!;
                target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!, zero_coverage)!!;
                Vec4[] with_neutral = render_layered_pixels(&fixture, &target, &view)!!;
                defer free(with_neutral);
                check_layered_fog_reference_pixels(with_neutral, baseline);
                ViewRecord* record = fixture.renderer.views.get(view.view);
                assert(record.fog_volume.texture.is_valid() == volumetric);
                AtmosphereSelection selected = render::select_atmosphere(&target.scene);
                assert((selected.atmosphere != null) == combined);
                if (combined) assert(record.aerial_perspective.texture.is_valid());
                uint[] nearest = read_layered_depth(&fixture, &view, 0)!!;
                defer free(nearest);
                uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
                assert(nearest[sample] == bitcast(0.75f, uint), "Zero-coverage layer did not reach retained shading.");
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_fog_below_floor_is_finite_and_records_neutral_layer_deviation() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    double maximum_deviation;
    foreach (capacity : (uint[2]){ 1, 2 }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        add_layered_height_fog(&target, LAYERED_FOG_DENSE_EXTINCTION)!!;
        LayeredView view = create_layered_view(&fixture, capacity)!!;
        defer destroy_layered_view(&fixture, &view);
        Vec4[] baseline = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(baseline);
        MaterialId neutral = add_layered_fog_glass(
            fixture: &fixture,
            tint: { 1, 1, 1 },
            absorption: { 1, 1, 1 },
            thickness: 0,
            attenuation_distance: 0,
        )!!;
        target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!, neutral)!!;
        target.scene.add_mesh(add_layered_fog_sheet(&fixture, LAYERED_FOG_REAR_DISTANCE)!!, neutral)!!;
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        foreach (pixel, actual : pixels) {
            foreach (channel : actual) assert(math::is_finite(channel));
            if (pixel / LAYERED_IMAGE_SIZE < LAYERED_INTERIOR_BEGIN
              || pixel / LAYERED_IMAGE_SIZE >= LAYERED_INTERIOR_END
              || pixel % LAYERED_IMAGE_SIZE < LAYERED_INTERIOR_BEGIN
              || pixel % LAYERED_IMAGE_SIZE >= LAYERED_INTERIOR_END) continue;
            for (uint channel = 0; channel < 3; channel++) {
                maximum_deviation = math::max(maximum_deviation,
                    math::abs((double)actual[channel] - baseline[pixel][channel]));
            }
        }
        FilterFogTerms front = layered_fog_terms(LAYERED_FOG_FRONT_DISTANCE, LAYERED_FOG_DENSE_EXTINCTION);
        assert(front.attenuation.x < FILTER_FOG_DENOMINATOR_FLOOR);
    }
    io::printfn(
        "production layered fog below_floor=%s neutral_deviation=%s",
        FILTER_FOG_DENOMINATOR_FLOOR,
        maximum_deviation,
    );
    check_validation(&fixture.renderer);
}

fn GeometryId? add_layered_fog_tilted_sheet(Fixture* fixture) @private {
    Vec3[4] positions = {
        { -0.75f, -0.75f, -LAYERED_FOG_FRONT_DISTANCE },
        { 0.75f, -0.75f, -LAYERED_FOG_FRONT_DISTANCE },
        { 0.75f, 0.75f, -LAYERED_FOG_FRONT_DISTANCE },
        { -0.75f, 0.75f, -LAYERED_FOG_FRONT_DISTANCE },
    };
    Vec3[4] normals = { { 0.8f, 0, 0.6f }, { 0.8f, 0, 0.6f }, { 0.8f, 0, 0.6f }, { 0.8f, 0, 0.6f } };
    Geometry geometry = {
        .positions = positions[..],
        .normals = normals[..],
        .indices = transparency_fixtures::QUAD_INDICES[..],
    };
    geometry.finalize();
    return fixture.assets.add_geometry(&geometry);
}

fn void test_layered_fog_projected_offsets_and_offscreen_missing_environment_preserve_silhouettes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (fogged : (bool[2]){ false, true }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        if (fogged) add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
        LayeredView view = create_layered_view(&fixture, 1)!!;
        defer destroy_layered_view(&fixture, &view);
        Vec4[] baseline = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(baseline);
        MaterialId glass = add_layered_fog_glass(
            fixture: &fixture,
            tint: { 1, 1, 1 },
            absorption: { 1, 1, 1 },
            thickness: 0.25f,
            attenuation_distance: 0,
        )!!;
        fixture.assets.material(glass).data.physical.ior = 1.5f;
        fixture.assets.mark_material_dirty(glass);
        Node* sheet = target.scene.add_mesh(add_layered_fog_tilted_sheet(&fixture)!!, glass)!!;
        Vec4[] offset = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(offset);
        transparency_fixtures::Color opaque = fogged
          ? layered_fog_observe(transparency_fixtures::PLANAR_BACKGROUND, LAYERED_FOG_BACKDROP_DISTANCE)
          : transparency_fixtures::PLANAR_BACKGROUND;
        for (uint row = 28; row < 100; row++) {
            for (uint column = 36; column < 92; column++) {
                check_layered_color(offset[row * LAYERED_IMAGE_SIZE + column], opaque);
            }
        }
        fixture.assets.material(glass).data.physical.thickness = 8;
        fixture.assets.mark_material_dirty(glass);
        Vec4[] offscreen = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(offscreen);
        transparency_fixtures::Color missing = fogged ? transparency_fixtures::FOG_COLOR
          : (transparency_fixtures::Color){};
        check_layered_interior(offscreen, missing);
        check_layered_color(offscreen[4 * LAYERED_IMAGE_SIZE + 4], {
            (double)baseline[4 * LAYERED_IMAGE_SIZE + 4].x,
            (double)baseline[4 * LAYERED_IMAGE_SIZE + 4].y,
            (double)baseline[4 * LAYERED_IMAGE_SIZE + 4].z,
        });
        sheet.local.position.x = 0.75f;
        Vec4[] partial = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(partial);
        check_layered_color(partial[64 * LAYERED_IMAGE_SIZE + 24], {
            (double)baseline[64 * LAYERED_IMAGE_SIZE + 24].x,
            (double)baseline[64 * LAYERED_IMAGE_SIZE + 24].y,
            (double)baseline[64 * LAYERED_IMAGE_SIZE + 24].z,
        });
        foreach (actual : partial) foreach (channel : actual) assert(math::is_finite(channel));
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_fog_combined_media_over_and_additive_match_independent_opaque_transfers() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
        Node* sun = target.scene.add_light(light::directional({ 1, 1, 1 }, 3, false))!!;
        target.scene.add(sun, light::ATMOSPHERE_EARTH);
        Node* backdrop;
        target.scene.@each(Mesh; Entity entity, Mesh* mesh) { backdrop = target.scene.node(entity); };
        assert(backdrop);
        backdrop.visible = false;
        LayeredView view = create_layered_view(&fixture, 1, shading)!!;
        defer destroy_layered_view(&fixture, &view);
        ViewDesc desc = fixture.renderer.views.get(view.view).desc;
        desc.transparency = {};
        render::configure_view(&fixture.renderer, view.view, desc)!!;
        MaterialId black = add_layered_basic(&fixture, { 0, 0, 0, 1 }, false)!!;
        MaterialId white = add_layered_basic(&fixture, { 1, 1, 1, 1 }, false)!!;
        Node* calibration = target.scene.add_mesh(
            add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!,
            black,
        )!!;
        Vec4[] black_response = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(black_response);
        target.scene.get(calibration, Mesh).material = white;
        Vec4[] white_response = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(white_response);
        calibration.visible = false;
        backdrop.visible = true;
        Vec4[] backdrop_response = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(backdrop_response);
        Node* overlay;
        foreach (additive : (bool[2]){ false, true }) {
            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.alpha_mode = AlphaMode.BLEND;
            common.double_sided = true;
            common.blend_mode = additive ? BlendMode.ADDITIVE : BlendMode.PREMULTIPLIED_ALPHA;
            MaterialId material = fixture.assets.add_material(material::basic(
                params: { .color = { 0.25f, 0.5f, 1, 0.375f } },
                common: common,
            ))!!;
            if (overlay) {
                target.scene.get(overlay, Mesh).material = material;
            } else {
                overlay = target.scene.add_mesh(
                    add_layered_fog_sheet(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!,
                    material,
                )!!;
            }
            foreach (mode : (TransparencyMode[2]){ SORTED, LAYERED }) {
                desc.transparency = mode == LAYERED
                  ? (TransparencyDesc){ .mode = LAYERED, .layer_capacity = 1 } : (TransparencyDesc){};
                render::configure_view(&fixture.renderer, view.view, desc)!!;
                Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
                defer free(pixels);
                for (uint row = LAYERED_INTERIOR_BEGIN; row < LAYERED_INTERIOR_END; row++) {
                    for (uint column = LAYERED_INTERIOR_BEGIN; column < LAYERED_INTERIOR_END; column++) {
                        usz pixel = (usz)row * LAYERED_IMAGE_SIZE + column;
                        transparency_fixtures::Color transmission = {
                            (double)white_response[pixel].x - black_response[pixel].x,
                            (double)white_response[pixel].y - black_response[pixel].y,
                            (double)white_response[pixel].z - black_response[pixel].z,
                        };
                        transparency_fixtures::Color scatter = {
                            (double)black_response[pixel].x,
                            (double)black_response[pixel].y,
                            (double)black_response[pixel].z,
                        };
                        transparency_fixtures::Color behind = {
                            (double)backdrop_response[pixel].x,
                            (double)backdrop_response[pixel].y,
                            (double)backdrop_response[pixel].z,
                        };
                        transparency_fixtures::Color source = transmission
                          * (transparency_fixtures::Color){ 0.25, 0.5, 1 };
                        transparency_fixtures::Color expected = additive
                          ? transparency_fixtures::compose_additive(behind, source, 0.375)
                          : transparency_fixtures::compose_over(behind, source + scatter, 0.375);
                        check_layered_color(pixels[pixel], expected);
                    }
                }
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn GeometryId? add_layered_fog_region(
    Fixture* fixture,
    float distance,
    float minimum_x,
    float maximum_x,
) @private {
    Vec3[4] positions = {
        { minimum_x, -1, -distance },
        { maximum_x, -1, -distance },
        { maximum_x, 1, -distance },
        { minimum_x, 1, -distance },
    };
    Geometry geometry = { .positions = positions[..], .indices = transparency_fixtures::QUAD_INDICES[..] };
    geometry.finalize();
    return fixture.assets.add_geometry(&geometry);
}

fn void test_layered_fog_two_physical_sheets_filter_raw_radiance_across_a_continuation_depth_edge() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    float edge = -1.0f / LAYERED_ROUGH_HEIGHT;
    float extent = (float)LAYERED_ROUGH_WIDTH / LAYERED_ROUGH_HEIGHT;
    foreach (capacity : (uint[2]){ 1, 2 }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        target.scene.@each(Mesh; Entity entity, Mesh* mesh) { target.scene.node(entity).visible = false; };
        add_layered_height_fog(&target, transparency_fixtures::FOG_EXTINCTION)!!;
        LayeredView view = create_layered_view(&fixture, capacity)!!;
        defer destroy_layered_view(&fixture, &view);
        render::resize_render_target(
            renderer: &fixture.renderer,
            target: view.target,
            width: LAYERED_ROUGH_WIDTH,
            height: LAYERED_ROUGH_HEIGHT,
        )!!;
        MaterialId left = add_layered_basic(&fixture, { 0.125f, 0.25f, 0.5f, 1 }, false)!!;
        MaterialId right = add_layered_basic(&fixture, { 0.8f, 0.6f, 0.4f, 1 }, false)!!;
        target.scene.add_mesh(add_layered_fog_region(
            fixture: &fixture,
            distance: LAYERED_FOG_EDGE_LEFT_DISTANCE,
            minimum_x: -extent,
            maximum_x: edge,
        )!!, left)!!;
        target.scene.add_mesh(add_layered_fog_region(
            fixture: &fixture,
            distance: LAYERED_FOG_BACKDROP_DISTANCE,
            minimum_x: edge,
            maximum_x: extent,
        )!!, right)!!;
        MaterialId rear = add_layered_fog_glass(
            fixture: &fixture,
            tint: LAYERED_FOG_REAR_TINT,
            absorption: LAYERED_FOG_REAR_ABSORPTION,
            thickness: 0.5f,
            attenuation_distance: 2,
        )!!;
        target.scene.add_mesh(add_layered_fog_region(
            fixture: &fixture,
            distance: LAYERED_FOG_EDGE_REAR_DISTANCE,
            minimum_x: -extent,
            maximum_x: edge,
        )!!, rear)!!;
        MaterialId front = add_layered_fog_glass(
            fixture: &fixture,
            tint: { 1, 1, 1 },
            absorption: { 1, 1, 1 },
            thickness: 0,
            attenuation_distance: 0,
        )!!;
        fixture.assets.material(front).data.physical.standard.roughness = 1;
        fixture.assets.material(front).data.physical.ior = 1.5f;
        fixture.assets.mark_material_dirty(front);
        target.scene.add_mesh(add_layered_fullscreen_geometry(&fixture, LAYERED_FOG_FRONT_DISTANCE)!!, front)!!;
        transparency_fixtures::Color left_raw = transparency_fixtures::PLANAR_BACKGROUND;
        if (capacity == 2) {
            left_raw = layered_fog_connect(
                radiance: left_raw,
                near_distance: LAYERED_FOG_EDGE_REAR_DISTANCE,
                far_distance: LAYERED_FOG_EDGE_LEFT_DISTANCE,
            );
        }
        left_raw *= layered_fog_optical_factor(
            tint: LAYERED_FOG_REAR_TINT,
            absorption: LAYERED_FOG_REAR_ABSORPTION,
            thickness: 0.5f,
            attenuation_distance: 2,
        );
        transparency_fixtures::ColorImage[material::TEXTURE_MIP_CAPACITY] reference;
        defer foreach (image : reference) free(image.pixels.ptr);
        uint levels = transparency_fixtures::mip_level_count(LAYERED_ROUGH_WIDTH, LAYERED_ROUGH_HEIGHT);
        uint width = LAYERED_ROUGH_WIDTH;
        uint height = LAYERED_ROUGH_HEIGHT;
        for (uint mip = 0; mip < levels; mip++) {
            reference[mip] = {
                .width = width,
                .height = height,
                .pixels = mem::new_array(transparency_fixtures::Color, (usz)width * height),
            };
            if (mip) {
                transparency_fixtures::reduce_area_box(reference[mip - 1], reference[mip]);
            } else {
                for (uint row = 0; row < height; row++) {
                    for (uint column = 0; column < width; column++) {
                        reference[0].pixels[row * width + column] = column < LAYERED_FOG_EDGE_LEFT_COLUMNS
                          ? left_raw : LAYERED_FOG_EDGE_RIGHT_COLOR;
                    }
                }
            }
            width = math::max(1u, width / 2);
            height = math::max(1u, height / 2);
        }
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        transparency_fixtures::Color filtered = reference[levels - 1].pixels[0];
        for (uint row = 2; row + 2 < LAYERED_ROUGH_HEIGHT; row++) {
            for (uint column = 2; column + 2 < LAYERED_ROUGH_WIDTH; column++) {
                double anchor = column < LAYERED_FOG_EDGE_LEFT_COLUMNS
                  ? LAYERED_FOG_EDGE_REAR_DISTANCE : LAYERED_FOG_BACKDROP_DISTANCE;
                transparency_fixtures::Color expected = layered_fog_connect(
                    filtered,
                    LAYERED_FOG_FRONT_DISTANCE,
                    anchor,
                );
                expected = layered_fog_observe(expected, LAYERED_FOG_FRONT_DISTANCE);
                check_layered_color(pixels[row * LAYERED_ROUGH_WIDTH + column], expected);
            }
        }
        uint side = capacity == 2 ? 1 : 0;
        TransparencyPyramid* pyramid = &fixture.renderer.views.get(view.view).transparency.raw_pyramid[side];
        for (uint mip = 0; mip < levels; mip++) {
            transparency_fixtures::Color[] actual = read_layered_pyramid_level(&fixture, pyramid, mip)!!;
            defer free(actual);
            foreach (pixel, expected : reference[mip].pixels) {
                for (uint channel = 0; channel < 3; channel++) {
                    double bound = LAYERED_COLOR_ABSOLUTE_TOLERANCE
                      + LAYERED_COLOR_RELATIVE_TOLERANCE * math::abs(expected[channel]);
                    assert(math::is_finite(actual[pixel][channel])
                      && math::abs(actual[pixel][channel] - expected[channel]) <= bound,
                      "capacity=%s mip=%s pixel=%s channel=%s actual=%s expected=%s",
                      capacity, mip, pixel, channel, actual[pixel][channel], expected[channel]);
                }
            }
        }
    }
    check_validation(&fixture.renderer);
}
