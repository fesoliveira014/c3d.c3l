module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::render @public;
import c3d::shader;
import c3d::shader::compile;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;
import std::math::vector;

const char[*] OPTICAL_LIGHT_HEADER @private = $embed("optical_throughput.light.glsl");
const char[*] OPTICAL_LIGHT_VERTEX @private = $embed("optical_throughput.light.vert.glsl");
const char[*] OPTICAL_LIGHT_FRAGMENT @private = $embed("optical_throughput.light.frag.glsl");
const char[*] OPTICAL_LIGHT_COMPUTE @private = $embed("optical_throughput.light.comp.glsl");
const uint OPTICAL_LIGHT_DIRECTIONAL @private = 0;
const uint OPTICAL_LIGHT_POINT @private = 1;
const uint OPTICAL_LIGHT_SPOT @private = 2;
const uint OPTICAL_LIGHT_LAYER_ONE @private = 512;
const uint OPTICAL_LIGHT_LAYER_TWO @private = 1024;

struct OpticalLightDraw @private {
    OpticalDraw draw;
    uint kind;
    uint layers;
    uint[2] padding;
}
$assert OpticalLightDraw::size == 64;
$assert $reflect(OpticalLightDraw.kind).offset == 48;

struct OpticalLightTraceRoot @private {
    gpu::GpuAddress scene;
    gpu::GpuAddress surfaces;
    gpu::GpuAddress order;
    gpu::GpuAddress output_address;
    uint capacity;
    uint width;
    uint height;
    uint sampler_index;
    uint kind;
    uint layers;
    uint enabled;
    uint padding;
}
$assert OpticalLightTraceRoot::size == 64;

fn float optical_light_receiver_depth(uint kind) @private {
    return kind == OPTICAL_LIGHT_DIRECTIONAL ? OPTICAL_RECEIVER_DEPTH : OPTICAL_RECEIVER_DEPTH / 8.5f;
}

fn char[]? compile_optical_light(String source, ShaderStage stage, String[] defines = {}) @private {
    asset::ShaderInclude[2] includes = {
        { .name = "optical_throughput.surface.glsl", .text = (String)OPTICAL_SURFACE_SOURCE[..] },
        { .name = "optical_throughput.light.glsl", .text = (String)OPTICAL_LIGHT_HEADER[..] },
    };
    String log;
    char[]? result = compile::compile_glsl(
        allocator: mem,
        source: source,
        stage: stage,
        defines: defines,
        debug_name: "optical_light",
        log: &log,
        includes: includes[..],
    );
    defer free(log.ptr);
    if (catch excuse = result) {
        io::eprintfn("Optical light shader compilation failed:\n%s", log);
        return excuse~;
    }
    return result;
}

fn void? configure_optical_light_pipelines(
    Renderer* renderer,
    OpticalStack* stack,
    OpticalTraceResources* trace,
) @private {
    char[] vertex = compile_optical_light((String)OPTICAL_LIGHT_VERTEX[..], ShaderStage.VERTEX)!;
    defer free(vertex.ptr);
    String[1] outputs = { "OPTICAL_GROUP_OUTPUTS" };
    char[] fragment = compile_optical_light((String)OPTICAL_LIGHT_FRAGMENT[..], ShaderStage.FRAGMENT, outputs[..])!;
    defer free(fragment.ptr);
    foreach (phase : (uint[3]){ 0, 1, 2 }) {
        gpu::Format[3] formats = {
            phase == 0 ? gpu::Format.R32_FLOAT
              : phase == 1 ? gpu::Format.RGBA32_FLOAT : gpu::Format.RGBA16_FLOAT,
            gpu::Format.R32_FLOAT,
            gpu::Format.RGBA32_FLOAT,
        };
        gpu::GraphicsPipelineDesc desc = {
            .vertex_shader = { .spirv = vertex },
            .fragment_shader = { .spirv = fragment },
            .color_formats = formats[..],
            .depth_format = phase == 0 ? gpu::Format.D32_FLOAT : gpu::Format.UNDEFINED,
            .debug_name = "optical_light_surface",
        };
        gpu::PipelineHandle* selected = phase == 0 ? &stack.capture : phase == 1 ? &stack.accumulate : &stack.store;
        gpu::PipelineHandle pipeline = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
        gpu::destroy_pipeline(&renderer.device, *selected)!;
        *selected = pipeline;
    }
    String[1] software = { "SCENE_TRACE_BVH" };
    String[1] hardware = { "SCENE_TRACE_RAY_QUERY" };
    foreach (branch, defines : (String[][2]){ software[..], hardware[..] }) {
        char[] compute = compile_optical_light((String)OPTICAL_LIGHT_COMPUTE[..], ShaderStage.COMPUTE, defines)!;
        defer free(compute.ptr);
        gpu::ComputePipelineDesc desc = { .shader = { .spirv = compute }, .debug_name = "optical_light_trace" };
        gpu::PipelineHandle* selected = branch ? &trace.hardware : &trace.software;
        gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&renderer.device, &desc)!;
        gpu::destroy_pipeline(&renderer.device, *selected)!;
        *selected = pipeline;
    }
}

