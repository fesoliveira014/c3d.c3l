module c3d_water_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::landscape::water @public;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
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
const Vec3 OCEAN_POSITION @local = { 1.7f, 0, -2.3f }; // off the origin, so the anchor's fold is not zero
const float OCEAN_SPLIT_PIXELS @local = 16; // small: the whole 12.8 m ocean draws at its finest level
const float LEVELS_CELL_SIZE @local = 0.1f; // 6.4 m chunks
const uint LEVELS_CHUNKS @local = 16; // five levels over 102.4 m
const Vec3 LEVELS_CAMERA @local = { -30, 3, -30 }; // in a corner of the ocean: the nearer levels cover a quarter plane
const uint LEVELS_VIEW_SIZE @local = 64;
const float LEVELS_FOV_DEGREES @local = 60;
const uint LEVELS_FRAMES @local = 3; // the view's selection history is valid from the second
const uint MINIMUM_LEVEL_SPAN @local = 2; // the camera sees at least three levels
const float ADJACENT_TOLERANCE @local = 0.001f; // metres: shared edges of boxes computed from the same lattice
const float SEAM_SPLIT_PIXELS @local = 1e9f; // the natural ranges vanish: the levels follow the camera position alone
const uint ZOOM_SIZE @local = 256;
const float ZOOM_FOV_DEGREES @local = 3; // 2.1 mm per pixel along a seam at 11 m, twice that across it
const uint SEAM_POINTS @local = 48; // pixels along a line across the seam
const float SEAM_POINT_STEP @local = 0.005f; // metres between them: the coarse cell is 0.2 m
const uint SEAM_LINES @local = 8; // lines along the seam
const float SEAM_LINE_STEP @local = 0.08f; // metres between lines: an eighth of the waves' 0.8 m
const float SEAM_SLACK @local = 0.0005f; // metres of depth reconstruction noise
const Vec3 SEAM_CAMERA @local = { -30, 8, -30 }; // high enough that the waves' slope stays under the line of sight
const Vec3 OCEAN_FOLLOW @local = { -1.6f, 0, 1 }; // metres a node follows the view by: eight steps of its 0.2 m snap
const double[3] TWIN_TIMES @local = { 0.5, 4.8, 65540.8 }; // 4.8 s puts wave 0's largest crest shift at the origin
const Vec3 POST_HALF_EXTENTS @local = { 0.05f, 0.5f, 0.05f }; // a slender crate: its eight cells see one surface
const float POST_DENSITY @local = 600;
const float POST_SUBMERSION @local = 0.6f; // metres of the post placed under the sampled surface
const uint MIRROR_SIZE @local = 64;
const uint WATER_LAYER @local = 2;
const float EMISSIVE_STRENGTH @local = 20;
const Vec3 MIRROR_CAMERA_POSITION @local = { 0, 1.5f, 4 };
const Vec3 LEFT_VIEW_POSITION @local = { -8, 1.5f, 6 }; // two viewing cameras 16 m apart, each facing a box of its own
const Vec3 RIGHT_VIEW_POSITION @local = { 8, 1.5f, 6 };
const Vec3 LEFT_BOX_POSITION @local = { -8, 2, -8 }; // seen by the left mirror only
const Vec3 RIGHT_BOX_POSITION @local = { 14, 2, -8 }; // seen by the right mirror only; 23 pixels off the left image
const Vec3 STEP_VIEW_POSITION @local = { 0, 5, 9 };
const Vec3 STEP_VIEW_FORWARD @local = { 0, -0.4f, -1 };
const float STEP_FOV_DEGREES @local = 90;
const float UPPER_LEVEL @local = 3; // metres above the lower body; the two mirrors place an image ten pixels apart
const Vec3 LOWER_BOX_POSITION @local = { -9, 5, -6 };
const Vec3 UPPER_BOX_POSITION @local = { 9, 6, -6 };
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
const float SEA_BLEND_SECONDS @local = 0.3f;
const float SEA_VELOCITY_TOLERANCE @local = 0.02f; // encoded units: twice the steady case's; measures 0.0096
const double SEA_START_TIME @local = 1000; // seconds: large, so the offsets and the phase products are not near zero
const uint SEA_STEADY_FRAMES @local = 3; // frames before the blend: the view's history is valid when it starts
const uint SEA_BLEND_FRAMES @local = 3; // frames into the blend when the velocities are read: two thirds done
const uint FIXED_POINT_STEPS @local = 24;
const char[*] TRACE_PROBE_SOURCE @local = $embed("trace_probe.comp.glsl");
const uint TRACE_GROUP_SIZE @local = 8; // mirrored as local_size_x and _y in trace_probe.comp.glsl
const uint RASTER_HIT @local = 1; // mirrored as RASTER_HIT in trace_probe.comp.glsl
const uint TRACE_HIT @local = 2; // mirrored as TRACE_HIT in trace_probe.comp.glsl
const uint PROBE_SIZE @local = 64;
const usz PROBE_PIXELS @local = PROBE_SIZE * PROBE_SIZE;
const usz PROBE_RESULT_BYTES @local = PROBE_PIXELS * TraceProbeResult::size;
const usz COVERAGE_MINIMUM @local = PROBE_PIXELS * 9 / 10; // the whole view looks at water
const float PROBE_CELL_SIZE @local = 0.2f; // ten cells to the shortest choppy wavelength
const double[3] PROBE_TIMES @local = { 0.5, 1.0, 1.5 }; // seconds; half a second moves wave 0 by a tenth of a cycle
const double SHADOW_PROBE_TIME @local = 2;
const float MOVE_MINIMUM @local = 0.05f; // metres: wave 0 moves the surface by up to 0.22 m in half a second
const bool[2] TRACE_KINDS @local = { false, true }; // ray_queries: software walk, then ray queries

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
const Wave[4] SWIFT_WAVES @local = { // fast enough that each frame moves the crest shift by several pixels
    { .amplitude = 0.3f, .wavelength = 8, .speed = 10, .direction = { 1, 0 }, .steepness = 0.5f },
    { .amplitude = 0.2f, .wavelength = 6, .speed = 8, .direction = { 0.8f, 0.6f }, .steepness = 0.5f },
    { .amplitude = 0.12f, .wavelength = 5, .speed = 7, .direction = { 0.28f, 0.96f }, .steepness = 0.5f },
    { .amplitude = 0.06f, .wavelength = 4, .speed = 6, .direction = { -0.6f, 0.8f }, .steepness = 0.5f },
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

struct TraceProbe @local {
    ViewId             view;
    Node*              camera;
    BufferId           output;
    gpu::MappedGpuSpan readback;
    ComputeShaderId    shader;
    ComputeShaderId    shadow_shader; // the same rays with the shadow-caster mask
    TraceKind          kind;
}

struct TraceAgreement @local {
    usz   covered;  // pixels where the drawn and the traced surface both answer
    usz   mismatch; // pixels where only one does
    float worst;    // largest distance between the two over covered pixels, in metres
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

fn void? create_fixture(Fixture* fixture, bool ray_queries = false) @local {
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
        desc:      { .validation = true, .application_name = "water_acceptance", .ray_queries = ray_queries },
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
        bool validation_message = entry.category.backend && entry.category.validation;
        assert(!validation_message);
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

fn Node* add_water_node(Fixture* fixture, WaterDesc desc, Vec3 position = {}) @local {
    Node* node = fixture.scene.add_node(name: "water")!!;
    node.local.position = position;
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

fn void update_water(Fixture* fixture, double time) @local {
    fixture.scene.update_world();
    water::update(
        scene:         &fixture.scene,
        assets:        &fixture.assets,
        wind_velocity: {},
        time:          time,
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
    update_water(fixture, time);
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

// Where the line from the eye through the point meets the water's rest plane at the level.
fn Vec3 plane_hit(Vec3 eye, Vec3 point, float level = 0) @local {
    Vec3 ray = point - eye;
    return eye + ray * ((level - eye.y) / ray.y);
}

// The image of the point across the horizontal plane at the level.
fn Vec3 image_of(Vec3 point, float level = 0) @local => { point.x, 2 * level - point.y, point.z };

// The part of a reflected emitter's radiance the surface passes at the point's image, halved for the box's edges.
fn float image_minimum(Vec3 eye, Vec3 image, float level = 0) @local {
    float normal_view = (eye - plane_hit(eye, image, level)).normalize().y;
    return 0.5f * schlick(normal_view) * EMISSIVE_STRENGTH;
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

fn void check_twin(
    Fixture* fixture,
    Wave[] waves,
    bool sea_state = false,
    bool ocean = false,
) @local {
    WaterDesc desc = surface_desc(waves, TWIN_EXTENT, TWIN_CELL_SIZE);
    if (ocean) desc.mode = OCEAN;
    Node* water_node = add_water_node(fixture, desc, ocean ? OCEAN_POSITION : (Vec3){});
    defer fixture.scene.remove(water_node);
    if (ocean) fixture.scene.get(water_node, InstancedMesh).quadtree.split_pixels = OCEAN_SPLIT_PIXELS;
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
    if (sea_state) {
        water::blend_to(
            scene:              &fixture.scene,
            node:               water_node.id,
            target:             CHOPPY_WAVES,
            transition_seconds: 0,
        );
        update_water(fixture, TWIN_TIMES[0]); // the switch, then the update that settles it
        update_water(fixture, TWIN_TIMES[0]);
    }
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
        WaterFluid lake = { .view = surface, .time = time };
        fixture.physics.set_fluid_sampler(&water::fluid_sample, &lake);
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        assert(fixture.physics.steps_last_update == 1);
        float fraction = fixture.scene.get(post, Buoyancy).submerged_fraction;
        fixture.physics.set_fluid_sampler(null, null);
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
    check_twin(&fixture, EXAMPLE_WAVES[..], sea_state: true);
}

fn void test_drawn_ocean_matches_the_cpu_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    check_twin(&fixture, EXAMPLE_WAVES[..], ocean: true);
    check_twin(&fixture, CHOPPY_WAVES[..], ocean: true);
}

// A chunk of an ocean: its level (0 is the finest) and footprint, from the layout the instance records follow.
struct OceanTile @local {
    uint  level;
    float min_x;
    float min_z;
    float edge;
}

fn OceanTile ocean_tile(uint index, uint chunks, float chunk_edge, Vec3 centre) @local {
    uint level;
    uint first;
    uint side = chunks;
    while (index >= first + side * side) {
        first += side * side;
        side >>= 1;
        level++;
    }
    uint offset = index - first;
    float edge = chunk_edge * (float)(1u << level);
    float corner = -(float)chunks * chunk_edge / 2;
    return {
        .level = level,
        .min_x = centre.x + corner + (float)(offset % side) * edge,
        .min_z = centre.z + corner + (float)(offset / side) * edge,
        .edge  = edge,
    };
}

// Two tiles touch when their footprints share an edge of positive length.
fn bool tiles_touch(OceanTile first, OceanTile second) @local {
    float end_x = math::min(first.min_x + first.edge, second.min_x + second.edge);
    float end_z = math::min(first.min_z + first.edge, second.min_z + second.edge);
    float along_x = end_x - math::max(first.min_x, second.min_x);
    float along_z = end_z - math::max(first.min_z, second.min_z);
    bool beside_x = math::abs(along_x) <= ADJACENT_TOLERANCE && along_z > ADJACENT_TOLERANCE;
    bool beside_z = math::abs(along_z) <= ADJACENT_TOLERANCE && along_x > ADJACENT_TOLERANCE;
    return beside_x || beside_z;
}

// Copies the selection words the renderer wrote for the view, one per node of the ocean.
fn void? record_selection_copy(
    Fixture* fixture,
    ViewId view,
    Node* ocean,
    gpu::MappedGpuSpan readback,
) @local {
    Renderer* renderer = &fixture.renderer;
    render::QuadtreeHistoryEntry* history = &renderer.views.get(view).quadtree_history.entries[ocean.id.index];
    assert(history.allocation.is_valid());
    usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * uint::size;
    gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, history.allocation)!;
    gpu::Barrier produced = { .before = { .compute, .vertex_shader }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &produced)!;
    gpu::BufferCopyDesc copy = { .src = source.checked_subspan(offset, readback.bytes.len)!, .dst = readback.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &copied);
}

// Renders frames of the view at one camera and returns the selection words of the last.
fn uint[]? render_selection(
    Fixture* fixture,
    Node* viewing,
    ViewId view,
    Node* ocean,
    gpu::MappedGpuSpan readback,
    uint frames,
) @local {
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < frames; frame++) {
        update_water(fixture, 0);
        renderer.begin_frame({ .time = 0, .delta = (float)VELOCITY_STEP })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&fixture.scene, viewing, view)!;
        if (frame + 1 == frames) {
            record_selection_copy(
                fixture:  fixture,
                view:     view,
                ocean:    ocean,
                readback: readback,
            )!;
        }
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    return ((uint*)readback.bytes.ptr)[:readback.bytes.len / uint::size];
}

fn gpu::MappedGpuSpan? create_selection_readback(Fixture* fixture, uint nodes) @local {
    gpu::AllocationDesc desc = {
        .size         = nodes * uint::size,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "ocean_selection_host",
    };
    return gpu::allocate_mapped_memory(&fixture.renderer.device, &desc);
}

fn void free_selection_readback(Fixture* fixture, gpu::MappedGpuSpan readback) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
}

fn WaterDesc levels_desc() @local {
    WaterDesc desc = surface_desc(EXAMPLE_WAVES[..], 0, LEVELS_CELL_SIZE);
    desc.mode = OCEAN;
    desc.extent = (float)LEVELS_CHUNKS * LEVELS_CELL_SIZE * (float)water::OCEAN_CHUNK_CELLS;
    return desc;
}

fn void test_ocean_levels_differ_by_at_most_one() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    WaterDesc desc = levels_desc();
    Node* ocean = add_water_node(&fixture, desc);
    Node* camera = add_camera_node(
        fixture:     &fixture,
        fov_degrees: LEVELS_FOV_DEGREES,
        position:    LEVELS_CAMERA,
        forward:     { 1, -0.4f, 1 },
        up:          { 0, 1, 0 },
    );
    ViewId view = add_view(&fixture, LEVELS_VIEW_SIZE);
    uint nodes = fixture.scene.get(ocean, InstancedMesh).count;
    gpu::MappedGpuSpan readback = create_selection_readback(&fixture, nodes)!!;
    defer free_selection_readback(&fixture, readback);

    uint[] words = render_selection(
        fixture:  &fixture,
        viewing:  camera,
        view:     view,
        ocean:    ocean,
        readback: readback,
        frames:   LEVELS_FRAMES,
    )!!;
    float chunk_edge = LEVELS_CELL_SIZE * (float)water::OCEAN_CHUNK_CELLS;
    OceanTile[] drawn = alloc::new_array(tmem, OceanTile, nodes);
    uint drawn_count;
    uint[LEVELS_CHUNKS] per_level;
    uint finest = uint::max;
    uint coarsest;
    foreach (uint index, word : words) {
        if (!(word & shader::QUADTREE_DRAW)) continue;

        OceanTile tile = ocean_tile(
            index:      index,
            chunks:     LEVELS_CHUNKS,
            chunk_edge: chunk_edge,
            centre:     {},
        );
        drawn[drawn_count++] = tile;
        per_level[tile.level]++;
        finest = math::min(finest, tile.level);
        coarsest = math::max(coarsest, tile.level);
    }
    foreach (first : drawn[:drawn_count]) {
        foreach (second : drawn[:drawn_count]) {
            if (!tiles_touch(first, second)) continue;

            uint difference = first.level > second.level ? first.level - second.level : second.level - first.level;
            assert(difference <= 1, "levels %d and %d share an edge", first.level, second.level);
        }
    }
    assert(coarsest - finest >= MINIMUM_LEVEL_SPAN, "only levels %d to %d drew", finest, coarsest);
    io::printfn("Ocean chunks per level, finest first: %s", per_level[:coarsest + 1]);
    check_validation(&fixture.renderer);
}

// The edge two tiles of neighbouring levels share, with the normal that points from the finer tile to the coarser.
struct SeamEdge @local {
    OceanTile fine;
    OceanTile coarse;
    Vec2      midpoint;
    Vec2      normal;
}

fn bool shared_edge(OceanTile fine, OceanTile coarse, SeamEdge* edge) @local {
    if (coarse.level != fine.level + 1 || !tiles_touch(fine, coarse)) return false;

    float fine_right = fine.min_x + fine.edge;
    float fine_top = fine.min_z + fine.edge;
    float overlap_x = math::max(fine.min_x, coarse.min_x) + 0.5f * (math::min(fine_right, coarse.min_x + coarse.edge)
      - math::max(fine.min_x, coarse.min_x));
    float overlap_z = math::max(fine.min_z, coarse.min_z) + 0.5f * (math::min(fine_top, coarse.min_z + coarse.edge)
      - math::max(fine.min_z, coarse.min_z));
    *edge = { .fine = fine, .coarse = coarse };
    if (math::abs(fine_right - coarse.min_x) <= ADJACENT_TOLERANCE) {
        edge.midpoint = { fine_right, overlap_z };
        edge.normal = { 1, 0 };
    } else if (math::abs(coarse.min_x + coarse.edge - fine.min_x) <= ADJACENT_TOLERANCE) {
        edge.midpoint = { fine.min_x, overlap_z };
        edge.normal = { -1, 0 };
    } else if (math::abs(fine_top - coarse.min_z) <= ADJACENT_TOLERANCE) {
        edge.midpoint = { overlap_x, fine_top };
        edge.normal = { 0, 1 };
    } else {
        edge.midpoint = { overlap_x, fine.min_z };
        edge.normal = { 0, -1 };
    }
    return true;
}

fn bool tile_contains(OceanTile tile, Vec3 point) @local {
    return point.x >= tile.min_x && point.x <= tile.min_x + tile.edge
      && point.z >= tile.min_z && point.z <= tile.min_z + tile.edge;
}

fn WaterDesc seam_desc() @local {
    WaterDesc desc = levels_desc();
    // Four cells of the level above the finest, along x and along z, so a seam has waves running along it.
    desc.waves[0] = { .amplitude = 0.025f, .wavelength = 0.8f, .speed = 0, .direction = { 1, 0 }, .steepness = 0.1f };
    desc.waves[1] = { .amplitude = 0.025f, .wavelength = 0.8f, .speed = 0, .direction = { 0, 1 }, .steepness = 0.1f };
    return desc;
}

fn void test_ocean_seam_is_continuous() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    WaterDesc desc = seam_desc();
    Node* ocean = add_water_node(&fixture, desc);
    fixture.scene.get(ocean, InstancedMesh).quadtree.split_pixels = SEAM_SPLIT_PIXELS;
    uint nodes = fixture.scene.get(ocean, InstancedMesh).count;
    gpu::MappedGpuSpan readback = create_selection_readback(&fixture, nodes)!!;
    defer free_selection_readback(&fixture, readback);

    Node* wide = add_camera_node(
        fixture:     &fixture,
        fov_degrees: LEVELS_FOV_DEGREES,
        position:    SEAM_CAMERA,
        forward:     { 1, -0.4f, 1 },
        up:          { 0, 1, 0 },
    );
    ViewId wide_view = add_view(&fixture, LEVELS_VIEW_SIZE);
    uint[] wide_words = alloc::new_array(tmem, uint, nodes);
    wide_words[..] = render_selection(
        fixture:  &fixture,
        viewing:  wide,
        view:     wide_view,
        ocean:    ocean,
        readback: readback,
        frames:   LEVELS_FRAMES,
    )!![..];

    float chunk_edge = LEVELS_CELL_SIZE * (float)water::OCEAN_CHUNK_CELLS;
    OceanTile[] drawn = alloc::new_array(tmem, OceanTile, nodes);
    uint drawn_count;
    foreach (uint index, word : wide_words) {
        if (!(word & shader::QUADTREE_DRAW)) continue;

        drawn[drawn_count++] = ocean_tile(
            index:      index,
            chunks:     LEVELS_CHUNKS,
            chunk_edge: chunk_edge,
            centre:     {},
        );
    }
    SeamEdge seam;
    float nearest = float::max;
    foreach (fine : drawn[:drawn_count]) {
        foreach (coarse : drawn[:drawn_count]) {
            SeamEdge candidate;
            if (!shared_edge(fine, coarse, &candidate)) continue;

            float distance = (candidate.midpoint - (Vec2){ SEAM_CAMERA.x, SEAM_CAMERA.z }).length();
            if (distance < nearest) {
                nearest = distance;
                seam = candidate;
            }
        }
    }
    assert(nearest < float::max, "No level changes within the view.");

    // The same camera position selects the same levels, so a camera that looks at the seam through a narrow lens
    // draws the edge the wide view found.
    Vec3 target = { seam.midpoint.x, 0, seam.midpoint.y };
    Node* zoom = add_camera_node(
        fixture:     &fixture,
        fov_degrees: ZOOM_FOV_DEGREES,
        position:    SEAM_CAMERA,
        forward:     target - SEAM_CAMERA,
        up:          { 0, 1, 0 },
    );
    ViewId zoom_view = add_view(&fixture, ZOOM_SIZE);
    uint[] zoom_words = render_selection(
        fixture:  &fixture,
        viewing:  zoom,
        view:     zoom_view,
        ocean:    ocean,
        readback: readback,
        frames:   LEVELS_FRAMES,
    )!!;
    assert(zoom_words[..] == wide_words[..], "The two lenses selected different levels.");

    SurfaceView surface = water::surface_view(&fixture.scene, &fixture.assets, ocean.id)!!;
    WaterDesc checked = fixture.scene.get(ocean, WaterRuntime).desc;
    float slope_limit = height_slope_bound(&checked);
    CameraMatrices matrices = matrices_of(&fixture, zoom, ZOOM_SIZE);
    Vec2 along = { -seam.normal.y, seam.normal.x };
    float worst;
    uint crossed;
    for (uint line = 0; line < SEAM_LINES; line++) {
        int[<2>][SEAM_POINTS] pixels;
        foreach (point, &pixel : pixels) {
            Vec2 offset = seam.normal * (((float)point - 0.5f * (SEAM_POINTS - 1)) * SEAM_POINT_STEP)
              + along * (((float)line - 0.5f * (SEAM_LINES - 1)) * SEAM_LINE_STEP);
            Vec2 ground = seam.midpoint + offset;
            float height = water::sample_surface(
                view:    &surface,
                world_x: ground.x,
                world_z: ground.y,
                time:    0,
            ) ?? 0;
            *pixel = pixel_of(&matrices, { ground.x, height, ground.y }, ZOOM_SIZE);
        }
        Vec4[] depths = render_and_read(
            fixture: &fixture,
            viewing: zoom,
            view:    zoom_view,
            time:    0,
            pixels:  pixels[..],
            depth:   true,
        )!!;
        Vec3[SEAM_POINTS] hits;
        foreach (point, hit : hits) {
            hits[point] = unproject(
                matrices: &matrices,
                pixel:    pixels[point],
                size:     ZOOM_SIZE,
                depth:    depths[point].x,
            );
        }
        if (tile_contains(seam.fine, hits[0]) != tile_contains(seam.fine, hits[SEAM_POINTS - 1])) crossed++;
        for (uint point = 1; point < SEAM_POINTS; point++) {
            float run = (Vec2){ hits[point].x - hits[point - 1].x, hits[point].z - hits[point - 1].z }.length();
            if (pixels[point] == pixels[point - 1]) continue;

            float step = math::abs(hits[point].y - hits[point - 1].y);
            worst = math::max(worst, step / (slope_limit * run + SEAM_SLACK));
            assert(step <= slope_limit * run + SEAM_SLACK, "line %d: depth stepped %f m over %f m", line, step, run);
        }
    }
    assert(crossed == SEAM_LINES, "Only %d of %d lines cross the seam.", crossed, SEAM_LINES);
    io::printfn(
        "Ocean seam at (%f, %f) between levels %d and %d: the largest step is %f of the bound",
        seam.midpoint.x,
        seam.midpoint.y,
        seam.fine.level,
        seam.coarse.level,
        worst,
    );
    check_validation(&fixture.renderer);
}

// Metres of height per metre of drawn surface, at most: the gradient the waves add in quadrature, over what the
// horizontal shift leaves.
fn float height_slope_bound(WaterDesc* desc) @local {
    float squares;
    float steepness;
    foreach (&wave : desc.waves[:desc.wave_count]) {
        float slope = wave.amplitude * 2 * (float)math::PI / wave.wavelength;
        squares += slope * slope;
        steepness += wave.steepness;
    }
    return math::sqrt(squares) / (1 - steepness / (float)desc.wave_count);
}

// The velocities of a running ocean after SETTLE_FRAMES frames, the last of them after the node moved by follow.
fn Vec4[VELOCITY_ROW_SAMPLES] ocean_velocities_after(Vec3 follow) @local {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Wave[1] running = { RUNNING_WAVE };
    WaterDesc desc = surface_desc(running[..], TWIN_EXTENT, TWIN_CELL_SIZE);
    desc.mode = OCEAN;
    Node* ocean = add_water_node(&fixture, desc, OCEAN_POSITION);
    fixture.scene.get(ocean, InstancedMesh).quadtree.split_pixels = OCEAN_SPLIT_PIXELS;
    Node* camera_node = add_camera_node(
        fixture:     &fixture,
        fov_degrees: TWIN_FOV_DEGREES,
        position:    VELOCITY_CAMERA_POSITION,
        forward:     { 0, -1, 0 },
        up:          { 0, 0, -1 },
    );
    ViewId view = add_view(&fixture, VELOCITY_SIZE, AntiAliasing.TAA);
    ViewDesc view_desc = fixture.renderer.views.get(view).desc;
    view_desc.post.taa_params.debug = TaaDebug.VELOCITY;
    render::configure_view(&fixture.renderer, view, view_desc)!!;

    int[<2>][VELOCITY_ROW_SAMPLES] pixels;
    int row = (int)VELOCITY_SIZE / 2;
    foreach (index, &pixel : pixels) *pixel = { 8 + 6 * (int)index, row };
    Vec4[] velocities;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        if (frame + 1 == SETTLE_FRAMES) {
            ocean.local.position += follow;
            fixture.scene.update_world();
        }
        velocities = render_and_read(
            fixture: &fixture,
            viewing: camera_node,
            view:    view,
            time:    (double)frame * VELOCITY_STEP,
            pixels:  pixels[..],
            depth:   false,
        )!!;
    }
    Vec4[VELOCITY_ROW_SAMPLES] result;
    result[..] = velocities[:VELOCITY_ROW_SAMPLES];
    check_validation(&fixture.renderer);
    return result;
}

