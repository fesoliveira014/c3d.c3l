module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::hash::sha256;
import std::io::file;
import std::math;
import std::math::quaternion;

const Vec4 NEUTRAL_VELOCITY @private = { 0.5f, 0.5f, 0, 1 };
const uint CROWD_NATIVE_WIDTH @private = 384;
const uint CROWD_NATIVE_HEIGHT @private = 256;
const uint CROWD_NATIVE_PIXELS @private = CROWD_NATIVE_WIDTH * CROWD_NATIVE_HEIGHT;
const uint CROWD_NATIVE_INSTANCES @private = 3;
const uint CROWD_NATIVE_SCENE_NODES @private = 2048;
const uint CROWD_NATIVE_WARMUP @private = render::FRAMES_IN_FLIGHT + 2;
const float CROWD_NATIVE_COLOR_TOLERANCE @private = 0.004f;
const float CROWD_NATIVE_DEPTH_TOLERANCE @private = 1e-5f;
const float CROWD_NATIVE_STILL_TOLERANCE @private = 1e-5f;
const float CROWD_NATIVE_CORNER_TOLERANCE @private = 1e-4f;
const uint CROWD_NATIVE_PROBE_GROUP @private = 8;
const char[*] CROWD_NATIVE_PROBE_SOURCE @private = $embed("../render/probe_readback.comp.glsl");
const Vec4[CROWD_NATIVE_INSTANCES] CROWD_NATIVE_TINTS @private = {
    { 0.9f, 0.2f, 0.1f, 1 },
    { 0.2f, 0.8f, 0.3f, 1 },
    { 0.1f, 0.3f, 0.9f, 1 },
};
const String CROWD_NATIVE_QUATERNIUS @private = "../../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String CROWD_NATIVE_MORPH_CUBE @private = "../../../examples/assets/gltf/AnimatedMorphCube.glb";
const String CROWD_NATIVE_QUATERNIUS_SHA @private = "272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c";
const String CROWD_NATIVE_MORPH_CUBE_SHA @private = "214ee56160a50dbf22543a1d66dbf860986e87f0efac3d89feac1359d0e6aeab";

struct CrowdNativeRoot @private {
    gpu::GpuAddress output_address;
    gpu::TextureIndex atlas;
    uint width;
    uint height;
    uint padding;
}
$assert CrowdNativeRoot::size == 24;

struct CrowdNativeProbe @private {
    BufferId output;
    ComputeShaderId shader;
    gpu::MappedGpuSpan depth;
    gpu::MappedGpuSpan velocity;
    gpu::MappedGpuSpan normal;
    gpu::MappedGpuSpan shadow;
}

struct CrowdNativePair @private {
    Scene scene;
    Node* crowd;
    Node* references;
    Node*[CROWD_NATIVE_INSTANCES] ordinary;
    AnimationActionId[CROWD_NATIVE_INSTANCES] crowd_base;
    AnimationActionId[CROWD_NATIVE_INSTANCES] ordinary_base;
    Node* camera;
    ModelId model;
}

struct CrowdNativeImages @private {
    Vec4[] color;
    Vec4[] depth;
    Vec4[] velocity;
    Vec4[] normal;
    Vec4[] shadow;
    Stats stats;
    gpu::Format velocity_format;
    bool has_normal;
    uint shadow_resolution;
}

struct CrowdNativeOutput @private {
    RenderTargetId target;
    ViewId view;
    CrowdNativeProbe probe;
    CrowdNativeImages actual;
    CrowdNativeImages expected;
}

fn void check_near_pixel(uint actual, uint expected) @private {
    check_channels(actual, {
        (float)(expected & 0xff) / 255,
        (float)((expected >> 8) & 0xff) / 255,
        (float)((expected >> 16) & 0xff) / 255,
        (float)(expected >> 24) / 255,
    });
}

fn CrowdNativeImages create_crowd_native_images(Allocator allocator) @private {
    return {
        .color = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
        .depth = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
        .velocity = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
        .normal = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
        .shadow = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
    };
}

fn void destroy_crowd_native_images(Allocator allocator, CrowdNativeImages* images) @private {
    alloc::free(allocator, images.color.ptr);
    alloc::free(allocator, images.depth.ptr);
    alloc::free(allocator, images.velocity.ptr);
    alloc::free(allocator, images.normal.ptr);
    alloc::free(allocator, images.shadow.ptr);
    *images = {};
}

fn gpu::MappedGpuSpan? allocate_crowd_native_readback(Renderer* renderer, ZString name) @private {
    gpu::AllocationDesc desc = {
        .size = CROWD_NATIVE_PIXELS * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = name,
    };
    return gpu::allocate_mapped_memory(&renderer.device, &desc);
}

