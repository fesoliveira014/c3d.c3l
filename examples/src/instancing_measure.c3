module instancing_measure;

import std::io;
import std::io::file;
import std::math;
import std::sort;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::profile;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;

const String PULSE_VERTEX_FILE @local = "../shaders/custom/pulse.vert.glsl";
const String PULSE_FRAGMENT_FILE @local = "../shaders/custom/pulse.frag.glsl";
const uint GRID_SIDE @local = 316; // 99,856 props in one batch; the instance-count lever of the example
const float GRID_SPACING @local = 0.5f;
const float PROP_SIZE @local = 0.3f;
const uint PULSE_COUNT @local = 8;
const float PULSE_RING_RADIUS @local = 5;
const float PULSE_RADIUS @local = 0.5f;
const float PULSE_HEIGHT @local = 0.8f;
const float PULSE_AMPLITUDE @local = 0.4f;
const float PULSE_ANGULAR_FREQUENCY @local = 3;
const float TRIO_HEIGHT @local = 1.5f;
const float TRIO_SPACING @local = 1.8f;
const float TRIO_SPIN_RADIANS_PER_SECOND @local = 0.8f;
const float BOB_HEIGHT @local = 0.8f;
const float BOB_RADIANS_PER_SECOND @local = 2;
const Vec3 CAMERA_TARGET @local = { 0, 1, 4 }; // the instancing example's initial orbit
const float CAMERA_DISTANCE @local = 14;
const float CAMERA_PITCH @local = 0.45f;
const uint MEASURE_WIDTH @local = 1920;
const uint MEASURE_HEIGHT @local = 1080;
const uint MEASURE_WARMUP_FRAMES @local = 120; // pipelines built, records uploaded, history valid
const usz MEASURE_FRAMES @local = 1200; // captured frames per run
const String RESOLVE_SCOPE @local = "view.resolve";
const String CONFIGURATION @local = "after";

struct PulseParams @local {
    Vec4 color;
    Vec4 motion;
}

struct Batches @local {
    Node* trio;
    Node* props;
    Node* pulses;
}

fn char[]? compile_file(Allocator allocator, String path, ShaderStage stage, String[] defines = {}) @local {
    String source = (String)file::load(tmem, path)!;
    String log;
    char[]? spirv = compile::compile_glsl(
        allocator:  allocator,
        source:     source,
        stage:      stage,
        defines:    defines,
        debug_name: path,
        log:        &log,
    );
    if (log.len) io::printfn("%s", log);
    return spirv;
}

fn ShaderDesc? compile_pulse(Allocator allocator) @local {
    String[2] depth_instanced = { "DEPTH_ONLY", "INSTANCED" };
    String[2] velocity_instanced = { "VELOCITY", "INSTANCED" };
    return {
        .fragment = compile_file(allocator, PULSE_FRAGMENT_FILE, ShaderStage.FRAGMENT)!,
        .vertex   = {
            .shaded           = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX)!,
            .depth            = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX, { "DEPTH_ONLY" })!,
            .instanced_shaded = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX, { "INSTANCED" })!,
            .instanced_depth  = compile_file(allocator, PULSE_VERTEX_FILE, ShaderStage.VERTEX, depth_instanced[..])!,
            .velocity         = compile_file(
                allocator: allocator,
                path:      PULSE_VERTEX_FILE,
                stage:     ShaderStage.VERTEX,
                defines:   { "VELOCITY" },
            )!,
            .instanced_velocity = compile_file(
                allocator: allocator,
                path:      PULSE_VERTEX_FILE,
                stage:     ShaderStage.VERTEX,
                defines:   velocity_instanced[..],
            )!,
        },
        .param_block_size = PulseParams::size,
    };
}

fn Node*? add_trio(Scene* scene, GeometryId cube, MaterialId white) @local {
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[0].position = { -TRIO_SPACING, 0, 0 };
    transforms[2].position = { TRIO_SPACING, 0, 0 };
    transforms[2].scale = { -1, 1, 1 };
    Vec4[3] colors = { { 1, 0.2f, 0.2f, 1 }, { 0.2f, 1, 0.2f, 1 }, { 0.2f, 0.4f, 1, 1 } };
    Node* node = scene.add_instanced_mesh(
        geometry:   cube,
        material:   white,
        capacity:   3,
        transforms: transforms[..],
        colors:     colors[..],
        name:       "trio",
    )!;
    node.local.position = { 0, TRIO_HEIGHT, 0 };
    return node;
}

