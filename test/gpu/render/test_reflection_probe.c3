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
import c3d::shader;
import gpu;
import std::io;
import std::math;

const char[*] REFLECTION_TWINS_SOURCE @private = $embed("reflection_twins.comp.glsl");
const uint REFLECTION_TWIN_POINTS @private = 64; // mirrored as REFLECTION_TWIN_POINTS in reflection_twins.comp.glsl
const uint REFLECTION_TWIN_VALUES @private = 3;  // vec4 results per point
const float REFLECTION_TWIN_WEIGHT_TOLERANCE @private = 1e-5f;
const float REFLECTION_TWIN_DIRECTION_TOLERANCE @private = 1e-4f;
const float REFLECTION_TWIN_TURN_DEGREES @private = 30;
const Vec3 REFLECTION_ROOM_A_CENTER @private = { -2, 1, 0 };
const Vec3 REFLECTION_ROOM_B_CENTER @private = { 2, 1, 0 };
const Vec3 REFLECTION_ROOM_HALF_EXTENTS @private = { 2, 2, 2 }; // y from -1 to 3: the floor at y = 0 lies 1 inside
const Vec3 REFLECTION_ROOM_A_COLOR @private = { 1, 0, 0 };
const Vec3 REFLECTION_ROOM_B_COLOR @private = { 0, 1, 0 };
const Vec3 REFLECTION_GLOBAL_COLOR @private = { 0, 0, 1 };
const float REFLECTION_ROOM_BLEND @private = 0.5f;
const uint[<2>] REFLECTION_ROOM_TARGET @private = { 256, 128 }; // 20 texels per world unit at the spheres
const Vec3 REFLECTION_ROOM_CAMERA_POSITION @private = { 0, 1.5f, 12 }; // outside both boxes, looking along -z
const float REFLECTION_ROOM_CAMERA_FOV_DEGREES @private = 30;
const float REFLECTION_SPHERE_RADIUS @private = 0.25f;
const float REFLECTION_LOBE_MINIMUM @private = 0.02f;     // the lit channel of a probe-lit lobe
const float REFLECTION_FOREIGN_MAXIMUM @private = 1e-3f;  // a channel no selected source carries
const float REFLECTION_PARITY_TOLERANCE @private = 2e-3f; // relative, forward against deferred
const float REFLECTION_QUAD_TILT_DEGREES @private = 30;   // the quad's normal makes 60 degrees with the view
const float REFLECTION_TRANSMISSION_THICKNESS @private = 50; // the refracted exit point leaves the frustum
const uint[<2>] REFLECTION_FLOOR_TARGET @private = { 128, 16 }; // 64 texels per world unit across the wall
const float REFLECTION_FLOOR_SPAN @private = 2;           // world units across the floor row
const float REFLECTION_FLOOR_SUM_TOLERANCE @private = 2e-3f; // relative: two half-float steps of the working image
const float REFLECTION_FLOOR_SHARE_TOLERANCE @private = 0.01f;
const float REFLECTION_FLOOR_STEP_LIMIT @private = 0.1f;  // of the summed radiance, between adjacent texels
const float REFLECTION_FLOOR_FLAT_TOLERANCE @private = 2e-3f; // relative: prefilter noise between adjacent texels
const uint REFLECTION_PATH_FRAMES @private = 8;
const uint REFLECTION_PATH_SAMPLES @private = 4;
const uint[<2>] REFLECTION_SMALL_TARGET @private = { 32, 32 };
const uint REFLECTION_PROBE_UPDATE_FRAMES @private = 4;
const float REFLECTION_STRIP_WIDTH @private = 0.8f;
const float REFLECTION_STRIP_SPACING @private = 1;
const float[3] REFLECTION_STRIP_ROUGHNESS @private = { 0.1f, 0.45f, 0.6f }; // traced, the top fifth of 0.5, probe
const float REFLECTION_COMPOSITION_TOLERANCE @private = 0.02f;
const float REFLECTION_ENCLOSURE_SIZE @private = 20;

struct ReflectionRooms @private {
    Scene         scene;
    Node*         camera;
    Node*         probe_a;
    Node*         probe_b;
    EnvironmentId environment_a;
    EnvironmentId environment_b;
    GeometryId    sphere;
}

struct ReflectionShot @private {
    Scene*         scene;
    Node*          camera;
    RenderTargetId target;
    ViewId         view;
    uint[<2>]      size;
}

struct ReflectionTwinRoot @private {
    gpu::GpuAddress frame_address;
    gpu::GpuAddress output_address;
}
$assert ReflectionTwinRoot::size == 16;

