module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import gpu;
import std::hash::sha256;
import std::io::file;
import std::math;

const uint CROWD_NATIVE_WIDTH @private = 384;
const uint CROWD_NATIVE_HEIGHT @private = 256;
const uint CROWD_NATIVE_PIXELS @private = CROWD_NATIVE_WIDTH * CROWD_NATIVE_HEIGHT;
const uint CROWD_NATIVE_INSTANCES @private = 3;
const uint CROWD_NATIVE_SCENE_NODES @private = 2048;
const uint CROWD_NATIVE_WARMUP @private = render::FRAMES_IN_FLIGHT + 2;
const float CROWD_NATIVE_COLOR_TOLERANCE @private = 0.004f;
const float CROWD_NATIVE_DEPTH_TOLERANCE @private = 1e-5f;
const float CROWD_NATIVE_STILL_TOLERANCE @private = 1e-5f;
const uint CROWD_NATIVE_PROBE_GROUP @private = 8;
const char[*] CROWD_NATIVE_PROBE_SOURCE @private = $embed("../render/probe_readback.comp.glsl");
const String CROWD_NATIVE_QUATERNIUS @private = "../../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String CROWD_NATIVE_MORPH_CUBE @private = "../../../examples/assets/gltf/AnimatedMorphCube.glb";
const String CROWD_NATIVE_QUATERNIUS_SHA @private = "272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c";
const String CROWD_NATIVE_MORPH_CUBE_SHA @private = "214ee56160a50dbf22543a1d66dbf860986e87f0efac3d89feac1359d0e6aeab";

struct Fixture @private {
    Allocator allocator;
    AssetStore assets;
    Renderer renderer;
}

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
}

struct CrowdNativePair @private {
    Scene scene;
    Node* crowd;
    Node* references;
    Node*[CROWD_NATIVE_INSTANCES] ordinary;
    Node* camera;
    ModelId model;
}

struct CrowdNativeImages @private {
    Vec4[] color;
    Vec4[] depth;
    Vec4[] velocity;
    gpu::Format velocity_format;
}

struct CrowdNativeOutput @private {
    RenderTargetId target;
    ViewId view;
    CrowdNativeProbe probe;
    CrowdNativeImages actual;
    CrowdNativeImages expected;
}

fn void? create_fixture(Allocator allocator, Fixture* fixture) @private {
    fixture.allocator = allocator;
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);

    fixture.renderer = render::create_renderer(
        allocator: allocator,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .shadow_resolution = 64,
            .max_shadow_layers = 1,
            .application_name = "animation_authoring_acceptance",
        },
    )!;
}

fn void destroy_fixture(Fixture* fixture) @private {
    render::wait_frames(&fixture.renderer)!!;
    render::destroy_renderer(&fixture.renderer);
    asset::destroy_asset_store(&fixture.assets);
}

fn ComputeShaderId? add_compute_shader(Fixture* fixture, String source) @private {
    char[] spirv = compile::compile_glsl(fixture.allocator, source, ShaderStage.COMPUTE)!;
    defer alloc::free(fixture.allocator, spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    return fixture.assets.add_compute_shader(&shader_desc);
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

fn CrowdNativeImages create_crowd_native_images(Allocator allocator) @private {
    return {
        .color = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
        .depth = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
        .velocity = alloc::new_array(allocator, Vec4, CROWD_NATIVE_PIXELS),
    };
}

fn void destroy_crowd_native_images(Allocator allocator, CrowdNativeImages* images) @private {
    alloc::free(allocator, images.color.ptr);
    alloc::free(allocator, images.depth.ptr);
    alloc::free(allocator, images.velocity.ptr);
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
    probe.output = fixture.renderer.create_buffer({
        .size = CROWD_NATIVE_PIXELS * Vec4::size,
        .debug_name = "crowd_native_output",
    })!;
    probe.shader = add_compute_shader(fixture, (String)CROWD_NATIVE_PROBE_SOURCE[..])!;
}

fn void destroy_crowd_native_probe(Renderer* renderer, CrowdNativeProbe* probe) @private {
    render::wait_frames(renderer)!!;
    foreach (mapped : (gpu::MappedGpuSpan[2]){ probe.depth, probe.velocity }) {
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
        }
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }

    images.velocity_format = renderer.views.get(view).velocity.format;
    renderer.read_render_target(output, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!;
    gpu::invalidate_mapped_span(&renderer.device, probe.depth.span)!;
    gpu::invalidate_mapped_span(&renderer.device, probe.velocity.span)!;
    mem::copy(images.depth.ptr, probe.depth.bytes.ptr, images.depth.len * Vec4::size);
    mem::copy(images.velocity.ptr, probe.velocity.bytes.ptr, images.velocity.len * Vec4::size);
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

fn void check_crowd_native_coverage(CrowdNativeImages* images) @private {
    uint covered;
    uint[CROWD_NATIVE_INSTANCES] sources;
    foreach (index, depth : images.depth) {
        if (depth.x <= 0) continue;
        covered++;
        sources[(index % CROWD_NATIVE_WIDTH) * CROWD_NATIVE_INSTANCES / CROWD_NATIVE_WIDTH]++;
        Vec4 velocity = images.velocity[index];
        assert(math::abs(velocity.x) < CROWD_NATIVE_STILL_TOLERANCE);
        assert(math::abs(velocity.y) < CROWD_NATIVE_STILL_TOLERANCE);
        if (images.velocity_format == gpu::Format.RGBA16_FLOAT) assert(velocity.w == 0);
    }
    assert(covered > 0, "Crowd frame has empty depth coverage");
    foreach (count : sources) assert(count > 0, "A logical source has empty coverage");
}

fn void check_crowd_native_parity(CrowdNativeImages* crowd, CrowdNativeImages* ordinary) @private {
    check_crowd_native_coverage(crowd);
    check_crowd_native_coverage(ordinary);
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
    Transform[] placements,
) @private {
    pair.scene = scene::create_scene(allocator, { .max_nodes = CROWD_NATIVE_SCENE_NODES });
    defer catch scene::destroy_scene(&pair.scene);
    pair.model = model;
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    foreach (index, &instance : instances) {
        *instance = {
            .placement = placements[index],
            .pose = { .clip = clip, .time = 0, .speed = 0, .loop = false },
            .color = { 1, 1, 1, 1 },
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

fn void? crowd_native_stop_all(CrowdNativePair* pair) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(pair, source)!;
        CrowdPlaybackSlot* slot = &player.state.slots[source];
        while (slot.action_count) player.stop(slot.order[slot.action_count - 1])!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        while (animator.action_count) animator.stop(animator.order[animator.action_count - 1])!;
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