fn void test_ocean_velocity_ignores_a_node_move() @test {
    Vec4[VELOCITY_ROW_SAMPLES] steady = ocean_velocities_after({});
    Vec4[VELOCITY_ROW_SAMPLES] followed = ocean_velocities_after(OCEAN_FOLLOW);
    uint moving;
    foreach (index, velocity : steady) {
        if (math::abs(velocity.x - 0.5f) >= MIN_VELOCITY_ENCODED) moving++;
        Vec4 after = followed[index];
        assert(math::abs(velocity.x - after.x) <= VELOCITY_TOLERANCE, "x %f against %f", after.x, velocity.x);
        assert(math::abs(velocity.y - after.y) <= VELOCITY_TOLERANCE, "y %f against %f", after.y, velocity.y);
    }
    assert(moving >= VELOCITY_ROW_SAMPLES / 2, "only %d samples move", moving);
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
    fixture.scene.update_world();
    water::update_mirror(&fixture.scene, water_node.id, 0, camera_node.id)!!;
    WaterRuntime* runtime = fixture.scene.get(water_node, WaterRuntime);
    RenderTargetId mirror_target = render::create_render_target(
        &fixture.renderer,
        render::render_target_desc(MIRROR_SIZE, MIRROR_SIZE),
    )!!;
    ViewDesc mirror_desc = render::texture_view_desc(mirror_target);
    mirror_desc.post.anti_aliasing = AntiAliasing.NONE;
    mirror_desc.clip_plane = runtime.clip_plane;
    ViewId mirror_view = render::create_view(&fixture.renderer, mirror_desc)!!;
    Node* mirror_node = fixture.scene.node(runtime.mirrors[0]);

    CameraMatrices matrices = matrices_of(&fixture, camera_node, MIRROR_SIZE);
    Vec3 box_image = FLOATING_BOX_POSITION * (Vec3){ 1, -1, 1 };
    Vec3 buried_image = BURIED_BOX_POSITION * (Vec3){ 1, -1, 1 };
    int[<2>][3] pixels = {
        pixel_of(&matrices, box_image, MIRROR_SIZE),
        pixel_of(&matrices, buried_image, MIRROR_SIZE),
        pixel_of(&matrices, { -4, 0, -8 }, MIRROR_SIZE),
    };
    Renderer* renderer = &fixture.renderer;
    update_water(&fixture, 0);
    renderer.begin_frame({ .time = 0, .delta = (float)VELOCITY_STEP })!!;
    renderer.render_view(&fixture.scene, mirror_node, mirror_view)!!;
    renderer.finish_view(mirror_view)!!;
    renderer.set_view_texture(main_view, 0, mirror_target)!!;
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
        update_water(&fixture, 0);
        water::update_mirror(&fixture.scene, water_node.id, 0, camera_node.id)!!;
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

struct Mirrored @local {
    Node*          body;
    uint           mirror_slot;
    ViewId         mirror_view;
    RenderTargetId target;     // provided to the viewing view at view_slot
    uint           view_slot;
}

struct Viewer @local {
    Node*       camera;
    ViewId      view;
    Mirrored[]  mirrors;
}

// A mirror view with a target of its own, clipped at the body's plane, for one slot of the body.
fn Mirrored add_mirrored(
    Fixture* fixture,
    Node* body,
    uint mirror_slot,
    uint view_slot,
    Node* viewing,
) @local {
    fixture.scene.update_world();
    water::update_mirror(&fixture.scene, body.id, mirror_slot, viewing.id)!!;

    RenderTargetId target = render::create_render_target(
        &fixture.renderer,
        render::render_target_desc(MIRROR_SIZE, MIRROR_SIZE),
    )!!;
    ViewDesc desc = render::texture_view_desc(target);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.clip_plane = fixture.scene.get(body, WaterRuntime).clip_plane;

    return {
        .body        = body,
        .mirror_slot = mirror_slot,
        .mirror_view = render::create_view(&fixture.renderer, desc)!!,
        .target      = target,
        .view_slot   = view_slot,
    };
}

// docs/water.md's frame for every viewer in turn: its mirrors, the textures it is given, then the viewer itself.
fn Vec4[]? render_viewers(
    Fixture* fixture,
    Viewer[] viewers,
    sz reader,
    int[<2>][] pixels,
) @local {
    Renderer* renderer = &fixture.renderer;
    fixture.scene.update_world();
    foreach (viewer : viewers) {
        foreach (mirrored : viewer.mirrors) {
            water::update_mirror(&fixture.scene, mirrored.body.id, mirrored.mirror_slot, viewer.camera.id)!;
        }
    }

    renderer.begin_frame({ .delta = (float)VELOCITY_STEP })!;
    defer catch render::abort_frame(renderer);
    foreach (index, viewer : viewers) {
        foreach (mirrored : viewer.mirrors) {
            Entity mirror = fixture.scene.get(mirrored.body, WaterRuntime).mirrors[mirrored.mirror_slot];
            renderer.render_view(&fixture.scene, fixture.scene.node(mirror), mirrored.mirror_view)!;
            renderer.finish_view(mirrored.mirror_view)!;
            renderer.set_view_texture(viewer.view, mirrored.view_slot, mirrored.target)!;
        }

        renderer.render_view(&fixture.scene, viewer.camera, viewer.view)!;
        if (index == reader) record_readback(fixture, render::read_view_color(viewer.view), pixels)!;
        renderer.finish_view(viewer.view)!;
    }

    renderer.end_frame()!;
    return read_texels(fixture, pixels.len);
}

fn void test_each_viewing_view_reflects_the_mirror_it_is_given() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    WaterDesc desc = surface_desc({}, 40, 1);
    desc.max_mirrors = 2;
    Node* water_node = add_water_node(&fixture, desc);
    add_emissive_box(&fixture, LEFT_BOX_POSITION, { 1, 1, 1 });
    add_emissive_box(&fixture, RIGHT_BOX_POSITION, { 1, 1, 1 });

    Vec3[2] positions = { LEFT_VIEW_POSITION, RIGHT_VIEW_POSITION };
    Vec3[2] boxes = { LEFT_BOX_POSITION, RIGHT_BOX_POSITION };

    Mirrored[2] mirrored;
    Viewer[2] viewers;
    int[<2>][2] pixels;
    float[2] minimums;
    foreach (index, position : positions) {
        Node* camera = add_camera_node(
            fixture:     &fixture,
            fov_degrees: 60,
            position:    position,
            forward:     { 0, -0.25f, -1 },
            up:          { 0, 1, 0 },
        );
        mirrored[index] = add_mirrored(
            fixture:     &fixture,
            body:        water_node,
            mirror_slot: (uint)index,
            view_slot:   0,
            viewing:     camera,
        );
        viewers[index] = { .camera = camera, .view = add_view(&fixture, MIRROR_SIZE), .mirrors = mirrored[index:1] };
        CameraMatrices matrices = matrices_of(&fixture, camera, MIRROR_SIZE);
        Vec3 image = image_of(boxes[index]);
        pixels[index] = pixel_of(&matrices, image, MIRROR_SIZE);
        minimums[index] = image_minimum(position, image);
    }

    foreach (reader, minimum : minimums) {
        Vec4[] colors = render_viewers(&fixture, viewers[..], reader, pixels[reader:1])!!;
        assert(luminance(colors[0]) >= minimum, "view %d shows %f of its own box", reader, luminance(colors[0]));
    }

    // Given each other's targets, neither view finds its box image where its own mirror put it.
    RenderTargetId first_target = viewers[0].mirrors[0].target;
    viewers[0].mirrors[0].target = viewers[1].mirrors[0].target;
    viewers[1].mirrors[0].target = first_target;
    for (sz reader = 0; reader < viewers.len; reader++) {
        Vec4[] colors = render_viewers(&fixture, viewers[..], reader, pixels[reader:1])!!;
        float found = luminance(colors[0]);
        assert(found <= DARK_LIMIT, "view %d shows %f of the other mirror", reader, found);
    }

    check_validation(&fixture.renderer);
}

