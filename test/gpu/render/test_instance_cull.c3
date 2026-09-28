module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import std::io::file;
import std::math;

const uint LINE_COUNT @private = 16;
const uint LINE_CENTER @private = 8; // the instance at x = 0, under the camera
const uint LINE_MIRROR_EVERY @private = 4;
const float LINE_SPACING @private = 0.7f; // survivors end at 1.4; the next instance lies 0.05 outside the side planes
const float LINE_SCALE @private = 0.4f;
const uint SETTLE_FRAMES @private = render::FRAMES_IN_FLIGHT + 1; // the counter of the first frame reads back here
const uint VIEW_CULLING_PASSES @private = 2; // depth prepass and view
const uint CROWD_COUNT @private = 8;
const uint CROWD_TARGET @private = 5; // the walker at x = 0 keeps the rest pose
const uint CROWD_EDGE @private = 7; // placed outside the view; its pose reaches back in
const float CROWD_PART_SIZE @private = 0.5f;
const Vec3 CROWD_POSE_OFFSET @private = { -1, 1, 0 };
const Vec2 CROWD_EDGE_UV @private = { 0.919f, 0.211f }; // the edge walker's posed box at (1.45, 1, 0)
const float LINE_STEP @private = 0.05f;
const usz OVERFLOW_ARENA_BYTES @private = 96; // counter, two indirect commands and one 4-instance list
const String PULSE_VERTEX @private = "../../../examples/shaders/custom/pulse.vert.glsl";
const String PULSE_FRAGMENT @private = "../../../examples/shaders/custom/pulse.frag.glsl";

struct PulseBlock @private {
    Vec4 color;
    Vec4 motion;
}

fn Node*? add_line_batch(Scene* scene, GeometryId geometry, MaterialId material) @private {
    Transform[LINE_COUNT] transforms;
    foreach (uint index, &transform : transforms) {
        float mirror = index % LINE_MIRROR_EVERY == LINE_MIRROR_EVERY - 1 ? -1 : 1;
        *transform = {
            .position = { ((float)index - LINE_CENTER) * LINE_SPACING, 0, 0 },
            .rotation = maths::TRANSFORM_IDENTITY.rotation,
            .scale    = { mirror * LINE_SCALE, LINE_SCALE, LINE_SCALE },
        };
    }
    return scene.add_instanced_mesh(
        geometry:   geometry,
        material:   material,
        capacity:   LINE_COUNT,
        transforms: transforms[..],
    );
}

fn DeformedScene? create_line_scene(Fixture* fixture, MaterialId material, bool sunlit = false) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.mesh = add_line_batch(&result.scene, fixture.box, material)!;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    if (sunlit) {
        Light sunlight = light::directional({ 1, 1, 1 }, 2);
        sunlight.shadow.cascades = 1;
        sunlight.shadow.max_distance = 10;
        result.scene.add_light(sunlight)!;
    }
    result.scene.update_world();
    return result;
}

fn uint line_survivors(Fixture* fixture, DeformedScene* target) @private {
    Camera* camera = target.scene.get(target.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, target.camera.world, { TARGET_SIZE, TARGET_SIZE });
    InstancedMesh* batch = target.scene.get(target.mesh, InstancedMesh);
    Aabb local = fixture.assets.geometry(fixture.box).data.bounds;
    uint survivors;
    foreach (transform : batch.transforms[:batch.count]) {
        Mat4 model = target.mesh.world.mul(transform.to_mat4());
        if (render::instance_visible(&matrices.frustum, local, model)) survivors++;
    }
    return survivors;
}

fn void? set_view_culling(Fixture* fixture, bool culling) @private {
    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.instance_culling = culling;
    return render::configure_view(&fixture.renderer, fixture.view, desc);
}

