module c3d::render::acceptance;

import c3d;
import c3d::render @public;
import c3d::shader;
import c3d::test::transparency_fixtures;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] PEEL_VERTEX @private = $embed("transparency_peel.vert.glsl");
const char[*] PEEL_FRAGMENT @private = $embed("transparency_peel.frag.glsl");
const char[*] PEEL_PARTICIPATION @private = $embed("transparency_peel.participation.glsl");
const char[*] PEEL_REFERENCE @private = $embed("transparency_peel.reference.frag.glsl");
const char[*] PEEL_OVERFLOW @private = $embed("transparency_peel.comp.glsl");
const char[*] PEEL_MESH_VERTEX @private = $embed("transparency_peel.mesh.vert.glsl");
const char[*] PEEL_BILLBOARD_VERTEX @private = $embed("transparency_peel.billboard.vert.glsl");
const char[*] PEEL_MESH_BODY @private = $embed("../../../shaders/mesh.vert.glsl");
const char[*] PEEL_BILLBOARD_BODY @private = $embed("../../../shaders/billboard.vert.glsl");
const uint PEEL_SIZE @private = 128;
const uint PEEL_GROUPS @private = 4;
const uint PEEL_SOURCE_CAPACITY @private = 17;
const double PEEL_ANALYTIC_DEPTH_TOLERANCE @private = 4 * math::FLOAT_EPSILON; // raster rounding only; keys stay exact
const uint PEEL_PIXELS @private = PEEL_SIZE * PEEL_SIZE;
const usz PEEL_PLANE_BYTES @private = PEEL_PIXELS * float::size;
const uint PEEL_SHADE_PLANE_FIRST @private = 4 + 2 * (PEEL_GROUPS + 1);
const uint PEEL_CAPTURE_STAGE_PLANE_FIRST @private = PEEL_SHADE_PLANE_FIRST + PEEL_GROUPS;
const usz PEEL_DIAGNOSTIC_OFFSET @private = PEEL_PLANE_BYTES * (PEEL_CAPTURE_STAGE_PLANE_FIRST + PEEL_GROUPS + 1);
const gpu::TextureState PEEL_TRANSFER_STATE @private = {
    .layout = gpu::TextureLayout.TRANSFER_SOURCE,
    .stages = { .transfer },
    .access = { .read },
};

struct PeelSurface @private {
    Vec4 bounds;
    Vec4 color;
    float depth;
    float coverage;
    uint kind;
    uint node;
    uint part;
    uint instance;
    uint primitive;
    uint reader;
    Vec4 plane;
    uint range;
    uint[3] padding;
}
$assert PeelSurface::size == 96;

struct PeelDraw @private {
    gpu::GpuAddress surfaces;
    uint first;
    uint entries_per_instance;
    uint previous;
    uint selected;
    uint scene;
    uint mode;
    uint has_previous;
    uint[3] padding;
}
$assert PeelDraw::size == 48;

struct PeelCounts @private {
    gpu::GpuAddress output;
    gpu::GpuAddress surfaces;
    uint selected;
    uint count;
    uint[2] padding;
}
$assert PeelCounts::size == 32;

struct PeelResources @private {
    Target[PEEL_GROUPS + 1] depths;
    Target[PEEL_GROUPS + 1] captured_depths;
    Target[PEEL_GROUPS + 1] capture_stage_depths;
    Target[PEEL_GROUPS] shaded_depths;
    Target color;
    Target snapshot;
    Target opaque;
    Target opaque_depth;
    Target[2] reference_color;
    Target reference_depth;
    gpu::PipelineHandle capture;
    gpu::PipelineHandle shade;
    gpu::PipelineHandle overflow;
    gpu::PipelineHandle reference;
    gpu::MappedGpuSpan readback;
    gpu::MappedGpuSpan reference_readback;
    gpu::GpuAddress mesh_root;
    DrawRoot mesh_draw;
    uint mesh_mode;
    uint mesh_instances;
    gpu::GpuSpan mesh_indices;
}

fn char[]? compile_peel_source(
    String source,
    ShaderStage stage,
    String debug_name,
    String[] defines = {},
    asset::ShaderInclude[] includes = {},
) @private {
    String log;
    char[]? result = compile::compile_glsl(
        allocator: mem,
        source: source,
        stage: stage,
        defines: defines,
        debug_name: debug_name,
        log: &log,
        includes: includes,
    );
    defer free(log.ptr);
    if (catch err = result) {
        io::eprintfn("%s GLSL compilation failed:\n%s", debug_name, log);
        return err~;
    }
    return result;
}

fn Target? create_peel_target(gpu::Device* device, gpu::Format format, bool depth) @private {
    gpu::TextureDesc desc = {
        .width = PEEL_SIZE,
        .height = PEEL_SIZE,
        .format = format,
        .usage = depth
            ? (gpu::TextureUsage){ .depth_attach, .sampled, .transfer_src }
            : (gpu::TextureUsage){ .color_attach, .sampled, .transfer_src, .transfer_dst },
        .access = { .graphics },
        .debug_name = depth ? "transparent_capture_depth" : "transparent_capture_color",
    };
    Target target = { .format = format, .width = PEEL_SIZE, .height = PEEL_SIZE };
    target.texture = gpu::create_texture(device, &desc)!;
    defer catch (void)gpu::destroy_texture(device, target.texture);
    gpu::AttachmentViewDesc attachment = { .texture = target.texture };
    target.attachment = gpu::create_attachment_view(device, &attachment)!;
    defer catch (void)gpu::destroy_attachment_view(device, target.attachment);
    target.view = gpu::create_texture_view(device, target.texture, null)!;
    return target;
}

fn void destroy_peel_target(gpu::Device* device, Target* target) @private {
    if (!target.texture.is_valid()) return;
    gpu::destroy_texture_view(device, target.view)!!;
    gpu::destroy_attachment_view(device, target.attachment)!!;
    gpu::destroy_texture(device, target.texture)!!;
    *target = {};
}

