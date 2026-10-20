module particle_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::job;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::particle;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;
import std::io;
import std::io::file;
import std::math;
import std::time;
import std::time::clock;

const uint WIDTH @local = 1920;
const uint HEIGHT @local = 1080;
const uint SPRITE_SIZE @local = 64;
const uint SMOKE_CAPACITY @local = 8192; // about 1 MiB of simulation and scene draw data
const uint SPARK_CAPACITY @local = 4096;
const uint DEBRIS_CAPACITY @local = 1024;
const uint PUFF_CAPACITY @local = 8192; // 448 KiB pool; above the puffs alive at the spark death rate
const uint SPARK_EVENTS @local = 512; // 24 KiB queue; above the deaths one step raises at the spark rate
const float OBSTACLE_THICKNESS @local = 0.12f;
const Vec3 CANOPY_SIZE @local = { 2.4f, OBSTACLE_THICKNESS, 2.4f };
const Vec3 CANOPY_POSITION @local = { 0, 1.7f, 0 };
const Vec3 CRATE_SIZE @local = { 0.7f, 0.7f, 0.7f };
const Vec3[2] CRATE_POSITIONS @local = { { -1.7f, 0.35f, 0.4f }, { 1.5f, 0.35f, -0.3f } };
const uint STRESS_CAPACITY @local = 100_000; // about 18 MiB of pool, draw and packed records
const uint MAX_VIEWS @local = 2;
const float SPARK_RATE @local = 3200; // per second at SPARK_CAPACITY; scales with --capacity to keep the pool full
const float SATURATED_REQUEST_FRACTION @local = 0.1f; // share of the pool requested every step of the saturated segment
const uint DEFAULT_BENCHMARK_FRAMES @local = 300;
const uint WARMUP_FRAMES @local = 60; // warm pipelines, uploads and delayed timestamp readback
const uint PREWARM_STEPS @local = 1200; // twenty simulated seconds mix the ages before steady-state measurements
const float STEP_SECONDS @local = 1.0f / 60;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const uint SPRITE_CHANNELS @local = 4;
const ZString[3] EFFECT_NAMES @local = { "Smoke", "Sparks", "Debris" };
const uint SMOKE_SHEET_COLUMNS @local = 4;
const uint SMOKE_CELL_TEXELS @local = 64;
const uint SMOKE_SHEET_TEXELS @local = SMOKE_SHEET_COLUMNS * SMOKE_CELL_TEXELS;
const uint SMOKE_CELL_PADDING @local = 8; // zero-alpha border; 2^(4 - 1) texels cover four sampled mip levels
const float SMOKE_FRAME_RATE @local = 6;
const uint EMBER_CAPACITY @local = 3072; // above the embers alive at the ember rate
const Vec3 EMBER_POSITION @local = { 0, 0.1f, 3 };
const float EMBER_STRENGTH @local = 1.6f; // metres per second; comparable to the embers' own launch speed
const float EMBER_FREQUENCY @local = 1.5f; // lattice cells per metre
const uint EMBER_OCTAVES @local = 3;
const uint EMBER_PERIOD @local = 32; // cells; the pattern repeats every period / frequency metres
const Vec3 EMBER_SCROLL @local = { 0, 0.4f, 0 }; // metres per second; the pattern climbs with the embers
const uint TRAIL_POINTS @local = 24;
const float TRAIL_INTERVAL @local = STEP_SECONDS; // one point per rendered frame at the fixed benchmark step
const float TRAIL_LIFETIME @local = 0.4f; // seconds; about the span the 24 points cover at the fixed step
const float TRAIL_WIDTH @local = 0.05f; // metres at the live position
const uint STREAK_ACROSS @local = 32;
const uint STREAK_ALONG @local = 4;
const float PUFF_BASE_RADIUS @local = 10; // texels at the first frame
const float PUFF_GROWTH @local = 8; // texels gained by the last frame
const float PUFF_EDGE_WARP @local = 0.35f; // share of the radius the lobes move the edge
const float PUFF_THINNING @local = 0.6f; // opacity lost by the last frame
const float[2] PUFF_LOBES @local = { 3, 5 };
const float[2] PUFF_LOBE_DRIFT @local = { 0.7f, -1.1f };
const ZString[4] LIGHTING_NAMES @local = { "unlit", "ambient", "direct", "direct_shadowed" };
const ZString[3] NORMAL_NAMES @local = { "camera", "spherical", "volume" };
const ParticleLighting[3] LIT_BENCHMARK_LIGHTING @local = { AMBIENT, DIRECT, DIRECT_SHADOWED };
const Vec3 LIT_SMOKE_POSITION @local = { 0, 0.15f, 0 };
const Vec3[2] LIT_CAMERA_POSITIONS @local = { { 4.5f, 2.5f, 9.5f }, { -7, 2.5f, 6 } };
const Vec3 LIT_CAMERA_FOCUS @local = { 0, 2, 0 };
const ParticleRange LIT_SMOKE_LIFETIME @local = { .min = 3, .max = 4 }; // a plume the frame holds
const Vec3 SLAB_SIZE @local = { 2.4f, OBSTACLE_THICKNESS, 2.4f };
const Vec3 SLAB_POSITION @local = { 0.9f, 2.2f, 0.3f }; // offset toward the sun, so its shadow falls across the plume
const float LAMP_ORBIT_RADIUS @local = 1.8f;
const float LAMP_ORBIT_HEIGHT @local = 1.4f;
const float LAMP_ORBIT_SPEED @local = 0.7f; // radians per second
const float LAMP_INTENSITY @local = 6;
const float LAMP_RANGE @local = 8;
const float SMOKE_ANISOTROPY @local = 0.4f;
const float MAX_SMOKE_ANISOTROPY @local = 0.95f; // below one, where the phase function diverges

struct Options @local {
    bool benchmark;
    bool stress;
    bool sparks;
    bool smoke;
    bool lit_smoke;
    bool embers;
    bool trails;
    bool debris_shadows;
    bool collide;
    bool drop_oldest;
    bool limit_frames;
    bool single_lighting;
    uint frames;
    uint workers;
    uint views;
    uint capacity;
    ParticleLighting lighting;
    ParticleNormal normal;
    String capture_rgba;
}

struct Workers @local {
    JobPool pool;
    bool pooled;
    uint count;
}

struct Demo @local {
    AssetStore assets;
    Scene scene;
    PhysicsWorld physics;
    Workers workers;
    bool has_physics;
    Node*[3] emitters;
    Node*[2] cameras;
    Node* spark_puffs;
    Node* lamp;
    bool lit_smoke;
    Node* embers;
    MaterialId smoke;
    MaterialId sparks;
    MaterialId smoke_sheet;
    MaterialId embers_material;
    MaterialId trail_material;
    ParticleMaterialParams smoke_params;
    ParticleMaterialParams spark_params;
}

