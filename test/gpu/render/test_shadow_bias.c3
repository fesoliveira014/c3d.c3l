module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::math;

const uint  BIAS_SHADOW_RESOLUTION @private = 2048; // the default atlas, so cascade texels match the sky example's
const uint  BIAS_IMAGE_SIZE @private = 256;
const uint  BIAS_PIXELS @private = BIAS_IMAGE_SIZE * BIAS_IMAGE_SIZE;
const float BIAS_SHADOW_DISTANCE @private = 400; // the sky example's coverage: splits near 21, 45, 100 and 400 m
const float BIAS_GROUND_SIZE @private = 2000; // holds every camera and the ground under the last cascade
const float BIAS_SUN_INTENSITY @private = 3;
const float BIAS_SUN_AZIMUTH_DEGREES @private = 30; // from -Z toward +X; the shadow lattice runs oblique to the casters
const float BIAS_CAMERA_NEAR @private = 0.1f;
const float BIAS_PITCH_DEGREES @private = -30;
const float BIAS_WIDE_FOV_DEGREES @private = 60; // with the pitch, the top row meets the horizon
const float BIAS_WIDE_HEIGHT @private = 10; // the bottom row meets the ground 10 m deep, inside the first cascade
const float BIAS_PROBE_FOV_DEGREES @private = 2; // a ground pixel spans about half a texel of the probed cascade
const float BIAS_CONTACT_ELEVATION_DEGREES @private = 46.5f;
const float BIAS_BOX_SIZE @private = 1;
const float BIAS_SLAB_OFFSETS @private = 1.5f; // slab thickness in normal offsets of its cascade
const float BIAS_SLAB_STEP_TEXELS @private = 0.25f;
const float BIAS_MAP_TILT_DEGREES @private = 20;
const float BIAS_LIT_VISIBILITY @private = 0.99f;
const float BIAS_SHADOWED_VISIBILITY @private = 0.5f;
const float BIAS_NORMAL_MAP_TOLERANCE @private = 0.02f;
const float BIAS_FLAT_VARIANCE @private = 0.001f;
const float BIAS_EDGE_TOLERANCE @private = 0.05f;
const float BIAS_SUNLIT_LUMINANCE @private = 0.001f; // dimmer pixels face away from the sun and carry no visibility
const float BIAS_PENUMBRA_LOW @private = 0.05f;
const float BIAS_PENUMBRA_HIGH @private = 0.95f;
const uint  BIAS_MIN_CASCADE_PIXELS @private = 64;
const uint  BIAS_MIN_PENUMBRA_PIXELS @private = 16; // the box's shadow edge must cross the probe image
const uint  BIAS_MIN_SILHOUETTE_PIXELS @private = 32;
const uint  BIAS_FLAT_BLOCK @private = 16;
const uint  BIAS_FLAT_BLOCK_ORIGIN @private = 8; // the top-left corner: open ground beside and beyond the box
const float[4] BIAS_SWEEP_ELEVATIONS_DEGREES @private = { 10, 20, 46.5f, 60 };
const float[3] BIAS_CONTACT_TEXELS @private = { 1, 2, 4 }; // ground probes in front of the box's base
const uint[2] BIAS_CONTACT_CASCADES @private = { 0, 2 };
const uint[2] BIAS_DEFERRED_CASCADES @private = { 2, 3 };

struct BiasFixture @private {
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    Node* camera_node;
    Node* sun;
    Node* ground;
    Node* box;
    MaterialId matte;
    MaterialId mapped;
    RenderTargetId target;
    ViewId forward_view;
    ViewId deferred_view;
    Vec4[] shadowed_pixels;
    Vec4[] open_pixels;
}

struct BiasVisibility @private {
    float[] values; // shadowed luminance over the luminance with the sun's shadows off
    bool[] sunlit;
}

