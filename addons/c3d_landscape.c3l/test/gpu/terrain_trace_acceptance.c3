module c3d_landscape_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::landscape::terrain;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
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
const ShadingPath[2] SHADINGS @local = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
const usz TRACE_ERROR_OFFSET @local = 28; // in the material block, after the border edges, projection and sharpness
const uint SHADE_SIZE @local = 256;
const usz SHADE_BYTES @local = (usz)SHADE_SIZE * SHADE_SIZE * 4;
const float SHADE_HEIGHT_SCALE @local = 100; // metres: hills 24 m high, steep enough to shadow their valleys
const float HILL_AMPLITUDE @local = 0.12f; // of the height scale
const Vec3 SPECKLE_CAMERA @local = { 256, 400, 256 }; // over the middle of the map, 1.5 m of ground to a pixel
const float SPECKLE_FOV_DEGREES @local = 60;
const Vec3 RIDGE_SUN @local = { -0.9f, -0.34f, -0.2f }; // 20 degrees above the horizon: ridges shadow valleys
const float SPECKLE_RIPPLE @local = 0.003f; // of the height scale: 0.3 m, too small to shadow anything itself
const float FINEST_LOD @local = 0; // the finest chunks everywhere
const float COARSE_LOD @local = 512; // the default: the whole map draws as one chunk of the coarsest level
const float MIDDLE_LOD @local = 300; // the second level
const float FINE_LOD @local = 64; // the finest level again
const uint SPECKLE_EDGE @local = 40; // luminance step of an edge, out of 255
const float SPECKLE_LAPLACIAN_RATIO @local = 1.25f; // of the finest grid's mean |Laplacian|
const float SPECKLE_PIXEL_RATIO @local = 2; // of the finest grid's edge pixels
const Vec3 CREST @local = { 31.4f, 0, 89.8f }; // where the hills are level: sin(0.05 x) and cos(0.07 z) peak
const float BOX_SIZE @local = 0.5f;
const Vec3 CONTACT_CAMERA_OFFSET @local = { 0, 4, 0 }; // above the box, looking down
const float CONTACT_FOV_DEGREES @local = 40;
const Vec3 CONTACT_SUN @local = { -0.82f, -0.57f, 0 }; // 35 degrees above the horizon; the shadow falls toward -x
const float SHADOW_GAP @local = 0.12f; // metres from the box's base to the point read in its shadow
const float LIT_DISTANCE @local = 0.9f; // metres to the sun's side of the box, where the ground is lit
const float SHADOW_RATIO @local = 0.6f; // of the lit ground's luminance
const uint PATCH_FIRST @local = 440; // texels of the rough patch in the far corner of the contact map
const uint PATCH_LAST @local = 470;
const float PATCH_AMPLITUDE @local = 0.02f; // of the height scale: 2 m, above the box's height

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

// Hills a few hundred metres across, with a regular ripple the trace grid misses and a patch of rough ground in a far
// corner. The ripple is a lattice, which puts the grid's largest gap at every crest and trough.
fn TextureId add_hills_map(AssetStore* assets, uint side, float ripple, bool patch) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (sz)side * side);
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                float wave = 0.5f + HILL_AMPLITUDE * math::sin((float)x * 0.05f)
                  + HILL_AMPLITUDE * math::cos((float)z * 0.07f)
                  + ripple * math::sin((float)x * 1.3f) * math::cos((float)z * 1.1f);
                bool in_patch = x >= PATCH_FIRST && x <= PATCH_LAST && z >= PATCH_FIRST && z <= PATCH_LAST;
                if (patch && in_patch) wave += PATCH_AMPLITUDE * math::sin((float)x * (float)math::PI * 0.5f);
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