struct Metrics @local {
    double update_ms;
    double frame_ms;
    double[3] alive;
    ulong upload_bytes;
    double gpu_sort_ms;
    double gpu_transparent_ms;
    uint gpu_samples;
    bool sorted;
    bool transparent;
}

fn ParticleTurbulence ember_turbulence() @local {
    return {
        .strength = EMBER_STRENGTH,
        .frequency = EMBER_FREQUENCY,
        .octaves = EMBER_OCTAVES,
        .period = EMBER_PERIOD,
        .scroll = EMBER_SCROLL,
    };
}

fn ParticleTrail spark_trail(MaterialId material) @local {
    ParticleTrail trail = {
        .max_points = TRAIL_POINTS,
        .point_interval = TRAIL_INTERVAL,
        .lifetime = TRAIL_LIFETIME,
        .width = TRAIL_WIDTH,
        .material = material,
    };
    trail.width_over_trail.values = { 1, 0.85f, 0.7f, 0.55f, 0.4f, 0.25f, 0.1f, 0 };
    float[8] fade = { 1, 0.8f, 0.6f, 0.45f, 0.3f, 0.2f, 0.1f, 0 };
    foreach (index, alpha : fade) trail.color_over_trail.values[index] = { 1, 1, 1, alpha };
    return trail;
}

fn void run_on_pool(
    void* context,
    ParallelRangeFn range,
    void* data,
    uint count,
    uint batch,
) @local {
    JobPool* pool = context;
    pool.wait(pool.run(
        range: range,
        data:  data,
        count: count,
        batch: batch,
    ));
}

fn void? create_workers(Workers* workers, uint count) @local {
    if (!count) return;

    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = count;
    desc.background_workers = job::default_background_workers(count);
    workers.pool = job::create_job_pool(mem, desc)!;
    workers.pooled = true;
    workers.count = count;
}

fn void destroy_workers(Workers* workers) @local {
    if (workers.pooled) job::destroy_job_pool(&workers.pool);
    workers.pooled = false;
}

fn ParallelFor Workers.parallel(&self) {
    if (!self.pooled) return {};

    return { .run = &run_on_pool, .context = &self.pool };
}

fn double elapsed_ms(time::Clock started) @local {
    return (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;
}

fn TextureId? add_sprite(AssetStore* assets) @local {
    char[SPRITE_SIZE * SPRITE_SIZE * SPRITE_CHANNELS] pixels;
    for (uint y = 0; y < SPRITE_SIZE; y++) {
        for (uint x = 0; x < SPRITE_SIZE; x++) {
            float horizontal = 2 * ((float)x + 0.5f) / SPRITE_SIZE - 1;
            float vertical = 2 * ((float)y + 0.5f) / SPRITE_SIZE - 1;
            float coverage = math::max(0.0f, 1 - horizontal * horizontal - vertical * vertical);
            uint offset = (y * SPRITE_SIZE + x) * SPRITE_CHANNELS;
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = char::max;
            pixels[offset + 3] = (char)(coverage * coverage * char::max);
        }
    }
    return assets.add_texture(
        material::texture_2d_desc(SPRITE_SIZE, SPRITE_SIZE, PixelFormat.RGBA8_UNORM),
        pixels[..],
    );
}

fn TextureId? add_streak(AssetStore* assets) @local {
    char[STREAK_ACROSS * STREAK_ALONG * SPRITE_CHANNELS] pixels;
    for (uint y = 0; y < STREAK_ALONG; y++) {
        for (uint x = 0; x < STREAK_ACROSS; x++) {
            float across = 2 * ((float)x + 0.5f) / STREAK_ACROSS - 1;
            float coverage = 1 - across * across;
            uint offset = (y * STREAK_ACROSS + x) * SPRITE_CHANNELS;
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = char::max;
            pixels[offset + 3] = (char)(coverage * coverage * char::max);
        }
    }
    return assets.add_texture(
        material::texture_2d_desc(STREAK_ACROSS, STREAK_ALONG, PixelFormat.RGBA8_UNORM),
        pixels[..],
    );
}

fn float puff_alpha(uint frame, uint x, uint y) @local {
    float centre = (float)SMOKE_CELL_TEXELS / 2;
    float horizontal = (float)x + 0.5f - centre;
    float vertical = (float)y + 0.5f - centre;
    float progress = (float)frame / (SMOKE_SHEET_COLUMNS * SMOKE_SHEET_COLUMNS - 1);
    float angle = math::atan2(vertical, horizontal);
    float lobes;
    foreach (index, count : PUFF_LOBES) lobes += math::sin(count * angle + PUFF_LOBE_DRIFT[index] * frame) / 2;
    float edge = (PUFF_BASE_RADIUS + PUFF_GROWTH * progress) * (1 + PUFF_EDGE_WARP * lobes / 2);
    edge = math::min(edge, centre - SMOKE_CELL_PADDING);
    float coverage = math::max(0.0f, 1 - (horizontal * horizontal + vertical * vertical) / (edge * edge));
    return coverage * coverage * (1 - PUFF_THINNING * progress);
}

fn TextureId? add_smoke_sheet(AssetStore* assets) @local {
    char[] pixels = mem::new_array(char, SMOKE_SHEET_TEXELS * SMOKE_SHEET_TEXELS * SPRITE_CHANNELS);
    defer free(pixels);
    for (uint y = 0; y < SMOKE_SHEET_TEXELS; y++) {
        for (uint x = 0; x < SMOKE_SHEET_TEXELS; x++) {
            uint frame = y / SMOKE_CELL_TEXELS * SMOKE_SHEET_COLUMNS + x / SMOKE_CELL_TEXELS;
            float alpha = puff_alpha(frame, x % SMOKE_CELL_TEXELS, y % SMOKE_CELL_TEXELS);
            uint offset = (y * SMOKE_SHEET_TEXELS + x) * SPRITE_CHANNELS;
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = char::max;
            pixels[offset + 3] = (char)(alpha * char::max);
        }
    }
    return assets.add_texture(
        material::texture_2d_desc(SMOKE_SHEET_TEXELS, SMOKE_SHEET_TEXELS, PixelFormat.RGBA8_UNORM),
        pixels[..],
    );
}

fn void destroy_demo(Demo* demo) @local {
    destroy_workers(&demo.workers);
    if (demo.has_physics) {
        demo.scene.get(demo.emitters[1], ParticleSystem).set_collision(null, null);
        physics::destroy_physics_world(&demo.physics);
    }
    scene::destroy_scene(&demo.scene);
    asset::destroy_asset_store(&demo.assets);
}

fn void? add_lit_smoke_props(Demo* demo) @local {
    demo.lamp = demo.scene.add_light(light::point({ 1, 0.65f, 0.35f }, LAMP_INTENSITY, LAMP_RANGE), name: "lamp")!;

    GeometryId slab_geometry;
    @pool() {
        Geometry shape = geometry::box(
            allocator: tmem,
            width: SLAB_SIZE.x,
            height: SLAB_SIZE.y,
            depth: SLAB_SIZE.z,
        );
        slab_geometry = demo.assets.add_geometry(&shape)!;
    };
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.35f, 0.4f, 0.5f, 1 };
    surface.metallic = 0;
    surface.roughness = 0.6f;
    MaterialId slab_material = demo.assets.add_material(material::standard(surface))!;

    Node* slab = demo.scene.add_mesh(slab_geometry, slab_material, name: "slab")!;
    slab.local.position = SLAB_POSITION;
}

