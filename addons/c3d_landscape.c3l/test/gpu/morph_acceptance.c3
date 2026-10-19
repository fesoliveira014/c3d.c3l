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

const char[*] MORPH_READBACK_SOURCE @local = $embed("morph_readback.comp.glsl");
const uint MORPH_READBACK_POINTS @local = 32; // mirrored as MORPH_READBACK_POINTS in morph_readback.comp.glsl
const uint MORPH_TEXELS @local = 257; // two finest chunks per side under one root
const uint MORPH_NODES @local = 5; // four finest chunks and the root
const float MORPH_CELL_SIZE @local = 0.1f; // a 25.6 m map: the box ranges stay within tens of metres
const float MORPH_HEIGHT_SCALE @local = 12;
const float MORPH_NOISE_SHARE @local = 0.5f; // of the height scale: odd vertices sit far off their parents
const float MORPH_BAND @local = 0.25f;
const float MORPH_SPLIT_PIXELS @local = 64;
const float MORPH_FOV_DEGREES @local = 90;
const float MORPH_FAR_PLANE @local = 300;
const uint MORPH_FINEST_CHUNK @local = 128; // the finest chunk at the far corner of the map starts at this texel
const uint MORPH_PROBE_SPAN @local = 100; // texels scanned for a probe inside that chunk
const float MORPH_MIN_POP @local = 1.5f; // metres between a probe vertex and its parent surface
const uint DEPTH_SIZE @local = 65; // odd: the centre pixel's ray is the optical axis
const float DEPTH_HIGH @local = 60; // metres above the map: only the root draws
const float DEPTH_LOW @local = 8; // only the finest chunks draw
const uint SPLIT_BISECTIONS @local = 14; // 52 m down to under 4 mm
const float CONTINUITY_TOLERANCE @local = 0.01f; // metres of surface height between the two renderings
const uint VELOCITY_SIZE @local = 64;
const uint VELOCITY_GRID @local = 5;
const uint VELOCITY_GRID_FIRST @local = 24; // pixels: the map covers pixels 22 to 42 at the highest altitude
const uint VELOCITY_GRID_STEP @local = 4;
const float VELOCITY_ABOVE @local = 3; // metres above the split altitude where the descent starts
const float VELOCITY_BELOW @local = 9; // metres under it: the band's width at this altitude
const float VELOCITY_STEP @local = 0.5f; // metres of descent per frame
const float VELOCITY_RANGE @local = 16; // pixels either side of zero, mirrored as TAA_DEBUG_VELOCITY_RANGE
const float VELOCITY_TOLERANCE @local = 0.3f; // pixels: above the morph's own motion, below a stale morph state
const double MORPH_TIME_STEP @local = 1.0 / 60.0;

struct MorphReadbackRoot @local {
    gpu::GpuAddress                          output;
    uint                                     point_count;
    uint                                     read_color;
    int[<2>][MORPH_READBACK_POINTS]          pixels;
}
$assert MorphReadbackRoot::size == 272;

struct MorphReadbackOutput @local {
    Vec4[MORPH_READBACK_POINTS] texels;
}

struct MorphFixture @local {
    AssetStore         assets;
    Scene              scene;
    Renderer           renderer;
    Node*              camera_node;
    Node*              terrain_node;
    ViewId             view;
    ComputeShaderId    readback_shader;
    BufferId           output;
    gpu::MappedGpuSpan readback;
    gpu::MappedGpuSpan selection;
    uint               size;
    uint               frame;
    uint               drawn; // nodes the last rendering selected
}

struct MorphHit {
    float height; // world height of the surface under the centre pixel
    uint  drawn;  // nodes the rendering selected
}

struct VertexProbe {
    uint  texel_x;
    uint  texel_z;
    float pop; // fine height less the parent surface's height there
}

fn uint noise_hash(uint x, uint z) @local {
    uint value = x * 73856093 ^ z * 19349663;
    value ^= value >> 13;
    value *= 0x5bd1e995;
    value ^= value >> 15;
    return value;
}

fn float noise_height(uint x, uint z) @local {
    float unit = (float)(noise_hash(x, z) & 0xffff) / 65535.0f;
    return MORPH_HEIGHT_SCALE * (0.5f + MORPH_NOISE_SHARE * (unit - 0.5f));
}

fn ushort noise_texel(uint x, uint z) @local => (ushort)(noise_height(x, z) / MORPH_HEIGHT_SCALE * 65535.0f);

fn TextureId add_noise_map(AssetStore* assets) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (sz)MORPH_TEXELS * MORPH_TEXELS);
        for (uint z = 0; z < MORPH_TEXELS; z++) {
            for (uint x = 0; x < MORPH_TEXELS; x++) texels[z * MORPH_TEXELS + x] = noise_texel(x, z);
        }
        material::TextureDesc desc = material::texture_2d_desc(MORPH_TEXELS, MORPH_TEXELS, R16_UINT);
        desc.generate_mips = false;
        texture = assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * ushort::size])!!;
    };
    return texture;
}