fn void assert_agreement(TraceRig* rig, ProbeView* probe) @local {
    TraceAgreement agreement = trace_agreement(rig, probe);
    assert(agreement.covered >= COVERAGE_MINIMUM && agreement.mismatch == 0);
    assert(agreement.worst <= agreement.limit);
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
        assert(rig.scene.get(rig.terrain_node, TerrainRuntime).trace_error > 0);
        assert(renderer.stats.trace_posed_instances == 1 && renderer.stats.trace_deform_overflow == 0);
        assert(renderer.stats.trace_skipped == 0 && renderer.stats.shader_rejections == 0);
        assert(renderer.stats.trace_poses == 1 && renderer.stats.trace_refits == (ray_queries ? 0 : 1));
        assert(renderer.stats.blas_builds == (ray_queries ? 1 : 0) && renderer.stats.blas_updates == 0);

        trace_frame(&rig)!!;
        assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_refits == 0);
        assert(renderer.stats.blas_builds == 0 && renderer.stats.blas_updates == 0);
        assert_agreement(&rig, &rig.views[0]);

        raise_hill(&rig, FIRST_VIEW_CENTER);
        trace_frame(&rig)!!;
        assert(renderer.stats.trace_poses == 1 && renderer.stats.trace_refits == (ray_queries ? 0 : 1));
        assert(renderer.stats.blas_builds == (ray_queries ? 1 : 0) && renderer.stats.blas_updates == 0);
        assert_agreement(&rig, &rig.views[0]);
        assert_agreement(&rig, &rig.views[1]);

        trace_frame(&rig)!!;
        assert(renderer.stats.trace_poses == 0 && renderer.stats.blas_builds == 0);
        check_validation(renderer);
    }
}

struct ShadeDesc @local {
    bool        ray_queries;
    ShadingPath shading;
    bool        patch_map;      // the contact map: smooth hills and a rough patch, instead of the rippled hills
    uint        trace_level;
    float       lod_threshold;
    Vec3        camera;         // looks straight down
    float       fov_degrees;
    Vec3        sun_direction;
    bool        without_skip;   // publishes no gaps, so no hit on the trace grid is skipped
}

struct ShadeRig @local {
    AssetStore   assets;
    Scene        scene;
    Renderer     renderer;
    Node*        terrain_node;
    Node*        camera;
    RenderTargetId target;
    ViewId       view;
    char[]       pixels;
}

fn void drop_published_gaps(ShadeRig* rig) @local {
    MaterialId material = rig.scene.get(rig.terrain_node, TerrainRuntime).material;
    char[] block = rig.assets.material(material).data.custom.param_block;

    // The trace error and the per-level drawn deviations are one run of floats in the block.
    mem::clear(block.ptr + TRACE_ERROR_OFFSET, float::size * (1 + terrain::MAX_TERRAIN_LEVELS));
    rig.assets.mark_material_dirty(material);
}

fn void? create_shade_rig(ShadeRig* rig, ShadeDesc* shade) @local {
    rig.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    rig.scene = scene::create_scene(mem, scene::default_scene_desc());
    terrain::register_terrain(&rig.scene, &rig.assets)!;

    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = add_hills_map(
        assets: &rig.assets,
        side:   TRACE_TEXELS,
        ripple: shade.patch_map ? 0 : SPECKLE_RIPPLE,
        patch:  shade.patch_map,
    );
    desc.cell_size = TRACE_CELL_SIZE;
    desc.height_scale = SHADE_HEIGHT_SCALE;
    desc.lod_threshold = shade.lod_threshold;
    desc.trace = true;
    desc.trace_level = shade.trace_level;
    StandardParams grass = { .base_color = { 0.5f, 0.6f, 0.3f, 1 }, .roughness = 1 };
    desc.layers[0] = rig.assets.add_material(material::standard(grass))!;

    rig.terrain_node = rig.scene.add_node()!;
    terrain::add_terrain(
        scene:  &rig.scene,
        assets: &rig.assets,
        node:   rig.terrain_node,
        desc:   desc,
    )!;

    if (shade.without_skip) drop_published_gaps(rig);

    Light sun = light::directional({ 1, 0.95f, 0.85f }, 3);
    sun.shadow.ray_traced = true;
    Node* sun_node = rig.scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation(shade.sun_direction.normalize(), { 0, 1, 0 });

    rig.camera = rig.scene.add_camera(camera::perspective_deg(shade.fov_degrees, 0.1f, VIEW_FAR))!;
    rig.camera.local.position = shade.camera;
    rig.camera.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    rig.scene.update_world();

    rig.renderer = render::create_renderer(
        allocator: mem,
        assets:    &rig.assets,
        desc:      {
            .validation       = true,
            .application_name = "terrain_shade_acceptance",
            .ray_queries      = shade.ray_queries,
        },
    )!;
    rig.target = render::create_render_target(
        renderer: &rig.renderer,
        desc:     render::render_target_desc(SHADE_SIZE, SHADE_SIZE, PixelFormat.RGBA8_UNORM),
    )!;
    ViewDesc view_desc = render::texture_view_desc(rig.target, OutputMode.DISPLAY_LDR);
    view_desc.shading = shade.shading;
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    view_desc.ray_tracing.shadows = true;
    rig.view = render::create_view(&rig.renderer, view_desc)!;
    rig.pixels = alloc::new_array(mem, char, SHADE_BYTES);
}

