module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::math;

const usz INDIRECT_REPLAY_COMMAND_STRIDE @private = 32;
const uint[3][2] INDIRECT_REPLAY_QUATERNIUS_INDICES @private = {
    { 17196, 8598, 4299 },
    { 24036, 12018, 6009 },
};

struct IndirectReplayCommand @private {
    uint level;
    uint representation;
    bool mirrored;
    bool indexed;
    uint elements;
    usz command_offset;
    usz source_offset;
}

fn void check_indirect_replay(
    gpu::MappedGpuSpan readback,
    IndirectReplayCommand[] commands,
    LodSelection* selection,
    uint sources,
    uint selected_level,
    uint parts,
    bool sorted,
    ulong expected_triangles,
) @private {
    uint[] seen = alloc::new_array(tmem, uint, (sz)selection.part_mirrored.len * sources);
    ulong triangles;
    uint visible_instances;
    foreach (command : commands) {
        uint elements;
        uint count;
        if (command.indexed) {
            gpu::DrawIndexedIndirectCommand* args =
              (gpu::DrawIndexedIndirectCommand*)(readback.bytes.ptr + command.command_offset);
            elements = args.index_count;
            count = args.instance_count;
        } else {
            gpu::DrawIndirectCommand* args = (gpu::DrawIndirectCommand*)(readback.bytes.ptr + command.command_offset);
            elements = args.vertex_count;
            count = args.instance_count;
        }
        assert(elements == command.elements && elements % 3 == 0);
        bool[] mirrored = selection.part_mirrored[command.representation];
        uint expected;
        if (command.level == selected_level) {
            foreach (source_mirrored : mirrored[:sources]) if (source_mirrored == command.mirrored) expected++;
        }
        assert(count == expected);
        uint previous = uint::max;
        foreach (source : ((uint*)(readback.bytes.ptr + command.source_offset))[:count]) {
            assert(source < sources && mirrored[source] == command.mirrored);
            assert(++seen[command.representation * sources + source] == 1);
            assert(!sorted || source < previous, "Blend sort lost the far-to-near source order");
            previous = source;
        }
        triangles += (ulong)(elements / 3) * count;
        visible_instances += count;
    }

    uint represented;
    for (uint representation = 0; representation < selection.part_mirrored.len; representation++) {
        uint listed;
        foreach (count : seen[representation * sources:sources]) listed += count;
        assert(listed == 0 || listed == sources);
        if (listed) represented++;
    }
    assert(represented == parts && triangles == expected_triangles);
    uint* counters = (uint*)readback.bytes.ptr;
    assert(counters[0] == visible_instances);
    for (uint level = 0; level < scene::MAX_LOD_CHOICES; level++) {
        uint expected = level == selected_level ? sources : 0;
        assert(counters[1 + level] == expected && counters[1 + scene::MAX_LOD_CHOICES + level] == expected);
    }
}

