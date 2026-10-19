module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::math;

const float MEDIUM_TOP @private = 10;           // world y of the boxes' top faces
const float MEDIUM_DEPTH @private = 20;         // the camera at y = 2 and the plane's lower rows lie inside
const float MEDIUM_BED_DISTANCE @private = 30;
const float MEDIUM_BOX_HALF @private = 50;
const float MEDIUM_MIRROR_BOX @private = 1000;
const float SECOND_BOX_ENTRY @private = 5;      // metres along the level ray where the second box begins
const uint MEDIUM_REFERENCE_STEPS @private = 20000; // midpoint steps of the in-scatter reference
const MediumVolume MEDIUM_WATER @private = {
    .absorption  = { 0.02f, 0.05f, 0.01f },
    .scattering  = { 0.01f, 0, 0.03f },
    .half_extent = { MEDIUM_BOX_HALF, MEDIUM_BOX_HALF },
    .depth       = MEDIUM_DEPTH,
};
const MediumVolume MEDIUM_MURK @private = {
    .absorption  = { 0.04f, 0.01f, 0.06f },
    .scattering  = { 0, 0.02f, 0.01f },
    .half_extent = { MEDIUM_BOX_HALF, MEDIUM_BOX_HALF },
    .depth       = MEDIUM_DEPTH,
};

fn Node*? add_medium_box(FogScene* target, MediumVolume medium, Vec3 position) @private {
    Node* node = target.scene.add_node(name: "medium")!;
    node.local.position = position;
    target.scene.add(node, medium);
    target.scene.update_world();
    return node;
}

// Radiance seen through the media's summed extinction over a distance, with no light to scatter.
fn Vec3 absorbed(Vec3 extinction, float distance, Vec3 radiance) @private {
    Vec3 transmittance = {
        math::exp(-extinction.x * distance),
        math::exp(-extinction.y * distance),
        math::exp(-extinction.z * distance),
    };
    return radiance * transmittance;
}

fn Vec3 extinction_of(MediumVolume* medium) @private {
    return medium.absorption + medium.scattering;
}

// Metres of a ray inside a box whose top face is at MEDIUM_TOP and whose bottom lies below the plane.
fn float covered_distance(FogRay ray) @private {
    if (ray.direction.y <= 0) return ray.distance;
    return math::min(ray.distance, (MEDIUM_TOP - ray.origin.y) / ray.direction.y);
}

// With ambient intensity zero and no sun nothing lights the medium, so a pixel is the emitter's radiance absorbed.
fn FogScene? create_unlit_medium_scene(Fixture* fixture) @private {
    FogScene target = create_fog_scene(fixture)!;
    target.scene.ambient_intensity = 0;
    add_facing_plane(&target, add_unlit(fixture, BED_COLOR)!, MEDIUM_BED_DISTANCE)!;
    return target;
}

fn void test_medium_absorbs_the_view_ray_inside_its_box() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_unlit_medium_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_medium_box(&target, MEDIUM_WATER, { 0, MEDIUM_TOP, 0 })!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    Vec3 extinction = extinction_of(&MEDIUM_WATER);
    uint[3] rows = { SKY_CENTRE, SKY_UPPER_ROW, SKY_LOWER_ROW };
    String[3] names = { "level ray", "ray leaving through the top face", "descending ray" };
    foreach (index, row : rows) {
        FogRay ray = pixel_ray(&target, row, MEDIUM_BED_DISTANCE);
        Vec3 expected = absorbed(extinction, covered_distance(ray), BED_COLOR.xyz);
        check_rgb_close(pixel_at(pixels, SKY_CENTRE, row), expected, names[index]);
    }
    assert(covered_distance(pixel_ray(&target, SKY_UPPER_ROW, MEDIUM_BED_DISTANCE)) < MEDIUM_BED_DISTANCE);
    check_validation(&fixture.renderer);
}

