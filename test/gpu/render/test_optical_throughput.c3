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
const double OPTICAL_INTERMEDIATE_ABSOLUTE_TOLERANCE @private = 0.00002;
const double OPTICAL_INTERMEDIATE_RELATIVE_TOLERANCE @private = 0.0002;
const double OPTICAL_BACKEND_DIFFERENCE_TOLERANCE @private = 0.005;
const uint OPTICAL_ALPHA_BLEND @private = 1;
const uint OPTICAL_ALPHA_MASK @private = 2;
const uint OPTICAL_ADDITIVE @private = 4;
const uint OPTICAL_CAST_OFF @private = 8;
const uint OPTICAL_OPAQUE @private = 16;
const uint OPTICAL_FACE_POLICY @private = 32;
const uint OPTICAL_DOUBLE_SIDED @private = 64;
const uint OPTICAL_REVERSED @private = 128;
const uint OPTICAL_MIRRORED @private = 256;
const uint OPTICAL_GROUP_CAPACITY @private = 16;
const uint OPTICAL_SURFACE_CAPACITY @private = 64;
const uint OPTICAL_VERTEX_COUNT @private = 6;
const uint OPTICAL_RESOLVE_GROUP_SIZE @private = 8;
const uint OPTICAL_CAPTURE_PHASE @private = 1;
const uint OPTICAL_PRODUCT_PHASE @private = 2;
const uint OPTICAL_STORE_PHASE @private = 3;
const uint OPTICAL_OPAQUE_PHASE @private = 4;
const uint OPTICAL_LEGACY_PHASE @private = 5;
const float OPTICAL_RECEIVER_DEPTH @private = 0.0625f;
const usz OPTICAL_SCALAR_BYTES @private = (usz)OPTICAL_EXTENT * OPTICAL_EXTENT * float::size;
const usz OPTICAL_CAPTURE_OFFSET @private = (OPTICAL_GROUP_CAPACITY + 1) * OPTICAL_SCALAR_BYTES;
const usz OPTICAL_SHADE_OFFSET @private = 2 * (OPTICAL_GROUP_CAPACITY + 1) * OPTICAL_SCALAR_BYTES;
const usz OPTICAL_PRODUCT_OFFSET @private = OPTICAL_SHADE_OFFSET + OPTICAL_GROUP_CAPACITY * OPTICAL_SCALAR_BYTES;
const usz OPTICAL_DIRECT_OFFSET @private = OPTICAL_PRODUCT_OFFSET + 2 * OPTICAL_GROUP_CAPACITY * OPTICAL_SCALAR_BYTES;
const usz OPTICAL_SIGNATURE_OFFSET @private = OPTICAL_DIRECT_OFFSET + 2 * OPTICAL_GROUP_CAPACITY * OPTICAL_SCALAR_BYTES;
const usz OPTICAL_STACK_READBACK_BYTES @private = OPTICAL_SIGNATURE_OFFSET
  + 4 * OPTICAL_GROUP_CAPACITY * OPTICAL_SCALAR_BYTES;
const char[*] OPTICAL_RESOLVE_SOURCE @private = $embed("optical_throughput.comp.glsl");
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

struct OpticalResolve @private {
    gpu::GpuAddress output;
    uint capacity;
    uint enabled;
    uint opaque_depth;
    uint legacy_depth;
    uint overflow_depth;
    float receiver_depth;
    uint width;
    uint height;
    uint[OPTICAL_GROUP_CAPACITY] products;
    uint[2] padding;
}
$assert OpticalResolve::size == 112;
$assert $reflect(OpticalResolve.products).offset == 40;

struct OpticalStack @private {
    Target[OPTICAL_GROUP_CAPACITY + 1] depths;
    Target[OPTICAL_GROUP_CAPACITY] products;
    Target opaque_depth;
    Target legacy_depth;
    Target key;
    Target shade_depth;
    Target signature;
    Target group_float;
    Target direct_product;
    gpu::PipelineHandle capture;
    gpu::PipelineHandle accumulate;
    gpu::PipelineHandle store;
    gpu::PipelineHandle resolve;
    gpu::MappedGpuSpan output;
    gpu::MappedGpuSpan readback;
}