fn Node*? reflection_add_probe(
    Scene* scene,
    Vec3 center,
    EnvironmentId environment,
    float blend_distance,
) @private {
    Node* node = scene.add_node(name: "reflection_probe")!;
    node.local.position = center;
    ReflectionProbe probe = light::reflection_probe(REFLECTION_ROOM_HALF_EXTENTS, environment);
    probe.blend_distance = blend_distance;
    scene.add(node, probe);
    return node;
}

fn EnvironmentId? reflection_solid(Fixture* fixture, Vec3 color) @private {
    return fixture.assets.add_environment(light::solid_environment(color, SMALL_PROCESSING));
}

fn ReflectionRooms? reflection_rooms(Fixture* fixture, float blend_distance, bool global = true) @private {
    ReflectionRooms rooms;
    rooms.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&rooms.scene);
    rooms.scene.ambient_intensity = 0;
    rooms.scene.background.color = { 0, 0, 0, 1 };
    if (global) rooms.scene.environment = reflection_solid(fixture, REFLECTION_GLOBAL_COLOR)!;
    rooms.environment_a = reflection_solid(fixture, REFLECTION_ROOM_A_COLOR)!;
    rooms.environment_b = reflection_solid(fixture, REFLECTION_ROOM_B_COLOR)!;
    rooms.probe_a = reflection_add_probe(
        scene:          &rooms.scene,
        center:         REFLECTION_ROOM_A_CENTER,
        environment:    rooms.environment_a,
        blend_distance: blend_distance,
    )!;
    rooms.probe_b = reflection_add_probe(
        scene:          &rooms.scene,
        center:         REFLECTION_ROOM_B_CENTER,
        environment:    rooms.environment_b,
        blend_distance: blend_distance,
    )!;
    rooms.sphere = add_sphere(fixture, REFLECTION_SPHERE_RADIUS)!;
    rooms.camera = rooms.scene.add_camera(
        camera::perspective_deg(REFLECTION_ROOM_CAMERA_FOV_DEGREES, 0.1f),
        name: "camera",
    )!;
    rooms.camera.local.position = REFLECTION_ROOM_CAMERA_POSITION;
    rooms.scene.update_world();
    return rooms;
}

fn Node*? reflection_add_sphere(ReflectionRooms* rooms, MaterialId material, Vec3 position) @private {
    Node* node = rooms.scene.add_mesh(rooms.sphere, material, name: "sphere")!;
    node.local.position = position;
    return node;
}

fn MaterialId? reflection_metal(Fixture* fixture, float roughness) @private {
    return fixture.assets.add_material(material::standard({
        .base_color = { 1, 1, 1, 1 },
        .metallic   = 1,
        .roughness  = roughness,
    }));
}

fn ReflectionShot? reflection_shot(
    Fixture* fixture,
    Scene* scene,
    Node* camera_node,
    ShadingPath shading,
    uint[<2>] size = REFLECTION_ROOM_TARGET,
) @private {
    ReflectionShot shot = { .scene = scene, .camera = camera_node, .size = size };
    shot.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(size.x, size.y, PixelFormat.RGBA32_FLOAT),
    )!;
    defer catch (void)render::destroy_render_target(&fixture.renderer, shot.target);
    ViewDesc desc = render::texture_view_desc(shot.target);
    desc.shading = shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    shot.view = render::create_view(&fixture.renderer, desc)!;
    return shot;
}

fn ReflectionShot? reflection_room_shot(Fixture* fixture, ReflectionRooms* rooms, ShadingPath shading) @private {
    return reflection_shot(
        fixture:     fixture,
        scene:       &rooms.scene,
        camera_node: rooms.camera,
        shading:     shading,
    );
}

fn void reflection_destroy_shot(Fixture* fixture, ReflectionShot* shot) @private {
    render::destroy_view(&fixture.renderer, shot.view)!!;
    render::destroy_render_target(&fixture.renderer, shot.target)!!;
}

// One frame of the shot's view, read back; the caller frees the pixels.
fn Vec4[]? reflection_render(Fixture* fixture, ReflectionShot* shot) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(shot.scene, shot.camera, shot.view)!;
    renderer.finish_view(shot.view)!;
    renderer.end_frame()!;
    return read_float_target(fixture, shot.target);
}

fn Vec4 reflection_texel(ReflectionShot* shot, Vec4[] pixels, Vec3 point) @private {
    Vec2 viewport = (Vec2)shot.size;
    Camera* lens = shot.scene.get(shot.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*lens, shot.camera.world, viewport);
    Vec3 screen = camera::world_to_screen(&matrices, point, viewport);
    return pixels[(usz)screen.y * shot.size.x + (usz)screen.x];
}

