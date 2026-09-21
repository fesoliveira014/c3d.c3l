module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] FILL_SOURCE @private = $embed("fill.comp.glsl");
const char[*] SAMPLE_SOURCE @private = $embed("sample.comp.glsl");
const uint TARGET_SIZE @private = 32;
const uint TEXTURE_SIZE @private = 8;
const uint FILL_GROUP_SIZE @private = 8; // mirrored as local_size_x and local_size_y in fill.comp.glsl
const uint PIXEL_ALPHA_MASK @private = 0xff000000;
const uint PIXEL_COLOR_MASK @private = 0x00ffffff;
const int CHANNEL_TOLERANCE @private = 1;
const Vec4 RED @private = { 1, 0, 0, 1 };
const Vec4 GREEN @private = { 0, 1, 0, 1 };
const Vec4 BLUE @private = { 0, 0, 1, 1 };
const Vec4 WARM @private = { 1, 0.5f, 0.25f, 1 };
const Vec4 COOL @private = { 0.25f, 0.5f, 1, 1 };
const Vec2 CENTER_UV @private = { 0.5f, 0.5f };
const Vec3 CAMERA_POSITION @private = { 0, 0, 3 };
const float CAMERA_TURN_DEGREES @private = 2;
const float CAMERA_SLIDE @private = 0.1f;
const float ORTHOGRAPHIC_HEIGHT @private = 2;
const uint SHARED_BOX_COUNT @private = 5;
const uint SHARED_GRID_WIDTH @private = 8;
const uint OVERFLOW_BOX_COUNT @private = 64; // about 20 KiB of draw roots per frame against a 4 KiB ring
const usz TINY_RING_BYTES @private = 4096;
const float BLURRED_CENTER_MINIMUM @private = 0.8f; // a few pixels of true motion keep the box center nearly solid; a background velocity clamped at max_velocity smears it dark

struct FillRoot @private {
    Vec4 color;
    uint size;
    uint[3] padding;
}
$assert FillRoot::size == 32;

struct SampleRoot @private {
    gpu::GpuAddress output_address;
    Vec2 uv;
}
$assert SampleRoot::size == 16;

struct SampleOutput @private {
    uint pixel;
}

struct Fixture @private {
    Allocator allocator;
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    Node* camera_node;
    TextureId storage_texture;
    MaterialId material;
    GeometryId box;
    GeometryId colored_box;
    GeometryId faded_box;
    MaterialId plain;
    MaterialId masked;
    SkeletonId skeleton;
    GeometryId deformed_box;
    ComputeShaderId fill_shader;
    ComputeShaderId sample_shader;
    BufferId output;
    RenderTargetId hdr_target;
    RenderTargetId ldr_target;
    ViewId view;
    ViewId second_view;
    gpu::MappedGpuSpan readback;
    bool renderer_alive;
}

struct DeformedScene @private {
    Scene scene;
    Node* mesh;
    Node* camera;
}