fn void? create_bias_fixture(BiasFixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer catch scene::destroy_scene(&fixture.scene);

    GeometryId ground_geometry;
    GeometryId box_geometry;
    @pool() {
        Geometry ground = geometry::plane(tmem, BIAS_GROUND_SIZE, BIAS_GROUND_SIZE);
        TangentGeometry tangent_ground = geometry::create_tangent_geometry(fixture.assets.allocator, &ground)!;
        defer geometry::destroy_tangent_geometry(&tangent_ground);
        ground_geometry = fixture.assets.add_tangent_geometry_owned(&tangent_ground)!;

        Geometry box = geometry::box(
            allocator: tmem,
            width: BIAS_BOX_SIZE,
            height: BIAS_BOX_SIZE,
            depth: BIAS_BOX_SIZE,
        );
        box_geometry = fixture.assets.add_geometry(&box)!;
    };
    fixture.matte = fixture.assets.add_material(material::standard(bias_matte_params()))!;
    fixture.mapped = bias_add_tilted_normal_material(fixture)!;
    fixture.ground = fixture.scene.add_mesh(ground_geometry, fixture.matte, name: "ground")!;
    fixture.box = fixture.scene.add_mesh(box_geometry, fixture.matte, name: "box")!;
    fixture.box.visible = false;
    Light sunlight = light::directional({ 1, 1, 1 }, BIAS_SUN_INTENSITY);
    sunlight.shadow.max_distance = BIAS_SHADOW_DISTANCE;
    fixture.sun = fixture.scene.add_light(sunlight, name: "sun")!;
    Camera lens = camera::perspective_deg(BIAS_WIDE_FOV_DEGREES, BIAS_CAMERA_NEAR);
    fixture.camera_node = fixture.scene.add_camera(lens, name: "camera")!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .shadow_resolution = BIAS_SHADOW_RESOLUTION,
            .max_shadow_layers = light::MAX_SHADOW_CASCADES,
            .application_name = "shadow_bias_acceptance",
        },
    )!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(BIAS_IMAGE_SIZE, BIAS_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    fixture.forward_view = create_bias_view(fixture, ShadingPath.FORWARD)!;
    fixture.deferred_view = create_bias_view(fixture, ShadingPath.DEFERRED)!;
    fixture.shadowed_pixels = mem::new_array(Vec4, BIAS_PIXELS);
    fixture.open_pixels = mem::new_array(Vec4, BIAS_PIXELS);
}

fn void destroy_bias_fixture(BiasFixture* fixture) @private {
    free(fixture.shadowed_pixels);
    free(fixture.open_pixels);
    render::wait_frames(&fixture.renderer)!!;
    check_validation(&fixture.renderer);
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn StandardParams bias_matte_params() @private {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.8f, 0.8f, 0.8f, 1 };
    params.metallic = 0;
    params.roughness = 1;
    return params;
}

fn MaterialId? bias_add_tilted_normal_material(BiasFixture* fixture) @private {
    float tilt = math::deg_to_rad(BIAS_MAP_TILT_DEGREES);
    char[4] texel = {
        (char)math::round((math::sin(tilt) * 0.5f + 0.5f) * 255),
        128,
        (char)math::round((math::cos(tilt) * 0.5f + 0.5f) * 255),
        255,
    };
    TextureDesc texture_desc = material::texture_2d_desc(
        width:      1,
        height:     1,
        format:     PixelFormat.RGBA8_UNORM,
        debug_name: "tilted_normal",
    );
    texture_desc.generate_mips = false;
    StandardParams params = bias_matte_params();
    params.normal_map = material::texture_slot(fixture.assets.add_texture(texture_desc, texel[..])!);
    params.normal_scale = 1;
    return fixture.assets.add_material(material::standard(params));
}

fn ViewId? create_bias_view(BiasFixture* fixture, ShadingPath shading) @private {
    ViewDesc desc = render::texture_view_desc(fixture.target);
    desc.shading = shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    return render::create_view(&fixture.renderer, desc);
}

fn BiasVisibility bias_new_visibility() @private {
    return { .values = mem::new_array(float, BIAS_PIXELS), .sunlit = mem::new_array(bool, BIAS_PIXELS) };
}