fn void reflection_assert_lit_by(Vec4 pixel, Vec3 color) @private {
    for (usz channel = 0; channel < 3; channel++) {
        if (color[channel] > 0) {
            assert(pixel[channel] >= REFLECTION_LOBE_MINIMUM);
        } else {
            assert(pixel[channel] <= REFLECTION_FOREIGN_MAXIMUM);
        }
    }
}

// Shares of room A, room B and the global environment, in colour channel order.
fn Vec3 reflection_room_shares(ReflectionSelection selection) @private {
    Vec3 shares = { 0, 0, selection.global_weight };
    if (selection.count > 0) shares[selection.first] += selection.first_weight;
    if (selection.count > 1) shares[selection.second] += selection.second_weight;
    return shares;
}

fn ReflectionProbeGpu reflection_record_of(Scene* scene, Node* node) @private {
    return render::reflection_probe_record(
        probe:         scene.get(node, ReflectionProbe),
        world:         node.world,
        origin:        {},
        specular_cube: (gpu::TextureIndex)0,
        sheen_cube:    (gpu::TextureIndex)0,
    );
}

// Mirrored as reflection_twin_point in reflection_twins.comp.glsl.
fn Vec3 reflection_twin_point(uint index) @private {
    return {
        (float)(index % 4) * 1.1f - 1.4f,
        (float)((index / 4) % 4) * 0.6f - 0.9f,
        (float)(index / 16) * 0.9f - 1.3f,
    };
}

// Mirrored as reflection_twin_direction in reflection_twins.comp.glsl.
fn Vec3 reflection_twin_direction(uint index) @private {
    Vec3 lattice = { (float)(index % 4) - 1.5f, (float)((index / 4) % 4) - 1.5f, (float)(index / 16) - 1.5f };
    return lattice.normalize();
}

fn ReflectionProbeGpu reflection_twin_record(ReflectionProbe* probe, Vec3 center, Quat rotation) @private {
    Transform placement = maths::TRANSFORM_IDENTITY;
    placement.position = center;
    placement.rotation = rotation;
    return render::reflection_probe_record(
        probe:         probe,
        world:         placement.to_mat4(),
        origin:        {},
        specular_cube: (gpu::TextureIndex)0,
        sheen_cube:    (gpu::TextureIndex)0,
    );
}