fn void destroy_peel_resources(Renderer* renderer, PeelResources* resources) @private {
    render::wait_frames(renderer)!!;
    foreach (&target : resources.depths) destroy_peel_target(&renderer.device, target);
    foreach (&target : resources.captured_depths) destroy_peel_target(&renderer.device, target);
    foreach (&target : resources.capture_stage_depths) destroy_peel_target(&renderer.device, target);
    foreach (&target : resources.shaded_depths) destroy_peel_target(&renderer.device, target);
    destroy_peel_target(&renderer.device, &resources.color);
    destroy_peel_target(&renderer.device, &resources.snapshot);
    destroy_peel_target(&renderer.device, &resources.opaque);
    destroy_peel_target(&renderer.device, &resources.opaque_depth);
    foreach (&target : resources.reference_color) destroy_peel_target(&renderer.device, target);
    destroy_peel_target(&renderer.device, &resources.reference_depth);
    if (resources.capture.is_valid()) gpu::destroy_pipeline(&renderer.device, resources.capture)!!;
    if (resources.shade.is_valid()) gpu::destroy_pipeline(&renderer.device, resources.shade)!!;
    if (resources.overflow.is_valid()) gpu::destroy_pipeline(&renderer.device, resources.overflow)!!;
    if (resources.reference.is_valid()) gpu::destroy_pipeline(&renderer.device, resources.reference)!!;
    if (resources.readback.bytes.len) {
        gpu::GpuAllocation allocation = resources.readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    if (resources.reference_readback.bytes.len) {
        gpu::GpuAllocation allocation = resources.reference_readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
}

fn void? create_peel_resources(Renderer* renderer, PeelResources* resources) @private {
    defer catch destroy_peel_resources(renderer, resources);
    foreach (&target : resources.depths) *target = create_peel_target(&renderer.device, gpu::Format.D32_FLOAT, true)!;
    foreach (&target : resources.captured_depths) {
        *target = create_peel_target(&renderer.device, gpu::Format.R32_FLOAT, false)!;
    }
    foreach (&target : resources.capture_stage_depths) {
        *target = create_peel_target(&renderer.device, gpu::Format.R32_FLOAT, false)!;
    }
    foreach (&target : resources.shaded_depths) {
        *target = create_peel_target(&renderer.device, gpu::Format.R32_FLOAT, false)!;
    }
    resources.color = create_peel_target(&renderer.device, gpu::Format.RGBA32_FLOAT, false)!;
    resources.snapshot = create_peel_target(&renderer.device, gpu::Format.RGBA32_FLOAT, false)!;
    resources.opaque = create_peel_target(&renderer.device, gpu::Format.RGBA32_FLOAT, false)!;
    resources.opaque_depth = create_peel_target(&renderer.device, gpu::Format.R32_FLOAT, false)!;
    foreach (&target : resources.reference_color) {
        *target = create_peel_target(&renderer.device, gpu::Format.R32_FLOAT, false)!;
    }
    resources.reference_depth = create_peel_target(&renderer.device, gpu::Format.D32_FLOAT, true)!;

    char[] vertex = compile_peel_source((String)PEEL_VERTEX[..], ShaderStage.VERTEX, "transparency_peel_vertex")!;
    defer free(vertex.ptr);
    asset::ShaderInclude[1] includes = {{ .name = "transparency.glsl", .text = (String)PEEL_PARTICIPATION[..] }};
    char[] fragment = compile_peel_source(
        source: (String)PEEL_FRAGMENT[..],
        stage: ShaderStage.FRAGMENT,
        debug_name: "transparency_peel_fragment",
        includes: includes[..],
    )!;
    defer free(fragment.ptr);
    gpu::Format[2] capture_formats = { gpu::Format.R32_FLOAT, gpu::Format.R32_FLOAT };
    gpu::GraphicsPipelineDesc pipeline = {
        .vertex_shader = { .spirv = vertex, .debug_name = "transparent_invariant_vertex" },
        .fragment_shader = { .spirv = fragment, .debug_name = "transparent_participation_fragment" },
        .color_formats = capture_formats[..],
        .depth_format = gpu::Format.D32_FLOAT,
        .debug_name = "transparent_depth_capture",
    };
    resources.capture = gpu::create_graphics_pipeline(&renderer.device, &pipeline)!;
    char[] reference = compile_peel_source(
        source: (String)PEEL_REFERENCE[..],
        stage: ShaderStage.FRAGMENT,
        debug_name: "transparency_raster_reference",
    )!;
    defer free(reference.ptr);
    pipeline.fragment_shader.spirv = reference;
    pipeline.debug_name = "transparent_single_source_depth";
    resources.reference = gpu::create_graphics_pipeline(&renderer.device, &pipeline)!;
    pipeline.fragment_shader.spirv = fragment;
    gpu::Format[2] shade_formats = { gpu::Format.RGBA32_FLOAT, gpu::Format.R32_FLOAT };
    pipeline.color_formats = shade_formats[..];
    pipeline.depth_format = gpu::Format.UNDEFINED;
    pipeline.debug_name = "transparent_group_shade";
    resources.shade = gpu::create_graphics_pipeline(&renderer.device, &pipeline)!;

    char[] compute = compile_peel_source((String)PEEL_OVERFLOW[..], ShaderStage.COMPUTE, "transparency_peel_reduce")!;
    defer free(compute.ptr);
    gpu::ComputePipelineDesc overflow = {
        .shader = { .spirv = compute, .debug_name = "transparent_overflow_reduce" },
        .debug_name = "transparent_overflow_reduce",
    };
    resources.overflow = gpu::create_compute_pipeline(&renderer.device, &overflow)!;

    gpu::AllocationDesc allocation = {
        .size = PEEL_DIAGNOSTIC_OFFSET + 16,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "transparent_peel_readback",
    };
    resources.readback = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;
    allocation.size = PEEL_PLANE_BYTES * 2 * PEEL_SOURCE_CAPACITY;
    allocation.debug_name = "transparent_single_source_readback";
    resources.reference_readback = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;
}

fn gpu::GpuAddress? write_peel_draw(Renderer* renderer, PeelDraw root) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, PeelDraw::size)!;
    *(PeelDraw*)upload.bytes.ptr = root;
    return upload.address;
}

fn void? draw_peel_surface(
    Renderer* renderer,
    PeelDraw root,
    uint vertices = 6,
    uint instances = 1,
    gpu::GpuAddress mesh_root = (gpu::GpuAddress)0,
    gpu::GpuSpan index_span = {},
) @private {
    gpu::GpuAddress address = write_peel_draw(renderer, root)!;
    if (index_span.size) {
        gpu::cmd_draw_indexed(
            commands: &renderer.commands,
            vertex_root: mesh_root,
            fragment_root: address,
            index_span: index_span,
            index_count: vertices,
            instance_count: instances,
        )!;
        return;
    }
    gpu::cmd_draw(
        commands: &renderer.commands,
        vertex_root: (ulong)mesh_root ? mesh_root : address,
        fragment_root: address,
        vertex_count: vertices,
        instance_count: instances,
    )!;
}

fn void? capture_peel_group(
    Renderer* renderer,
    PeelResources* resources,
    gpu::GpuAddress surfaces,
    uint surface_count,
    uint group,
    bool batched_ties = false,
) @private {
    Target* selected = &resources.captured_depths[group];
    selected.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    resources.capture_stage_depths[group].transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    resources.depths[group].transition(&renderer.commands, render::DEPTH_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[2] color = {
        { .view = selected.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE },
        {
            .view = resources.capture_stage_depths[group].attachment,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
        },
    };
    gpu::DepthTargetDesc depth = {
        .view = resources.depths[group].attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .depth = 0 },
    };
    gpu::RenderPassDesc pass = { .colors = color[..], .depth = &depth };
    gpu::cmd_bind_pipeline(&renderer.commands, resources.capture)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::ColorTargetState[2] blends = { gpu::color_blend_disabled(), gpu::color_blend_disabled() };
    gpu::GraphicsState state = gpu::render_geometry_state(PEEL_SIZE, PEEL_SIZE)!;
    state.viewport = { .y = PEEL_SIZE, .width = PEEL_SIZE, .height = -(float)PEEL_SIZE, .max_depth = 1 };
    state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };
    state.color.targets = blends[..];
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    for (uint index = 0; index < surface_count; index++) {
        draw_peel_surface(
            renderer: renderer,
            root: {
                .surfaces = surfaces,
                .first = index,
                .entries_per_instance = batched_ties ? 2 : 1,
                .previous = group ? (uint)resources.captured_depths[group - 1].view.index : 0,
                .has_previous = group ? 1 : 0,
                .padding = { (uint)resources.opaque_depth.view.index, 0, 0 },
            },
            vertices: batched_ties ? 12 : 6,
            instances: (ulong)resources.mesh_root ? resources.mesh_instances : batched_ties ? 2 : 1,
            mesh_root: resources.mesh_root,
            index_span: resources.mesh_indices,
        )!;
        if (batched_ties || (ulong)resources.mesh_root) break;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
    selected.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
}