fn void bias_free_visibility(BiasVisibility* image) @private {
    free(image.values);
    free(image.sunlit);
}

fn float bias_luminance_of(Vec4 color) @private {
    return 0.2126f * color.x + 0.7152f * color.y + 0.0722f * color.z;
}

fn void? render_bias_frame(BiasFixture* fixture, ViewId view, bool shadowed) @private {
    fixture.scene.get(fixture.sun, Light).shadow.enabled = shadowed;
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, fixture.camera_node, view)!;
    renderer.finish_view(view)!;
    return renderer.end_frame();
}

fn void? read_bias_image(BiasFixture* fixture, Vec4[] pixels) @private {
    return fixture.renderer.read_render_target(fixture.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size]);
}

// Leaves the sun's shadows enabled.
fn void? bias_render_visibility(BiasFixture* fixture, ViewId view, BiasVisibility* image) @private {
    render_bias_frame(fixture, view, false)!;
    read_bias_image(fixture, fixture.open_pixels)!;
    render_bias_frame(fixture, view, true)!;
    read_bias_image(fixture, fixture.shadowed_pixels)!;
    foreach (index, color : fixture.open_pixels) {
        float open = bias_luminance_of(color);
        image.sunlit[index] = open > BIAS_SUNLIT_LUMINANCE;
        image.values[index] = image.sunlit[index] ? bias_luminance_of(fixture.shadowed_pixels[index]) / open : 1;
    }
}

fn Vec3 bias_sun_heading() @private {
    float azimuth = math::deg_to_rad(BIAS_SUN_AZIMUTH_DEGREES);
    return { math::sin(azimuth), 0, -math::cos(azimuth) };
}

fn void bias_set_sun_elevation(BiasFixture* fixture, float degrees) @private {
    float elevation = math::deg_to_rad(degrees);
    Vec3 toward_sun = bias_sun_heading() * math::cos(elevation) + (Vec3){ 0, math::sin(elevation), 0 };
    fixture.sun.local.rotation = maths::look_rotation(-toward_sun, { 0, 1, 0 });
}

// Every camera looks toward the sun's azimuth, so shadows fall toward it.
fn Vec3 bias_camera_forward() @private {
    float pitch = math::deg_to_rad(BIAS_PITCH_DEGREES);
    return bias_sun_heading() * math::cos(pitch) + (Vec3){ 0, math::sin(pitch), 0 };
}

fn void bias_place_wide_camera(BiasFixture* fixture) @private {
    fixture.scene.get(fixture.camera_node, Camera).fov_y = math::deg_to_rad(BIAS_WIDE_FOV_DEGREES);
    fixture.camera_node.local.position = { 0, BIAS_WIDE_HEIGHT, 0 };
    fixture.camera_node.local.rotation = maths::look_rotation(bias_camera_forward(), { 0, 1, 0 });
}

// The world origin lands at the image centre, depth metres down the view axis.
fn void bias_place_probe_camera(BiasFixture* fixture, float depth) @private {
    fixture.scene.get(fixture.camera_node, Camera).fov_y = math::deg_to_rad(BIAS_PROBE_FOV_DEGREES);
    fixture.camera_node.local.position = -bias_camera_forward() * depth;
    fixture.camera_node.local.rotation = maths::look_rotation(bias_camera_forward(), { 0, 1, 0 });
}

// The caster's camera-side face stands on the ground through the world origin.
fn void bias_place_caster(Node* caster, float height) @private {
    caster.local.position = bias_sun_heading() * (BIAS_BOX_SIZE / 2) + (Vec3){ 0, height / 2, 0 };
    caster.local.rotation = maths::look_rotation(bias_sun_heading(), { 0, 1, 0 });
}

fn CameraMatrices bias_matrices(BiasFixture* fixture) @private {
    Camera lens = *fixture.scene.get(fixture.camera_node, Camera);
    return camera::derive_matrices(lens, fixture.camera_node.world, { BIAS_IMAGE_SIZE, BIAS_IMAGE_SIZE });
}

