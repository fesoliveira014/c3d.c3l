module c3d::render::acceptance;

import c3d;
import c3d::render @public;
import c3d::shader;
import c3d::shader::compile;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;

const char[*] OPTICAL_VERTEX @private = $embed("optical_throughput.vert.glsl");
const char[*] OPTICAL_FRAGMENT @private = $embed("optical_throughput.frag.glsl");
const char[*] OPTICAL_SURFACE_SOURCE @private = $embed("optical_throughput.surface.glsl");
const uint OPTICAL_EXTENT @private = 64;
const uint OPTICAL_TILE_WIDTH @private = 8;
const uint OPTICAL_TILE_COLUMNS @private = OPTICAL_EXTENT / OPTICAL_TILE_WIDTH;
const uint OPTICAL_MATRIX_CAPACITY @private = OPTICAL_TILE_COLUMNS * OPTICAL_TILE_COLUMNS;
const double OPTICAL_ABSOLUTE_TOLERANCE @private = 0.002;
const double OPTICAL_RELATIVE_TOLERANCE @private = 0.005;
const uint OPTICAL_ALPHA_BLEND @private = 1;
const uint OPTICAL_ALPHA_MASK @private = 2;
const uint OPTICAL_ADDITIVE @private = 4;
const uint OPTICAL_CAST_OFF @private = 8;
const gpu::TextureState OPTICAL_TRANSFER_SOURCE @private = {
    .layout = gpu::TextureLayout.TRANSFER_SOURCE,
    .stages = { .transfer },
    .access = { .read },
};

struct OpticalSurface @private {
    Vec4 bounds;
    Vec4 base_coverage;
    Vec4 factors;
    Vec4 specular_cosine;
    Vec4 attenuation_distance;
    Vec4 normal_thickness;
    Vec4 model_scale;
    Vec4 plane;
    uint node_index;
    uint node_generation;
    uint part_index;
    uint range_index;
    uint instance_index;
    uint primitive_index;
    uint flags;
    uint map;
}
$assert OpticalSurface::size == 160;
$assert $reflect(OpticalSurface.flags).offset == 152;

struct OpticalDraw @private {
    gpu::GpuAddress surfaces;
    uint first;
    uint phase;
    uint previous;
    uint selected;
    uint source;
    uint sampler_index;
    uint enabled;
    float receiver_depth;
    uint[2] padding;
}
$assert OpticalDraw::size == 48;

struct OpticalResources @private {
    Target surface;
    gpu::PipelineHandle evaluate;
    gpu::MappedGpuSpan readback;
}

fn char[]? compile_optical_source(String source, ShaderStage stage, String name) @private {
    asset::ShaderInclude[1] includes = {{
        .name = "optical_throughput.surface.glsl",
        .text = (String)OPTICAL_SURFACE_SOURCE[..],
    }};
    String log;
    char[]? result = compile::compile_glsl(
        allocator: mem,
        source: source,
        stage: stage,
        debug_name: name,
        log: &log,
        includes: includes[..],
    );
    defer free(log.ptr);
    if (catch excuse = result) {
        io::eprintfn("%s shader compilation failed:\n%s", name, log);
        return excuse~;
    }
    return result;
}

fn Target? create_optical_target(gpu::Device* device, gpu::Format format, bool depth = false) @private {
    gpu::TextureDesc desc = {
        .width = OPTICAL_EXTENT,
        .height = OPTICAL_EXTENT,
        .format = format,
        .usage = depth ? (gpu::TextureUsage){ .depth_attach, .sampled, .transfer_src }
          : (gpu::TextureUsage){ .color_attach, .sampled, .transfer_src },
        .access = { .graphics },
        .debug_name = "optical_throughput",
    };
    Target target = { .width = desc.width, .height = desc.height, .format = format };
    target.texture = gpu::create_texture(device, &desc)!;
    defer catch (void)gpu::destroy_texture(device, target.texture);
    gpu::AttachmentViewDesc attachment = { .texture = target.texture };
    target.attachment = gpu::create_attachment_view(device, &attachment)!;
    defer catch (void)gpu::destroy_attachment_view(device, target.attachment);
    target.view = gpu::create_texture_view(device, target.texture, null)!;
    return target;
}