fn void? copy_peel_snapshot(Renderer* renderer, PeelResources* resources) @private {
    resources.color.transition(&renderer.commands, PEEL_TRANSFER_STATE)!;
    resources.snapshot.transition(&renderer.commands, {
        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer },
        .access = { .write },
    })!;
    gpu::TextureCopyDesc copy = { .src = resources.color.texture, .dst = resources.snapshot.texture };
    gpu::cmd_copy_texture(&renderer.commands, &copy)!;
    resources.snapshot.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
}

fn void? shade_peel_group(
    Renderer* renderer,
    PeelResources* resources,
    gpu::GpuAddress surfaces,
    uint[] order,
    uint group,
    uint mode,
    bool clear,
    bool batched_ties = false,
) @private {
    copy_peel_snapshot(renderer, resources)!;
    resources.color.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    Target* shade_depth = &resources.shaded_depths[group];
    shade_depth.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[2] colors = {
        {
            .view = resources.color.attachment,
            .load_op = clear ? gpu::LoadOp.CLEAR : gpu::LoadOp.LOAD,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .rgba = { 0.125f, 0.25f, 0.5f, 1 } },
        },
        { .view = shade_depth.attachment, .load_op = gpu::LoadOp.CLEAR, .store_op = gpu::StoreOp.STORE },
    };
    gpu::RenderPassDesc pass = { .colors = colors[..] };
    gpu::cmd_bind_pipeline(&renderer.commands, resources.shade)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::ColorTargetState[2] blends = { gpu::premultiplied_alpha_blend(), gpu::color_blend_disabled() };
    gpu::GraphicsState state = gpu::render_geometry_state(PEEL_SIZE, PEEL_SIZE)!;
    state.viewport = { .y = PEEL_SIZE, .width = PEEL_SIZE, .height = -(float)PEEL_SIZE, .max_depth = 1 };
    state.color.targets = blends[..];
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    foreach (index : order) {
        draw_peel_surface(
            renderer: renderer,
            root: {
                .surfaces = surfaces,
                .first = index,
                .entries_per_instance = batched_ties ? 2 : 1,
                .selected = (uint)resources.captured_depths[group].view.index,
                .scene = (uint)(mode == 1 ? resources.snapshot.view.index : resources.opaque.view.index),
                .mode = mode,
                .padding = { (uint)resources.opaque_depth.view.index, 0, 0 },
            },
            vertices: batched_ties ? 12 : 6,
            instances: (ulong)resources.mesh_root ? resources.mesh_instances : batched_ties ? 2 : 1,
            mesh_root: resources.mesh_root,
            index_span: resources.mesh_indices,
        )!;
        if (batched_ties || (ulong)resources.mesh_root) break;
    }
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? clear_peel_color(Renderer* renderer, Target* target) @private {
    target.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
    gpu::ColorTargetDesc[1] colors = {{
        .view = target.attachment,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 0.125f, 0.25f, 0.5f, 1 } },
    }};
    gpu::RenderPassDesc pass = { .colors = colors[..] };
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
    gpu::cmd_end_render_pass(&renderer.commands)!;
}

fn void? upload_peel_opaque_depth(Renderer* renderer, Target* target) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, PEEL_PLANE_BYTES)!;
    float* pixels = (float*)upload.bytes.ptr;
    for (uint y = 0; y < PEEL_SIZE; y++) {
        for (uint x = 0; x < PEEL_SIZE; x++) pixels[y * PEEL_SIZE + x] = x >= 64 ? 0.3125f : 0;
    }
    target.transition(&renderer.commands, {
        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer },
        .access = { .write },
    })!;
    gpu::BufferTextureCopyDesc copy = { .src = upload.span, .texture = target.texture };
    gpu::cmd_copy_buffer_to_texture(&renderer.commands, &copy)!;
    target.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
}

fn gpu::GpuAddress? write_peel_bytes(Renderer* renderer, char[] bytes) @private {
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, bytes.len)!;
    mem::copy(upload.bytes.ptr, bytes.ptr, (sz)bytes.len);
    return upload.address;
}

fn void? prepare_peel_mesh_root(Renderer* renderer, PeelResources* resources) @private {
    Vec3[6] positions = {
        { -0.75f, -0.75f, 0.5f }, { 0.75f, -0.75f, 0.5f }, { 0.75f, 0.75f, 0.5f },
        { -0.75f, -0.75f, 0.5f }, { 0.75f, 0.75f, 0.5f }, { -0.75f, 0.75f, 0.5f },
    };
    GeometryRoot geometry = {
        .positions = write_peel_bytes(renderer, ((char*)&positions)[:positions.len * Vec3::size])!,
        .vertex_count = 6,
    };
    FrameRoot frame = {
        .view = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .proj = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .view_proj = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .inv_view_proj = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .prev_view_proj = bitcast(matrix::IDENTITY4{float}, Mat4f),
    };
    DrawRoot root = {
        .model = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .prev_model = bitcast(matrix::IDENTITY4{float}, Mat4f),
        .normal_0 = { 1, 0, 0, 0 },
        .normal_1 = { 0, 1, 0, 0 },
        .normal_2 = { 0, 0, 1, 0 },
        .frame = write_peel_bytes(renderer, ((char*)&frame)[:FrameRoot::size])!,
    };
    resources.mesh_instances = 1;
    resources.mesh_indices = {};
    if (resources.mesh_mode == 2 || resources.mesh_mode == 5) {
        InstanceGpu[2] instances;
        foreach (&instance : instances) {
            *instance = {
                .model = bitcast(matrix::IDENTITY4{float}, Mat4f),
                .normal_0 = { 1, 0, 0, 0 },
                .normal_1 = { 0, 1, 0, 0 },
                .normal_2 = { 0, 0, 1, 0 },
                .color = { 1, 1, 1, 1 },
            };
        }
        instances[1].model[0][0] = -1;
        instances[1].model[3][2] = 0.25f;
        uint[2] indices = { 1, 0 };
        root.instance_data = write_peel_bytes(renderer, ((char*)&instances)[:instances.len * InstanceGpu::size])!;
        root.instance_indices = write_peel_bytes(renderer, ((char*)&indices)[:indices.len * uint::size])!;
        resources.mesh_instances = 2;
    }
    if (resources.mesh_mode == 3 || resources.mesh_mode == 5) {
        uint[12] joints;
        for (uint index = 0; index < 6; index++) joints[2 * index] = 1u << 16;
        float[6] blend = { 0, 0.5f, 1, 0, 1, 0.5f };
        Vec4[6] weights;
        for (uint index = 0; index < 6; index++) weights[index] = { 1 - blend[index], blend[index], 0, 0 };
        Mat4f[4] palette;
        foreach (&joint : palette) *joint = bitcast(matrix::IDENTITY4{float}, Mat4f);
        palette[1][3][2] = 0.0625f;
        palette[3][3][2] = 0.0625f;
        Vec3[12] deltas;
        for (uint index = 0; index < 6; index++) deltas[index] = { 0, 0, 0.03125f };
        MorphWeightsGpu[2] morphs;
        foreach (&morph : morphs) {
            morph.count = 1;
            morph.weights[0] = 0.5f;
        }
        geometry.joints = write_peel_bytes(renderer, ((char*)&joints)[:joints.len * uint::size])!;
        geometry.weights = write_peel_bytes(renderer, ((char*)&weights)[:weights.len * Vec4::size])!;
        geometry.morph_deltas = write_peel_bytes(renderer, ((char*)&deltas)[:deltas.len * Vec3::size])!;
        geometry.morph_target_count = 1;
        root.skin = write_peel_bytes(renderer, ((char*)&palette)[:palette.len * Mat4f::size])!;
        root.morph = write_peel_bytes(renderer, ((char*)&morphs)[:morphs.len * MorphWeightsGpu::size])!;
        root.skin_stride = 2;
    }
    if (resources.mesh_mode == 6) {
        uint[6] reversed = { 0, 2, 1, 3, 5, 4 };
        Frame* frame_slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan indices = frame_slot.upload.take(&renderer.device, reversed.len * uint::size)!;
        mem::copy(indices.bytes.ptr, &reversed, (sz)(reversed.len * uint::size));
        resources.mesh_indices = indices.span;
    }
    if (resources.mesh_mode == 4) {
        positions = {
            { -0.75f, -0.75f, 0 }, { 0.75f, -0.75f, 0 }, { 0.75f, 0.75f, 0 },
            { -0.75f, -0.75f, 0 }, { 0.75f, 0.75f, 0 }, { -0.75f, 0.75f, 0 },
        };
        geometry.positions = write_peel_bytes(renderer, ((char*)&positions)[:positions.len * Vec3::size])!;
        BillboardGpu billboard = {
            .position_width = { 0, 0, 0.5f, 1 },
            .direction_height = { 0, 1, 0, 1 },
            .color = { 1, 1, 1, 1 },
        };
        root.instance_data = write_peel_bytes(renderer, ((char*)&billboard)[:BillboardGpu::size])!;
    }
    root.geometry = write_peel_bytes(renderer, ((char*)&geometry)[:GeometryRoot::size])!;
    resources.mesh_draw = root;
    resources.mesh_root = write_peel_bytes(renderer, ((char*)&root)[:DrawRoot::size])!;
}