fn void test_two_rooms_read_their_probes_per_lobe() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ReflectionRooms rooms = reflection_rooms(&fixture, REFLECTION_ROOM_BLEND)!!;
    defer scene::destroy_scene(&rooms.scene);

    MaterialId smooth = reflection_metal(&fixture, 0)!!;
    MaterialId rough = reflection_metal(&fixture, 0.8f)!!;
    PhysicalParams coat = material::PHYSICAL_PARAMS_DEFAULT;
    coat.standard.metallic = 0;
    coat.standard.base_color = { 0, 0, 0, 1 };
    coat.specular = 0;
    coat.clearcoat = 1;
    coat.clearcoat_roughness = 0.2f;
    PhysicalParams sheen = material::PHYSICAL_PARAMS_DEFAULT;
    sheen.standard.metallic = 0;
    sheen.standard.base_color = { 0, 0, 0, 1 };
    sheen.specular = 0;
    sheen.sheen_color = { 1, 1, 1 };
    sheen.sheen_roughness = 0.5f;
    PhysicalParams matte = material::PHYSICAL_PARAMS_DEFAULT;
    matte.standard.metallic = 0;
    matte.standard.base_color = { 0.5f, 0.5f, 0.5f, 1 };
    matte.standard.roughness = 1;
    matte.specular = 0;
    PhysicalParams glass = material::PHYSICAL_PARAMS_DEFAULT;
    glass.standard.metallic = 0;
    glass.standard.base_color = { 1, 1, 1, 1 };
    glass.standard.roughness = 0.1f;
    glass.specular = 0;
    glass.transmission = 1;
    glass.thickness = REFLECTION_TRANSMISSION_THICKNESS;

    Vec3[4] lobe_points = { { -3.2f, 1.5f, 0 }, { -2.6f, 1.5f, 0 }, { -2.0f, 1.5f, 0 }, { -1.4f, 1.5f, 0 } };
    MaterialId[4] lobe_materials = {
        smooth,
        rough,
        fixture.assets.add_material(material::physical(coat))!!,
        fixture.assets.add_material(material::physical(sheen))!!,
    };
    foreach (index, point : lobe_points) reflection_add_sphere(&rooms, lobe_materials[index], point)!!;
    Vec3 matte_point = { -0.9f, 1.5f, 0 };
    reflection_add_sphere(&rooms, fixture.assets.add_material(material::physical(matte))!!, matte_point)!!;
    Vec3 outside_point = { 0, 4, 0 };
    reflection_add_sphere(&rooms, smooth, outside_point)!!;
    GeometryId quad = add_plane(&fixture, 0.5f)!!;
    Vec3 quad_point = { -2.3f, 0.6f, 0.8f };
    MaterialId glass_material = fixture.assets.add_material(material::physical(glass))!!;
    Node* glass_node = rooms.scene.add_mesh(quad, glass_material, name: "glass")!!;
    glass_node.local.position = quad_point;
    float tilt = math::deg_to_rad(REFLECTION_QUAD_TILT_DEGREES);
    glass_node.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, tilt);
    rooms.scene.update_world();

    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    ReflectionShot[2] shots;
    foreach (index, path : paths) shots[index] = reflection_room_shot(&fixture, &rooms, path)!!;
    Vec4[2][2] metals;
    Vec4[2] matte_with;
    fixture.renderer.prepare_scene(&rooms.scene)!!;
    foreach (index, &shot : shots) {
        Vec4[] pixels = reflection_render(&fixture, shot)!!;
        defer free(pixels);
        foreach (point : lobe_points) {
            reflection_assert_lit_by(reflection_texel(shot, pixels, point), REFLECTION_ROOM_A_COLOR);
        }
        reflection_assert_lit_by(reflection_texel(shot, pixels, quad_point), REFLECTION_ROOM_A_COLOR);
        reflection_assert_lit_by(reflection_texel(shot, pixels, outside_point), REFLECTION_GLOBAL_COLOR);
        metals[index][0] = reflection_texel(shot, pixels, lobe_points[0]);
        metals[index][1] = reflection_texel(shot, pixels, lobe_points[1]);
        matte_with[index] = reflection_texel(shot, pixels, matte_point);
    }
    // Clearcoat, sheen and transmission shade forward in deferred views too: the G-buffer encodes none of them, so
    // their parity holds by construction and only the metals compare across paths.
    for (usz metal = 0; metal < 2; metal++) {
        for (usz channel = 0; channel < 3; channel++) {
            float forward = metals[0][metal][channel];
            float deferred = metals[1][metal][channel];
            assert(math::abs(forward - deferred) <= REFLECTION_PARITY_TOLERANCE * math::max(1.0f, math::abs(forward)));
        }
    }

    rooms.scene.remove_component(rooms.probe_a, ReflectionProbe);
    rooms.scene.remove_component(rooms.probe_b, ReflectionProbe);
    foreach (index, &shot : shots) {
        Vec4[] pixels = reflection_render(&fixture, shot)!!;
        defer free(pixels);
        assert(reflection_texel(shot, pixels, matte_point) == matte_with[index]);
    }
    foreach (&shot : shots) reflection_destroy_shot(&fixture, shot);
    check_validation(&fixture.renderer);
}