fn void destroy_optical_target(gpu::Device* device, Target* target) @private {
    if (!target.texture.is_valid()) return;

    gpu::destroy_texture_view(device, target.view)!!;
    gpu::destroy_attachment_view(device, target.attachment)!!;
    gpu::destroy_texture(device, target.texture)!!;
    *target = {};
}

fn void destroy_optical_resources(Renderer* renderer, OpticalResources* resources) @private {
    render::wait_frames(renderer)!!;
    destroy_optical_target(&renderer.device, &resources.surface);
    if (resources.evaluate.is_valid()) gpu::destroy_pipeline(&renderer.device, resources.evaluate)!!;
    if (resources.readback.bytes.len) {
        gpu::GpuAllocation allocation = resources.readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    *resources = {};
}

fn void? create_optical_resources(Renderer* renderer, OpticalResources* resources) @private {
    defer catch destroy_optical_resources(renderer, resources);
    resources.surface = create_optical_target(&renderer.device, gpu::Format.RGBA32_FLOAT)!;
    char[] vertex = compile_optical_source(
        source: (String)OPTICAL_VERTEX[..],
        stage: ShaderStage.VERTEX,
        name: "optical_surface_vertex",
    )!;
    defer free(vertex.ptr);
    char[] fragment = compile_optical_source(
        source: (String)OPTICAL_FRAGMENT[..],
        stage: ShaderStage.FRAGMENT,
        name: "optical_surface_fragment",
    )!;
    defer free(fragment.ptr);
    gpu::Format[1] formats = { gpu::Format.RGBA32_FLOAT };
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader = { .spirv = vertex },
        .fragment_shader = { .spirv = fragment },
        .color_formats = formats[..],
        .debug_name = "optical_surface_evaluation",
    };
    resources.evaluate = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    gpu::AllocationDesc readback = {
        .size = (usz)OPTICAL_EXTENT * OPTICAL_EXTENT * Vec4::size,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "optical_surface_readback",
    };
    resources.readback = gpu::allocate_mapped_memory(&renderer.device, &readback)!;
}

fn gpu::GpuAddress? write_optical_bytes(Renderer* renderer, char[] bytes) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, bytes.len)!;
    mem::copy(upload.bytes.ptr, bytes.ptr, (sz)bytes.len);
    return upload.address;
}

fn OpticalSurface optical_default_surface() @private {
    return {
        .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
        .base_coverage = { 0.8f, 0.6f, 0.4f, 0.5f },
        .factors = { 1, 0, 1.5f, 1 },
        .specular_cosine = { 1, 1, 1, 1 },
        .attenuation_distance = { 0.5f, 0.25f, 0.125f, 2 },
        .normal_thickness = { 0, 0, 1, 1 },
        .model_scale = { 1, 1, 1, 0.5f },
        .plane = { 0, 0, 0.5f, 0 },
        .node_generation = 1,
        .flags = OPTICAL_ALPHA_BLEND,
    };
}