fn void? create_crowd_native_probe(Fixture* fixture, CrowdNativeProbe* probe) @private {
    probe.depth = allocate_crowd_native_readback(&fixture.renderer, "crowd_native_depth")!;
    defer catch {
        gpu::GpuAllocation allocation = probe.depth.span.allocation();
        gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    }
    probe.velocity = allocate_crowd_native_readback(&fixture.renderer, "crowd_native_velocity")!;
    defer catch {
        gpu::GpuAllocation allocation = probe.velocity.span.allocation();
        gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    }
    probe.normal = allocate_crowd_native_readback(&fixture.renderer, "crowd_native_normal")!;
    defer catch {
        gpu::GpuAllocation allocation = probe.normal.span.allocation();
        gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    }
    probe.shadow = allocate_crowd_native_readback(&fixture.renderer, "crowd_native_shadow")!;
    defer catch {
        gpu::GpuAllocation allocation = probe.shadow.span.allocation();
        gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    }
    probe.output = fixture.renderer.create_buffer({
        .size = CROWD_NATIVE_PIXELS * Vec4::size,
        .debug_name = "crowd_native_output",
    })!;
    probe.shader = add_compute_shader(fixture, (String)CROWD_NATIVE_PROBE_SOURCE[..])!;
}

fn void destroy_crowd_native_probe(Renderer* renderer, CrowdNativeProbe* probe) @private {
    render::wait_frames(renderer)!!;
    foreach (mapped : (gpu::MappedGpuSpan[4]){ probe.depth, probe.velocity, probe.normal, probe.shadow }) {
        gpu::GpuAllocation allocation = mapped.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    *probe = {};
}

fn void? create_crowd_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    output.target = render::create_render_target(
        &fixture.renderer,
        render::render_target_desc(CROWD_NATIVE_WIDTH, CROWD_NATIVE_HEIGHT, PixelFormat.RGBA32_FLOAT),
    )!;
    output.view = render::create_view(&fixture.renderer, render::texture_view_desc(output.target))!;
    create_crowd_native_probe(fixture, &output.probe)!;
    output.actual = create_crowd_native_images(fixture.allocator);
    output.expected = create_crowd_native_images(fixture.allocator);
}

fn void destroy_crowd_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    destroy_crowd_native_images(fixture.allocator, &output.expected);
    destroy_crowd_native_images(fixture.allocator, &output.actual);
    destroy_crowd_native_probe(&fixture.renderer, &output.probe);
}

fn void? record_crowd_native_target(
    Fixture* fixture,
    CrowdNativeProbe* probe,
    Target* target,
    gpu::MappedGpuSpan mapped,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    CrowdNativeRoot root = {
        .output_address = renderer.buffer_address(probe.output),
        .atlas = target.view.index,
        .width = target.width,
        .height = target.height,
    };
    BufferId[1] writes = { probe.output };
    renderer.dispatch({
        .shader = probe.shader,
        .root = ((char*)&root)[:CrowdNativeRoot::size],
        .groups = {
            (target.width + CROWD_NATIVE_PROBE_GROUP - 1) / CROWD_NATIVE_PROBE_GROUP,
            (target.height + CROWD_NATIVE_PROBE_GROUP - 1) / CROWD_NATIVE_PROBE_GROUP,
            1,
        },
        .writes = writes[..],
    })!;
    gpu::Barrier written = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(probe.output).allocation)!,
        .dst = mapped.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host, .compute } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;
}

fn void? record_crowd_native_view(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeProbe* probe,
    ViewId view,
    bool crowd_visible,
    CrowdNativeImages* images,
) @private {
    pair.crowd.visible = crowd_visible;
    pair.references.visible = !crowd_visible;
    pair.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    renderer.render_view(&pair.scene, pair.camera, view)!;
    ViewRecord* record = renderer.views.get(view);
    record_crowd_native_target(
        fixture: fixture,
        probe: probe,
        target: &record.depth,
        mapped: probe.depth,
    )!;
    record_crowd_native_target(
        fixture: fixture,
        probe: probe,
        target: &record.velocity,
        mapped: probe.velocity,
    )!;
    images.velocity_format = record.velocity.format;
    images.has_normal = record.desc.shading == ShadingPath.DEFERRED;
    if (images.has_normal) {
        record_crowd_native_target(
            fixture: fixture,
            probe: probe,
            target: &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS],
            mapped: probe.normal,
        )!;
    }

    images.shadow_resolution = renderer.shadow_set.layer_count ? renderer.shadow_atlas.resolution : 0;
    if (images.shadow_resolution) {
        assert(images.shadow_resolution * images.shadow_resolution <= CROWD_NATIVE_PIXELS);
        Target shadow = {
            .texture = renderer.shadow_atlas.texture,
            .view = renderer.shadow_atlas.layers[renderer.shadow_set.lights[0].first_layer].view,
            .state = renderer.shadow_atlas.state,
            .format = gpu::Format.D32_FLOAT,
            .width = images.shadow_resolution,
            .height = images.shadow_resolution,
        };
        record_crowd_native_target(
            fixture: fixture,
            probe: probe,
            target: &shadow,
            mapped: probe.shadow,
        )!;
        renderer.shadow_atlas.state = shadow.state;
    }
    renderer.finish_view(view)!;
}