fn CascadeSplits bias_splits(BiasFixture* fixture) @private {
    Camera lens = *fixture.scene.get(fixture.camera_node, Camera);
    return render::directional_cascade_splits(lens, fixture.scene.get(fixture.sun, Light).shadow);
}

// The middle of the depths only this cascade shades, before its blend band.
fn float bias_cascade_probe_depth(BiasFixture* fixture, CascadeSplits splits, uint index) @private {
    float blend = fixture.scene.get(fixture.sun, Light).shadow.cascade_blend;
    float start = index ? splits.far_depths[index - 1] : splits.near_depth;
    return (start + render::cascade_blend_depth(splits, index, blend)) / 2;
}

fn float bias_cascade_normal_bias(BiasFixture* fixture, CascadeSplits splits, uint index) @private {
    CameraMatrices matrices = bias_matrices(fixture);
    ShadowSettings settings = fixture.scene.get(fixture.sun, Light).shadow;
    float near_depth = index
      ? render::cascade_blend_depth(splits, index - 1, settings.cascade_blend) : splits.near_depth;
    ShadowCascade cascade = render::fit_directional_cascade(
        view: &matrices,
        near_depth: near_depth,
        far_depth: splits.far_depths[index],
        light_direction: maths::transform_dir(fixture.sun.world, { 0, 0, -1 }).normalize(),
        casters: {},
        resolution: BIAS_SHADOW_RESOLUTION,
        normal_bias_texels: settings.directional_normal_bias_texels,
    );
    return cascade.normal_bias;
}

fn usz bias_pixel_of(BiasFixture* fixture, Vec3 point) @private {
    CameraMatrices matrices = bias_matrices(fixture);
    Vec4 clip = matrices.view_proj.apply({ point.x, point.y, point.z, 1 });
    usz column = (usz)((clip.x / clip.w * 0.5f + 0.5f) * BIAS_IMAGE_SIZE);
    usz row = (usz)((0.5f - clip.y / clip.w * 0.5f) * BIAS_IMAGE_SIZE);
    return row * BIAS_IMAGE_SIZE + column;
}

fn Vec3 bias_camera_ray(CameraMatrices* matrices, Vec3 origin, usz index) @private {
    float ndc_x = 2 * ((float)(index % BIAS_IMAGE_SIZE) + 0.5f) / BIAS_IMAGE_SIZE - 1;
    float ndc_y = 1 - 2 * ((float)(index / BIAS_IMAGE_SIZE) + 0.5f) / BIAS_IMAGE_SIZE;
    Vec4 near_point = matrices.inv_view_proj.apply({ ndc_x, ndc_y, 1, 1 });
    return (near_point.xyz / near_point.w - origin).normalize();
}

// Camera-space depth of the ground under each pixel centre; float::max where the pixel sees the sky.
fn void bias_ground_view_depths(BiasFixture* fixture, float[] depths) @private {
    CameraMatrices matrices = bias_matrices(fixture);
    Vec3 origin = maths::translation(fixture.camera_node.world);
    foreach (usz index, &depth : depths) {
        Vec3 direction = bias_camera_ray(&matrices, origin, index);
        *depth = float::max;
        if (direction.y >= 0) continue;
        Vec3 ground = origin + direction * (-origin.y / direction.y);
        *depth = -maths::transform_point(matrices.view, ground).z;
    }
}

fn uint bias_cascade_of(CascadeSplits splits, float depth) @private {
    uint index;
    while (depth > splits.far_depths[index]) index++;
    return index;
}

