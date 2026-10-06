module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const Plane KEEP_ABOVE_GROUND @private = { .normal = { 0, 1, 0 } };
const Plane KEEP_POSITIVE_X @private = { .normal = { 1, 0, 0 } };
const Plane KEEP_EVERYTHING @private = { .normal = { 0, 1, 0 }, .d = 1000 }; // sets the flag and clips nothing
const Vec3 CLIP_CAMERA_POSITION @private = { 0.75f, -0.75f, 4.5f }; // sees both boxes' +z faces and the buried box
const float CLIP_BATCH_OFFSET @private = 1.5f;
const float BURIED_HEIGHT @private = -2; // the unit box spans y -2.5 to -1.5, wholly behind the ground plane
const Vec3 BOX_KEPT_POINT @private = { 0, 0.25f, 0.5f };
const Vec3 BOX_CLIPPED_POINT @private = { 0, -0.25f, 0.5f };
const Vec3 BATCH_KEPT_POINT @private = { 1.5f, 0.25f, 0.5f };
const Vec3 BATCH_CLIPPED_POINT @private = { 1.5f, -0.25f, 0.5f };
const Vec3 BURIED_POINT @private = { 0, -2, 0.5f };
const int DOMINANT_CHANNEL_MINIMUM @private = 64; // a lit face; the background and the other channels stay far below
const float CASTER_OFFSET @private = -1.5f; // the caster spans x -2 to -1, wholly behind the plane keeping x >= 0
const float CASTER_CENTRE_HEIGHT @private = 2;
const float CASTER_VERTICAL_SIZE @private = 3; // its shadow still crosses the plane past the default 0.68 m offset
const float CASTER_DEPTH @private = 3; // about ten texels of the fixture's 64-texel cascade
const Vec3 CASTER_SHADOW_POINT @private = { 0.8f, 0, 0 }; // in the caster's shadow; the sun falls 1 in 2 toward +x
const Vec3 CASTER_CAMERA_POSITION @private = { 1.5f, 3, 4 };
const float SHADOW_RATIO_MAXIMUM @private = 0.5f; // of the lit floor; the 64-texel atlas filters the shadow's edge
const Vec3 MIRROR_MAIN_CAMERA_POSITION @private = { 0, 0.5f, 6 };
const float MIRROR_QUAD_DEPTH @private = 3; // about ten rows tall at the mirror camera's grazing angle
const Vec3 DOWNWARD_QUAD_POSITION @private = { -1, 1, 0 };
const Vec3 UPWARD_QUAD_POSITION @private = { 1, 1, 0 };
const Vec3 MIRRORED_BOX_POSITION @private = { 0, -1, 0 };
const float VELOCITY_STEP @private = 0.1f; // two pixels at the box, well inside the debug range
const float CUT_TILT_Z_DEGREES @private = 30; // with the x tilt, the ground plane cuts the box obliquely
const float CUT_TILT_X_DEGREES @private = 20;
const uint CUT_COLUMNS @private = 16;
const float COVERAGE_THRESHOLD @private = 0.5f; // of the brightest reference sample; the background reads near zero

const RasterPath[3] RASTER_PATHS @private = {
    { .shading = ShadingPath.FORWARD, .depth_prepass = false },
    { .shading = ShadingPath.FORWARD, .depth_prepass = true },
    { .shading = ShadingPath.DEFERRED, .depth_prepass = true },
};

struct ClipScene @private {
    Scene  scene;
    ViewId view;
    Node*  camera;
    Node*  box;
    Node*  batch;
    Node*  buried;
}

struct RasterPath @private {
    ShadingPath shading;
    bool        depth_prepass;
}

struct CasterScene @private {
    Scene scene;
    Node* camera;
    Node* caster;
}

struct ReflectedScene @private {
    Scene  scene;
    ViewId view;
    Node*  main_camera;
    Node*  mirror_camera;
    Node*  downward_quad;
    Node*  upward_quad;
    Node*  box;
}

struct CutLine @private {
    ComputeShaderId    shader;
    BufferId           output;
    gpu::MappedGpuSpan readback;
}

fn MaterialId? add_matte_material(Fixture* fixture, Vec4 color) @private {
    return fixture.assets.add_material(material::standard({ .base_color = color, .roughness = 1 }));
}