fn void? read_crowd_native_view(Fixture* fixture, CrowdNativeProbe* probe, CrowdNativeImages* images) @private {
    Renderer* renderer = &fixture.renderer;
    render::wait_frames(renderer)!;
    images.stats = renderer.stats;
    gpu::invalidate_mapped_span(&renderer.device, probe.depth.span)!;
    gpu::invalidate_mapped_span(&renderer.device, probe.velocity.span)!;
    mem::copy(images.depth.ptr, probe.depth.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    mem::copy(images.velocity.ptr, probe.velocity.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    if (images.has_normal) {
        gpu::invalidate_mapped_span(&renderer.device, probe.normal.span)!;
        mem::copy(images.normal.ptr, probe.normal.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    }
    if (images.shadow_resolution) {
        gpu::invalidate_mapped_span(&renderer.device, probe.shadow.span)!;
        mem::copy(
            dst: images.shadow.ptr,
            src: probe.shadow.bytes.ptr,
            len: (sz)images.shadow_resolution * images.shadow_resolution * Vec4::size,
        );
    }
}

fn void? capture_crowd_native(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeProbe* probe,
    RenderTargetId output,
    ViewId view,
    bool crowd_visible,
    CrowdNativeImages* images,
) @private {
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        record_crowd_native_view(
            fixture: fixture,
            pair: pair,
            probe: probe,
            view: view,
            crowd_visible: crowd_visible,
            images: images,
        )!;
        renderer.end_frame()!;
    }
    read_crowd_native_view(fixture, probe, images)!;
    renderer.read_render_target(output, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!;
}

fn void? read_crowd_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    CrowdNativeImages* images = &output.actual;
    read_crowd_native_view(fixture, &output.probe, images)!;
    fixture.renderer.read_render_target(output.target, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!;
}

fn void? capture_crowd_native_outputs(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* actual,
    CrowdNativeOutput* reference,
) @private {
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        foreach (index, output : (CrowdNativeOutput*[2]){ actual, reference }) {
            record_crowd_native_view(
                fixture: fixture,
                pair: pair,
                probe: &output.probe,
                view: output.view,
                crowd_visible: index == 0,
                images: &output.actual,
            )!;
        }
        renderer.end_frame()!;
    }
    read_crowd_native_output(fixture, actual)!;
    read_crowd_native_output(fixture, reference)!;
}

fn void check_crowd_native_image(
    Vec4[] actual,
    Vec4[] expected,
    float tolerance,
    uint width = CROWD_NATIVE_WIDTH,
    uint height = CROWD_NATIVE_HEIGHT,
) @private {
    for (int y = 1; y + 1 < (int)height; y++) {
        for (int x = 1; x + 1 < (int)width; x++) {
            Vec4 pixel = actual[y * (int)width + x];
            bool matched;
            for (int dy = -1; dy <= 1 && !matched; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    Vec4 delta = math::abs(pixel - expected[(y + dy) * (int)width + x + dx]);
                    float error = math::max(math::max(delta.x, delta.y), math::max(delta.z, delta.w));
                    if (error <= tolerance) matched = true;
                }
            }
            assert(matched, "Crowd raster differs from ordinary Animator");
        }
    }
}

fn void check_crowd_native_coverage(CrowdNativeImages* images, bool tinted = true) @private {
    uint covered;
    uint[CROWD_NATIVE_INSTANCES] sources;
    foreach (index, depth : images.depth) {
        if (depth.x <= 0) continue;
        covered++;
        if (!tinted) sources[(index % CROWD_NATIVE_WIDTH) * CROWD_NATIVE_INSTANCES / CROWD_NATIVE_WIDTH]++;
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Vec4 delta = math::abs(images.color[index] - CROWD_NATIVE_TINTS[source]);
            if (math::max(math::max(delta.x, delta.y), delta.z) <= CROWD_NATIVE_COLOR_TOLERANCE) sources[source]++;
        }
        Vec4 velocity = images.velocity[index];
        assert(math::abs(velocity.x) < CROWD_NATIVE_STILL_TOLERANCE);
        assert(math::abs(velocity.y) < CROWD_NATIVE_STILL_TOLERANCE);
        if (images.velocity_format == gpu::Format.RGBA16_FLOAT) assert(velocity.w == 0);
    }
    assert(covered > 0, "Crowd frame has empty depth coverage");
    foreach (count : sources) assert(count > 0, "A logical source has empty coverage");
}