fn void? create_morph_fixture(
    MorphFixture* fixture,
    float morph_band,
    uint size,
    AntiAliasing anti_aliasing,
) @local {
    fixture.size = size;
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    terrain::register_terrain(&fixture.scene, &fixture.assets)!;

    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = add_noise_map(&fixture.assets);
    desc.cell_size = MORPH_CELL_SIZE;
    desc.height_scale = MORPH_HEIGHT_SCALE;
    desc.lod_threshold = MORPH_SPLIT_PIXELS;
    desc.morph_band = morph_band;
    StandardParams grass = { .base_color = { 0.5f, 0.6f, 0.3f, 1 }, .roughness = 1 };
    desc.layers[0] = fixture.assets.add_material(material::standard(grass))!;
    fixture.terrain_node = fixture.scene.add_node()!;
    terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   fixture.terrain_node,
        desc:   desc,
    )!;

    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(MORPH_FOV_DEGREES, 1, MORPH_FAR_PLANE))!;
    fixture.camera_node.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    fixture.scene.update_world();

    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)MORPH_READBACK_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
    )!;
    defer alloc::free(mem, spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    fixture.readback_shader = fixture.assets.add_compute_shader(&shader_desc)!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets:    &fixture.assets,
        desc:      { .validation = true, .application_name = "morph_acceptance" },
    )!;
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(size, size),
    )!;
    ViewDesc view_desc = render::texture_view_desc(target);
    view_desc.post.anti_aliasing = anti_aliasing;
    view_desc.post.taa_params.debug = anti_aliasing == AntiAliasing.TAA ? TaaDebug.VELOCITY : TaaDebug.NONE;
    fixture.view = render::create_view(&fixture.renderer, view_desc)!;
    fixture.output = fixture.renderer.create_buffer({
        .size       = MorphReadbackOutput::size,
        .debug_name = "morph_readback",
    })!;
    gpu::AllocationDesc readback_desc = {
        .size         = MorphReadbackOutput::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "morph_readback_host",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
    gpu::AllocationDesc selection_desc = {
        .size         = MORPH_NODES * uint::size,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "morph_selection_host",
    };
    fixture.selection = gpu::allocate_mapped_memory(&fixture.renderer.device, &selection_desc)!;
}

fn void destroy_morph_fixture(MorphFixture* fixture) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = fixture.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    gpu::GpuAllocation selection = fixture.selection.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &selection)!!;
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void check_morph_validation(Renderer* renderer) @local {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        bool validation_error = entry.category.backend && entry.category.validation
          && entry.severity == gpu::DebugMessageSeverity.ERROR;
        assert(!validation_error);
    }
}

fn void? record_morph_readback(MorphFixture* fixture, int[<2>][] pixels, bool read_color) @local {
    Renderer* renderer = &fixture.renderer;
    MorphReadbackRoot root = {
        .output      = renderer.buffer_address(fixture.output),
        .point_count = (uint)pixels.len,
        .read_color  = read_color ? 1 : 0,
    };
    root.pixels[:pixels.len] = pixels[..];
    BufferId[1] writes = { fixture.output };
    DispatchTexture[2] textures = { render::read_view_depth(fixture.view), render::read_view_color(fixture.view) };
    renderer.dispatch({
        .shader   = fixture.readback_shader,
        .root     = ((char*)&root)[:MorphReadbackRoot::size],
        .groups   = { 1, 1, 1 },
        .writes   = writes[..],
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
    return gpu::cmd_barrier(&renderer.commands, &host_read);
}

// Copies the selection words of this rendering, as the renderer wrote them.
fn void? record_selection_copy(MorphFixture* fixture) @local {
    Renderer* renderer = &fixture.renderer;
    uint node_slot = fixture.terrain_node.id.index;
    render::QuadtreeHistoryEntry* history = &renderer.views.get(fixture.view).quadtree_history.entries[node_slot];
    assert(history.allocation.is_valid());
    usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * uint::size;
    gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, history.allocation)!;
    gpu::Barrier produced = { .before = { .compute, .vertex_shader }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &produced)!;
    gpu::BufferCopyDesc copy = {
        .src = source.checked_subspan(offset, fixture.selection.bytes.len)!,
        .dst = fixture.selection.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &copied);
}

// Renders one frame from the position, looking straight down, and reads the pixels' depth and velocity.
fn Vec4[]? render_morph_frame(
    MorphFixture* fixture,
    Vec3 position,
    int[<2>][] pixels,
    bool read_color,
    bool reset_history = false,
) @local {
    Renderer* renderer = &fixture.renderer;
    fixture.camera_node.local.position = position;
    fixture.scene.update_world();
    terrain::update(&fixture.scene, &fixture.assets)!;
    if (reset_history) render::reset_view_history(renderer, fixture.view)!;

    double time = (double)fixture.frame++ * MORPH_TIME_STEP;
    renderer.begin_frame({ .time = time, .delta = (float)MORPH_TIME_STEP })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, fixture.camera_node, fixture.view)!;
    record_selection_copy(fixture)!;
    record_morph_readback(fixture, pixels, read_color)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, fixture.readback.span)!;
    gpu::invalidate_mapped_span(&renderer.device, fixture.selection.span)!;

    fixture.drawn = 0;
    foreach (word : ((uint*)fixture.selection.bytes.ptr)[:MORPH_NODES]) {
        if (word & shader::QUADTREE_DRAW) fixture.drawn++;
    }
    return ((MorphReadbackOutput*)fixture.readback.bytes.ptr).texels[:pixels.len];
}

