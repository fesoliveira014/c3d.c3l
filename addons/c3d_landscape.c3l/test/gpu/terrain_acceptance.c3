module c3d_landscape_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::landscape;
import c3d::landscape::terrain;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] READBACK_SOURCE @local = $embed("readback.comp.glsl");
const char[*] NORMAL_PROBE_SOURCE @local = $embed("normal_probe.comp.glsl");
const uint READBACK_POINTS @local = 2; // mirrored as READBACK_POINTS in readback.comp.glsl
const uint TARGET_SIZE @local = 64;
const uint TERRAIN_TEXELS @local = 257; // four finest chunks, so a reversal re-pairs every record index
const float CELL_SIZE @local = 1;
const float HEIGHT_SCALE @local = 24;
const Vec3 CAMERA_POSITION @local = { 128, 420, 128 }; // the 256 m terrain fills the middle, background the corners
const float CAMERA_FAR @local = 1000;
const uint NEUTRAL_VELOCITY @local = 0xff008080;
const int VELOCITY_TOLERANCE @local = 1; // one encoding step; devices round a zero velocity to 0x7f or 0x80
const uint SETTLE_FRAMES @local = 8; // history and TAA settle on a still camera
const float NODE_NUDGE @local = 20; // metres: about three pixels of motion at this view, far above the encoding step
const double TIME_STEP @local = 1.0 / 60.0;
const Vec2 TERRAIN_UV @local = { 0.4f, 0.6f };
const Vec2 BACKGROUND_UV @local = { 0.02f, 0.02f };
const float FLAT_HEIGHT @local = 0.5f; // fraction of the height scale
const Vec3 DECAL_SIZE @local = { 160, 160, 100 }; // metres; local z is the projection axis, tall enough for the flat patch
const Vec4 DECAL_COLOR @local = { 1, 0, 0, 1 };
const float DECAL_TOLERANCE @local = 0.02f; // the core decal tolerance, including G-buffer quantization
const float DECAL_MIN_DIFFERENCE @local = 0.1f; // far above the tolerance, so an unchanged colour fails
const uint PROBE_COUNT @local = 8; // mirrored as PROBE_COUNT in normal_probe.comp.glsl
const uint PROBE_TEXELS @local = 129; // one chunk per tile
const uint PROBE_PARAMS_SIZE @local = 32; // the terrain material's parameter block
const usz PROBE_BORDER_EDGES_OFFSET @local = 16; // in that block, after texels, cell_size, height_scale and layer_count
const float PROBE_HEIGHT_SCALE @local = 24;
const float PROBE_BEND_X @local = 0.3f; // radians per texel; bends the surface enough that one-sided slopes differ across a seam
const float PROBE_BEND_Z @local = 0.35f;
const float RING_AGREEMENT @local = 1e-5f; // float rounding of the shared texel's two gradients, which use the same four heights
const float ONE_SIDED_DISAGREEMENT @local = 0.01f; // far above the agreement, so a missing ring fails
const float CPU_SHADER_AGREEMENT @local = 1e-5f; // float rounding of two evaluations of the same texels
const uint SLOPE_TARGET_SIZE @local = 64;
const uint SLOPE_TEXELS @local = 257; // two finest chunks per side
const float SLOPE_CELL_SIZE @local = 0.25f; // a 24 m wall falls within one cell
const float SLOPE_HEIGHT_SCALE @local = 24;
const uint PLATEAU_TEXELS @local = 128; // texels below this along x and z are high; the walls fall away past them
const float WALL_PLANE @local = 31.875f; // metres: the middle of the one-cell run between texels 127 and 128
const float VIEW_DISTANCE @local = 10; // from the wall or the ground, so both views share one pixel scale
const float VIEW_HEIGHT @local = 12;
const float VIEW_ALONG_WALL @local = 16;
const float GROUND_VIEW_X @local = 40;
const float FAR_NODE_OFFSET @local = 200; // separates the two terrains drawn in one scene
const float SLOPE_NEAR @local = 0.1f;
const uint SLOPE_FRAMES @local = 2;
const uint CHECKER_TEXELS @local = 8;
const uint CHECKER_SQUARE_TEXELS @local = 4;
const float CHECKER_PERIOD @local = 2; // metres of terrain per repeat of the checker texture
const float PERIOD_TOLERANCE @local = 1; // pixels
const float MIN_CONTRAST @local = 0.25f; // of linear luminance; a stretched checker shows none along the fall line
const uint PATCH_SIZE @local = 8; // pixels square at the middle of the view
const double SLOPE_TIME_STEP @local = 1.0 / 60.0;
const char[4] NORMAL_FLAT @local = { 128, 128, 255, 255 };
const char[4] NORMAL_ALONG_U @local = { 191, 128, 238, 255 }; // 30 degrees toward +u
const char[4] NORMAL_AGAINST_U @local = { 64, 128, 238, 255 };
const char[4] NORMAL_ALONG_V @local = { 128, 191, 238, 255 }; // 30 degrees toward +v
const float GROUND_LIT_MIN @local = 0.1f; // a flat unmapped ground is dark under the horizontal light
const float FLAT_MAP_TOLERANCE @local = 0.03f; // of the unmapped brightness
const float ALONG_U_MIN_RATIO @local = 1.2f; // of the flat brightness; the diffuse cos 30 + sin 30 gives 1.37
const float AGAINST_U_MAX_RATIO @local = 0.55f; // diffuse (cos 30 - sin 30) gives 0.37
const float DEFERRED_TOLERANCE @local = 0.05f; // of the forward brightness, including G-buffer quantization