fn char[]? compile_optical_source(
    String source,
    ShaderStage stage,
    String name,
    String[] defines = {},
) @private {
    asset::ShaderInclude[1] includes = {{
        .name = "optical_throughput.surface.glsl",
        .text = (String)OPTICAL_SURFACE_SOURCE[..],
    }};
    String log;
    char[]? result = compile::compile_glsl(
        allocator: mem,
        source: source,
        stage: stage,
        defines: defines,
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
            double bound = OPTICAL_INTERMEDIATE_ABSOLUTE_TOLERANCE
              + OPTICAL_INTERMEDIATE_RELATIVE_TOLERANCE * math::abs(expected[channel]);
            assert(math::is_finite(actual[channel]) && error <= bound,
                "optical case=%s channel=%s actual=%s expected=%s", index, channel, actual[channel], expected[channel]);
        }
    }
    io::printfn("optical surface rows=%s max_error=%s format=RGBA32_FLOAT", count, maximum_error);
    check_validation(&fixture.renderer);
}

fn void destroy_optical_stack(Renderer* renderer, OpticalStack* stack) @private {
    render::wait_frames(renderer)!!;
    foreach (&target : stack.depths) destroy_optical_target(&renderer.device, target);
    foreach (&target : stack.products) destroy_optical_target(&renderer.device, target);
    foreach (target : (Target*[7]){ &stack.opaque_depth, &stack.legacy_depth, &stack.key,
        &stack.shade_depth, &stack.signature, &stack.group_float, &stack.direct_product }) {
        destroy_optical_target(&renderer.device, target);
    }
    foreach (pipeline : (gpu::PipelineHandle[4]){ stack.capture, stack.accumulate, stack.store, stack.resolve }) {
        if (pipeline.is_valid()) gpu::destroy_pipeline(&renderer.device, pipeline)!!;
    }
    foreach (span : (gpu::MappedGpuSpan[2]){ stack.output, stack.readback }) {
        if (!span.bytes.len) continue;
        gpu::GpuAllocation allocation = span.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    *stack = {};
}

fn void? create_optical_stack(Renderer* renderer, OpticalStack* stack) @private {
    defer catch destroy_optical_stack(renderer, stack);
    foreach (&target : stack.depths) *target = create_optical_target(&renderer.device, gpu::Format.D32_FLOAT, true)!;
    foreach (&target : stack.products) *target = create_optical_target(&renderer.device, gpu::Format.RGBA16_FLOAT)!;
    stack.opaque_depth = create_optical_target(&renderer.device, gpu::Format.D32_FLOAT, true)!;
    stack.legacy_depth = create_optical_target(&renderer.device, gpu::Format.D32_FLOAT, true)!;
    stack.key = create_optical_target(&renderer.device, gpu::Format.R32_FLOAT)!;
    stack.shade_depth = create_optical_target(&renderer.device, gpu::Format.R32_FLOAT)!;
    stack.signature = create_optical_target(&renderer.device, gpu::Format.RGBA32_FLOAT)!;
    stack.group_float = create_optical_target(&renderer.device, gpu::Format.RGBA32_FLOAT)!;
    stack.direct_product = create_optical_target(&renderer.device, gpu::Format.RGBA16_FLOAT)!;
    char[] vertex = compile_optical_source(
        source: (String)OPTICAL_VERTEX[..],
        stage: ShaderStage.VERTEX,
        name: "optical_group_vertex",
    )!;
    defer free(vertex.ptr);
    String[1] defines = { "OPTICAL_GROUP_OUTPUTS" };
    char[] fragment = compile_optical_source(
        source: (String)OPTICAL_FRAGMENT[..],
        stage: ShaderStage.FRAGMENT,
        name: "optical_group_fragment",
        defines: defines[..],
    )!;
    defer free(fragment.ptr);
    gpu::Format[3] capture_formats = { gpu::Format.R32_FLOAT, gpu::Format.R32_FLOAT, gpu::Format.RGBA32_FLOAT };
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader = { .spirv = vertex },
        .fragment_shader = { .spirv = fragment },
        .color_formats = capture_formats[..],
        .depth_format = gpu::Format.D32_FLOAT,
        .debug_name = "optical_depth_capture",
    };
    stack.capture = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    gpu::Format[3] accumulation_formats = {
        gpu::Format.RGBA32_FLOAT, gpu::Format.R32_FLOAT, gpu::Format.RGBA32_FLOAT,
    };
    desc.color_formats = accumulation_formats[..];
    desc.depth_format = gpu::Format.UNDEFINED;
    desc.debug_name = "optical_full_precision_group";
    stack.accumulate = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    gpu::Format[3] stored_formats = { gpu::Format.RGBA16_FLOAT, gpu::Format.R32_FLOAT, gpu::Format.RGBA32_FLOAT };
    desc.color_formats = stored_formats[..];
    desc.debug_name = "optical_group_store";
    stack.store = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    char[] compute = compile_optical_source(
        source: (String)OPTICAL_RESOLVE_SOURCE[..],
        stage: ShaderStage.COMPUTE,
        name: "optical_visibility_resolve",
    )!;
    defer free(compute.ptr);
    gpu::ComputePipelineDesc resolve = { .shader = { .spirv = compute }, .debug_name = "optical_visibility_resolve" };
    stack.resolve = gpu::create_compute_pipeline(&renderer.device, &resolve)!;
    gpu::AllocationDesc output = {
        .size = 4 * OPTICAL_SCALAR_BYTES,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "optical_visibility_readback",
    };
    stack.output = gpu::allocate_mapped_memory(&renderer.device, &output)!;
    output.size = OPTICAL_STACK_READBACK_BYTES;
    output.debug_name = "optical_group_readback";
    stack.readback = gpu::allocate_mapped_memory(&renderer.device, &output)!;
}

