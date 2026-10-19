module c3d_landscape_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::landscape::terrain;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] TRACE_PROBE_SOURCE @local = $embed("trace_probe.comp.glsl");
const uint TRACE_GROUP_SIZE @local = 8; // mirrored as local_size_x and _y in trace_probe.comp.glsl
const uint RASTER_HIT @local = 1; // mirrored as RASTER_HIT in trace_probe.comp.glsl
const uint TRACE_HIT @local = 2; // mirrored as TRACE_HIT in trace_probe.comp.glsl
const uint PROBE_SIZE @local = 64;
const usz PROBE_PIXELS @local = PROBE_SIZE * PROBE_SIZE;
const usz PROBE_RESULT_BYTES @local = PROBE_PIXELS * TraceProbeResult::size;
const uint TRACE_TEXELS @local = 513; // four finest chunks a side, three levels
const uint TRACE_LEVEL @local = 2; // grid cells span four texels
const float TRACE_CELL_SIZE @local = 1;
const float TRACE_HEIGHT_SCALE @local = 24;
const float VIEW_ALTITUDE @local = 250; // metres: a 20 degree view spans 88 m of the 512 m map
const float VIEW_FOV_DEGREES @local = 20; // near vertical, so a vertical gap stays a gap in distance
const float VIEW_FAR @local = 1000;
const Vec2 FIRST_VIEW_CENTER @local = { 128, 128 }; // metres; the second view's footprint is outside this one's
const Vec2 SECOND_VIEW_CENTER @local = { 384, 384 };
const float ERROR_SCALE @local = 1.25f; // a ray off vertical over a slope turns a vertical gap into more distance
const float DEPTH_NOISE @local = 0.01f; // metres of float rounding in rebuilding a position from depth
const usz COVERAGE_MINIMUM @local = PROBE_PIXELS * 9 / 10; // the whole view looks at terrain
const double FRAME_STEP @local = 1.0 / 60.0;
const float EDIT_RAISE @local = 13107; // texels at the center of the edit: a fifth of the height scale
const uint EDIT_RADIUS @local = 50; // texels; the raise falls to zero at this distance
const bool[2] TRACE_KINDS @local = { false, true }; // ray_queries: software walk, then ray queries

struct TraceProbeRoot @local {
    Mat4f           inv_view_proj;
    Vec4f           camera;
    gpu::GpuAddress scene;
    gpu::GpuAddress output_address;
    uint            size;
    uint            _pad0;
    uint            _pad1;
    uint            _pad2;
}
$assert TraceProbeRoot::size == 112;

struct TraceProbeResult @local {
    float raster; // distance to the drawn surface from the view's depth
    float traced; // distance to the traced surface
    uint  flags;
    uint  padding;
}
$assert TraceProbeResult::size == 16;

struct ProbeView @local {
    RenderTargetId     target;
    ViewId             view;
    Node*              camera;
    BufferId           output;
    gpu::MappedGpuSpan readback;
}

struct TraceRig @local {
    AssetStore      assets;
    Scene           scene;
    Renderer        renderer;
    Node*           terrain_node;
    TextureId       height_map;
    ComputeShaderId walk_shader;
    ComputeShaderId query_shader;
    ProbeView[2]    views;
    TraceKind       kind;
    uint            frame;
}

struct TraceAgreement @local {
    usz   covered;  // pixels where the drawn and the traced surface both answer
    usz   mismatch; // pixels where only one does
    float worst;    // largest distance between the two over covered pixels, in metres
    float limit;    // what the terrain's trace error allows
}

// Hills a few hundred metres across under a ripple a few metres across, so the trace grid misses real detail.
fn TextureId add_rough_map(AssetStore* assets, uint side) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (sz)side * side);
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                float wave = 0.5f + 0.2f * math::sin((float)x * 0.05f) + 0.2f * math::cos((float)z * 0.07f)
                  + 0.03f * math::sin((float)x * 1.3f) * math::cos((float)z * 1.1f);
                texels[z * side + x] = (ushort)(wave * (float)ushort::max);
            }
        }
        material::TextureDesc desc = material::texture_2d_desc(side, side, R16_UINT);
        desc.generate_mips = false;
        texture = assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * ushort::size])!!;
    };
    return texture;
}