fn void test_glossy_floor_has_no_seam_across_the_shared_wall() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ReflectionRooms rooms = reflection_rooms(&fixture, REFLECTION_ROOM_BLEND)!!;
    defer scene::destroy_scene(&rooms.scene);
    GeometryId floor = add_plane(&fixture, 10)!!;
    rooms.scene.add_mesh(floor, reflection_metal(&fixture, 0.05f)!!, name: "floor")!!;
    float height = REFLECTION_FLOOR_SPAN * REFLECTION_FLOOR_TARGET.y / REFLECTION_FLOOR_TARGET.x;
    *rooms.scene.get(rooms.camera, Camera) = camera::orthographic(height, 0.1f, 10);
    rooms.camera.local.position = { 0, 5, 0 };
    rooms.camera.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    rooms.scene.update_world();
    ReflectionShot shot = reflection_shot(
        fixture:     &fixture,
        scene:       &rooms.scene,
        camera_node: rooms.camera,
        shading:     ShadingPath.FORWARD,
        size:        REFLECTION_FLOOR_TARGET,
    )!!;
    fixture.renderer.prepare_scene(&rooms.scene)!!;

    ReflectionProbeSetGpu set = { .count = 2 };
    set.probes[0] = reflection_record_of(&rooms.scene, rooms.probe_a);
    set.probes[1] = reflection_record_of(&rooms.scene, rooms.probe_b);
    uint width = REFLECTION_FLOOR_TARGET.x;
    usz middle_row = (usz)(REFLECTION_FLOOR_TARGET.y / 2) * width;
    Vec4[] faded = reflection_render(&fixture, &shot)!!;
    defer free(faded);
    Vec4[] row = faded[middle_row:width];
    float sum = row[0].x + row[0].y + row[0].z;
    for (uint column = 0; column < width; column++) {
        Vec4 texel = row[column];
        float texel_sum = texel.x + texel.y + texel.z;
        assert(math::abs(texel_sum - sum) <= REFLECTION_FLOOR_SUM_TOLERANCE * sum);
        float x = -REFLECTION_FLOOR_SPAN / 2 + ((float)column + 0.5f) * REFLECTION_FLOOR_SPAN / width;
        Vec3 shares = reflection_room_shares(render::reflection_probe_select(&set, { x, 0, 0 }));
        for (usz channel = 0; channel < 3; channel++) {
            assert(math::abs(texel[channel] / texel_sum - shares[channel]) <= REFLECTION_FLOOR_SHARE_TOLERANCE);
            if (column > 0) {
                assert(math::abs(texel[channel] - row[column - 1][channel]) <= REFLECTION_FLOOR_STEP_LIMIT * sum);
            }
        }
    }

    rooms.scene.get(rooms.probe_a, ReflectionProbe).blend_distance = 0;
    rooms.scene.get(rooms.probe_b, ReflectionProbe).blend_distance = 0;
    Vec4[] hard = reflection_render(&fixture, &shot)!!;
    defer free(hard);
    Vec4[] hard_row = hard[middle_row:width];
    uint switches;
    for (uint column = 0; column < width; column++) {
        assert(hard_row[column].z <= REFLECTION_FOREIGN_MAXIMUM);
        if (column == 0) continue;
        Vec4 step = hard_row[column] - hard_row[column - 1];
        bool flat = math::abs(step.x) <= REFLECTION_FLOOR_FLAT_TOLERANCE * sum
            && math::abs(step.y) <= REFLECTION_FLOOR_FLAT_TOLERANCE * sum;
        if (flat) continue;
        switches++;
        assert(math::abs(hard_row[column - 1].x - sum) <= REFLECTION_FLOOR_SUM_TOLERANCE * sum);
        assert(math::abs(hard_row[column].y - sum) <= REFLECTION_FLOOR_SUM_TOLERANCE * sum);
    }
    assert(switches == 1);
    reflection_destroy_shot(&fixture, &shot);
    check_validation(&fixture.renderer);
}

fn void test_traced_reflections_compose_through_the_fade_band() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        scene.ambient_intensity = 0;
        scene.background.color = { 0, 0, 0, 1 };
        Node* probe_node = scene.add_node(name: "reflection_probe")!!;
        probe_node.local.position = { 0, 2, 0 };
        EnvironmentId red = reflection_solid(&fixture, REFLECTION_ROOM_A_COLOR)!!;
        ReflectionProbe probe = light::reflection_probe({ 6, 4, 6 }, red);
        probe.blend_distance = 0;
        scene.add(probe_node, probe);

        GeometryId enclosure;
        GeometryId strip;
        @pool() {
            float size = REFLECTION_ENCLOSURE_SIZE;
            Geometry box = geometry::box(
                allocator: tmem,
                width:     size,
                height:    size,
                depth:     size,
            );
            enclosure = fixture.assets.add_geometry(&box)!!;
            Geometry plane = geometry::plane(tmem, REFLECTION_STRIP_WIDTH, REFLECTION_STRIP_WIDTH);
            strip = fixture.assets.add_geometry(&plane)!!;
        };
        MaterialCommon both_sides = material::MATERIAL_COMMON_DEFAULT;
        both_sides.double_sided = true;
        MaterialId green = fixture.assets.add_material(material::basic({ .color = { 0, 1, 0, 1 } }, both_sides))!!;
        scene.add_mesh(enclosure, green, name: "enclosure")!!;
        Vec3[3] strip_points;
        foreach (index, roughness : REFLECTION_STRIP_ROUGHNESS) {
            Node* node = scene.add_mesh(strip, reflection_metal(&fixture, roughness)!!, name: "strip")!!;
            strip_points[index] = { ((float)index - 1) * REFLECTION_STRIP_SPACING, 0, 0 };
            node.local.position = strip_points[index];
        }
        Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;
        camera_node.local.position = { 0, 1.2f, 2.5f };
        camera_node.local.rotation = maths::look_rotation(((Vec3){ 0, -1.2f, -2.5f }).normalize(), { 0, 1, 0 });
        scene.update_world();

        ReflectionShot shot = reflection_shot(
            fixture:     &fixture,
            scene:       &scene,
            camera_node: camera_node,
            shading:     ShadingPath.DEFERRED,
        )!!;
        Vec4[3][3] readings;
        bool[3] traced = { true, false, true };
        for (usz run = 0; run < 3; run++) {
            if (run == 2) scene.remove_component(probe_node, ReflectionProbe);
            set_reflections(&fixture, shot.view, traced[run])!!;
            Vec4[] pixels = reflection_render(&fixture, &shot)!!;
            defer free(pixels);
            foreach (index, point : strip_points) readings[run][index] = reflection_texel(&shot, pixels, point);
        }
        Vec4[3] composed = readings[0];
        Vec4[3] probe_only = readings[1];
        Vec4[3] traced_only = readings[2];
        float tolerance = REFLECTION_COMPOSITION_TOLERANCE;
        assert(composed[0].x <= tolerance * probe_only[0].x);
        assert(math::abs(composed[0].y - traced_only[0].y) <= tolerance * traced_only[0].y);
        assert(math::abs(composed[2].x - probe_only[2].x) <= tolerance * probe_only[2].x);
        assert(composed[2].y <= tolerance * probe_only[2].x);
        assert(math::abs(composed[1].x - 0.5f * probe_only[1].x) <= tolerance * probe_only[1].x);
        assert(math::abs(composed[1].y - traced_only[1].y) <= tolerance * traced_only[1].y);
        reflection_destroy_shot(&fixture, &shot);
        check_validation(&fixture.renderer);
    }
}