fn Vec3 unproject_pixel(MorphFixture* fixture, int[<2>] pixel, float depth) @local {
    CameraMatrices matrices = camera::derive_matrices(
        *fixture.scene.get(fixture.camera_node, Camera),
        fixture.camera_node.world,
        { fixture.size, fixture.size },
    );
    Vec2 uv = { ((float)pixel.x + 0.5f) / fixture.size, ((float)pixel.y + 0.5f) / fixture.size };
    Vec4 world = matrices.inv_view_proj * (Vec4){ uv.x * 2 - 1, 1 - uv.y * 2, depth, 1 };
    return world.xyz / world.w;
}

fn MorphHit? render_centre_hit(
    MorphFixture* fixture,
    Vec3 position,
    bool reset_history,
) @local {
    int[<2>][1] centre = { { (int)fixture.size / 2, (int)fixture.size / 2 } };
    Vec4[] texels = render_morph_frame(
        fixture:       fixture,
        position:      position,
        pixels:        centre[..],
        read_color:    false,
        reset_history: reset_history,
    )!;
    return {
        .height = unproject_pixel(fixture, centre[0], texels[0].x).y,
        .drawn  = fixture.drawn,
    };
}

// Camera altitudes a few millimetres apart that straddle the root's split over the position.
fn float[2]? find_split_altitudes(MorphFixture* fixture, float x, float z) @local {
    float high = DEPTH_HIGH;
    float low = DEPTH_LOW;
    assert(render_centre_hit(fixture, { x, high, z }, true)!.drawn == 1, "The root splits at %s m.", high);
    assert(render_centre_hit(fixture, { x, low, z }, true)!.drawn == 4, "The root does not split by %s m.", low);
    for (uint step = 0; step < SPLIT_BISECTIONS; step++) {
        float middle = 0.5f * (high + low);
        if (render_centre_hit(fixture, { x, middle, z }, true)!.drawn == 1) {
            high = middle;
        } else {
            low = middle;
        }
    }
    return { high, low };
}

// The first interior vertex of the finest chunk at the far corner with the parities, standing off its parent surface.
fn VertexProbe find_probe(bool odd_x, bool odd_z) @local {
    for (uint z = MORPH_FINEST_CHUNK + 2; z < MORPH_FINEST_CHUNK + MORPH_PROBE_SPAN; z++) {
        for (uint x = MORPH_FINEST_CHUNK + 2; x < MORPH_FINEST_CHUNK + MORPH_PROBE_SPAN; x++) {
            bool x_is_odd = (bool)((x - MORPH_FINEST_CHUNK) & 1);
            bool z_is_odd = (bool)((z - MORPH_FINEST_CHUNK) & 1);
            if (x_is_odd != odd_x || z_is_odd != odd_z) continue;

            float parent;
            if (odd_x && odd_z) {
                parent = 0.5f * (noise_height(x + 1, z - 1) + noise_height(x - 1, z + 1));
            } else if (odd_x) {
                parent = 0.5f * (noise_height(x - 1, z) + noise_height(x + 1, z));
            } else {
                parent = 0.5f * (noise_height(x, z - 1) + noise_height(x, z + 1));
            }
            float pop = noise_height(x, z) - parent;
            if (math::abs(pop) >= MORPH_MIN_POP) return { .texel_x = x, .texel_z = z, .pop = pop };
        }
    }
    unreachable("No probe vertex stands off its parent surface.");
}

// The camera straddles the root's split directly over the vertex; the centre pixel's ray meets the map at the vertex.
fn float surface_change_across_split(MorphFixture* fixture, VertexProbe probe) @local {
    float x = (float)probe.texel_x * MORPH_CELL_SIZE;
    float z = (float)probe.texel_z * MORPH_CELL_SIZE;
    float[2] altitudes = find_split_altitudes(fixture, x, z)!!;

    MorphHit whole = render_centre_hit(fixture, { x, altitudes[0], z }, true)!!;
    MorphHit split = render_centre_hit(fixture, { x, altitudes[1], z }, false)!!;
    assert(whole.drawn == 1 && split.drawn == 4);
    return split.height - whole.height;
}