struct ReadbackRoot @local {
    gpu::GpuAddress output;
    Vec2[READBACK_POINTS] uvs;
}
$assert ReadbackRoot::size == 24;

struct ReadbackOutput @local {
    uint[READBACK_POINTS] pixels;
}

struct Fixture @local {
    AssetStore           assets;
    Scene                scene;
    Renderer             renderer;
    Node*                camera_node;
    Node*                terrain_node;
    ViewId               view;
    ComputeShaderId      readback_shader;
    BufferId             output;
    gpu::MappedGpuSpan   readback;
}

fn TextureId add_hills(AssetStore* assets, bool flat) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (sz)TERRAIN_TEXELS * TERRAIN_TEXELS);
        for (uint z = 0; z < TERRAIN_TEXELS; z++) {
            for (uint x = 0; x < TERRAIN_TEXELS; x++) {
                float wave = flat ? FLAT_HEIGHT : 0.5f + 0.25f * math::sin((float)x * 0.05f) + 0.25f * math::cos((float)z * 0.07f);
                texels[z * TERRAIN_TEXELS + x] = (ushort)(wave * (float)ushort::max);
            }
        }
        material::TextureDesc desc = material::texture_2d_desc(TERRAIN_TEXELS, TERRAIN_TEXELS, R16_UINT);
        desc.generate_mips = false;
        texture = assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * ushort::size])!!;
    };
    return texture;
}

fn void? create_fixture(Fixture* fixture, bool flat = false) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    terrain::register_terrain(&fixture.scene, &fixture.assets)!;

    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = add_hills(&fixture.assets, flat);
    desc.cell_size = CELL_SIZE;
    desc.height_scale = HEIGHT_SCALE;
    desc.lod_threshold = 0;
    StandardParams grass = { .base_color = { 0.5f, 0.6f, 0.3f, 1 }, .roughness = 1 };
    desc.layers[0] = fixture.assets.add_material(material::standard(grass))!;
    fixture.terrain_node = fixture.scene.add_node()!;
    terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   fixture.terrain_node,
        desc:   desc,
    )!;

    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(60, 1, CAMERA_FAR))!;
    fixture.camera_node.local.position = CAMERA_POSITION;
    fixture.camera_node.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    fixture.scene.update_world();

    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)READBACK_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
    )!;
    defer alloc::free(mem, spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    fixture.readback_shader = fixture.assets.add_compute_shader(&shader_desc)!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets:    &fixture.assets,
        desc:      { .validation = true, .application_name = "terrain_acceptance" },
    )!;
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(TARGET_SIZE, TARGET_SIZE),
    )!;
    ViewDesc view_desc = render::texture_view_desc(target);
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.post.taa_params.debug = TaaDebug.VELOCITY;
    fixture.view = render::create_view(&fixture.renderer, view_desc)!;
    fixture.output = fixture.renderer.create_buffer({
        .size       = ReadbackOutput::size,
        .debug_name = "terrain_readback",
    })!;
    gpu::AllocationDesc readback_desc = {
        .size         = ReadbackOutput::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "terrain_readback_host",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
}

fn void destroy_fixture(Fixture* fixture) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = fixture.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void check_validation(Renderer* renderer) @local {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        bool validation_error = entry.category.backend && entry.category.validation
          && entry.severity == gpu::DebugMessageSeverity.ERROR;
        assert(!validation_error);
    }
}

