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

const float CAPTURE_ROOM_HALF_SIZE @private = 2;
const float CAPTURE_ROOM_TILE @private = 2;               // four tiles per wall
const float CAPTURE_ROOM_DIM @private = 0.25f;           // the three tiles outside a wall's (+, +) quadrant
const Vec3 CAPTURE_ROOM_PROBE_HALF_EXTENTS @private = { 1.9f, 1.9f, 1.9f };
const float CAPTURE_ROOM_SPHERE_RADIUS @private = 0.5f;
const float CAPTURE_ROOM_FLOOR_HEIGHT @private = -1.2f;  // inside the probe box past its fade: the probe would light it
const uint CAPTURE_ROOM_SPHERE_LAYER @private = 2;       // captures render layer 1 only
// A black screen before the +X wall that a layer-1 capture must not see.
const uint CAPTURE_ROOM_SCREEN_LAYER @private = 4;
const float CAPTURE_ROOM_SCREEN_DISTANCE @private = 1;
const uint CAPTURE_ROOM_SIZE @private = 32;              // the default size exceeds 30 s on software devices
const uint[<2>][4] CAPTURE_ROOM_TEXELS @private = { { 8, 8 }, { 23, 8 }, { 8, 23 }, { 23, 23 } }; // quadrant centres
const float CAPTURE_ROOM_FACE_TOLERANCE @private = 0.02f;
const float CAPTURE_ROOM_HUE_TOLERANCE @private = 0.1f;
const float CAPTURE_ROOM_REPEAT_TOLERANCE @private = 1e-3f;
const float CAPTURE_ROOM_CAMERA_DISTANCE @private = 1.5f;
const float CAPTURE_ROOM_CAMERA_FOV_DEGREES @private = 20;
const uint[<2>] CAPTURE_ROOM_TARGET @private = { 32, 32 };
const float CAPTURE_ROOM_WHITE_RATIO @private = 1.1f;    // largest over smallest channel of a white reflection
const Vec3[6] CAPTURE_ROOM_COLORS @private = {
    { 1, 0, 0 },
    { 0, 1, 1 },
    { 0, 1, 0 },
    { 1, 0, 1 },
    { 0, 0, 1 },
    { 1, 1, 0 },
};

struct CaptureRoom @private {
    Scene        scene;
    Node*        probe;
    MaterialId[6] bright;
    MaterialId[6] dim;
}

fn Vec3 capture_room_axis(CubeFace face) @private {
    switch (face) {
        case POSITIVE_X: return { 1, 0, 0 };
        case NEGATIVE_X: return { -1, 0, 0 };
        case POSITIVE_Y: return { 0, 1, 0 };
        case NEGATIVE_Y: return { 0, -1, 0 };
        case POSITIVE_Z: return { 0, 0, 1 };
        case NEGATIVE_Z: return { 0, 0, -1 };
    }
}

// The wall's two in-plane world axes: (y, z) for the x walls, (x, z) for the y walls, (x, y) for the z walls.
fn Vec2 capture_room_in_plane(CubeFace face, Vec3 point) @private {
    switch (face) {
        case POSITIVE_X:
        case NEGATIVE_X: return { point.y, point.z };
        case POSITIVE_Y:
        case NEGATIVE_Y: return { point.x, point.z };
        case POSITIVE_Z:
        case NEGATIVE_Z: return { point.x, point.y };
    }
}

fn Vec3 capture_room_tile_center(CubeFace face, Vec2 tile) @private {
    Vec3 axis = capture_room_axis(face) * CAPTURE_ROOM_HALF_SIZE;
    switch (face) {
        case POSITIVE_X:
        case NEGATIVE_X: return { axis.x, tile.x, tile.y };
        case POSITIVE_Y:
        case NEGATIVE_Y: return { tile.x, axis.y, tile.y };
        case POSITIVE_Z:
        case NEGATIVE_Z: return { tile.x, tile.y, axis.z };
    }
}

