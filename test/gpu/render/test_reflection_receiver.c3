module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const uint RECEIVER_WORD_COUNT @private = 7;
const uint RECEIVER_PIXEL_WORDS @private = 8;
const uint RECEIVER_READBACK_SECTIONS @private = 8; // Includes G-buffer identity and both graphics consumers.
const uint RECEIVER_GROUP_SIZE @private = 8; // Mirrors reflection_receiver.comp.glsl local size.
const uint RECEIVER_SIZE @private = 128;
const uint RECEIVER_ODD_WIDTH @private = 257;
const uint RECEIVER_ODD_HEIGHT @private = 129;
const double RECEIVER_ABSOLUTE_BOUND @private = 0.003;
const double RECEIVER_RELATIVE_BOUND @private = 0.005;
const char[*] RECEIVER_VERTEX @private = $embed("reflection_receiver.vert.glsl");
const char[*] RECEIVER_FRAGMENT @private = $embed("reflection_receiver.frag.glsl");
const char[*] RECEIVER_COMPUTE @private = $embed("reflection_receiver.comp.glsl");
const char[*] RECEIVER_INPUT @private = $embed("reflection_receiver_input.glsl");

enum ReceiverPhase : uint @private {
    CAPTURE,
    CONSUMED_WORDS,
    COMPOSED_COLOR,
    FLOAT_COLOR,
    DEFERRED_CONSUMED_WORDS,
}

struct ReceiverRoot @private {
    gpu::GpuAddress draw;
    uint[RECEIVER_WORD_COUNT] words;
    uint source_depth;
    uint[2] consumer_keys;
    uint consumer_depth;
    uint ordinal_base;
    ReceiverPhase phase;
    uint material_kind;
    float fade;
    float ambient_occlusion;
    uint flags;
    uint padding;
    Vec4 other_lobes;
    Vec4 reflected_radiance;
    Vec4 original_radiance;
}
$assert ReceiverRoot::size == 128;

struct ReceiverDispatch @private {
    gpu::GpuAddress receiver;
    gpu::GpuAddress output;
    uint width;
    uint height;
    uint mode;
    uint padding;
}
$assert ReceiverDispatch::size == 32;

struct ReceiverImages @private {
    Target[RECEIVER_WORD_COUNT] source;
    Target source_depth;
    Target[RECEIVER_WORD_COUNT] consumed;
    Target consumed_depth;
    Target[RECEIVER_WORD_COUNT] deferred;
    Target deferred_depth;
    gpu::MappedGpuSpan readback;
    gpu::GpuAllocation computed;
    gpu::PipelineHandle graphics;
    gpu::PipelineHandle identities;
    gpu::PipelineHandle compute;
    uint width;
    uint height;
}

struct ReceiverDraw @private {
    DrawRoot draw;
    GeometryRoot geometry;
    ReceiverRoot receiver;
    gpu::GpuAddress vertex_root;
    uint vertices;
    uint instances;
    gpu::GpuSpan indices;
    bool eligible;
}

fn gpu::GpuAddress? upload_receiver(Renderer* renderer, void* data, usz bytes) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = frame.upload.take(&renderer.device, bytes, render::STREAM_ALIGNMENT)!;
    mem::copy(span.bytes.ptr, data, (sz)bytes);
    return span.address;
}

fn char[]? compile_receiver(String source, ShaderStage stage, String[] defines = {}) @private {
    asset::ShaderInclude[1] includes = {{
        .name = "reflection_receiver_input.glsl",
        .text = (String)RECEIVER_INPUT[..],
    }};
    String log;
    char[]? spirv = compile::compile_glsl(
        allocator: mem,
        source: source,
        stage: stage,
        defines: defines,
        log: &log,
        includes: includes[..],
    );
    defer free(log.ptr);
    if (catch excuse = spirv) {
        io::eprintfn("receiver GLSL: %s", log);
        return excuse~;
    }
    return spirv;
}