fn ClipScene? create_clip_scene(Fixture* fixture, MaterialId box_material) @private {
    ClipScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = { 1, 1, 1 };
    result.scene.ambient_intensity = 1;
    MaterialId red_material = add_matte_material(fixture, RED)!;
    MaterialId blue_material = add_matte_material(fixture, BLUE)!;

    result.box = result.scene.add_mesh(fixture.box, box_material, name: "box")!;
    Transform[1] instances = { maths::TRANSFORM_IDENTITY };
    instances[0].position = { CLIP_BATCH_OFFSET, 0, 0 };
    result.batch = result.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   red_material,
        capacity:   1,
        transforms: instances[..],
        name:       "batch",
    )!;
    result.buried = result.scene.add_mesh(fixture.box, blue_material, name: "buried")!;
    result.buried.local.position = { 0, BURIED_HEIGHT, 0 };
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = CLIP_CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn void set_clip_meshes_visible(ClipScene* clip, bool visible) @private {
    clip.box.visible = visible;
    clip.batch.visible = visible;
    clip.buried.visible = visible;
}

fn AoView? create_clip_view(Fixture* fixture, RasterPath path) @private {
    AoView result = create_ao_view(fixture, path.shading)!;
    defer catch destroy_ao_view(fixture, &result);
    ViewDesc desc = fixture.renderer.views.get(result.view).desc;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.depth_prepass = path.depth_prepass;
    render::configure_view(&fixture.renderer, result.view, desc)!;
    return result;
}