fn void test_medium_outside_its_box_leaves_pixels_unfogged() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_unlit_medium_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    Vec4[] without = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(without);

    MediumVolume beside = MEDIUM_WATER;
    beside.absorption = { 1, 1, 1 };
    beside.half_extent = { 5, 5 };
    assert(!fixture.renderer.sky_pipelines.fog.is_valid(), "no fog pass records without a medium");
    Node* node = add_medium_box(&target, beside, { 100, MEDIUM_TOP, 0 })!!;
    Vec4[] with = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(with);
    assert(fixture.renderer.sky_pipelines.fog.is_valid(), "a medium in the scene records the fog pass");
    uint[3] rows = { SKY_CENTRE, SKY_UPPER_ROW, SKY_LOWER_ROW };
    foreach (row : rows) {
        check_rgb_close(pixel_at(with, SKY_CENTRE, row), pixel_at(without, SKY_CENTRE, row).xyz, "outside the box");
    }
    Vec3 emitter = BED_COLOR.xyz;
    check_rgb_close(pixel_at(with, SKY_CENTRE, SKY_LOWER_ROW), emitter, "the surface below the top face");

    target.scene.get(node, MediumVolume).half_extent = { MEDIUM_BOX_HALF + 100, MEDIUM_BOX_HALF };
    Vec4[] covering = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(covering);
    assert(pixel_at(covering, SKY_CENTRE, SKY_CENTRE).x < 0.5f * emitter.x, "the volume fogs once it covers the ray");
    check_validation(&fixture.renderer);
}

fn void test_overlapping_media_sum() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_unlit_medium_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MediumVolume first = MEDIUM_WATER;
    first.half_extent = { MEDIUM_BOX_HALF, 20 };
    MediumVolume second = MEDIUM_MURK;
    second.half_extent = { MEDIUM_BOX_HALF, 15 };
    add_medium_box(&target, first, { 0, MEDIUM_TOP, 0 })!!;
    add_medium_box(&target, second, { 0, MEDIUM_TOP, -20 })!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    // The level ray runs down -z from z = 0: the first box covers 0 to 20 m, the second 5 m to the emitter.
    float first_reach = 20;
    float second_reach = MEDIUM_BED_DISTANCE - SECOND_BOX_ENTRY;
    Vec3 depth = extinction_of(&first) * first_reach + extinction_of(&second) * second_reach;
    Vec3 expected = BED_COLOR.xyz * (Vec3){ math::exp(-depth.x), math::exp(-depth.y), math::exp(-depth.z) };
    check_rgb_close(pixel_at(pixels, SKY_CENTRE, SKY_CENTRE), expected, "overlap");
    check_validation(&fixture.renderer);
}

// The tolerance is FOG_RELATIVE_TOLERANCE (3e-3): the HDR colour is RGBA16F, which rounds at 2^-11, and the closed form
// takes the pixel ray's plane crossing in float. Without the cut the mirror camera's own body would fog the first
// 23 m of the ray and darken the pixel by exp(-1.15), a 68 % change, far outside it.
fn void test_medium_in_a_clip_plane_frame_applies_only_past_the_plane() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 0;
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    Vec3 down_the_view = { 0, -math::sin(MIRROR_PITCH), -math::cos(MIRROR_PITCH) };
    target.camera.local.rotation = maths::look_rotation(down_the_view, { 0, 1, 0 });
    Node* mirror = target.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "mirror")!!;
    Mat4 mirrored = maths::reflection_matrix(WATER_PLANE).mul(target.camera.local.to_mat4());
    mirror.local = maths::transform_from_affine(mirrored)!!;
    target.camera = mirror;

    MediumVolume body = {
        .absorption  = { 0.05f, 0.05f, 0.05f },
        .half_extent = { MEDIUM_MIRROR_BOX, MEDIUM_MIRROR_BOX },
        .depth       = MEDIUM_DEPTH,
    };
    MediumVolume above = MEDIUM_WATER;
    above.half_extent = { MEDIUM_MIRROR_BOX, MEDIUM_MIRROR_BOX };
    above.depth = 100;
    add_medium_box(&target, body, { 0, 0, 0 })!!;
    add_medium_box(&target, above, { 0, 100, 0 })!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD, WATER_PLANE)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    FogRay to_bed = pixel_ray(&target, SKY_CENTRE, BED_DISTANCE);
    float entry = -to_bed.origin.y / to_bed.direction.y;
    assert(entry > 0 && entry < to_bed.distance, "the centre ray crosses the plane before the bed: %f", entry);
    assert(to_bed.origin.y < 0, "the mirror camera sits inside the body's box");
    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    Vec3 expected = absorbed(extinction_of(&above), to_bed.distance - entry, BED_COLOR.xyz);
    check_rgb_close(pixel_at(pixels, SKY_CENTRE, SKY_CENTRE), expected, "the part past the plane");
    check_validation(&fixture.renderer);
}