fn void? record_readback(Fixture* fixture) @local {
    Renderer* renderer = &fixture.renderer;
    ReadbackRoot root = {
        .output = renderer.buffer_address(fixture.output),
        .uvs    = { TERRAIN_UV, BACKGROUND_UV },
    };
    BufferId[1] writes = { fixture.output };
    DispatchTexture[1] textures = { render::read_view_color(fixture.view) };
    renderer.dispatch({
        .shader   = fixture.readback_shader,
        .root     = ((char*)&root)[:ReadbackRoot::size],
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

fn void? update_terrain(Fixture* fixture) @local {
    fixture.scene.update_world();
    return terrain::update(
        scene:                &fixture.scene,
        assets:               &fixture.assets,
        camera_node:          fixture.camera_node,
        output_height_pixels: TARGET_SIZE,
    );
}

fn void? render_frame(
    Fixture* fixture,
    uint frame,
    bool read,
    Vec3 reference = {},
) @local {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({
        .time = (double)frame * TIME_STEP,
        .delta = (float)TIME_STEP,
        .reference_position = reference,
    })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, fixture.camera_node, fixture.view)!;
    if (read) record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
}

fn uint[READBACK_POINTS] read_pixels(Fixture* fixture) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::invalidate_mapped_span(&fixture.renderer.device, fixture.readback.span)!!;
    return ((ReadbackOutput*)fixture.readback.bytes.ptr).pixels;
}

fn void settle(Fixture* fixture, uint* frame) @local {
    for (uint settled = 0; settled < SETTLE_FRAMES; settled++, (*frame)++) {
        update_terrain(fixture)!!;
        render_frame(fixture, *frame, false)!!;
    }
}

fn bool near_pixel(uint first, uint second) @local {
    for (uint shift = 0; shift < 32; shift += 8) {
        int difference = (int)((first >> shift) & 0xff) - (int)((second >> shift) & 0xff);
        if (difference < -VELOCITY_TOLERANCE || difference > VELOCITY_TOLERANCE) return false;
    }
    return true;
}

fn void test_reselected_chunks_keep_background_velocity() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    uint frame;
    settle(&fixture, &frame);

    // Node motion shows as velocity, so an equal pair below means the terrain was drawn and still.
    fixture.terrain_node.local.position.x += NODE_NUDGE;
    update_terrain(&fixture)!!;
    render_frame(&fixture, frame++, true)!!;
    uint[READBACK_POINTS] moved = read_pixels(&fixture);
    assert(!near_pixel(moved[0], moved[1]), "The moved terrain shows the background's velocity %08x.", moved[1]);
    settle(&fixture, &frame);

    // Equal count, every record index now names another chunk: a re-selection at rest.
    update_terrain(&fixture)!!;
    InstancedMesh* batch = fixture.scene.get(fixture.terrain_node, InstancedMesh);
    assert(batch.count > 1);
    for (uint index = 0; index < batch.count / 2; index++) {
        uint mirror = batch.count - 1 - index;
        @swap(batch.transforms[index], batch.transforms[mirror]);
        @swap(batch.colors[index], batch.colors[mirror]);
    }
    fixture.scene.mark_instances_dirty(fixture.terrain_node);
    render_frame(&fixture, frame, true)!!;

    uint[READBACK_POINTS] pixels = read_pixels(&fixture);
    assert(near_pixel(pixels[1], NEUTRAL_VELOCITY), "The still background shows velocity %08x.", pixels[1]);
    assert(near_pixel(pixels[0], pixels[1]), "Terrain velocity %08x against background %08x.", pixels[0], pixels[1]);
    check_validation(&fixture.renderer);
}

fn void test_relative_terrain_has_no_velocity_when_only_reference_changes() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Vec3 offset = { 65536, 0, 65536 };
    fixture.scene.root.local.position = offset;
    for (uint frame = 0; frame < SETTLE_FRAMES + 2; frame++) {
        update_terrain(&fixture)!!;
        Vec3 reference = offset + (frame >= SETTLE_FRAMES ? (Vec3){ 256, 0, -256 } : (Vec3){});
        render_frame(
            fixture: &fixture,
            frame: frame,
            read: true,
            reference: reference,
        )!!;
        if (frame < SETTLE_FRAMES) continue;
        uint[READBACK_POINTS] pixels = read_pixels(&fixture);
        assert(near_pixel(pixels[1], NEUTRAL_VELOCITY));
        assert(near_pixel(pixels[0], pixels[1]));
    }
    check_validation(&fixture.renderer);
}

fn Vec4 unpack_pixel(uint pixel) @local {
    return {
        (float)(pixel & 0xff) / 255.0f,
        (float)((pixel >> 8) & 0xff) / 255.0f,
        (float)((pixel >> 16) & 0xff) / 255.0f,
        (float)((pixel >> 24) & 0xff) / 255.0f,
    };
}

fn float color_difference(Vec4 first, Vec4 second) @local {
    float maximum;
    for (usz channel = 0; channel < 4; channel++) {
        maximum = math::max(maximum, math::abs(first[channel] - second[channel]));
    }
    return maximum;
}

fn Vec4 render_terrain_color(Fixture* fixture, ShadingPath shading) @local {
    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.shading = shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.post.taa_params.debug = TaaDebug.NONE;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        update_terrain(fixture)!!;
        render_frame(fixture, frame, frame + 1 == SETTLE_FRAMES)!!;
    }
    return unpack_pixel(read_pixels(fixture)[0]);
}

fn void test_terrain_receives_decals_on_both_paths() @test {
    Fixture fixture;
    create_fixture(&fixture, true)!!;
    defer destroy_fixture(&fixture);
    fixture.scene.ambient_color = { 1, 1, 1 };
    fixture.scene.ambient_intensity = 1;

    Vec4 plain_forward = render_terrain_color(&fixture, ShadingPath.FORWARD);
    Vec4 plain_deferred = render_terrain_color(&fixture, ShadingPath.DEFERRED);
    assert(color_difference(plain_forward, plain_deferred) <= DECAL_TOLERANCE);

    StandardParams params = { .base_color = DECAL_COLOR, .roughness = 1 };
    DecalDesc desc = scene::default_decal_desc(fixture.assets.add_material(material::standard(params))!!);
    desc.size = DECAL_SIZE;
    desc.decal.weights = { .base_color = 1, .normal = 0, .roughness = 0, .metallic = 0 };
    Node* projector = fixture.scene.add_decal(desc)!!;
    projector.local.position = { 128, FLAT_HEIGHT * HEIGHT_SCALE, 128 };
    projector.local.rotation = fixture.camera_node.local.rotation; // local z along world y
    fixture.scene.update_world();

    Vec4 decaled_forward = render_terrain_color(&fixture, ShadingPath.FORWARD);
    Vec4 decaled_deferred = render_terrain_color(&fixture, ShadingPath.DEFERRED);
    io::printfn("Terrain decal colours: plain %s decaled forward %s deferred %s",
        plain_forward, decaled_forward, decaled_deferred);
    assert(color_difference(decaled_forward, plain_forward) > DECAL_MIN_DIFFERENCE);
    assert(color_difference(decaled_deferred, plain_deferred) > DECAL_MIN_DIFFERENCE);
    float path_difference = color_difference(decaled_forward, decaled_deferred);
    io::printfn("Terrain decal forward/deferred maximum channel difference: %f", path_difference);
    assert(path_difference <= DECAL_TOLERANCE);

    fixture.scene.get(projector, Decal).receiver_layers = ~fixture.terrain_node.layers;
    Vec4 excluded_forward = render_terrain_color(&fixture, ShadingPath.FORWARD);
    Vec4 excluded_deferred = render_terrain_color(&fixture, ShadingPath.DEFERRED);
    assert(color_difference(excluded_forward, plain_forward) <= DECAL_TOLERANCE);
    assert(color_difference(excluded_deferred, plain_deferred) <= DECAL_TOLERANCE);
    check_validation(&fixture.renderer);
}