fn void check_crowd_native_parity(CrowdNativeImages* crowd, CrowdNativeImages* ordinary, bool tinted = true) @private {
    check_crowd_native_coverage(crowd, tinted);
    check_crowd_native_coverage(ordinary, tinted);
    check_crowd_native_image(crowd.color, ordinary.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(ordinary.color, crowd.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(crowd.depth, ordinary.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(ordinary.depth, crowd.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
}

fn void check_crowd_native_normals(CrowdNativeImages* actual, CrowdNativeImages* expected) @private {
    assert(actual.has_normal && expected.has_normal);
    check_crowd_native_image(actual.normal, expected.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(expected.normal, actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    uint covered;
    foreach (index, depth : actual.depth) {
        if (depth.x > 0 && actual.normal[index].w > 0.5f) covered++;
    }
    assert(covered > 0, "Standard geometry did not write the G-buffer normal attachment");
}

fn void check_crowd_native_shadows(CrowdNativeImages* actual, CrowdNativeImages* expected) @private {
    uint resolution = actual.shadow_resolution;
    assert(resolution && resolution == expected.shadow_resolution);
    uint actual_covered;
    uint expected_covered;
    for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
        if (actual.shadow[pixel].x > 0) actual_covered++;
        if (expected.shadow[pixel].x > 0) expected_covered++;
    }
    assert(actual_covered > 0 && expected_covered > 0, "Shadow atlas has empty coverage");
    check_crowd_native_image(
        actual: actual.shadow,
        expected: expected.shadow,
        tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
        width: resolution,
        height: resolution,
    );
    check_crowd_native_image(
        actual: expected.shadow,
        expected: actual.shadow,
        tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
        width: resolution,
        height: resolution,
    );
}

fn CrowdPlayer? crowd_native_player(CrowdNativePair* pair, uint index) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    return crowd.playback.player(crowd.playback.instance_id(index)!);
}

fn void? create_crowd_native_pair(
    Allocator allocator,
    Fixture* fixture,
    CrowdNativePair* pair,
    ModelId model,
    ClipId clip,
    Aabb bounds,
    Transform[] placements = {},
    bool tinted = true,
) @private {
    pair.scene = scene::create_scene(allocator, { .max_nodes = CROWD_NATIVE_SCENE_NODES });
    defer catch scene::destroy_scene(&pair.scene);
    pair.model = model;
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    for (uint index = 0; index < CROWD_NATIVE_INSTANCES; index++) {
        Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)index - 1) * 11;
        placement.scale = { index == 2 ? -0.6f : 0.6f, 0.6f, 0.6f };
        instances[index] = {
            .placement = placements.len ? placements[index] : placement,
            .pose = { .clip = clip, .time = 0, .speed = 0, .loop = false },
            .color = tinted ? CROWD_NATIVE_TINTS[index] : (Vec4){ 1, 1, 1, 1 },
        };
    }
    pair.crowd = model::add_crowd(
        assets: &fixture.assets,
        scene: &pair.scene,
        model: model,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: bounds,
        instances: instances[..],
        actions_per_instance: anim::MAX_ACTIONS,
    )!;
    pair.references = pair.scene.add_node(name: "ordinary_references")!;
    for (uint index = 0; index < CROWD_NATIVE_INSTANCES; index++) {
        pair.ordinary[index] = model::instantiate(
            assets: &fixture.assets,
            scene: &pair.scene,
            model: model,
            parent: pair.references,
        )!;
        pair.ordinary[index].local = instances[index].placement;
        Animator* animator = anim::add_animator(&pair.scene, pair.ordinary[index]);
        AnimationActionId action = animator.play(&fixture.assets, clip)!;
        animator.action(action).speed = 0;
        animator.action(action).loop = false;
        pair.ordinary_base[index] = action;
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        pair.crowd_base[index] = crowd.playback.slots[index].base_action;
        if (tinted) {
            MaterialId material = fixture.assets.add_material(material::basic({ .color = CROWD_NATIVE_TINTS[index] }))!;
            ModelInstance* instance = pair.scene.get(pair.ordinary[index], ModelInstance);
            foreach (node : instance.mesh_nodes) pair.scene.get(instance.present_node(node), Mesh).material = material;
        }
    }
    pair.camera = pair.scene.add_camera(camera::orthographic(18, 0.1f, 100))!;
    pair.camera.local.position = { 0, 0, 20 };
    pair.references.visible = false;
}

fn void crowd_native_update(Fixture* fixture, CrowdNativePair* pair, float dt) @private {
    anim::update(&fixture.assets, &pair.scene, dt);
    anim::crowd_update(&fixture.assets, &pair.scene, dt);
    pair.scene.update_world();
}

fn void? crowd_native_phase(CrowdNativePair* pair, float phase) @private {
    for (uint index = 0; index < CROWD_NATIVE_INSTANCES; index++) {
        CrowdPlayer player = crowd_native_player(pair, index)!;
        player.action(pair.crowd_base[index]).time = phase;
        Animator* animator = pair.scene.get(pair.ordinary[index], Animator);
        animator.action(pair.ordinary_base[index]).time = phase;
    }
}

fn void? crowd_native_replace_base(Fixture* fixture, CrowdNativePair* pair, ClipId clip) @private {
    for (uint index = 0; index < CROWD_NATIVE_INSTANCES; index++) {
        CrowdPlayer player = crowd_native_player(pair, index)!;
        player.stop(pair.crowd_base[index])!;
        pair.crowd_base[index] = player.play(&fixture.assets, clip)!;
        player.action(pair.crowd_base[index]).speed = 0;
        player.action(pair.crowd_base[index]).loop = false;
        Animator* animator = pair.scene.get(pair.ordinary[index], Animator);
        animator.stop(pair.ordinary_base[index])!;
        pair.ordinary_base[index] = animator.play(&fixture.assets, clip)!;
        animator.action(pair.ordinary_base[index]).speed = 0;
        animator.action(pair.ordinary_base[index]).loop = false;
    }
}

fn void check_crowd_native_validation(Renderer* renderer) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        if (!entry.category.backend || !entry.category.validation) continue;
        assert(entry.severity != gpu::DebugMessageSeverity.ERROR);
        assert(entry.severity != gpu::DebugMessageSeverity.WARNING);
    }
}