fn void test_path_tracer_never_reads_a_reflection_probe() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    PathScene room = create_lit_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);
    Node* left = reflection_add_probe(
        scene:          &room.scene,
        center:         { -2, 1, -2 },
        environment:    reflection_solid(&fixture, REFLECTION_ROOM_A_COLOR)!!,
        blend_distance: REFLECTION_ROOM_BLEND,
    )!!;
    Node* right = reflection_add_probe(
        scene:          &room.scene,
        center:         { 2, 1, -2 },
        environment:    reflection_solid(&fixture, REFLECTION_ROOM_B_COLOR)!!,
        blend_distance: REFLECTION_ROOM_BLEND,
    )!!;
    room.scene.update_world();

    PathTraceDesc settings = { .max_bounces = 6, .samples_per_frame = REFLECTION_PATH_SAMPLES };
    RenderTargetId[2] targets;
    ViewId[2] views;
    foreach (index, &target : targets) {
        *target = render::create_render_target(
            renderer: &fixture.renderer,
            desc:     render::render_target_desc(
                REFLECTION_SMALL_TARGET.x,
                REFLECTION_SMALL_TARGET.y,
                PixelFormat.RGBA32_FLOAT,
            ),
        )!!;
        views[index] = create_path_view(&fixture, *target, settings)!!;
    }
    fixture.renderer.prepare_scene(&room.scene)!!;
    PathRun with_probes = { .fixture = &fixture, .path_scene = &room, .view = views[0] };
    render_frames(&with_probes, REFLECTION_PATH_FRAMES)!!;
    room.scene.remove_component(left, ReflectionProbe);
    room.scene.remove_component(right, ReflectionProbe);
    PathRun without_probes = { .fixture = &fixture, .path_scene = &room, .view = views[1] };
    render_frames(&without_probes, REFLECTION_PATH_FRAMES)!!;

    Vec4[] first = read_float_target(&fixture, targets[0])!!;
    defer free(first);
    Vec4[] second = read_float_target(&fixture, targets[1])!!;
    defer free(second);
    foreach (index, value : first) assert(value == second[index]);
    foreach (view : views) {
        uint samples = fixture.renderer.view_stats(view)!!.accumulated_samples;
        assert(samples == REFLECTION_PATH_FRAMES * REFLECTION_PATH_SAMPLES);
    }
    check_validation(&fixture.renderer);
}

// Both atlases of a scene-filled volume after a few updates, with or without a reflection probe over the room.
fn Vec4f[][2]? reflection_probe_update_atlases(bool with_probe) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!;
    defer destroy_fixture(&fixture);
    ProbeRoom room = create_probe_room(&fixture)!;
    defer scene::destroy_scene(&room.scene);
    EnvironmentId red = reflection_solid(&fixture, REFLECTION_ROOM_A_COLOR)!;
    reflection_add_probe(
        scene:          &room.scene,
        center:         ROOM_CENTER,
        environment:    with_probe ? red : (EnvironmentId){},
        blend_distance: REFLECTION_ROOM_BLEND,
    )!;
    room.scene.update_world();
    ReflectionShot shot = reflection_shot(
        fixture:     &fixture,
        scene:       &room.scene,
        camera_node: room.camera,
        shading:     ShadingPath.FORWARD,
        size:        REFLECTION_SMALL_TARGET,
    )!;
    fixture.renderer.prepare_scene(&room.scene)!;
    render_room_frames(&fixture, &room, shot.view, REFLECTION_PROBE_UPDATE_FRAMES)!;
    ProbeVolumeRes* mirror = mirror_of(&fixture, &room.scene, room.volume);
    Vec4f[][2] atlases = { read_atlas(&fixture, &mirror.irradiance)!, read_atlas(&fixture, &mirror.visibility)! };
    reflection_destroy_shot(&fixture, &shot);
    check_validation(&fixture.renderer);
    return atlases;
}