fn void? draw_optical_surface(Renderer* renderer, OpticalDraw draw) @private {
    gpu::GpuAddress root = write_optical_bytes(renderer, ((char*)&draw)[:OpticalDraw::size])!;
    gpu::cmd_draw(
        commands: &renderer.commands,
        vertex_root: root,
        fragment_root: root,
        vertex_count: 6,
        instance_count: 1,
    )!;
}

fn void? read_optical_target(
    Renderer* renderer,
    OpticalStack* stack,
    Target* target,
    usz offset,
    usz bytes,
) @private {
    target.transition(&renderer.commands, OPTICAL_TRANSFER_SOURCE)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = target.texture,
        .dst = stack.readback.span.checked_subspan(offset, bytes)!,
    };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
}

fn void? record_optical_stack_pass(
    Renderer* renderer,
    OpticalStack* stack,
    OpticalDraw draw,
    uint count,
    uint[] order,
    Target* color,
    Target* depth,
    gpu::PipelineHandle pipeline,
    bool product,
) @private {
    color.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    stack.shade_depth.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    stack.signature.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    if (depth) depth.transition(&renderer.commands, render::DEPTH_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[3] colors = {
        {
            .view = color.attachment,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .rgba = product ? (Vec4){ 1, 1, 1, 1 } : (Vec4){} },
        },
        { .view = stack.shade_depth.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE },
        { .view = stack.signature.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE },
    };
    gpu::DepthTargetDesc depth_target;
    if (depth) {
        depth_target = {
            .view = depth.attachment,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .depth = 0 },
        };
    }
    gpu::RenderPassDesc pass = { .colors = colors[..], .depth = depth ? &depth_target : null };
    gpu::ColorTargetState[3] outputs = {
        gpu::color_blend_disabled(), gpu::color_blend_disabled(), gpu::color_blend_disabled(),
    };
    if (product) {
        outputs[0].blend = {
            .enable = true,
            .src_color = gpu::BlendFactor.ZERO,
            .dst_color = gpu::BlendFactor.SRC_COLOR,
            .color_op = gpu::BlendOp.ADD,
            .src_alpha = gpu::BlendFactor.ZERO,
            .dst_alpha = gpu::BlendFactor.ONE,
            .alpha_op = gpu::BlendOp.ADD,
        };
        outputs[2] = gpu::premultiplied_alpha_blend();
    }
    gpu::GraphicsState state = gpu::render_geometry_state(OPTICAL_EXTENT, OPTICAL_EXTENT)!;
    state.viewport = {
        .y = OPTICAL_EXTENT,
        .width = OPTICAL_EXTENT,
        .height = -(float)OPTICAL_EXTENT,
        .max_depth = 1,
    };
    state.color.targets = outputs[..];
    state.raster.front_face = gpu::FrontFace.COUNTER_CLOCKWISE;
    state.depth = { .test_enable = depth != null, .write_enable = depth != null, .compare = gpu::CompareOp.GREATER };
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    for (uint index = 0; index < count; index++) {
        draw.first = order.len ? order[index] : index;
        draw_optical_surface(renderer, draw)!;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.work_recorded = true;
}