fn void destroy_shade_rig(ShadeRig* rig) @local {
    render::wait_frames(&rig.renderer)!!;
    alloc::free(mem, rig.pixels.ptr);
    render::destroy_renderer(&rig.renderer);
    scene::destroy_scene(&rig.scene);
    asset::destroy_asset_store(&rig.assets);
}

fn void? render_shade(ShadeRig* rig) @local {
    Renderer* renderer = &rig.renderer;
    rig.scene.update_world();
    terrain::update(&rig.scene, &rig.assets)!;

    renderer.begin_frame({ .time = 0, .delta = (float)FRAME_STEP })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&rig.scene, rig.camera, rig.view)!;
    renderer.finish_view(rig.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    renderer.read_render_target(rig.target, rig.pixels)!;
}

fn float luminance_at(ShadeRig* rig, uint x, uint y) @local {
    usz offset = ((usz)y * SHADE_SIZE + x) * 4;
    return ((float)rig.pixels[offset] + (float)rig.pixels[offset + 1] + (float)rig.pixels[offset + 2]) / 3;
}

struct Speckle @local {
    float mean_laplacian;
    usz   edges;
}

// Edges over the middle of the view, where the terrain's own shadows are: a speckle of false shadows adds many.
fn Speckle measure_speckle(ShadeRig* rig) @local {
    uint first = SHADE_SIZE / 4;
    uint last = SHADE_SIZE * 3 / 4;
    float total;
    usz edges;
    usz count;
    for (uint y = first; y < last; y++) {
        for (uint x = first; x < last; x++) {
            float around = luminance_at(rig, x - 1, y) + luminance_at(rig, x + 1, y)
              + luminance_at(rig, x, y - 1) + luminance_at(rig, x, y + 1);
            float step = math::abs(4 * luminance_at(rig, x, y) - around);
            total += step;
            if (step > (float)SPECKLE_EDGE) edges++;
            count++;
        }
    }
    return { .mean_laplacian = total / (float)count, .edges = edges };
}

fn Speckle render_speckle(
    bool        ray_queries,
    ShadingPath shading,
    uint        trace_level,
    float       lod_threshold,
    bool        without_skip = false,
) @local {
    ShadeDesc shade = {
        .ray_queries   = ray_queries,
        .shading       = shading,
        .trace_level   = trace_level,
        .lod_threshold = lod_threshold,
        .camera        = SPECKLE_CAMERA,
        .fov_degrees   = SPECKLE_FOV_DEGREES,
        .sun_direction = RIDGE_SUN,
        .without_skip  = without_skip,
    };
    ShadeRig rig;
    create_shade_rig(&rig, &shade)!!;
    defer destroy_shade_rig(&rig);

    render_shade(&rig)!!;
    check_validation(&rig.renderer);
    return measure_speckle(&rig);
}

struct SpeckleCase @local {
    uint  trace_level;
    float lod_threshold;
}

// Each gap in turn: the grid's alone, the drawn chunks' alone, and both.
const SpeckleCase[3] SPECKLE_CASES @local = {
    { .trace_level = TRACE_LEVEL, .lod_threshold = FINE_LOD },
    { .trace_level = 0, .lod_threshold = COARSE_LOD },
    { .trace_level = TRACE_LEVEL, .lod_threshold = MIDDLE_LOD },
};

fn void test_traced_terrain_does_not_shadow_itself() @test {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (shading : SHADINGS) {
            Speckle floor = render_speckle(
                ray_queries:   ray_queries,
                shading:       shading,
                trace_level:   0,
                lod_threshold: FINEST_LOD,
            );
            foreach (&speckle_case : SPECKLE_CASES) {
                Speckle speckle = render_speckle(
                    ray_queries:   ray_queries,
                    shading:       shading,
                    trace_level:   speckle_case.trace_level,
                    lod_threshold: speckle_case.lod_threshold,
                );
                assert(speckle.mean_laplacian <= SPECKLE_LAPLACIAN_RATIO * floor.mean_laplacian);
                assert((float)speckle.edges <= SPECKLE_PIXEL_RATIO * (float)floor.edges);
            }
        }
    }
}

