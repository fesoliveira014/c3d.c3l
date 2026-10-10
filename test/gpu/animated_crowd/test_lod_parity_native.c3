module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::io;
import std::math;

const uint PARITY_NATIVE_GUARD_WORDS @private = 4;
const uint PARITY_NATIVE_GUARD_VALUE @private = 0xa719c3ef;
const usz PARITY_NATIVE_COMMAND_STRIDE @private = 32;

fn void? capture_animated_lod_native_guarded_parity(
    Fixture* fixture,
    Scene* scene,
    Node* owner,
    Node* camera_node,
    uint selected_level,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    @pool() {
        Camera camera = *scene.get(camera_node, Camera);
        CameraMatrices matrices = camera::derive_matrices(camera, camera_node.world, { TARGET_SIZE, TARGET_SIZE });
        LodSelection[] selections = render::prepare_lod_view(
            renderer: renderer,
            record: renderer.views.get(fixture.view),
            scene: scene,
            camera: camera,
            matrices: &matrices,
        )!;
        assert(selections.len == 1 && !selections[0].fallback && selections[0].node == owner);
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
        assert(counts.dangling == 0 && candidates.len > 0);
        CullRange[] ranges = alloc::new_array(tmem, CullRange, candidates.len);
        CullItem[] items = alloc::new_array(tmem, CullItem, candidates.len);
        gpu::MappedGpuSpan[] guarded = alloc::new_array(tmem, gpu::MappedGpuSpan, candidates.len);
        defer {
            render::wait_frames(renderer)!!;
            foreach (span : guarded) {
                gpu::GpuAllocation allocation = span.span.allocation();
                if (!allocation.is_valid()) continue;
                gpu::free_allocation(&renderer.device, &allocation)!!;
            }
        }
        foreach (index, &candidate : candidates) {
            assert(candidate.node == owner && candidate.animated_lod && candidate.instance_count > 0);
            items[index] = {
                .candidate = candidate,
                .geometry = render::resolve_geometry(renderer, candidate.geometry)!,
                .records = candidate.lod.instances.records,
                .frustum = &matrices.frustum,
                .range = &ranges[index],
                .main_view = true,
                .depth_axis = render::view_depth_axis(matrices.view),
            };
        }
        render::prepare_cull_stage(renderer, items, false)!;
        Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        foreach (index, &item : items) {
            uint capacity = item.candidate.instance_count;
            usz bytes = ((usz)capacity + 2 * PARITY_NATIVE_GUARD_WORDS) * uint::size;
            gpu::AllocationDesc allocation_desc = {
                .size = bytes,
                .alignment = render::STREAM_ALIGNMENT,
                .memory_class = gpu::MemoryClass.CPU_READ,
                .access = { .graphics },
                .debug_name = "animated_lod_parity_guard",
            };
            guarded[index] = gpu::allocate_mapped_memory(&renderer.device, &allocation_desc)!;
            gpu::MappedGpuSpan initial = frame.upload.take(&renderer.device, bytes, render::STREAM_ALIGNMENT)!;
            uint[] initial_words = ((uint*)initial.bytes.ptr)[:bytes / uint::size];
            initial_words[..] = PARITY_NATIVE_GUARD_VALUE;
            renderer.pending_copies.push({ .src = initial.span, .dst = guarded[index].span });
            item.range.visible = (gpu::GpuAddress)((ulong)guarded[index].address
              + (usz)PARITY_NATIVE_GUARD_WORDS * uint::size);
        }
        render::record_pending_copies(renderer, &renderer.commands)!;
        render::record_lod_selection(renderer, selections)!;
        render::record_instance_cull(renderer, items)!;
        gpu::AllocationDesc readback_desc = {
            .size = candidates.len * PARITY_NATIVE_COMMAND_STRIDE,
            .alignment = render::STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics },
            .debug_name = "animated_lod_parity_commands",
        };
        gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
        defer {
            render::wait_frames(renderer)!!;
            gpu::GpuAllocation allocation = readback.span.allocation();
            gpu::free_allocation(&renderer.device, &allocation)!!;
        }
        gpu::Barrier produced = { .before = { .compute }, .after = { .transfer, .host } };
        gpu::cmd_barrier(&renderer.commands, &produced)!;
        foreach (index, item : items) {
            gpu::BufferCopyDesc command = {
                .src = item.range.args,
                .dst = readback.span.checked_subspan(
                    offset: (usz)index * PARITY_NATIVE_COMMAND_STRIDE,
                    size: render::indirect_args_bytes(&item.geometry.layout),
                )!,
            };
            gpu::cmd_copy_buffer(&renderer.commands, &command)!;
        }
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!;
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
        uint total;
        foreach (index, candidate : candidates) {
            uint* command = (uint*)(readback.bytes.ptr + (usz)index * PARITY_NATIVE_COMMAND_STRIDE);
            uint expected = candidate.lod_level == selected_level ? candidate.instance_count : 0;
            assert(command[1] == expected);
            gpu::invalidate_mapped_span(&renderer.device, guarded[index].span)!;
            uint[] words = ((uint*)guarded[index].bytes.ptr)[:guarded[index].bytes.len / uint::size];
            for (uint guard = 0; guard < PARITY_NATIVE_GUARD_WORDS; guard++) {
                assert(words[guard] == PARITY_NATIVE_GUARD_VALUE);
                assert(words[PARITY_NATIVE_GUARD_WORDS + candidate.instance_count + guard]
                    == PARITY_NATIVE_GUARD_VALUE, "Animated LOD visible-list overrun");
            }
            bool[CROWD_NATIVE_INSTANCES] seen;
            for (uint listed = 0; listed < expected; listed++) {
                uint source = words[PARITY_NATIVE_GUARD_WORDS + listed];
                assert(source < CROWD_NATIVE_INSTANCES && !seen[source]);
                seen[source] = true;
                assert(selections[0].part_mirrored[candidate.lod_part][source] == candidate.mirrored);
            }
            total += expected;
        }
        uint expected_total = selected_level == 0 ? 15u : 3u;
        assert(total == expected_total);
        assert(renderer.stats.cull_overflows == 0 && renderer.stats.lod_fallbacks == 0);
        io::printfn("guarded parity level=%s listed=%s prefix/suffix canaries intact", selected_level, total);
    };
}