fn bool optical_survives(OpticalSurface surface) @private {
    bool front = (surface.flags & OPTICAL_FACE_POLICY) == 0 || (surface.flags & OPTICAL_REVERSED) == 0
      || (surface.flags & OPTICAL_DOUBLE_SIDED) != 0;
    return front && (surface.flags & OPTICAL_CAST_OFF) == 0
      && ((surface.flags & OPTICAL_ALPHA_MASK) == 0 || surface.base_coverage.w >= surface.plane.z);
}

fn bool optical_blocks(OpticalSurface surface) @private {
    return optical_survives(surface) && ((surface.flags & OPTICAL_OPAQUE) != 0
      || ((surface.flags & OPTICAL_ALPHA_BLEND) == 0 && surface.factors.x == 0));
}

fn bool optical_participates(OpticalSurface surface) @private {
    return optical_survives(surface) && (surface.flags & OPTICAL_OPAQUE) == 0 && surface.factors.x > 0;
}

fn void order_optical_surfaces(OpticalSurface[] surfaces, uint[] order) @private {
    transparency_fixtures::DepthFragment[OPTICAL_SURFACE_CAPACITY] fragments;
    foreach (index, surface : surfaces) {
        fragments[index] = {
            .depth = surface.model_scale.w,
            .node_index = surface.node_index,
            .node_generation = surface.node_generation,
            .part_index = surface.part_index,
            .range_index = surface.range_index,
            .instance_index = surface.instance_index,
            .primitive_index = surface.primitive_index,
            .radiance = { (double)index, 0, 0 },
        };
    }
    transparency_fixtures::order_depth_fragments(fragments[:surfaces.len]);
    foreach (index, fragment : fragments[:surfaces.len]) order[index] = (uint)fragment.radiance.x;
}