fn void? create_fixture(Allocator allocator, Fixture* fixture, usz upload_ring_bytes = 0) @private {
    fixture.allocator = allocator;
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&fixture.scene);

    fixture.storage_texture = fixture.assets.add_texture_empty(storage_texture_desc("acceptance_storage"))!;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.box = fixture.assets.add_geometry(&box)!;
        fixture.material = fixture.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(fixture.storage_texture),
        }))!;
        fixture.scene.add_mesh(fixture.box, fixture.material)!;
        fixture.plain = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!;
        MaterialCommon cutout = material::MATERIAL_COMMON_DEFAULT;
        cutout.alpha_mode = AlphaMode.MASK;
        cutout.alpha_cutoff = 0.5f;
        fixture.masked = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, cutout))!;
        fixture.colored_box = add_colored_box(fixture, GREEN)!;
        fixture.faded_box = add_colored_box(fixture, { 1, 1, 1, 0 })!;

        Geometry deformed = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        deformed.joints = alloc::new_array(tmem, ushort[<4>], deformed.positions.len);
        deformed.weights = alloc::new_array(tmem, Vec4, deformed.positions.len);
        foreach (&weight : deformed.weights) *weight = { 1, 0, 0, 0 };
        deformed.targets = alloc::new_array(tmem, MorphTarget, 1);
        deformed.targets[0] = {
            .position_deltas = alloc::new_array(tmem, Vec3, deformed.positions.len),
            .normal_deltas   = alloc::new_array(tmem, Vec3, deformed.positions.len),
        };
        foreach (&delta : deformed.targets[0].position_deltas) *delta = { 0, 0.5f, 0 };
        fixture.deformed_box = fixture.assets.add_geometry(&deformed)!;
    };
    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    fixture.camera_node.local.position = CAMERA_POSITION;
    fixture.scene.update_world();

    Skeleton skeleton = {
        .joint_names  = alloc::new_array(allocator, String, 1),
        .parents      = alloc::new_array(allocator, int, 1),
        .rest_pose    = alloc::new_array(allocator, Transform, 1),
        .inverse_bind = alloc::new_array(allocator, Mat4, 1),
    };
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    fixture.skeleton = fixture.assets.add_skeleton_owned(&skeleton)!;

    fixture.fill_shader = add_compute_shader(fixture, (String)FILL_SOURCE[..])!;
    fixture.sample_shader = add_compute_shader(fixture, (String)SAMPLE_SOURCE[..])!;

    fixture.renderer = render::create_renderer(
        allocator: allocator,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .shadow_resolution = 64,
            .max_shadow_layers = 1,
            .upload_ring_bytes = upload_ring_bytes,
            .application_name = "render_acceptance",
        },
    )!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.renderer_alive = true;
    fixture.hdr_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(TARGET_SIZE, TARGET_SIZE),
    )!;
    fixture.ldr_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(TARGET_SIZE, TARGET_SIZE, PixelFormat.RGBA8_UNORM),
    )!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(fixture.hdr_target))!;
    fixture.second_view = render::create_view(&fixture.renderer, render::texture_view_desc(fixture.hdr_target))!;
    fixture.output = fixture.renderer.create_buffer({ .size = SampleOutput::size, .debug_name = "acceptance_output" })!;
    gpu::AllocationDesc readback_desc = {
        .size = SampleOutput::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "acceptance_readback",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
}

fn material::TextureDesc storage_texture_desc(ZString debug_name) @private {
    return {
        .width      = TEXTURE_SIZE,
        .height     = TEXTURE_SIZE,
        .format     = PixelFormat.RGBA8_UNORM,
        .debug_name = debug_name,
    };
}

fn DeformedScene? create_deformed_scene(Fixture* fixture, Vec3 joint_position, float morph_weight) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    Node* joint = result.scene.add_node(name: "joint")!;
    joint.local.position = joint_position;
    result.mesh = result.scene.add_mesh(fixture.deformed_box, fixture.material)!;
    Mesh* mesh = result.scene.get(result.mesh, Mesh);
    mesh.morph_weights = alloc::new_array(result.scene.allocator, float, 1);
    mesh.morph_weights[0] = morph_weight;
    Node*[] joints = alloc::new_array(result.scene.allocator, Node*, 1);
    joints[0] = joint;
    result.scene.add(result.mesh, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn DeformedScene? create_shared_material_scene(Fixture* fixture, uint count) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    for (uint index = 0; index < count; index++) {
        Node* box = result.scene.add_mesh(fixture.box, fixture.material)!;
        box.local.position = {
            (float)(index % SHARED_GRID_WIDTH) - (float)SHARED_GRID_WIDTH / 2 + 0.5f,
            (float)(index / SHARED_GRID_WIDTH) - (float)SHARED_GRID_WIDTH / 2 + 0.5f,
            0,
        };
        if (index == 0) result.mesh = box;
    }
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = { 0, 0, 14 };
    result.scene.update_world();
    return result;
}

fn void? enable_motion_blur(Fixture* fixture, ViewId view) @private {
    ViewDesc desc = render::texture_view_desc(fixture.hdr_target);
    desc.post.motion_blur = true;
    return render::configure_view(&fixture.renderer, view, desc);
}

fn GeometryId? add_colored_box(Fixture* fixture, Vec4 color) @private {
    Geometry box = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    box.colors = alloc::new_array(tmem, Vec4, box.positions.len);
    foreach (&vertex_color : box.colors) *vertex_color = color;
    return fixture.assets.add_geometry(&box);
}

fn DeformedScene? create_single_box_scene(Fixture* fixture, GeometryId geometry, MaterialId material, bool sunlit) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.mesh = result.scene.add_mesh(geometry, material)!;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    if (sunlit) {
        Light sunlight = light::directional({ 1, 1, 1 }, 2);
        sunlight.shadow.cascades = 1;
        sunlight.shadow.max_distance = 10;
        result.scene.add_light(sunlight)!;
    }
    result.scene.update_world();
    return result;
}