struct ProbeParams @local {
    char[PROBE_PARAMS_SIZE] bytes;
}

struct ProbePoint @local {
    Vec2 texel_position;
    uint tile;      // index into SeamFixture.tiles
    bool one_sided; // clears the tile's edge mask, as before the ring
}

struct ProbeInput @local {
    Vec2 texel_position;
    uint height_slot; // dispatch texture of the tile's height map
    uint border_slot; // dispatch texture of its border ring
}
$assert ProbeInput::size == 16;

struct ProbeRoot @local {
    gpu::GpuAddress          output;
    ulong                    padding; // keeps the parameter blocks 16-byte aligned
    ProbeParams[PROBE_COUNT] params;
    ProbeInput[PROBE_COUNT]  inputs;
}
$assert ProbeRoot::size == 16 + PROBE_COUNT * PROBE_PARAMS_SIZE + PROBE_COUNT * ProbeInput::size;

struct ProbeOutput @local {
    Vec4[PROBE_COUNT] normals;
}

struct SeamFixture @local {
    AssetStore         assets;
    Scene              scene;
    Renderer           renderer;
    Node*[3]           tiles; // north-west, north-east and south-west of a 2 x 2 set
    ComputeShaderId    shader;
    BufferId           output;
    gpu::MappedGpuSpan readback;
}

fn ushort seam_height(uint global_x, uint global_z) @local {
    float along_x = 0.25f * math::sin((float)global_x * PROBE_BEND_X);
    float along_z = 0.25f * math::cos((float)global_z * PROBE_BEND_Z);
    return (ushort)((0.5f + along_x + along_z) * (float)ushort::max);
}

// Tiles are cut from one surface and overlap by a row and a column, as terrain tile sets require.
fn TextureId add_seam_map(AssetStore* assets, uint column, uint row) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (sz)PROBE_TEXELS * PROBE_TEXELS);
        for (uint z = 0; z < PROBE_TEXELS; z++) {
            for (uint x = 0; x < PROBE_TEXELS; x++) {
                uint global_x = column * (PROBE_TEXELS - 1) + x;
                uint global_z = row * (PROBE_TEXELS - 1) + z;
                texels[z * PROBE_TEXELS + x] = seam_height(global_x, global_z);
            }
        }
        material::TextureDesc desc = material::texture_2d_desc(PROBE_TEXELS, PROBE_TEXELS, R16_UINT);
        desc.generate_mips = false;
        texture = assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * ushort::size])!!;
    };
    return texture;
}

fn void? create_seam_fixture(SeamFixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    terrain::register_terrain(&fixture.scene, &fixture.assets)!;

    StandardParams grass = { .base_color = { 0.5f, 0.6f, 0.3f, 1 }, .roughness = 1 };
    MaterialId layer = fixture.assets.add_material(material::standard(grass))!;
    float cell_size = 1;
    TerrainSet set = { .texels = PROBE_TEXELS, .cell_size = cell_size, .height_scale = PROBE_HEIGHT_SCALE };
    Node* set_node = fixture.scene.add_node()!;
    fixture.scene.add(set_node, set);
    for (uint index = 0; index < 4; index++) {
        uint column = index % 2;
        uint row = index / 2;
        TerrainDesc desc = terrain::default_terrain_desc();
        desc.height_map = add_seam_map(&fixture.assets, column, row);
        desc.cell_size = cell_size;
        desc.height_scale = PROBE_HEIGHT_SCALE;
        desc.layers[0] = layer;
        Node* tile = fixture.scene.add_node(set_node)!;
        tile.local.position = { (float)column * set.tile_extent(), 0, (float)row * set.tile_extent() };
        fixture.scene.add(tile, (TerrainTile){ .x = (int)column, .z = (int)row });
        terrain::add_terrain(
            scene:  &fixture.scene,
            assets: &fixture.assets,
            node:   tile,
            desc:   desc,
        )!;
        if (index < fixture.tiles.len) fixture.tiles[index] = tile;
    }

    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)NORMAL_PROBE_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
        includes:  landscape::LANDSCAPE_SHADER_INCLUDES[..],
    )!;
    defer alloc::free(mem, spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    fixture.shader = fixture.assets.add_compute_shader(&shader_desc)!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets:    &fixture.assets,
        desc:      { .validation = true, .application_name = "terrain_seam_acceptance" },
    )!;
    fixture.output = fixture.renderer.create_buffer({
        .size       = ProbeOutput::size,
        .debug_name = "terrain_seam_output",
    })!;
    gpu::AllocationDesc readback_desc = {
        .size         = ProbeOutput::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "terrain_seam_readback",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
}