fn void test_two_bodies_in_one_view_each_reflect_their_own_mirror() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    WaterDesc lower = surface_desc({}, 20, 1);
    WaterDesc upper = surface_desc({}, 20, 1);
    upper.reflection_view_slot = 1;
    Node* lower_node = add_water_node(&fixture, lower, { -10, 0, 0 });
    Node* upper_node = add_water_node(&fixture, upper, { 10, UPPER_LEVEL, 0 });
    add_emissive_box(&fixture, LOWER_BOX_POSITION, { 2, 2, 2 });
    add_emissive_box(&fixture, UPPER_BOX_POSITION, { 2, 2, 2 });

    Node* camera = add_camera_node(
        fixture:     &fixture,
        fov_degrees: STEP_FOV_DEGREES,
        position:    STEP_VIEW_POSITION,
        forward:     STEP_VIEW_FORWARD,
        up:          { 0, 1, 0 },
    );
    Mirrored[2] mirrored = {
        add_mirrored(
            fixture:     &fixture,
            body:        lower_node,
            mirror_slot: 0,
            view_slot:   0,
            viewing:     camera,
        ),
        add_mirrored(
            fixture:     &fixture,
            body:        upper_node,
            mirror_slot: 0,
            view_slot:   1,
            viewing:     camera,
        ),
    };

    Viewer[1] viewers = { { .camera = camera, .view = add_view(&fixture, MIRROR_SIZE), .mirrors = mirrored[..] } };
    CameraMatrices matrices = matrices_of(&fixture, camera, MIRROR_SIZE);
    Vec3 lower_image = image_of(LOWER_BOX_POSITION);
    Vec3 upper_image = image_of(UPPER_BOX_POSITION, UPPER_LEVEL);
    int[<2>][2] pixels = {
        pixel_of(&matrices, lower_image, MIRROR_SIZE),
        pixel_of(&matrices, upper_image, MIRROR_SIZE),
    };
    float lower_minimum = image_minimum(STEP_VIEW_POSITION, lower_image);
    float upper_minimum = image_minimum(STEP_VIEW_POSITION, upper_image, UPPER_LEVEL);

    Vec4[] colors = render_viewers(&fixture, viewers[..], 0, pixels[..])!!;
    assert(luminance(colors[0]) >= lower_minimum, "lower body shows %f", luminance(colors[0]));
    assert(luminance(colors[1]) >= upper_minimum, "upper body shows %f", luminance(colors[1]));

    // Slots swapped, each body samples the other's target, which holds its box ten pixels away.
    RenderTargetId lower_target = viewers[0].mirrors[0].target;
    viewers[0].mirrors[0].target = viewers[0].mirrors[1].target;
    viewers[0].mirrors[1].target = lower_target;
    colors = render_viewers(&fixture, viewers[..], 0, pixels[..])!!;
    assert(luminance(colors[0]) <= DARK_LIMIT, "lower body shows %f of the upper mirror", luminance(colors[0]));
    assert(luminance(colors[1]) <= DARK_LIMIT, "upper body shows %f of the lower mirror", luminance(colors[1]));

    check_validation(&fixture.renderer);
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