fn Target? create_receiver_target(
    Renderer* renderer,
    uint width,
    uint height,
    gpu::Format format,
) @private {
    gpu::TextureDesc desc = {
        .width = width,
        .height = height,
        .mip_levels = 1,
        .array_layers = 1,
        .format = format,
        .usage = format == gpu::Format.D32_FLOAT
          ? (gpu::TextureUsage){ .sampled, .depth_attach, .transfer_src }
          : (gpu::TextureUsage){ .sampled, .color_attach, .transfer_src },
        .access = { .graphics },
        .debug_name = "reflection_receiver",
    };
    Target target = { .width = width, .height = height, .format = format };
    target.texture = gpu::create_texture(&renderer.device, &desc)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, target.texture);
    gpu::AttachmentViewDesc attachment = { .texture = target.texture };
    target.attachment = gpu::create_attachment_view(&renderer.device, &attachment)!;
    defer catch (void)gpu::destroy_attachment_view(&renderer.device, target.attachment);
    target.view = gpu::create_texture_view(&renderer.device, target.texture, null)!;
    return target;
}

fn void destroy_receiver_target(Renderer* renderer, Target* target) @private {
    if (!target.texture.is_valid()) return;
    gpu::destroy_texture_view(&renderer.device, target.view)!!;
    gpu::destroy_attachment_view(&renderer.device, target.attachment)!!;
    gpu::destroy_texture(&renderer.device, target.texture)!!;
    *target = {};
}