fn void orbit_lamp(Demo* demo, double elapsed) @local {
    if (!demo.lamp) return;

    float angle = (float)elapsed * LAMP_ORBIT_SPEED;
    demo.lamp.local.position = {
        LIT_SMOKE_POSITION.x + math::cos(angle) * LAMP_ORBIT_RADIUS,
        LAMP_ORBIT_HEIGHT,
        LIT_SMOKE_POSITION.z + math::sin(angle) * LAMP_ORBIT_RADIUS,
    };
}

fn void? apply_smoke_params(Demo* demo) @local {
    demo.assets.@set_custom_params(demo.smoke, demo.smoke_params)!;
    if (demo.smoke_sheet.generation) demo.assets.@set_custom_params(demo.smoke_sheet, demo.smoke_params)!;
}

fn void? cycle_smoke_look(Demo* demo, Input* input) @local {
    bool changed;
    if (input.key_pressed(platform::Scancode.L)) {
        usz next = ((usz)demo.smoke_params.lighting.ordinal + 1) % LIGHTING_NAMES.len;
        demo.smoke_params.lighting = ParticleLighting::from_ordinal(next);
        changed = true;
    }
    if (input.key_pressed(platform::Scancode.N)) {
        usz next = ((usz)demo.smoke_params.normal.ordinal + 1) % NORMAL_NAMES.len;
        demo.smoke_params.normal = ParticleNormal::from_ordinal(next);
        changed = true;
    }
    if (changed) apply_smoke_params(demo)!;
}