// Where the packed waves of one frame draw a rest point at a time, in double.
fn Vec3 drawn_point(SurfaceView* view, Vec2 rest, double time) @local {
    double drawn_time = (double)(float)time;
    double x = rest.x;
    double y = 0;
    double z = rest.y;
    foreach (&wave : view.waves[:view.wave_count]) {
        double along = (double)wave.direction.x * rest.x + (double)wave.direction.y * rest.y;
        double cycles = along * wave.cycles_per_metre - drawn_time * wave.cycles_per_second + wave.phase_offset;
        double angle = 2 * math::PI * (cycles - math::floor(cycles));
        x += (double)wave.shift * wave.direction.x * math::cos(angle);
        y += (double)wave.amplitude * math::sin(angle);
        z += (double)wave.shift * wave.direction.y * math::cos(angle);
    }
    return { (float)x, (float)y, (float)z };
}

// The rest point whose drawn position lies on the pixel's ray; the horizontal map contracts below steepness 1.
fn Vec2 rest_under_ray(SurfaceView* view, Vec3 origin, Vec3 direction, double time) @local {
    Vec2 rest = { origin.x - direction.x * origin.y / direction.y, origin.z - direction.z * origin.y / direction.y };
    for (uint step = 0; step < FIXED_POINT_STEPS; step++) {
        Vec3 drawn = drawn_point(view, rest, time);
        float along = (drawn.y - origin.y) / direction.y;
        Vec2 on_ray = { origin.x + direction.x * along, origin.z + direction.z * along };
        rest += on_ray - (Vec2){ drawn.x, drawn.z };
    }
    return rest;
}