fn void? capture_indirect_replay(
    Fixture* fixture,
    Scene* scene,
    Node* owner,
    Node* camera_node,
    ViewId view,
    uint selected_level,
    uint parts,
    ulong expected_triangles,
    bool sorted = false,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    @pool() {
        Camera camera = *scene.get(camera_node, Camera);
        CameraMatrices matrices = camera::derive_matrices(camera, camera_node.world, { TARGET_SIZE, TARGET_SIZE });
        LodSelection[] selections = render::prepare_lod_view(
            renderer: renderer,
            record: renderer.views.get(view),
            scene: scene,
            camera: camera,
            matrices: &matrices,
        )!;
        assert(selections.len == 1 && selections[0].node == owner && !selections[0].fallback);
        uint sources = scene.get(owner, AnimatedCrowd).count;
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene: scene,
            assets: &fixture.assets,
            camera: &matrices,
            layers: camera.layers,
            counts: &counts,
            lod: selections,
        );
        assert(counts.dangling == 0);
        CullRange[] ranges = alloc::new_array(tmem, CullRange, candidates.len);
        CullItem[] items = alloc::new_array(tmem, CullItem, candidates.len);
        IndirectReplayCommand[] commands = alloc::new_array(tmem, IndirectReplayCommand, candidates.len);
        foreach (index, &candidate : candidates) {
            assert(candidate.node == owner && candidate.lod == &selections[0]);
            GpuGeometry* geometry = render::resolve_geometry(renderer, candidate.geometry)!;
            items[index] = {
                .candidate = candidate,
                .geometry = geometry,
                .records = candidate.lod.instances.records,
                .frustum = &matrices.frustum,
                .range = &ranges[index],
                .main_view = true,
                .depth_axis = render::view_depth_axis(matrices.view),
            };
            commands[index] = {
                .level = candidate.lod_level,
                .representation = candidate.lod_part,
                .mirrored = candidate.mirrored,
                .indexed = geometry.layout.index_count > 0,
                .elements = geometry.layout.index_count ? geometry.layout.index_count : geometry.layout.vertex_count,
                .command_offset = render::CULL_COUNTER_BYTES + (usz)index * INDIRECT_REPLAY_COMMAND_STRIDE,
                .source_offset = render::CULL_COUNTER_BYTES + candidates.len * INDIRECT_REPLAY_COMMAND_STRIDE
                  + (usz)index * sources * uint::size,
            };
        }
        render::prepare_cull_stage(renderer, items, true)!;
        render::record_pending_copies(renderer, &renderer.commands)!;
        render::record_lod_selection(renderer, selections)!;
        render::record_instance_cull(renderer, items)!;
        render::record_instance_sort(renderer, items)!;
        CullArena* arena = &renderer.cull_arenas[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        gpu::AllocationDesc desc = {
            .size = render::CULL_COUNTER_BYTES + candidates.len
              * (INDIRECT_REPLAY_COMMAND_STRIDE + sources * uint::size),
            .alignment = render::STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics },
            .debug_name = "animated_lod_indirect_replay",
        };
        gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
        defer {
            render::wait_frames(renderer)!!;
            gpu::GpuAllocation allocation = readback.span.allocation();
            gpu::free_allocation(&renderer.device, &allocation)!!;
        }

        gpu::Barrier produced = { .before = { .compute }, .after = { .transfer } };
        gpu::cmd_barrier(&renderer.commands, &produced)!;
        gpu::BufferCopyDesc counters = {
            .src = arena.span.checked_subspan(0, render::CULL_COUNTER_BYTES)!,
            .dst = readback.span.checked_subspan(0, render::CULL_COUNTER_BYTES)!,
        };
        gpu::cmd_copy_buffer(&renderer.commands, &counters)!;
        foreach (index, item : items) {
            assert(item.range.culled);
            usz bytes = render::indirect_args_bytes(&item.geometry.layout);
            gpu::BufferCopyDesc command = {
                .src = item.range.args,
                .dst = readback.span.checked_subspan(commands[index].command_offset, bytes)!,
            };
            gpu::cmd_copy_buffer(&renderer.commands, &command)!;
            usz offset = (usz)((ulong)item.range.visible - (ulong)arena.address);
            gpu::BufferCopyDesc listed = {
                .src = arena.span.checked_subspan(offset, sources * uint::size)!,
                .dst = readback.span.checked_subspan(commands[index].source_offset, sources * uint::size)!,
            };
            gpu::cmd_copy_buffer(&renderer.commands, &listed)!;
        }
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!;
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
        check_indirect_replay(
            readback: readback,
            commands: commands,
            selection: &selections[0],
            sources: sources,
            selected_level: selected_level,
            parts: parts,
            sorted: sorted,
            expected_triangles: expected_triangles,
        );
    };
}

fn void configure_indirect_replay_bias(Fixture* fixture, ViewId view, float lod_bias) @private {
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.lod_bias = lod_bias;
    render::configure_view(&fixture.renderer, view, desc)!!;
}