fn Node*? add_props(Scene* scene, GeometryId prop, MaterialId white) @local {
    uint count = GRID_SIDE * GRID_SIDE;
    Node* node = scene.add_instanced_mesh(prop, white, count, name: "props")!;
    scene.resize_instances(node, count)!;
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    float half_extent = (GRID_SIDE - 1) * GRID_SPACING * 0.5f;
    for (uint row = 0; row < GRID_SIDE; row++) {
        for (uint column = 0; column < GRID_SIDE; column++) {
            uint index = row * GRID_SIDE + column;
            float u = (float)column / (GRID_SIDE - 1);
            float v = (float)row / (GRID_SIDE - 1);
            batch.transforms[index].position = { column * GRID_SPACING - half_extent, 0, row * GRID_SPACING - half_extent };
            batch.transforms[index].rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (u + v) * (float)math::PI);
            batch.colors[index] = { u, 0.4f, v, 1 };
        }
    }
    node.local.position = { 0, PROP_SIZE * 0.5f, 12 };
    return node;
}

fn Node*? add_pulses(Scene* scene, GeometryId sphere, MaterialId pulse_material) @local {
    Transform[PULSE_COUNT] transforms;
    Vec4[PULSE_COUNT] colors;
    for (uint index = 0; index < PULSE_COUNT; index++) {
        float angle = (float)index / PULSE_COUNT * 2 * (float)math::PI;
        transforms[index] = maths::TRANSFORM_IDENTITY;
        transforms[index].position = {
            math::cos(angle) * PULSE_RING_RADIUS,
            PULSE_HEIGHT,
            math::sin(angle) * PULSE_RING_RADIUS,
        };
        colors[index] = { 0.5f + 0.5f * math::cos(angle), 1, 0.5f + 0.5f * math::sin(angle), 1 };
    }
    Node* node = scene.add_instanced_mesh(
        geometry:   sphere,
        material:   pulse_material,
        capacity:   PULSE_COUNT,
        transforms: transforms[..],
        colors:     colors[..],
        name:       "pulses",
    )!;
    // The vertex stage moves each sphere by up to PULSE_AMPLITUDE; the geometry bound does not cover that.
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    float reach = PULSE_RING_RADIUS + PULSE_RADIUS;
    float rise = PULSE_RADIUS + PULSE_AMPLITUDE;
    batch.has_bounds_override = true;
    batch.local_bounds = {
        .min = { -reach, PULSE_HEIGHT - rise, -reach },
        .max = { reach, PULSE_HEIGHT + rise, reach },
    };
    return node;
}