fn void test_probe_update_never_reads_a_reflection_probe() @test {
    @pool() {
        Vec4f[][2] with_probe = reflection_probe_update_atlases(true)!!;
        Vec4f[][2] without_probe = reflection_probe_update_atlases(false)!!;
        for (usz atlas = 0; atlas < 2; atlas++) {
            assert(with_probe[atlas].len == without_probe[atlas].len);
            foreach (index, texel : with_probe[atlas]) assert(texel == without_probe[atlas][index]);
        }
    };
}

fn void test_probe_lights_specular_without_a_global_environment() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ReflectionRooms rooms = reflection_rooms(&fixture, REFLECTION_ROOM_BLEND, global: false)!!;
    defer scene::destroy_scene(&rooms.scene);
    rooms.scene.ambient_intensity = 0.2f;
    rooms.scene.remove_component(rooms.probe_b, ReflectionProbe);
    MaterialId smooth = reflection_metal(&fixture, 0)!!;
    MaterialId dielectric = fixture.assets.add_material(material::standard({
        .base_color = { 0.5f, 0.5f, 0.5f, 1 },
        .roughness  = 1,
    }))!!;
    Vec3 inside = { -2, 1.5f, 0 };
    Vec3[2] outside = { { 1.6f, 1.5f, 0 }, { 2.4f, 1.5f, 0 } };
    reflection_add_sphere(&rooms, smooth, inside)!!;
    reflection_add_sphere(&rooms, smooth, outside[0])!!;
    reflection_add_sphere(&rooms, dielectric, outside[1])!!;
    rooms.scene.update_world();

    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (path : paths) {
        ReflectionShot shot = reflection_room_shot(&fixture, &rooms, path)!!;
        Vec4[] with_probe = reflection_render(&fixture, &shot)!!;
        defer free(with_probe);
        reflection_assert_lit_by(reflection_texel(&shot, with_probe, inside), REFLECTION_ROOM_A_COLOR);

        rooms.scene.remove_component(rooms.probe_a, ReflectionProbe);
        Vec4[] without_probe = reflection_render(&fixture, &shot)!!;
        defer free(without_probe);
        foreach (point : outside) {
            assert(reflection_texel(&shot, with_probe, point) == reflection_texel(&shot, without_probe, point));
        }
        rooms.scene.add(rooms.probe_a, light::reflection_probe(REFLECTION_ROOM_HALF_EXTENTS, rooms.environment_a));
        reflection_destroy_shot(&fixture, &shot);
    }
    check_validation(&fixture.renderer);
}

fn void test_removing_probe_assets_falls_back_without_validation_errors() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ReflectionRooms rooms = reflection_rooms(&fixture, 0)!!;
    defer scene::destroy_scene(&rooms.scene);
    MaterialId smooth = reflection_metal(&fixture, 0)!!;
    Vec3 point_a = { -2, 1.5f, 0 };
    Vec3 point_b = { 2, 1.5f, 0 };
    reflection_add_sphere(&rooms, smooth, point_a)!!;
    reflection_add_sphere(&rooms, smooth, point_b)!!;
    rooms.scene.update_world();
    ReflectionShot shot = reflection_room_shot(&fixture, &rooms, ShadingPath.FORWARD)!!;

    Vec4[] first = reflection_render(&fixture, &shot)!!;
    defer free(first);
    reflection_assert_lit_by(reflection_texel(&shot, first, point_a), REFLECTION_ROOM_A_COLOR);

    fixture.assets.remove_environment(rooms.environment_a);
    for (uint frame = 0; frame <= render::FRAMES_IN_FLIGHT; frame++) {
        Vec4[] removed = reflection_render(&fixture, &shot)!!;
        defer free(removed);
        assert(fixture.renderer.stats.dangling_refs >= 1);
        reflection_assert_lit_by(reflection_texel(&shot, removed, point_a), REFLECTION_GLOBAL_COLOR);
    }

    rooms.scene.remove_component(rooms.probe_a, ReflectionProbe);
    Vec4[] without_component = reflection_render(&fixture, &shot)!!;
    defer free(without_component);
    assert(fixture.renderer.stats.dangling_refs == 0);
    rooms.scene.remove(rooms.probe_b);
    Vec4[] last = reflection_render(&fixture, &shot)!!;
    defer free(last);
    reflection_assert_lit_by(reflection_texel(&shot, last, point_a), REFLECTION_GLOBAL_COLOR);
    reflection_assert_lit_by(reflection_texel(&shot, last, point_b), REFLECTION_GLOBAL_COLOR);
    reflection_destroy_shot(&fixture, &shot);
    check_validation(&fixture.renderer);
}