// The radiance a capture should store along a direction: the wall it hits and the tile's brightness.
fn Vec3 capture_room_expected(Vec3 direction) @private {
    Vec3 magnitude = math::abs(direction);
    CubeFace face;
    if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
        face = direction.x > 0 ? CubeFace.POSITIVE_X : CubeFace.NEGATIVE_X;
    } else if (magnitude.y >= magnitude.z) {
        face = direction.y > 0 ? CubeFace.POSITIVE_Y : CubeFace.NEGATIVE_Y;
    } else {
        face = direction.z > 0 ? CubeFace.POSITIVE_Z : CubeFace.NEGATIVE_Z;
    }
    float major = math::max(magnitude.x, magnitude.y, magnitude.z);
    Vec2 in_plane = capture_room_in_plane(face, direction * (CAPTURE_ROOM_HALF_SIZE / major));
    Vec3 color = CAPTURE_ROOM_COLORS[face.ordinal];
    return in_plane.x > 0 && in_plane.y > 0 ? color : color * CAPTURE_ROOM_DIM;
}

fn CaptureRoom? capture_room(Fixture* fixture, bool metal_floor) @private {
    CaptureRoom room;
    room.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&room.scene);
    room.scene.ambient_intensity = 0;
    room.scene.background.color = { 0, 0, 0, 1 };
    GeometryId tile = add_plane(fixture, CAPTURE_ROOM_TILE)!;
    GeometryId floor = add_plane(fixture, 2 * CAPTURE_ROOM_HALF_SIZE)!;
    MaterialCommon both_sides = material::MATERIAL_COMMON_DEFAULT;
    both_sides.double_sided = true;
    foreach (face : CubeFace::values) {
        Vec3 color = CAPTURE_ROOM_COLORS[face.ordinal];
        Vec3 dim = color * CAPTURE_ROOM_DIM;
        BasicParams bright = { .color = { color.x, color.y, color.z, 1 } };
        BasicParams faint = { .color = { dim.x, dim.y, dim.z, 1 } };
        room.bright[face.ordinal] = fixture.assets.add_material(material::basic(bright, both_sides))!;
        room.dim[face.ordinal] = fixture.assets.add_material(material::basic(faint, both_sides))!;
        if (metal_floor && face == CubeFace.NEGATIVE_Y) {
            MaterialId metal = fixture.assets.add_material(material::standard({
                .base_color = { 1, 1, 1, 1 },
                .metallic   = 1,
                .roughness  = 0,
            }))!;
            room.scene.add_mesh(floor, metal, name: "floor")!.local.position = { 0, CAPTURE_ROOM_FLOOR_HEIGHT, 0 };
            continue;
        }
        Quat facing = maths::rotation_between({ 0, 1, 0 }, math::abs(capture_room_axis(face)));
        for (uint quadrant = 0; quadrant < 4; quadrant++) {
            Vec2 offset = { (quadrant & 1) != 0 ? 1 : -1, (quadrant & 2) != 0 ? 1 : -1 };
            bool lit = offset.x > 0 && offset.y > 0;
            MaterialId material_id = lit ? room.bright[face.ordinal] : room.dim[face.ordinal];
            Node* node = room.scene.add_mesh(tile, material_id, name: "tile")!;
            node.local.position = capture_room_tile_center(face, offset * (CAPTURE_ROOM_TILE / 2));
            node.local.rotation = facing;
        }
    }
    room.probe = room.scene.add_node(name: "reflection_probe")!;
    room.scene.add(room.probe, light::reflection_probe(CAPTURE_ROOM_PROBE_HALF_EXTENTS, {}));
    GeometryId sphere = add_sphere(fixture, CAPTURE_ROOM_SPHERE_RADIUS)!;
    MaterialId mirror = fixture.assets.add_material(material::standard({
        .base_color = { 1, 1, 1, 1 },
        .metallic   = 1,
        .roughness  = 0,
    }))!;
    room.scene.add_mesh(sphere, mirror, name: "sphere")!.layers = CAPTURE_ROOM_SPHERE_LAYER;
    MaterialId black = fixture.assets.add_material(material::basic({ .color = { 0, 0, 0, 1 } }, both_sides))!;
    Node* screen = room.scene.add_mesh(floor, black, name: "screen")!;
    screen.layers = CAPTURE_ROOM_SCREEN_LAYER;
    screen.local.position = { CAPTURE_ROOM_SCREEN_DISTANCE, 0, 0 };
    screen.local.rotation = maths::rotation_between({ 0, 1, 0 }, { 1, 0, 0 });
    room.scene.update_world();
    return room;
}