fn void? configure_peel_mesh_pipelines(Renderer* renderer, PeelResources* resources, uint mode) @private {
    render::wait_frames(renderer)!;
    String[3] defines;
    uint count;
    if (mode == 2 || mode == 5) defines[count++] = "INSTANCED";
    if (mode == 3 || mode == 5) {
        defines[count++] = "SKINNED_U16";
        defines[count++] = "MORPH";
    }
    asset::ShaderInclude[3] includes = {
        { .name = "transparency_mesh_body.glsl", .text = (String)PEEL_MESH_BODY[12..] },
        { .name = "transparency_billboard_body.glsl", .text = (String)PEEL_BILLBOARD_BODY[12..] },
        { .name = "transparency.glsl", .text = (String)PEEL_PARTICIPATION[..] },
    };
    char[] vertex = compile_peel_source(
        source: mode == 4 ? (String)PEEL_BILLBOARD_VERTEX[..] : (String)PEEL_MESH_VERTEX[..],
        stage: ShaderStage.VERTEX,
        debug_name: mode == 4 ? "transparency_peel_billboard" : "transparency_peel_mesh",
        defines: defines[:count],
        includes: includes[..],
    )!;
    defer free(vertex.ptr);
    String[1] mesh_input = { "MESH_VERTEX_PATH" };
    char[] fragment = compile_peel_source(
        source: (String)PEEL_FRAGMENT[..],
        stage: ShaderStage.FRAGMENT,
        debug_name: "transparency_peel_mesh_fragment",
        defines: mesh_input[..],
        includes: includes[..],
    )!;
    defer free(fragment.ptr);
    gpu::Format[2] capture_formats = { gpu::Format.R32_FLOAT, gpu::Format.R32_FLOAT };
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader = { .spirv = vertex, .debug_name = "transparent_shared_mesh_vertex" },
        .fragment_shader = { .spirv = fragment, .debug_name = "transparent_mesh_participation" },
        .color_formats = capture_formats[..],
        .depth_format = gpu::Format.D32_FLOAT,
        .debug_name = "transparent_mesh_depth_capture",
    };
    gpu::PipelineHandle capture = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    defer catch (void)gpu::destroy_pipeline(&renderer.device, capture);
    char[] reference_fragment = compile_peel_source(
        source: (String)PEEL_REFERENCE[..],
        stage: ShaderStage.FRAGMENT,
        debug_name: "transparency_mesh_raster_reference",
        defines: mesh_input[..],
    )!;
    defer free(reference_fragment.ptr);
    desc.fragment_shader.spirv = reference_fragment;
    desc.debug_name = "transparent_mesh_single_source_depth";
    gpu::PipelineHandle reference = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    defer catch (void)gpu::destroy_pipeline(&renderer.device, reference);
    desc.fragment_shader.spirv = fragment;
    gpu::Format[2] shade_formats = { gpu::Format.RGBA32_FLOAT, gpu::Format.R32_FLOAT };
    desc.color_formats = shade_formats[..];
    desc.depth_format = gpu::Format.UNDEFINED;
    desc.debug_name = "transparent_mesh_group_shade";
    gpu::PipelineHandle shade = gpu::create_graphics_pipeline(&renderer.device, &desc)!;
    gpu::destroy_pipeline(&renderer.device, resources.capture)!;
    gpu::destroy_pipeline(&renderer.device, resources.shade)!;
    gpu::destroy_pipeline(&renderer.device, resources.reference)!;
    resources.capture = capture;
    resources.shade = shade;
    resources.reference = reference;
    resources.mesh_mode = mode;
}

fn void? read_peel_target(
    Renderer* renderer,
    PeelResources* resources,
    Target* target,
    usz offset,
    usz bytes,
) @private {
    target.transition(&renderer.commands, PEEL_TRANSFER_STATE)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = target.texture,
        .dst = resources.readback.span.checked_subspan(offset, bytes)!,
    };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
}