fn uint? render_scene_and_sample(Fixture* fixture, DeformedScene* target, Vec2 uv = CENTER_UV) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, target.camera, fixture.view)!;
    sample(fixture, render::read_view_color(fixture.view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn uint? settle_and_sample(Fixture* fixture, DeformedScene* target, Vec2 uv = CENTER_UV) @private {
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) pixel = render_scene_and_sample(fixture, target, uv)!;
    return pixel;
}

fn void test_culled_batch_draws_only_survivors() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&line.scene);
    uint survivors = line_survivors(&fixture, &line);
    assert(survivors > 0 && survivors < LINE_COUNT);

    uint culled_pixel = settle_and_sample(&fixture, &line)!!;
    assert(renderer.stats.instances_tested == VIEW_CULLING_PASSES * LINE_COUNT);
    assert(renderer.stats.instances_visible == VIEW_CULLING_PASSES * survivors);
    check_opaque_color(culled_pixel);

    set_view_culling(&fixture, false)!!;
    uint unculled_pixel = settle_and_sample(&fixture, &line)!!;
    assert(unculled_pixel == culled_pixel);
    assert(renderer.stats.cull_dispatches == 0 && renderer.stats.instances_tested == 0);

    DeformedScene shadowed = create_line_scene(&fixture, fixture.plain, sunlit: true)!!;
    defer scene::destroy_scene(&shadowed.scene);
    uint shadowed_unculled = settle_and_sample(&fixture, &shadowed)!!;
    set_view_culling(&fixture, true)!!;
    uint shadowed_culled = settle_and_sample(&fixture, &shadowed)!!;
    assert(shadowed_culled == shadowed_unculled);
    assert(renderer.stats.instances_visible <= renderer.stats.instances_tested);
    assert(renderer.stats.instances_tested > VIEW_CULLING_PASSES * LINE_COUNT);
    check_validation(renderer);
}

fn void test_cull_overflow_draws_unculled() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, instance_cull_bytes: OVERFLOW_ARENA_BYTES)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&line.scene);

    uint overflowed_pixel = settle_and_sample(&fixture, &line)!!;
    assert(renderer.stats.cull_overflows > 0);
    set_view_culling(&fixture, false)!!;
    uint unculled_pixel = settle_and_sample(&fixture, &line)!!;
    assert(overflowed_pixel == unculled_pixel);
    check_validation(renderer);
}

fn ModelId? add_offset_walker(Fixture* fixture) @private {
    AssetStore* assets = &fixture.assets;
    GeometryId part;
    @pool() {
        Geometry box = geometry::box(tmem, CROWD_PART_SIZE, CROWD_PART_SIZE, CROWD_PART_SIZE);
        box.joints = alloc::new_array(tmem, ushort[<4>], box.positions.len);
        box.weights = alloc::new_array(tmem, Vec4, box.positions.len);
        foreach (&weights : box.weights) *weights = { 1, 0, 0, 0 };
        part = assets.add_geometry(&box)!;
    };

    Skeleton skeleton = {
        .joint_names  = alloc::new_array(assets.allocator, String, 1),
        .parents      = alloc::new_array(assets.allocator, int, 1),
        .rest_pose    = alloc::new_array(assets.allocator, Transform, 1),
        .inverse_bind = alloc::new_array(assets.allocator, Mat4, 1),
    };
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    SkeletonId skeleton_id = assets.add_skeleton_owned(&skeleton)!;

    AnimationClip clip = {
        .name     = "offset".copy(assets.allocator),
        .duration = 1,
        .tracks   = alloc::new_array(assets.allocator, Track, 1),
        .targets  = alloc::new_array(assets.allocator, uint, 1),
    };
    clip.targets[0] = 1;
    clip.tracks[0] = {
        .target        = 0,
        .path          = TargetPath.TRANSLATION,
        .interpolation = Interpolation.LINEAR,
        .times         = alloc::new_array(assets.allocator, float, 2),
        .values        = alloc::new_array(assets.allocator, float, 6),
    };
    clip.tracks[0].times[1] = 1;
    clip.tracks[0].values[3] = CROWD_POSE_OFFSET.x;
    clip.tracks[0].values[4] = CROWD_POSE_OFFSET.y;
    clip.tracks[0].values[5] = CROWD_POSE_OFFSET.z;
    ClipId offset = assets.add_clip_owned(&clip)!;

    ModelTemplate template = {
        .nodes  = alloc::new_array(assets.allocator, NodeTemplate, 3),
        .meshes = alloc::new_array(assets.allocator, ModelMesh, 1),
        .skins  = alloc::new_array(assets.allocator, ModelSkin, 1),
        .clips  = alloc::new_array(assets.allocator, ClipId, 1),
    };
    foreach (index, &node : template.nodes) {
        node.parent = index == 0 ? -1 : 0;
        node.name = string::format(assets.allocator, "walker%d", index);
        node.local = maths::TRANSFORM_IDENTITY;
        node.layers = scene::DEFAULT_LAYERS;
        node.visible = true;
    }
    template.meshes[0] = { .node = 2, .geometry = part, .material = fixture.plain };
    template.skins[0] = {
        .mesh_node   = 2,
        .skeleton    = skeleton_id,
        .joint_nodes = alloc::new_array(assets.allocator, uint, 1),
    };
    template.skins[0].joint_nodes[0] = 1;
    template.clips[0] = offset;
    return assets.add_model_owned(&template);
}