fn ProbeView? create_probe_view(TraceRig* rig, Vec2 center) @local {
    Renderer* renderer = &rig.renderer;
    RenderTargetId target = render::create_render_target(
        renderer: renderer,
        desc:     render::render_target_desc(PROBE_SIZE, PROBE_SIZE, PixelFormat.RGBA8_UNORM),
    )!;
    ViewDesc desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    Node* camera = rig.scene.add_camera(camera::perspective_deg(VIEW_FOV_DEGREES, 1, VIEW_FAR))!;
    camera.local.position = { center.x, VIEW_ALTITUDE, center.y };
    camera.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    BufferId output = renderer.create_buffer({ .size = PROBE_RESULT_BYTES, .debug_name = "terrain_trace_probe" })!;
    gpu::AllocationDesc readback_desc = {
        .size         = PROBE_RESULT_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "terrain_trace_probe_host",
    };
    return {
        .target   = target,
        .view     = render::create_view(renderer, desc)!,
        .camera   = camera,
        .output   = output,
        .readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!,
    };
}

fn ComputeShaderId? add_probe_shader(TraceRig* rig, String define) @local {
    String[1] defines = { define };
    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)TRACE_PROBE_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
        defines:   defines[..],
    )!;
    defer alloc::free(mem, spirv.ptr);
    ComputeShaderDesc desc = { .compute = spirv };
    return rig.assets.add_compute_shader(&desc);
}

fn void? create_trace_rig(TraceRig* rig, bool ray_queries) @local {
    rig.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    rig.scene = scene::create_scene(mem, scene::default_scene_desc());
    terrain::register_terrain(&rig.scene, &rig.assets)!;

    TerrainDesc desc = terrain::default_terrain_desc();
    rig.height_map = add_rough_map(&rig.assets, TRACE_TEXELS);
    desc.height_map = rig.height_map;
    desc.cell_size = TRACE_CELL_SIZE;
    desc.height_scale = TRACE_HEIGHT_SCALE;
    desc.lod_threshold = 0; // the drawn surface is the full-resolution one
    desc.trace = true;
    desc.trace_level = TRACE_LEVEL;
    StandardParams grass = { .base_color = { 0.5f, 0.6f, 0.3f, 1 }, .roughness = 1 };
    desc.layers[0] = rig.assets.add_material(material::standard(grass))!;
    rig.terrain_node = rig.scene.add_node()!;
    terrain::add_terrain(
        scene:  &rig.scene,
        assets: &rig.assets,
        node:   rig.terrain_node,
        desc:   desc,
    )!;

    rig.renderer = render::create_renderer(
        allocator: mem,
        assets:    &rig.assets,
        desc:      { .validation = true, .application_name = "terrain_trace_acceptance", .ray_queries = ray_queries },
    )!;
    rig.walk_shader = add_probe_shader(rig, "SCENE_TRACE_BVH")!;
    if (ray_queries) rig.query_shader = add_probe_shader(rig, "SCENE_TRACE_RAY_QUERY")!;
    rig.views[0] = create_probe_view(rig, FIRST_VIEW_CENTER)!;
    rig.views[1] = create_probe_view(rig, SECOND_VIEW_CENTER)!;
    rig.kind = ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
    rig.scene.update_world();
}

fn void destroy_trace_rig(TraceRig* rig) @local {
    render::wait_frames(&rig.renderer)!!;
    foreach (&probe : rig.views) {
        gpu::GpuAllocation allocation = probe.readback.span.allocation();
        gpu::free_allocation(&rig.renderer.device, &allocation)!!;
    }
    render::destroy_renderer(&rig.renderer);
    scene::destroy_scene(&rig.scene);
    asset::destroy_asset_store(&rig.assets);
}