fn ReflectionCaptureDesc capture_room_desc() @private {
    ReflectionCaptureDesc desc = render::REFLECTION_CAPTURE_DESC_DEFAULT;
    desc.size = CAPTURE_ROOM_SIZE;
    desc.layers = 1;
    return desc;
}

fn Vec3 capture_room_texel(char[] pixels, CubeFace face, uint[<2>] texel) @private {
    usz first = (((usz)face.ordinal * CAPTURE_ROOM_SIZE + texel.y) * CAPTURE_ROOM_SIZE + texel.x) * 4;
    ushort[] halves = ((ushort*)pixels.ptr)[:pixels.len / ushort::size];
    return {
        render::half_to_float(halves[first]),
        render::half_to_float(halves[first + 1]),
        render::half_to_float(halves[first + 2]),
    };
}

// Centre pixel of a mirror sphere seen from the probe's side along the face axis: the wall behind the camera.
fn Vec3? capture_room_reflection(Fixture* fixture, CaptureRoom* room, CubeFace face) @private {
    Vec3 axis = capture_room_axis(face);
    Node* camera_node = room.scene.add_camera(
        camera::perspective_deg(CAPTURE_ROOM_CAMERA_FOV_DEGREES, 0.05f),
        name: "camera",
    )!;
    defer room.scene.remove(camera_node);
    room.scene.get(camera_node, Camera).layers = 1 | CAPTURE_ROOM_SPHERE_LAYER;
    camera_node.local.position = axis * CAPTURE_ROOM_CAMERA_DISTANCE;
    Vec3 up = face == CubeFace.POSITIVE_Y || face == CubeFace.NEGATIVE_Y ? (Vec3){ 0, 0, 1 } : (Vec3){ 0, 1, 0 };
    camera_node.local.rotation = maths::look_rotation(-axis, up);
    room.scene.update_world();
    ReflectionShot shot = reflection_shot(
        fixture:     fixture,
        scene:       &room.scene,
        camera_node: camera_node,
        shading:     ShadingPath.FORWARD,
        size:        CAPTURE_ROOM_TARGET,
    )!;
    defer reflection_destroy_shot(fixture, &shot);
    Vec4[] pixels = reflection_render(fixture, &shot)!;
    defer free(pixels);
    return reflection_texel(&shot, pixels, axis * CAPTURE_ROOM_SPHERE_RADIUS).xyz;
}

fn void capture_room_assert_hue(Vec3 found, Vec3 expected) @private {
    float largest = math::max(found.x, found.y, found.z);
    assert(largest > 0);
    for (usz channel = 0; channel < 3; channel++) {
        assert(math::abs(found[channel] / largest - expected[channel]) <= CAPTURE_ROOM_HUE_TOLERANCE);
    }
}