fn void? set_clip_plane(Fixture* fixture, ViewId view, Plane plane) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.clip_plane = plane;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn Vec2 clip_view_uv(Scene* scene, Node* camera_node, Vec3 point) @private {
    Camera* camera = scene.get(camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(
        *camera,
        camera_node.world,
        { AO_TARGET_WIDTH, AO_TARGET_HEIGHT },
    );
    return projected_uv(&matrices, point);
}

fn uint? render_clip_view(
    Fixture* fixture,
    Scene* scene,
    Node* camera_node,
    ViewId view,
    Vec2 uv,
) @private {
    Renderer* renderer = &fixture.renderer;
    scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(scene, camera_node, view)!;
    sample(fixture, render::read_view_color(view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn uint? read_clip_point(Fixture* fixture, ClipScene* clip, Vec3 point) @private {
    return render_clip_view(
        fixture:     fixture,
        scene:       &clip.scene,
        camera_node: clip.camera,
        view:        clip.view,
        uv:          clip_view_uv(&clip.scene, clip.camera, point),
    );
}

fn void check_dominant_channel(uint pixel, uint channel) @private {
    int dominant = pixel_channel(pixel, channel);
    assert(dominant >= DOMINANT_CHANNEL_MINIMUM);
    for (uint other = 0; other < 3; other++) {
        if (other != channel) assert(pixel_channel(pixel, other) * 2 < dominant);
    }
}

fn bool same_texture(gpu::TextureHandle texture, gpu::TextureHandle other) @private {
    return texture.owner == other.owner && texture.index == other.index && texture.generation == other.generation;
}

fn void test_clip_plane_cuts_meshes_on_every_raster_path() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialId red_material = add_matte_material(&fixture, RED)!!;
    ClipScene clip = create_clip_scene(&fixture, red_material)!!;
    defer scene::destroy_scene(&clip.scene);
    Renderer* renderer = &fixture.renderer;

    Vec3[2] kept = { BOX_KEPT_POINT, BATCH_KEPT_POINT };
    Vec3[3] removed = { BOX_CLIPPED_POINT, BATCH_CLIPPED_POINT, BURIED_POINT };
    foreach (path : RASTER_PATHS) {
        AoView clip_view = create_clip_view(&fixture, path)!!;
        defer destroy_ao_view(&fixture, &clip_view);
        clip.view = clip_view.view;

        uint[3] background;
        set_clip_meshes_visible(&clip, false);
        foreach (index, point : removed) background[index] = read_clip_point(&fixture, &clip, point)!!;
        set_clip_meshes_visible(&clip, true);

        uint[2] unclipped;
        foreach (index, point : kept) {
            unclipped[index] = read_clip_point(&fixture, &clip, point)!!;
            check_dominant_channel(unclipped[index], 0);
        }
        check_dominant_channel(read_clip_point(&fixture, &clip, BURIED_POINT)!!, 2);
        uint unclipped_culled = renderer.stats.culled;

        ViewRecord* record = renderer.views.get(clip_view.view);
        gpu::TextureHandle color = record.hdr_color.texture;
        gpu::TextureHandle depth = record.depth.texture;
        set_clip_plane(&fixture, clip_view.view, KEEP_ABOVE_GROUND)!!;
        assert(same_texture(record.hdr_color.texture, color) && same_texture(record.depth.texture, depth));

        foreach (index, point : kept) {
            check_near_pixel(read_clip_point(&fixture, &clip, point)!!, unclipped[index]);
        }
        foreach (index, point : removed) {
            check_near_pixel(read_clip_point(&fixture, &clip, point)!!, background[index]);
        }
        io::eprintfn(
            "%s prepass %s: culled %d -> %d",
            path.shading,
            path.depth_prepass,
            unclipped_culled,
            renderer.stats.culled,
        );
        assert(renderer.stats.culled == unclipped_culled + 1);
    }
    check_validation(renderer);
}

fn CasterScene? create_caster_scene(Fixture* fixture) @private {
    CasterScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    GeometryId floor;
    GeometryId slab;
    @pool() {
        Geometry plane = geometry::plane(tmem, 10, 10);
        floor = fixture.assets.add_geometry(&plane)!;
        Geometry caster = geometry::box(
            allocator: tmem,
            width:     1,
            height:    CASTER_VERTICAL_SIZE,
            depth:     CASTER_DEPTH,
        );
        slab = fixture.assets.add_geometry(&caster)!;
    };
    MaterialId grey = add_matte_material(fixture, { LIT_ALBEDO, LIT_ALBEDO, LIT_ALBEDO, 1 })!;
    result.scene.add_mesh(floor, grey, name: "floor")!;
    result.caster = result.scene.add_mesh(slab, grey, name: "caster")!;
    result.caster.local.position = { CASTER_OFFSET, CASTER_CENTRE_HEIGHT, 0 };

    Light sunlight = light::directional({ 1, 1, 1 }, 2);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = 10;
    Node* sun = result.scene.add_light(sunlight, name: "sun")!;
    sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, (Vec3){ 1, -0.5f, 0 }.normalize());
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = CASTER_CAMERA_POSITION;
    result.camera.local.rotation = maths::look_rotation(
        (CASTER_SHADOW_POINT - CASTER_CAMERA_POSITION).normalize(),
        { 0, 1, 0 },
    );
    result.scene.update_world();
    return result;
}

fn uint? read_caster_point(Fixture* fixture, CasterScene* caster, ViewId view) @private {
    return render_clip_view(
        fixture:     fixture,
        scene:       &caster.scene,
        camera_node: caster.camera,
        view:        view,
        uv:          clip_view_uv(&caster.scene, caster.camera, CASTER_SHADOW_POINT),
    );
}

fn void test_clip_plane_keeps_shadow_casters() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CasterScene caster = create_caster_scene(&fixture)!!;
    defer scene::destroy_scene(&caster.scene);
    AoView clip_view = create_clip_view(&fixture, RASTER_PATHS[1])!!;
    defer destroy_ao_view(&fixture, &clip_view);
    Renderer* renderer = &fixture.renderer;

    uint unclipped = read_caster_point(&fixture, &caster, clip_view.view)!!;
    uint unclipped_layers = renderer.stats.shadow_layers;
    set_clip_plane(&fixture, clip_view.view, KEEP_POSITIVE_X)!!;
    uint clipped = read_caster_point(&fixture, &caster, clip_view.view)!!;
    uint clipped_layers = renderer.stats.shadow_layers;
    set_clip_plane(&fixture, clip_view.view, {})!!;
    caster.caster.visible = false;
    uint lit = read_caster_point(&fixture, &caster, clip_view.view)!!;
    io::eprintfn(
        "shadowed floor %08x clipped %08x lit %08x, layers %d and %d",
        unclipped,
        clipped,
        lit,
        unclipped_layers,
        clipped_layers,
    );

    check_near_pixel(clipped, unclipped);
    assert((float)red(clipped) < SHADOW_RATIO_MAXIMUM * (float)red(lit));
    assert(clipped_layers == unclipped_layers && clipped_layers > 0);
    check_validation(renderer);
}

fn void test_clip_plane_keeping_everything_matches_no_plane() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CreaseScene crease = create_crease_scene(&fixture)!!;
    defer scene::destroy_scene(&crease.scene);
    crease.quad.visible = true;
    crease.masked_box.visible = true;
    crease.cut_box.visible = true;
    crease.sun.visible = true;
    crease.scene.update_world();

    Vec3[5] points = { CREASE_POINT, OPEN_POINT, MASKED_TOP_POINT, CUT_POINT, QUAD_POINT };
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (shading : paths) {
        AoView ao_view = create_ao_view(&fixture, shading)!!;
        defer destroy_ao_view(&fixture, &ao_view);
        crease.view = ao_view.view;
        uint[5] without;
        foreach (index, point : points) without[index] = render_and_read(&fixture, &crease, point)!!;
        set_clip_plane(&fixture, ao_view.view, KEEP_EVERYTHING)!!;
        foreach (index, point : points) assert(render_and_read(&fixture, &crease, point)!! == without[index]);
    }
    check_validation(&fixture.renderer);
}