fn void? run_optical_stack(
    Renderer* renderer,
    OpticalStack* stack,
    OpticalSurface[] surfaces,
    uint capacity,
    bool enabled = true,
    gpu::SamplerIndex sampler = (gpu::SamplerIndex)0,
) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    char[] surface_bytes = ((char*)surfaces.ptr)[:surfaces.len * OpticalSurface::size];
    gpu::GpuAddress address = write_optical_bytes(renderer, surface_bytes)!;
    OpticalDraw draw = {
        .surfaces = address,
        .receiver_depth = OPTICAL_RECEIVER_DEPTH,
        .sampler_index = (uint)sampler,
    };
    uint[OPTICAL_SURFACE_CAPACITY] order;
    order_optical_surfaces(surfaces, order[:surfaces.len]);
    foreach (phase : (uint[2]){ OPTICAL_OPAQUE_PHASE, OPTICAL_LEGACY_PHASE }) {
        draw.phase = phase;
        Target* depth = phase == OPTICAL_OPAQUE_PHASE ? &stack.opaque_depth : &stack.legacy_depth;
        record_optical_stack_pass(
            renderer: renderer,
            stack: stack,
            draw: draw,
            count: (uint)surfaces.len,
            order: {},
            color: &stack.key,
            depth: depth,
            pipeline: stack.capture,
            product: false,
        )!;
        depth.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    }
    for (uint group = 0; group <= capacity; group++) {
        draw.phase = OPTICAL_CAPTURE_PHASE;
        draw.previous = group ? (uint)stack.depths[group - 1].view.index : 0;
        record_optical_stack_pass(
            renderer: renderer,
            stack: stack,
            draw: draw,
            count: (uint)surfaces.len,
            order: {},
            color: &stack.key,
            depth: &stack.depths[group],
            pipeline: stack.capture,
            product: false,
        )!;
        read_optical_target(
            renderer: renderer,
            stack: stack,
            target: &stack.depths[group],
            offset: group * OPTICAL_SCALAR_BYTES,
            bytes: OPTICAL_SCALAR_BYTES,
        )!;
        read_optical_target(
            renderer: renderer,
            stack: stack,
            target: &stack.key,
            offset: OPTICAL_CAPTURE_OFFSET + group * OPTICAL_SCALAR_BYTES,
            bytes: OPTICAL_SCALAR_BYTES,
        )!;
        stack.depths[group].transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    }
    gpu::TextureState compute = { .layout = gpu::TextureLayout.SAMPLED, .stages = { .compute }, .access = { .read } };
    for (uint group = 0; group < capacity; group++) {
        draw.phase = OPTICAL_PRODUCT_PHASE;
        draw.selected = (uint)stack.depths[group].view.index;
        record_optical_stack_pass(
            renderer: renderer,
            stack: stack,
            draw: draw,
            count: (uint)surfaces.len,
            order: order[:surfaces.len],
            color: &stack.group_float,
            depth: null,
            pipeline: stack.accumulate,
            product: true,
        )!;
        read_optical_target(
            renderer: renderer,
            stack: stack,
            target: &stack.shade_depth,
            offset: OPTICAL_SHADE_OFFSET + group * OPTICAL_SCALAR_BYTES,
            bytes: OPTICAL_SCALAR_BYTES,
        )!;
        read_optical_target(
            renderer: renderer,
            stack: stack,
            target: &stack.signature,
            offset: OPTICAL_SIGNATURE_OFFSET + (usz)group * 4 * OPTICAL_SCALAR_BYTES,
            bytes: 4 * OPTICAL_SCALAR_BYTES,
        )!;
        stack.group_float.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
        draw.phase = OPTICAL_STORE_PHASE;
        draw.source = (uint)stack.group_float.view.index;
        record_optical_stack_pass(
            renderer: renderer,
            stack: stack,
            draw: draw,
            count: 1,
            order: {},
            color: &stack.products[group],
            depth: null,
            pipeline: stack.store,
            product: false,
        )!;
        read_optical_target(
            renderer: renderer,
            stack: stack,
            target: &stack.products[group],
            offset: OPTICAL_PRODUCT_OFFSET + (usz)group * 2 * OPTICAL_SCALAR_BYTES,
            bytes: 2 * OPTICAL_SCALAR_BYTES,
        )!;
        stack.products[group].transition(&renderer.commands, compute)!;
        draw.phase = OPTICAL_PRODUCT_PHASE;
        record_optical_stack_pass(
            renderer: renderer,
            stack: stack,
            draw: draw,
            count: (uint)surfaces.len,
            order: order[:surfaces.len],
            color: &stack.direct_product,
            depth: null,
            pipeline: stack.store,
            product: true,
        )!;
        read_optical_target(
            renderer: renderer,
            stack: stack,
            target: &stack.direct_product,
            offset: OPTICAL_DIRECT_OFFSET + (usz)group * 2 * OPTICAL_SCALAR_BYTES,
            bytes: 2 * OPTICAL_SCALAR_BYTES,
        )!;
    }
    stack.opaque_depth.transition(&renderer.commands, compute)!;
    stack.legacy_depth.transition(&renderer.commands, compute)!;
    stack.depths[capacity].transition(&renderer.commands, compute)!;
    OpticalResolve resolve = {
        .output = stack.output.address,
        .capacity = capacity,
        .enabled = enabled ? 1 : 0,
        .opaque_depth = (uint)stack.opaque_depth.view.index,
        .legacy_depth = (uint)stack.legacy_depth.view.index,
        .overflow_depth = (uint)stack.depths[capacity].view.index,
        .receiver_depth = OPTICAL_RECEIVER_DEPTH,
        .width = OPTICAL_EXTENT,
        .height = OPTICAL_EXTENT,
    };
    for (uint group = 0; group < capacity; group++) resolve.products[group] = (uint)stack.products[group].view.index;
    gpu::GpuAddress root = write_optical_bytes(renderer, ((char*)&resolve)[:OpticalResolve::size])!;
    gpu::cmd_bind_pipeline(&renderer.commands, stack.resolve)!;
    uint groups = OPTICAL_EXTENT / OPTICAL_RESOLVE_GROUP_SIZE;
    gpu::cmd_dispatch(&renderer.commands, root, { groups, groups, 1 })!;
    gpu::Barrier host = { .before = { .compute, .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, stack.readback.span)!;
    gpu::invalidate_mapped_span(&renderer.device, stack.output.span)!;
}

