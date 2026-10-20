module c3d::render::acceptance;

import c3d;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::math;
import std::os::env;

const uint MSAA_EDGE_IMAGE_WIDTH @private = 256;
const uint MSAA_EDGE_IMAGE_HEIGHT @private = 192;
const usz MSAA_EDGE_IMAGE_BYTES @private = (usz)MSAA_EDGE_IMAGE_WIDTH * MSAA_EDGE_IMAGE_HEIGHT * 4;
const double MSAA_EDGE_MEAN_LIMIT @private = 1.0; // one 8-bit step: the frame-comparison tolerance
const uint MSAA_EDGE_MAXIMUM_LIMIT @private = 4; // exclusive, in 8-bit steps
const String MSAA_EDGE_MODE_VARIABLE @private = "C3D_MSAA_EDGES";
const String MSAA_EDGE_DUMP_VARIABLE @private = "C3D_MSAA_EDGES_DUMP";
const Vec3 MSAA_EDGE_CAMERA_POSITION @private = { 0.6f, 1.7f, 5.5f };
const Vec3 MSAA_EDGE_CAMERA_TARGET @private = { 0, 0.3f, 0 };
const Vec3 MSAA_EDGE_SUN_DIRECTION @private = { -0.5f, -1, -0.4f };
const float MSAA_EDGE_SUN_INTENSITY @private = 3;
const float MSAA_EDGE_SUN_DISTANCE @private = 20;
const uint MSAA_EDGE_SHADOW_RESOLUTION @private = 1024;

enum MsaaEdgeShadows @private {
    NONE,
    ATLAS,
    TRACED_SOFTWARE,
    TRACED_QUERIES,
}

struct MsaaEdgeScene @private {
    Scene scene;
    Node* camera;
}

struct MsaaEdgeError @private {
    double mean;
    uint   maximum;
}

fn MsaaEdgeScene? create_msaa_edge_scene(Fixture* fixture, MsaaEdgeShadows shadows) @private {
    MsaaEdgeScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = { 0.5f, 0.55f, 0.6f };
    result.scene.ambient_intensity = 0.3f;

    GeometryId sphere;
    @pool() {
        Geometry geometry = geometry::sphere(tmem, 0.55f);
        sphere = fixture.assets.add_geometry(&geometry)!;
    };
    MaterialId ground_material = fixture.assets.add_material(
        material::standard({ .base_color = { 0.55f, 0.55f, 0.58f, 1 }, .roughness = 0.8f }),
    )!;
    MaterialId red_material = fixture.assets.add_material(
        material::standard({ .base_color = { 0.85f, 0.25f, 0.2f, 1 }, .roughness = 0.45f }),
    )!;
    MaterialId blue_material = fixture.assets.add_material(
        material::standard({ .base_color = { 0.2f, 0.4f, 0.85f, 1 }, .metallic = 0.6f, .roughness = 0.35f }),
    )!;

    Node* ground = result.scene.add_mesh(fixture.box, ground_material, name: "ground")!;
    ground.local.position = { 0, -0.55f, 0 };
    ground.local.scale = { 12, 0.1f, 12 };

    for (uint side = 0; side < 2; side++) {
        bool receives = side == 0;
        Node* seam = result.scene.add_mesh(fixture.box, red_material, name: receives ? "shadowed" : "unshadowed")!;
        seam.local.position = { receives ? -0.5f : 0.5f, 0, 0 };
        if (Mesh* mesh = result.scene.get(seam, Mesh)) mesh.receive_shadow = receives;
    }

    Node* canopy = result.scene.add_mesh(fixture.box, ground_material, name: "canopy")!;
    canopy.local.position = { -0.1f, 1.3f, 0.1f };
    canopy.local.scale = { 1.6f, 0.08f, 0.9f };

    Node* ball = result.scene.add_mesh(sphere, blue_material, name: "ball")!;
    ball.local.position = { -2, 0, -1 };

    Node* tilted = result.scene.add_mesh(fixture.box, blue_material, name: "tilted")!;
    tilted.local.position = { 2, 0.2f, 0.2f };
    tilted.local.rotation = maths::look_rotation({ 0.6f, -0.3f, -1 }, { 0.2f, 1, 0 });

    Light sun = light::directional({ 1, 0.95f, 0.85f }, MSAA_EDGE_SUN_INTENSITY, shadows != MsaaEdgeShadows.NONE);
    sun.shadow.cascades = 1;
    sun.shadow.max_distance = MSAA_EDGE_SUN_DISTANCE;
    sun.shadow.ray_traced = shadows == MsaaEdgeShadows.TRACED_SOFTWARE || shadows == MsaaEdgeShadows.TRACED_QUERIES;
    Node* sun_node = result.scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation(MSAA_EDGE_SUN_DIRECTION.normalize(), { 0, 1, 0 });

    result.camera = result.scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!;
    result.camera.local.position = MSAA_EDGE_CAMERA_POSITION;
    result.camera.local.rotation = maths::look_rotation(MSAA_EDGE_CAMERA_TARGET - MSAA_EDGE_CAMERA_POSITION, { 0, 1, 0 });
    result.scene.update_world();
    return result;
}