fn void? record_peel_raster_reference(
    Renderer* renderer,
    PeelResources* resources,
    gpu::GpuAddress surfaces,
    uint count,
) @private {
    for (uint source = 0; source < count; source++) {
        foreach (&target : resources.reference_color) {
            target.transition(&renderer.commands, render::COLOR_ATTACHMENT_STATE)!;
        }
        resources.reference_depth.transition(&renderer.commands, render::DEPTH_ATTACHMENT_STATE)!;
        gpu::ColorTargetDesc[2] colors = {
            {
                .view = resources.reference_color[0].attachment,
                .load_op = gpu::LoadOp.CLEAR,
                .store_op = gpu::StoreOp.STORE,
            },
            {
                .view = resources.reference_color[1].attachment,
                .load_op = gpu::LoadOp.CLEAR,
                .store_op = gpu::StoreOp.STORE,
            },
        };
        gpu::DepthTargetDesc depth = {
            .view = resources.reference_depth.attachment,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
        };
        gpu::RenderPassDesc pass = { .colors = colors[..], .depth = &depth };
        gpu::cmd_bind_pipeline(&renderer.commands, resources.reference)!;
        gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;
        gpu::ColorTargetState[2] blends = { gpu::color_blend_disabled(), gpu::color_blend_disabled() };
        gpu::GraphicsState state = gpu::render_geometry_state(PEEL_SIZE, PEEL_SIZE)!;
        state.viewport = { .y = PEEL_SIZE, .width = PEEL_SIZE, .height = -(float)PEEL_SIZE, .max_depth = 1 };
        state.depth = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.GREATER };
        state.color.targets = blends[..];
        gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
        gpu::GpuAddress vertex_root = (gpu::GpuAddress)0;
        if (resources.mesh_mode) {
            DrawRoot selected = resources.mesh_draw;
            selected.instance_indices = write_peel_bytes(renderer, ((char*)&source)[:uint::size])!;
            vertex_root = write_peel_bytes(renderer, ((char*)&selected)[:DrawRoot::size])!;
        }
        draw_peel_surface(
            renderer: renderer,
            root: { .surfaces = surfaces, .first = source, .entries_per_instance = 1 },
            mesh_root: vertex_root,
            index_span: resources.mesh_indices,
        )!;
        gpu::cmd_end_render_pass(&renderer.commands)!;
        resources.reference_color[0].transition(&renderer.commands, PEEL_TRANSFER_STATE)!;
        resources.reference_depth.transition(&renderer.commands, PEEL_TRANSFER_STATE)!;
        usz color_offset = PEEL_PLANE_BYTES * (usz)(2 * source);
        usz depth_offset = PEEL_PLANE_BYTES * (usz)(2 * source + 1);
        gpu::TextureBufferCopyDesc color_copy = {
            .texture = resources.reference_color[0].texture,
            .dst = resources.reference_readback.span.checked_subspan(color_offset, PEEL_PLANE_BYTES)!,
        };
        gpu::cmd_copy_texture_to_buffer(&renderer.commands, &color_copy)!;
        gpu::TextureBufferCopyDesc depth_copy = {
            .texture = resources.reference_depth.texture,
            .dst = resources.reference_readback.span.checked_subspan(depth_offset, PEEL_PLANE_BYTES)!,
        };
        gpu::cmd_copy_texture_to_buffer(&renderer.commands, &depth_copy)!;
    }
}

fn void? run_peel_fixture(
    Renderer* renderer,
    PeelResources* resources,
    PeelSurface[] surfaces,
    uint[] sorted_order,
    uint[] canonical_order,
    uint cap,
    bool batched_ties = false,
) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan upload = frame.upload.take(&renderer.device, surfaces.len * PeelSurface::size)!;
    mem::copy(upload.bytes.ptr, surfaces.ptr, (sz)(surfaces.len * PeelSurface::size));
    if (resources.mesh_mode) prepare_peel_mesh_root(renderer, resources)!;
    record_peel_raster_reference(
        renderer: renderer,
        resources: resources,
        surfaces: upload.address,
        count: (uint)surfaces.len,
    )!;
    clear_peel_color(renderer, &resources.color)!;
    clear_peel_color(renderer, &resources.opaque)!;
    upload_peel_opaque_depth(renderer, &resources.opaque_depth)!;
    resources.opaque.transition(&renderer.commands, render::FRAGMENT_READ_STATE)!;
    for (uint group = 0; group <= cap; group++) {
        capture_peel_group(
            renderer: renderer,
            resources: resources,
            surfaces: upload.address,
            surface_count: (uint)surfaces.len,
            group: group,
            batched_ties: batched_ties,
        )!;
    }
    shade_peel_group(
        renderer: renderer,
        resources: resources,
        surfaces: upload.address,
        order: sorted_order,
        group: cap - 1,
        mode: 2,
        clear: true,
        batched_ties: batched_ties,
    )!;
    for (uint remaining = cap; remaining > 0; remaining--) {
        shade_peel_group(
            renderer: renderer,
            resources: resources,
            surfaces: upload.address,
            order: canonical_order,
            group: remaining - 1,
            mode: 1,
            clear: false,
            batched_ties: batched_ties,
        )!;
        read_peel_target(
            renderer: renderer,
            resources: resources,
            target: &resources.shaded_depths[remaining - 1],
            offset: PEEL_PLANE_BYTES * (usz)(4 + 2 * (PEEL_GROUPS + 1) + remaining - 1),
            bytes: PEEL_PLANE_BYTES,
        )!;
    }
    shade_peel_group(
        renderer: renderer,
        resources: resources,
        surfaces: upload.address,
        order: sorted_order,
        group: 0,
        mode: 3,
        clear: false,
        batched_ties: batched_ties,
    )!;
    read_peel_target(
        renderer: renderer,
        resources: resources,
        target: &resources.color,
        offset: 0,
        bytes: PEEL_PLANE_BYTES * 4,
    )!;
    for (uint group = 0; group <= cap; group++) {
        read_peel_target(
            renderer: renderer,
            resources: resources,
            target: &resources.captured_depths[group],
            offset: PEEL_PLANE_BYTES * (usz)(4 + 2 * group),
            bytes: PEEL_PLANE_BYTES,
        )!;
        read_peel_target(
            renderer: renderer,
            resources: resources,
            target: &resources.depths[group],
            offset: PEEL_PLANE_BYTES * (usz)(5 + 2 * group),
            bytes: PEEL_PLANE_BYTES,
        )!;
        read_peel_target(
            renderer: renderer,
            resources: resources,
            target: &resources.capture_stage_depths[group],
            offset: PEEL_PLANE_BYTES * (usz)(PEEL_CAPTURE_STAGE_PLANE_FIRST + group),
            bytes: PEEL_PLANE_BYTES,
        )!;
    }
    resources.captured_depths[cap].transition(&renderer.commands, {
        .layout = gpu::TextureLayout.SAMPLED,
        .stages = { .compute },
        .access = { .read },
    })!;
    PeelCounts count = {
        .output = (gpu::GpuAddress)((ulong)resources.readback.address + PEEL_DIAGNOSTIC_OFFSET),
        .surfaces = upload.address,
        .selected = (uint)resources.captured_depths[cap].view.index,
        .count = (uint)surfaces.len,
    };
    gpu::GpuAddress count_root = write_peel_bytes(renderer, ((char*)&count)[:PeelCounts::size])!;
    gpu::cmd_bind_pipeline(&renderer.commands, resources.overflow)!;
    gpu::cmd_dispatch(&renderer.commands, count_root, { 1, 1, 1 })!;
    gpu::Barrier host = { .before = { .transfer, .compute }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, resources.readback.span)!;
    gpu::invalidate_mapped_span(&renderer.device, resources.reference_readback.span)!;
}

fn bool peel_covers(PeelSurface surface, uint x, uint y) @private {
    double px = 2 * ((double)x + 0.5) / PEEL_SIZE - 1;
    double py = 1 - 2 * ((double)y + 0.5) / PEEL_SIZE;
    return px > surface.bounds.x && px < surface.bounds.z && py > surface.bounds.y && py < surface.bounds.w;
}

