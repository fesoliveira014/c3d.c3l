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
import c3d::shader;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::io;
import std::math;

const uint INDIRECT_REPLAY_SOURCES @private = 3;
const usz INDIRECT_REPLAY_COMMAND_STRIDE @private = 32;
const uint[3][2] INDIRECT_REPLAY_QUATERNIUS_INDICES @private = {
    { 17196, 8598, 4299 },
    { 24036, 12018, 6009 },
};

struct IndirectReplayCommand @private {
    GeometryId geometry;
    uint level;
    uint representation;
    uint logical_part;
    bool mirrored;
    bool indexed;
    uint elements;
    usz command_offset;
    usz source_offset;
}

fn bool indirect_replay_matches(
    gpu::MappedGpuSpan readback,
    IndirectReplayCommand[] commands,
    CrowdInstance[] instances,
    uint selected_level,
    uint parts,
    bool sorted,
    ulong expected_triangles,
) @private {
    uint[] seen = alloc::new_array(tmem, uint, (sz)parts * instances.len);
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
        if (elements != command.elements || elements % 3 || count > instances.len) return false;
        uint expected;
        if (command.level == selected_level) {
            foreach (instance : instances) {
                Vec3 scale = instance.placement.scale;
                bool mirrored = scale.x * scale.y * scale.z < 0;
                if (mirrored == command.mirrored) expected++;
            }
        }
        if (count != expected || command.logical_part >= parts) return false;
        uint[] sources = ((uint*)(readback.bytes.ptr + command.source_offset))[:count];
        uint previous = uint::max;
        foreach (source : sources) {
            if (source >= instances.len) return false;
            Vec3 scale = instances[source].placement.scale;
            if ((scale.x * scale.y * scale.z < 0) != command.mirrored) return false;
            if (++seen[command.logical_part * instances.len + source] != 1) return false;
            if (sorted && source >= previous) return false;
            previous = source;
        }
        triangles += (ulong)(elements / 3) * count;
        visible_instances += count;
        io::eprintfn(
            "diagnostic_cull_replay geometry=%s/%s level=%s representation=%s logical_part=%s "
            "mirrored=%s indexed=%s elements=%s instances=%s triangles=%s",
            command.geometry.index,
            command.geometry.generation,
            command.level,
            command.representation,
            command.logical_part,
            command.mirrored,
            command.indexed,
            elements,
            count,
            (ulong)(elements / 3) * count,
        );
    }
    foreach (count : seen) if (count != 1) return false;
    if (triangles != expected_triangles || visible_instances != parts * instances.len) return false;
    uint* counters = (uint*)readback.bytes.ptr;
    if (counters[0] != visible_instances) return false;
    for (uint level = 0; level < scene::MAX_LOD_CHOICES; level++) {
        uint expected = level == selected_level ? (uint)instances.len : 0;
        if (counters[1 + level] != expected
          || counters[1 + scene::MAX_LOD_CHOICES + level] != expected) return false;
    }
    io::eprintfn("diagnostic_cull_replay total_indirect_triangles=%s selected_level=%s sources=%s parts=%s",
        triangles, selected_level, instances.len, parts);
    return true;
}

fn void? overwrite_indirect_replay_level(Renderer* renderer, LodSelection* selection) @private {
    gpu::Barrier selected = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &selected)!;
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan wrong = frame.upload.take(&renderer.device, uint::size, render::STREAM_ALIGNMENT)!;
    *(uint*)wrong.bytes.ptr = 0;
    gpu::GpuSpan history = gpu::get_allocation_span(&renderer.device, selection.history.allocation)!;
    usz current = (usz)(selection.history.committed_slot ^ 1)
      * selection.history.capacity * shader::LodHistoryGpu::size;
    for (uint source = 0; source < selection.state.count; source++) {
        usz offset = current + (usz)source * shader::LodHistoryGpu::size
          + $reflect(shader::LodHistoryGpu.level).offset;
        gpu::BufferCopyDesc copy = {
            .src = wrong.span,
            .dst = history.checked_subspan(offset, uint::size)!,
        };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    }
    gpu::Barrier overridden = { .before = { .transfer }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &overridden)!;
}