fn transparency_fixtures::Color optical_expected_surface(OpticalSurface surface) @private {
    double alpha = surface.base_coverage.w;
    if ((surface.flags & OPTICAL_CAST_OFF) != 0) return { 1, 1, 1 };
    if ((surface.flags & OPTICAL_ALPHA_MASK) != 0 && alpha < surface.plane.z) return { 1, 1, 1 };
    if ((surface.flags & OPTICAL_ALPHA_BLEND) != 0 && surface.factors.x == 0) return { 1, 1, 1 };

    double normal_length = math::sqrt((double)surface.normal_thickness.x * surface.normal_thickness.x
      + (double)surface.normal_thickness.y * surface.normal_thickness.y
      + (double)surface.normal_thickness.z * surface.normal_thickness.z);
    double sine = (double)surface.normal_thickness.x / normal_length;
    double cosine = (double)surface.normal_thickness.z / normal_length;
    double eta = 1.0 / surface.factors.z;
    double transmitted_cosine = math::sqrt(1 - eta * eta * (1 - cosine * cosine));
    double ray_x = (eta * cosine - transmitted_cosine) * sine;
    double ray_z = -eta + (eta * cosine - transmitted_cosine) * cosine;
    double ray_length = math::sqrt(ray_x * ray_x + ray_z * ray_z);
    ray_x = ray_x / ray_length * surface.normal_thickness.w * surface.model_scale.x;
    ray_z = ray_z / ray_length * surface.normal_thickness.w * surface.model_scale.z;
    double distance = math::sqrt(ray_x * ray_x + ray_z * ray_z);
    double ratio = ((double)surface.factors.z - 1) / ((double)surface.factors.z + 1);
    double complement = 1 - cosine;
    double grazing = complement * complement * complement * complement * complement;
    double coverage = (surface.flags & OPTICAL_ALPHA_BLEND) != 0 ? alpha : 1;
    transparency_fixtures::Color throughput;
    for (uint channel = 0; channel < 3; channel++) {
        double normal_reflectance = math::min(1.0, ratio * ratio * surface.specular_cosine[channel])
          * surface.factors.w;
        double fresnel = normal_reflectance + ((double)surface.factors.w - normal_reflectance) * grazing;
        double absorption = surface.attenuation_distance.w == 0 || distance == 0 ? 1.0
          : math::exp(math::ln((double)surface.attenuation_distance[channel])
              * distance / surface.attenuation_distance.w);
        double transmitted = (double)surface.factors.x * (1 - (double)surface.factors.y)
          * surface.base_coverage[channel] * (1 - fresnel) * absorption;
        throughput[channel] = (1 - coverage) + coverage * transmitted;
    }
    return throughput;
}

fn uint make_optical_surface_matrix(OpticalSurface[] output) @private {
    uint count;
    OpticalSurface base = optical_default_surface();
    foreach (value : transparency_fixtures::TRANSMISSION_VALUES) {
        output[count] = base;
        output[count++].factors.x = (float)value;
    }
    foreach (value : transparency_fixtures::METALLIC_VALUES) {
        output[count] = base;
        output[count++].factors.y = (float)value;
    }
    foreach (ior : (float[2]){ 1, 1.5f }) {
        output[count] = base;
        output[count++].factors.z = ior;
    }
    foreach (thickness : (float[3]){ 0, 1, 2 }) {
        output[count] = base;
        output[count++].normal_thickness.w = thickness;
    }
    foreach (degrees : (float[3]){ 0, 30, 60 }) {
        float angle = degrees * (float)math::PI / 180;
        output[count] = base;
        output[count++].normal_thickness = { math::sin(angle), 0, math::cos(angle), 1 };
    }
    foreach (scale : (Vec3[3]){ { 1, 1, 1 }, { 2, 2, 2 }, { 2, 1, 0.5f } }) {
        output[count] = base;
        output[count++].model_scale = { scale.x, scale.y, scale.z, 0.5f };
    }
    foreach (alpha : transparency_fixtures::COVERAGE_MAP) {
        output[count] = base;
        output[count++].base_coverage.w = (float)alpha;
    }
    foreach (alpha : transparency_fixtures::COVERAGE_MAP) {
        output[count] = base;
        output[count].flags = OPTICAL_ALPHA_MASK;
        output[count++].base_coverage.w = (float)alpha;
    }
    output[count] = base;
    output[count++].attenuation_distance.w = 0;
    output[count] = base;
    output[count++].factors.w = 0;
    output[count] = base;
    output[count++].specular_cosine = { 0.25f, 0.5f, 1, 1 };
    output[count] = base;
    output[count++].flags |= OPTICAL_ADDITIVE;
    output[count] = base;
    output[count++].flags |= OPTICAL_CAST_OFF;
    foreach (uint index, &surface : output[:count]) {
        uint column = index % OPTICAL_TILE_COLUMNS;
        uint row = index / OPTICAL_TILE_COLUMNS;
        surface.bounds = {
            -1 + 2 * (float)column / OPTICAL_TILE_COLUMNS,
            1 - 2 * (float)(row + 1) / OPTICAL_TILE_COLUMNS,
            -1 + 2 * (float)(column + 1) / OPTICAL_TILE_COLUMNS,
            1 - 2 * (float)row / OPTICAL_TILE_COLUMNS,
        };
        surface.node_index = index;
    }
    return count;
}

