module c3d_water_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::landscape::water;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::math;

const char[*] READBACK_SOURCE @local = $embed("water_readback.comp.glsl");
const uint READBACK_POINTS @local = 64; // mirrored as WATER_READBACK_POINTS in water_readback.comp.glsl
const uint TWIN_SIZE @local = 129; // odd: the centre pixel's ray is the optical axis
const uint TWIN_GRID @local = 7; // 49 surface samples across the central 80 % of the view
const float TWIN_FOV_DEGREES @local = 20; // 7 m of water at 20 m, 5.4 cm per pixel
const Vec3 TWIN_CAMERA_POSITION @local = { 0, 20, 0 };
const float TWIN_EXTENT @local = 12.8f;
const float TWIN_CELL_SIZE @local = 0.05f; // triangulation error under 0.2 mm on the 2 m wave
const float SURFACE_TOLERANCE @local = 0.01f; // metres, the render and physics contract
const double[3] TWIN_TIMES @local = { 0.5, 4.8, 65540.8 }; // 4.8 s puts wave 0's largest crest shift at the origin
const Vec3 POST_HALF_EXTENTS @local = { 0.05f, 0.5f, 0.05f }; // a slender crate: its eight cells see one surface
const float POST_DENSITY @local = 600;
const float POST_SUBMERSION @local = 0.6f; // metres of the post placed under the sampled surface
const uint MIRROR_SIZE @local = 64;
const uint WATER_LAYER @local = 2;
const float EMISSIVE_STRENGTH @local = 20;
const Vec3 MIRROR_CAMERA_POSITION @local = { 0, 1.5f, 4 };
const Vec3 FLOATING_BOX_POSITION @local = { 0, 2, -8 };
const Vec3 BURIED_BOX_POSITION @local = { 3, -0.6f, -8 }; // wholly under the plane; its image lies on the water
const float DARK_LIMIT @local = 0.01f;
const Vec3 STRIPE_POSITION @local = { 0, 1.5f, -10 };
const Vec3 STRIPE_SIZE @local = { 0.4f, 3, 0.4f };
const Vec3 MARCH_CAMERA_POSITION @local = { 0, 1, 4 };
const Vec3 AMBIENT @local = { 0.2f, 0.1f, 0.05f };
const float MISS_TOLERANCE @local = 0.03f; // relative; half-float storage and the Schlick fit
const float HALF_FLOAT_STEP @local = 0.0005f; // absolute floor of the comparison, near zero
const uint VELOCITY_SIZE @local = 65;
const Vec3 VELOCITY_CAMERA_POSITION @local = { 0, 20, 0 };
const double VELOCITY_STEP @local = 0.1;
const uint SETTLE_FRAMES @local = 8;
const uint VELOCITY_ROW_SAMPLES @local = 9;
const float VELOCITY_TOLERANCE @local = 0.01f; // encoded units, about two and a half 8-bit steps
const float MIN_VELOCITY_ENCODED @local = 0.03f; // every sample moves well above the tolerance
const uint BISECTION_STEPS @local = 60;

const Wave[2] EXAMPLE_WAVES @local = { // kept identical by hand with default_water_desc, the example's waves
    { .amplitude = 0.12f, .wavelength = 6, .speed = 1.2f, .direction = { 1, 0 }, .steepness = 0.5f },
    { .amplitude = 0.07f, .wavelength = 3.5f, .speed = 0.9f, .direction = { 0.6f, 0.8f }, .steepness = 0.5f },
};
const Wave[4] CHOPPY_WAVES @local = {
    { .amplitude = 0.35f, .wavelength = 12, .speed = 2.5f, .direction = { 1, 0 }, .steepness = 0.8f },
    { .amplitude = 0.2f, .wavelength = 7, .speed = 1.9f, .direction = { 0.8f, 0.6f }, .steepness = 0.8f },
    { .amplitude = 0.12f, .wavelength = 4, .speed = 1.4f, .direction = { 0.28f, 0.96f }, .steepness = 0.8f },
    { .amplitude = 0.06f, .wavelength = 2, .speed = 1.0f, .direction = { -0.6f, 0.8f }, .steepness = 0.8f },
};
const Wave RUNNING_WAVE @local = {
    .amplitude  = 0.3f,
    .wavelength = 8,
    .speed      = 3,
    .direction  = { 1, 0 },
    .steepness  = 0.8f,
};