fn bool? capture_indirect_replay(
    Fixture* fixture,
    Scene* scene,
    Node* owner,
    Node* camera_node,
    ViewId view,
    CrowdInstance[] instances,
    uint selected_level,
    uint parts,
    ulong expected_triangles,
    bool sorted = false,
    bool wrong_selected_level = false,
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
        foreach (instance : instances) {
            assert(render::instance_visible(
                frustum: &matrices.frustum,
                local_bounds: scene.get(owner, AnimatedCrowd).pose_bounds,
                model: owner.world.mul(instance.placement.to_mat4()),
            ));
        }
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
            assert(candidate.node == owner && candidate.animated_lod && candidate.lod == &selections[0]);
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
                .geometry = candidate.geometry,
                .level = candidate.lod_level,
                .representation = candidate.lod_part,
                .logical_part = candidate.animated_lod.mesh_index,
                .mirrored = candidate.mirrored,
                .indexed = geometry.layout.index_count > 0,
                .elements = geometry.layout.index_count ? geometry.layout.index_count : geometry.layout.vertex_count,
                .command_offset = render::CULL_COUNTER_BYTES + index * INDIRECT_REPLAY_COMMAND_STRIDE,
                .source_offset = render::CULL_COUNTER_BYTES + candidates.len * INDIRECT_REPLAY_COMMAND_STRIDE
                  + index * instances.len * uint::size,
            };
        }
        render::prepare_cull_stage(renderer, items, true)!;
        render::record_pending_copies(renderer, &renderer.commands)!;
        render::record_lod_selection(renderer, selections)!;
        if (wrong_selected_level) overwrite_indirect_replay_level(renderer, &selections[0])!;
        render::record_instance_cull(renderer, items)!;
        render::record_instance_sort(renderer, items)!;
        CullArena* arena = &renderer.cull_arenas[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        gpu::AllocationDesc desc = {
            .size = render::CULL_COUNTER_BYTES + candidates.len
              * (INDIRECT_REPLAY_COMMAND_STRIDE + instances.len * uint::size),
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
            gpu::BufferCopyDesc sources = {
                .src = arena.span.checked_subspan(offset, instances.len * uint::size)!,
                .dst = readback.span.checked_subspan(commands[index].source_offset, instances.len * uint::size)!,
            };
            gpu::cmd_copy_buffer(&renderer.commands, &sources)!;
        }
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!;
        ulong submission = renderer.frame_index;
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
        io::eprintfn("diagnostic_cull_replay submission=%s view=%s/%s wrong_level=%s sorted=%s",
            submission, view.index, view.generation, wrong_selected_level, sorted);
        return indirect_replay_matches(
            readback: readback,
            commands: commands,
            instances: instances,
            selected_level: selected_level,
            parts: parts,
            sorted: sorted,
            expected_triangles: expected_triangles,
        );
    };
}