fn bool bias_ray_hits_box(Node* box, Vec3 origin, Vec3 direction) @private {
    Mat4 to_local = maths::inverse_affine(box.world);
    Vec3 local_origin = maths::transform_point(to_local, origin);
    Vec3 local_direction = maths::transform_dir(to_local, direction);
    float half_size = BIAS_BOX_SIZE / 2;
    float enter = -float::max;
    float leave = float::max;
    for (uint axis = 0; axis < 3; axis++) {
        if (local_direction[axis] == 0) {
            if (math::abs(local_origin[axis]) > half_size) return false;
            continue;
        }
        float first = (-half_size - local_origin[axis]) / local_direction[axis];
        float second = (half_size - local_origin[axis]) / local_direction[axis];
        enter = math::max(enter, math::min(first, second));
        leave = math::min(leave, math::max(first, second));
    }
    return enter <= leave && leave > 0;
}

fn void bias_box_coverage(BiasFixture* fixture, bool[] covered) @private {
    CameraMatrices matrices = bias_matrices(fixture);
    Vec3 origin = maths::translation(fixture.camera_node.world);
    foreach (usz index, &pixel : covered) {
        *pixel = bias_ray_hits_box(fixture.box, origin, bias_camera_ray(&matrices, origin, index));
    }
}

fn bool bias_on_silhouette(bool[] covered, usz index) @private {
    bool inside = covered[index];
    return covered[index - 1] != inside || covered[index + 1] != inside
        || covered[index - BIAS_IMAGE_SIZE] != inside || covered[index + BIAS_IMAGE_SIZE] != inside;
}

fn float bias_flat_block_variance(BiasVisibility* image) @private {
    float sum;
    float squares;
    for (uint row = BIAS_FLAT_BLOCK_ORIGIN; row < BIAS_FLAT_BLOCK_ORIGIN + BIAS_FLAT_BLOCK; row++) {
        for (uint column = BIAS_FLAT_BLOCK_ORIGIN; column < BIAS_FLAT_BLOCK_ORIGIN + BIAS_FLAT_BLOCK; column++) {
            usz index = (usz)row * BIAS_IMAGE_SIZE + column;
            assert(image.sunlit[index]);
            sum += image.values[index];
            squares += image.values[index] * image.values[index];
        }
    }
    float count = BIAS_FLAT_BLOCK * BIAS_FLAT_BLOCK;
    float mean = sum / count;
    return squares / count - mean * mean;
}

fn void test_flat_ground_stays_lit_in_every_cascade() @test {
    BiasFixture fixture;
    create_bias_fixture(&fixture)!!;
    defer destroy_bias_fixture(&fixture);
    BiasVisibility image = bias_new_visibility();
    defer bias_free_visibility(&image);
    float[] depths = mem::new_array(float, BIAS_PIXELS);
    defer free(depths);
    bias_place_wide_camera(&fixture);
    fixture.scene.update_world();
    bias_ground_view_depths(&fixture, depths);
    CascadeSplits splits = bias_splits(&fixture);
    float coverage_end = splits.far_depths[splits.count - 1];

    ViewId[2] views = { fixture.forward_view, fixture.deferred_view };
    ZString[2] names = { "forward", "deferred" };
    foreach (elevation : BIAS_SWEEP_ELEVATIONS_DEGREES) {
        bias_set_sun_elevation(&fixture, elevation);
        fixture.scene.update_world();
        foreach (view_index, view : views) {
            bias_render_visibility(&fixture, view, &image)!!;
            uint[light::MAX_SHADOW_CASCADES] counts;
            float[light::MAX_SHADOW_CASCADES] lowest = { 1, 1, 1, 1 };
            foreach (index, depth : depths) {
                if (depth > coverage_end || !image.sunlit[index]) continue;
                uint cascade = bias_cascade_of(splits, depth);
                counts[cascade]++;
                lowest[cascade] = math::min(lowest[cascade], image.values[index]);
            }
            io::eprintfn(
                "%s, sun %.1f degrees: lowest %s over %s pixels",
                names[view_index],
                elevation,
                lowest,
                counts,
            );
            for (uint cascade = 0; cascade < splits.count; cascade++) {
                assert(counts[cascade] >= BIAS_MIN_CASCADE_PIXELS);
                assert(lowest[cascade] >= BIAS_LIT_VISIBILITY);
            }
        }
    }
}