fn void? compare_crowd_native_paths(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* output,
    bool standard = false,
    bool tinted = true,
    bool shadow = false,
) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    for (uint path = 0; path < 3; path++) {
        ViewDesc desc = render::texture_view_desc(output.target);
        desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.depth_prepass = path == 1 || (!standard && path == 2);
        desc.post.motion_blur = true;
        render::configure_view(&fixture.renderer, output.view, desc)!;
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: true,
            images: &output.actual,
        )!;
        uint passes = path == 0 ? 1 : 2; // Deferred geometry records its own depth prepass.
        if (shadow) passes += output.actual.stats.shadow_layers;
        assert(output.actual.stats.instances_tested == passes * crowd.parts.len * crowd.count);
        assert(output.actual.stats.instances_visible == passes * crowd.parts.len * crowd.count);
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: false,
            images: &output.expected,
        )!;
        check_crowd_native_parity(&output.actual, &output.expected, tinted);
        if (shadow) {
            assert(output.actual.stats.shadow_layers == 1);
            check_crowd_native_shadows(&output.actual, &output.expected);
        }
        if (standard && path == 2) check_crowd_native_normals(&output.actual, &output.expected);
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn Track crowd_native_track(
    Allocator allocator,
    uint target,
    TargetPath path,
    float[] values,
) @private {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(allocator, float, 2),
        .values = alloc::clone_slice(allocator, values),
    };
    track.times[1] = 1;
    return track;
}

fn ClipId? add_crowd_native_controls_clip(AssetStore* assets) @private {
    Allocator allocator = assets.allocator;
    AnimationClip clip = {
        .name = "native_controls".copy(allocator),
        .duration = 1,
        .tracks = alloc::new_array(allocator, Track, 4),
        .targets = alloc::new_array(allocator, uint, 3),
        .events = alloc::new_array(allocator, ClipEvent, 2),
    };
    defer catch asset::free_clip(allocator, &clip);
    uint[3] targets = {
        animated_crowd_fixtures::PARTS_RIGID_NODE,
        animated_crowd_fixtures::PARTS_MORPH_B,
        animated_crowd_fixtures::PARTS_JOINT_ROOT,
    };
    clip.targets[..] = targets[..];
    Quat rigid = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.9f);
    Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.5f);
    float[8] rigid_values = { 0, 0, 0, 1, rigid.v.x, rigid.v.y, rigid.v.z, rigid.v.w };
    float[2] morph_values = { 0.75f, 0.1f };
    float[6] root_values = { 2, 0, 0, 4, 0, 0.5f };
    float[8] yaw_values = { 0, 0, 0, 1, yaw.v.x, yaw.v.y, yaw.v.z, yaw.v.w };
    clip.tracks[0] = crowd_native_track(
        allocator: allocator,
        target: 0,
        path: TargetPath.ROTATION,
        values: rigid_values[..],
    );
    clip.tracks[1] = crowd_native_track(
        allocator: allocator,
        target: 1,
        path: TargetPath.MORPH_WEIGHTS,
        values: morph_values[..],
    );
    clip.tracks[2] = crowd_native_track(
        allocator: allocator,
        target: 2,
        path: TargetPath.TRANSLATION,
        values: root_values[..],
    );
    clip.tracks[3] = crowd_native_track(
        allocator: allocator,
        target: 2,
        path: TargetPath.ROTATION,
        values: yaw_values[..],
    );
    ClipEvent[2] events = { { .time = 0.2f, .id = 20 }, { .time = 0.7f, .id = 70 } };
    clip.events[..] = events[..];
    return assets.add_clip_owned(&clip);
}

fn void crowd_native_action_controls(Action* action, float time, float weight = 1) @private {
    action.time = time;
    action.speed = 0;
    action.weight = weight;
    action.loop = false;
}

fn void? crowd_native_play_both(
    Fixture* fixture,
    CrowdNativePair* pair,
    uint source,
    ClipId clip,
    PlayDesc desc,
    float time,
    float weight = 1,
) @private {
    CrowdPlayer player = crowd_native_player(pair, source)!;
    AnimationActionId crowd_action = player.play(&fixture.assets, clip, desc)!;
    crowd_native_action_controls(player.action(crowd_action), time, weight);
    Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
    AnimationActionId ordinary_action = animator.play(&fixture.assets, clip, desc)!;
    crowd_native_action_controls(animator.action(ordinary_action), time, weight);
}

