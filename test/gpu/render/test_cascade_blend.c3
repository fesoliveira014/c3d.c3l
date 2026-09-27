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

const char[*] LINE_SOURCE @private = $embed("line.comp.glsl");
const uint  LINE_WIDTH @private = 32;
const uint  LINE_HEIGHT @private = 1024; // tall and narrow, so the thin depth band spans several rows
const uint  LINE_GROUP_SIZE @private = 64; // mirrored as local_size_x in line.comp.glsl
const uint  BLEND_SHADOW_RESOLUTION @private = 256;
const float BLEND_FOV_DEGREES @private = 60;
const float BLEND_CAMERA_HEIGHT @private = 3;
const float BLEND_CAMERA_PITCH_DEGREES @private = -30; // the top row meets the horizon
const float ROD_HEIGHT @private = 0.5f; // a 45 degree sun lays the rod's shadow this far along +X
const float ROD_WIDTH @private = 0.12f; // about two texels of the near cascade, under one of the far cascade
const float ROD_LENGTH @private = 60;
const float GROUND_SIZE @private = 200;
const float SHADOW_DISTANCE @private = 40;
const float TEST_BLEND @private = 0.1f;
const float LINE_LEAD @private = 1; // meters of depth before the band the line starts at
const float LINE_TRAIL @private = 2; // meters of depth after the split the line ends at
const float MINIMUM_SPLIT_STEP @private = 0.01f; // below it the scene shows no seam to smooth

struct LineRoot @private {
    gpu::GpuAddress output_address;
    Vec2 uv_start;
    Vec2 uv_step;
    uint count;
    uint padding;
}
$assert LineRoot::size == 32;

struct BlendFixture @private {
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    Node* camera_node;
    Node* sun;
    ComputeShaderId line_shader;
    BufferId output;
    RenderTargetId target;
    ViewId view;
    gpu::MappedGpuSpan readback;
}

fn void? create_blend_fixture(BlendFixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    @pool() {
        Geometry ground = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        GeometryId ground_geometry = fixture.assets.add_geometry(&ground)!;
        Geometry rod = geometry::box(
            allocator: tmem,
            width: ROD_WIDTH,
            height: ROD_WIDTH,
            depth: ROD_LENGTH,
        );
        GeometryId rod_geometry = fixture.assets.add_geometry(&rod)!;
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.metallic = 0;
        MaterialId matte = fixture.assets.add_material(material::standard(params))!;
        fixture.scene.add_mesh(ground_geometry, matte)!;
        Node* rod_node = fixture.scene.add_mesh(rod_geometry, matte)!;
        rod_node.local.position = { 0, ROD_HEIGHT, 5 - ROD_LENGTH / 2 };
    };

    Light sunlight = light::directional({ 1, 1, 1 }, 2);
    sunlight.shadow.cascades = 2;
    sunlight.shadow.cascade_lambda = 0.5f;
    sunlight.shadow.max_distance = SHADOW_DISTANCE;
    fixture.sun = fixture.scene.add_light(sunlight)!;
    fixture.sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, (Vec3){ 1, -1, 0 }.normalize());
    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(BLEND_FOV_DEGREES, 0.1f))!;
    fixture.camera_node.local.position = { ROD_HEIGHT, BLEND_CAMERA_HEIGHT, 0 };
    fixture.camera_node.local.rotation = quaternion::from_axis_angle{float}(
        { 1, 0, 0 },
        math::deg_to_rad(BLEND_CAMERA_PITCH_DEGREES),
    );
    fixture.scene.update_world();

    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)LINE_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
    )!;
    defer free(spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    fixture.line_shader = fixture.assets.add_compute_shader(&shader_desc)!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .shadow_resolution = BLEND_SHADOW_RESOLUTION,
            .max_shadow_layers = 2,
            .application_name = "cascade_blend_acceptance",
        },
    )!;
    fixture.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(LINE_WIDTH, LINE_HEIGHT),
    )!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(fixture.target))!;
    fixture.output = fixture.renderer.create_buffer({
        .size = LINE_HEIGHT * float::size,
        .debug_name = "cascade_blend_line",
    })!;
    gpu::AllocationDesc readback_desc = {
        .size = LINE_HEIGHT * float::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "cascade_blend_readback",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
}

fn void destroy_blend_fixture(BlendFixture* fixture) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = fixture.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    check_validation(&fixture.renderer);
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