fn void test_animated_lod_native_sheared_near_singular_part_uses_shared_cpu_parity_and_keeps_guards() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    ModelTemplate* template = &fixture.assets.model(parts.mixed).data;
    assert(template.meshes.len == animated_crowd_fixtures::PARTS_MESH_COUNT);
    ModelMesh mesh = template.meshes[1];
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
    near_singular.m00 = 1;
    near_singular.m10 = 1;
    near_singular.m01 = 1;
    near_singular.m11 = bitcast(0x3f800001u, float);
    assert(near_singular.determinant() > 0 && near_singular.determinant() < 1e-6f);
    LodLevel[2] levels = {
        {
            .first_part = 0,
            .part_count = animated_crowd_fixtures::PARTS_MESH_COUNT,
            .min_screen_size = 0.5f,
        },
        { .first_part = animated_crowd_fixtures::PARTS_MESH_COUNT, .part_count = 1 },
    };
    AnimatedLodPart[animated_crowd_fixtures::PARTS_MESH_COUNT + 1] alternatives;
    foreach (uint index, source_mesh : template.meshes) {
        ModelSkin skin;
        foreach (source_skin : template.skins) {
            if (source_skin.mesh_node == source_mesh.node) skin = source_skin;
        }
        alternatives[index] = {
            .draw = {
                .geometry = source_mesh.geometry,
                .material = source_mesh.material,
                .local = matrix::IDENTITY4,
            },
            .mesh_index = index,
            .skin = skin,
            .default_morph_weights = source_mesh.default_morph_weights,
        };
    }
    alternatives[animated_crowd_fixtures::PARTS_MESH_COUNT] = {
        .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = near_singular },
        .mesh_index = 1,
    };
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &scene,
        owner: owner,
        desc: { .levels = levels[..], .parts = alternatives[..] },
    )!!;
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
        ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
        desc.lod_bias = level == 0 ? 16 : -16;
        render::configure_view(&fixture.renderer, fixture.view, desc)!!;
        capture_animated_lod_native_guarded_parity(
            fixture: &fixture,
            scene: &scene,
            owner: owner,
            camera_node: camera_node,
            selected_level: level,
        )!!;
    }
    check_crowd_native_validation(&fixture.renderer);
}