fn void test_capture_faces_show_their_walls() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    CaptureRoom room = capture_room(&fixture, false)!!;
    defer scene::destroy_scene(&room.scene);

    Renderer* renderer = &fixture.renderer;
    EnvironmentId environment = renderer.capture_reflection_probe(&room.scene, room.probe, capture_room_desc())!!;
    ReflectionCaptureStats captured = renderer.last_reflection_capture;
    io::eprintfn("capture: %.1f ms, %d cube bytes", captured.elapsed_ms, captured.cube_bytes);
    // A capture face records no post compute work: LINEAR_HDR views never meter exposure.
    assert(renderer.stats.post_dispatches == 0);
    room.scene.get(room.probe, ReflectionProbe).environment = environment;
    TextureId source = fixture.assets.environment(environment).desc.source;
    char[] pixels = fixture.assets.texture(source).pixels;
    foreach (face : CubeFace::values) {
        foreach (texel : CAPTURE_ROOM_TEXELS) {
            Vec2 uv = ((Vec2)texel + 0.5f) / CAPTURE_ROOM_SIZE;
            Vec3 expected = capture_room_expected(render::preview_face_direction(face, uv));
            Vec3 found = capture_room_texel(pixels, face, texel);
            for (usz channel = 0; channel < 3; channel++) {
                assert(math::abs(found[channel] - expected[channel]) <= CAPTURE_ROOM_FACE_TOLERANCE);
            }
        }
    }

    fixture.renderer.upload_environment(environment)!!;
    foreach (face : CubeFace::values) {
        capture_room_assert_hue(capture_room_reflection(&fixture, &room, face)!!, CAPTURE_ROOM_COLORS[face.ordinal]);
    }
    check_validation(&fixture.renderer);
}

fn void test_recapture_keeps_ids_and_repeats_its_bytes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CaptureRoom room = capture_room(&fixture, true)!!;
    defer scene::destroy_scene(&room.scene);
    ReflectionProbe* probe = room.scene.get(room.probe, ReflectionProbe);

    Renderer* renderer = &fixture.renderer;
    EnvironmentId environment = renderer.capture_reflection_probe(&room.scene, room.probe, capture_room_desc())!!;
    probe.environment = environment;
    TextureId source = fixture.assets.environment(environment).desc.source;
    (void)capture_room_reflection(&fixture, &room, CubeFace.POSITIVE_X)!!;
    uint revision = fixture.assets.texture(source).header.revision;
    gpu::TextureHandle filtered = renderer.environment_state.mirrors[environment.index].specular_cube;
    @pool() {
        char[] first = alloc::new_array(tmem, char, fixture.assets.texture(source).pixels.len);
        first[..] = fixture.assets.texture(source).pixels[..];

        renderer.recapture_reflection_probe(&room.scene, room.probe, capture_room_desc())!!;
        assert(c3d::same_id(probe.environment, environment));
        assert(c3d::same_id(fixture.assets.environment(environment).desc.source, source));
        assert(fixture.assets.texture(source).header.revision == revision + 1);
        char[] second = fixture.assets.texture(source).pixels;
        ushort[] before = ((ushort*)first.ptr)[:first.len / ushort::size];
        ushort[] after = ((ushort*)second.ptr)[:second.len / ushort::size];
        foreach (index, bits : before) {
            float expected = render::half_to_float(bits);
            float found = render::half_to_float(after[index]);
            float tolerance = CAPTURE_ROOM_REPEAT_TOLERANCE * math::max(1.0f, math::abs(expected));
            assert(math::abs(found - expected) <= tolerance);
        }
    };

    MaterialId[2] east = { room.bright[CubeFace.POSITIVE_X.ordinal], room.dim[CubeFace.POSITIVE_X.ordinal] };
    foreach (id : east) {
        fixture.assets.material(id).data.basic.color = { 1, 1, 1, 1 };
        fixture.assets.mark_material_dirty(id);
    }
    renderer.recapture_reflection_probe(&room.scene, room.probe, capture_room_desc())!!;
    Vec3 white = capture_room_reflection(&fixture, &room, CubeFace.POSITIVE_X)!!;
    assert(renderer.stats.environment_prepares == 1);
    assert(math::max(white.x, white.y, white.z) <= CAPTURE_ROOM_WHITE_RATIO * math::min(white.x, white.y, white.z));
    assert(renderer.environment_state.mirrors[environment.index].specular_cube == filtered);

    fixture.assets.remove_environment(environment);
    fixture.assets.remove_texture(source);
    for (uint frame = 0; frame <= render::FRAMES_IN_FLIGHT; frame++) {
        (void)capture_room_reflection(&fixture, &room, CubeFace.POSITIVE_X)!!;
        assert(fixture.renderer.stats.dangling_refs >= 1);
    }
    check_validation(&fixture.renderer);
}