fn void? render_msaa_edge_image(
    String mode,
    MsaaEdgeShadows shadows,
    MsaaSamples msaa,
    MsaaEdgeMode expected,
    char[] pixels,
) @private {
    env::set_var(MSAA_EDGE_MODE_VARIABLE, mode);
    Fixture fixture;
    create_fixture(
        allocator:         mem,
        fixture:           &fixture,
        ray_queries:       shadows == MsaaEdgeShadows.TRACED_QUERIES,
        shadow_resolution: MSAA_EDGE_SHADOW_RESOLUTION,
        max_shadow_layers: 1,
    )!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    assert(renderer.msaa_edge_mode == expected);

    MsaaEdgeScene edge = create_msaa_edge_scene(&fixture, shadows)!;
    defer scene::destroy_scene(&edge.scene);
    RenderTargetId target = render::create_render_target(
        renderer,
        render::render_target_desc(MSAA_EDGE_IMAGE_WIDTH, MSAA_EDGE_IMAGE_HEIGHT, PixelFormat.RGBA8_UNORM),
    )!;
    ViewId view = render::create_view(renderer, render::texture_view_desc(target, OutputMode.DISPLAY_LDR))!;
    ViewDesc desc = renderer.views.get(view).desc;
    desc.shading = ShadingPath.DEFERRED;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.msaa = msaa;
    desc.ray_tracing.shadows = shadows == MsaaEdgeShadows.TRACED_SOFTWARE || shadows == MsaaEdgeShadows.TRACED_QUERIES;
    render::configure_view(renderer, view, desc)!;

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&edge.scene, edge.camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    renderer.read_render_target(target, pixels)!;
}

fn MsaaEdgeError compare_msaa_edge_images(char[] actual, char[] expected) @private {
    MsaaEdgeError error;
    ulong total;
    foreach (index, value : actual) {
        uint difference = (uint)math::abs((int)value - (int)expected[index]);
        error.maximum = math::max(error.maximum, difference);
        total += difference;
    }

    error.mean = (double)total / actual.len;
    return error;
}

fn void dump_msaa_edge_image(String label, MsaaEdgeShadows shadows, MsaaSamples msaa, char[] pixels) @private {
    if (try directory = env::tget_var(MSAA_EDGE_DUMP_VARIABLE)) {
        String path = string::tformat(
            "%s/%s_%s_%s.png",
            directory,
            label,
            MsaaEdgeShadows::names[shadows.ordinal],
            MsaaSamples::names[msaa.ordinal],
        );
        image::write_png(
            path:   path,
            width:  MSAA_EDGE_IMAGE_WIDTH,
            height: MSAA_EDGE_IMAGE_HEIGHT,
            pixels: pixels,
        )!!;
    }
}