fn void? draw_optical_light_surface(Renderer* renderer, OpticalLightDraw light) @private {
    gpu::GpuAddress root = write_optical_bytes(renderer, ((char*)&light)[:OpticalLightDraw::size])!;
    gpu::cmd_draw(
        commands: &renderer.commands,
        vertex_root: root,
        fragment_root: root,
        vertex_count: OPTICAL_VERTEX_COUNT,
        instance_count: 1,
    )!;
}

fn void? record_optical_light_pass(
    Renderer* renderer,
    OpticalStack* stack,
    OpticalLightDraw light,
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
        light.draw.first = order.len ? order[index] : index;
        draw_optical_light_surface(renderer, light)!;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.work_recorded = true;
}

fn void? run_optical_light_stack(
    Renderer* renderer,
    OpticalStack* stack,
    OpticalSurface[] surfaces,
    uint capacity,
    uint kind,
    uint layers,
    bool enabled = true,
    gpu::SamplerIndex sampler = (gpu::SamplerIndex)0,
) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    char[] surface_bytes = ((char*)surfaces.ptr)[:surfaces.len * OpticalSurface::size];
    gpu::GpuAddress address = write_optical_bytes(renderer, surface_bytes)!;
    OpticalLightDraw light = {
        .draw = {
            .surfaces = address,
            .receiver_depth = optical_light_receiver_depth(kind),
            .sampler_index = (uint)sampler,
        },
        .kind = kind,
        .layers = layers,
    };
    uint[OPTICAL_SURFACE_CAPACITY] order;
    order_optical_surfaces(surfaces, order[:surfaces.len]);
    foreach (phase : (uint[2]){ OPTICAL_OPAQUE_PHASE, OPTICAL_LEGACY_PHASE }) {
        light.draw.phase = phase;
        Target* depth = phase == OPTICAL_OPAQUE_PHASE ? &stack.opaque_depth : &stack.legacy_depth;
        record_optical_light_pass(
            renderer: renderer,
            stack: stack,
            light: light,
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
        light.draw.phase = OPTICAL_CAPTURE_PHASE;
        light.draw.previous = group ? (uint)stack.depths[group - 1].view.index : 0;
        record_optical_light_pass(
            renderer: renderer,
            stack: stack,
            light: light,
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
        light.draw.phase = OPTICAL_PRODUCT_PHASE;
        light.draw.selected = (uint)stack.depths[group].view.index;
        record_optical_light_pass(
            renderer: renderer,
            stack: stack,
            light: light,
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
        light.draw.phase = OPTICAL_STORE_PHASE;
        light.draw.source = (uint)stack.group_float.view.index;
        record_optical_light_pass(
            renderer: renderer,
            stack: stack,
            light: light,
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
        light.draw.phase = OPTICAL_PRODUCT_PHASE;
        record_optical_light_pass(
            renderer: renderer,
            stack: stack,
            light: light,
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
        .receiver_depth = optical_light_receiver_depth(kind),
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

fn void? run_optical_light_trace(
    Fixture* fixture,
    OpticalTraceResources* trace,
    OpticalSurface[] surfaces,
    uint capacity,
    uint kind,
    uint layers,
    bool enabled,
    bool hardware,
    gpu::SamplerIndex sampler,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::GpuAddress surface_address;
    gpu::GpuAddress order_address;
    gpu::GpuAddress scene = upload_optical_trace_scene(
        fixture: fixture,
        trace: trace,
        surfaces: surfaces,
        surface_address: &surface_address,
        order_address: &order_address,
    )!;
    OpticalLightTraceRoot parameters = {
        .scene = scene,
        .surfaces = surface_address,
        .order = order_address,
        .output_address = trace.output.address,
        .capacity = capacity,
        .width = OPTICAL_EXTENT,
        .height = OPTICAL_EXTENT,
        .sampler_index = (uint)sampler,
        .kind = kind,
        .layers = layers,
        .enabled = enabled ? 1 : 0,
    };
    gpu::GpuAddress root = write_optical_bytes(renderer, ((char*)&parameters)[:OpticalLightTraceRoot::size])!;
    gpu::cmd_bind_pipeline(&renderer.commands, hardware ? trace.hardware : trace.software)!;
    uint groups = OPTICAL_EXTENT / OPTICAL_RESOLVE_GROUP_SIZE;
    gpu::cmd_dispatch(&renderer.commands, root, { groups, groups, 1 })!;
    gpu::Barrier host = { .before = { .compute }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, trace.output.span)!;
}

fn transparency_fixtures::Color optical_light_ray(uint kind, uint column, uint row) @private {
    if (kind == OPTICAL_LIGHT_DIRECTIONAL) return { 0, 0, -1 };
    double tangent = kind == OPTICAL_LIGHT_SPOT ? math::sqrt(1.0 / 3) : 1.0;
    double x = (2 * ((double)column + 0.5) / OPTICAL_EXTENT - 1) * tangent;
    double y = (1 - 2 * ((double)row + 0.5) / OPTICAL_EXTENT) * tangent;
    double length = math::sqrt(1 + x * x + y * y);
    return { x / length, y / length, -1 / length };
}

fn transparency_fixtures::Color optical_light_expected(
    OpticalSurface surface,
    transparency_fixtures::Color direction,
) @private {
    if (!optical_survives(surface)) return { 1, 1, 1 };
    if ((surface.flags & OPTICAL_ALPHA_BLEND) != 0 && surface.factors.x == 0) return { 1, 1, 1 };
    transparency_fixtures::Color normal = {
        surface.normal_thickness.x, surface.normal_thickness.y, surface.normal_thickness.z,
    };
    double normal_length = math::sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z);
    normal /= normal_length;
    double signed_cosine = -(normal.x * direction.x + normal.y * direction.y + normal.z * direction.z);
    double cosine = math::max(0.0, signed_cosine);
    double eta = 1.0 / surface.factors.z;
    double transmitted_cosine = math::sqrt(1 - eta * eta * (1 - signed_cosine * signed_cosine));
    transparency_fixtures::Color ray = eta * direction + (eta * signed_cosine - transmitted_cosine) * normal;
    double ray_length = math::sqrt(ray.x * ray.x + ray.y * ray.y + ray.z * ray.z);
    ray /= ray_length;
    ray *= (double)surface.normal_thickness.w;
    ray.x *= surface.model_scale.x;
    ray.y *= surface.model_scale.y;
    ray.z *= surface.model_scale.z;
    double distance = math::sqrt(ray.x * ray.x + ray.y * ray.y + ray.z * ray.z);
    double ratio = ((double)surface.factors.z - 1) / ((double)surface.factors.z + 1);
    double complement = 1 - cosine;
    double grazing = complement * complement * complement * complement * complement;
    double coverage = (surface.flags & OPTICAL_ALPHA_BLEND) != 0 ? surface.base_coverage.w : 1.0;
    transparency_fixtures::Color result;
    for (uint channel = 0; channel < 3; channel++) {
        double reflectance = math::min(1.0, ratio * ratio * surface.specular_cosine[channel]) * surface.factors.w;
        double fresnel = reflectance + ((double)surface.factors.w - reflectance) * grazing;
        double exponent = surface.attenuation_distance.w == 0 ? 0 : distance / surface.attenuation_distance.w;
        double absorption = surface.attenuation_distance.w == 0 || distance == 0 ? 1.0
          : math::exp(math::ln((double)surface.attenuation_distance[channel]) * exponent);
        double optical = (double)surface.factors.x * (1 - (double)surface.factors.y) * surface.base_coverage[channel]
          * (1 - fresnel) * absorption;
        result[channel] = 1 - coverage + coverage * optical;
    }
    return result;
}

fn void test_optical_throughput_point_spot_and_directional_lights_keep_per_light_layers_and_off_state() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    Renderer* renderer = &fixture.renderer;
    TextureId texture = add_optical_factor_map(&fixture)!!;
    renderer.upload_texture(texture)!!;
    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "optical_light_nearest",
    };
    gpu::SamplerIndex sampler = gpu::intern_sampler(&renderer.device, &sampler_desc)!!;
    OpticalSurface[2] surfaces = { optical_default_surface(), optical_default_surface() };
    surfaces[0].flags |= OPTICAL_LIGHT_LAYER_ONE;
    surfaces[0].base_coverage.w = 1;
    surfaces[0].map = (uint)renderer.textures[texture.index].view.index;
    surfaces[0].normal_thickness = { 0.5f, 0, 0.8660254f, 1 };
    surfaces[0].model_scale.x = 2;
    surfaces[0].model_scale.y = 1;
    surfaces[0].model_scale.z = 0.5f;
    surfaces[1].flags = OPTICAL_OPAQUE | OPTICAL_LIGHT_LAYER_TWO;
    surfaces[1].model_scale.w = (9 - 6.0f) / 8;
    surfaces[1].node_index = 1;
    OpticalStack stack;
    create_optical_stack(renderer, &stack)!!;
    defer destroy_optical_stack(renderer, &stack);
    OpticalTraceResources trace;
    create_optical_trace(&fixture, &trace, surfaces[..])!!;
    defer destroy_optical_trace(&fixture, &trace);
    configure_optical_light_pipelines(renderer, &stack, &trace)!!;
    uint[4] columns = { 31, 32, 31, 32 };
    uint[4] rows = { 31, 31, 32, 32 };
    double maximum_half_error;
    double maximum_float_error;
    double maximum_pair_error;
    foreach (kind : (uint[3]){ OPTICAL_LIGHT_DIRECTIONAL, OPTICAL_LIGHT_POINT, OPTICAL_LIGHT_SPOT }) {
        foreach (layers : (uint[2]){ OPTICAL_LIGHT_LAYER_ONE, OPTICAL_LIGHT_LAYER_TWO }) {
            foreach (enabled : (bool[2]){ false, true }) {
                run_optical_light_stack(
                    renderer: renderer,
                    stack: &stack,
                    surfaces: surfaces[..],
                    capacity: 4,
                    kind: kind,
                    layers: layers,
                    enabled: enabled,
                    sampler: sampler,
                )!!;
                Vec4[4] atlas;
                Vec4[4] software;
                transparency_fixtures::Color[4] expected;
                float scalar = layers == OPTICAL_LIGHT_LAYER_ONE ? 1 : 0;
                for (uint sample = 0; sample < 4; sample++) {
                    uint pixel = rows[sample] * OPTICAL_EXTENT + columns[sample];
                    atlas[sample] = ((Vec4*)stack.output.bytes.ptr)[pixel];
                    uint captured = ((uint*)stack.readback.bytes.ptr)[pixel];
                    uint emitted = ((uint*)(stack.readback.bytes.ptr + OPTICAL_CAPTURE_OFFSET))[pixel];
                    uint shaded = ((uint*)(stack.readback.bytes.ptr + OPTICAL_SHADE_OFFSET))[pixel];
                    assert(captured == emitted && shaded == captured, "Light capture/shade depth bits differ.");
                    if (layers == OPTICAL_LIGHT_LAYER_ONE) {
                        assert(captured != 0);
                    } else {
                        assert(captured == 0);
                    }
                    uint overflow = ((uint*)(stack.readback.bytes.ptr + 4 * OPTICAL_SCALAR_BYTES))[pixel];
                    assert(overflow == 0);
                    OpticalSurface mapped = optical_mapped_reference(surfaces[0], sample);
                    expected[sample] = layers == OPTICAL_LIGHT_LAYER_TWO ? (transparency_fixtures::Color){}
                      : enabled ? optical_light_expected(mapped, optical_light_ray(kind, columns[sample], rows[sample]))
                      : (transparency_fixtures::Color){ 1, 1, 1 };
                    assert(bitcast(atlas[sample].w, uint) == bitcast(scalar, uint));
                    for (uint channel = 0; channel < 3; channel++) {
                        double error = math::abs((double)atlas[sample][channel] - expected[sample][channel]);
                        maximum_half_error = math::max(maximum_half_error, error);
                        double bound = OPTICAL_ABSOLUTE_TOLERANCE
                          + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[sample][channel]);
                        assert(math::is_finite(atlas[sample][channel]) && error <= bound,
                            "Light atlas kind=%s layers=%s enabled=%s sample=%s channel=%s actual=%s expected=%s",
                            kind, layers, enabled, sample, channel, atlas[sample][channel], expected[sample][channel]);
                        if (layers == OPTICAL_LIGHT_LAYER_TWO) assert(atlas[sample][channel] == 0);
                    }
                }
                foreach (hardware : (bool[2]){ false, true }) {
                    run_optical_light_trace(
                        fixture: &fixture,
                        trace: &trace,
                        surfaces: surfaces[..],
                        capacity: 4,
                        kind: kind,
                        layers: layers,
                        enabled: enabled,
                        hardware: hardware,
                        sampler: sampler,
                    )!!;
                    for (uint sample = 0; sample < 4; sample++) {
                        uint pixel = rows[sample] * OPTICAL_EXTENT + columns[sample];
                        Vec4 actual = ((Vec4*)trace.output.bytes.ptr)[pixel];
                        assert(bitcast(actual.w, uint) == bitcast(scalar, uint));
                        for (uint channel = 0; channel < 3; channel++) {
                            double error = math::abs((double)actual[channel] - expected[sample][channel]);
                            maximum_float_error = math::max(maximum_float_error, error);
                            double bound = OPTICAL_INTERMEDIATE_ABSOLUTE_TOLERANCE
                              + OPTICAL_INTERMEDIATE_RELATIVE_TOLERANCE * math::abs(expected[sample][channel]);
                            assert(math::is_finite(actual[channel]) && error <= bound,
                                "Light ray hardware=%s kind=%s layers=%s enabled=%s sample=%s channel=%s actual=%s expected=%s",
                                hardware, kind, layers, enabled, sample, channel, actual[channel], expected[sample][channel]);
                            double pair = math::abs((double)actual[channel] - atlas[sample][channel]);
                            maximum_pair_error = math::max(maximum_pair_error, pair);
                            assert(pair <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE);
                            if (hardware) {
                                pair = math::abs((double)actual[channel] - software[sample][channel]);
                                maximum_pair_error = math::max(maximum_pair_error, pair);
                                assert(pair <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE);
                            }
                            if (layers == OPTICAL_LIGHT_LAYER_TWO) assert(actual[channel] == 0);
                        }
                        if (!hardware) software[sample] = actual;
                    }
                }
            }
        }
    }
    io::printfn("optical lights=directional,point_neg_z,spot30 range=9 layers=2 off_on=2 samples=4 rows=12 half=%s float=%s pair=%s",
        maximum_half_error, maximum_float_error, maximum_pair_error);
    check_validation(renderer);
}