fn void destroy_receiver_images(Renderer* renderer, ReceiverImages* images) @private {
    render::wait_frames(renderer)!!;
    foreach (&target : images.source) destroy_receiver_target(renderer, target);
    foreach (&target : images.consumed) destroy_receiver_target(renderer, target);
    foreach (&target : images.deferred) destroy_receiver_target(renderer, target);
    destroy_receiver_target(renderer, &images.source_depth);
    destroy_receiver_target(renderer, &images.consumed_depth);
    destroy_receiver_target(renderer, &images.deferred_depth);
    if (images.compute.is_valid()) gpu::destroy_pipeline(&renderer.device, images.compute)!!;
    if (images.readback.bytes.len) {
        gpu::GpuAllocation allocation = images.readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    if (images.computed.is_valid()) gpu::free_allocation(&renderer.device, &images.computed)!!;
    *images = {};
}

fn void? create_receiver_images(
    Fixture* fixture,
    ReceiverImages* images,
    uint width,
    uint height,
) @private {
    Renderer* renderer = &fixture.renderer;
    if (renderer.caps.max_color_attachments < RECEIVER_WORD_COUNT) return gpu::UNSUPPORTED_FEATURE~;
    images.width = width;
    images.height = height;
    defer catch destroy_receiver_images(renderer, images);
    foreach (&target : images.source) {
        *target = create_receiver_target(
            renderer: renderer,
            width: width,
            height: height,
            format: gpu::Format.R32_UINT,
        )!;
    }
    foreach (&target : images.consumed) {
        *target = create_receiver_target(
            renderer: renderer,
            width: width,
            height: height,
            format: gpu::Format.R32_UINT,
        )!;
    }
    foreach (word, &target : images.deferred) {
        *target = create_receiver_target(
            renderer: renderer,
            width: width,
            height: height,
            format: word < render::GBUFFER_CHANNEL_COUNT ? render::GBUFFER_FORMATS[word] : gpu::Format.R32_UINT,
        )!;
    }
    images.source_depth = create_receiver_target(
        renderer: renderer,
        width: width,
        height: height,
        format: gpu::Format.D32_FLOAT,
    )!;
    images.consumed_depth = create_receiver_target(
        renderer: renderer,
        width: width,
        height: height,
        format: gpu::Format.D32_FLOAT,
    )!;
    images.deferred_depth = create_receiver_target(
        renderer: renderer,
        width: width,
        height: height,
        format: gpu::Format.D32_FLOAT,
    )!;
    usz pixel_bytes = (usz)width * height * uint::size;
    gpu::AllocationDesc readback = {
        .size = pixel_bytes * RECEIVER_PIXEL_WORDS * RECEIVER_READBACK_SECTIONS,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "receiver_readback",
    };
    images.readback = gpu::allocate_mapped_memory(&renderer.device, &readback)!;
    gpu::AllocationDesc computed = readback;
    computed.size = pixel_bytes * RECEIVER_PIXEL_WORDS;
    computed.memory_class = gpu::MemoryClass.GPU_PRIVATE;
    computed.debug_name = "receiver_consumed_words";
    images.computed = gpu::allocate_memory(&renderer.device, &computed)!;
    char[] spirv = compile_receiver((String)RECEIVER_COMPUTE[..], ShaderStage.COMPUTE)!;
    defer free(spirv.ptr);
    gpu::ComputePipelineDesc pipeline = { .shader = { .spirv = spirv }, .debug_name = "receiver_trace_blur" };
    images.compute = gpu::create_compute_pipeline(&renderer.device, &pipeline)!;
}

fn void? prepare_receiver_pipelines(Fixture* fixture, ReceiverImages* images, String[] vertex_defines = {}) @private {
    char[] vertex = compile_receiver((String)RECEIVER_VERTEX[..], ShaderStage.VERTEX, vertex_defines)!;
    defer free(vertex.ptr);
    char[] fragment = compile_receiver((String)RECEIVER_FRAGMENT[..], ShaderStage.FRAGMENT)!;
    defer free(fragment.ptr);
    String[1] identity_define = { "RECEIVER_DEFERRED_IDENTITY" };
    char[] identities = compile_receiver((String)RECEIVER_FRAGMENT[..], ShaderStage.FRAGMENT, identity_define[..])!;
    defer free(identities.ptr);
    asset::ShaderDesc shader_desc = { .fragment = fragment, .vertex = { .shaded = vertex, .depth = vertex } };
    ShaderId shader_id = fixture.assets.add_shader(&shader_desc)!;
    CustomStageSource source = { .vertex = vertex, .fragment = fragment };
    PipelineKey key = {
        .vertex = { .shader = MESH },
        .fragment = { .shader = PHYSICAL },
        .shader = shader_id,
        .shader_revision = fixture.assets.shader(shader_id).header.revision,
        .custom = { .vertex = true, .fragment = true },
        .color_count = RECEIVER_WORD_COUNT,
        .depth_format = gpu::Format.D32_FLOAT,
        .samples = gpu::SampleCount.ONE,
        .polygon = gpu::PolygonMode.FILL,
    };
    assert(render::KEY_COLOR_TARGETS >= RECEIVER_WORD_COUNT);
    for (uint word = 0; word < RECEIVER_WORD_COUNT; word++) key.color_formats[word] = gpu::Format.R32_UINT;
    images.graphics = fixture.renderer.pipelines.get(
        device: &fixture.renderer.device,
        key: key,
        custom: &source,
    )!;
    for (uint word = 0; word < RECEIVER_WORD_COUNT; word++) {
        key.color_formats[word] = images.deferred[word].format;
    }
    source.fragment = identities;
    images.identities = fixture.renderer.pipelines.get(
        device: &fixture.renderer.device,
        key: key,
        custom: &source,
    )!;
}

fn void? record_receiver_pass(
    Renderer* renderer,
    ReceiverImages* images,
    ReceiverDraw[] draws,
    ReceiverPhase phase,
    bool deferred = false,
) @private {
    Target[] targets = phase == CAPTURE ? images.source[..] : images.consumed[..];
    Target* depth = phase == CAPTURE ? &images.source_depth : &images.consumed_depth;
    if (deferred) {
        targets = images.deferred[..];
        depth = &images.deferred_depth;
    }
    gpu::ColorTargetDesc[RECEIVER_WORD_COUNT] colors;
    foreach (word, &target : targets) {
        target.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
        colors[word] = { .view = target.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE };
    }
    depth.transition(&renderer.commands, render::DEPTH_ATTACHMENT_STATE)!;
    gpu::DepthTargetDesc depth_target = {
        .view = depth.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = 0 },
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..], .depth = &depth_target, .width = images.width, .height = images.height,
    };
    gpu::ColorTargetState[RECEIVER_WORD_COUNT] outputs;
    foreach (&output : outputs) *output = gpu::color_blend_disabled();
    gpu::GraphicsState state = gpu::render_geometry_state(images.width, images.height)!;
    state.viewport = render::flipped_viewport(images.width, images.height);
    state.color.targets = outputs[..];
    state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };
    state.raster.cull_mode = gpu::CullMode.NONE;
    gpu::cmd_bind_pipeline(&renderer.commands, deferred ? images.identities : images.graphics)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    foreach (&draw : draws) {
        if (phase == CAPTURE && !draw.eligible) continue;
        ReceiverRoot receiver = draw.receiver;
        receiver.phase = phase;
        foreach (word, source : images.source) receiver.words[word] = (uint)source.view.index;
        receiver.source_depth = (uint)images.source_depth.view.index;
        receiver.consumer_keys = { (uint)images.deferred[5].view.index, (uint)images.deferred[6].view.index };
        receiver.consumer_depth = (uint)images.deferred_depth.view.index;
        if (draw.indices.size) {
            GeometryRoot geometry = draw.geometry;
            geometry.indices = gpu::get_span_address(&renderer.device, draw.indices)!;
            draw.draw.geometry = upload_receiver(renderer, &geometry, GeometryRoot::size)!;
        }
        draw.draw.instance_effects = upload_receiver(renderer, &receiver, ReceiverRoot::size)!;
        gpu::GpuAddress root = upload_receiver(renderer, &draw.draw, DrawRoot::size)!;
        gpu::cmd_draw(
            commands: &renderer.commands,
            vertex_root: root,
            fragment_root: root,
            vertex_count: draw.vertices,
            instance_count: draw.instances,
        )!;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
    renderer.work_recorded = true;
}