fn double optical_half_value(ushort bits) @private {
    uint exponent = (bits >> 10) & 31;
    double mantissa = bits & 1023;
    if (exponent == 31) return mantissa ? double::nan : double::inf;
    double value = exponent ? math::pow(2.0, (double)exponent - 15) * (1 + mantissa / 1024)
      : math::pow(2.0, -24.0) * mantissa;
    return bits & 32768 ? -value : value;
}

fn void check_optical_stack(
    OpticalStack* stack,
    OpticalSurface[] surfaces,
    uint capacity,
    bool enabled = true,
) @private {
    uint[OPTICAL_SURFACE_CAPACITY] order;
    order_optical_surfaces(surfaces, order[:surfaces.len]);
    float[OPTICAL_SURFACE_CAPACITY] depths;
    transparency_fixtures::Color[OPTICAL_SURFACE_CAPACITY] products;
    transparency_fixtures::Color[OPTICAL_SURFACE_CAPACITY] signatures;
    uint groups;
    bool blocker;
    bool scalar_blocker;
    foreach (index : order[:surfaces.len]) {
        OpticalSurface surface = surfaces[index];
        if (!optical_survives(surface) || surface.model_scale.w <= OPTICAL_RECEIVER_DEPTH) continue;
        blocker |= optical_blocks(surface);
        scalar_blocker |= (surface.flags & OPTICAL_ALPHA_BLEND) == 0;
        if (!optical_participates(surface)) continue;
        if (!groups || depths[groups - 1] != surface.model_scale.w) {
            depths[groups] = surface.model_scale.w;
            products[groups++] = { 1, 1, 1 };
        }
        products[groups - 1] *= optical_expected_surface(surface);
        transparency_fixtures::Color token = {
            (double)(surface.node_index + 1) / 32,
            (double)(surface.instance_index + 1) / 32,
            (double)(surface.primitive_index + 1) / 32,
        };
        signatures[groups - 1] = 0.5 * token + 0.5 * signatures[groups - 1];
    }
    transparency_fixtures::Color expected = { 1, 1, 1 };
    for (uint group = 0; group < math::min(groups, capacity); group++) expected *= products[group];
    if (blocker || groups > capacity) expected = {};
    if (!enabled) {
        expected = scalar_blocker ? (transparency_fixtures::Color){} : (transparency_fixtures::Color){ 1, 1, 1 };
    }
    uint sample = OPTICAL_EXTENT / 2 * OPTICAL_EXTENT + OPTICAL_EXTENT / 2;
    Vec4 actual = ((Vec4*)stack.output.bytes.ptr)[sample];
    for (uint channel = 0; channel < 3; channel++) {
        double error = math::abs((double)actual[channel] - expected[channel]);
        assert(math::is_finite(actual[channel])
          && error <= OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[channel]),
          "visibility capacity=%s groups=%s blocker=%s channel=%s actual=%s expected=%s",
          capacity, groups, blocker, channel, actual[channel], expected[channel]);
        if (enabled && (blocker || groups > capacity)) assert(actual[channel] == 0);
    }
    assert(bitcast(actual.w, uint) == bitcast(scalar_blocker ? 0.0f : 1.0f, uint));
    double stored_error;
    double fragment_error;
    for (uint group = 0; group <= capacity; group++) {
        float expected_depth = group < groups ? depths[group] : 0;
        uint stored = ((uint*)(stack.readback.bytes.ptr + group * OPTICAL_SCALAR_BYTES))[sample];
        usz capture_offset = OPTICAL_CAPTURE_OFFSET + group * OPTICAL_SCALAR_BYTES;
        uint capture = ((uint*)(stack.readback.bytes.ptr + capture_offset))[sample];
        assert(stored == bitcast(expected_depth, uint) && capture == stored,
            "Nearest group/capture depth bits changed.");
        if (group == capacity) continue;
        uint shade = ((uint*)(stack.readback.bytes.ptr + OPTICAL_SHADE_OFFSET + group * OPTICAL_SCALAR_BYTES))[sample];
        assert(shade == stored, "Capture and product-shade bits differ.");
        usz product_offset = OPTICAL_PRODUCT_OFFSET + (usz)group * 2 * OPTICAL_SCALAR_BYTES;
        usz direct_offset = OPTICAL_DIRECT_OFFSET + (usz)group * 2 * OPTICAL_SCALAR_BYTES;
        usz signature_offset = OPTICAL_SIGNATURE_OFFSET + (usz)group * 4 * OPTICAL_SCALAR_BYTES;
        ushort* product = (ushort*)(stack.readback.bytes.ptr + product_offset);
        ushort* direct = (ushort*)(stack.readback.bytes.ptr + direct_offset);
        Vec4 signature = ((Vec4*)(stack.readback.bytes.ptr + signature_offset))[sample];
        for (uint channel = 0; channel < 3; channel++) {
            double reference = group < groups ? products[group][channel] : 1;
            double error = math::abs(optical_half_value(product[4 * sample + channel]) - reference);
            stored_error = math::max(stored_error, error);
            double direct_error = math::abs(optical_half_value(direct[4 * sample + channel]) - reference);
            fragment_error = math::max(fragment_error, direct_error);
            assert(error <= OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(reference),
                "stored group=%s channel=%s error=%s reference=%s", group, channel, error, reference);
            double expected_signature = group < groups ? signatures[group][channel] : 0;
            double signature_error = math::abs((double)signature[channel] - expected_signature);
            assert(signature_error <= OPTICAL_INTERMEDIATE_ABSOLUTE_TOLERANCE, "Canonical tied order changed.");
        }
    }
    io::printfn("optical stored groups=%s cap=%s enabled=%s blocker=%s stored_once_max_error=%s per_fragment_max_error=%s",
        groups, capacity, enabled, blocker, stored_error, fragment_error);
}