fn void destroy_seam_fixture(SeamFixture* fixture) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = fixture.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ProbeParams tile_params(SeamFixture* fixture, Node* tile, bool border_edges) @local {
    ProbeParams params;
    char[] block = fixture.assets.material(fixture.scene.get(tile, TerrainRuntime).material).data.custom.param_block;
    params.bytes[..] = block[..];
    if (!border_edges) *(uint*)&params.bytes[PROBE_BORDER_EDGES_OFFSET] = 0;
    return params;
}

// Probes 0 to 3 use the tiles' own blocks; probes 4 to 7 repeat them with the edge mask cleared, as before the ring.
fn Vec4[PROBE_COUNT]? read_seam_normals(SeamFixture* fixture) @local {
    Vec2[4] points = {
        { PROBE_TEXELS - 1, 60.5f }, // north-west tile, east edge
        { 0, 60.5f },                // north-east tile, west edge
        { 40.5f, PROBE_TEXELS - 1 }, // north-west tile, south edge
        { 40.5f, 0 },                // south-west tile, north edge
    };
    uint[4] owners = { 0, 1, 0, 2 };
    ProbePoint[PROBE_COUNT] probes;
    foreach (probe, owner : owners) {
        probes[probe] = { .texel_position = points[probe], .tile = owner };
        probes[probe + owners.len] = { .texel_position = points[probe], .tile = owner, .one_sided = true };
    }
    return read_probe_normals(fixture, probes);
}

fn Vec4[PROBE_COUNT]? read_probe_normals(SeamFixture* fixture, ProbePoint[PROBE_COUNT] probes) @local {
    Renderer* renderer = &fixture.renderer;
    ProbeRoot root = { .output = renderer.buffer_address(fixture.output) };
    foreach (index, probe : probes) {
        root.params[index] = tile_params(fixture, fixture.tiles[probe.tile], !probe.one_sided);
        root.inputs[index] = {
            .texel_position = probe.texel_position,
            .height_slot    = 2 * probe.tile,
            .border_slot    = 2 * probe.tile + 1,
        };
    }
    DispatchTexture[6] textures;
    foreach (index, tile : fixture.tiles) {
        textures[2 * index] = render::read_texture(fixture.scene.get(tile, Terrain).desc.height_map);
        textures[2 * index + 1] = render::read_texture(fixture.scene.get(tile, TerrainRuntime).border_ring);
    }
    BufferId[1] writes = { fixture.output };
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.dispatch({
        .shader   = fixture.shader,
        .root     = ((char*)&root)[:ProbeRoot::size],
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
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, fixture.readback.span)!;
    return ((ProbeOutput*)fixture.readback.bytes.ptr).normals;
}

fn float normal_distance(Vec4 first, Vec4 second) @local {
    return (first.xyz - second.xyz).length();
}

fn void test_tile_edge_normals_agree_across_a_seam() @test {
    SeamFixture fixture;
    create_seam_fixture(&fixture)!!;
    defer destroy_seam_fixture(&fixture);

    Vec4[PROBE_COUNT] normals = read_seam_normals(&fixture)!!;
    float east_west = normal_distance(normals[0], normals[1]);
    float north_south = normal_distance(normals[2], normals[3]);
    float east_west_one_sided = normal_distance(normals[4], normals[5]);
    float north_south_one_sided = normal_distance(normals[6], normals[7]);
    io::printfn("Seam normal distance with the ring: east-west %g north-south %g", east_west, north_south);
    io::printfn(
        "Seam normal distance one-sided: east-west %g north-south %g",
        east_west_one_sided,
        north_south_one_sided,
    );
    assert(east_west <= RING_AGREEMENT && north_south <= RING_AGREEMENT);
    assert(east_west_one_sided >= ONE_SIDED_DISAGREEMENT && north_south_one_sided >= ONE_SIDED_DISAGREEMENT);
    check_validation(&fixture.renderer);
}

struct SlopeFixture @local {
    AssetStore     assets;
    Scene          scene;
    Renderer       renderer;
    RenderTargetId target;
    ViewId         view;
    Node*          camera_node;
    TextureId      cliff;
}

struct ViewPose @local {
    Vec3 position;
    Vec3 forward;
    Vec3 up;
}

fn TextureId add_cliff(AssetStore* assets) @local {
    TextureId texture;
    @pool() {
        ushort[] texels = alloc::new_array(tmem, ushort, (sz)SLOPE_TEXELS * SLOPE_TEXELS);
        for (uint z = 0; z < SLOPE_TEXELS; z++) {
            for (uint x = 0; x < SLOPE_TEXELS; x++) {
                bool plateau = x < PLATEAU_TEXELS && z < PLATEAU_TEXELS;
                texels[z * SLOPE_TEXELS + x] = plateau ? ushort::max : 0;
            }
        }
        material::TextureDesc desc = material::texture_2d_desc(SLOPE_TEXELS, SLOPE_TEXELS, R16_UINT);
        desc.generate_mips = false;
        texture = assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * ushort::size])!!;
    };
    return texture;
}