fn ReflectedScene? create_reflected_scene(Fixture* fixture) @private {
    ReflectedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    GeometryId quad;
    @pool() {
        Geometry plane = geometry::plane(tmem, 1, MIRROR_QUAD_DEPTH);
        quad = fixture.assets.add_geometry(&plane)!;
    };
    MaterialId red_material = fixture.assets.add_material(material::basic({ .color = RED }))!;
    MaterialId green_material = fixture.assets.add_material(material::basic({ .color = GREEN }))!;
    MaterialId blue_material = fixture.assets.add_material(material::basic({ .color = BLUE }))!;

    result.downward_quad = result.scene.add_mesh(quad, red_material, name: "downward_quad")!;
    result.downward_quad.local.position = DOWNWARD_QUAD_POSITION;
    result.downward_quad.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI);
    result.upward_quad = result.scene.add_mesh(quad, green_material, name: "upward_quad")!;
    result.upward_quad.local.position = UPWARD_QUAD_POSITION;
    result.box = result.scene.add_mesh(fixture.box, blue_material, name: "box")!;
    result.box.local.position = MIRRORED_BOX_POSITION;

    result.main_camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "main_camera")!;
    result.main_camera.local.position = MIRROR_MAIN_CAMERA_POSITION;
    result.main_camera.local.rotation = maths::look_rotation(-MIRROR_MAIN_CAMERA_POSITION.normalize(), { 0, 1, 0 });
    result.mirror_camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "mirror_camera")!;
    Mat4 mirrored = maths::reflection_matrix(KEEP_ABOVE_GROUND).mul(result.main_camera.local.to_mat4());
    result.mirror_camera.local = maths::transform_from_affine(mirrored)!;
    result.scene.update_world();
    return result;
}

fn uint? read_reflection(Fixture* fixture, ReflectedScene* reflected, Vec3 image_point) @private {
    return render_clip_view(
        fixture:     fixture,
        scene:       &reflected.scene,
        camera_node: reflected.mirror_camera,
        view:        reflected.view,
        uv:          clip_view_uv(&reflected.scene, reflected.main_camera, image_point),
    );
}

fn void test_mirrored_camera_reflects_only_the_kept_side() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ReflectedScene reflected = create_reflected_scene(&fixture)!!;
    defer scene::destroy_scene(&reflected.scene);
    AoView mirror_view = create_clip_view(&fixture, RASTER_PATHS[1])!!;
    defer destroy_ao_view(&fixture, &mirror_view);
    reflected.view = mirror_view.view;

    Vec3 downward_image = { DOWNWARD_QUAD_POSITION.x, -DOWNWARD_QUAD_POSITION.y, DOWNWARD_QUAD_POSITION.z };
    Vec3 upward_image = { UPWARD_QUAD_POSITION.x, -UPWARD_QUAD_POSITION.y, UPWARD_QUAD_POSITION.z };
    Vec3 box_image = { MIRRORED_BOX_POSITION.x, -MIRRORED_BOX_POSITION.y, MIRRORED_BOX_POSITION.z };
    Vec3[3] images = { downward_image, upward_image, box_image };
    uint[3] background;
    reflected.downward_quad.visible = false;
    reflected.upward_quad.visible = false;
    reflected.box.visible = false;
    foreach (index, image : images) {
        background[index] = read_reflection(&fixture, &reflected, image)!!;
    }
    reflected.downward_quad.visible = true;
    reflected.upward_quad.visible = true;
    reflected.box.visible = true;
    check_dominant_channel(read_reflection(&fixture, &reflected, box_image)!!, 2);

    set_clip_plane(&fixture, mirror_view.view, KEEP_ABOVE_GROUND)!!;
    check_dominant_channel(read_reflection(&fixture, &reflected, downward_image)!!, 0);
    check_near_pixel(read_reflection(&fixture, &reflected, upward_image)!!, background[1]);
    check_near_pixel(read_reflection(&fixture, &reflected, box_image)!!, background[2]);
    check_validation(&fixture.renderer);
}