fn ReceiverDraw? receiver_draw(
    Fixture* fixture,
    ReceiverImages* images,
    MaterialId material,
    EnvironmentRes* environment,
    uint ordinal,
    bool physical,
    Vec3 normal = { 0, 0, 1 },
) @private {
    Renderer* renderer = &fixture.renderer;
    Vec3[6] positions = {
        { -0.75f, -0.75f, -5 }, { 0.75f, -0.75f, -5 }, { 0.75f, 0.75f, -5 },
        { -0.75f, -0.75f, -5 }, { 0.75f, 0.75f, -5 }, { -0.75f, 0.75f, -5 },
    };
    Vec3[6] normals;
    Vec4[6] tangents;
    Vec2[6] uv = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 0 }, { 1, 1 }, { 0, 1 } };
    foreach (&value : normals) *value = normal;
    Vec3 tangent = { normal.z, 0, -normal.x };
    foreach (&value : tangents) *value = { tangent.x, tangent.y, tangent.z, 1 };
    GeometryRoot geometry = {
        .positions = upload_receiver(renderer, &positions, (usz)positions.len * Vec3::size)!,
        .normals = upload_receiver(renderer, &normals, (usz)normals.len * Vec3::size)!,
        .tangents = upload_receiver(renderer, &tangents, (usz)tangents.len * Vec4::size)!,
        .uv0 = upload_receiver(renderer, &uv, (usz)uv.len * Vec2::size)!,
        .uv1 = upload_receiver(renderer, &uv, (usz)uv.len * Vec2::size)!,
        .vertex_count = 6,
        .flags = (uint)(GeometryFlags){ .has_normals = true, .has_tangents = true, .has_uv0 = true },
    };
    CameraMatrices matrices = camera::derive_matrices(
        camera: camera::orthographic(2, 1, 9),
        camera_world: matrix::IDENTITY4,
        viewport: { (float)images.width, (float)images.height },
    );
    FrameRoot frame = {
        .view = bitcast(matrices.view, Mat4f),
        .proj = bitcast(matrices.proj, Mat4f),
        .view_proj = bitcast(matrices.view_proj, Mat4f),
        .inv_view_proj = bitcast(matrices.inv_view_proj, Mat4f),
        .prev_view_proj = bitcast(matrices.view_proj, Mat4f),
        .camera_params = { 1, 9, (float)images.width, (float)images.height },
        .environment = render::pack_lighting_environment(
            renderer: renderer,
            environment: environment,
            intensity: 1,
            rotation: quaternion::IDENTITY,
            sheen: false,
        )!,
    };
    ReceiverDraw result = {
        .geometry = geometry,
        .vertices = 6,
        .instances = 1,
        .eligible = true,
        .receiver = {
            .ordinal_base = ordinal,
            .material_kind = physical ? 1 : 0,
            .fade = 0.5f,
            .ambient_occlusion = 1,
            .other_lobes = { 0.25f, 0.5f, 0.75f, 1 },
            .reflected_radiance = { 0.8f, 0.6f, 0.4f, 1 },
        },
        .draw = {
            .model = bitcast(matrix::IDENTITY4{float}, Mat4f),
            .prev_model = bitcast(matrix::IDENTITY4{float}, Mat4f),
            .normal_0 = { 1, 0, 0, 0 },
            .normal_1 = { 0, 1, 0, 0 },
            .normal_2 = { 0, 0, 1, 0 },
            .layers = uint::max,
            .frame = upload_receiver(renderer, &frame, FrameRoot::size)!,
            .geometry = upload_receiver(renderer, &geometry, GeometryRoot::size)!,
            .material = render::resolve_material(renderer, material)!.address,
        },
    };
    return result;
}

