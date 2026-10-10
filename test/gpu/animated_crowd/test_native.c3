module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::io;
import std::math;

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
    Stats stats;
    gpu::Format velocity_format;
    bool has_normal;
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
    };
}

fn void destroy_crowd_native_images(Allocator allocator, CrowdNativeImages* images) @private {
    alloc::free(allocator, images.color.ptr);
    alloc::free(allocator, images.depth.ptr);
    alloc::free(allocator, images.velocity.ptr);
    alloc::free(allocator, images.normal.ptr);
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
    probe.output = fixture.renderer.create_buffer({
        .size = CROWD_NATIVE_PIXELS * Vec4::size,
        .debug_name = "crowd_native_output",
    })!;
    probe.shader = add_compute_shader(fixture, (String)CROWD_NATIVE_PROBE_SOURCE[..])!;
}

fn void destroy_crowd_native_probe(Renderer* renderer, CrowdNativeProbe* probe) @private {
    render::wait_frames(renderer)!!;
    foreach (mapped : (gpu::MappedGpuSpan[3]){ probe.depth, probe.velocity, probe.normal }) {
        gpu::GpuAllocation allocation = mapped.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    *probe = {};
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

fn void? capture_crowd_native(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeProbe* probe,
    RenderTargetId output,
    ViewId view,
    bool crowd_visible,
    CrowdNativeImages* images,
) @private {
    pair.crowd.visible = crowd_visible;
    pair.references.visible = !crowd_visible;
    pair.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&pair.scene, pair.camera, view)!;
        if (frame + 1 == CROWD_NATIVE_WARMUP) {
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
            images.has_normal = record.desc.shading == ShadingPath.DEFERRED;
            if (images.has_normal) {
                record_crowd_native_target(
                    fixture: fixture,
                    probe: probe,
                    target: &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS],
                    mapped: probe.normal,
                )!;
            }
        }
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }
    images.stats = renderer.stats;
    images.velocity_format = renderer.views.get(view).velocity.format;
    renderer.read_render_target(output, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!;
    gpu::invalidate_mapped_span(&renderer.device, probe.depth.span)!;
    gpu::invalidate_mapped_span(&renderer.device, probe.velocity.span)!;
    mem::copy(images.depth.ptr, probe.depth.bytes.ptr, images.depth.len * Vec4::size);
    mem::copy(images.velocity.ptr, probe.velocity.bytes.ptr, images.velocity.len * Vec4::size);
    if (images.has_normal) {
        gpu::invalidate_mapped_span(&renderer.device, probe.normal.span)!;
        mem::copy(images.normal.ptr, probe.normal.bytes.ptr, images.normal.len * Vec4::size);
    }
}

fn void check_crowd_native_image(Vec4[] actual, Vec4[] expected, float tolerance) @private {
    for (int y = 1; y + 1 < (int)CROWD_NATIVE_HEIGHT; y++) {
        for (int x = 1; x + 1 < (int)CROWD_NATIVE_WIDTH; x++) {
            Vec4 pixel = actual[y * (int)CROWD_NATIVE_WIDTH + x];
            bool matched;
            for (int dy = -1; dy <= 1 && !matched; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    Vec4 delta = math::abs(pixel - expected[(y + dy) * (int)CROWD_NATIVE_WIDTH + x + dx]);
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

fn void? run_crowd_native_mixed(bool skin_free) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: skin_free ? parts.skin_free : parts.mixed,
        clip: parts.posing,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
    )!;
    defer scene::destroy_scene(&pair.scene);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    uint expected_parts = skin_free ? 3 : animated_crowd_fixtures::PARTS_MESH_COUNT;
    assert(crowd.parts.len == expected_parts && crowd.count == CROWD_NATIVE_INSTANCES);
    RenderTargetId output = render::create_render_target(
        &fixture.renderer,
        render::render_target_desc(CROWD_NATIVE_WIDTH, CROWD_NATIVE_HEIGHT, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewId view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!;
    CrowdNativeProbe probe;
    create_crowd_native_probe(&fixture, &probe)!;
    defer destroy_crowd_native_probe(&fixture.renderer, &probe);
    CrowdNativeImages actual = create_crowd_native_images(mem);
    defer destroy_crowd_native_images(mem, &actual);
    CrowdNativeImages expected = create_crowd_native_images(mem);
    defer destroy_crowd_native_images(mem, &expected);
    for (uint pose = 0; pose < 3; pose++) {
        if (pose == 2) crowd_native_replace_base(&fixture, &pair, parts.missing_weights)!;
        crowd_native_phase(&pair, pose == 0 ? 0 : 1)!;
        crowd_native_update(&fixture, &pair, 0);
        for (uint path = 0; path < 3; path++) {
            ViewDesc desc = render::texture_view_desc(output);
            desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
            desc.depth_prepass = path != 0;
            desc.post.motion_blur = true;
            render::configure_view(&fixture.renderer, view, desc)!;
            capture_crowd_native(
                fixture: &fixture,
                pair: &pair,
                probe: &probe,
                output: output,
                view: view,
                crowd_visible: true,
                images: &actual,
            )!;
            uint culling_passes = path == 0 ? 1 : 2;
            uint expected_instances = culling_passes * expected_parts * CROWD_NATIVE_INSTANCES;
            io::printfn("mixed=%s pose=%s path=%s tested=%s visible=%s expected=%s",
                !skin_free, pose, path, actual.stats.instances_tested, actual.stats.instances_visible, expected_instances);
            assert(actual.stats.instances_tested == expected_instances);
            assert(actual.stats.instances_visible == expected_instances);
            capture_crowd_native(
                fixture: &fixture,
                pair: &pair,
                probe: &probe,
                output: output,
                view: view,
                crowd_visible: false,
                images: &expected,
            )!;
            check_crowd_native_parity(&actual, &expected);
        }
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_crowd_native_mixed_rest_endpoint_and_missing_weights_match_animator() @test {
    run_crowd_native_mixed(false)!!;
}

fn void test_crowd_native_skin_free_rest_endpoint_and_missing_weights_match_animator() @test {
    run_crowd_native_mixed(true)!!;
}