fn Demo? create_demo(Options options) @local {
    Demo demo = {
        .assets = asset::create_asset_store(mem, asset::default_asset_store_desc()),
        .scene = scene::create_scene(mem, { .max_nodes = 48 }),
        .lit_smoke = options.lit_smoke,
    };
    defer catch destroy_demo(&demo);
    create_workers(&demo.workers, options.workers)!;
    particle::register_particles(&demo.scene)!;
    demo.scene.background.color = { 0.018f, 0.025f, 0.04f, 1 };
    demo.scene.ambient_color = { 1, 1, 1 };
    demo.scene.ambient_intensity = 0.45f;
    ShaderId shader = particle::add_particle_shader(&demo.assets)!;
    TextureId sprite = add_sprite(&demo.assets)!;
    demo.smoke_params = { .color = { 0.8f, 0.86f, 0.95f, 1 }, .soft_distance = 0.5f, .lighting = AMBIENT };
    demo.spark_params = { .color = { 1, 0.6f, 0.1f, 1 }, .soft_distance = 0.08f };
    if (options.lit_smoke) {
        demo.smoke_params.lighting = options.lighting;
        demo.smoke_params.normal = options.normal;
        demo.smoke_params.anisotropy = SMOKE_ANISOTROPY;
    }
    demo.smoke = particle::add_particle_material(
        assets: &demo.assets,
        shader: shader,
        params: demo.smoke_params,
        map: material::texture_slot(sprite),
    )!;
    demo.sparks = particle::add_particle_material(
        assets: &demo.assets,
        shader: shader,
        params: demo.spark_params,
        map: material::texture_slot(sprite),
        blend: BlendMode.ADDITIVE,
    )!;
    if (options.smoke) {
        TextureId sheet = add_smoke_sheet(&demo.assets)!;
        demo.smoke_sheet = particle::add_particle_material(
            assets: &demo.assets,
            shader: shader,
            params: demo.smoke_params,
            map: material::texture_slot(sheet),
        )!;
    }
    if (options.embers) {
        demo.embers_material = particle::add_particle_material(
            assets: &demo.assets,
            shader: shader,
            params: { .color = { 1, 0.5f, 0.12f, 1 }, .soft_distance = 0.05f },
            map: material::texture_slot(sprite),
            blend: BlendMode.ADDITIVE,
        )!;
    }
    if (options.trails) {
        TextureId streak = add_streak(&demo.assets)!;
        demo.trail_material = particle::add_particle_material(
            assets: &demo.assets,
            shader: shader,
            params: { .color = { 1, 0.55f, 0.15f, 1 }, .soft_distance = 0.05f },
            map: material::texture_slot(streak),
            blend: BlendMode.ADDITIVE,
        )!;
    }
    GeometryId box;
    GeometryId floor;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        box = demo.assets.add_geometry(&cube)!;
        Geometry plane = geometry::plane(tmem, 30, 30);
        floor = demo.assets.add_geometry(&plane)!;
    };
    MaterialId ground_material;
    if (options.debris_shadows) {
        StandardParams ground = material::STANDARD_PARAMS_DEFAULT;
        ground.base_color = { 0.35f, 0.4f, 0.45f, 1 };
        ground.metallic = 0;
        ground.roughness = 0.9f;
        ground_material = demo.assets.add_material(material::standard(ground))!;
    } else {
        ground_material = demo.assets.add_material(material::basic({ .color = { 0.08f, 0.11f, 0.15f, 1 } }))!;
    }
    Node* ground = demo.scene.add_mesh(floor, ground_material)!;
    demo.scene.get(ground, Mesh).cast_shadow = false;
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.7f, 0.75f, 0.85f, 1 };
    surface.metallic = 0;
    surface.roughness = 0.7f;
    MaterialId debris_material = demo.assets.add_material(material::standard(surface))!;
    bool sun_shadow = options.lit_smoke || options.debris_shadows;
    Node* sun = demo.scene.add_light(light::directional({ 1, 0.9f, 0.8f }, 2, sun_shadow))!;
    sun.local.rotation = maths::look_rotation({ -0.5f, -1, -0.3f }, { 0, 1, 0 });
    if (options.lit_smoke) add_lit_smoke_props(&demo)!;

    ParticleSystemDesc smoke = particle::default_particle_system_desc();
    smoke.capacity = SMOKE_CAPACITY;
    smoke.material = demo.smoke;
    smoke.shape = CONE;
    smoke.radius = 0.3f;
    smoke.cone_angle = 0.25f;
    smoke.rate = 1400;
    smoke.lifetime = options.lit_smoke ? LIT_SMOKE_LIFETIME : (ParticleRange){ .min = 5, .max = 7 };
    smoke.speed = { .min = 0.8f, .max = 1.5f };
    smoke.size = { .min = 0.18f, .max = 0.35f };
    smoke.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
    smoke.spin = { .min = -0.2f, .max = 0.2f };
    smoke.color_min = { 0.6f, 0.6f, 0.6f, 0.04f };
    smoke.color_max = { 1, 1, 1, 0.09f };
    smoke.drag = 0.1f;
    smoke.gravity_scale = -0.03f;
    smoke.size_over_life.values = { 0.5f, 1, 1.5f, 2.2f, 3, 4, 5, 6 };
    if (options.smoke) {
        smoke.material = demo.smoke_sheet;
        smoke.flipbook = {
            .columns = SMOKE_SHEET_COLUMNS,
            .rows = SMOKE_SHEET_COLUMNS,
            .frame_count = SMOKE_SHEET_COLUMNS * SMOKE_SHEET_COLUMNS,
            .inset = { 0.5f / SMOKE_SHEET_TEXELS, 0.5f / SMOKE_SHEET_TEXELS },
            .mode = FPS,
            .fps = SMOKE_FRAME_RATE,
            .random_start = true,
            .blend = true,
        };
    }
    float[8] opacity = { 0, 0.7f, 1, 1, 0.9f, 0.6f, 0.3f, 0 };
    foreach (index, alpha : opacity) smoke.color_over_life.values[index] = { 1, 1, 1, alpha };
    demo.emitters[0] = demo.scene.add_particle_system(smoke, name: "smoke")!;
    demo.emitters[0].local.position = options.lit_smoke ? LIT_SMOKE_POSITION : (Vec3){ -3, 0.15f, 0 };

    if (options.sparks) {
        ParticleSystemDesc puff = particle::default_particle_system_desc();
        puff.capacity = PUFF_CAPACITY;
        puff.seed = 4;
        puff.material = demo.smoke;
        puff.lifetime = { .min = 1, .max = 1.8f };
        puff.speed = { .min = 0.2f, .max = 0.7f };
        puff.size = { .min = 0.12f, .max = 0.25f };
        puff.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
        puff.color_min = { 0.7f, 0.7f, 0.7f, 0.2f };
        puff.color_max = { 1, 1, 1, 0.4f };
        puff.drag = 0.5f;
        puff.gravity_scale = -0.05f;
        puff.size_over_life.values = { 0.6f, 1, 1.5f, 2, 2.6f, 3, 3.4f, 3.8f };
        foreach (index, alpha : opacity) puff.color_over_life.values[index] = { 1, 1, 1, alpha };
        demo.spark_puffs = demo.scene.add_particle_system(puff, name: "spark smoke")!;
    }

    ParticleSystemDesc sparks = particle::default_particle_system_desc();
    sparks.capacity = options.capacity;
    sparks.seed = 2;
    sparks.material = demo.sparks;
    sparks.render_mode = STRETCHED;
    sparks.shape = CONE;
    sparks.radius = 0.15f;
    sparks.cone_angle = 0.4f;
    sparks.rate = SPARK_RATE * options.capacity / SPARK_CAPACITY;
    sparks.lifetime = { .min = 1, .max = 1.6f };
    sparks.speed = { .min = 5, .max = 8 };
    sparks.size = { .min = 0.025f, .max = 0.05f };
    sparks.gravity_scale = 1;
    sparks.drag = 0.1f;
    sparks.stretch = 0.055f;
    sparks.color_min = { 1, 0.5f, 0.2f, 0.3f };
    sparks.color_max = { 1, 1, 0.6f, 0.7f };
    foreach (index, alpha : opacity) sparks.color_over_life.values[index] = { 1, 1, 1, 1 - (float)index / 7 };
    if (options.sparks) {
        sparks.max_events = SPARK_EVENTS;
        sparks.sub_emitter_count = 1;
        sparks.sub_emitters[0] = {
            .trigger = DEATH,
            .target = demo.spark_puffs.id,
            .count = 1,
            .inherit_velocity = 0.1f,
        };
    }
    if (options.trails) sparks.trail = spark_trail(demo.trail_material);
    if (options.collide) {
        sparks.collision.response = BOUNCE;
        sparks.collision.restitution = 0.45f;
        sparks.collision.friction = 0.3f;
        sparks.collision.ground_plane = true;
        sparks.collision.max_queries = options.capacity; // one ray per spark, so none wait
    }
    demo.emitters[1] = demo.scene.add_particle_system(sparks, name: "sparks")!;
    demo.emitters[1].local.position = { 0, 0.2f, 0 };

    ParticleSystemDesc debris = particle::default_particle_system_desc();
    debris.capacity = DEBRIS_CAPACITY;
    debris.seed = 3;
    debris.render_mode = MESH;
    debris.material = debris_material;
    debris.geometry = box;
    debris.mesh_cast_shadow = options.debris_shadows;
    debris.shape = CONE;
    debris.radius = 0.2f;
    debris.cone_angle = 0.5f;
    debris.rate = 450;
    debris.lifetime = { .min = 2, .max = 3 };
    debris.speed = { .min = 4, .max = 7 };
    debris.size = { .min = 0.06f, .max = 0.15f };
    debris.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
    debris.spin = { .min = -4, .max = 4 };
    debris.gravity_scale = 1;
    debris.size_over_life.values = { 1, 1, 1, 1, 1, 0.8f, 0.4f, 0 };
    demo.emitters[2] = demo.scene.add_particle_system(debris, name: "debris")!;
    demo.emitters[2].local.position = { 3, 0.2f, 0 };

    if (options.embers) {
        ParticleSystemDesc embers = particle::default_particle_system_desc();
        embers.capacity = EMBER_CAPACITY;
        embers.seed = 5;
        embers.material = demo.embers_material;
        embers.shape = CONE;
        embers.radius = 0.25f;
        embers.cone_angle = 0.35f;
        embers.rate = 450;
        embers.lifetime = { .min = 3, .max = 6 };
        embers.speed = { .min = 0.6f, .max = 1.6f };
        embers.size = { .min = 0.03f, .max = 0.07f };
        embers.gravity_scale = -0.25f;
        embers.drag = 1.2f;
        embers.color_min = { 1, 0.4f, 0.1f, 0.5f };
        embers.color_max = { 1, 0.8f, 0.3f, 1 };
        embers.turbulence = ember_turbulence();
        float[8] glow = { 0, 1, 1, 0.9f, 0.7f, 0.5f, 0.25f, 0 };
        foreach (index, alpha : glow) embers.color_over_life.values[index] = { 1, 1, 1, alpha };
        demo.embers = demo.scene.add_particle_system(embers, name: "embers")!;
        demo.embers.local.position = EMBER_POSITION;
    }

    demo.cameras[0] = demo.scene.add_camera(camera::perspective_deg(55, 0.1f, 100))!;
    demo.cameras[1] = demo.scene.add_camera(camera::perspective_deg(55, 0.1f, 100))!;
    demo.cameras[0].local.position = options.lit_smoke ? LIT_CAMERA_POSITIONS[0] : (Vec3){ 10, 7, 17 };
    demo.cameras[1].local.position = options.lit_smoke ? LIT_CAMERA_POSITIONS[1] : (Vec3){ -14, 6, 6 };
    demo.scene.update_world();
    foreach (camera : demo.cameras) camera.look_at(options.lit_smoke ? LIT_CAMERA_FOCUS : (Vec3){ 0, 3, 0 });
    demo.scene.update_world();
    return demo;
}

