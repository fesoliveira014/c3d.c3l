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
const float MEDIUM_RAISE @private = 10;         // metres the second box top sits above the first, deepening the camera
const float FLOOR_DEPTH @private = 2;           // metres from the box top down to the floor
const float FAR_FACE @private = 15;             // half extent along z: the floor of row 27 is inside, row 19's past it
const float SUN_COSINE @private = 0.6f;         // the sun's cosine to the box's up
const uint FLOOR_OUTSIDE_ROW @private = 19;
const Vec3 FLOOR_ABSORPTION @private = { 0.1f, 0.2f, 0.05f };
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

fn Vec4 level_pixel(Fixture* fixture, FogScene* target, FogView* fog_view) @private {
    Vec4[] pixels = render_fog_pixels(fixture, target, fog_view)!!;
    defer free(pixels);
    return pixel_at(pixels, SKY_CENTRE, SKY_CENTRE);
}

fn float channel_sum(Vec3 value) @private {
    return value.x + value.y + value.z;
}

// Every case compares two renders of one scene: the black emitter makes a pixel the medium's own in-scatter, and the
// render without a sun is the ambient the sun term is measured over.
fn void test_medium_sun_term_follows_its_phase_and_its_column() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, { 0, 0, 0, 1 })!!, MEDIUM_BED_DISTANCE)!!;
    MediumVolume medium = MEDIUM_WATER;
    medium.anisotropy = 0.4f;
    medium.depth = MEDIUM_DEPTH + MEDIUM_RAISE;
    Node* box = add_medium_box(&target, medium, { 0, MEDIUM_TOP, 0 })!!;
    Vec3 to_sun = ((Vec3){ 0.3f, 0.7f, -0.6f }).normalize();
    Node* sun = add_plain_sun(&target, to_sun, false)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Light* lamp = target.scene.get(sun, Light);
    float intensity = lamp.intensity;
    lamp.intensity = 0;
    Vec3 ambient = level_pixel(&fixture, &target, &fog_view).xyz;
    assert(ambient.x > 0 && ambient.z > 0 && ambient.y == 0, "the ambient scatters in the channels that scatter");

    lamp.intensity = intensity;
    float forward = channel_sum(level_pixel(&fixture, &target, &fog_view).xyz - ambient);
    assert(forward > 0, "the sun adds light: %f", forward);
    target.scene.get(box, MediumVolume).anisotropy = -0.4f;
    float backward = channel_sum(level_pixel(&fixture, &target, &fog_view).xyz - ambient);
    assert(forward > 2 * backward, "forward scattering toward the sun is brighter: %f against %f", forward, backward);

    target.scene.get(box, MediumVolume).anisotropy = 0.4f;
    box.local.position.y = MEDIUM_TOP + MEDIUM_RAISE;
    target.scene.update_world();
    float deeper = channel_sum(level_pixel(&fixture, &target, &fog_view).xyz - ambient);
    assert(deeper < 0.85f * forward, "a deeper camera sees less sun: %f against %f", deeper, forward);

    box.local.position.y = MEDIUM_TOP;
    target.sun.local.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    target.scene.update_world();
    check_rgb_close(level_pixel(&fixture, &target, &fog_view), ambient, "a sun below the top face scatters nothing");
    check_validation(&fixture.renderer);
}

// Metres along a ray to the horizontal plane at a height; the ray must slope toward it.
fn float distance_to_height(FogRay ray, float height) @private {
    return (height - ray.origin.y) / ray.direction.y;
}

// Ambient zero leaves the sun the floor's only light, so a pixel inside the box is the pixel without it scaled by the
// medium's transmittance over the sun's path up to the top face and the view's path back to it. The camera lies above
// the box, so the view path is the floor's depth along the ray. A sun term without the cosine leaves the floor 7 to
// 31 % brighter per channel.
fn void check_sun_on_a_submerged_floor(ShadingPath shading) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 0;

    Node* floor = target.scene.add_mesh(target.plane, add_matte_material(&fixture, { 0.8f, 0.8f, 0.8f, 1 })!!)!!;
    floor.local.position = { 0, -FLOOR_DEPTH, 0 };
    target.scene.get(floor, Mesh).cast_shadow = false;
    add_plain_sun(&target, { 0, SUN_COSINE, 0.8f }, false)!!;

    FogView fog_view = create_fog_view(&fixture, shading)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    Vec4[] without = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(without);

    MediumVolume medium = {
        .absorption  = FLOOR_ABSORPTION,
        .half_extent = { MEDIUM_BOX_HALF, FAR_FACE },
        .depth       = MEDIUM_DEPTH,
    };
    add_medium_box(&target, medium, { 0, 0, 0 })!!;
    Vec4[] with = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(with);

    FogRay inside = pixel_ray(&target, SKY_LOWER_ROW);
    Vec3 floor_point = inside.origin + inside.direction * distance_to_height(inside, -FLOOR_DEPTH);
    assert(math::abs(floor_point.z) < FAR_FACE, "the descending ray meets the floor inside the box: %f", floor_point.z);

    float sun_path = FLOOR_DEPTH / SUN_COSINE;
    float view_path = FLOOR_DEPTH / -inside.direction.y;
    Vec3 floor_without = pixel_at(without, SKY_CENTRE, SKY_LOWER_ROW).xyz;
    Vec3 expected = absorbed(extinction_of(&medium), sun_path + view_path, floor_without);
    check_rgb_close(pixel_at(with, SKY_CENTRE, SKY_LOWER_ROW), expected, "the floor inside the box");

    FogRay outside = pixel_ray(&target, FLOOR_OUTSIDE_ROW);
    Vec3 top_point = outside.origin + outside.direction * distance_to_height(outside, 0);
    assert(-top_point.z > FAR_FACE, "the shallow ray reaches the top plane past the far face: %f", top_point.z);

    check_rgb_close(
        pixel_at(with, SKY_CENTRE, FLOOR_OUTSIDE_ROW),
        pixel_at(without, SKY_CENTRE, FLOOR_OUTSIDE_ROW).xyz,
        "the floor outside the box",
    );
    check_validation(&fixture.renderer);
}

fn void test_medium_attenuates_the_sun_on_a_submerged_floor() @test {
    check_sun_on_a_submerged_floor(ShadingPath.FORWARD);
    check_sun_on_a_submerged_floor(ShadingPath.DEFERRED);
}