fn ComputeShaderId? add_compute_shader(Fixture* fixture, String source) @private {
    char[] spirv = compile::compile_glsl(fixture.allocator, source, ShaderStage.COMPUTE)!;
    defer alloc::free(fixture.allocator, spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    return fixture.assets.add_compute_shader(&shader_desc);
}

fn void destroy_fixture(Fixture* fixture) @private {
    if (fixture.renderer_alive) {
        render::wait_frames(&fixture.renderer)!!;
        gpu::GpuAllocation allocation = fixture.readback.span.allocation();
        gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
        check_validation(&fixture.renderer);
        render::destroy_renderer(&fixture.renderer);
    }
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void check_validation(Renderer* renderer) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        assert(!(entry.category.backend && entry.category.validation && entry.severity == gpu::DebugMessageSeverity.ERROR));
    }
}

fn void print_adapter(Fixture* fixture) @private {
    gpu::DeviceDesc device_desc;
    gpu::Adapter adapter = render::select_adapter(&fixture.renderer.runtime, &device_desc)!!;
    gpu::AdapterInfo info = gpu::get_adapter_info(&adapter)!!;
    io::eprintfn("Vulkan acceptance adapter: %s", info.name);
}

fn void? fill(Fixture* fixture, TextureId texture, Vec4 color) @private {
    FillRoot root = { .color = color, .size = TEXTURE_SIZE };
    DispatchTexture[1] textures = { render::write_texture(texture) };
    uint groups = TEXTURE_SIZE / FILL_GROUP_SIZE;
    return fixture.renderer.dispatch({
        .shader = fixture.fill_shader,
        .root = ((char*)&root)[:FillRoot::size],
        .groups = { groups, groups, 1 },
        .textures = textures[..],
    });
}

fn void? sample(Fixture* fixture, DispatchTexture source, Vec2 uv = CENTER_UV) @private {
    SampleRoot root = { .output_address = fixture.renderer.buffer_address(fixture.output), .uv = uv };
    BufferId[1] writes = { fixture.output };
    DispatchTexture[1] textures = { source };
    return fixture.renderer.dispatch({
        .shader = fixture.sample_shader,
        .root = ((char*)&root)[:SampleRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
        .textures = textures[..],
    });
}

fn void? record_readback(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::Barrier copied_writes = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied_writes)!;
    gpu::BufferCopyDesc buffer_copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(fixture.output).allocation)!,
        .dst = fixture.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &buffer_copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &host_read);
}

fn void? render_view_and_finish(Fixture* fixture) @private {
    fixture.renderer.render_view(&fixture.scene, fixture.camera_node, fixture.view)!;
    return fixture.renderer.finish_view(fixture.view);
}

fn void? fill_frame(Fixture* fixture, TextureId texture, Vec4 color) @private {
    fixture.renderer.begin_frame()!;
    defer catch render::abort_frame(&fixture.renderer);
    fill(fixture, texture, color)!;
    return fixture.renderer.end_frame();
}

fn void? sample_frame(Fixture* fixture, DispatchTexture source, Vec2 uv = CENTER_UV) @private {
    fixture.renderer.begin_frame()!;
    defer catch render::abort_frame(&fixture.renderer);
    sample(fixture, source, uv)!;
    record_readback(fixture)!;
    return fixture.renderer.end_frame();
}

fn uint? run_camera_motion(Fixture* fixture, Camera camera) @private {
    Renderer* renderer = &fixture.renderer;
    *fixture.scene.get(fixture.camera_node, Camera) = camera;
    fixture.camera_node.local = maths::TRANSFORM_IDENTITY;
    fixture.camera_node.local.position = CAMERA_POSITION;
    fixture.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    render_view_and_finish(fixture)!;
    renderer.end_frame()!;

    fixture.camera_node.local.position.x += CAMERA_SLIDE;
    fixture.camera_node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(CAMERA_TURN_DEGREES));
    fixture.scene.update_world();
    renderer.begin_frame()!;
    renderer.render_view(&fixture.scene, fixture.camera_node, fixture.view)!;
    sample(fixture, render::read_view_color(fixture.view))!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn uint read_pixel(Fixture* fixture) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::invalidate_mapped_span(&fixture.renderer.device, fixture.readback.span)!!;
    return ((SampleOutput*)fixture.readback.bytes.ptr).pixel;
}

fn void check_channels(uint pixel, Vec4 expected) @private {
    for (uint channel = 0; channel < 4; channel++) {
        int actual = (int)((pixel >> (8 * channel)) & 0xff);
        int wanted = (int)(expected[channel] * 255 + 0.5f);
        assert(math::abs(actual - wanted) <= CHANNEL_TOLERANCE);
    }
}