fn void test_contact_shadow_stays_attached() @test {
    BiasFixture fixture;
    create_bias_fixture(&fixture)!!;
    defer destroy_bias_fixture(&fixture);
    BiasVisibility image = bias_new_visibility();
    defer bias_free_visibility(&image);
    bias_set_sun_elevation(&fixture, BIAS_CONTACT_ELEVATION_DEGREES);
    fixture.box.visible = true;
    bias_place_caster(fixture.box, BIAS_BOX_SIZE);
    float offset_texels = fixture.scene.get(fixture.sun, Light).shadow.directional_normal_bias_texels;

    foreach (cascade : BIAS_CONTACT_CASCADES) {
        CascadeSplits splits = bias_splits(&fixture);
        bias_place_probe_camera(&fixture, bias_cascade_probe_depth(&fixture, splits, cascade));
        fixture.scene.update_world();
        float texel = bias_cascade_normal_bias(&fixture, splits, cascade) / offset_texels;
        bias_render_visibility(&fixture, fixture.forward_view, &image)!!;
        foreach (texels : BIAS_CONTACT_TEXELS) {
            usz pixel = bias_pixel_of(&fixture, -bias_sun_heading() * (texels * texel));
            io::eprintfn(
                "cascade %d, %.0f texels before the box: %.3f",
                cascade,
                texels,
                image.values[pixel],
            );
            assert(image.sunlit[pixel]);
            assert(image.values[pixel] <= BIAS_SHADOWED_VISIBILITY);
        }
    }
}

fn void test_slab_thicker_than_the_offset_keeps_its_shadow() @test {
    BiasFixture fixture;
    create_bias_fixture(&fixture)!!;
    defer destroy_bias_fixture(&fixture);
    BiasVisibility image = bias_new_visibility();
    defer bias_free_visibility(&image);
    bias_set_sun_elevation(&fixture, BIAS_CONTACT_ELEVATION_DEGREES);
    CascadeSplits splits = bias_splits(&fixture);
    bias_place_probe_camera(&fixture, bias_cascade_probe_depth(&fixture, splits, 0));
    fixture.scene.update_world();
    float normal_bias = bias_cascade_normal_bias(&fixture, splits, 0);
    float texel = normal_bias / fixture.scene.get(fixture.sun, Light).shadow.directional_normal_bias_texels;
    float thickness = BIAS_SLAB_OFFSETS * normal_bias;

    GeometryId slab_geometry;
    @pool() {
        Geometry slab_shape = geometry::box(
            allocator: tmem,
            width: BIAS_BOX_SIZE,
            height: thickness,
            depth: BIAS_BOX_SIZE,
        );
        slab_geometry = fixture.assets.add_geometry(&slab_shape)!!;
    };
    Node* slab = fixture.scene.add_mesh(slab_geometry, fixture.matte, name: "slab")!!;
    bias_place_caster(slab, thickness);
    fixture.scene.update_world();
    bias_render_visibility(&fixture, fixture.forward_view, &image)!!;

    float unbiased_length = thickness / math::tan(math::deg_to_rad(BIAS_CONTACT_ELEVATION_DEGREES));
    float step = BIAS_SLAB_STEP_TEXELS * texel;
    float darkest = 1;
    for (float distance = step; distance <= unbiased_length; distance += step) {
        darkest = math::min(darkest, image.values[bias_pixel_of(&fixture, -bias_sun_heading() * distance)]);
    }
    io::eprintfn(
        "slab %.4f m thick: darkest %.3f within %.4f m of its edge",
        thickness,
        darkest,
        unbiased_length,
    );
    assert(darkest <= BIAS_SHADOWED_VISIBILITY);
}

