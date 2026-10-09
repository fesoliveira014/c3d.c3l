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

const char[*] READBACK_SOURCE @local = $embed("readback.comp.glsl");
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