fn PeelSurface peel_surface_at(PeelSurface surface, uint x, uint y) @private {
    double px = 2 * ((double)x + 0.5) / PEEL_SIZE - 1;
    double py = 1 - 2 * ((double)y + 0.5) / PEEL_SIZE;
    surface.depth = (float)((double)surface.depth + (double)surface.plane.x * px + (double)surface.plane.y * py);
    return surface;
}

fn PeelSurface peel_reference_surface_at(
    PeelResources* resources,
    PeelSurface surface,
    uint source,
    uint x,
    uint y,
) @private {
    float* reference = (float*)resources.reference_readback.bytes.ptr;
    uint pixel = y * PEEL_SIZE + x;
    float sampled = reference[2 * source * PEEL_PIXELS + pixel];
    float stored = reference[(2 * source + 1) * PEEL_PIXELS + pixel];
    assert(bitcast(sampled, uint) == bitcast(stored, uint), "Independent raster reference depth planes disagree.");
    bool covered = peel_covers(surface, x, y);
    float analytic = covered ? peel_surface_at(surface, x, y).depth : 0;
    assert(math::abs((double)stored - analytic) <= PEEL_ANALYTIC_DEPTH_TOLERANCE,
        "Independent raster depth disagrees with the fixture geometry.");
    if (surface.plane.x == 0 && surface.plane.y == 0) {
        assert(bitcast(stored, uint) == bitcast(analytic, uint), "Constant and adjacent flat depth keys changed.");
    }
    surface.depth = stored;
    return surface;
}

fn transparency_fixtures::DepthFragment peel_reference_fragment(PeelSurface surface, float opaque) @private {
    transparency_fixtures::ReaderMode reader = transparency_fixtures::ReaderMode.NONE;
    if (surface.kind == 1 || surface.kind == 2) reader = transparency_fixtures::ReaderMode.COLOR;
    if ((surface.kind == 1 || surface.kind == 2) && surface.reader == 2) {
        reader = transparency_fixtures::ReaderMode.DEPTH;
    }
    if ((surface.kind == 1 || surface.kind == 2) && surface.reader == 3) {
        reader = transparency_fixtures::ReaderMode.COLOR_DEPTH;
    }
    return {
        .depth = surface.depth,
        .node_index = surface.node,
        .node_generation = 1,
        .part_index = surface.part,
        .range_index = surface.range,
        .instance_index = surface.instance,
        .primitive_index = surface.primitive,
        .radiance = { surface.color.x, surface.color.y, surface.color.z },
        .coverage = surface.coverage,
        .reader = reader,
        .opaque_depth = opaque,
    };
}