fn void test_custom_vertex_stage_clips_through_write_mesh_outputs() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ShaderId pulse;
    @pool() {
        pulse = add_pulse_shader(&fixture)!!;
    };
    PulseBlock magenta = { .color = { 1, 0, 1, 1 } };
    MaterialId custom = fixture.assets.add_material(material::custom(pulse, material::@as_bytes(magenta)))!!;
    ClipScene clip = create_clip_scene(&fixture, custom)!!;
    defer scene::destroy_scene(&clip.scene);

    foreach (path : RASTER_PATHS[:2]) {
        AoView clip_view = create_clip_view(&fixture, path)!!;
        defer destroy_ao_view(&fixture, &clip_view);
        clip.view = clip_view.view;
        clip.box.visible = false;
        uint background = read_clip_point(&fixture, &clip, BOX_CLIPPED_POINT)!!;
        clip.box.visible = true;
        uint unclipped = read_clip_point(&fixture, &clip, BOX_KEPT_POINT)!!;
        assert(red(unclipped) >= DOMINANT_CHANNEL_MINIMUM && blue(unclipped) >= DOMINANT_CHANNEL_MINIMUM);
        assert(green(unclipped) * 2 < red(unclipped));

        set_clip_plane(&fixture, clip_view.view, KEEP_ABOVE_GROUND)!!;
        check_near_pixel(read_clip_point(&fixture, &clip, BOX_KEPT_POINT)!!, unclipped);
        check_near_pixel(read_clip_point(&fixture, &clip, BOX_CLIPPED_POINT)!!, background);
    }
    check_validation(&fixture.renderer);
}

fn uint? read_moving_box(Fixture* fixture, ClipScene* clip, Vec3 point) @private {
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        clip.box.local.position.x = (float)frame * VELOCITY_STEP;
        pixel = read_clip_point(fixture, clip, point)!;
    }
    return pixel;
}

fn void test_clipped_moving_mesh_keeps_geometry_velocity_above_the_plane() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialId red_material = add_matte_material(&fixture, RED)!!;
    ClipScene clip = create_clip_scene(&fixture, red_material)!!;
    defer scene::destroy_scene(&clip.scene);
    AoView clip_view = create_clip_view(&fixture, RASTER_PATHS[1])!!;
    defer destroy_ao_view(&fixture, &clip_view);
    clip.view = clip_view.view;
    enable_taa(&fixture, clip_view.view, debug: TaaDebug.VELOCITY)!!;

    uint kept_unclipped = read_moving_box(&fixture, &clip, BOX_KEPT_POINT)!!;
    set_clip_plane(&fixture, clip_view.view, KEEP_ABOVE_GROUND)!!;
    uint kept_clipped = read_moving_box(&fixture, &clip, BOX_KEPT_POINT)!!;
    uint removed_clipped = read_moving_box(&fixture, &clip, BOX_CLIPPED_POINT)!!;
    clip.box.visible = false;
    uint removed_hidden = read_moving_box(&fixture, &clip, BOX_CLIPPED_POINT)!!;
    io::eprintfn(
        "kept %08x -> %08x, removed %08x, hidden %08x",
        kept_unclipped,
        kept_clipped,
        removed_clipped,
        removed_hidden,
    );

    assert((float)channel_difference(kept_unclipped, removed_hidden, 0) >= MIN_VELOCITY_STEPS);
    check_near_pixel(kept_clipped, kept_unclipped);
    check_near_pixel(removed_clipped, removed_hidden);
    check_validation(&fixture.renderer);
}

fn CutLine? create_cut_line(Fixture* fixture) @private {
    CutLine result;
    result.shader = add_compute_shader(fixture, (String)LINE_SOURCE[..])!;
    usz bytes = CUT_COLUMNS * AO_TARGET_HEIGHT * float::size;
    result.output = fixture.renderer.create_buffer({ .size = bytes, .debug_name = "clip_cut_line" })!;
    gpu::AllocationDesc readback_desc = {
        .size = bytes,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "clip_cut_line_readback",
    };
    result.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
    return result;
}

fn void destroy_cut_line(Fixture* fixture, CutLine* line) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = line.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
}