// Row 0 is the top of the image; each value is the luminance at the column pair's centre.
fn void? render_center_column(BlendFixture* fixture, float blend, float[] luminance) @private {
    fixture.scene.get(fixture.sun, Light).shadow.cascade_blend = blend;
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, fixture.camera_node, fixture.view)!;
    LineRoot root = {
        .output_address = renderer.buffer_address(fixture.output),
        .uv_start = { 0.5f, 0.5f / LINE_HEIGHT },
        .uv_step = { 0, 1.0f / LINE_HEIGHT },
        .count = LINE_HEIGHT,
    };
    BufferId[1] writes = { fixture.output };
    DispatchTexture[1] textures = { render::read_view_color(fixture.view) };
    renderer.dispatch({
        .shader = fixture.line_shader,
        .root = ((char*)&root)[:LineRoot::size],
        .groups = { LINE_HEIGHT / LINE_GROUP_SIZE, 1, 1 },
        .writes = writes[..],
        .textures = textures[..],
    })!;
    gpu::Barrier copied_writes = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied_writes)!;
    gpu::BufferCopyDesc buffer_copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(fixture.output).allocation)!,
        .dst = fixture.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &buffer_copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;

    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, fixture.readback.span)!;
    luminance[..] = ((float*)fixture.readback.bytes.ptr)[:LINE_HEIGHT];
}

// Camera-space depth of the ground under the centre of each row.
fn void ground_depths(BlendFixture* fixture, float[] depths) @private {
    Camera camera = *fixture.scene.get(fixture.camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(camera, fixture.camera_node.world, { LINE_WIDTH, LINE_HEIGHT });
    Vec3 origin = maths::translation(fixture.camera_node.world);
    foreach (row, &depth : depths) {
        float ndc_y = 1 - 2 * ((float)row + 0.5f) / LINE_HEIGHT;
        Vec4 near_point = matrices.inv_view_proj.apply({ 0, ndc_y, 1, 1 });
        Vec3 direction = (near_point.xyz / near_point.w - origin).normalize();
        *depth = float::max;
        if (direction.y >= 0) continue;
        Vec3 ground = origin + direction * (-origin.y / direction.y);
        *depth = -maths::transform_point(matrices.view, ground).z;
    }
}

fn void test_cascade_blend_smooths_the_split() @test {
    BlendFixture fixture;
    create_blend_fixture(&fixture)!!;
    defer destroy_blend_fixture(&fixture);

    Camera camera = *fixture.scene.get(fixture.camera_node, Camera);
    ShadowSettings settings = fixture.scene.get(fixture.sun, Light).shadow;
    CascadeSplits splits = render::directional_cascade_splits(camera, settings);
    float split = splits.far_depths[0];
    float band_start = render::cascade_blend_depth(splits, 0, TEST_BLEND);
    float[LINE_HEIGHT] depths;
    float[LINE_HEIGHT] direct;
    float[LINE_HEIGHT] blended;
    ground_depths(&fixture, depths[..]);
    render_center_column(&fixture, 0, direct[..])!!;
    render_center_column(&fixture, TEST_BLEND, blended[..])!!;
    io::eprintfn("band %.3f to split %.3f", band_start, split);

    float split_step;
    float largest_blended_step;
    bool band_differs;
    // Rows run bottom to top, so depth grows along the line.
    for (usz row = LINE_HEIGHT - 1; row > 0; row--) {
        float depth = depths[row];
        float next_depth = depths[row - 1];
        if (depth < band_start - LINE_LEAD || next_depth > split + LINE_TRAIL) continue;
        // Past the band start cascade 1's fit is wider at 0.1, so only earlier rows match the direct image.
        if (depth < band_start) assert(direct[row] == blended[row]);
        if (depth > band_start && depth < split && direct[row] != blended[row]) band_differs = true;
        if (depth <= split && next_depth > split) split_step = math::abs(direct[row - 1] - direct[row]);
        largest_blended_step = math::max(largest_blended_step, math::abs(blended[row - 1] - blended[row]));
    }
    io::eprintfn("split step %.5f, largest blended step %.5f", split_step, largest_blended_step);
    assert(split_step > MINIMUM_SPLIT_STEP);
    assert(band_differs);
    assert(largest_blended_step < split_step);
}