struct ReadbackRoot @local {
    gpu::GpuAddress           output;
    uint                      point_count;
    uint                      _pad0;
    int[<2>][READBACK_POINTS] pixels;
}
$assert ReadbackRoot::size == 528;

struct ReadbackOutput @local {
    Vec4[READBACK_POINTS] texels;
}

struct Fixture @local {
    AssetStore         assets;
    Scene              scene;
    PhysicsWorld       physics;
    Renderer           renderer;
    GeometryId         box;
    ComputeShaderId    readback_shader;
    BufferId           output;
    gpu::MappedGpuSpan readback;
}

struct Lake @local {
    SurfaceView view;
    double      time;
}

// The reference adapter of docs/water.md: one water body, the update's base time.
fn float? lake_height(void* context, float x, float z, float step_offset) @local {
    Lake* lake = context;
    return water::sample_surface(
        view:    &lake.view,
        world_x: x,
        world_z: z,
        time:    lake.time + step_offset,
    );
}

fn void? create_fixture(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    fixture.scene.background = { .kind = COLOR, .color = { 0, 0, 0, 1 } };
    fixture.scene.ambient_color = {};
    physics::register_physics(&fixture.scene)!;
    water::register_water(&fixture.scene, &fixture.assets)!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!;
    @pool() {
        Geometry unit_box = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&unit_box)!;
    };

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
        desc:      { .validation = true, .application_name = "water_acceptance" },
    )!;
    fixture.output = fixture.renderer.create_buffer({ .size = ReadbackOutput::size, .debug_name = "water_readback" })!;
    gpu::AllocationDesc readback_desc = {
        .size         = ReadbackOutput::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "water_readback_host",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
}

fn void destroy_fixture(Fixture* fixture) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = fixture.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    render::destroy_renderer(&fixture.renderer);
    physics::destroy_physics_world(&fixture.physics);
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

fn WaterDesc surface_desc(Wave[] waves, float extent, float cell_size) @local {
    WaterDesc desc = water::default_water_desc();
    desc.waves[:waves.len] = waves[..];
    desc.wave_count = (uint)waves.len;
    desc.extent = extent;
    desc.cell_size = cell_size;
    desc.absorption_color = { 0.001f, 0.001f, 0.001f }; // opaque in centimetres: refraction adds nothing
    desc.absorption_distance = 0.1f;
    desc.scatter_color = {};
    desc.march_reflections = false;
    return desc;
}

fn Node* add_water_node(Fixture* fixture, WaterDesc desc) @local {
    Node* node = fixture.scene.add_node(name: "water")!!;
    node.layers = WATER_LAYER;
    fixture.scene.update_world();
    water::add_water(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    )!!;
    return node;
}

fn Node* add_camera_node(
    Fixture* fixture,
    float fov_degrees,
    Vec3 position,
    Vec3 forward,
    Vec3 up,
) @local {
    Node* node = fixture.scene.add_camera(camera::perspective_deg(fov_degrees, 0.5f, 100))!!;
    node.local.position = position;
    node.local.rotation = maths::look_rotation(forward.normalize(), up);
    fixture.scene.update_world();
    return node;
}

fn Node* add_emissive_box(Fixture* fixture, Vec3 position, Vec3 size) @local {
    StandardParams glow = material::STANDARD_PARAMS_DEFAULT;
    glow.base_color = { 0, 0, 0, 1 };
    glow.emissive = { 1, 1, 1 };
    glow.emissive_strength = EMISSIVE_STRENGTH;
    MaterialId glowing = fixture.assets.add_material(material::standard(glow))!!;
    Node* node = fixture.scene.add_mesh(fixture.box, glowing, name: "emissive")!!;
    node.local.position = position;
    node.local.scale = size;
    fixture.scene.update_world();
    return node;
}

fn ViewId add_view(Fixture* fixture, uint size, AntiAliasing anti_aliasing = AntiAliasing.NONE) @local {
    RenderTargetId target = render::create_render_target(&fixture.renderer, render::render_target_desc(size, size))!!;
    ViewDesc desc = render::texture_view_desc(target);
    desc.post.anti_aliasing = anti_aliasing;
    return render::create_view(&fixture.renderer, desc)!!;
}