fn void? copy_receiver_section(
    Renderer* renderer,
    ReceiverImages* images,
    Target[] targets,
    Target* depth,
    uint section,
) @private {
    usz plane = (usz)images.width * images.height * uint::size;
    usz section_offset = (usz)section * plane * RECEIVER_PIXEL_WORDS;
    gpu::TextureState transfer = {
        .layout = gpu::TextureLayout.TRANSFER_SOURCE, .stages = { .transfer }, .access = { .read },
    };
    foreach (word, &target : targets) {
        target.transition(&renderer.commands, transfer)!;
        gpu::TextureBufferCopyDesc copy = {
            .texture = target.texture,
            .dst = images.readback.span.checked_subspan(section_offset + (usz)word * plane, plane)!,
        };
        gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    }
    depth.transition(&renderer.commands, transfer)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = depth.texture,
        .dst = images.readback.span.checked_subspan(section_offset + RECEIVER_WORD_COUNT * plane, plane)!,
    };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
}

fn void? record_receiver_compute(
    Renderer* renderer,
    ReceiverImages* images,
    ReceiverRoot receiver,
    uint mode,
    uint section,
) @private {
    gpu::TextureState sampled = {
        .layout = gpu::TextureLayout.SAMPLED, .stages = { .compute }, .access = { .read },
    };
    foreach (word, &target : images.source) {
        target.transition(&renderer.commands, sampled)!;
        receiver.words[word] = (uint)target.view.index;
    }
    images.source_depth.transition(&renderer.commands, sampled)!;
    receiver.source_depth = (uint)images.source_depth.view.index;
    for (uint index = 0; index < receiver.consumer_keys.len; index++) {
        Target* target = &images.deferred[5 + index];
        target.transition(&renderer.commands, sampled)!;
        receiver.consumer_keys[index] = (uint)target.view.index;
    }
    images.deferred_depth.transition(&renderer.commands, sampled)!;
    receiver.consumer_depth = (uint)images.deferred_depth.view.index;
    gpu::GpuSpan output = gpu::get_allocation_span(&renderer.device, images.computed)!;
    ReceiverDispatch dispatch = {
        .receiver = upload_receiver(renderer, &receiver, ReceiverRoot::size)!,
        .output = gpu::get_span_address(&renderer.device, output)!,
        .width = images.width,
        .height = images.height,
        .mode = mode,
    };
    gpu::GpuAddress root = upload_receiver(renderer, &dispatch, ReceiverDispatch::size)!;
    gpu::cmd_bind_pipeline(&renderer.commands, images.compute)!;
    uint groups_x = (images.width + RECEIVER_GROUP_SIZE - 1) / RECEIVER_GROUP_SIZE;
    uint groups_y = (images.height + RECEIVER_GROUP_SIZE - 1) / RECEIVER_GROUP_SIZE;
    gpu::cmd_dispatch(&renderer.commands, root, { groups_x, groups_y, 1 })!;
    gpu::Barrier copied = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;
    usz bytes = (usz)images.width * images.height * RECEIVER_PIXEL_WORDS * uint::size;
    gpu::BufferCopyDesc copy = {
        .src = output,
        .dst = images.readback.span.checked_subspan((usz)section * bytes, bytes)!,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier next = { .before = { .transfer }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &next)!;
}

fn uint[]? run_receiver_draws(Fixture* fixture, ReceiverImages* images, ReceiverDraw[] draws) @private {
    Renderer* renderer = &fixture.renderer;
    render::record_pending_copies(renderer, &renderer.commands)!;
    record_receiver_pass(
        renderer: renderer,
        images: images,
        draws: draws,
        phase: CAPTURE,
    )!;
    copy_receiver_section(
        renderer: renderer,
        images: images,
        targets: images.source[..],
        depth: &images.source_depth,
        section: 0,
    )!;
    foreach (&target : images.source) target.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    images.source_depth.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    record_receiver_pass(
        renderer: renderer,
        images: images,
        draws: draws,
        phase: CONSUMED_WORDS,
    )!;
    copy_receiver_section(
        renderer: renderer,
        images: images,
        targets: images.consumed[..],
        depth: &images.consumed_depth,
        section: 1,
    )!;
    record_receiver_pass(
        renderer: renderer,
        images: images,
        draws: draws,
        phase: COMPOSED_COLOR,
    )!;
    copy_receiver_section(
        renderer: renderer,
        images: images,
        targets: images.consumed[..],
        depth: &images.consumed_depth,
        section: 2,
    )!;
    record_receiver_pass(
        renderer: renderer,
        images: images,
        draws: draws,
        phase: FLOAT_COLOR,
    )!;
    copy_receiver_section(
        renderer: renderer,
        images: images,
        targets: images.consumed[..],
        depth: &images.consumed_depth,
        section: 3,
    )!;
    record_receiver_pass(
        renderer: renderer,
        images: images,
        draws: draws,
        phase: CONSUMED_WORDS,
        deferred: true,
    )!;
    usz plane = (usz)images.width * images.height * uint::size;
    gpu::TextureState transfer = {
        .layout = gpu::TextureLayout.TRANSFER_SOURCE, .stages = { .transfer }, .access = { .read },
    };
    for (uint word = 5; word < RECEIVER_PIXEL_WORDS; word++) {
        Target* target = word < RECEIVER_WORD_COUNT ? &images.deferred[word] : &images.deferred_depth;
        target.transition(&renderer.commands, transfer)!;
        usz offset = ((usz)6 * RECEIVER_PIXEL_WORDS + word) * plane;
        gpu::TextureBufferCopyDesc copy = {
            .texture = target.texture,
            .dst = images.readback.span.checked_subspan(offset, plane)!,
        };
        gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    }
    record_receiver_compute(
        renderer: renderer,
        images: images,
        receiver: draws[0].receiver,
        mode: 0,
        section: 4,
    )!;
    record_receiver_compute(
        renderer: renderer,
        images: images,
        receiver: draws[0].receiver,
        mode: 1,
        section: 5,
    )!;
    foreach (&target : images.source) target.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    images.source_depth.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    images.deferred[5].transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    images.deferred[6].transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    images.deferred_depth.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    record_receiver_pass(
        renderer: renderer,
        images: images,
        draws: draws,
        phase: DEFERRED_CONSUMED_WORDS,
    )!;
    copy_receiver_section(
        renderer: renderer,
        images: images,
        targets: images.consumed[..],
        depth: &images.consumed_depth,
        section: 7,
    )!;
    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, images.readback.span)!;
    return alloc::clone_slice(mem, ((uint*)images.readback.bytes.ptr)[:images.readback.bytes.len / uint::size]);
}