fn bool cast_physics(
    void* context,
    Vec3 from,
    Vec3 to,
    float radius,
    ParticleHit* out,
) @local {
    PhysicsWorld* physics = context;
    Vec3 path = to - from;
    float length = path.length();
    RayHit? hit = physics.raycast(from, path / length, length);
    if (catch hit) return false;

    *out = { .point = hit.point, .normal = hit.normal, .fraction = hit.fraction };
    return true;
}

fn void? add_obstacle(
    Demo* demo,
    Vec3 size,
    Vec3 position,
    MaterialId material,
) @local {
    GeometryId geometry;
    @pool() {
        Geometry shape = geometry::box(
            allocator: tmem,
            width: size.x,
            height: size.y,
            depth: size.z,
        );
        geometry = demo.assets.add_geometry(&shape)!;
    };
    Node* node = demo.scene.add_mesh(geometry, material, name: "obstacle")!;
    node.local.position = position;
    demo.scene.update_world();

    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = size * 0.5f;
    demo.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!;
}

fn void? add_collision_world(Demo* demo) @local {
    physics::register_physics(&demo.scene)!;
    demo.physics = physics::create_physics_world(
        allocator: mem,
        assets: &demo.assets,
        scene: &demo.scene,
        desc: physics::default_physics_desc(),
    )!;
    demo.has_physics = true;

    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.35f, 0.4f, 0.5f, 1 };
    surface.metallic = 0;
    surface.roughness = 0.6f;
    MaterialId material = demo.assets.add_material(material::standard(surface))!;
    add_obstacle(
        demo: demo,
        size: CANOPY_SIZE,
        position: CANOPY_POSITION,
        material: material,
    )!;
    foreach (position : CRATE_POSITIONS) {
        add_obstacle(
            demo: demo,
            size: CRATE_SIZE,
            position: position,
            material: material,
        )!;
    }
    demo.scene.get(demo.emitters[1], ParticleSystem).set_collision(&cast_physics, &demo.physics);
}

fn void advance_physics(Demo* demo, float dt) @local {
    if (demo.has_physics) demo.physics.update(dt);
}

fn void set_emission(Demo* demo, bool active) @local {
    foreach (index, emitter : demo.emitters) {
        ParticleSystem* system = demo.scene.get(emitter, ParticleSystem);
        system.emitting = active && (!demo.lit_smoke || index == 0);
    }
    if (demo.embers) demo.scene.get(demo.embers, ParticleSystem).emitting = active;
}

fn void report_metrics(String segment, Metrics totals, uint frames) @local {
    io::printfn("%s,update_ms,%.6f", segment, totals.update_ms / frames);
    io::printfn("%s,frame_cpu_ms,%.6f", segment, totals.frame_ms / frames);
    io::printfn("%s,alive_smoke,%.1f", segment, totals.alive[0] / frames);
    io::printfn("%s,alive_sparks,%.1f", segment, totals.alive[1] / frames);
    io::printfn("%s,alive_debris,%.1f", segment, totals.alive[2] / frames);
    io::printfn("%s,upload_bytes,%.1f", segment, (double)totals.upload_bytes / frames);
    io::printfn("%s,gpu_samples,%d", segment, totals.gpu_samples);
    if (totals.gpu_samples) {
        if (totals.sorted) {
            io::printfn("%s,gpu_sort_ms,%.6f", segment, totals.gpu_sort_ms / totals.gpu_samples);
        } else {
            io::printfn("%s,gpu_sort_ms,not_recorded", segment);
        }
        if (totals.transparent) {
            io::printfn("%s,gpu_transparent_ms,%.6f", segment, totals.gpu_transparent_ms / totals.gpu_samples);
        } else {
            io::printfn("%s,gpu_transparent_ms,not_recorded", segment);
        }
    } else {
        io::printfn("%s,gpu_sort_ms,unavailable", segment);
        io::printfn("%s,gpu_transparent_ms,unavailable", segment);
    }
}

fn void? report_batch_costs(
    Demo* demo,
    Renderer* renderer,
    String segment,
    uint frames,
) @local {
    Node* child = demo.scene.node(demo.scene.get(demo.emitters[1], ParticleSystem).draw_node);
    BillboardBatch* batch = demo.scene.get(child, BillboardBatch);
    BillboardGpu[] records = mem::new_array(BillboardGpu, batch.capacity());
    defer free(records);
    double bounds_ms;
    double copy_ms;
    for (uint frame = 0; frame < frames; frame++) {
        demo.scene.mark_billboards_dirty(child);
        time::Clock started = clock::now();
        spatial::billboard_world_bounds(child, batch, renderer.frame_origin);
        bounds_ms += elapsed_ms(started);
        started = clock::now();
        render::copy_billboard_records(records, batch, renderer.frame_origin);
        copy_ms += elapsed_ms(started);
    }
    io::printfn("%s,sparks_live,%d", segment, batch.count);
    io::printfn("%s,sparks_bounds_ms,%.6f", segment, bounds_ms / frames);
    io::printfn("%s,sparks_copy_ms,%.6f", segment, copy_ms / frames);
}