fn void? record_readback(Fixture* fixture, DispatchTexture source, int[<2>][] pixels) @local {
    Renderer* renderer = &fixture.renderer;
    ReadbackRoot root = { .output = renderer.buffer_address(fixture.output), .point_count = (uint)pixels.len };
    root.pixels[:pixels.len] = pixels[..];
    BufferId[1] writes = { fixture.output };
    DispatchTexture[1] textures = { source };
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

fn Vec4[] read_texels(Fixture* fixture, usz count) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::invalidate_mapped_span(&fixture.renderer.device, fixture.readback.span)!!;
    return ((ReadbackOutput*)fixture.readback.bytes.ptr).texels[:count];
}

fn void? update_water(Fixture* fixture, Node* viewing, double time) @local {
    fixture.scene.update_world();
    return water::update(
        scene:          &fixture.scene,
        assets:         &fixture.assets,
        viewing_camera: viewing.id,
        wind_velocity:  {},
        time:           time,
    );
}

// Renders the view at the time and reads the pixels of one of its images.
fn Vec4[]? render_and_read(
    Fixture* fixture,
    Node* viewing,
    ViewId view,
    double time,
    int[<2>][] pixels,
    bool depth,
    Vec3 reference = {},
) @local {
    Renderer* renderer = &fixture.renderer;
    update_water(fixture, viewing, time)!;
    renderer.begin_frame({ .time = time, .delta = (float)VELOCITY_STEP, .reference_position = reference })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, viewing, view)!;
    record_readback(fixture, depth ? render::read_view_depth(view) : render::read_view_color(view), pixels)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_texels(fixture, pixels.len);
}

fn CameraMatrices matrices_of(Fixture* fixture, Node* camera_node, uint size) @local {
    return camera::derive_matrices(*fixture.scene.get(camera_node, Camera), camera_node.world, { size, size });
}

fn Vec3 unproject(
    CameraMatrices* matrices,
    int[<2>] pixel,
    uint size,
    float depth,
) @local {
    Vec2 uv = { ((float)pixel.x + 0.5f) / size, ((float)pixel.y + 0.5f) / size };
    Vec4 world = matrices.inv_view_proj * (Vec4){ uv.x * 2 - 1, 1 - uv.y * 2, depth, 1 };
    return world.xyz / world.w;
}