fn void capture_room_assert_untouched(Fixture* fixture, ulong frame, uint[3] free_counts) @private {
    assert(fixture.renderer.frame_index == frame);
    assert(fixture.assets.textures.free_count == free_counts[0]);
    assert(fixture.assets.environments.free_count == free_counts[1]);
    assert(fixture.renderer.views.free_count == free_counts[2]);
}

fn void test_capture_faults_before_any_work() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CaptureRoom room = capture_room(&fixture, false)!!;
    defer scene::destroy_scene(&room.scene);
    Renderer* renderer = &fixture.renderer;
    Node* bare = room.scene.add_node(name: "bare")!!;
    Node* removed = room.scene.add_node(name: "removed")!!;
    room.scene.remove(removed);
    room.scene.update_world();
    fixture.assets.add_environment(light::solid_environment({ 1, 1, 1 }, SMALL_PROCESSING), "taken")!!;
    ReflectionCaptureDesc desc = capture_room_desc();
    ReflectionCaptureDesc odd = desc;
    odd.size = 48;

    ulong frame = renderer.frame_index;
    uint[3] free_counts = {
        fixture.assets.textures.free_count,
        fixture.assets.environments.free_count,
        renderer.views.free_count,
    };
    assert(@catch(renderer.capture_reflection_probe(&room.scene, bare, desc)) == c3d::INVALID_ARGUMENT);
    assert(@catch(renderer.capture_reflection_probe(&room.scene, removed, desc)) == c3d::INVALID_ID);
    assert(@catch(renderer.capture_reflection_probe(&room.scene, room.probe, odd)) == c3d::INVALID_ARGUMENT);
    fault excuse = @catch(renderer.capture_reflection_probe(
        scene:      &room.scene,
        probe_node: room.probe,
        desc:       desc,
        key:        "taken",
    ));
    assert(excuse == c3d::INVALID_ARGUMENT);
    assert(@catch(renderer.recapture_reflection_probe(&room.scene, room.probe, desc)) == c3d::INVALID_ID);
    room.scene.get(room.probe, ReflectionProbe).environment = fixture.assets.find_environment("taken")!!;
    assert(@catch(renderer.recapture_reflection_probe(&room.scene, room.probe, desc)) == c3d::INVALID_ARGUMENT);
    capture_room_assert_untouched(&fixture, frame, free_counts);

    EnvironmentId[16] fillers;
    usz filled;
    while (fixture.assets.environments.free_count) {
        fillers[filled++] = fixture.assets.add_environment(light::solid_environment({ 1, 1, 1 }, SMALL_PROCESSING))!!;
    }
    assert(@catch(renderer.capture_reflection_probe(&room.scene, room.probe, desc)) == c3d::CAPACITY_EXCEEDED);
    foreach (filler : fillers[:filled]) fixture.assets.remove_environment(filler);
    capture_room_assert_untouched(&fixture, frame, free_counts);

    RenderTargetId[8] targets;
    ViewId[8] views;
    usz occupied;
    while (renderer.views.free_count) {
        targets[occupied] = render::create_render_target(renderer, render::render_target_desc(8, 8))!!;
        views[occupied] = render::create_view(renderer, render::texture_view_desc(targets[occupied]))!!;
        occupied++;
    }
    assert(@catch(renderer.capture_reflection_probe(&room.scene, room.probe, desc)) == c3d::CAPACITY_EXCEEDED);
    assert(renderer.frame_index == frame);
    for (usz index = 0; index < occupied; index++) {
        render::destroy_view(renderer, views[index])!!;
        render::destroy_render_target(renderer, targets[index])!!;
    }
    capture_room_assert_untouched(&fixture, frame, free_counts);
    check_validation(renderer);
}