fn void? record_probe(TraceRig* rig, ProbeView* probe, gpu::GpuAddress trace_scene) @local {
    Renderer* renderer = &rig.renderer;
    Camera* camera = rig.scene.get(probe.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, probe.camera.world, { PROBE_SIZE, PROBE_SIZE });
    TraceProbeRoot root = {
        .inv_view_proj  = bitcast(matrices.inv_view_proj, Mat4f),
        .camera         = { matrices.position.x, matrices.position.y, matrices.position.z, 1 },
        .scene          = trace_scene,
        .output_address = renderer.buffer_address(probe.output),
        .size           = PROBE_SIZE,
    };
    BufferId[1] writes = { probe.output };
    DispatchTexture[1] textures = { render::read_view_depth(probe.view, asset::SAMPLER_NEAREST) };
    uint groups = PROBE_SIZE / TRACE_GROUP_SIZE;
    renderer.dispatch({
        .shader   = rig.kind == TraceKind.HARDWARE ? rig.query_shader : rig.walk_shader,
        .root     = ((char*)&root)[:TraceProbeRoot::size],
        .groups   = { groups, groups, 1 },
        .writes   = writes[..],
        .textures = textures[..],
    })!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(probe.output).allocation)!,
        .dst = probe.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &host_read);
}

// Both views draw, then one scene trace answers the rays of both: each view's terrain is off the other's camera.
fn void? trace_frame(TraceRig* rig) @local {
    Renderer* renderer = &rig.renderer;
    rig.scene.update_world();
    terrain::update(&rig.scene, &rig.assets)!;
    renderer.begin_frame({ .time = (double)rig.frame++ * FRAME_STEP, .delta = (float)FRAME_STEP })!;
    defer catch render::abort_frame(renderer);
    foreach (&probe : rig.views) renderer.render_view(&rig.scene, probe.camera, probe.view)!;
    gpu::GpuAddress trace_scene = renderer.prepare_scene_trace(&rig.scene, rig.kind)!;
    foreach (&probe : rig.views) record_probe(rig, probe, trace_scene)!;
    foreach (&probe : rig.views) renderer.finish_view(probe.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
}

fn TraceProbeResult[] read_probe(TraceRig* rig, ProbeView* probe) @local {
    gpu::invalidate_mapped_span(&rig.renderer.device, probe.readback.span)!!;
    return ((TraceProbeResult*)probe.readback.bytes.ptr)[:PROBE_PIXELS];
}

fn TraceAgreement trace_agreement(TraceRig* rig, ProbeView* probe) @local {
    TerrainRuntime* runtime = rig.scene.get(rig.terrain_node, TerrainRuntime);
    TraceAgreement agreement = { .limit = ERROR_SCALE * runtime.trace_error + DEPTH_NOISE };
    foreach (&result : read_probe(rig, probe)) {
        bool raster = (result.flags & RASTER_HIT) != 0;
        bool traced = (result.flags & TRACE_HIT) != 0;
        if (raster != traced) {
            agreement.mismatch++;
        } else if (raster) {
            agreement.covered++;
            agreement.worst = math::max(agreement.worst, math::abs(result.traced - result.raster));
        }
    }
    return agreement;
}

fn void assert_agreement(TraceRig* rig, ProbeView* probe, ZString name) @local {
    TraceAgreement agreement = trace_agreement(rig, probe);
    float error = rig.scene.get(rig.terrain_node, TerrainRuntime).trace_error;
    io::eprintfn(
        "%s: %d covered, %d mismatched, worst %f m, trace error %f m, limit %f m",
        name,
        agreement.covered,
        agreement.mismatch,
        agreement.worst,
        error,
        agreement.limit,
    );
    assert(agreement.covered >= COVERAGE_MINIMUM && agreement.mismatch == 0);
    assert(agreement.worst <= agreement.limit);
}

fn void report_trace_counts(Renderer* renderer, ZString name) @local {
    Stats* stats = &renderer.stats;
    io::eprintfn(
        "%s: %d traced, %d posed, %d poses, %d refits, %d builds, %d updates, %d deform overflow, %d skipped",
        name,
        stats.trace_instances,
        stats.trace_posed_instances,
        stats.trace_poses,
        stats.trace_refits,
        stats.blas_builds,
        stats.blas_updates,
        stats.trace_deform_overflow,
        stats.trace_skipped,
    );
}

fn void test_traced_terrain_agrees_with_the_drawn_surface_from_two_views() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);

        trace_frame(&rig)!!;
        report_trace_counts(&rig.renderer, "terrain trace");
        assert(rig.scene.get(rig.terrain_node, TerrainRuntime).trace_error > 0);
        assert(rig.renderer.stats.trace_posed_instances == 1 && rig.renderer.stats.trace_deform_overflow == 0);
        assert(rig.renderer.stats.trace_skipped == 0 && rig.renderer.stats.shader_rejections == 0);
        assert_agreement(&rig, &rig.views[0], "first view");
        assert_agreement(&rig, &rig.views[1], "second view");
        check_validation(&rig.renderer);
    }
}