fn int[<2>] pixel_of(CameraMatrices* matrices, Vec3 point, uint size) @local {
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    Vec2 uv = { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
    return { (int)(uv.x * size), (int)(uv.y * size) };
}

fn Vec2 uv_of(CameraMatrices* matrices, Vec3 point) @local {
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

// Where the line from the eye through the point meets the water's rest plane, y = 0.
fn Vec3 plane_hit(Vec3 eye, Vec3 point) @local {
    Vec3 ray = point - eye;
    return eye + ray * (-eye.y / ray.y);
}

fn float luminance(Vec4 color) @local => 0.2126f * color.x + 0.7152f * color.y + 0.0722f * color.z;

fn float schlick(float normal_view) @local {
    float complement = 1 - normal_view;
    return 0.02f + 0.98f * complement * complement * complement * complement * complement;
}

// A crate that samples the surface through the physics seam, but draws nothing.
fn Node* add_post(Fixture* fixture, float bottom) @local {
    Node* post = fixture.scene.add_node(name: "post")!!;
    post.local.position = { 0, bottom + POST_HALF_EXTENTS.y, 0 };
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = POST_HALF_EXTENTS;
    collider.density = POST_DENSITY;
    fixture.physics.add_body(post, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    fixture.scene.add(post, (Buoyancy){ .fluid_density = physics::DEFAULT_FLUID_DENSITY });
    return post;
}

fn void check_twin(Fixture* fixture, Wave[] waves) @local {
    Node* water_node = add_water_node(fixture, surface_desc(waves, TWIN_EXTENT, TWIN_CELL_SIZE));
    defer fixture.scene.remove(water_node);
    Node* camera_node = add_camera_node(
        fixture:     fixture,
        fov_degrees: TWIN_FOV_DEGREES,
        position:    TWIN_CAMERA_POSITION,
        forward:     { 0, -1, 0 },
        up:          { 0, 0, -1 },
    );
    defer fixture.scene.remove(camera_node);
    ViewId view = add_view(fixture, TWIN_SIZE);
    CameraMatrices matrices = matrices_of(fixture, camera_node, TWIN_SIZE);
    SurfaceView surface = water::surface_view(&fixture.scene, &fixture.assets, water_node.id)!!;

    int[<2>][TWIN_GRID * TWIN_GRID + 1] pixels;
    int centre = (int)TWIN_SIZE / 2;
    int margin = (int)TWIN_SIZE / 10;
    foreach (index, &pixel : pixels[:TWIN_GRID * TWIN_GRID]) {
        int step = ((int)TWIN_SIZE - 2 * margin) / ((int)TWIN_GRID - 1);
        *pixel = { margin + (int)(index % TWIN_GRID) * step, margin + (int)(index / TWIN_GRID) * step };
    }
    pixels[TWIN_GRID * TWIN_GRID] = { centre, centre };

    foreach (time : TWIN_TIMES) {
        float resting = water::sample_surface(view: &surface, world_x: 0, world_z: 0, time: time)!!;
        float bottom = resting - POST_SUBMERSION;
        Node* post = add_post(fixture, bottom);
        Lake lake = { .view = surface, .time = time };
        fixture.physics.set_fluid_surface(&lake_height, &lake);
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        assert(fixture.physics.steps_last_update == 1);
        float fraction = fixture.scene.get(post, Buoyancy).submerged_fraction;
        fixture.physics.set_fluid_surface(null, null);
        fixture.scene.remove(post);

        Vec4[] depths = render_and_read(
            fixture:  fixture,
            viewing:  camera_node,
            view:     view,
            time:     time,
            pixels:   pixels[..],
            depth:    true,
        )!!;
        foreach (index, pixel : pixels) {
            Vec3 drawn = unproject(
                matrices: &matrices,
                pixel:    pixel,
                size:     TWIN_SIZE,
                depth:    depths[index].x,
            );
            float twin = water::sample_surface(
                view:    &surface,
                world_x: drawn.x,
                world_z: drawn.z,
                time:    time,
            )!!;
            assert(math::abs(drawn.y - twin) <= SURFACE_TOLERANCE, "drawn %f, twin %f at %f s", drawn.y, twin, time);
        }
        // The centre ray meets the surface at the post's axis: the waterline its fraction implies.
        Vec3 axis = unproject(
            matrices: &matrices,
            pixel:    pixels[TWIN_GRID * TWIN_GRID],
            size:     TWIN_SIZE,
            depth:    depths[TWIN_GRID * TWIN_GRID].x,
        );
        float waterline = bottom + fraction * 2 * POST_HALF_EXTENTS.y;
        assert(math::abs(axis.y - waterline) <= SURFACE_TOLERANCE, "drawn %f, waterline %f", axis.y, waterline);
    }
    check_validation(&fixture.renderer);
}

fn void test_drawn_surface_matches_the_cpu_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    check_twin(&fixture, EXAMPLE_WAVES[..]);
    check_twin(&fixture, CHOPPY_WAVES[..]);
}

fn void test_mirror_view_reflects_what_is_above_the_water() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* water_node = add_water_node(&fixture, surface_desc({}, 40, 1));
    add_emissive_box(&fixture, FLOATING_BOX_POSITION, { 1, 1, 1 });
    add_emissive_box(&fixture, BURIED_BOX_POSITION, { 0.5f, 0.5f, 0.5f });
    Node* camera_node = add_camera_node(
        fixture:     &fixture,
        fov_degrees: 60,
        position:    MIRROR_CAMERA_POSITION,
        forward:     { 0, -0.25f, -1 },
        up:          { 0, 1, 0 },
    );
    ViewId main_view = add_view(&fixture, MIRROR_SIZE);

    // The application's half of the mirror, as in docs/water.md.
    update_water(&fixture, camera_node, 0)!!;
    WaterRuntime* runtime = fixture.scene.get(water_node, WaterRuntime);
    RenderTargetId mirror_target = render::create_render_target(
        &fixture.renderer,
        render::render_target_desc(MIRROR_SIZE, MIRROR_SIZE),
    )!!;
    ViewDesc mirror_desc = render::texture_view_desc(mirror_target);
    mirror_desc.post.anti_aliasing = AntiAliasing.NONE;
    mirror_desc.clip_plane = runtime.clip_plane;
    ViewId mirror_view = render::create_view(&fixture.renderer, mirror_desc)!!;
    water::set_reflection_target(&fixture.scene, &fixture.assets, water_node, mirror_target);
    Node* mirror_node = fixture.scene.node(runtime.mirror);

    CameraMatrices matrices = matrices_of(&fixture, camera_node, MIRROR_SIZE);
    Vec3 box_image = FLOATING_BOX_POSITION * (Vec3){ 1, -1, 1 };
    Vec3 buried_image = BURIED_BOX_POSITION * (Vec3){ 1, -1, 1 };
    int[<2>][3] pixels = {
        pixel_of(&matrices, box_image, MIRROR_SIZE),
        pixel_of(&matrices, buried_image, MIRROR_SIZE),
        pixel_of(&matrices, { -4, 0, -8 }, MIRROR_SIZE),
    };
    Renderer* renderer = &fixture.renderer;
    update_water(&fixture, camera_node, 0)!!;
    renderer.begin_frame({ .time = 0, .delta = (float)VELOCITY_STEP })!!;
    renderer.render_view(&fixture.scene, mirror_node, mirror_view)!!;
    renderer.finish_view(mirror_view)!!;
    renderer.render_view(&fixture.scene, camera_node, main_view)!!;
    record_readback(&fixture, render::read_view_color(main_view), pixels[..])!!;
    renderer.finish_view(main_view)!!;
    renderer.end_frame()!!;
    Vec4[] colors = read_texels(&fixture, pixels.len);

    float normal_view = (MIRROR_CAMERA_POSITION - plane_hit(MIRROR_CAMERA_POSITION, box_image)).normalize().y;
    float box_minimum = 0.5f * schlick(normal_view) * EMISSIVE_STRENGTH;
    assert(luminance(colors[0]) >= box_minimum, "box image %f", luminance(colors[0]));
    assert(luminance(colors[1]) <= DARK_LIMIT, "buried image %f", luminance(colors[1]));
    assert(luminance(colors[2]) <= DARK_LIMIT, "open water %f", luminance(colors[2]));
    Vec4[3] reference = { colors[0], colors[1], colors[2] };
    Vec3 offset = { 65536, 0, 65536 };
    foreach (&node : fixture.scene.nodes) {
        if (node.parent == fixture.scene.root) node.local.position += offset;
    }
    for (uint crossing = 0; crossing < 2; crossing++) {
        update_water(&fixture, camera_node, 0)!!;
        mirror_desc.clip_plane = runtime.clip_plane;
        render::configure_view(renderer, mirror_view, mirror_desc)!!;
        renderer.begin_frame({ .reference_position = offset + (crossing ? (Vec3){ 256, 0, -256 } : (Vec3){}) })!!;
        renderer.render_view(&fixture.scene, mirror_node, mirror_view)!!;
        renderer.finish_view(mirror_view)!!;
        renderer.render_view(&fixture.scene, camera_node, main_view)!!;
        record_readback(&fixture, render::read_view_color(main_view), pixels[..])!!;
        renderer.finish_view(main_view)!!;
        renderer.end_frame()!!;
        Vec4[] translated = read_texels(&fixture, pixels.len);
        foreach (index, expected : reference) {
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::abs(translated[index][channel] - expected[channel]) < 0.002f);
            }
        }
    }
    check_validation(renderer);
}