fn void? run_benchmark(Options options) @local {
    Demo demo = create_demo(options)!;
    defer destroy_demo(&demo);
    if (options.collide) add_collision_world(&demo)!;
    Renderer renderer = render::create_renderer(mem, &demo.assets, { .validation = true, .gpu_timings = true })!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(WIDTH, HEIGHT, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(&renderer, desc)!;
    ViewId second_view;
    if (options.views > 1) {
        RenderTargetId second_target = render::create_render_target(
            renderer: &renderer,
            desc: render::render_target_desc(WIDTH, HEIGHT, PixelFormat.RGBA8_SRGB),
        )!;
        ViewDesc second_desc = render::texture_view_desc(second_target, OutputMode.DISPLAY_LDR);
        second_desc.post.anti_aliasing = AntiAliasing.NONE;
        second_view = render::create_view(&renderer, second_desc)!;
    }
    io::printfn("adapter,%s", renderer.adapter_name);
    io::printfn("resolution,%dx%d", WIDTH, HEIGHT);
    io::printfn("frames,%d", options.frames);
    io::printn("validation,on");
    io::printfn("views,%d", options.views);
    io::printfn("spark_capacity,%d", options.capacity);
    io::printfn("execution,%s", options.workers ? "workers" : "inline");
    io::printfn("workers,%d", options.workers);
    uint segments = 2;
    if (options.lit_smoke) segments = options.single_lighting ? 1 : LIT_BENCHMARK_LIGHTING.len;
    for (uint segment = 0; segment < segments; segment++) {
        bool active = options.lit_smoke || segment != 0;
        if (options.lit_smoke) {
            demo.smoke_params.lighting = options.single_lighting ? options.lighting : LIT_BENCHMARK_LIGHTING[segment];
            apply_smoke_params(&demo)!;
        }
        set_emission(&demo, active);
        if (active) {
            for (uint step = 0; step < PREWARM_STEPS; step++) {
                advance_physics(&demo, STEP_SECONDS);
                particle::update(&demo.scene, STEP_SECONDS, { 0.4f, 0, 0 }, demo.workers.parallel());
            }
        }
        Metrics totals;
        ulong first_measured = renderer.frame_index + WARMUP_FRAMES;
        ulong last_measured = first_measured + options.frames;
        ulong last_gpu_frame = ulong::max;
        ulong total_frames = (ulong)WARMUP_FRAMES + options.frames + render::FRAMES_IN_FLIGHT + 1;
        for (ulong frame = 0; frame < total_frames; frame++) {
            time::Clock frame_start = clock::now();
            advance_physics(&demo, STEP_SECONDS);
            orbit_lamp(&demo, (double)renderer.frame_index * STEP_SECONDS);
            demo.scene.update_world();
            time::Clock update_start = clock::now();
            particle::update(&demo.scene, STEP_SECONDS, { 0.4f, 0, 0 }, demo.workers.parallel());
            double update_ms = elapsed_ms(update_start);
            renderer.begin_frame({ .time = (double)renderer.frame_index * STEP_SECONDS, .delta = STEP_SECONDS })!;
            defer catch render::abort_frame(&renderer);
            renderer.render_view(&demo.scene, demo.cameras[0], view)!;
            renderer.finish_view(view)!;
            if (options.views > 1) {
                renderer.render_view(&demo.scene, demo.cameras[1], second_view)!;
                renderer.finish_view(second_view)!;
            }
            renderer.end_frame()!;
            if (frame >= WARMUP_FRAMES && frame < (ulong)WARMUP_FRAMES + options.frames) {
                totals.update_ms += update_ms;
                totals.frame_ms += elapsed_ms(frame_start);
                totals.upload_bytes += renderer.stats.upload_bytes;
                foreach (index, emitter : demo.emitters) {
                    totals.alive[index] += demo.scene.get(emitter, ParticleSystem).alive;
                }
            }
            Stats* stats = &renderer.stats;
            if (stats.gpu_timing_state == GpuTimingState.READY && stats.gpu_frame_index != last_gpu_frame
                && stats.gpu_frame_index >= first_measured && stats.gpu_frame_index < last_measured) {
                totals.gpu_samples++;
                totals.gpu_sort_ms += stats.gpu_pass_ms[Pass.INSTANCE_SORT.ordinal];
                totals.gpu_transparent_ms += stats.gpu_pass_ms[Pass.FORWARD_TRANSPARENT.ordinal];
                totals.sorted = totals.sorted || stats.gpu_pass_valid[Pass.INSTANCE_SORT.ordinal];
                totals.transparent = totals.transparent || stats.gpu_pass_valid[Pass.FORWARD_TRANSPARENT.ordinal];
                last_gpu_frame = stats.gpu_frame_index;
            }
        }
        String name = segment ? "active" : "empty";
        if (options.lit_smoke) name = LIGHTING_NAMES[demo.smoke_params.lighting.ordinal].str_view();
        report_metrics(name, totals, options.frames);
        if (active) {
            report_batch_costs(
                demo: &demo,
                renderer: &renderer,
                segment: name,
                frames: options.frames,
            )!;
        }
    }
    if (options.collide) {
        io::printfn("sparks,collision_skips,%d", demo.scene.get(demo.emitters[1], ParticleSystem).collision_skips);
    }
    if (demo.embers) io::printfn("embers,alive,%d", demo.scene.get(demo.embers, ParticleSystem).alive);
    if (demo.spark_puffs) {
        ParticleSystem* sparks = demo.scene.get(demo.emitters[1], ParticleSystem);
        io::printfn("spark_smoke,alive,%d", demo.scene.get(demo.spark_puffs, ParticleSystem).alive);
        io::printfn("sparks,dropped_events,%d", sparks.dropped_events);
        io::printfn("sparks,skipped_events,%d", sparks.skipped_events);
    }
    if (options.capture_rgba.len) {
        char[] pixels = mem::new_array(char, WIDTH * HEIGHT * SPRITE_CHANNELS);
        defer free(pixels);
        renderer.read_render_target(target, pixels)!;
        file::save(options.capture_rgba, pixels)!;
    }
    return renderer.log.check_validation();
}

fn void? run_stress(
    uint frames,
    ParticleSaturation saturation,
    bool turbulent,
    bool trailed,
    uint worker_count,
) @local {
    Workers workers;
    create_workers(&workers, worker_count)!;
    defer destroy_workers(&workers);
    run_stress_segment(
        segment: "stress",
        frames: frames,
        saturation: saturation,
        rate: 0,
        turbulent: turbulent,
        trailed: trailed,
        workers: &workers,
    )!;
    run_stress_segment(
        segment: "saturated",
        frames: frames,
        saturation: saturation,
        rate: STRESS_CAPACITY * SATURATED_REQUEST_FRACTION / STEP_SECONDS,
        turbulent: turbulent,
        trailed: trailed,
        workers: &workers,
    )!;
}

fn void? run_stress_segment(
    String segment,
    uint frames,
    ParticleSaturation saturation,
    float rate,
    bool turbulent,
    bool trailed,
    Workers* workers,
) @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 3 });
    defer scene::destroy_scene(&scene);
    particle::register_particles(&scene)!;
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = STRESS_CAPACITY;
    desc.saturation = saturation;
    desc.rate = rate;
    desc.render_mode = STRETCHED;
    desc.shape = CONE;
    desc.radius = 1;
    desc.cone_angle = 0.5f;
    desc.lifetime.min = (float)(((double)frames + WARMUP_FRAMES + 1) * STEP_SECONDS + 1);
    desc.lifetime.max = desc.lifetime.min;
    desc.speed = { .min = 1, .max = 3 };
    desc.size = { .min = 0.1f, .max = 0.2f };
    desc.spin = { .min = -1, .max = 1 };
    desc.gravity_scale = 0.1f;
    desc.drag = 0.2f;
    desc.stretch = 0.1f;
    desc.size_over_life.values = { 1, 1.1f, 1.2f, 1.3f, 1.4f, 1.5f, 1.6f, 1.7f };
    if (turbulent) desc.turbulence = ember_turbulence();
    if (trailed) desc.trail = spark_trail({});
    Node* emitter = scene.add_particle_system(desc)!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(STRESS_CAPACITY);
    scene.update_world();
    particle::update(&scene, 0, {}, workers.parallel());
    Node* child = scene.node(system.draw_node);
    BillboardBatch* batch = scene.get(child, BillboardBatch);
    BillboardGpu[] records = mem::new_array(BillboardGpu, STRESS_CAPACITY);
    defer free(records);
    Node* trail_node;
    RibbonBatch* ribbons;
    RibbonPointGpu[] ribbon_records;
    if (trailed) {
        trail_node = scene.node(system.trail_node);
        ribbons = scene.get(trail_node, RibbonBatch);
        ribbon_records = mem::new_array(RibbonPointGpu, ribbons.points.len + 1);
    }
    defer free(ribbon_records);
    double update_ms;
    double bounds_ms;
    double pack_ms;
    double ribbon_bounds_ms;
    double ribbon_pack_ms;
    double checksum;
    for (ulong frame = 0; frame < (ulong)WARMUP_FRAMES + frames; frame++) {
        time::Clock started = clock::now();
        particle::update(&scene, STEP_SECONDS, { 0.4f, 0, 0 }, workers.parallel());
        double updated = elapsed_ms(started);
        started = clock::now();
        Aabb bounds = spatial::billboard_world_bounds(child, batch);
        double bounded = elapsed_ms(started);
        started = clock::now();
        render::copy_billboard_records(records, batch, {});
        double packed = elapsed_ms(started);
        checksum += (double)(bounds.max.x + records[frame % STRESS_CAPACITY].position_width.x);
        double ribbon_bounded;
        double ribbon_packed;
        if (trailed) {
            started = clock::now();
            Aabb ribbon_bounds = spatial::ribbon_world_bounds(trail_node, ribbons);
            ribbon_bounded = elapsed_ms(started);
            started = clock::now();
            render::pack_ribbon_records(ribbon_records, trail_node.world, ribbons);
            ribbon_packed = elapsed_ms(started);
            RibbonPointGpu sampled = ribbon_records[frame % (ulong)ribbon_records.len];
            checksum += (double)(ribbon_bounds.max.x + sampled.position_width.x);
        }
        if (frame >= WARMUP_FRAMES) {
            update_ms += updated;
            bounds_ms += bounded;
            pack_ms += packed;
            ribbon_bounds_ms += ribbon_bounded;
            ribbon_pack_ms += ribbon_packed;
        }
    }
    io::printfn("%s,frames,%d", segment, frames);
    io::printfn("%s,workers,%d", segment, workers.count);
    io::printfn("%s,turbulence_octaves,%d", segment, desc.turbulence.strength > 0 ? desc.turbulence.octaves : 0);
    io::printfn("%s,alive,%d", segment, system.alive);
    io::printfn("%s,refused,%d", segment, system.dropped);
    io::printfn("%s,evicted,%d", segment, system.evicted);
    io::printfn("%s,draw_count,%d", segment, batch.count);
    io::printfn("%s,update_ms,%.6f", segment, update_ms / frames);
    io::printfn("%s,billboard_bounds_ms,%.6f", segment, bounds_ms / frames);
    io::printfn("%s,billboard_pack_ms,%.6f", segment, pack_ms / frames);
    io::printfn("%s,trail_points,%d", segment, trailed ? desc.trail.max_points : 0);
    if (trailed) {
        io::printfn("%s,trail_draw_count,%d", segment, ribbons.count);
        io::printfn("%s,ribbon_bounds_ms,%.6f", segment, ribbon_bounds_ms / frames);
        io::printfn("%s,ribbon_pack_ms,%.6f", segment, ribbon_pack_ms / frames);
    }
    io::printfn("%s,checksum,%.6f", segment, checksum);
}