fn void test_sea_state_velocity_matches_the_surface_motion() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Wave[2] flat = EXAMPLE_WAVES; // the blend grows the sea from nothing, so every frame moves it
    flat[0].amplitude = 0;
    flat[1].amplitude = 0;
    Node* water_node = add_water_node(&fixture, surface_desc(flat[..], TWIN_EXTENT, TWIN_CELL_SIZE));
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
    SurfaceView previous;
    SurfaceView current;
    double time;
    Vec4[] velocities;
    for (uint frame = 0; frame < SEA_STEADY_FRAMES + SEA_BLEND_FRAMES; frame++) {
        if (frame == SEA_STEADY_FRAMES) {
            water::blend_to(
                scene:              &fixture.scene,
                node:               water_node.id,
                target:             SWIFT_WAVES,
                transition_seconds: SEA_BLEND_SECONDS,
            );
        }
        time = SEA_START_TIME + (double)frame * VELOCITY_STEP;
        velocities = render_and_read(
            fixture: &fixture,
            viewing: camera_node,
            view:    view,
            time:    time,
            pixels:  pixels[..],
            depth:   false,
        )!!;
        previous = current;
        current = water::surface_view(&fixture.scene, &fixture.assets, water_node.id)!!;
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
        Vec2 rest = rest_under_ray(&current, VELOCITY_CAMERA_POSITION, direction, (double)(float)time);
        Vec2 motion = uv_of(&matrices, drawn_point(&current, rest, time))
            - uv_of(&matrices, drawn_point(&previous, rest, time - VELOCITY_STEP));
        Vec2 expected = { 0.5f + motion.x * scale, 0.5f + motion.y * scale };
        if (math::abs(expected.x - 0.5f) >= MIN_VELOCITY_ENCODED) moving++;
        Vec4 velocity = velocities[index];
        float error_x = math::abs(velocity.x - expected.x);
        float error_y = math::abs(velocity.y - expected.y);
        assert(error_x <= SEA_VELOCITY_TOLERANCE, "x %f against %f", velocity.x, expected.x);
        assert(error_y <= SEA_VELOCITY_TOLERANCE, "y %f against %f", velocity.y, expected.y);
    }
    assert(moving >= VELOCITY_ROW_SAMPLES / 2, "only %d samples move", moving);
    check_validation(&fixture.renderer);
}