fn TextureId add_checker(AssetStore* assets) @local {
    char[CHECKER_TEXELS * CHECKER_TEXELS * 4] texels;
    for (uint y = 0; y < CHECKER_TEXELS; y++) {
        for (uint x = 0; x < CHECKER_TEXELS; x++) {
            bool light = ((x / CHECKER_SQUARE_TEXELS + y / CHECKER_SQUARE_TEXELS) & 1) != 0;
            char level = light ? 255 : 0;
            char[4] texel = { level, level, level, 255 };
            texels[(y * CHECKER_TEXELS + x) * 4 : 4] = texel[..];
        }
    }
    material::TextureDesc desc = material::texture_2d_desc(CHECKER_TEXELS, CHECKER_TEXELS, RGBA8_UNORM);
    desc.generate_mips = false;
    return assets.add_texture(desc, texels[..])!!;
}

fn TextureId add_constant_texture(AssetStore* assets, char[4] texel) @local {
    return assets.add_texture(material::texture_2d_desc(1, 1, RGBA8_UNORM), texel[..])!!;
}

fn void? create_slope_fixture(SlopeFixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    fixture.scene.background = { .kind = COLOR, .color = { 0, 0, 0, 1 } };
    fixture.scene.ambient_color = { 1, 1, 1 };
    fixture.scene.ambient_intensity = 1;
    terrain::register_terrain(&fixture.scene, &fixture.assets)!;
    fixture.cliff = add_cliff(&fixture.assets);
    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(60, SLOPE_NEAR, CAMERA_FAR))!;

    fixture.renderer = render::create_renderer(
        allocator: mem,
        assets:    &fixture.assets,
        desc:      { .validation = true, .application_name = "terrain_slope_acceptance" },
    )!;
    fixture.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(SLOPE_TARGET_SIZE, SLOPE_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc view_desc = render::texture_view_desc(fixture.target);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    fixture.view = render::create_view(&fixture.renderer, view_desc)!;
}