fn void test_deferred_offset_ignores_normal_map() @test {
    BiasFixture fixture;
    create_bias_fixture(&fixture)!!;
    defer destroy_bias_fixture(&fixture);
    BiasVisibility plain = bias_new_visibility();
    defer bias_free_visibility(&plain);
    BiasVisibility mapped = bias_new_visibility();
    defer bias_free_visibility(&mapped);
    bias_set_sun_elevation(&fixture, BIAS_CONTACT_ELEVATION_DEGREES);
    fixture.box.visible = true;
    bias_place_caster(fixture.box, BIAS_BOX_SIZE);
    CascadeSplits splits = bias_splits(&fixture);

    foreach (cascade : BIAS_DEFERRED_CASCADES) {
        bias_place_probe_camera(&fixture, bias_cascade_probe_depth(&fixture, splits, cascade));
        fixture.scene.update_world();
        fixture.scene.get(fixture.ground, Mesh).material = fixture.matte;
        bias_render_visibility(&fixture, fixture.deferred_view, &plain)!!;
        fixture.scene.get(fixture.ground, Mesh).material = fixture.mapped;
        bias_render_visibility(&fixture, fixture.deferred_view, &mapped)!!;

        float largest_difference;
        uint penumbra;
        foreach (index, value : mapped.values) {
            if (!mapped.sunlit[index] || !plain.sunlit[index]) continue;
            largest_difference = math::max(largest_difference, math::abs(value - plain.values[index]));
            if (plain.values[index] > BIAS_PENUMBRA_LOW && plain.values[index] < BIAS_PENUMBRA_HIGH) penumbra++;
        }
        float variance = bias_flat_block_variance(&mapped);
        io::eprintfn(
            "cascade %d: largest difference %.4f over %d penumbra pixels, open variance %.6f",
            cascade,
            largest_difference,
            penumbra,
            variance,
        );
        assert(penumbra >= BIAS_MIN_PENUMBRA_PIXELS);
        assert(largest_difference <= BIAS_NORMAL_MAP_TOLERANCE);
        assert(variance <= BIAS_FLAT_VARIANCE);
    }
}

fn void test_deferred_offsets_match_forward_across_edges() @test {
    BiasFixture fixture;
    create_bias_fixture(&fixture)!!;
    defer destroy_bias_fixture(&fixture);
    BiasVisibility forward = bias_new_visibility();
    defer bias_free_visibility(&forward);
    BiasVisibility deferred = bias_new_visibility();
    defer bias_free_visibility(&deferred);
    bool[] covered = mem::new_array(bool, BIAS_PIXELS);
    defer free(covered);
    bias_set_sun_elevation(&fixture, BIAS_CONTACT_ELEVATION_DEGREES);
    fixture.box.visible = true;
    bias_place_caster(fixture.box, BIAS_BOX_SIZE);
    CascadeSplits splits = bias_splits(&fixture);

    foreach (cascade : BIAS_DEFERRED_CASCADES) {
        bias_place_probe_camera(&fixture, bias_cascade_probe_depth(&fixture, splits, cascade));
        fixture.scene.update_world();
        bias_render_visibility(&fixture, fixture.forward_view, &forward)!!;
        bias_render_visibility(&fixture, fixture.deferred_view, &deferred)!!;
        bias_box_coverage(&fixture, covered);

        uint silhouette_pixels;
        float largest_difference;
        for (usz row = 1; row + 1 < BIAS_IMAGE_SIZE; row++) {
            for (usz column = 1; column + 1 < BIAS_IMAGE_SIZE; column++) {
                usz index = row * BIAS_IMAGE_SIZE + column;
                if (!forward.sunlit[index] || !deferred.sunlit[index]) continue;
                if (bias_on_silhouette(covered, index)) silhouette_pixels++;
                float difference = math::abs(forward.values[index] - deferred.values[index]);
                largest_difference = math::max(largest_difference, difference);
            }
        }
        io::eprintfn(
            "cascade %d: largest difference %.4f with %d silhouette pixels",
            cascade,
            largest_difference,
            silhouette_pixels,
        );
        assert(silhouette_pixels >= BIAS_MIN_SILHOUETTE_PIXELS);
        assert(largest_difference <= BIAS_EDGE_TOLERANCE);
    }
}
