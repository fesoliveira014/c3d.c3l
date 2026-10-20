module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::math;

const uint MSAA_EDGE_IMAGE_WIDTH @private = 256;
const uint MSAA_EDGE_IMAGE_HEIGHT @private = 192;
const usz MSAA_EDGE_IMAGE_BYTES @private = (usz)MSAA_EDGE_IMAGE_WIDTH * MSAA_EDGE_IMAGE_HEIGHT * 4;
const uint MSAA_EDGE_PROBE_COUNT @private = 16;
const Vec3 MSAA_EDGE_CAMERA_POSITION @private = { 0.6f, 1.7f, 5.5f };
const Vec3 MSAA_EDGE_CAMERA_TARGET @private = { 0, 0.3f, 0 };
const Vec3 MSAA_EDGE_SUN_DIRECTION @private = { -0.5f, -1, -0.4f };
const float MSAA_EDGE_SUN_INTENSITY @private = 3;
const float MSAA_EDGE_SUN_DISTANCE @private = 20;
const uint MSAA_EDGE_SHADOW_RESOLUTION @private = 1024;
const float MSAA_EDGE_TOP_HEIGHT @private = 0.5f; // the pair's top faces
const float MSAA_EDGE_PILLAR_X @private = 2.4f; // outside the canopy's shadow
const int MSAA_EDGE_PROBE_REACH @private = 4; // pixels from the edge to the pixel read as one side
const int MSAA_EDGE_SIDE_MINIMUM @private = 40; // the two sides of an edge differ by at least this in one channel
const int MSAA_EDGE_BLEND_MARGIN @private = 12; // a blend lies this far inside both sides
const int MSAA_EDGE_FLAT_SPREAD @private = 4; // a flat neighborhood varies by at most this across its 3x3 pixels
const uint MSAA_EDGE_FLAT_LIMIT @private = 4; // exclusive: the frame-comparison tolerance, in 8-bit steps
const double MSAA_EDGE_MEAN_LIMIT @private = 1.0; // one 8-bit step over the image
const uint MSAA_EDGE_BLEND_SHARE @private = 4; // a partly covered pixel needs a sample on each side, so a quarter of the probes

enum MsaaEdgeShadows @private {
    ATLAS,
    TRACED_SOFTWARE,
    TRACED_QUERIES,
}

struct MsaaEdgeProbes @private {
    Vec2[MSAA_EDGE_PROBE_COUNT] seam;
    Vec2[MSAA_EDGE_PROBE_COUNT] silhouette;
}

struct MsaaEdgeFlat @private {
    uint count;
    uint maximum;
}

fn Node*? add_msaa_edge_box(Scene* scene, GeometryId box, MaterialId material, Vec3 position, Vec3 scale) @private {
    Node* node = scene.add_mesh(box, material)!;
    node.local.position = position;
    node.local.scale = scale;
    return node;
}