fn void check_peel_fixture(
    PeelResources* resources,
    PeelSurface[] surfaces,
    uint[] sorted_order,
    uint[] canonical_order,
    uint cap,
) @private {
    float[] readback = ((float*)resources.readback.bytes.ptr)[:resources.readback.bytes.len / float::size];
    uint overflow_pixels;
    for (uint y = 0; y < PEEL_SIZE; y++) {
        for (uint x = 0; x < PEEL_SIZE; x++) {
            uint pixel = y * PEEL_SIZE + x;
            float opaque = x >= 64 ? 0.3125f : 0;
            transparency_fixtures::DepthFragment[32] ordered;
            transparency_fixtures::DepthFragment[32] sorted;
            transparency_fixtures::DepthFragment[32] fallback;
            uint ordered_count;
            uint sorted_count;
            uint fallback_count;
            foreach (index : canonical_order) {
                PeelSurface surface = peel_reference_surface_at(
                    resources: resources,
                    surface: surfaces[index],
                    source: index,
                    x: x,
                    y: y,
                );
                if (surface.kind >= 2 || surface.depth <= opaque || !peel_covers(surface, x, y)) continue;
                ordered[ordered_count++] = peel_reference_fragment(surface, opaque);
            }
            foreach (index : sorted_order) {
                PeelSurface surface = peel_reference_surface_at(
                    resources: resources,
                    surface: surfaces[index],
                    source: index,
                    x: x,
                    y: y,
                );
                if (!peel_covers(surface, x, y) || (surface.kind != 3 && surface.depth <= opaque)) continue;
                if (surface.kind >= 2) {
                    fallback[fallback_count++] = peel_reference_fragment(surface, opaque);
                } else {
                    sorted[sorted_count++] = peel_reference_fragment(surface, opaque);
                }
            }
            transparency_fixtures::order_depth_fragments(ordered[:ordered_count]);
            transparency_fixtures::DepthGroup[32] groups;
            uint group_count = transparency_fixtures::classify_depth_groups(ordered[:ordered_count], groups[..]);
            for (uint group = 0; group <= cap; group++) {
                float expected_depth = group < group_count ? groups[group].depth : 0;
                float r32 = readback[(4 + 2 * group) * PEEL_PIXELS + pixel];
                float d32 = readback[(5 + 2 * group) * PEEL_PIXELS + pixel];
                float capture_stage = readback[(PEEL_CAPTURE_STAGE_PLANE_FIRST + group) * PEEL_PIXELS + pixel];
                if (bitcast(r32, uint) != bitcast(expected_depth, uint)
                    || bitcast(d32, uint) != bitcast(expected_depth, uint)
                    || bitcast(capture_stage, uint) != bitcast(expected_depth, uint)) {
                    io::eprintfn(
                        "depth mismatch pixel=(%s,%s) group=%s cap=%s expected=%08x r32=%08x d32=%08x stage=%08x",
                        x,
                        y,
                        group,
                        cap,
                        bitcast(expected_depth, uint),
                        bitcast(r32, uint),
                        bitcast(d32, uint),
                        bitcast(capture_stage, uint),
                    );
                    foreach (fragment : ordered[:ordered_count]) {
                        io::eprintfn(
                            "source node=%s part=%s range=%s instance=%s primitive=%s depth=%08x",
                            fragment.node_index,
                            fragment.part_index,
                            fragment.range_index,
                            fragment.instance_index,
                            fragment.primitive_index,
                            bitcast(fragment.depth, uint),
                        );
                    }
                }
                assert(bitcast(r32, uint) == bitcast(expected_depth, uint)
                    && bitcast(d32, uint) == bitcast(expected_depth, uint)
                    && bitcast(capture_stage, uint) == bitcast(expected_depth, uint),
                    "Captured group membership or stored depth changed.");
                if (group < cap) {
                    float shaded = readback[(4 + 2 * (PEEL_GROUPS + 1) + group) * PEEL_PIXELS + pixel];
                    assert(bitcast(shaded, uint) == bitcast(expected_depth, uint),
                        "Capture and shading stored different depth bits.");
                }
            }
            if (group_count > cap) overflow_pixels++;
            transparency_fixtures::Color expected = transparency_fixtures::compose_hybrid(
                ordered: ordered[:ordered_count],
                groups: groups[:group_count],
                capacity: cap,
                sorted: sorted[:sorted_count],
                background: transparency_fixtures::PLANAR_BACKGROUND,
            );
            expected = transparency_fixtures::compose_sorted(
                fallback[:fallback_count], expected, transparency_fixtures::PLANAR_BACKGROUND,
            );
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::abs((double)readback[4 * pixel + channel] - expected[channel]) <= 2e-5,
                    "Hybrid composition dropped, duplicated or reordered a fragment.");
            }
            assert(readback[4 * pixel + 3] == 1);
        }
    }
    uint* diagnostics = (uint*)(resources.readback.bytes.ptr + PEEL_DIAGNOSTIC_OFFSET);
    assert(diagnostics[0] == overflow_pixels && diagnostics[1] == (overflow_pixels ? 1u : 0u),
        "Extra-peel overflow reduction disagrees with independent membership.");
    uint fallback_entries;
    foreach (surface : surfaces) fallback_entries += surface.kind >= 2 ? 1 : 0;
    assert(diagnostics[2] == fallback_entries, "The nonparticipating source count changed.");
    io::printfn("transparent peel cap=%s overflow_pixels=%s depth_groups=exact color=cpu_equal",
        cap, overflow_pixels);
}
fn void test_attachment_peeling_preserves_exact_ties_and_the_sorted_remainder() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    PeelSurface[9] surfaces;
    Vec4[6] colors = {
        { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 },
        { 1, 1, 0, 1 }, { 0, 1, 1, 1 }, { 1, 0, 1, 1 },
    };
    float[6] coverage = { 0.25f, 0.5f, 0.75f, 0.25f, 0.5f, 0.75f };
    for (uint index = 0; index < 6; index++) {
        surfaces[index] = {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = colors[index], .depth = 0.75f - 0.125f * (float)index,
            .coverage = coverage[index], .node = index,
        };
    }
    surfaces[6] = surfaces[2]; surfaces[6].color = { 1, 0.25f, 0.5f, 1 }; surfaces[6].node = 6;
    surfaces[7] = surfaces[2]; surfaces[7].color = { 0.25f, 1, 0.5f, 1 }; surfaces[7].node = 7;
    surfaces[8] = surfaces[2]; surfaces[8].depth = 0x1.000002p-1f; surfaces[8].node = 8;
    uint[9] canonical = { 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    uint[9] sorted = { 5, 4, 3, 7, 2, 6, 8, 1, 0 };
    uint[3] caps = { 1, 2, 4 };
    foreach (cap : caps) {
        run_peel_fixture(
            renderer: &fixture.renderer,
            resources: &resources,
            surfaces: surfaces[..],
            sorted_order: sorted[..],
            canonical_order: canonical[..],
            cap: cap,
        )!!;
        check_peel_fixture(
            resources: &resources,
            surfaces: surfaces[..],
            sorted_order: sorted[..],
            canonical_order: canonical[..],
            cap: cap,
        );
    }
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_keeps_single_draw_instance_and_primitive_order() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    PeelSurface[4] surfaces;
    Vec4[4] colors = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 0, 1 } };
    for (uint index = 0; index < 4; index++) {
        surfaces[index] = {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = colors[index],
            .depth = 0.5f,
            .coverage = 0.5f,
            .node = 1,
            .instance = index / 2,
            .primitive = index % 2,
        };
    }
    uint[4] order = { 0, 1, 2, 3 };
    run_peel_fixture(
        renderer: &fixture.renderer,
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
        batched_ties: true,
    )!!;
    check_peel_fixture(
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
    );
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_custom_readers_and_fallback_keep_every_fragment() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    PeelSurface[7] surfaces;
    Vec4[7] colors = {
        { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 },
        { 1, 1, 0, 1 }, { 0, 1, 1, 1 }, { 1, 0, 1, 1 }, { 0.25f, 0.5f, 1, 1 },
    };
    for (uint index = 0; index < 7; index++) {
        surfaces[index] = {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = colors[index],
            .depth = 0.875f - 0.125f * (float)index,
            .coverage = 0.5f,
            .node = index,
        };
    }
    surfaces[1].kind = 1;
    surfaces[3].kind = 1;
    surfaces[4].kind = 2;
    surfaces[6].kind = 3;
    uint[7] canonical = { 0, 1, 2, 3, 4, 5, 6 };
    uint[7] sorted = { 6, 5, 4, 3, 2, 1, 0 };
    uint[3] caps = { 1, 2, 4 };
    for (uint reader = 1; reader <= 3; reader++) {
        surfaces[1].reader = reader;
        surfaces[3].reader = reader;
        surfaces[4].reader = reader;
        foreach (cap : caps) {
            run_peel_fixture(
                renderer: &fixture.renderer,
                resources: &resources,
                surfaces: surfaces[..],
                sorted_order: sorted[..],
                canonical_order: canonical[..],
                cap: cap,
            )!!;
            check_peel_fixture(
                resources: &resources,
                surfaces: surfaces[..],
                sorted_order: sorted[..],
                canonical_order: canonical[..],
                cap: cap,
            );
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_shared_mesh_instance_and_billboard_depths_are_identical() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    PeelSurface[2] surfaces = {
        {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = { 1, 0, 0, 1 },
            .depth = 0.5f,
            .coverage = 0.5f,
            .node = 1,
        },
        {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = { 0, 1, 0, 1 },
            .depth = 0.75f,
            .coverage = 0.5f,
            .node = 1,
            .instance = 1,
        },
    };
    uint[2] order = { 0, 1 };
    uint[3] modes = { 1, 2, 4 };
    foreach (mode : modes) {
        configure_peel_mesh_pipelines(&fixture.renderer, &resources, mode)!!;
        uint count = mode == 2 ? 2 : 1;
        run_peel_fixture(
            renderer: &fixture.renderer,
            resources: &resources,
            surfaces: surfaces[:count],
            sorted_order: order[:count],
            canonical_order: order[:count],
            cap: 2,
        )!!;
        check_peel_fixture(
            resources: &resources,
            surfaces: surfaces[:count],
            sorted_order: order[:count],
            canonical_order: order[:count],
            cap: 2,
        );
        io::printfn("transparent shared vertex path=%s capture/shade_bits=identical", mode);
    }
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_shared_skin_and_morph_depths_are_identical() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    configure_peel_mesh_pipelines(&fixture.renderer, &resources, 3)!!;
    PeelSurface[1] surfaces = {{
        .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
        .color = { 1, 0, 0, 1 },
        .depth = 0.5f,
        .coverage = 0.5f,
        .node = 1,
    }};
    uint[1] order = { 0 };
    run_peel_fixture(
        renderer: &fixture.renderer,
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
    )!!;
    float[] readback = ((float*)resources.readback.bytes.ptr)[:resources.readback.bytes.len / float::size];
    double maximum_depth_error;
    uint covered;
    for (uint y = 0; y < PEEL_SIZE; y++) {
        for (uint x = 0; x < PEEL_SIZE; x++) {
            uint pixel = y * PEEL_SIZE + x;
            bool inside = peel_covers(surfaces[0], x, y);
            double px = 2 * ((double)x + 0.5) / PEEL_SIZE - 1;
            double py = 1 - 2 * ((double)y + 0.5) / PEEL_SIZE;
            double bone_weight = ((px + 0.75) + (py + 0.75)) / 3;
            double expected = inside ? 0.5 + 0.03125 * 0.5 + 0.0625 * bone_weight : 0;
            float captured = readback[4 * PEEL_PIXELS + pixel];
            float depth = readback[5 * PEEL_PIXELS + pixel];
            float stage = readback[PEEL_CAPTURE_STAGE_PLANE_FIRST * PEEL_PIXELS + pixel];
            float shaded = readback[PEEL_SHADE_PLANE_FIRST * PEEL_PIXELS + pixel];
            float* reference = (float*)resources.reference_readback.bytes.ptr;
            float source_depth = reference[pixel];
            float source_stored = reference[PEEL_PIXELS + pixel];
            assert(bitcast(captured, uint) == bitcast(depth, uint)
                && bitcast(captured, uint) == bitcast(stage, uint)
                && bitcast(captured, uint) == bitcast(shaded, uint)
                && bitcast(captured, uint) == bitcast(source_depth, uint)
                && bitcast(captured, uint) == bitcast(source_stored, uint),
                "Shared skin/morph vertex output changed across capture and shade.");
            double error = math::abs((double)captured - expected);
            maximum_depth_error = math::max(maximum_depth_error, error);
            assert(error <= 2e-7, "Deformed depth disagrees with the independent affine plane.");
            transparency_fixtures::Color color = transparency_fixtures::PLANAR_BACKGROUND;
            if (inside) {
                covered++;
                color = transparency_fixtures::compose_over(color, { 1, 0, 0 }, 0.5);
            }
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::abs((double)readback[4 * pixel + channel] - color[channel]) <= 2e-5);
            }
        }
    }
    assert(covered == 96 * 96);
    uint* diagnostics = (uint*)(resources.readback.bytes.ptr + PEEL_DIAGNOSTIC_OFFSET);
    assert(diagnostics[0] == 0 && diagnostics[1] == 0);
    io::printfn("transparent shared skin/morph covered=%s depth_error=%s bits=identical",
        covered, maximum_depth_error);
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_dense_overflow_counts_every_pixel() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    transparency_fixtures::DepthFragment[17] fragments;
    transparency_fixtures::make_dense_fragments(fragments[..]);
    PeelSurface[17] surfaces;
    uint[17] sorted;
    uint[17] canonical;
    foreach (uint index, fragment : fragments) {
        surfaces[index] = {
            .bounds = { -0.125f, -0.125f, 0.125f, 0.125f },
            .color = { (float)fragment.radiance.x, (float)fragment.radiance.y, (float)fragment.radiance.z, 1 },
            .depth = fragment.depth,
            .coverage = (float)fragment.coverage,
            .node = index,
        };
        canonical[index] = index;
        sorted[index] = (uint)fragments.len - 1 - index;
    }
    run_peel_fixture(
        renderer: &fixture.renderer,
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: sorted[..],
        canonical_order: canonical[..],
        cap: 4,
    )!!;
    check_peel_fixture(
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: sorted[..],
        canonical_order: canonical[..],
        cap: 4,
    );
    uint* diagnostics = (uint*)(resources.readback.bytes.ptr + PEEL_DIAGNOSTIC_OFFSET);
    assert(diagnostics[0] == 256 && diagnostics[1] == 1);
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_interleaves_batches_meshes_and_crossing_sheets() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    float[7] depths = { 0.75f, 0.25f, 0.5f, 0.625f, 0.375f, 0.5f, 0.5f };
    Vec4[7] colors = {
        { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 },
        { 1, 1, 0, 1 }, { 0, 1, 1, 1 }, { 1, 0, 1, 1 }, { 0.25f, 0.5f, 1, 1 },
    };
    PeelSurface[7] surfaces;
    for (uint index = 0; index < surfaces.len; index++) {
        surfaces[index] = {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = colors[index],
            .depth = depths[index],
            .coverage = 0.5f,
            .node = index < 2 ? 0 : index < 3 ? 1 : index < 5 ? 2 : index - 2,
            .instance = index == 1 || index == 4 ? 1 : 0,
        };
    }
    surfaces[5].plane.x = 0.0625f;
    surfaces[6].plane.x = -0.0625f;
    uint[7] canonical = { 0, 1, 2, 3, 4, 5, 6 };
    uint[7] sorted = { 1, 0, 2, 4, 3, 5, 6 };
    uint[3] caps = { 1, 2, 4 };
    foreach (cap : caps) {
        run_peel_fixture(
            renderer: &fixture.renderer,
            resources: &resources,
            surfaces: surfaces[..],
            sorted_order: sorted[..],
            canonical_order: canonical[..],
            cap: cap,
        )!!;
        check_peel_fixture(
            resources: &resources,
            surfaces: surfaces[..],
            sorted_order: sorted[..],
            canonical_order: canonical[..],
            cap: cap,
        );
    }
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_exact_ties_follow_source_part_range_and_primitive_identity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    Vec4[5] colors = {
        { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 0, 1 }, { 1, 0, 1, 1 },
    };
    uint[5] parts = { 2, 0, 0, 1, 0 };
    uint[5] ranges = { 0, 1, 0, 0, 0 };
    PeelSurface[5] surfaces;
    for (uint index = 0; index < surfaces.len; index++) {
        surfaces[index] = {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = colors[index],
            .depth = 0.5f,
            .coverage = 0.5f,
            .node = 5,
            .part = parts[index],
            .range = ranges[index],
            .primitive = index == 4 ? 1 : 0,
        };
    }
    uint[5] canonical = { 2, 4, 1, 3, 0 };
    uint[5] sorted = { 0, 3, 2, 1, 4 };
    run_peel_fixture(
        renderer: &fixture.renderer,
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: sorted[..],
        canonical_order: canonical[..],
        cap: 1,
    )!!;
    check_peel_fixture(
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: sorted[..],
        canonical_order: canonical[..],
        cap: 1,
    );
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_remapped_instanced_skin_and_morph_depths_are_identical() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    configure_peel_mesh_pipelines(&fixture.renderer, &resources, 5)!!;
    PeelSurface[2] surfaces = {
        {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = { 1, 0, 0, 1 },
            .depth = 0.546875f,
            .coverage = 0.5f,
            .node = 1,
            .plane = { 0.0625f / 3, 0.0625f / 3, 0, 0 },
        },
        {
            .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
            .color = { 0, 1, 0, 1 },
            .depth = 0.796875f,
            .coverage = 0.5f,
            .node = 1,
            .instance = 1,
            .plane = { -0.0625f / 3, 0.0625f / 3, 0, 0 },
        },
    };
    uint[2] order = { 0, 1 };
    run_peel_fixture(
        renderer: &fixture.renderer,
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
    )!!;
    check_peel_fixture(
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
    );
    check_validation(&fixture.renderer);
}

fn void test_attachment_peeling_reversed_indices_preserve_depth_and_coverage() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PeelResources resources;
    create_peel_resources(&fixture.renderer, &resources)!!;
    defer destroy_peel_resources(&fixture.renderer, &resources);
    configure_peel_mesh_pipelines(&fixture.renderer, &resources, 6)!!;
    PeelSurface[1] surfaces = {{
        .bounds = { -0.75f, -0.75f, 0.75f, 0.75f },
        .color = { 1, 0, 0, 1 },
        .depth = 0.5f,
        .coverage = 0.5f,
        .node = 1,
    }};
    uint[1] order = { 0 };
    run_peel_fixture(
        renderer: &fixture.renderer,
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
    )!!;
    check_peel_fixture(
        resources: &resources,
        surfaces: surfaces[..],
        sorted_order: order[..],
        canonical_order: order[..],
        cap: 2,
    );
    check_validation(&fixture.renderer);
}