fn float walker_x(uint index) @private {
    if (index == CROWD_EDGE) return 2.6f;
    if (index == CROWD_TARGET) return 0;
    if (index == CROWD_TARGET + 1) return 1.2f;
    return -6 + 1.2f * (float)index;
}

fn uint? render_crowd_and_sample(Fixture* fixture, Scene* crowd_scene, Node* camera_node, Vec2 uv) @private {
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        Renderer* renderer = &fixture.renderer;
        anim::crowd_update(&fixture.assets, crowd_scene, 0);
        crowd_scene.update_world();
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(crowd_scene, camera_node, fixture.view)!;
        sample(fixture, render::read_view_color(fixture.view), uv)!;
        record_readback(fixture)!;
        renderer.finish_view(fixture.view)!;
        renderer.end_frame()!;
        pixel = read_pixel(fixture);
    }
    return pixel;
}

fn void test_culled_crowd_skins_by_source_index() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ModelId walker = add_offset_walker(&fixture)!!;
    ClipId offset = fixture.assets.model(walker).data.clips[0];

    Scene crowd_scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&crowd_scene);
    CrowdInstance[CROWD_COUNT] walkers;
    foreach (uint index, &instance : walkers) {
        Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position = { walker_x(index), 0, 0 };
        *instance = {
            .placement = placement,
            .pose      = { .clip = offset, .time = index == CROWD_TARGET ? 0 : 1, .speed = 0 },
            .color     = { 1, 1, 1, 1 },
        };
    }
    Aabb pose_bounds = { .min = { -1.5f, -0.5f, -0.5f }, .max = { 0.5f, 1.5f, 0.5f } };
    model::add_crowd(&fixture.assets, &crowd_scene, walker, CROWD_COUNT, pose_bounds, walkers[..])!!;
    Node* camera_node = crowd_scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    camera_node.local.position = CAMERA_POSITION;

    uint background = render_crowd_and_sample(&fixture, &crowd_scene, camera_node, BACKGROUND_UV)!!;
    uint target_culled = render_crowd_and_sample(&fixture, &crowd_scene, camera_node, CENTER_UV)!!;
    assert(renderer.stats.instances_visible < renderer.stats.instances_tested);
    uint edge_culled = render_crowd_and_sample(&fixture, &crowd_scene, camera_node, CROWD_EDGE_UV)!!;
    assert(target_culled != background && edge_culled != background);

    set_view_culling(&fixture, false)!!;
    assert(render_crowd_and_sample(&fixture, &crowd_scene, camera_node, CENTER_UV)!! == target_culled);
    assert(render_crowd_and_sample(&fixture, &crowd_scene, camera_node, CROWD_EDGE_UV)!! == edge_culled);
    check_validation(renderer);
}