fn void test_msaa_edge_modes_match_the_per_sample_image() @test {
    MsaaEdgeShadows[4] kinds = {
        MsaaEdgeShadows.NONE,
        MsaaEdgeShadows.ATLAS,
        MsaaEdgeShadows.TRACED_SOFTWARE,
        MsaaEdgeShadows.TRACED_QUERIES,
    };
    MsaaSamples[3] counts = { MsaaSamples.TWO, MsaaSamples.FOUR, MsaaSamples.EIGHT };
    char[] per_sample = alloc::new_array(mem, char, MSAA_EDGE_IMAGE_BYTES);
    char[] forced = alloc::new_array(mem, char, MSAA_EDGE_IMAGE_BYTES);
    char[] classified = alloc::new_array(mem, char, MSAA_EDGE_IMAGE_BYTES);
    char[] tolerant = alloc::new_array(mem, char, MSAA_EDGE_IMAGE_BYTES);
    defer {
        alloc::free(mem, per_sample.ptr);
        alloc::free(mem, forced.ptr);
        alloc::free(mem, classified.ptr);
        alloc::free(mem, tolerant.ptr);
        env::clear_var(MSAA_EDGE_MODE_VARIABLE);
    }

    foreach (msaa : counts) {
        foreach (shadows : kinds) {
            if (catch excuse = render_msaa_edge_image(
                mode:     "0",
                shadows:  shadows,
                msaa:     msaa,
                expected: MsaaEdgeMode.PER_SAMPLE,
                pixels:   per_sample,
            )) {
                assert(excuse == c3d::UNSUPPORTED);
                io::printfn("Edge modes %s: skipped, the device lacks it", MsaaSamples::names[msaa.ordinal]);
                break;
            }

            render_msaa_edge_image(
                mode:     "2",
                shadows:  shadows,
                msaa:     msaa,
                expected: MsaaEdgeMode.ALL_EDGES,
                pixels:   forced,
            )!!;
            render_msaa_edge_image(
                mode:     "1",
                shadows:  shadows,
                msaa:     msaa,
                expected: MsaaEdgeMode.CLASSIFIED,
                pixels:   classified,
            )!!;
            render_msaa_edge_image(
                mode:     "3",
                shadows:  shadows,
                msaa:     msaa,
                expected: MsaaEdgeMode.TOLERANT,
                pixels:   tolerant,
            )!!;
            dump_msaa_edge_image("per_sample", shadows, msaa, per_sample);
            dump_msaa_edge_image("forced", shadows, msaa, forced);
            dump_msaa_edge_image("classified", shadows, msaa, classified);
            dump_msaa_edge_image("tolerant", shadows, msaa, tolerant);

            MsaaEdgeError forced_error = compare_msaa_edge_images(forced, per_sample);
            MsaaEdgeError classified_error = compare_msaa_edge_images(classified, per_sample);
            MsaaEdgeError tolerant_error = compare_msaa_edge_images(tolerant, per_sample);
            io::printfn(
                "Edge modes %s %s: forced max %d mean %.6f, classified max %d mean %.6f, tolerant max %d mean %.6f",
                MsaaSamples::names[msaa.ordinal],
                MsaaEdgeShadows::names[shadows.ordinal],
                forced_error.maximum,
                forced_error.mean,
                classified_error.maximum,
                classified_error.mean,
                tolerant_error.maximum,
                tolerant_error.mean,
            );
            assert(forced_error.maximum == 0);
            assert(classified_error.mean < MSAA_EDGE_MEAN_LIMIT);
            assert(tolerant_error.mean < MSAA_EDGE_MEAN_LIMIT);
            if (shadows == MsaaEdgeShadows.NONE) assert(classified_error.maximum < MSAA_EDGE_MAXIMUM_LIMIT);
        }
    }
}