// Column index major; row 0 is the top of the image.
fn void? read_cut_columns(
    Fixture* fixture,
    ClipScene* clip,
    CutLine* line,
    uint first_column,
    float[] luminance,
) @private {
    Renderer* renderer = &fixture.renderer;
    clip.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&clip.scene, clip.camera, clip.view)!;
    BufferId[1] writes = { line.output };
    DispatchTexture[1] textures = { render::read_view_color(clip.view) };
    gpu::GpuAddress base = renderer.buffer_address(line.output);
    for (uint column = 0; column < CUT_COLUMNS; column++) {
        LineRoot root = {
            .output_address = (gpu::GpuAddress)((ulong)base + (ulong)column * AO_TARGET_HEIGHT * float::size),
            .uv_start = { ((float)(first_column + column) + 0.5f) / AO_TARGET_WIDTH, 0.5f / AO_TARGET_HEIGHT },
            .uv_step = { 0, 1.0f / AO_TARGET_HEIGHT },
            .count = AO_TARGET_HEIGHT,
        };
        renderer.dispatch({
            .shader = line.shader,
            .root = ((char*)&root)[:LineRoot::size],
            .groups = { (AO_TARGET_HEIGHT + LINE_GROUP_SIZE - 1) / LINE_GROUP_SIZE, 1, 1 },
            .writes = writes[..],
            .textures = textures[..],
        })!;
    }
    gpu::Barrier copied_writes = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied_writes)!;
    gpu::BufferCopyDesc buffer_copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(line.output).allocation)!,
        .dst = line.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &buffer_copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.finish_view(clip.view)!;
    renderer.end_frame()!;

    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, line.readback.span)!;
    luminance[..] = ((float*)line.readback.bytes.ptr)[:luminance.len];
}

fn void test_clip_plane_cut_line_matches_the_single_pass() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialId red_material = add_matte_material(&fixture, RED)!!;
    ClipScene clip = create_clip_scene(&fixture, red_material)!!;
    defer scene::destroy_scene(&clip.scene);
    clip.batch.visible = false;
    clip.buried.visible = false;
    Quat tilt_z = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::deg_to_rad(CUT_TILT_Z_DEGREES));
    Quat tilt_x = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::deg_to_rad(CUT_TILT_X_DEGREES));
    clip.box.local.rotation = tilt_z.mul(tilt_x).normalize();
    CutLine line = create_cut_line(&fixture)!!;
    defer destroy_cut_line(&fixture, &line);

    Vec2 center = clip_view_uv(&clip.scene, clip.camera, { 0, 0, 0 });
    uint first_column = (uint)(center.x * AO_TARGET_WIDTH) - CUT_COLUMNS / 2;
    float[CUT_COLUMNS * AO_TARGET_HEIGHT] unclipped;
    float[CUT_COLUMNS * AO_TARGET_HEIGHT][RASTER_PATHS.len] clipped;
    foreach (index, path : RASTER_PATHS) {
        AoView clip_view = create_clip_view(&fixture, path)!!;
        defer destroy_ao_view(&fixture, &clip_view);
        clip.view = clip_view.view;
        if (index == 0) {
            read_cut_columns(
                fixture:      &fixture,
                clip:         &clip,
                line:         &line,
                first_column: first_column,
                luminance:    unclipped[..],
            )!!;
        }
        set_clip_plane(&fixture, clip_view.view, KEEP_ABOVE_GROUND)!!;
        read_cut_columns(
            fixture:      &fixture,
            clip:         &clip,
            line:         &line,
            first_column: first_column,
            luminance:    clipped[index][..],
        )!!;
    }

    float brightest;
    foreach (value : unclipped) brightest = math::max(brightest, value);
    float threshold = brightest * COVERAGE_THRESHOLD;
    usz covered;
    usz cut;
    usz[RASTER_PATHS.len] mismatches;
    foreach (sample, value : unclipped) {
        bool reference = clipped[0][sample] > threshold;
        if (reference) covered++;
        if (value > threshold && !reference) cut++;
        for (usz index = 1; index < RASTER_PATHS.len; index++) {
            if ((clipped[index][sample] > threshold) != reference) mismatches[index]++;
        }
    }
    io::eprintfn(
        "cut line: %d samples, %d covered, %d cut; mismatches prepass %d, deferred %d (threshold %.4f)",
        unclipped.len,
        covered,
        cut,
        mismatches[1],
        mismatches[2],
        threshold,
    );
    assert(covered > 0 && cut > 0);
    assert(mismatches[1] == 0 && mismatches[2] == 0);
    check_validation(&fixture.renderer);
}