fn uint? run_moving_line(Fixture* fixture, DeformedScene* line) @private {
    line.mesh.local.position.x = 0;
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        line.mesh.local.position.x += LINE_STEP;
        pixel = render_scene_and_sample(fixture, line)!;
    }
    return pixel;
}

fn void test_culled_temporal_batch_keeps_instance_velocity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene line = create_line_scene(&fixture, fixture.plain)!!;
    defer scene::destroy_scene(&line.scene);
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;

    uint culled_velocity = run_moving_line(&fixture, &line)!!;
    assert(renderer.stats.instances_visible < renderer.stats.instances_tested);
    set_view_culling(&fixture, false)!!;
    uint unculled_velocity = run_moving_line(&fixture, &line)!!;
    check_channels(culled_velocity, {
        (float)(unculled_velocity & 0xff) / 255,
        (float)((unculled_velocity >> 8) & 0xff) / 255,
        (float)((unculled_velocity >> 16) & 0xff) / 255,
        (float)(unculled_velocity >> 24) / 255,
    });
    check_validation(renderer);
}

fn char[]? compile_pulse_stage(Fixture* fixture, String relative, ShaderStage stage, String[] defines = {}) @private {
    String source = (String)file::load(tmem, repository_path(relative))!;
    return compile::compile_glsl(
        allocator: fixture.allocator,
        source:    source,
        stage:     stage,
        defines:   defines,
    );
}

fn ShaderId? add_pulse_shader(Fixture* fixture) @private {
    String[1] depth_only = { "DEPTH_ONLY" };
    String[1] instanced = { "INSTANCED" };
    String[2] instanced_depth = { "DEPTH_ONLY", "INSTANCED" };
    ShaderDesc desc = {
        .fragment = compile_pulse_stage(fixture, PULSE_FRAGMENT, ShaderStage.FRAGMENT)!,
        .vertex   = {
            .shaded           = compile_pulse_stage(fixture, PULSE_VERTEX, ShaderStage.VERTEX)!,
            .depth            = compile_pulse_stage(fixture, PULSE_VERTEX, ShaderStage.VERTEX, depth_only[..])!,
            .instanced_shaded = compile_pulse_stage(fixture, PULSE_VERTEX, ShaderStage.VERTEX, instanced[..])!,
            .instanced_depth  = compile_pulse_stage(fixture, PULSE_VERTEX, ShaderStage.VERTEX, instanced_depth[..])!,
        },
        .param_block_size = PulseBlock::size,
    };
    defer {
        alloc::free(fixture.allocator, desc.fragment.ptr);
        alloc::free(fixture.allocator, desc.vertex.shaded.ptr);
        alloc::free(fixture.allocator, desc.vertex.depth.ptr);
        alloc::free(fixture.allocator, desc.vertex.instanced_shaded.ptr);
        alloc::free(fixture.allocator, desc.vertex.instanced_depth.ptr);
    }
    return fixture.assets.add_shader(&desc, "pulse");
}

fn void test_culled_custom_vertex_batch_draws_survivors() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ShaderId pulse;
    @pool() {
        pulse = add_pulse_shader(&fixture)!!;
    };
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    MaterialId custom = fixture.assets.add_material(material::custom(pulse, material::@as_bytes(still)))!!;
    DeformedScene line = create_line_scene(&fixture, custom)!!;
    defer scene::destroy_scene(&line.scene);
    line.scene.ambient_intensity = 1;

    uint culled_pixel = settle_and_sample(&fixture, &line)!!;
    assert(renderer.stats.instances_visible < renderer.stats.instances_tested);
    check_opaque_color(culled_pixel);
    set_view_culling(&fixture, false)!!;
    assert(settle_and_sample(&fixture, &line)!! == culled_pixel);
    check_validation(renderer);
}