fn void test_animated_lod_native_indirect_quaternius_three_levels_match_literal_counts() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    for (uint part = 0; part < animated_lod_fixtures::LOD_PRIMITIVES; part++) {
        for (uint level = 0; level < animated_lod_fixtures::LOD_LEVELS; level++) {
            assert(corpus.layouts[part][level].index_count == INDIRECT_REPLAY_QUATERNIUS_INDICES[part][level]);
        }
    }
    Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    LodNativeSubject subject = quaternius_lod_subject(&fixture, &corpus);
    float duration = fixture.assets.clip(subject.clip).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        instances[source] = {
            .placement = placements[source],
            .pose = {
                .clip = subject.clip,
                .time = (0.125f + 0.25f * (float)source) * duration,
                .speed = 0,
                .loop = true,
            },
            .color = { 1, 1, 1, 1 },
        };
    }
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &scene,
        model: corpus.model,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: CROWD_LOD_NATIVE_BOUNDS,
        instances: instances[..],
    )!!;
    LodNativeDescriptor descriptor;
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &scene,
        owner: owner,
        desc: lod_native_desc(
            fixture: &fixture,
            subject: &subject,
            descriptor: &descriptor,
            crowd: true,
        ),
    )!!;
    Node* camera = scene.add_camera(camera::orthographic(6, 0.1f, 100))!!;
    camera.local.position = { 0, 1, 12 };
    scene.update_world();
    for (uint level = 0; level < animated_lod_fixtures::LOD_LEVELS; level++) {
        ViewId view = level == 1 ? fixture.second_view : fixture.view;
        configure_indirect_replay_bias(&fixture, view, lod_native_force_bias(&subject, level));
        ulong triangles = (ulong)(INDIRECT_REPLAY_QUATERNIUS_INDICES[0][level]
          + INDIRECT_REPLAY_QUATERNIUS_INDICES[1][level]) / 3 * CROWD_NATIVE_INSTANCES;
        capture_indirect_replay(
            fixture: &fixture,
            scene: &scene,
            owner: owner,
            camera_node: camera,
            view: view,
            selected_level: level,
            parts: animated_lod_fixtures::LOD_PRIMITIVES,
            expected_triangles: triangles,
        )!!;
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animated_lod_native_indirect_mixed_equal_count_parity_and_blend_sort_keep_sources() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        instances[source] = {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = parts.posing, .time = 0.25f * (float)(source + 1), .speed = 0, .loop = false },
            .color = { 1, 1, 1, 1 },
        };
        instances[source].placement.position = { 30 * (float)source, 0, -3 * (float)source };
    }
    instances[1].placement.scale = { -1, 2, 1 };
    instances[2].placement.scale = { 1.3f, 0.9f, 1.1f };
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &scene,
        model: parts.mixed,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    Node* camera = scene.add_camera(camera::orthographic(120, 0.1f, 1000))!!;
    camera.local.position = { 35, 2, 20 };
    scene.update_world();
    configure_indirect_replay_bias(&fixture, fixture.view, 16);
    capture_indirect_replay(
        fixture: &fixture,
        scene: &scene,
        owner: owner,
        camera_node: camera,
        view: fixture.view,
        selected_level: 0,
        parts: animated_crowd_fixtures::PARTS_MESH_COUNT,
        expected_triangles: 15,
    )!!;

    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    crowd.placements[0].scale.x = -1;
    crowd.placements[1].scale.x = 1;
    crowd.placements[2].scale.x = -1.3f;
    scene.write_crowd_batches(crowd);
    fixture.assets.material(parts.material).data.common.alpha_mode = AlphaMode.BLEND;
    fixture.assets.mark_material_dirty(parts.material);
    configure_indirect_replay_bias(&fixture, fixture.view, -16);
    capture_indirect_replay(
        fixture: &fixture,
        scene: &scene,
        owner: owner,
        camera_node: camera,
        view: fixture.view,
        selected_level: 1,
        parts: animated_crowd_fixtures::PARTS_MESH_COUNT,
        expected_triangles: 15,
        sorted: true,
    )!!;
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animated_lod_native_sheared_near_singular_part_uses_shared_cpu_parity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    ModelMesh mesh = fixture.assets.model(parts.mixed).data.meshes[1];
    Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        instances[source] = {
            .placement = {
                .position = { (float)source - 1, 0, 0 },
                .rotation = quaternion::from_euler(0.0f, 0.0f, 0.37f + 0.41f * (float)source),
                .scale = { source == 2 ? -1 : 1, 3, 0.7f },
            },
            .pose = { .clip = parts.posing, .speed = 0 },
            .color = { 1, 1, 1, 1 },
        };
    }
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &scene,
        model: parts.mixed,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    Mat4 near_singular = matrix::IDENTITY4;
    near_singular.m10 = 1;
    near_singular.m01 = 1;
    near_singular.m11 = bitcast(0x3f800001u, float);
    assert(near_singular.determinant() > 0 && near_singular.determinant() < 1e-6f);
    @pool() {
        AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed);
        LodLevel[2] levels = {
            { .first_part = 0, .part_count = animated_crowd_fixtures::PARTS_MESH_COUNT, .min_screen_size = 0.5f },
            { .first_part = animated_crowd_fixtures::PARTS_MESH_COUNT, .part_count = 1 },
        };
        desc.parts[animated_crowd_fixtures::PARTS_MESH_COUNT] = {
            .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = near_singular },
            .mesh_index = 1,
        };
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &scene,
            owner: owner,
            desc: {
                .levels = levels[..],
                .parts = desc.parts[:animated_crowd_fixtures::PARTS_MESH_COUNT + 1],
            },
        )!!;
    };
    Node* parent = scene.add_node()!!;
    parent.local.scale = { 2, 3, 1 };
    owner.local.rotation = quaternion::from_euler(0.0f, 0.0f, 0.4f);
    scene.reparent(owner, parent);
    Node* camera_node = scene.add_camera(camera::orthographic(100, 0.1f, 100))!!;
    camera_node.local.position = { 0, 0, 30 };
    anim::crowd_update(&fixture.assets, &scene, 0);
    scene.update_world();
    Vec3 axis_x = { owner.world.m00, owner.world.m10, owner.world.m20 };
    Vec3 axis_y = { owner.world.m01, owner.world.m11, owner.world.m21 };
    assert(math::abs(axis_x.dot(axis_y)) > 0.1f, "Placement hierarchy must contain affine shear");
    for (uint level = 0; level < 2; level++) {
        configure_indirect_replay_bias(&fixture, fixture.view, level == 0 ? 16 : -16);
        uint level_parts = level == 0 ? animated_crowd_fixtures::PARTS_MESH_COUNT : 1;
        capture_indirect_replay(
            fixture: &fixture,
            scene: &scene,
            owner: owner,
            camera_node: camera_node,
            view: fixture.view,
            selected_level: level,
            parts: level_parts,
            expected_triangles: (ulong)level_parts * CROWD_NATIVE_INSTANCES,
        )!!;
    }
    check_crowd_native_validation(&fixture.renderer);
}