fn void? configure_split(Renderer* renderer, ViewId second, bool split) @local {
    if (!renderer.output_width || !renderer.output_height) return;
    uint width = math::max(renderer.output_width, 1u);
    uint height = math::max(renderer.output_height, 1u);
    ViewDesc first = render::default_view_desc();
    first.post.anti_aliasing = AntiAliasing.NONE;
    first.viewport = { .width = split ? math::max(width / 2, 1u) : width, .height = height };
    render::configure_view(renderer, renderer.default_view, first)!;
    ViewDesc next = render::default_view_desc();
    next.post.anti_aliasing = AntiAliasing.NONE;
    next.viewport = { .x = width / 2, .width = width - width / 2, .height = height };
    return render::configure_view(renderer, second, next);
}

fn void? controls(
    Demo* demo,
    bool* split,
    float* wind,
    double update_ms,
) @local {
    if (imgui::begin("Particles", null, {})) {
        imgui::text("CPU update: %.3f ms", update_ms);
        imgui::checkbox("Second camera", split);
        imgui::slider_float(
            label: "Wind",
            v: wind,
            v_min: -2,
            v_max: 2,
        );
        foreach (index, emitter : demo.emitters) {
            ParticleSystem* system = demo.scene.get(emitter, ParticleSystem);
            imgui::push_id_int((int)index);
            imgui::text("%s", EFFECT_NAMES[index]);
            imgui::checkbox("Emitting", &system.emitting);
            if (imgui::button("Burst")) system.emit_burst(128);
            imgui::text("Alive: %u", system.alive);
            imgui::text("Dropped: %llu", system.dropped);
            imgui::pop_id();
        }
        if (demo.has_physics) {
            imgui::text("Collision skips: %llu", demo.scene.get(demo.emitters[1], ParticleSystem).collision_skips);
        }
        if (demo.embers) {
            ParticleSystem* embers = demo.scene.get(demo.embers, ParticleSystem);
            imgui::checkbox("Embers emitting", &embers.emitting);
            imgui::text("Embers alive: %u", embers.alive);
        }
        if (demo.spark_puffs) {
            ParticleSystem* sparks = demo.scene.get(demo.emitters[1], ParticleSystem);
            imgui::text("Spark smoke alive: %u", demo.scene.get(demo.spark_puffs, ParticleSystem).alive);
            imgui::text("Dropped events: %llu", sparks.dropped_events);
            imgui::text("Skipped events: %llu", sparks.skipped_events);
        }
        bool material_changed = imgui::slider_float(
            label: "Soft distance",
            v: &demo.smoke_params.soft_distance,
            v_min: 0,
            v_max: 1,
        );
        if (demo.lit_smoke) {
            imgui::text("Lighting (L): %s", LIGHTING_NAMES[demo.smoke_params.lighting.ordinal]);
            imgui::text("Normal (N): %s", NORMAL_NAMES[demo.smoke_params.normal.ordinal]);
            material_changed |= imgui::slider_float(
                label: "Anisotropy",
                v: &demo.smoke_params.anisotropy,
                v_min: -MAX_SMOKE_ANISOTROPY,
                v_max: MAX_SMOKE_ANISOTROPY,
            );
        } else {
            bool ambient = demo.smoke_params.lighting == ParticleLighting.AMBIENT;
            material_changed |= imgui::checkbox("Ambient smoke", &ambient);
            demo.smoke_params.lighting = ambient ? ParticleLighting.AMBIENT : ParticleLighting.UNLIT;
        }
        if (material_changed) apply_smoke_params(demo)!;
        Material* sparks = &demo.assets.material(demo.sparks).data;
        bool additive = sparks.common.blend_mode == BlendMode.ADDITIVE;
        if (imgui::checkbox("Additive sparks", &additive)) {
            sparks.common.blend_mode = additive ? BlendMode.ADDITIVE : BlendMode.PREMULTIPLIED_ALPHA;
            demo.assets.mark_material_dirty(demo.sparks);
        }
    }
    imgui::end();
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d particles", WIDTH, HEIGHT))!;
    defer platform::destroy_window(&window);
    Demo demo = create_demo(options)!;
    defer destroy_demo(&demo);
    if (options.collide) add_collision_world(&demo)!;
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .gpu_timings = true },
    )!;
    defer render::destroy_renderer(&renderer);
    ViewId second = render::create_view(&renderer, render::default_view_desc())!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    set_emission(&demo, true);
    bool split = true;
    bool previous_split;
    uint previous_width;
    uint previous_height;
    float wind = 0.4f;
    double update_ms;
    double elapsed;
    uint frame;
    while (window.poll()) {
        if (options.limit_frames && frame++ >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE) && !window.input.keyboard_captured_by_gui) break;
        @pool() {
            gui_renderer.new_frame();
            defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
            controls(
                demo: &demo,
                split: &split,
                wind: &wind,
                update_ms: update_ms,
            )!;
            gui_renderer.finish_frame();
            platform::sync_window(&window, &renderer);
            if (renderer.output_width != previous_width || renderer.output_height != previous_height
                || split != previous_split) {
                configure_split(&renderer, second, split)!;
                previous_split = split;
                previous_width = renderer.output_width;
                previous_height = renderer.output_height;
            }
            if (demo.lit_smoke && !window.input.keyboard_captured_by_gui) cycle_smoke_look(&demo, &window.input)!;
            advance_physics(&demo, window.clock.delta);
            orbit_lamp(&demo, elapsed);
            demo.scene.update_world();
            time::Clock started = clock::now();
            particle::update(&demo.scene, window.clock.delta, { wind, 0, 0 }, demo.workers.parallel());
            update_ms = elapsed_ms(started);
            elapsed += window.clock.delta;
            renderer.begin_frame({ .time = elapsed, .delta = window.clock.delta })!;
            defer catch render::abort_frame(&renderer);
            if (renderer.has_output) {
                renderer.render_view(&demo.scene, demo.cameras[0], renderer.default_view)!;
                renderer.finish_view(renderer.default_view)!;
                if (split) {
                    renderer.render_view(&demo.scene, demo.cameras[1], second)!;
                    renderer.finish_view(second)!;
                }
                OverlayContext overlay = renderer.begin_overlay()!;
                gui_renderer.record(&overlay)!;
                renderer.end_overlay(&overlay)!;
            }
            renderer.end_frame()!;
        };
    }
    return renderer.log.check_validation();
}

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn ParticleLighting? parse_lighting(String name) @local {
    foreach (index, label : LIGHTING_NAMES) {
        if (label.str_view() == name) return ParticleLighting::from_ordinal(index);
    }
    return c3d::INVALID_ARGUMENT~;
}