fn void test_animated_lod_native_indirect_quaternius_three_levels_match_literal_counts() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    for (uint part = 0; part < 2; part++) {
        for (uint level = 0; level < 3; level++) {
            assert(corpus.layouts[part][level].index_count == INDIRECT_REPLAY_QUATERNIUS_INDICES[part][level]);
        }
    }
    Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    ClipId clip = crowd_native_clip_named(&fixture, corpus.model, "Walk_Loop")!!;
    float duration = fixture.assets.clip(clip).data.duration;
    Transform[3] placements = crowd_native_real_placements();
    CrowdInstance[3] instances;
    for (uint source = 0; source < 3; source++) {
        instances[source] = {
            .placement = placements[source],
            .pose = { .clip = clip, .time = (0.125f + 0.25f * (float)source) * duration, .speed = 0, .loop = true },
            .color = { 1, 1, 1, 1 },
        };
    }
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &scene,
        model: corpus.model,
        capacity: 3,
        pose_bounds: CROWD_LOD_NATIVE_BOUNDS,
        instances: instances[..],
    )!!;
    CrowdLodNativeDescriptor descriptor;
    fill_crowd_lod_native_descriptor(
        fixture: &fixture,
        corpus: &corpus,
        descriptor: &descriptor,
        material: {},
    );
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &scene,
        owner: owner,
        desc: crowd_lod_native_desc(&descriptor),
    )!!;
    Node* camera = scene.add_camera(camera::orthographic(6, 0.1f, 100))!!;
    camera.local.position = { 0, 1, 12 };
    scene.update_world();
    for (uint level = 0; level < 3; level++) {
        ViewId view = level == 1 ? fixture.second_view : fixture.view;
        ViewDesc desc = fixture.renderer.views.get(view).desc;
        desc.lod_bias = CROWD_LOD_NATIVE_FORCE_BIASES[level];
        render::configure_view(&fixture.renderer, view, desc)!!;
        ulong triangles = (ulong)(INDIRECT_REPLAY_QUATERNIUS_INDICES[0][level]
          + INDIRECT_REPLAY_QUATERNIUS_INDICES[1][level]) / 3 * INDIRECT_REPLAY_SOURCES;
        assert(capture_indirect_replay(
            fixture: &fixture,
            scene: &scene,
            owner: owner,
            camera_node: camera,
            view: view,
            instances: instances[..],
            selected_level: level,
            parts: (uint)template.meshes.len,
            expected_triangles: triangles,
        )!!);
    }
    ulong triangles = (ulong)(INDIRECT_REPLAY_QUATERNIUS_INDICES[0][2]
      + INDIRECT_REPLAY_QUATERNIUS_INDICES[1][2]) / 3 * INDIRECT_REPLAY_SOURCES;
    assert(!capture_indirect_replay(
        fixture: &fixture,
        scene: &scene,
        owner: owner,
        camera_node: camera,
        view: fixture.view,
        instances: instances[..],
        selected_level: 2,
        parts: 2,
        expected_triangles: triangles,
        wrong_selected_level: true,
    )!!);
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animated_lod_native_indirect_mixed_equal_count_parity_and_blend_sort_keep_sources() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    CrowdInstance[3] instances;
    for (uint source = 0; source < 3; source++) {
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
        capacity: 3,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &scene,
            owner: owner,
            desc: lod_trace_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    Node* camera = scene.add_camera(camera::orthographic(120, 0.1f, 1000))!!;
    camera.local.position = { 35, 2, 20 };
    scene.update_world();
    LodGroupState* state = scene.get(owner, LodGroup).state;
    ulong identity = state.identity;
    uint generation = state.slot_generations[0];
    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.lod_bias = 16;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    assert(capture_indirect_replay(
        fixture: &fixture,
        scene: &scene,
        owner: owner,
        camera_node: camera,
        view: fixture.view,
        instances: instances[..],
        selected_level: 0,
        parts: 5,
        expected_triangles: 15,
    )!!);
    instances[0].placement.scale.x = -1;
    instances[1].placement.scale.x = 1;
    instances[2].placement.scale.x = -1.3f;
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    for (uint source = 0; source < 3; source++) crowd.placements[source] = instances[source].placement;
    scene.write_crowd_batches(crowd);
    fixture.assets.material(parts.material).data.common.alpha_mode = AlphaMode.BLEND;
    fixture.assets.mark_material_dirty(parts.material);
    desc.lod_bias = -16;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    assert(capture_indirect_replay(
        fixture: &fixture,
        scene: &scene,
        owner: owner,
        camera_node: camera,
        view: fixture.view,
        instances: instances[..],
        selected_level: 1,
        parts: 5,
        expected_triangles: 15,
        sorted: true,
    )!!);
    assert(state.identity == identity && state.count == 3 && state.slot_generations[0] == generation);
    assert(c3d::same_id(state.desc.parts[2].geometry, state.desc.parts[3].geometry));
    check_crowd_native_validation(&fixture.renderer);
}