fn uint make_optical_stack_sheets(OpticalSurface[] output, uint groups, bool tied = false) @private {
    uint written;
    for (uint group = 0; group < groups; group++) {
        uint copies = tied ? 3 : 1;
        for (uint copy = 0; copy < copies; copy++) {
            OpticalSurface surface = optical_default_surface();
            surface.model_scale.w = (9 - (2 + (float)group / 4)) / 8;
            surface.node_index = groups - group;
            surface.instance_index = copies - copy;
            surface.primitive_index = copy;
            surface.flags |= copy == 1 ? OPTICAL_ADDITIVE : 0;
            output[written++] = surface;
        }
    }
    return written;
}

fn void test_optical_throughput_stored_groups_keep_nearest_depths_ties_and_fail_dark_on_overflow() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    OpticalSurface[OPTICAL_SURFACE_CAPACITY] surfaces;
    foreach (capacity : (uint[4]){ 1, 2, 4, 16 }) {
        foreach (groups : (uint[3]){ capacity, capacity + 1, 17 }) {
            uint count = make_optical_stack_sheets(surfaces[..], groups);
            run_optical_stack(
                renderer: &fixture.renderer,
                stack: &stack,
                surfaces: surfaces[:count],
                capacity: capacity,
            )!!;
            check_optical_stack(&stack, surfaces[:count], capacity);
        }
    }
    uint count = make_optical_stack_sheets(surfaces[..], 6, true);
    run_optical_stack(
        renderer: &fixture.renderer,
        stack: &stack,
        surfaces: surfaces[:count],
        capacity: 16,
    )!!;
    check_optical_stack(&stack, surfaces[:count], 16);
    check_validation(&fixture.renderer);
}