fn void test_relative_water_wave_depth_survives_reference_changes() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    add_water_node(&fixture, surface_desc(EXAMPLE_WAVES[..], TWIN_EXTENT, TWIN_CELL_SIZE));
    Node* camera_node = add_camera_node(
        fixture: &fixture,
        fov_degrees: TWIN_FOV_DEGREES,
        position: TWIN_CAMERA_POSITION,
        forward: { 0, -1, 0 },
        up: { 0, 0, -1 },
    );
    ViewId view = add_view(&fixture, TWIN_SIZE);
    int[<2>][3] pixels = {
        { TWIN_SIZE / 2, TWIN_SIZE / 2 },
        { TWIN_SIZE / 3, TWIN_SIZE / 3 },
        { 2 * TWIN_SIZE / 3, 2 * TWIN_SIZE / 3 },
    };
    Vec4[] near = render_and_read(
        fixture: &fixture,
        viewing: camera_node,
        view: view,
        time: 1.25,
        pixels: pixels[..],
        depth: true,
    )!!;
    Vec4[3] reference = { near[0], near[1], near[2] };
    Vec3 offset = { 65536, 0, 65536 };
    foreach (&node : fixture.scene.nodes) {
        if (node.parent == fixture.scene.root) node.local.position += offset;
    }
    for (uint crossing = 0; crossing < 2; crossing++) {
        Vec4[] found = render_and_read(
            fixture: &fixture,
            viewing: camera_node,
            view: view,
            time: 1.25,
            pixels: pixels[..],
            depth: true,
            reference: offset + (crossing ? (Vec3){ 256, 0, -256 } : (Vec3){}),
        )!!;
        foreach (index, expected : reference) assert(math::abs(found[index].x - expected.x) < 0.00001f);
    }
    check_validation(&fixture.renderer);
}