fn ComputeShaderId? add_probe_shader(Fixture* fixture, String[] defines) @local {
    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)TRACE_PROBE_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
        defines:   defines,
    )!;
    defer alloc::free(mem, spirv.ptr);

    ComputeShaderDesc desc = { .compute = spirv };
    return fixture.assets.add_compute_shader(&desc);
}

fn TraceProbe? create_trace_probe(Fixture* fixture, Node* camera, bool ray_queries) @local {
    Renderer* renderer = &fixture.renderer;
    String kind = ray_queries ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH";
    String[1] all_rays = { kind };
    String[2] shadow_rays = { kind, "SHADOW_CASTERS" };
    gpu::AllocationDesc readback_desc = {
        .size         = PROBE_RESULT_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "water_trace_probe_host",
    };

    return {
        .view          = add_view(fixture, PROBE_SIZE),
        .camera        = camera,
        .output        = renderer.create_buffer({ .size = PROBE_RESULT_BYTES, .debug_name = "water_trace_probe" })!,
        .readback      = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!,
        .shader        = add_probe_shader(fixture, all_rays[..])!,
        .shadow_shader = add_probe_shader(fixture, shadow_rays[..])!,
        .kind          = ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE,
    };
}

fn void destroy_trace_probe(Fixture* fixture, TraceProbe* probe) @local {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = probe.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
}