fn void test_optical_throughput_full_segment_blockers_and_disabled_scalar_are_independent_of_capacity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    OpticalSurface[OPTICAL_SURFACE_CAPACITY] surfaces;
    foreach (distance : (float[3]){ 2.5f, 8.25f, 9 }) {
        uint count = make_optical_stack_sheets(surfaces[..], 17);
        OpticalSurface blocker = optical_default_surface();
        blocker.flags = OPTICAL_OPAQUE;
        blocker.model_scale.w = (9 - distance) / 8;
        surfaces[count++] = blocker;
        foreach (capacity : (uint[2]){ 1, 16 }) {
            foreach (enabled : (bool[2]){ false, true }) {
                run_optical_stack(
                    renderer: &fixture.renderer,
                    stack: &stack,
                    surfaces: surfaces[:count],
                    capacity: capacity,
                    enabled: enabled,
                )!!;
                check_optical_stack(
                    stack: &stack,
                    surfaces: surfaces[:count],
                    capacity: capacity,
                    enabled: enabled,
                );
            }
        }
    }
    uint count = make_optical_stack_sheets(surfaces[..], 6);
    surfaces[0].flags = OPTICAL_ALPHA_MASK;
    surfaces[0].base_coverage.w = 0.49f;
    surfaces[1].factors.x = 0;
    surfaces[2].flags |= OPTICAL_CAST_OFF;
    run_optical_stack(
        renderer: &fixture.renderer,
        stack: &stack,
        surfaces: surfaces[:count],
        capacity: 16,
    )!!;
    check_optical_stack(&stack, surfaces[:count], 16);
    run_optical_stack(
        renderer: &fixture.renderer,
        stack: &stack,
        surfaces: surfaces[:count],
        capacity: 16,
        enabled: false,
    )!!;
    check_optical_stack(
        stack: &stack,
        surfaces: surfaces[:count],
        capacity: 16,
        enabled: false,
    );
    check_validation(&fixture.renderer);
}

fn void check_optical_trace_pair(Vec4[] software, Vec4[] hardware) @private {
    for (uint row = 16; row < 48; row++) {
        for (uint column = 16; column < 48; column++) {
            uint pixel = row * OPTICAL_EXTENT + column;
            assert(bitcast(software[pixel].w, uint) == bitcast(hardware[pixel].w, uint));
            for (uint channel = 0; channel < 3; channel++) {
                double error = math::abs((double)software[pixel][channel] - hardware[pixel][channel]);
                assert(error <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE, "Hardware/software pairwise visibility differs.");
            }
        }
    }
}