fn void check_crowd_native_affines(CrowdNativePair* pair) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* ordinary = pair.scene.get(pair.ordinary[source], ModelInstance);
        foreach (index, part : crowd.parts) {
            if (part.skinned) continue;
            Mat4 actual = pair.crowd.world.mul(crowd.part_transform(source, (uint)index));
            Mat4 expected = ordinary.present_node(part.template_node).world;
            foreach (point : (Vec3[4]){ {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) {
                assert((maths::transform_point(actual, point) - maths::transform_point(expected, point)).length()
                  <= CROWD_NATIVE_CORNER_TOLERANCE);
            }
        }
    }
    Mat4 rigid = crowd.part_transform(2, 1);
    Vec3 axis_x = { rigid.m00, rigid.m10, rigid.m20 };
    Vec3 axis_y = { rigid.m01, rigid.m11, rigid.m21 };
    assert(math::abs(axis_x.dot(axis_y)) > CROWD_NATIVE_CORNER_TOLERANCE, "Rigid fixture did not create affine shear");
    assert(rigid.determinant() < 0);
}

fn void? use_crowd_native_standard_materials(Fixture* fixture, CrowdNativePair* pair) @private {
    ModelTemplate* template = &fixture.assets.model(pair.model).data;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = 0.7f;
    params.emissive = { 0.2f, 0.2f, 0.2f };
    foreach (mesh : template.meshes) {
        fixture.assets.material(mesh.material).data = material::standard(params);
        fixture.assets.mark_material_dirty(mesh.material);
    }
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        params.base_color = CROWD_NATIVE_TINTS[source];
        ModelInstance* instance = pair.scene.get(pair.ordinary[source], ModelInstance);
        foreach (node : instance.mesh_nodes) {
            Mesh* mesh = pair.scene.get(instance.present_node(node), Mesh);
            fixture.assets.material(mesh.material).data = material::standard(params);
            fixture.assets.mark_material_dirty(mesh.material);
        }
    }
    Node* sun = pair.scene.add_light(light::directional({ 1, 1, 1 }, 2, false))!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0, -0.3f, -1 }.normalize(), { 0, 1, 0 });
}

fn ModelId? load_crowd_native_cc0(
    Fixture* fixture,
    String filename,
    String expected_hash,
) @private {
    char[] bytes = file::load(fixture.allocator, filename)!;
    defer alloc::free(fixture.allocator, bytes.ptr);
    char[32] digest = sha256::hash(bytes);
    char[64] encoded;
    foreach (index, value : digest) {
        encoded[index * 2] = "0123456789abcdef"[((uint)value & 255) >> 4];
        encoded[index * 2 + 1] = "0123456789abcdef"[(uint)value & 15];
    }
    assert((String)encoded[..] == expected_hash, "CC0 source bytes differ from the approved fixture");
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
    options.generate_tangents = false;
    return gltf::load_model_memory(
        assets: &fixture.assets,
        bytes: bytes,
        base_dir: "../../../examples/assets",
        key: filename,
        options: options,
    );
}

fn ClipId? crowd_native_clip_named(Fixture* fixture, ModelId model, String name) @private {
    foreach (clip : fixture.assets.model(model).data.clips) {
        if (fixture.assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn void crowd_native_flat_source_materials(Fixture* fixture, ModelId model) @private {
    foreach (mesh : fixture.assets.model(model).data.meshes) {
        fixture.assets.material(mesh.material).data = material::basic({ .color = { 1, 1, 1, 1 } });
        fixture.assets.mark_material_dirty(mesh.material);
    }
}

fn Transform[CROWD_NATIVE_INSTANCES] crowd_native_real_placements() @private {
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (index, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)index - 1) * 3;
        placement.scale = { index == 2 ? -0.9f : 0.9f, 1.1f, 0.8f };
    }
    return placements;
}

fn void? crowd_native_stop_all(CrowdNativePair* pair) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(pair, source)!;
        CrowdPlaybackSlot* slot = &player.state.slots[source];
        while (slot.action_count) player.stop(slot.order[slot.action_count - 1])!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        while (animator.action_count) animator.stop(animator.order[animator.action_count - 1])!;
    }
}

fn void test_crowd_native_mixed_rest_endpoint_and_missing_weights_match_animator() @test {
    foreach (bool skin_free : { false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: skin_free ? parts.skin_free : parts.mixed,
            clip: parts.posing,
            bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        )!!;
        defer scene::destroy_scene(&pair.scene);
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        uint expected_parts = skin_free ? 3 : animated_crowd_fixtures::PARTS_MESH_COUNT;
        assert(crowd.parts.len == expected_parts && crowd.count == CROWD_NATIVE_INSTANCES);
        CrowdNativeOutput output;
        create_crowd_native_output(&fixture, &output)!!;
        defer destroy_crowd_native_output(&fixture, &output);
        for (uint pose = 0; pose < 3; pose++) {
            if (pose == 2) crowd_native_replace_base(&fixture, &pair, parts.missing_weights)!!;
            crowd_native_phase(&pair, pose == 0 ? 0 : 1)!!;
            crowd_native_update(&fixture, &pair, 0);
            compare_crowd_native_paths(&fixture, &pair, &output)!!;
        }
    }
}