fn void destroy_slope_fixture(SlopeFixture* fixture) @local {
    render::wait_frames(&fixture.renderer)!!;
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node*? add_cliff_terrain(
    SlopeFixture* fixture,
    MaterialId layer,
    SlopeProjection projection,
    Vec3 position,
) @local {
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = fixture.cliff;
    desc.cell_size = SLOPE_CELL_SIZE;
    desc.height_scale = SLOPE_HEIGHT_SCALE;
    desc.layers[0] = layer;
    desc.lod_threshold = 0;
    desc.slope_projection = projection;

    Node* node = fixture.scene.add_node()!;
    node.local.position = position;
    fixture.scene.update_world();
    terrain::add_terrain(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    )!;
    return node;
}

fn ViewPose wall_view(Vec3 origin, bool facing_x) @local {
    if (facing_x) {
        return {
            .position = origin + (Vec3){ WALL_PLANE + VIEW_DISTANCE, VIEW_HEIGHT, VIEW_ALONG_WALL },
            .forward  = { -1, 0, 0 },
            .up       = { 0, 1, 0 },
        };
    }
    return {
        .position = origin + (Vec3){ VIEW_ALONG_WALL, VIEW_HEIGHT, WALL_PLANE + VIEW_DISTANCE },
        .forward  = { 0, 0, -1 },
        .up       = { 0, 1, 0 },
    };
}

fn ViewPose ground_view(Vec3 origin) @local {
    return {
        .position = origin + (Vec3){ GROUND_VIEW_X, VIEW_DISTANCE, VIEW_ALONG_WALL },
        .forward  = { 0, -1, 0 },
        .up       = { 0, 0, -1 },
    };
}

fn Vec4[]? render_slope_view(SlopeFixture* fixture, ViewPose pose) @local {
    Renderer* renderer = &fixture.renderer;
    fixture.camera_node.local.position = pose.position;
    fixture.camera_node.local.rotation = maths::look_rotation(pose.forward, pose.up);

    for (uint frame = 0; frame < SLOPE_FRAMES; frame++) {
        fixture.scene.update_world();
        terrain::update(
            scene:                &fixture.scene,
            assets:               &fixture.assets,
            camera_node:          fixture.camera_node,
            output_height_pixels: SLOPE_TARGET_SIZE,
        )!;

        renderer.begin_frame({ .time = (double)frame * SLOPE_TIME_STEP, .delta = (float)SLOPE_TIME_STEP })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&fixture.scene, fixture.camera_node, fixture.view)!;
        renderer.finish_view(fixture.view)!;
        renderer.end_frame()!;
    }

    Vec4[] pixels = alloc::new_array(tmem, Vec4, (usz)SLOPE_TARGET_SIZE * SLOPE_TARGET_SIZE);
    renderer.read_render_target(fixture.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn float luminance(Vec4 pixel) @local => (pixel.x + pixel.y + pixel.z) / 3;

fn float[SLOPE_TARGET_SIZE] column_scan(Vec4[] pixels, uint column) @local {
    float[SLOPE_TARGET_SIZE] values;
    for (uint row = 0; row < SLOPE_TARGET_SIZE; row++) {
        values[row] = luminance(pixels[row * SLOPE_TARGET_SIZE + column]);
    }
    return values;
}

fn float[SLOPE_TARGET_SIZE] row_scan(Vec4[] pixels, uint row) @local {
    float[SLOPE_TARGET_SIZE] values;
    for (uint column = 0; column < SLOPE_TARGET_SIZE; column++) {
        values[column] = luminance(pixels[row * SLOPE_TARGET_SIZE + column]);
    }
    return values;
}

// A scan with fewer than two crossings, such as a stretched checker, has no period and reports zero.
fn float checker_period(float[] values) @local {
    float lowest = float::max;
    float highest = -float::max;
    foreach (value : values) {
        lowest = math::min(lowest, value);
        highest = math::max(highest, value);
    }
    if (highest - lowest < MIN_CONTRAST) return 0;

    float middle = (lowest + highest) / 2;
    float first;
    float last;
    uint crossings;
    for (usz index = 0; index + 1 < values.len; index++) {
        if (values[index] >= middle || values[index + 1] < middle) continue;

        last = (float)index + (middle - values[index]) / (values[index + 1] - values[index]);
        if (!crossings) first = last;
        crossings++;
    }
    return crossings < 2 ? 0 : (last - first) / (float)(crossings - 1);
}

fn float patch_brightness(Vec4[] pixels) @local {
    foreach (pixel : pixels) {
        assert(math::is_finite(pixel.x) && math::is_finite(pixel.y) && math::is_finite(pixel.z));
    }

    float total;
    uint start = (SLOPE_TARGET_SIZE - PATCH_SIZE) / 2;
    for (uint row = start; row < start + PATCH_SIZE; row++) {
        for (uint column = start; column < start + PATCH_SIZE; column++) {
            total += luminance(pixels[row * SLOPE_TARGET_SIZE + column]);
        }
    }
    return total / (float)(PATCH_SIZE * PATCH_SIZE);
}

fn void test_triplanar_cliff_keeps_texel_density() @test {
    SlopeFixture fixture;
    create_slope_fixture(&fixture)!!;
    defer destroy_slope_fixture(&fixture);

    UvTransform tiling = { .scale = { 1 / CHECKER_PERIOD, 1 / CHECKER_PERIOD } };
    StandardParams params = {
        .base_color     = { 1, 1, 1, 1 },
        .roughness      = 1,
        .base_color_map = material::texture_slot(texture: add_checker(&fixture.assets), transform: tiling),
    };
    MaterialId layer = fixture.assets.add_material(material::standard(params))!!;
    Node*[2] nodes;
    foreach (index, projection : SlopeProjection::values) {
        Vec3 position = { FAR_NODE_OFFSET * (float)index, 0, 0 };
        nodes[index] = add_cliff_terrain(&fixture, layer, projection, position)!!;
    }

    float[2] ground_periods;
    float[2] wall_periods;
    foreach (index, node : nodes) {
        @pool() {
            Vec3 origin = node.local.position;
            Vec4[] ground = render_slope_view(&fixture, ground_view(origin))!!;
            ground_periods[index] = checker_period(row_scan(ground, SLOPE_TARGET_SIZE / 2)[..]);

            Vec4[] wall = render_slope_view(&fixture, wall_view(origin, true))!!;
            wall_periods[index] = checker_period(column_scan(wall, SLOPE_TARGET_SIZE / 2)[..]);
        };
    }
    foreach (period : ground_periods) assert(period > PERIOD_TOLERANCE);

    usz top = SlopeProjection.TOP.ordinal;
    usz triplanar = SlopeProjection.TRIPLANAR.ordinal;
    float top_difference = math::abs(wall_periods[top] - ground_periods[top]);
    float triplanar_difference = math::abs(wall_periods[triplanar] - ground_periods[triplanar]);
    io::printfn(
        "Checker period in pixels, ground and wall: top %g %g triplanar %g %g",
        ground_periods[top],
        wall_periods[top],
        ground_periods[triplanar],
        wall_periods[triplanar],
    );
    assert(top_difference > PERIOD_TOLERANCE, "The top projection's wall keeps the ground's period.");
    assert(triplanar_difference <= PERIOD_TOLERANCE, "The triplanar wall period is off by %g.", triplanar_difference);
    check_validation(&fixture.renderer);
}

fn void select_normal_map(SlopeFixture* fixture, MaterialId layer, TextureId normal_map) @local {
    TextureSlot slot = normal_map.generation ? material::texture_slot(texture: normal_map) : (TextureSlot){};
    fixture.assets.material(layer).data.standard.normal_map = slot;
    fixture.assets.mark_material_dirty(layer);
}

fn float view_brightness(SlopeFixture* fixture, MaterialId layer, TextureId normal_map, ViewPose pose) @local {
    select_normal_map(fixture, layer, normal_map);
    @pool() {
        return patch_brightness(render_slope_view(fixture, pose)!!);
    };
}

fn void test_triplanar_normal_map_follows_the_plane() @test {
    SlopeFixture fixture;
    create_slope_fixture(&fixture)!!;
    defer destroy_slope_fixture(&fixture);
    fixture.scene.ambient_intensity = 0;
    Node* sun = fixture.scene.add_light(light::directional({ 1, 1, 1 }, 3, shadow: false))!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -1, 0, -1 }.normalize(), { 0, 1, 0 });

    TextureId flat_map = add_constant_texture(&fixture.assets, NORMAL_FLAT);
    TextureId along_u_map = add_constant_texture(&fixture.assets, NORMAL_ALONG_U);
    TextureId against_u_map = add_constant_texture(&fixture.assets, NORMAL_AGAINST_U);
    TextureId along_v_map = add_constant_texture(&fixture.assets, NORMAL_ALONG_V);
    StandardParams params = { .base_color = { 1, 1, 1, 1 }, .roughness = 1, .normal_scale = 1 };
    MaterialId layer = fixture.assets.add_material(material::standard(params))!!;
    add_cliff_terrain(&fixture, layer, SlopeProjection.TRIPLANAR, {})!!;
    Vec3 top_origin = { FAR_NODE_OFFSET, 0, 0 };
    add_cliff_terrain(&fixture, layer, SlopeProjection.TOP, top_origin)!!;

    foreach (facing_x : (bool[2]){ true, false }) {
        ViewPose view = wall_view({}, facing_x);
        float unmapped = view_brightness(&fixture, layer, {}, view);
        float level = view_brightness(&fixture, layer, flat_map, view);
        float lifted = view_brightness(&fixture, layer, along_u_map, view);
        float lowered = view_brightness(&fixture, layer, against_u_map, view);
        io::printfn(
            "Wall facing %s brightness: unmapped %g flat %g toward u %g against u %g",
            facing_x ? "+x" : "+z",
            unmapped,
            level,
            lifted,
            lowered,
        );
        assert(unmapped > 0);
        assert(math::abs(level - unmapped) <= FLAT_MAP_TOLERANCE * unmapped, "A flat map moved the normal.");
        assert(lifted >= ALONG_U_MIN_RATIO * level, "A map tilted along +u did not turn toward the plane's u axis.");
        assert(lowered <= AGAINST_U_MAX_RATIO * level, "A map tilted against +u did not turn away from it.");
    }

    float top_ground = view_brightness(&fixture, layer, along_v_map, ground_view(top_origin));
    float triplanar_ground = view_brightness(&fixture, layer, along_v_map, ground_view({}));
    io::printfn("Ground brightness with a map tilted along +v: top %g triplanar %g", top_ground, triplanar_ground);
    assert(top_ground > GROUND_LIT_MIN, "The tilted map did not light the flat ground.");
    assert(math::abs(triplanar_ground - top_ground) <= FLAT_MAP_TOLERANCE * top_ground, "The ground frames differ.");

    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    ViewPose view = wall_view({}, true);
    float forward_brightness = view_brightness(&fixture, layer, along_u_map, view);
    desc.shading = ShadingPath.DEFERRED;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    float deferred_brightness = view_brightness(&fixture, layer, along_u_map, view);
    io::printfn("Wall facing +x toward u: forward %g deferred %g", forward_brightness, deferred_brightness);
    float deferred_difference = math::abs(deferred_brightness - forward_brightness);
    assert(deferred_difference <= DEFERRED_TOLERANCE * forward_brightness, "The G-buffer fragment differs.");
    check_validation(&fixture.renderer);
}