fn Node*? create_msaa_edge_scene(Fixture* fixture, Scene* scene, MsaaEdgeProbes* probes) @private {
    scene.ambient_color = { 0.5f, 0.55f, 0.6f };
    scene.ambient_intensity = 0.3f;

    GeometryId sphere;
    @pool() {
        Geometry geometry = geometry::sphere(tmem, 0.55f);
        sphere = fixture.assets.add_geometry(&geometry)!;
    };
    MaterialId gray = fixture.assets.add_material(
        material::standard({ .base_color = { 0.55f, 0.55f, 0.58f, 1 }, .roughness = 0.8f }),
    )!;
    MaterialId red = fixture.assets.add_material(
        material::standard({ .base_color = { 0.85f, 0.25f, 0.2f, 1 }, .roughness = 0.45f }),
    )!;
    MaterialId blue = fixture.assets.add_material(
        material::standard({ .base_color = { 0.2f, 0.4f, 0.85f, 1 }, .metallic = 0.6f, .roughness = 0.35f }),
    )!;

    add_msaa_edge_box(scene, fixture.box, gray, { 0, -0.55f, 0 }, { 12, 0.1f, 12 })!;
    add_msaa_edge_box(scene, fixture.box, gray, { 0, 1.3f, 0 }, { 3.2f, 0.08f, 2 })!;
    add_msaa_edge_box(scene, fixture.box, red, { MSAA_EDGE_PILLAR_X, 0, 0 }, { 1, 1, 1 })!;
    Node* receiver = add_msaa_edge_box(scene, fixture.box, red, { -0.5f, 0, 0 }, { 1, 1, 1 })!;
    Node* bare = add_msaa_edge_box(scene, fixture.box, red, { 0.5f, 0, 0 }, { 1, 1, 1 })!;
    scene.get(receiver, Mesh).receive_shadow = true;
    scene.get(bare, Mesh).receive_shadow = false;
    Node* ball = scene.add_mesh(sphere, blue)!;
    ball.local.position = { -2.4f, 0, -1 };

    Light sun = light::directional({ 1, 0.95f, 0.85f }, MSAA_EDGE_SUN_INTENSITY);
    sun.shadow.cascades = 1;
    sun.shadow.max_distance = MSAA_EDGE_SUN_DISTANCE;
    Node* sun_node = scene.add_light(sun)!;
    sun_node.local.rotation = maths::look_rotation(MSAA_EDGE_SUN_DIRECTION.normalize(), { 0, 1, 0 });

    Node* camera = scene.add_camera(camera::perspective_deg(55, 0.1f))!;
    camera.local.position = MSAA_EDGE_CAMERA_POSITION;
    camera.local.rotation = maths::look_rotation(MSAA_EDGE_CAMERA_TARGET - MSAA_EDGE_CAMERA_POSITION, { 0, 1, 0 });
    scene.update_world();

    CameraMatrices matrices = camera::derive_matrices(
        *scene.get(camera, Camera),
        camera.world,
        { MSAA_EDGE_IMAGE_WIDTH, MSAA_EDGE_IMAGE_HEIGHT },
    );
    for (uint index = 0; index < MSAA_EDGE_PROBE_COUNT; index++) {
        float along = (float)index / (MSAA_EDGE_PROBE_COUNT - 1);
        Vec3 seam = { 0, MSAA_EDGE_TOP_HEIGHT, -0.4f + 0.8f * along };
        Vec3 silhouette = { MSAA_EDGE_PILLAR_X + 0.5f, -0.4f + 0.8f * along, 0.5f };
        probes.seam[index] = projected_uv(&matrices, seam) * (Vec2){ MSAA_EDGE_IMAGE_WIDTH, MSAA_EDGE_IMAGE_HEIGHT };
        probes.silhouette[index] = projected_uv(&matrices, silhouette)
            * (Vec2){ MSAA_EDGE_IMAGE_WIDTH, MSAA_EDGE_IMAGE_HEIGHT };
    }

    return camera;
}

fn void? render_msaa_edge_pair(
    MsaaEdgeShadows shadows,
    MsaaSamples msaa,
    MsaaEdgeProbes* probes,
    char[] single,
    char[] multisample,
) @private {
    bool traced = shadows != MsaaEdgeShadows.ATLAS;
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

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* camera = create_msaa_edge_scene(&fixture, &scene, probes)!;
    if (traced) {
        scene.@each(Light; Entity entity, Light* light) {
            light.shadow.ray_traced = true;
        };
    }

    RenderTargetId[2] targets;
    ViewId[2] views;
    foreach (index, &target : targets) {
        *target = render::create_render_target(
            renderer,
            render::render_target_desc(MSAA_EDGE_IMAGE_WIDTH, MSAA_EDGE_IMAGE_HEIGHT, PixelFormat.RGBA8_UNORM),
        )!;
        views[index] = render::create_view(renderer, render::texture_view_desc(*target, OutputMode.DISPLAY_LDR))!;
        ViewDesc desc = renderer.views.get(views[index]).desc;
        desc.shading = ShadingPath.DEFERRED;
        desc.post.anti_aliasing = AntiAliasing.NONE;
        desc.msaa = index == 1 ? msaa : MsaaSamples.ONE;
        desc.ray_tracing.shadows = traced;
        render::configure_view(renderer, views[index], desc)!;
    }

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (view : views) {
        renderer.render_view(&scene, camera, view)!;
        renderer.finish_view(view)!;
    }
    renderer.end_frame()!;
    renderer.read_render_target(targets[0], single)!;
    renderer.read_render_target(targets[1], multisample)!;
}

fn int msaa_edge_channel(char[] pixels, int x, int y, uint channel) @private {
    return (int)pixels[((usz)y * MSAA_EDGE_IMAGE_WIDTH + (usz)x) * 4 + channel];
}

<*
 Whether the pixels beside a point on an edge include one strictly between the edge's two sides.