fn void check_receiver_sample(
    uint[] values,
    ReceiverImages* images,
    uint x,
    uint y,
    uint ordinal,
) @private {
    usz pixels = (usz)images.width * images.height;
    usz pixel = (usz)y * images.width + x;
    for (uint word = 0; word < RECEIVER_PIXEL_WORDS; word++) {
        uint stored = values[(usz)word * pixels + pixel];
        assert(values[pixels * RECEIVER_PIXEL_WORDS + (usz)word * pixels + pixel] == stored);
        assert(values[pixels * RECEIVER_PIXEL_WORDS * 7 + (usz)word * pixels + pixel] == stored);
        for (uint section = 4; section < 6; section++) {
            assert(values[pixels * RECEIVER_PIXEL_WORDS * section + pixel * RECEIVER_PIXEL_WORDS + word] == stored);
        }
    }
    for (uint word = 5; word < RECEIVER_PIXEL_WORDS; word++) {
        assert(values[((usz)6 * RECEIVER_PIXEL_WORDS + word) * pixels + pixel] == values[word * pixels + pixel]);
    }
    assert(values[5 * pixels + pixel] == ordinal + 1);
    assert(values[7 * pixels + pixel] == bitcast(0.5f, uint));
    assert(values[0 * pixels + pixel] == 0x80008000);
    assert(values[1 * pixels + pixel] == 0x8000ffff);
    for (uint channel = 0; channel < 3; channel++) {
        float packed = bitcast(values[pixels * RECEIVER_PIXEL_WORDS * 2 + channel * pixels + pixel], float);
        float reference = bitcast(values[pixels * RECEIVER_PIXEL_WORDS * 3 + channel * pixels + pixel], float);
        double bound = RECEIVER_ABSOLUTE_BOUND + RECEIVER_RELATIVE_BOUND * math::abs((double)reference);
        assert(math::is_finite(packed) && math::is_finite(reference));
        assert(math::abs((double)packed - reference) <= bound);
    }
}