// The same view with the gaps removed: the skip is what keeps the trace grid from shadowing the terrain.
fn void test_speckle_measure_catches_a_missing_proxy_skip() @test {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (shading : SHADINGS) {
            Speckle floor = render_speckle(
                ray_queries:   ray_queries,
                shading:       shading,
                trace_level:   0,
                lod_threshold: FINEST_LOD,
            );
            Speckle speckle = render_speckle(
                ray_queries:   ray_queries,
                shading:       shading,
                trace_level:   TRACE_LEVEL,
                lod_threshold: FINE_LOD,
                without_skip:  true,
            );
            assert(
                speckle.mean_laplacian > SPECKLE_LAPLACIAN_RATIO * floor.mean_laplacian
                || (float)speckle.edges > SPECKLE_PIXEL_RATIO * (float)floor.edges
            );
        }
    }
}

fn Vec2 project_to_pixel(ShadeRig* rig, Vec3 point) @local {
    Camera* camera = rig.scene.get(rig.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, rig.camera.world, { SHADE_SIZE, SHADE_SIZE });
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return {
        (clip.x / clip.w * 0.5f + 0.5f) * (float)SHADE_SIZE,
        (0.5f - clip.y / clip.w * 0.5f) * (float)SHADE_SIZE,
    };
}

fn float luminance_around(ShadeRig* rig, Vec3 point) @local {
    Vec2 pixel = project_to_pixel(rig, point);
    uint x = (uint)pixel.x;
    uint y = (uint)pixel.y;
    float total;
    for (uint step_y = y - 1; step_y <= y + 1; step_y++) {
        for (uint step_x = x - 1; step_x <= x + 1; step_x++) total += luminance_at(rig, step_x, step_y);
    }
    return total / 9;
}

fn void test_traced_shadow_of_a_box_on_terrain_stays_attached() @test {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (shading : SHADINGS) {
            ShadeDesc shade = {
                .ray_queries   = ray_queries,
                .shading       = shading,
                .patch_map     = true,
                .trace_level   = TRACE_LEVEL,
                .lod_threshold = COARSE_LOD,
                .camera        = CREST + CONTACT_CAMERA_OFFSET,
                .fov_degrees   = CONTACT_FOV_DEGREES,
                .sun_direction = CONTACT_SUN,
            };
            ShadeRig rig;
            create_shade_rig(&rig, &shade)!!;
            defer destroy_shade_rig(&rig);

            // The grid is off by more than the box is tall, so a skip that covered every instance would hide it.
            assert(rig.scene.get(rig.terrain_node, TerrainRuntime).trace_error > BOX_SIZE);
            HeightView ground = terrain::height_view(&rig.scene, &rig.assets, rig.terrain_node.id)!!;
            float surface = terrain::sample_height(&ground, CREST.x, CREST.z)!!;
            rig.camera.local.position.y = surface + CONTACT_CAMERA_OFFSET.y;

            GeometryId box;
            @pool() {
                Geometry shape = geometry::box(tmem, BOX_SIZE, BOX_SIZE, BOX_SIZE);
                box = rig.assets.add_geometry(&shape)!!;
            };
            StandardParams stone = { .base_color = { 0.8f, 0.8f, 0.8f, 1 }, .roughness = 1 };
            Node* block = rig.scene.add_mesh(box, rig.assets.add_material(material::standard(stone))!!)!!;
            block.local.position = { CREST.x, surface + BOX_SIZE * 0.5f, CREST.z };
            rig.scene.update_world();

            render_shade(&rig)!!;
            Vec3 shadowed = { CREST.x - BOX_SIZE * 0.5f - SHADOW_GAP, surface, CREST.z };
            Vec3 lit = { CREST.x + LIT_DISTANCE, surface, CREST.z };
            float in_shadow = luminance_around(&rig, shadowed);
            float in_light = luminance_around(&rig, lit);
            assert(in_shadow < SHADOW_RATIO * in_light);
            check_validation(&rig.renderer);
        }
    }
}