fn void check_solid_red(uint pixel) @private {
    io::eprintfn("blurred box center: %08x", pixel);
    float red = (float)(pixel & 0xff) / 255;
    assert(red >= BLURRED_CENTER_MINIMUM);
    assert((pixel & PIXEL_ALPHA_MASK) == PIXEL_ALPHA_MASK);
}

fn void check_opaque_color(uint pixel) @private {
    assert(pixel & PIXEL_COLOR_MASK);
    assert((pixel & PIXEL_ALPHA_MASK) == PIXEL_ALPHA_MASK);
}

fn void test_render_to_writes_both_output_modes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    Renderer* renderer = &fixture.renderer;

    renderer.begin_frame()!!;
    fill(&fixture, fixture.storage_texture, WARM)!!;
    renderer.end_frame()!!;

    renderer.render_to(&fixture.scene, fixture.camera_node, fixture.hdr_target)!!;
    sample_frame(&fixture, render::read_target(fixture.hdr_target))!!;
    check_channels(read_pixel(&fixture), WARM);

    renderer.render_to(&fixture.scene, fixture.camera_node, fixture.ldr_target, OutputMode.DISPLAY_LDR)!!;
    sample_frame(&fixture, render::read_target(fixture.ldr_target))!!;
    check_opaque_color(read_pixel(&fixture));
    check_validation(renderer);
}

fn void test_render_to_failure_closes_the_frame_and_frees_the_view() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Node* empty = fixture.scene.add_node()!!;

    for (uint attempt = 0; attempt <= render::VIEW_CAPACITY; attempt++) {
        if (catch excuse = renderer.render_to(&fixture.scene, empty, fixture.hdr_target)) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "render_to accepted a node without a camera");
        }
        assert(!renderer.frame_open);
    }

    renderer.render_to(&fixture.scene, fixture.camera_node, fixture.hdr_target)!!;
    check_validation(renderer);
}

fn void test_warm_standalone_frames_submit_and_empty_frames_do_not() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    renderer.begin_frame()!!;
    fill(&fixture, fixture.storage_texture, RED)!!;
    render_view_and_finish(&fixture)!!;
    renderer.end_frame()!!;

    renderer.begin_frame()!!;
    renderer.draw_fullscreen(fixture.hdr_target, { .shader = GRADIENT })!!;
    renderer.end_frame()!!;
    assert(renderer.frame_submitted);

    renderer.begin_frame()!!;
    fill(&fixture, fixture.storage_texture, WARM)!!;
    renderer.end_frame()!!;
    assert(renderer.frame_submitted);

    renderer.begin_frame()!!;
    renderer.end_frame()!!;
    assert(!renderer.frame_submitted);

    sample_frame(&fixture, render::read_texture(fixture.storage_texture))!!;
    check_channels(read_pixel(&fixture), WARM);
    check_validation(renderer);
}

fn void test_storage_texture_upload_write_sample_and_abort_keep_layouts_valid() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    renderer.begin_frame()!!;
    fill(&fixture, fixture.storage_texture, RED)!!;
    render_view_and_finish(&fixture)!!;
    renderer.end_frame()!!;

    renderer.begin_frame()!!;
    fill(&fixture, fixture.storage_texture, GREEN)!!;
    fill(&fixture, fixture.storage_texture, BLUE)!!;
    render_view_and_finish(&fixture)!!;
    renderer.end_frame()!!;

    TextureId late = fixture.assets.add_texture_empty(storage_texture_desc("acceptance_late"))!!;
    renderer.begin_frame()!!;
    fill(&fixture, late, RED)!!;
    render::abort_frame(renderer);

    renderer.begin_frame()!!;
    fill(&fixture, late, COOL)!!;
    render_view_and_finish(&fixture)!!;
    sample(&fixture, render::read_texture(late))!!;
    record_readback(&fixture)!!;
    renderer.end_frame()!!;
    check_channels(read_pixel(&fixture), COOL);
    check_validation(renderer);
}