fn void test_crowd_native_independent_controls_and_affine_shear_match_standard_deferred() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    ClipId controls = add_crowd_native_controls_clip(&fixture.assets)!!;
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (source, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)source - 1) * 11;
        placement.scale = { source == 2 ? -0.6f : 0.6f, 0.8f, 0.5f };
        placement.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.1f * (float)source);
    }
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    use_crowd_native_standard_materials(&fixture, &pair)!!;
    String[2] names = { "rigid_mesh", "morph_b" };
    JointMask mask = anim::create_joint_mask(
        allocator: mem,
        template: &fixture.assets.model(pair.model).data,
        names: names[..],
    )!!;
    defer anim::destroy_joint_mask(&mask);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float phase = 0.2f + 0.25f * (float)source;
        crowd_native_action_controls(player.base_action()!!, phase, 0.6f);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), phase, 0.6f);
        crowd_native_play_both(
            fixture: &fixture,
            pair: &pair,
            source: source,
            clip: controls,
            desc: { .layer = 1, .mask = &mask },
            time: 0.3f + 0.25f * (float)source,
            weight: 0.5f,
        )!!;
    }
    mask.nodes[..] = false;
    crowd_native_play_both(
        fixture: &fixture,
        pair: &pair,
        source: 0,
        clip: parts.missing_weights,
        desc: {},
        time: 0.8f,
        weight: 0.4f,
    )!!;
    crowd_native_play_both(
        fixture: &fixture,
        pair: &pair,
        source: 1,
        clip: parts.posing,
        desc: { .layer = 2, .additive = true },
        time: 0.7f,
        weight: 0.5f,
    )!!;
    CrowdPlayer space_player = crowd_native_player(&pair, 2)!!;
    Animator* space_animator = pair.scene.get(pair.ordinary[2], Animator);
    space_player.stop(pair.crowd_base[2])!!;
    space_animator.stop(pair.ordinary_base[2])!!;
    ClipId[2] clips = { parts.posing, parts.missing_weights };
    float[2] positions = { 0, 1 };
    BlendSpace1D* crowd_space = space_player.add_blend_space(
        assets: &fixture.assets,
        clips: clips[..],
        positions: positions[..],
        desc: {},
    )!!;
    BlendSpace1D* ordinary_space = space_animator.add_blend_space(
        assets: &fixture.assets,
        clips: clips[..],
        positions: positions[..],
        desc: {},
    )!!;
    crowd_space.parameter = ordinary_space.parameter = 0.65f;
    crowd_space.phase = ordinary_space.phase = 0.45;
    crowd_space.speed = ordinary_space.speed = 0;
    CrowdPlayer fading_player = crowd_native_player(&pair, 0)!!;
    Animator* fading_animator = pair.scene.get(pair.ordinary[0], Animator);
    AnimationActionId incoming = fading_player.play(&fixture.assets, parts.posing, { .fade_in = 0.5f })!!;
    AnimationActionId ordinary_incoming = fading_animator.play(&fixture.assets, parts.posing, { .fade_in = 0.5f })!!;
    crowd_native_action_controls(fading_player.action(incoming), 0.9f, 0);
    crowd_native_action_controls(fading_animator.action(ordinary_incoming), 0.9f, 0);
    fading_player.cross_fade(pair.crowd_base[0], incoming, 0.5f)!!;
    fading_animator.cross_fade(pair.ordinary_base[0], ordinary_incoming, 0.5f)!!;
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    for (uint step = 0; step < 3; step++) {
        crowd_native_update(&fixture, &pair, step == 0 ? 0 : 0.2f);
        check_crowd_native_affines(&pair);
        compare_crowd_native_paths(
            fixture: &fixture,
            pair: &pair,
            output: &output,
            standard: true,
            tinted: false,
        )!!;
    }
}