fn Batches? build_scene(AssetStore* assets, Scene* scene, ShaderId pulse_shader) @local {
    GeometryId ground;
    GeometryId cube;
    GeometryId prop;
    GeometryId sphere;
    @pool() {
        Geometry ground_geometry = geometry::plane(tmem, 60, 60);
        ground = assets.add_geometry(&ground_geometry, "instancing/ground")!;
        Geometry cube_geometry = geometry::box(tmem, 1, 1, 1);
        cube = assets.add_geometry(&cube_geometry, "instancing/cube")!;
        Geometry prop_geometry = geometry::box(tmem, PROP_SIZE, PROP_SIZE, PROP_SIZE);
        prop = assets.add_geometry(&prop_geometry, "instancing/prop")!;
        Geometry sphere_geometry = geometry::sphere(tmem, PULSE_RADIUS);
        sphere = assets.add_geometry(&sphere_geometry, "instancing/sphere")!;
    };

    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.metallic = 0;
    surface.base_color = { 0.7f, 0.7f, 0.7f, 1 };
    MaterialId ground_material = assets.add_material(material::standard(surface), "instancing/ground_material")!;
    surface.base_color = { 1, 1, 1, 1 };
    surface.roughness = 0.4f;
    MaterialId white = assets.add_material(material::standard(surface), "instancing/white")!;
    PulseParams pulse = {
        .color  = { 1, 1, 1, 1 },
        .motion = { PULSE_AMPLITUDE, PULSE_ANGULAR_FREQUENCY, 0, 0 },
    };
    MaterialId pulse_material = assets.add_material(
        material::custom(pulse_shader, material::@as_bytes(pulse)),
        "instancing/pulse",
    )!;

    scene.add_mesh(ground, ground_material, name: "ground")!;
    Node* sun = scene.add_light(light::directional({ 1, 0.97f, 0.9f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.25f;
    return {
        .trio   = add_trio(scene, cube, white)!,
        .props  = add_props(scene, prop, white)!,
        .pulses = add_pulses(scene, sphere, pulse_material)!,
    };
}

fn void animate(Scene* scene, Batches* batches, double time) @local {
    batches.trio.local.rotation = quaternion::from_axis_angle{float}(
        { 0, 1, 0 },
        (float)time * TRIO_SPIN_RADIANS_PER_SECOND,
    );
    InstancedMesh* trio = scene.get(batches.trio, InstancedMesh);
    trio.transforms[1].position.y = BOB_HEIGHT * (float)math::sin(time * BOB_RADIANS_PER_SECOND);
    scene.mark_instances_dirty(batches.trio);
}

fn Node*? add_measure_camera(Scene* scene) @local {
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!;
    Vec3 offset = { 0, math::sin(CAMERA_PITCH), math::cos(CAMERA_PITCH) };
    camera_node.local.position = CAMERA_TARGET + offset * CAMERA_DISTANCE;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
    return camera_node;
}

fn usz published_stage_bytes(render::Renderer* renderer, ShaderId shader) @local {
    ShaderDesc* desc = &renderer.shaders[shader.index].desc;
    CustomVertex* vertex = &desc.vertex;
    return desc.fragment.len + desc.gbuffer.len + desc.traced_fragment.hardware.len
        + desc.traced_fragment.software.len + vertex.shaded.len + vertex.depth.len + vertex.instanced_shaded.len
        + vertex.instanced_depth.len + vertex.velocity.len + vertex.instanced_velocity.len;
}

fn float median(float[] values) @local {
    if (!values.len) return -1;
    sort::quicksort(values);
    return values[values.len / 2];
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;
    }
    return renderer.end_frame();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    ShaderId pulse_shader,
) @local {
    Batches batches = build_scene(assets, scene, pulse_shader)!;
    Node* camera_node = add_measure_camera(scene)!;
    scene.update_world();
    ViewDesc desc = render::default_view_desc();
    desc.post.motion_blur = true;
    desc.instance_culling = true;
    render::configure_view(renderer, renderer.default_view, desc)!;
    renderer.prepare_scene(scene)!;
    io::printfn("MEASURE published_stage_bytes=%d shader=pulse", published_stage_bytes(renderer, pulse_shader));

    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity        = 4,
        .cpu_scopes_per_frame  = 512,
        .max_depth             = 16,
        .label_bytes_per_frame = 32768,
    })!;
    defer profile::destroy_recorder(&recorder);
    float[] resolve_ms = mem::new_array(float, MEASURE_FRAMES);
    defer free(resolve_ms.ptr);
    usz measured;
    uint frames;
    while (measured < MEASURE_FRAMES && window.poll()) {
        animate(scene, &batches, window.clock.total);
        scene.update_world();
        platform::sync_window(window, renderer);
        FrameInfo info = { .time = window.clock.total, .delta = window.clock.delta };
        ulong frame_id = renderer.frame_index;
        profile::@capture(&recorder, frame_id) {
            draw_frame(
                renderer:    renderer,
                scene:       scene,
                camera_node: camera_node,
                info:        info,
            )!;
        };
        frames++;
        if (frames <= MEASURE_WARMUP_FRAMES) continue;
        if (try capture = recorder.frame(frame_id)) {
            foreach (sample : capture.cpu) {
                if (sample.label != RESOLVE_SCOPE || measured == MEASURE_FRAMES) continue;
                resolve_ms[measured++] = (float)((double)sample.duration_ns / 1e6);
            }
        }
    }
    io::printfn(
        "MEASURE configuration=%s props=%d output=%dx%d frames=%d view_resolve=%.4f",
        CONFIGURATION, GRID_SIDE * GRID_SIDE, renderer.output_width, renderer.output_height, measured,
        median(resolve_ms[:measured]));
}

fn int main() {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    ShaderId pulse_shader;
    @pool() {
        ShaderDesc? pulse_desc = compile_pulse(tmem);
        if (catch excuse = pulse_desc) {
            io::eprintfn("pulse: compile failed (%s); run from examples/build so ../shaders resolves", excuse);
            return 1;
        }
        pulse_shader = assets.add_shader(&pulse_desc, "pulse")!!;
    };

    platform::WindowDesc window_desc = platform::default_window_desc(
        title:  "c3d instancing measure",
        width:  MEASURE_WIDTH,
        height: MEASURE_HEIGHT,
    );
    platform::Window window = platform::create_window(window_desc)!!;
    defer platform::destroy_window(&window);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_instancing_measure" },
    )!!;
    defer render::destroy_renderer(&renderer);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    if (catch excuse = run(
        window:       &window,
        renderer:     &renderer,
        assets:       &assets,
        scene:        &scene,
        pulse_shader: pulse_shader,
    )) {
        io::eprintfn("instancing measure failed: %s", excuse);
        return 1;
    }
    return 0;
}