// A smooth hill, so the edit leaves the grid's error where it was and a missed pose shows as the whole raise.
fn void raise_hill(TraceRig* rig, Vec2 center) @local {
    TextureAsset* record = rig.assets.texture(rig.height_map);
    ushort* texels = (ushort*)record.pixels.ptr;
    uint column = (uint)(center.x / TRACE_CELL_SIZE);
    uint row = (uint)(center.y / TRACE_CELL_SIZE);
    TexelRect rect = {
        .x       = column - EDIT_RADIUS,
        .z       = row - EDIT_RADIUS,
        .columns = 2 * EDIT_RADIUS + 1,
        .rows    = 2 * EDIT_RADIUS + 1,
    };
    for (uint z = rect.z; z < rect.z + rect.rows; z++) {
        for (uint x = rect.x; x < rect.x + rect.columns; x++) {
            float distance = math::sqrt(math::sqr((float)x - (float)column) + math::sqr((float)z - (float)row));
            if (distance >= (float)EDIT_RADIUS) continue;

            float raise = EDIT_RAISE * 0.5f * (1 + math::cos((float)math::PI * distance / (float)EDIT_RADIUS));
            float raised = (float)texels[z * TRACE_TEXELS + x] + raise;
            texels[z * TRACE_TEXELS + x] = (ushort)min(raised, (float)ushort::max);
        }
    }
    rig.assets.mark_texture_dirty(rig.height_map);
    terrain::mark_dirty(&rig.scene, rig.terrain_node, rect);
}

fn void test_height_edit_poses_the_trace_grid_once() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);
        Renderer* renderer = &rig.renderer;

        trace_frame(&rig)!!;
        report_trace_counts(renderer, "first frame");
        assert(renderer.stats.trace_poses == 1 && renderer.stats.trace_refits == (ray_queries ? 0 : 1));
        assert(renderer.stats.blas_builds == (ray_queries ? 1 : 0) && renderer.stats.blas_updates == 0);

        trace_frame(&rig)!!;
        report_trace_counts(renderer, "still frame");
        assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_refits == 0);
        assert(renderer.stats.blas_builds == 0 && renderer.stats.blas_updates == 0);
        assert_agreement(&rig, &rig.views[0], "before the edit");

        raise_hill(&rig, FIRST_VIEW_CENTER);
        trace_frame(&rig)!!;
        report_trace_counts(renderer, "edited frame");
        assert(renderer.stats.trace_poses == 1 && renderer.stats.trace_refits == (ray_queries ? 0 : 1));
        assert(renderer.stats.blas_builds == (ray_queries ? 1 : 0) && renderer.stats.blas_updates == 0);
        assert_agreement(&rig, &rig.views[0], "after the edit, edited view");
        assert_agreement(&rig, &rig.views[1], "after the edit, other view");

        trace_frame(&rig)!!;
        assert(renderer.stats.trace_poses == 0 && renderer.stats.blas_builds == 0);
        check_validation(renderer);
    }
}