fn void test_crowd_native_real_sources_match_animator() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);

    ModelId quaternius = load_crowd_native_cc0(&fixture, CROWD_NATIVE_QUATERNIUS, CROWD_NATIVE_QUATERNIUS_SHA)!!;
    crowd_native_flat_source_materials(&fixture, quaternius);
    ClipId walk = crowd_native_clip_named(&fixture, quaternius, "Walk_Loop")!!;
    ClipId jog = crowd_native_clip_named(&fixture, quaternius, "Jog_Fwd_Loop")!!;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: quaternius,
            clip: walk,
            bounds: { .min = { -1.5f, -0.1f, -1.5f }, .max = { 1.5f, 2.7f, 1.5f } },
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
        pair.camera.local.position = { 0, 1, 12 };
        float walk_duration = fixture.assets.clip(walk).data.duration;
        float jog_duration = fixture.assets.clip(jog).data.duration;
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            CrowdPlayer player = crowd_native_player(&pair, source)!!;
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            float time = (0.125f + 0.25f * (float)source) * walk_duration;
            crowd_native_action_controls(player.base_action()!!, time, 0.75f);
            crowd_native_action_controls(animator.action(pair.ordinary_base[source]), time, 0.75f);
            crowd_native_play_both(
                fixture: &fixture,
                pair: &pair,
                source: source,
                clip: jog,
                desc: {},
                time: (0.2f + 0.2f * (float)source) * jog_duration,
                weight: 0.25f,
            )!!;
        }
        crowd_native_update(&fixture, &pair, 0);
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        assert(crowd.parts.len == 2 && crowd.joint_count == 53);
        compare_crowd_native_paths(&fixture, &pair, &output)!!;
    }

    ModelId morph_cube = load_crowd_native_cc0(&fixture, CROWD_NATIVE_MORPH_CUBE, CROWD_NATIVE_MORPH_CUBE_SHA)!!;
    crowd_native_flat_source_materials(&fixture, morph_cube);
    ClipId morph_clip = fixture.assets.model(morph_cube).data.clips[0];
    float morph_duration = fixture.assets.clip(morph_clip).data.duration;
    {
        Transform[CROWD_NATIVE_INSTANCES] scaled = placements;
        foreach (&placement : scaled) placement.scale *= 0.6f;
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: morph_cube,
            clip: morph_clip,
            bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
            placements: scaled[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
        pair.camera.local.position = { 0, 0, 12 };
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            CrowdPlayer player = crowd_native_player(&pair, source)!!;
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            float time = (0.2f + 0.25f * (float)source) * morph_duration;
            crowd_native_action_controls(player.base_action()!!, time);
            crowd_native_action_controls(animator.action(pair.ordinary_base[source]), time);
        }
        crowd_native_play_both(
            fixture: &fixture,
            pair: &pair,
            source: 1,
            clip: morph_clip,
            desc: { .layer = 1, .additive = true },
            time: morph_duration * 0.5f,
            weight: 0.5f,
        )!!;
        crowd_native_update(&fixture, &pair, 0);
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        assert(crowd.parts.len == 1 && crowd.joint_count == 0);
        compare_crowd_native_paths(&fixture, &pair, &output)!!;
        crowd_native_stop_all(&pair)!!;
        crowd_native_update(&fixture, &pair, 0);
        compare_crowd_native_paths(&fixture, &pair, &output)!!;
    }

    ModelId wide = add_wide_crowd_model(&fixture)!!;
    ModelTemplate* template = &fixture.assets.model(wide).data;
    template.nodes[1].local.position.x = -0.7f;
    template.nodes[WIDE_JOINT_COUNT].local.position.x = 0.7f;
    crowd_native_flat_source_materials(&fixture, wide);
    {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: wide,
            clip: template.clips[0],
            bounds: { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } },
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
        pair.camera.local.position = { 0, 0, 12 };
        crowd_native_update(&fixture, &pair, 0);
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        assert(crowd.joint_count == WIDE_JOINT_COUNT && crowd.parts.len == 2);
        compare_crowd_native_paths(&fixture, &pair, &output)!!;
    }
}

fn void test_crowd_native_consumed_root_motion_and_shadow_pose_match_animator() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    ClipId motion = add_crowd_native_controls_clip(&fixture.assets)!!;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: { .min = { -8, -4, -8 }, .max = { 16, 8, 8 } },
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    crowd_native_stop_all(&pair)!!;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        crowd.placements[source].scale = { 0.6f, 0.6f, 0.6f };
        pair.ordinary[source].local.scale = { 0.6f, 0.6f, 0.6f };
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        PlayDesc desc = { .root_motion = RootMotion.EXTRACT, .root_yaw = true };
        AnimationActionId action = player.play(&fixture.assets, motion, desc)!!;
        AnimationActionId reference = animator.play(&fixture.assets, motion, desc)!!;
        player.action(action).speed = animator.action(reference).speed = source == 2 ? -1 : 1;
        player.action(action).time = animator.action(reference).time = source == 2 ? 0.9f : 0;
    }
    pair.scene.write_crowd_batches(crowd);
    crowd_native_update(&fixture, &pair, 0);
    crowd_native_update(&fixture, &pair, 0.35f);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        anim::apply_root_motion(pair.ordinary[source], animator.root_motion);
    }
    pair.scene.apply_crowd_root_motion(crowd);
    Light light = light::directional({ 1, 1, 1 }, 2);
    light.shadow.cascades = 1;
    light.shadow.max_distance = 100;
    Node* sun = pair.scene.add_light(light)!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0, -0.3f, -1 }.normalize(), { 0, 1, 0 });
    pair.scene.update_world();
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    compare_crowd_native_paths(
        fixture: &fixture,
        pair: &pair,
        output: &output,
        standard: false,
        tinted: true,
        shadow: true,
    )!!;
}