fn void? record_probe(
    Fixture* fixture,
    TraceProbe* probe,
    gpu::GpuAddress trace_scene,
    bool shadow_rays,
) @local {
    Renderer* renderer = &fixture.renderer;
    CameraMatrices matrices = matrices_of(fixture, probe.camera, PROBE_SIZE);
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
        .shader   = shadow_rays ? probe.shadow_shader : probe.shader,
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

// The view draws the water at the time, then one scene trace answers the pixel rays of the same frame.
fn void? trace_frame(
    Fixture* fixture,
    TraceProbe* probe,
    double time,
    bool shadow_rays = false,
) @local {
    Renderer* renderer = &fixture.renderer;
    update_water(fixture, time);

    renderer.begin_frame({ .time = time, .delta = (float)VELOCITY_STEP })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&fixture.scene, probe.camera, probe.view)!;
    gpu::GpuAddress trace_scene = renderer.prepare_scene_trace(&fixture.scene, probe.kind)!;
    record_probe(
        fixture:     fixture,
        probe:       probe,
        trace_scene: trace_scene,
        shadow_rays: shadow_rays,
    )!;
    renderer.finish_view(probe.view)!;
    renderer.end_frame()!;
    return render::wait_frames(renderer);
}

fn TraceProbeResult[] read_probe(Fixture* fixture, TraceProbe* probe) @local {
    gpu::invalidate_mapped_span(&fixture.renderer.device, probe.readback.span)!!;
    return ((TraceProbeResult*)probe.readback.bytes.ptr)[:PROBE_PIXELS];
}