fn void test_march_reflects_the_snapshot_and_misses_to_ambient() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    fixture.scene.ambient_color = AMBIENT;
    fixture.scene.ambient_intensity = 1;
    WaterDesc desc = surface_desc({}, 40, 1);
    desc.march_reflections = true;
    add_water_node(&fixture, desc);
    add_emissive_box(&fixture, STRIPE_POSITION, STRIPE_SIZE);
    Node* camera_node = add_camera_node(
        fixture:     &fixture,
        fov_degrees: 60,
        position:    MARCH_CAMERA_POSITION,
        forward:     { 0, -0.2f, -1 },
        up:          { 0, 1, 0 },
    );
    ViewId view = add_view(&fixture, MIRROR_SIZE);
    CameraMatrices matrices = matrices_of(&fixture, camera_node, MIRROR_SIZE);

    Vec3 stripe_image = { STRIPE_POSITION.x, -STRIPE_POSITION.y, STRIPE_POSITION.z };
    Vec3 open_water = { 3, 0, -6 };
    int[<2>][2] pixels = {
        pixel_of(&matrices, stripe_image, MIRROR_SIZE),
        pixel_of(&matrices, open_water, MIRROR_SIZE),
    };
    Vec4[] colors = render_and_read(
        fixture: &fixture,
        viewing: camera_node,
        view:    view,
        time:    0,
        pixels:  pixels[..],
        depth:   false,
    )!!;

    Vec3 stripe_hit = plane_hit(MARCH_CAMERA_POSITION, stripe_image);
    float stripe_fresnel = schlick((MARCH_CAMERA_POSITION - stripe_hit).normalize().y);
    assert(colors[0].x >= 0.5f * stripe_fresnel * EMISSIVE_STRENGTH, "stripe image %f", colors[0].x);
    Vec3 far_point = unproject(
        matrices: &matrices,
        pixel:    pixels[1],
        size:     MIRROR_SIZE,
        depth:    0.5f,
    );
    Vec3 hit = plane_hit(MARCH_CAMERA_POSITION, far_point);
    Vec3 expected = AMBIENT * schlick((MARCH_CAMERA_POSITION - hit).normalize().y);
    for (uint channel = 0; channel < 3; channel++) {
        float tolerance = MISS_TOLERANCE * expected[channel] + HALF_FLOAT_STEP;
        assert(math::abs(colors[1][channel] - expected[channel]) <= tolerance, "miss channel %d", channel);
    }
    Vec4[2] reference = { colors[0], colors[1] };
    Vec3 offset = { 65536, 0, 65536 };
    foreach (&node : fixture.scene.nodes) {
        if (node.parent == fixture.scene.root) node.local.position += offset;
    }
    for (uint crossing = 0; crossing < 2; crossing++) {
        Vec4[] translated = render_and_read(
            fixture: &fixture,
            viewing: camera_node,
            view: view,
            time: 0,
            pixels: pixels[..],
            depth: false,
            reference: offset + (crossing ? (Vec3){ 256, 0, -256 } : (Vec3){}),
        )!!;
        foreach (index, value : reference) {
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::abs(translated[index][channel] - value[channel]) < 0.002f);
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn Vec3 running_position(double rest_x, double time) @local {
    double wavenumber = 2 * math::PI / RUNNING_WAVE.wavelength;
    double phase = wavenumber * (rest_x - RUNNING_WAVE.speed * time);
    double shift = RUNNING_WAVE.steepness / wavenumber;
    return { (float)(rest_x + shift * math::cos(phase)), (float)(RUNNING_WAVE.amplitude * math::sin(phase)), 0 };
}

// The rest point whose drawn position lies on the pixel's ray; the horizontal map is monotonic below steepness 1.
fn double rest_on_ray(Vec3 origin, Vec3 direction, double time) @local {
    double low = -10;
    double high = 10;
    for (uint step = 0; step < BISECTION_STEPS; step++) {
        double middle = (low + high) / 2;
        Vec3 drawn = running_position(middle, time);
        float ray_x = origin.x + direction.x * (drawn.y - origin.y) / direction.y;
        if (drawn.x < ray_x) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return (low + high) / 2;
}

fn void test_velocity_form_follows_the_wave_motion() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Wave[1] running = { RUNNING_WAVE };
    add_water_node(&fixture, surface_desc(running[..], TWIN_EXTENT, TWIN_CELL_SIZE));
    Node* camera_node = add_camera_node(
        fixture:     &fixture,
        fov_degrees: TWIN_FOV_DEGREES,
        position:    VELOCITY_CAMERA_POSITION,
        forward:     { 0, -1, 0 },
        up:          { 0, 0, -1 },
    );
    ViewId view = add_view(&fixture, VELOCITY_SIZE, AntiAliasing.TAA);
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.post.taa_params.debug = TaaDebug.VELOCITY;
    render::configure_view(&fixture.renderer, view, desc)!!;
    CameraMatrices matrices = matrices_of(&fixture, camera_node, VELOCITY_SIZE);

    int[<2>][VELOCITY_ROW_SAMPLES] pixels;
    int row = (int)VELOCITY_SIZE / 2;
    foreach (index, &pixel : pixels) *pixel = { 8 + 6 * (int)index, row };
    double time;
    Vec4[] velocities;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        time = (double)frame * VELOCITY_STEP;
        velocities = render_and_read(
            fixture: &fixture,
            viewing: camera_node,
            view:    view,
            time:    time,
            pixels:  pixels[..],
            depth:   false,
        )!!;
    }

    float scale = (float)VELOCITY_SIZE / (2 * (float)shader::TAA_DEBUG_VELOCITY_RANGE);
    uint moving;
    foreach (index, pixel : pixels) {
        Vec3 far_point = unproject(
            matrices: &matrices,
            pixel:    pixel,
            size:     VELOCITY_SIZE,
            depth:    0.5f,
        );
        Vec3 direction = far_point - VELOCITY_CAMERA_POSITION;
        double rest = rest_on_ray(VELOCITY_CAMERA_POSITION, direction, (double)(float)time);
        Vec2 motion = uv_of(&matrices, running_position(rest, (double)(float)time))
            - uv_of(&matrices, running_position(rest, (double)(float)(time - VELOCITY_STEP)));
        Vec2 expected = { 0.5f + motion.x * scale, 0.5f + motion.y * scale };
        if (math::abs(expected.x - 0.5f) >= MIN_VELOCITY_ENCODED) moving++;
        Vec4 velocity = velocities[index];
        assert(math::abs(velocity.x - expected.x) <= VELOCITY_TOLERANCE, "x %f against %f", velocity.x, expected.x);
        assert(math::abs(velocity.y - expected.y) <= VELOCITY_TOLERANCE, "y %f against %f", velocity.y, expected.y);
    }
    assert(moving >= VELOCITY_ROW_SAMPLES / 2, "only %d samples move", moving);
    check_validation(&fixture.renderer);
}
