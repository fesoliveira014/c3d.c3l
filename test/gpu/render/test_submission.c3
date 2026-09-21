module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
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

struct FillRoot @private {
    Vec4 color;
    uint size;
    uint[3] padding;
}
$assert FillRoot::size == 32;

struct SampleRoot @private {
    gpu::GpuAddress output_address;
    ulong padding;
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
    ComputeShaderId fill_shader;
    ComputeShaderId sample_shader;
    BufferId output;
    RenderTargetId hdr_target;
    RenderTargetId ldr_target;
    ViewId view;
    gpu::MappedGpuSpan readback;
    bool renderer_alive;
}

fn void? create_fixture(Allocator allocator, Fixture* fixture) @private {
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
        GeometryId geometry_id = fixture.assets.add_geometry(&box)!;
        MaterialId material_id = fixture.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(fixture.storage_texture),
        }))!;
        fixture.scene.add_mesh(geometry_id, material_id)!;
    };
    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    fixture.camera_node.local.position = { 0, 0, 3 };
    fixture.scene.update_world();

    fixture.fill_shader = add_compute_shader(fixture, (String)FILL_SOURCE[..])!;
    fixture.sample_shader = add_compute_shader(fixture, (String)SAMPLE_SOURCE[..])!;

    fixture.renderer = render::create_renderer(
        allocator: allocator,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .shadow_resolution = 64,
            .max_shadow_layers = 1,
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

fn void? sample(Fixture* fixture, DispatchTexture source) @private {
    SampleRoot root = { .output_address = fixture.renderer.buffer_address(fixture.output) };
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

fn void? sample_frame(Fixture* fixture, DispatchTexture source) @private {
    fixture.renderer.begin_frame()!;
    defer catch render::abort_frame(&fixture.renderer);
    sample(fixture, source)!;
    record_readback(fixture)!;
    return fixture.renderer.end_frame();
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