fn void test_cpu_smooth_normal_matches_shader() @test {
    SeamFixture fixture;
    create_seam_fixture(&fixture)!!;
    defer destroy_seam_fixture(&fixture);

    ProbePoint[PROBE_COUNT] probes = {
        { .texel_position = { 40.25f, 60.75f }, .tile = 0 },                  // inside the north-west tile
        { .texel_position = { 90.5f, 33.25f }, .tile = 1 },                   // inside the north-east tile
        { .texel_position = { 0, 60.5f }, .tile = 0 },                        // map edge with no neighbour
        { .texel_position = { 0, 0 }, .tile = 0 },                            // map corner
        { .texel_position = { PROBE_TEXELS - 1, 60.5f }, .tile = 0 },         // seam, east edge
        { .texel_position = { 0, 60.5f }, .tile = 1 },                        // seam, west edge of the neighbour
        { .texel_position = { 127.5f, 60.5f }, .tile = 0 },                   // between the last two texels
        { .texel_position = { PROBE_TEXELS - 1, PROBE_TEXELS - 1 }, .tile = 0 }, // east and south seams
    };
    fixture.scene.update_world();
    Vec4[PROBE_COUNT] shader_normals = read_probe_normals(&fixture, probes)!!;
    float worst;
    foreach (index, probe : probes) {
        Node* tile = fixture.tiles[probe.tile];
        HeightView view = terrain::height_view(&fixture.scene, &fixture.assets, tile.id)!!;
        Vec3 world = maths::transform_point(
            tile.world,
            { probe.texel_position.x * view.cell_size, 0, probe.texel_position.y * view.cell_size },
        );
        Vec3 normal = terrain::sample_smooth_normal(&view, world.x, world.z)!!;
        worst = max(worst, (normal - shader_normals[index].xyz).length());
    }
    io::printfn("CPU smooth normal against the shader: worst distance %g over %d points", worst, probes.len);
    assert(worst <= CPU_SHADER_AGREEMENT);
    check_validation(&fixture.renderer);
}