fn ParticleNormal? parse_normal(String name) @local {
    foreach (index, label : NORMAL_NAMES) {
        if (label.str_view() == name) return ParticleNormal::from_ordinal(index);
    }
    return c3d::INVALID_ARGUMENT~;
}

fn Options? parse_options(String[] args) @local {
    Options options = {
        .frames = DEFAULT_BENCHMARK_FRAMES,
        .views = 1,
        .capacity = SPARK_CAPACITY,
        .lighting = ParticleLighting.DIRECT_SHADOWED,
        .normal = ParticleNormal.SPHERICAL,
    };
    for (usz index = 1; index < args.len; index++) {
        switch (args[index]) {
            case "--benchmark": options.benchmark = true;
            case "--stress": options.stress = true;
            case "--sparks": options.sparks = true;
            case "--smoke": options.smoke = true;
            case "--embers": options.embers = true;
            case "--trails": options.trails = true;
            case "--lit-smoke": options.lit_smoke = true;
            case "--lighting":
                options.lighting = parse_lighting(option_value(args, &index)!)!;
                options.single_lighting = true;
            case "--normal": options.normal = parse_normal(option_value(args, &index)!)!;
            case "--debris-shadows": options.debris_shadows = true;
            case "--collide": options.collide = true;
            case "--drop-oldest": options.drop_oldest = true;
            case "--frames":
                options.frames = option_value(args, &index)!.to_uint()!;
                options.limit_frames = true;
            case "--capture-rgba": options.capture_rgba = option_value(args, &index)!;
            case "--workers": options.workers = option_value(args, &index)!.to_uint()!;
            case "--views": options.views = option_value(args, &index)!.to_uint()!;
            case "--capacity": options.capacity = option_value(args, &index)!.to_uint()!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    bool scene_effect = options.sparks || options.smoke || options.collide || options.lit_smoke
        || options.debris_shadows;
    bool lit_option = options.single_lighting || options.normal != ParticleNormal.SPHERICAL;
    if (!options.frames || (options.stress && options.benchmark) || (scene_effect && options.stress)
        || (options.lit_smoke && (options.sparks || options.smoke || options.embers || options.trails
            || options.collide || options.debris_shadows))
        || (lit_option && !options.lit_smoke) || (options.drop_oldest && !options.stress)
        || (options.capture_rgba.len && !options.benchmark)
        || !options.views || options.views > MAX_VIEWS || !options.capacity
        || ((options.views > 1 || options.capacity != SPARK_CAPACITY) && !options.benchmark)) {
        return c3d::INVALID_ARGUMENT~;
    }
    return options;
}

<*
 Display smoke, sparks, debris and embers or measure their rendering.
*>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        io::eprintfn("Invalid options: %s", excuse);
        io::eprintn("Use [--benchmark [--views 1|2] [--capacity sparks] | --stress [--drop-oldest]] [--sparks]");
        io::eprintn("    [--smoke] [--embers] [--trails] [--collide] [--debris-shadows]");
        io::eprintn("    [--lit-smoke [--lighting name] [--normal name]] [--workers count]");
        io::eprintn("    [--frames count] [--capture-rgba path].");
        return 1;
    }
    Options options = parsed;
    ParticleSaturation saturation = options.drop_oldest ? ParticleSaturation.DROP_OLDEST : ParticleSaturation.REFUSE;
    if (catch excuse = (options.stress
        ? run_stress(options.frames, saturation, options.embers, options.trails, options.workers)
        : options.benchmark ? run_benchmark(options) : run_interactive(options))) {
        io::eprintfn("Particles failed: %s", excuse);
        return 1;
    }
    return 0;
}