fn void test_two_scenes_with_matching_ids_get_distinct_deformation_blocks() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    DeformedScene first = create_deformed_scene(&fixture, { 0, 0, 0 }, 0.25f)!!;
    defer scene::destroy_scene(&first.scene);
    DeformedScene second = create_deformed_scene(&fixture, { 1, 0, 0 }, 0.75f)!!;
    defer scene::destroy_scene(&second.scene);
    assert(first.mesh.id.index == second.mesh.id.index);

    renderer.begin_frame()!!;
    renderer.render_view(&first.scene, first.camera, fixture.view)!!;
    renderer.render_view(&second.scene, second.camera, fixture.second_view)!!;
    assert(renderer.deformation.palettes.len() == 2);
    assert(renderer.deformation.morph_blocks.len() == 2);
    gpu::GpuAddress first_palette = renderer.deformation.palettes.get((ulong)(uptr)first.mesh)!!;
    gpu::GpuAddress second_palette = renderer.deformation.palettes.get((ulong)(uptr)second.mesh)!!;
    assert((ulong)first_palette != (ulong)second_palette);
    renderer.finish_view(fixture.view)!!;
    renderer.finish_view(fixture.second_view)!!;
    renderer.end_frame()!!;
    check_validation(renderer);
}

fn void test_view_history_publishes_on_submit_and_drops_on_abort() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    enable_motion_blur(&fixture, fixture.view)!!;
    enable_motion_blur(&fixture, fixture.second_view)!!;
    DeformedScene moving = create_deformed_scene(&fixture, { 0, 0, 0 }, 0.5f)!!;
    defer scene::destroy_scene(&moving.scene);
    ViewRecord* first = renderer.views.get(fixture.view);
    ViewRecord* second = renderer.views.get(fixture.second_view);

    renderer.begin_frame()!!;
    renderer.render_view(&moving.scene, moving.camera, fixture.view)!!;
    renderer.finish_view(fixture.view)!!;
    assert(first.history.pending && !first.history.valid);
    renderer.end_frame()!!;
    assert(first.history.valid && first.history.has_previous(&moving.scene, moving.mesh));

    renderer.begin_frame()!!;
    renderer.render_view(&moving.scene, moving.camera, fixture.view)!!;
    render::abort_frame(renderer);
    assert(!first.history.valid && !first.history.pending);

    renderer.begin_frame()!!;
    renderer.render_view(&moving.scene, moving.camera, fixture.second_view)!!;
    renderer.finish_view(fixture.second_view)!!;
    renderer.end_frame()!!;
    assert(second.history.valid && !first.history.valid);

    renderer.begin_frame()!!;
    renderer.render_view(&moving.scene, moving.camera, fixture.view)!!;
    renderer.finish_view(fixture.view)!!;
    renderer.end_frame()!!;
    assert(first.history.valid);
    check_validation(renderer);
}

fn void test_orthographic_background_velocity_keeps_the_box_solid() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    enable_motion_blur(&fixture, fixture.view)!!;

    uint orthographic = run_camera_motion(&fixture, camera::orthographic(ORTHOGRAPHIC_HEIGHT, 0.1f, 100))!!;
    check_solid_red(orthographic);

    render::reset_view_history(renderer, fixture.view)!!;
    uint perspective = run_camera_motion(&fixture, camera::perspective_deg(60, 0.1f))!!;
    check_solid_red(perspective);
    check_validation(renderer);
}

fn void test_shared_material_resolves_once_per_view_and_pipelines_once_per_item() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    DeformedScene shared = create_shared_material_scene(&fixture, SHARED_BOX_COUNT)!!;
    defer scene::destroy_scene(&shared.scene);

    for (uint frame = 0; frame < 2; frame++) {
        renderer.begin_frame()!!;
        renderer.render_view(&shared.scene, shared.camera, fixture.view)!!;
        renderer.render_view(&shared.scene, shared.camera, fixture.second_view)!!;
        assert(renderer.stats.material_resolutions == 2);
        assert(renderer.stats.pipeline_lookups == 2 * SHARED_BOX_COUNT);
        renderer.finish_view(fixture.view)!!;
        renderer.finish_view(fixture.second_view)!!;
        renderer.end_frame()!!;
        fixture.assets.mark_material_dirty(fixture.material);
    }
    check_validation(renderer);
}

fn void test_shadowed_deformed_scene_draws_with_prepared_pipelines() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    DeformedScene moving = create_deformed_scene(&fixture, { 0, 0, 0 }, 0.5f)!!;
    defer scene::destroy_scene(&moving.scene);
    Light sunlight = light::directional({ 1, 1, 1 }, 2);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = 10;
    moving.scene.add_light(sunlight)!!;
    moving.scene.update_world();

    renderer.begin_frame()!!;
    renderer.render_view(&moving.scene, moving.camera, fixture.view)!!;
    assert(renderer.stats.shadow_layers == 1);
    assert(renderer.stats.pipeline_lookups == 2);
    renderer.finish_view(fixture.view)!!;
    renderer.end_frame()!!;
    check_validation(renderer);
}