// In-scatter of a box along a ray by midpoint integration: the ambient, and the sun through the phase and the
// column from the top face along the sun.
fn Vec3 integrated_scattering(MediumVolume* medium, FogRay ray, Vec3 to_sun, float sun_intensity) @private {
    Vec3 extinction = extinction_of(medium);
    float reach = covered_distance(ray);
    float g = medium.anisotropy;
    float denominator = 1 + g * g - 2 * g * ray.direction.dot(to_sun);
    float phase = (1 - g * g) / (4 * (float)math::PI * denominator * math::sqrt(denominator));
    double step = (double)reach / MEDIUM_REFERENCE_STEPS;
    double[3] total;
    for (uint index = 0; index < MEDIUM_REFERENCE_STEPS; index++) {
        double along = ((double)index + 0.5) * step;
        double below_top = MEDIUM_TOP - (ray.origin.y + ray.direction.y * along);
        double column = below_top / to_sun.y;
        for (uint channel = 0; channel < 3; channel++) {
            double view = math::exp(-(double)extinction[channel] * along);
            double sun = (double)sun_intensity * phase * math::exp(-(double)extinction[channel] * column);
            total[channel] += (double)medium.scattering[channel] * (FOG_AMBIENT[channel] + sun) * view * step;
        }
    }
    return { (float)total[0], (float)total[1], (float)total[2] };
}

fn void test_medium_scatters_the_ambient_and_the_sun_through_its_column() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, { 0, 0, 0, 1 })!!, MEDIUM_BED_DISTANCE)!!;
    MediumVolume medium = MEDIUM_WATER;
    medium.anisotropy = 0.4f;
    add_medium_box(&target, medium, { 0, MEDIUM_TOP, 0 })!!;
    Vec3 to_sun = ((Vec3){ 0.3f, 0.7f, -0.6f }).normalize();
    add_plain_sun(&target, to_sun, false)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    uint[2] rows = { SKY_CENTRE, SKY_UPPER_ROW };
    String[2] names = { "level ray", "ray leaving through the top face" };
    foreach (index, row : rows) {
        FogRay ray = pixel_ray(&target, row, MEDIUM_BED_DISTANCE);
        Vec3 expected = integrated_scattering(&medium, ray, to_sun, VOLUME_SUN_INTENSITY);
        check_rgb_close(pixel_at(pixels, SKY_CENTRE, row), expected, names[index]);
    }

    target.sun.local.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    Vec4[] below = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(below);
    FogRay level = pixel_ray(&target, SKY_CENTRE, MEDIUM_BED_DISTANCE);
    Vec3 ambient_only = integrated_scattering(&medium, level, { 0, -1, 0 }, 0);
    check_rgb_close(pixel_at(below, SKY_CENTRE, SKY_CENTRE), ambient_only, "a sun below the horizon scatters nothing");
    check_validation(&fixture.renderer);
}