fn void? run_optical_surface_matrix(Renderer* renderer, OpticalResources* resources, OpticalSurface[] cases) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::GpuAddress surfaces = write_optical_bytes(renderer, ((char*)cases.ptr)[:cases.len * OpticalSurface::size])!;
    resources.surface.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[1] colors = {{
        .view = resources.surface.attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 1, 1, 1, 1 } },
    }};
    gpu::RenderPassDesc pass = { .colors = colors[..] };
    gpu::cmd_bind_pipeline(&renderer.commands, resources.evaluate)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::ColorTargetState[1] blends = { gpu::color_blend_disabled() };
    gpu::GraphicsState state = gpu::render_geometry_state(OPTICAL_EXTENT, OPTICAL_EXTENT)!;
    state.viewport = {
        .y = OPTICAL_EXTENT, .width = OPTICAL_EXTENT,
        .height = -(float)OPTICAL_EXTENT, .max_depth = 1,
    };
    state.color.targets = blends[..];
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    for (uint index = 0; index < cases.len; index++) {
        OpticalDraw draw = { .surfaces = surfaces, .first = index };
        gpu::GpuAddress root = write_optical_bytes(renderer, ((char*)&draw)[:OpticalDraw::size])!;
        gpu::cmd_draw(
            commands: &renderer.commands,
            vertex_root: root,
            fragment_root: root,
            vertex_count: 6,
            instance_count: 1,
        )!;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
    resources.surface.transition(&renderer.commands, OPTICAL_TRANSFER_SOURCE)!;
    gpu::TextureBufferCopyDesc copy = { .texture = resources.surface.texture, .dst = resources.readback.span };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, resources.readback.span)!;
}

fn void test_optical_throughput_surface_factors_match_the_independent_light_facing_equation() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    OpticalResources resources;
    create_optical_resources(&fixture.renderer, &resources)!!;
    defer destroy_optical_resources(&fixture.renderer, &resources);
    OpticalSurface[OPTICAL_MATRIX_CAPACITY] cases;
    uint count = make_optical_surface_matrix(cases[..]);
    run_optical_surface_matrix(&fixture.renderer, &resources, cases[:count])!!;
    Vec4* pixels = (Vec4*)resources.readback.bytes.ptr;
    double maximum_error;
    foreach (uint index, surface : cases[:count]) {
        uint column = index % OPTICAL_TILE_COLUMNS * OPTICAL_TILE_WIDTH + OPTICAL_TILE_WIDTH / 2;
        uint row = index / OPTICAL_TILE_COLUMNS * OPTICAL_TILE_WIDTH + OPTICAL_TILE_WIDTH / 2;
        Vec4 actual = pixels[row * OPTICAL_EXTENT + column];
        transparency_fixtures::Color expected = optical_expected_surface(surface);
        for (uint channel = 0; channel < 3; channel++) {
            double error = math::abs((double)actual[channel] - expected[channel]);
            maximum_error = math::max(maximum_error, error);
            assert(math::is_finite(actual[channel])
              && error <= OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[channel]),
              "optical case=%s channel=%s actual=%s expected=%s", index, channel, actual[channel], expected[channel]);
        }
    }
    io::printfn("optical surface rows=%s max_error=%s format=RGBA32_FLOAT", count, maximum_error);
    check_validation(&fixture.renderer);
}