fn void test_reflection_receiver_seven_integer_attachments_preserve_graphics_trace_and_blur_words() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ReceiverImages images;
    create_receiver_images(
        fixture: &fixture,
        images: &images,
        width: RECEIVER_SIZE,
        height: RECEIVER_SIZE,
    )!!;
    defer destroy_receiver_images(&fixture.renderer, &images);
    prepare_receiver_pipelines(&fixture, &images)!!;
    EnvironmentId environment_id = fixture.assets.add_environment(light::solid_environment({ 0.25f, 0.5f, 1 }))!!;
    fixture.renderer.upload_environment(environment_id)!!;
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
    params.standard.metallic = 0.25f;
    params.standard.roughness = 0.5f;
    params.specular = 0.5f;
    params.specular_color = { 0.25f, 0.5f, 1 };
    params.ior = 1.33f;
    MaterialId material = fixture.assets.add_material(material::physical(params))!!;
    fixture.renderer.begin_frame()!!;
    defer catch render::abort_frame(&fixture.renderer);
    EnvironmentRes* environment = render::resolve_environment(
        renderer: &fixture.renderer,
        environment: environment_id,
        lighting: true,
        sheen: false,
    )!!;
    ReceiverDraw[1] draws = { receiver_draw(
        fixture: &fixture,
        images: &images,
        material: material,
        environment: environment,
        ordinal: 17,
        physical: true,
    )!! };
    uint[] values = run_receiver_draws(&fixture, &images, draws[..])!!;
    defer free(values.ptr);
    check_receiver_sample(
        values: values,
        images: &images,
        x: 40,
        y: 80,
        ordinal: 17,
    );
    check_receiver_sample(
        values: values,
        images: &images,
        x: 88,
        y: 48,
        ordinal: 17,
    );
    usz pixels = (usz)images.width * images.height;
    uint first_primitive = values[6 * pixels + (usz)80 * images.width + 40];
    uint second_primitive = values[6 * pixels + (usz)48 * images.width + 88];
    assert(first_primitive != second_primitive && first_primitive < 2 && second_primitive < 2);
    check_validation(&fixture.renderer);
}