*>
fn bool msaa_edge_is_blended(char[] pixels, Vec2 point) @private {
    int column = (int)point.x;
    int row = (int)point.y;
    uint channel;
    int widest;
    for (uint candidate = 0; candidate < 3; candidate++) {
        int difference = math::abs(
            msaa_edge_channel(pixels, column - MSAA_EDGE_PROBE_REACH, row, candidate)
            - msaa_edge_channel(pixels, column + MSAA_EDGE_PROBE_REACH, row, candidate),
        );
        if (difference > widest) {
            widest = difference;
            channel = candidate;
        }
    }

    assert(widest >= MSAA_EDGE_SIDE_MINIMUM);
    int first = msaa_edge_channel(pixels, column - MSAA_EDGE_PROBE_REACH, row, channel);
    int second = msaa_edge_channel(pixels, column + MSAA_EDGE_PROBE_REACH, row, channel);
    int low = math::min(first, second) + MSAA_EDGE_BLEND_MARGIN;
    int high = math::max(first, second) - MSAA_EDGE_BLEND_MARGIN;
    for (int x = column - 1; x <= column + 1; x++) {
        int value = msaa_edge_channel(pixels, x, row, channel);
        if (value > low && value < high) return true;
    }

    return false;
}

fn uint msaa_edge_blended_count(char[] pixels, Vec2[] points) @private {
    uint blended;
    foreach (point : points) {
        if (msaa_edge_is_blended(pixels, point)) blended++;
    }

    return blended;
}

<*
 Compare the pixels whose 3x3 neighborhood is flat in the single-sample image.
*>
fn MsaaEdgeFlat msaa_edge_compare_flat(char[] single, char[] multisample) @private {
    MsaaEdgeFlat result;
    for (int y = 1; y < (int)MSAA_EDGE_IMAGE_HEIGHT - 1; y++) {
        for (int x = 1; x < (int)MSAA_EDGE_IMAGE_WIDTH - 1; x++) {
            int spread;
            for (uint channel = 0; channel < 3; channel++) {
                int low = 255;
                int high;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int value = msaa_edge_channel(single, x + dx, y + dy, channel);
                        low = math::min(low, value);
                        high = math::max(high, value);
                    }
                }

                spread = math::max(spread, high - low);
            }

            if (spread > MSAA_EDGE_FLAT_SPREAD) continue;

            result.count++;
            for (uint channel = 0; channel < 3; channel++) {
                uint difference = (uint)math::abs(
                    msaa_edge_channel(single, x, y, channel) - msaa_edge_channel(multisample, x, y, channel),
                );
                result.maximum = math::max(result.maximum, difference);
            }
        }
    }

    return result;
}

fn double msaa_edge_mean_difference(char[] single, char[] multisample) @private {
    ulong total;
    foreach (index, value : single) total += (ulong)math::abs((int)value - (int)multisample[index]);

    return (double)total / single.len;
}

fn void test_deferred_multisample_lights_surfaces_once_and_blends_edges() @test {
    MsaaEdgeShadows[3] kinds = {
        MsaaEdgeShadows.ATLAS,
        MsaaEdgeShadows.TRACED_SOFTWARE,
        MsaaEdgeShadows.TRACED_QUERIES,
    };
    MsaaSamples[3] counts = { MsaaSamples.TWO, MsaaSamples.FOUR, MsaaSamples.EIGHT };
    char[] single = alloc::new_array(mem, char, MSAA_EDGE_IMAGE_BYTES);
    char[] multisample = alloc::new_array(mem, char, MSAA_EDGE_IMAGE_BYTES);
    defer {
        alloc::free(mem, single.ptr);
        alloc::free(mem, multisample.ptr);
    }

    foreach (msaa : counts) {
        foreach (shadows : kinds) {
            MsaaEdgeProbes probes;
            if (catch excuse = render_msaa_edge_pair(shadows, msaa, &probes, single, multisample)) {
                assert(excuse == c3d::UNSUPPORTED);
                break;
            }

            MsaaEdgeFlat flat = msaa_edge_compare_flat(single, multisample);
            assert(flat.count * 2 > MSAA_EDGE_IMAGE_WIDTH * MSAA_EDGE_IMAGE_HEIGHT);
            assert(flat.maximum < MSAA_EDGE_FLAT_LIMIT);
            assert(msaa_edge_mean_difference(single, multisample) < MSAA_EDGE_MEAN_LIMIT);

            // A single-sample render shades a pixel from one primitive, so it never blends across an edge.
            assert(msaa_edge_blended_count(single, probes.seam[..]) == 0);
            assert(msaa_edge_blended_count(single, probes.silhouette[..]) == 0);
            assert(msaa_edge_blended_count(multisample, probes.seam[..]) * MSAA_EDGE_BLEND_SHARE >= MSAA_EDGE_PROBE_COUNT);
            assert(
                msaa_edge_blended_count(multisample, probes.silhouette[..]) * MSAA_EDGE_BLEND_SHARE
                    >= MSAA_EDGE_PROBE_COUNT
            );
        }
    }
}