fn void test_reflection_glsl_matches_the_c3_twins() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    ReflectionProbe upright = light::reflection_probe({ 1.5f, 1, 1.2f }, {});
    upright.blend_distance = 0.4f;
    upright.capture_offset = { 0.3f, -0.2f, 0.1f };
    ReflectionProbe turned = light::reflection_probe({ 1, 0.8f, 1 }, {});
    turned.blend_distance = 0.3f;
    ReflectionProbe infinite = light::reflection_probe({ 1.8f, 0.8f, 1.4f }, {});
    infinite.blend_distance = 1;
    infinite.projection = ReflectionProjection.INFINITE;
    Quat turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(REFLECTION_TWIN_TURN_DEGREES));
    ReflectionProbeSetGpu set = { .count = 3 };
    set.probes[0] = reflection_twin_record(&upright, { 0, 0, 0 }, quaternion::IDENTITY);
    set.probes[1] = reflection_twin_record(&turned, { 0.8f, 0, 0.3f }, turn);
    set.probes[2] = reflection_twin_record(&infinite, { 0, 0, 0 }, quaternion::IDENTITY);

    usz bytes = (usz)REFLECTION_TWIN_POINTS * REFLECTION_TWIN_VALUES * Vec4f::size;
    ComputeShaderId twins = add_compute_shader(&fixture, (String)REFLECTION_TWINS_SOURCE[..])!!;
    BufferId output = renderer.create_buffer({ .size = bytes, .debug_name = "reflection_twins_output" })!!;
    gpu::AllocationDesc readback_desc = {
        .size         = bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "reflection_twins_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
    defer {
        render::wait_frames(renderer)!!;
        gpu::GpuAllocation allocation = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }

    renderer.begin_frame()!!;
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    usz set_bytes = ReflectionProbeSetGpu::size;
    gpu::MappedGpuSpan set_span = slot.upload.take(&renderer.device, set_bytes, render::STREAM_ALIGNMENT)!!;
    *(ReflectionProbeSetGpu*)set_span.bytes.ptr = set;
    gpu::MappedGpuSpan frame_span = slot.upload.take(&renderer.device, FrameRoot::size, render::STREAM_ALIGNMENT)!!;
    *(FrameRoot*)frame_span.bytes.ptr = { .reflection_probes = set_span.address };
    ReflectionTwinRoot root = {
        .frame_address  = frame_span.address,
        .output_address = renderer.buffer_address(output),
    };
    BufferId[1] writes = { output };
    renderer.dispatch({
        .shader = twins,
        .root   = ((char*)&root)[:ReflectionTwinRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
    })!!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(output).allocation)!!,
        .dst = readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!!;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;
    Vec4f[] results = ((Vec4f*)readback.bytes.ptr)[:(usz)REFLECTION_TWIN_POINTS * REFLECTION_TWIN_VALUES];

    uint weighted;
    for (uint index = 0; index < REFLECTION_TWIN_POINTS; index++) {
        ReflectionSelection expected = render::reflection_probe_select(&set, reflection_twin_point(index));
        Vec4f found_ids = results[index * REFLECTION_TWIN_VALUES];
        Vec4f found_shares = results[index * REFLECTION_TWIN_VALUES + 1];
        assert(found_ids.x == (float)expected.count && found_ids.y == (float)expected.first);
        assert(found_ids.z == (float)expected.second);
        assert(math::abs(found_shares.x - expected.first_weight) <= REFLECTION_TWIN_WEIGHT_TOLERANCE);
        assert(math::abs(found_shares.y - expected.second_weight) <= REFLECTION_TWIN_WEIGHT_TOLERANCE);
        assert(math::abs(found_shares.z - expected.global_weight) <= REFLECTION_TWIN_WEIGHT_TOLERANCE);
        if (expected.count == 0) continue;
        weighted++;
        Vec3 aimed = render::reflection_box_direction(
            &set.probes[expected.first],
            expected.first_position,
            reflection_twin_direction(index),
        ).normalize();
        Vec3 found = results[index * REFLECTION_TWIN_VALUES + 2].xyz;
        assert(found.normalize().distance(aimed) <= REFLECTION_TWIN_DIRECTION_TOLERANCE);
    }
    assert(weighted > 0 && weighted < REFLECTION_TWIN_POINTS);
    check_validation(renderer);
}