fn TraceAgreement trace_agreement(Fixture* fixture, TraceProbe* probe) @local {
    TraceAgreement agreement;
    foreach (&result : read_probe(fixture, probe)) {
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

// The largest change of a pixel's traced distance since the distances taken last; stores the new ones.
fn float follow_distances(Fixture* fixture, TraceProbe* probe, float[] distances) @local {
    float largest;
    foreach (index, &result : read_probe(fixture, probe)) {
        largest = math::max(largest, math::abs(result.traced - distances[index]));
        distances[index] = result.traced;
    }
    return largest;
}

fn void test_traced_water_agrees_with_the_drawn_surface_and_follows_the_waves() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(&fixture, ray_queries)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;

        WaterDesc desc = surface_desc(CHOPPY_WAVES[..], TWIN_EXTENT, PROBE_CELL_SIZE);
        desc.trace = true;
        add_water_node(&fixture, desc);
        Node* camera_node = add_camera_node(
            fixture:     &fixture,
            fov_degrees: TWIN_FOV_DEGREES,
            position:    TWIN_CAMERA_POSITION,
            forward:     { 0, -1, 0 },
            up:          { 0, 0, -1 },
        );
        TraceProbe probe = create_trace_probe(&fixture, camera_node, ray_queries)!!;
        defer destroy_trace_probe(&fixture, &probe);

        float[PROBE_PIXELS] distances;
        foreach (frame, time : PROBE_TIMES) {
            bool first = frame == 0;
            trace_frame(&fixture, &probe, time)!!;
            assert(renderer.stats.trace_posed_instances == 1 && renderer.stats.trace_deform_overflow == 0);
            assert(renderer.stats.trace_skipped == 0 && renderer.stats.shader_rejections == 0);
            assert(renderer.stats.trace_poses == 1 && renderer.stats.trace_refits == (ray_queries ? 0 : 1));
            assert(renderer.stats.blas_builds == (ray_queries && first ? 1 : 0));
            assert(renderer.stats.blas_updates == (ray_queries && !first ? 1 : 0));

            TraceAgreement agreement = trace_agreement(&fixture, &probe);
            assert(agreement.covered >= COVERAGE_MINIMUM && agreement.mismatch == 0);
            assert(agreement.worst <= SURFACE_TOLERANCE, "worst %f at %f s", agreement.worst, time);
            float change = follow_distances(&fixture, &probe, distances[..]);
            assert(first || change >= MOVE_MINIMUM, "the traced surface moved %f m between frames", change);
        }

        trace_frame(&fixture, &probe, SHADOW_PROBE_TIME, shadow_rays: true)!!;
        TraceAgreement shadowed = trace_agreement(&fixture, &probe);
        assert(shadowed.covered == 0 && shadowed.mismatch >= COVERAGE_MINIMUM, "the water cast a traced shadow");
        check_validation(renderer);
    }
}