fn void test_supplied_mips_upload_exact_bytes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    char[16] mip0;
    for (usz pixel = 0; pixel < 4; pixel++) {
        mip0[pixel * 4] = 255;
        mip0[pixel * 4 + 1] = 128;
        mip0[pixel * 4 + 2] = 64;
        mip0[pixel * 4 + 3] = 255;
    }
    char[4] mip1 = { 64, 128, 255, 255 };
    TextureMipData[2] levels = {
        { .mip = 0, .layer = 0, .bytes = mip0[..] },
        { .mip = 1, .layer = 0, .bytes = mip1[..] },
    };
    material::TextureDesc desc = {
        .width      = 2,
        .height     = 2,
        .layers     = 1,
        .format     = PixelFormat.RGBA8_UNORM,
        .mip_levels = 2,
        .debug_name = "acceptance_supplied",
    };
    TextureId supplied = fixture.assets.add_texture_mips(desc, levels[..])!!;

    renderer.upload_texture(supplied)!!;
    sample_frame(&fixture, render::read_texture(supplied))!!;
    check_channels(read_pixel(&fixture), WARM);
    check_validation(renderer);
}

fn void test_small_upload_ring_frees_overflow_when_the_slot_is_reused() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, TINY_RING_BYTES)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    DeformedScene crowd = create_shared_material_scene(&fixture, OVERFLOW_BOX_COUNT)!!;
    defer scene::destroy_scene(&crowd.scene);

    for (uint frame = 0; frame < 4; frame++) {
        renderer.begin_frame()!!;
        Frame* slot = &renderer.frames[renderer.recording_slot];
        assert(slot.upload.overflow.len() == 0);
        render_view_and_finish(&fixture)!!;
        renderer.render_view(&crowd.scene, crowd.camera, fixture.second_view)!!;
        renderer.finish_view(fixture.second_view)!!;
        if (frame == 0) assert(slot.upload.overflow.len() > 0);
        renderer.end_frame()!!;
    }
    render::wait_frames(renderer)!!;
    foreach (&slot : renderer.frames) assert(slot.upload.mapped.bytes.len > TINY_RING_BYTES);
    check_validation(renderer);
}

fn void test_skinned_geometry_without_binding_draws_unskinned() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    fill_frame(&fixture, fixture.storage_texture, RED)!!;
    Scene unbound = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer scene::destroy_scene(&unbound);
    unbound.add_mesh(fixture.deformed_box, fixture.material)!!;
    Node* camera = unbound.add_camera(camera::perspective_deg(60, 0.1f))!!;
    camera.local.position = CAMERA_POSITION;
    unbound.update_world();

    renderer.begin_frame()!!;
    renderer.render_view(&unbound, camera, fixture.view)!!;
    renderer.finish_view(fixture.view)!!;
    renderer.end_frame()!!;
    sample_frame(&fixture, render::read_target(fixture.hdr_target))!!;
    check_channels(read_pixel(&fixture), RED);
    check_validation(renderer);
}

fn void test_vertex_colors_tint_the_built_in_shading_and_cut_masked_alpha() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene tinted = create_single_box_scene(&fixture, fixture.colored_box, fixture.plain, false)!!;
    defer scene::destroy_scene(&tinted.scene);
    DeformedScene faded = create_single_box_scene(&fixture, fixture.faded_box, fixture.masked, true)!!;
    defer scene::destroy_scene(&faded.scene);

    renderer.begin_frame()!!;
    renderer.render_view(&tinted.scene, tinted.camera, fixture.view)!!;
    sample(&fixture, render::read_view_color(fixture.view))!!;
    record_readback(&fixture)!!;
    renderer.finish_view(fixture.view)!!;
    renderer.end_frame()!!;
    check_channels(read_pixel(&fixture), GREEN);

    renderer.begin_frame()!!;
    renderer.render_view(&faded.scene, faded.camera, fixture.view)!!;
    sample(&fixture, render::read_view_color(fixture.view))!!;
    record_readback(&fixture)!!;
    renderer.finish_view(fixture.view)!!;
    renderer.end_frame()!!;
    check_channels(read_pixel(&fixture), { 0, 0, 0, 1 });
    assert(renderer.stats.shadow_layers == 1);
    check_validation(renderer);
}