fn void test_morphing_split_keeps_depth_continuous() @test {
    VertexProbe[3] probes = {
        find_probe(true, true),
        find_probe(true, false),
        find_probe(false, true),
    };
    {
        MorphFixture fixture;
        create_morph_fixture(&fixture, MORPH_BAND, DEPTH_SIZE, AntiAliasing.NONE)!!;
        defer destroy_morph_fixture(&fixture);

        foreach (probe : probes) {
            float change = surface_change_across_split(&fixture, probe);
            io::printfn(
                "Morphing on: probe (%s, %s), parent offset %s m, surface change %s m",
                probe.texel_x,
                probe.texel_z,
                probe.pop,
                change,
            );
            assert(math::abs(change) <= CONTINUITY_TOLERANCE, "Surface changed by %s m across the split.", change);
        }
        check_morph_validation(&fixture.renderer);
    }
    {
        MorphFixture fixture;
        create_morph_fixture(&fixture, 0, DEPTH_SIZE, AntiAliasing.NONE)!!;
        defer destroy_morph_fixture(&fixture);

        float change = surface_change_across_split(&fixture, probes[0]);
        io::printfn(
            "Morphing off: probe (%s, %s), parent offset %s m, surface change %s m",
            probes[0].texel_x,
            probes[0].texel_z,
            probes[0].pop,
            change,
        );
        assert(math::abs(change) >= 0.5f * MORPH_MIN_POP, "Without morphing the surface changed by only %s m.", change);
        check_morph_validation(&fixture.renderer);
    }
}

fn float decode_velocity(float shown) @local => (shown - 0.5f) * 2 * VELOCITY_RANGE;

fn void test_morph_velocity_matches_camera_motion() @test {
    MorphFixture fixture;
    create_morph_fixture(&fixture, MORPH_BAND, VELOCITY_SIZE, AntiAliasing.TAA)!!;
    defer destroy_morph_fixture(&fixture);
    float centre = (float)(MORPH_TEXELS - 1) * MORPH_CELL_SIZE * 0.5f;
    float split = find_split_altitudes(&fixture, centre, centre)!![0];

    int[<2>][VELOCITY_GRID * VELOCITY_GRID] pixels;
    for (uint row = 0; row < VELOCITY_GRID; row++) {
        for (uint column = 0; column < VELOCITY_GRID; column++) {
            pixels[row * VELOCITY_GRID + column] = {
                (int)(VELOCITY_GRID_FIRST + column * VELOCITY_GRID_STEP),
                (int)(VELOCITY_GRID_FIRST + row * VELOCITY_GRID_STEP),
            };
        }
    }

    // The descent starts with only the root drawn, crosses the split, then runs through the band.
    uint split_frame;
    float worst;
    uint frames = (uint)((VELOCITY_ABOVE + VELOCITY_BELOW) / VELOCITY_STEP);
    for (uint frame = 0; frame <= frames; frame++) {
        Vec3 position = { centre, split + VELOCITY_ABOVE - (float)frame * VELOCITY_STEP, centre };
        Vec4[] texels = render_morph_frame(
            fixture:       &fixture,
            position:      position,
            pixels:        pixels[..],
            read_color:    true,
            reset_history: frame == 0,
        )!!;
        if (frame == 0) {
            assert(fixture.drawn == 1);
            continue;
        }

        if (fixture.drawn == 4 && !split_frame) split_frame = frame;
        foreach (index, texel : texels) {
            Vec3 surface = unproject_pixel(&fixture, pixels[index], texel.y);
            float depth = position.y - surface.y;
            float scale = VELOCITY_STEP / (depth + VELOCITY_STEP);
            float expected_x = ((float)pixels[index].x + 0.5f - 0.5f * VELOCITY_SIZE) * scale;
            float expected_y = ((float)pixels[index].y + 0.5f - 0.5f * VELOCITY_SIZE) * scale;
            float error_x = decode_velocity(texel.z) - expected_x;
            float error_y = decode_velocity(texel.w) - expected_y;
            worst = math::max(worst, math::max(math::abs(error_x), math::abs(error_y)));
        }
    }
    io::printfn(
        "Descent from %s m: split at frame %s of %s, worst velocity error %s px",
        split + VELOCITY_ABOVE,
        split_frame,
        frames,
        worst,
    );
    assert(split_frame > 1 && split_frame < frames, "The root split at frame %s of %s.", split_frame, frames);
    assert(worst <= VELOCITY_TOLERANCE, "Velocity strayed %s px from the camera's reprojection.", worst);
    check_morph_validation(&fixture.renderer);
}
