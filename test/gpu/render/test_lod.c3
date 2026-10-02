module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import gpu;
import std::math;

const uint LOD_PLACEMENTS @private = 12;
const float[3] LOD_DISTANCES @private = { 4, 10, 24 };
const Vec4[3] LOD_COLORS @private = { RED, GREEN, BLUE };
const uint LOD_EFFECT_SIZE @private = 512;

struct LodVelocityProbe @private {
    gpu::MappedGpuSpan readback;
    BufferId output;
    ComputeShaderId shader;
}

fn DeformedScene? create_lod_scene(Fixture* fixture, bool single = false, bool thin_middle = false) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    LodLevel[3] levels = {
        { .first_part = 0, .part_count = 2, .min_screen_size = 0.25f },
        { .first_part = 2, .part_count = 1, .min_screen_size = 0.1f },
        { .first_part = 3, .part_count = 3, .min_screen_size = 0 },
    };
    MaterialId[3] materials;
    foreach (index, &material : materials) *material = fixture.assets.add_material(material::basic({ .color = LOD_COLORS[index] }))!;
    GeometryId[3] geometries = { fixture.box, {}, {} };
    @pool() {
        Geometry divided = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
            segments: 2,
        );
        geometries[1] = fixture.assets.add_geometry(&divided)!;
        Geometry* box = &fixture.assets.geometry(fixture.box).data;
        Geometry expanded = { .positions = alloc::new_array(tmem, Vec3, box.indices.len), .bounds = box.bounds };
        foreach (index, vertex : box.indices) expanded.positions[index] = box.positions[vertex];
        geometries[2] = fixture.assets.add_geometry(&expanded)!;
    };
    LodPart[6] parts;
    foreach (index, level : levels) {
        foreach (uint part_index, &part : parts[level.first_part:level.part_count]) {
            Transform local = maths::TRANSFORM_IDENTITY;
            local.scale.x = 1.0f / (float)level.part_count;
            local.position.x = ((float)part_index + 0.5f) * local.scale.x - 0.5f;
            if (part_index + 1 == level.part_count) local.scale.x = -local.scale.x;
            if (thin_middle && index == 1) local.scale.x *= 0.2f;
            *part = { .geometry = geometries[(level.first_part + part_index) % 3], .material = materials[index], .local = local.to_mat4() };
        }
    }
    Transform[LOD_PLACEMENTS] transforms;
    foreach (uint index, &transform : transforms) {
        uint band = index / 4;
        float distance = LOD_DISTANCES[band];
        *transform = maths::TRANSFORM_IDENTITY;
        transform.position = { ((float)(index % 4) - 1.5f) * distance * 0.15f, ((float)band - 1) * distance * 0.2f, 3 - distance };
        if (index % 4 == 2) transform.scale.x = -1;
    }
    LodDesc desc = { .levels = levels[..], .parts = parts[..] };
    result.mesh = single ? result.scene.add_lod_group(&fixture.assets, desc)!
      : result.scene.add_instanced_lod_group(
            assets: &fixture.assets,
            desc: desc,
            capacity: LOD_PLACEMENTS,
            transforms: transforms[..],
        )!;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn gpu::MappedGpuSpan? create_lod_readback(Renderer* renderer) @private {
    gpu::AllocationDesc desc = {
        .size = LOD_PLACEMENTS * LodHistoryGpu::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "lod_readback",
    };
    return gpu::allocate_mapped_memory(&renderer.device, &desc);
}

fn void free_lod_readback(Renderer* renderer, gpu::MappedGpuSpan readback) @private {
    render::wait_frames(renderer)!!;
    gpu::GpuAllocation allocation = readback.span.allocation();
    gpu::free_allocation(&renderer.device, &allocation)!!;
}

fn void check_lod_bin_lists(Fixture* fixture, DeformedScene* target, bool sorted = false) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!!;
    @pool() {
        Camera camera = *target.scene.get(target.camera, Camera);
        CameraMatrices matrices = camera::derive_matrices(camera, target.camera.world, { TARGET_SIZE, TARGET_SIZE });
        render::LodSelection[] selections = render::prepare_lod_view(
            renderer: renderer,
            record: renderer.views.get(fixture.view),
            scene: &target.scene,
            camera: camera,
            matrices: &matrices,
        )!!;
        assert(selections.len == 1 && selections[0].node == target.mesh);
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene: &target.scene,
            assets: &fixture.assets,
            camera: &matrices,
            layers: camera.layers,
            counts: &counts,
            lod: selections,
        );
        render::CullItem[] items = alloc::new_array(tmem, render::CullItem, candidates.len);
        CullRange[] ranges = alloc::new_array(tmem, CullRange, candidates.len);
        foreach (index, &candidate : candidates) {
            items[index] = {
                .candidate = candidate,
                .geometry = render::resolve_geometry(renderer, candidate.geometry)!!,
                .records = candidate.lod.instances.records,
                .frustum = &matrices.frustum,
                .range = &ranges[index],
                .main_view = true,
                .depth_axis = render::view_depth_axis(matrices.view),
            };
        }
        render::prepare_cull_stage(renderer, items, true)!!;
        render::record_pending_copies(renderer, &renderer.commands)!!;
        render::record_lod_selection(renderer, selections)!!;
        render::record_instance_cull(renderer, items)!!;
        render::record_instance_sort(renderer, items)!!;
        render::CullArena* arena = &renderer.cull_arenas[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        gpu::AllocationDesc desc = {
            .size = arena.head, .alignment = render::STREAM_ALIGNMENT, .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics }, .debug_name = "lod_bins_readback",
        };
        gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!!;
        defer free_lod_readback(renderer, readback);
        gpu::Barrier produced = { .before = { .compute }, .after = { .transfer } };
        gpu::cmd_barrier(&renderer.commands, &produced)!!;
        gpu::BufferCopyDesc copy = { .src = arena.span.checked_subspan(0, arena.head)!!, .dst = readback.span };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!!;
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!!;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;
        uint[LOD_PLACEMENTS] seen;
        render::LodSelection* selected = &selections[0];
        foreach (bin : selected.bins[:selected.bin_count]) {
            usz args_offset = (usz)((ulong)bin.args - (ulong)arena.address);
            uint count = ((uint*)(readback.bytes.ptr + args_offset))[1];
            assert(count == (bin.mirrored ? 1 : 3));
            usz list_offset = (usz)((ulong)bin.visible - (ulong)arena.address);
            uint previous = uint::max;
            foreach (source : ((uint*)(readback.bytes.ptr + list_offset))[:count]) {
                assert(source < LOD_PLACEMENTS && source / 4 == bin.level);
                assert((source % 4 == 2) == bin.mirrored && seen[source] == 0);
                seen[source]++;
                if (sorted) {
                    assert(source < previous);
                    previous = source;
                }
            }
            foreach (item : items) {
                if (item.candidate.lod_level != bin.level || item.candidate.mirrored != bin.mirrored) continue;
                assert(item.range.visible == bin.visible);
                usz part_offset = (usz)((ulong)item.args_address - (ulong)arena.address);
                uint* command = (uint*)(readback.bytes.ptr + part_offset);
                assert(command[1] == count);
                assert(command[0] == (item.geometry.layout.index_count ? item.geometry.layout.index_count : item.geometry.layout.vertex_count));
            }
        }
        foreach (count : seen) assert(count == 1);
    };
}

fn void test_lod_effect_edits_reuse_placement_uploads() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_lod_readback(&fixture.renderer)!!;
    defer free_lod_readback(&fixture.renderer, readback);
    LodGroupState* state = target.scene.get(target.mesh, LodGroup).state;
    for (uint frame = 0; frame < 10; frame++) {
        LodEffects effects = state.effects;
        effects.sway.direction = { 1, 0, 0 };
        effects.sway.amplitude = (float)frame * 0.01f;
        target.scene.set_lod_effects(target.mesh, effects);
        render_lod_frame(
            fixture: &fixture,
            target: &target,
            view: fixture.view,
            readback: readback,
        )!!;
        if (frame > render::FRAMES_IN_FLIGHT) assert(fixture.renderer.stats.upload_bytes == 0);
    }
}

fn void test_lod_blended_parts_share_sorted_indices() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LodGroupState* state = target.scene.get(target.mesh, LodGroup).state;
    foreach (level : state.desc.levels) {
        MaterialId id = state.desc.parts[level.first_part].material;
        Material* material = &fixture.assets.material(id).data;
        material.common.alpha_mode = AlphaMode.BLEND;
        material.basic.color.w = 0.5f;
        fixture.assets.mark_material_dirty(id);
    }
    foreach (uint index, &transform : state.transforms[:state.count]) transform.position.z -= 0.05f * (float)(index % 4);
    target.scene.mark_lod_instances_dirty(target.mesh);
    check_lod_bin_lists(&fixture, &target, true);
    assert(fixture.renderer.stats.sort_dispatches == 6);
    check_validation(&fixture.renderer);
}

fn uint? render_lod_frame(
    Fixture* fixture,
    DeformedScene* target,
    ViewId view,
    gpu::MappedGpuSpan readback,
    Vec2 uv = CENTER_UV,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, target.camera, view)!;
    render::LodHistoryEntry* history = &renderer.views.get(view).lod_history.entries[target.mesh.id.index];
    if (history.allocation.is_valid() && history.pending.valid) {
        usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * LodHistoryGpu::size;
        gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, history.allocation)!;
        gpu::Barrier produced = { .before = { .compute, .vertex_shader }, .after = { .transfer } };
        gpu::cmd_barrier(&renderer.commands, &produced)!;
        gpu::BufferCopyDesc copy = { .src = source.checked_subspan(offset, readback.bytes.len)!, .dst = readback.span };
        gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
        gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
        gpu::cmd_barrier(&renderer.commands, &copied)!;
    }
    sample(fixture, render::read_view_color(view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    uint pixel = read_pixel(fixture);
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    return pixel;
}

fn void test_lod_bins_reference_shared_instances() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_lod_readback(&fixture.renderer)!!;
    defer free_lod_readback(&fixture.renderer, readback);
    LodHistoryGpu[] history = ((LodHistoryGpu*)readback.bytes.ptr)[:LOD_PLACEMENTS];
    bool[2] culling_modes = { true, false };
    foreach (culling : culling_modes) {
        set_view_culling(&fixture, culling)!!;
        for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
            render_lod_frame(
                fixture: &fixture,
                target: &target,
                view: fixture.view,
                readback: readback,
            )!!;
        }
        Stats stats = fixture.renderer.stats;
        assert(stats.lod_counts_valid && stats.lod_instances_tested == LOD_PLACEMENTS && stats.lod_fallbacks == 0);
        assert(stats.lod_frame_index + render::FRAMES_IN_FLIGHT + 1 == fixture.renderer.frame_index);
        assert(stats.lod_visible[0] == 4 && stats.lod_visible[1] == 4 && stats.lod_visible[2] == 4);
        assert(stats.lod_selected[0] == 4 && stats.lod_selected[1] == 4 && stats.lod_selected[2] == 4);
        foreach (uint index, entry : history) {
            assert(entry.level == index / 4 && entry.reject_history == 0);
            Mat4 expected = target.scene.get(target.mesh, LodGroup).state.transforms[index].to_mat4();
            assert(entry.model == bitcast(expected, Mat4f));
        }
        CameraMatrices matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { TARGET_SIZE, TARGET_SIZE });
        foreach (uint band : { 0u, 1u, 2u }) {
            Vec3 point = target.scene.get(target.mesh, LodGroup).state.transforms[band * 4 + 2].position;
            Vec2 uv = projected_uv(&matrices, point);
            uv = { (math::floor(uv.x * TARGET_SIZE) + 0.5f) / TARGET_SIZE, (math::floor(uv.y * TARGET_SIZE) + 0.5f) / TARGET_SIZE };
            uint pixel = render_lod_frame(
                fixture: &fixture,
                target: &target,
                view: fixture.view,
                readback: readback,
                uv: uv,
            )!!;
            check_channels(pixel, LOD_COLORS[band]);
        }
    }
    check_lod_bin_lists(&fixture, &target);
    check_validation(&fixture.renderer);
}

fn void test_lod_slot_history_survives_movement() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_lod_readback(&fixture.renderer)!!;
    defer free_lod_readback(&fixture.renderer, readback);
    LodHistoryGpu[] history = ((LodHistoryGpu*)readback.bytes.ptr)[:LOD_PLACEMENTS];
    LodGroupState* state = target.scene.get(target.mesh, LodGroup).state;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 1 && history[4].reject_history == 1);
    state.transforms[4].position = { 0, 0, 3 - 1.5f / 0.26f };
    state.transforms[4].scale.x = -1;
    target.scene.mark_lod_instances_dirty(target.mesh);
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 1 && history[4].reject_history == 0);
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.second_view,
        readback: readback,
    )!!;
    assert(history[4].level == 0 && history[4].reject_history == 1);
    target.scene.set_lod_instances(target.mesh, state.transforms[:state.count])!!;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 0 && history[4].reject_history == 1);
    target.scene.resize_lod_instances(target.mesh, 4)!!;
    target.scene.resize_lod_instances(target.mesh, LOD_PLACEMENTS)!!;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[0].reject_history == 0 && history[4].reject_history == 1);
    state.transforms[4].position.z = 3 - 24;
    target.scene.mark_lod_instances_dirty(target.mesh);
    target.scene.update_world();
    fixture.renderer.begin_frame()!!;
    fixture.renderer.render_view(&target.scene, target.camera, fixture.view)!!;
    render::abort_frame(&fixture.renderer);
    state.transforms[4].position.z = 3 - 1.5f / 0.105f;
    target.scene.mark_lod_instances_dirty(target.mesh);
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 1 && history[4].reject_history == 1);
    state.transforms[4].position.z = 3 - 1.5f / 0.26f;
    target.scene.mark_lod_instances_dirty(target.mesh);
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 1 && history[4].reject_history == 0);
    LodGroup replacement = scene::create_lod_group(
        allocator: mem,
        assets: &fixture.assets,
        desc: state.desc,
        capacity: LOD_PLACEMENTS,
    )!!;
    Transform[LOD_PLACEMENTS] placements;
    mem::copy(&placements, state.transforms.ptr, LOD_PLACEMENTS * Transform::size);
    target.scene.remove_component(target.mesh, LodGroup);
    target.scene.add(target.mesh, replacement);
    target.scene.set_lod_instances(target.mesh, placements[..])!!;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 0 && history[4].reject_history == 1);
    render::destroy_view(&fixture.renderer, fixture.view)!!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(fixture.hdr_target))!!;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history[4].level == 0 && history[4].reject_history == 1);
    check_validation(&fixture.renderer);
}

fn void test_lod_history_releases_replaced_and_absent_groups() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_lod_readback(&fixture.renderer)!!;
    defer free_lod_readback(&fixture.renderer, readback);
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    render::LodHistoryEntry* history = &fixture.renderer.views.get(fixture.view).lod_history.entries[target.mesh.id.index];
    assert(history.allocation.is_valid());
    assert(history.listed && fixture.renderer.views.get(fixture.view).lod_history.first == target.mesh.id.index + 1);
    LodGroup replacement = scene::create_lod_group(mem, &fixture.assets, target.scene.get(target.mesh, LodGroup).state.desc)!!;
    target.scene.remove_component(target.mesh, LodGroup);
    target.scene.add(target.mesh, replacement);
    target.camera.local.position.z = 10;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(!history.allocation.is_valid() && history.committed.level == 1);
    target.camera.local.position.z = 1.5f / 0.26f;
    for (uint frame = 0; frame < render::INSTANCE_ABSENCE_FRAMES + 2; frame++) {
        render_lod_frame(
            fixture: &fixture,
            target: &target,
            view: fixture.view,
            readback: readback,
        )!!;
        assert(history.committed.valid && history.committed.level == 1);
    }
    replacement = scene::create_lod_group(
        allocator: mem,
        assets: &fixture.assets,
        desc: target.scene.get(target.mesh, LodGroup).state.desc,
        capacity: LOD_PLACEMENTS,
    )!!;
    target.scene.remove_component(target.mesh, LodGroup);
    target.scene.add(target.mesh, replacement);
    Transform[1] placements = { maths::TRANSFORM_IDENTITY };
    target.scene.set_lod_instances(target.mesh, placements[..])!!;
    render_lod_frame(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        readback: readback,
    )!!;
    assert(history.allocation.is_valid());
    target.scene.remove_component(target.mesh, LodGroup);
    for (uint frame = 0; frame < render::INSTANCE_ABSENCE_FRAMES + 2; frame++) {
        render_lod_frame(
            fixture: &fixture,
            target: &target,
            view: fixture.view,
            readback: readback,
        )!!;
    }
    assert(!history.allocation.is_valid() && !history.committed.valid);
    check_validation(&fixture.renderer);
}

fn void test_lod_overflow_keeps_whole_groups() @test {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        instance_cull_bytes: 768,
        shadow_resolution: LOD_EFFECT_SIZE,
    )!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LodGroupState* state = target.scene.get(target.mesh, LodGroup).state;
    foreach (level : state.desc.levels) {
        MaterialId id = state.desc.parts[level.first_part].material;
        StandardParams params = SHADOW_GROUND_PARAMS;
        params.base_color = fixture.assets.material(id).data.basic.color;
        fixture.assets.material(id).data = material::standard(params);
        fixture.assets.mark_material_dirty(id);
    }
    target.scene.ambient_intensity = 0.2f;
    LodLevel[2] fitting_levels = {
        { .first_part = 0, .part_count = 1, .min_screen_size = 100 },
        { .first_part = 1, .part_count = 1, .min_screen_size = 0 },
    };
    LodPart[2] fitting_parts = {
        { .geometry = fixture.box, .material = state.desc.parts[0].material, .local = matrix::IDENTITY4 },
        { .geometry = fixture.box, .material = state.desc.parts[2].material, .local = matrix::IDENTITY4 },
    };
    Transform[1] fitting_placement = { maths::TRANSFORM_IDENTITY };
    fitting_placement[0].position = { 1, 0.75f, 0 };
    fitting_placement[0].scale = { 0.5f, 0.5f, 0.5f };
    target.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: { .levels = fitting_levels[..], .parts = fitting_parts[..] },
        capacity: 1,
        transforms: fitting_placement[..],
    )!!;
    MaterialId matte = fixture.assets.add_material(material::standard(SHADOW_GROUND_PARAMS))!!;
    Node* wall = target.scene.add_mesh(fixture.box, matte)!!;
    wall.local.position = { 0, 0, -26 };
    wall.local.scale = { 40, 40, 0.02f };
    target.scene.get(wall, Mesh).cast_shadow = false;
    Light sunlight = light::directional({ 1, 1, 1 }, 3);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = 32;
    Node* sun = target.scene.add_light(sunlight)!!;
    sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, (Vec3){ 0, -0.2f, -1 }.normalize());
    Node*[2] reference;
    foreach (index, part : state.desc.parts[:2]) {
        Transform[LOD_PLACEMENTS] composed;
        foreach (slot, transform : state.transforms[:state.count]) {
            composed[slot] = maths::transform_from_affine(transform.to_mat4().mul(part.local))!!;
        }
        reference[index] = target.scene.add_instanced_mesh(
            geometry: part.geometry,
            material: part.material,
            capacity: LOD_PLACEMENTS,
            transforms: composed[..],
        )!!;
        reference[index].visible = false;
    }
    RenderTargetId output = render::create_render_target(
        &fixture.renderer, render::render_target_desc(LOD_EFFECT_SIZE, LOD_EFFECT_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
    gpu::AllocationDesc allocation = {
        .size = LOD_EFFECT_SIZE * LOD_EFFECT_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "lod_overflow_depth",
    };
    LodVelocityProbe probe = {
        .readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &allocation)!!,
        .output = fixture.renderer.create_buffer({ .size = allocation.size, .debug_name = "lod_overflow_output" })!!,
        .shader = add_compute_shader(&fixture, (String)PROBE_READBACK_SOURCE[..])!!,
    };
    defer free_lod_readback(&fixture.renderer, probe.readback);
    Vec4[] color = mem::new_array(Vec4, LOD_EFFECT_SIZE * LOD_EFFECT_SIZE);
    defer free(color);
    Vec4[] reference_color = mem::new_array(Vec4, color.len);
    defer free(reference_color);
    Vec4[] depth = mem::new_array(Vec4, color.len);
    defer free(depth);
    Vec4[] reference_depth = mem::new_array(Vec4, color.len);
    defer free(reference_depth);
    for (uint path = 0; path < 3; path++) {
        ViewDesc view = render::texture_view_desc(output);
        view.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        view.depth_prepass = path != 0;
        render::configure_view(&fixture.renderer, fixture.view, view)!!;
        target.mesh.visible = true;
        foreach (node : reference) node.visible = false;
        capture_lod_effects(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            output: output,
            color: color,
            depth: depth,
        )!!;
        assert(fixture.renderer.stats.lod_fallbacks == 1 && fixture.renderer.stats.lod_visible[0] == LOD_PLACEMENTS);
        assert(fixture.renderer.stats.lod_visible[1] == 1 && fixture.renderer.stats.shadow_layers == 1);
        target.mesh.visible = false;
        foreach (node : reference) node.visible = true;
        capture_lod_effects(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            output: output,
            color: reference_color,
            depth: reference_depth,
        )!!;
        check_lod_images(color, reference_color, 0.004f);
        check_lod_images(reference_color, color, 0.004f);
        check_lod_images(depth, reference_depth, 1e-5f);
        check_lod_images(reference_depth, depth, 1e-5f);
    }
    check_validation(&fixture.renderer);
}

fn Vec4 lod_velocity_pixel(gpu::MappedGpuSpan readback, Vec2 uv) @private {
    uint x = (uint)(uv.x * TARGET_SIZE);
    uint y = (uint)(uv.y * TARGET_SIZE);
    return ((Vec4*)readback.bytes.ptr)[y * TARGET_SIZE + x];
}

fn void? record_lod_target(Fixture* fixture, LodVelocityProbe* probe, Target* target) @private {
    Renderer* renderer = &fixture.renderer;
    target.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    ProbeReadbackRoot root = {
        .output_address = renderer.buffer_address(probe.output),
        .atlas = target.view.index,
        .width = target.width,
        .height = target.height,
    };
    BufferId[1] writes = { probe.output };
    renderer.dispatch({
        .shader = probe.shader,
        .root = ((char*)&root)[:ProbeReadbackRoot::size],
        .groups = { (target.width + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP,
            (target.height + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP, 1 },
        .writes = writes[..],
    })!;
    gpu::Barrier written = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(probe.output).allocation)!,
        .dst = probe.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;
}

fn uint? render_lod_velocity(
    Fixture* fixture,
    DeformedScene* target,
    LodVelocityProbe* probe,
    Vec2 uv,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, target.camera, fixture.view)!;
    record_lod_target(fixture, probe, &renderer.views.get(fixture.view).velocity)!;
    sample(fixture, render::read_view_color(fixture.view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    uint pixel = read_pixel(fixture);
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!;
    return pixel;
}

fn void test_lod_transition_rejects_temporal_history() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_lod_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.resize_lod_instances(target.mesh, 2)!!;
    LodGroupState* state = target.scene.get(target.mesh, LodGroup).state;
    state.transforms[0] = maths::TRANSFORM_IDENTITY;
    state.transforms[0].position = { -0.75f, 0, -3.2f };
    state.transforms[1] = maths::TRANSFORM_IDENTITY;
    state.transforms[1].position = { 0.75f, 0, 0 };
    target.scene.mark_lod_instances_dirty(target.mesh);
    enable_taa(&fixture, fixture.view)!!;
    gpu::AllocationDesc desc = {
        .size = TARGET_SIZE * TARGET_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "lod_velocity_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &desc)!!;
    defer free_lod_readback(&fixture.renderer, readback);
    LodVelocityProbe probe = {
        .readback = readback,
        .output = fixture.renderer.create_buffer({ .size = desc.size, .debug_name = "lod_velocity_output" })!!,
        .shader = add_compute_shader(&fixture, (String)PROBE_READBACK_SOURCE[..])!!,
    };
    target.scene.update_world();
    CameraMatrices matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { TARGET_SIZE, TARGET_SIZE });
    Vec2 changing = projected_uv(&matrices, state.transforms[0].position);
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: changing,
        )!!;
    }
    assert(lod_velocity_pixel(readback, changing).w == 0);
    target.camera.local.position.z -= 1;
    target.scene.update_world();
    matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { TARGET_SIZE, TARGET_SIZE });
    changing = projected_uv(&matrices, state.transforms[0].position);
    Vec2 stable = projected_uv(&matrices, state.transforms[1].position);
    uint resolved = render_lod_velocity(
        fixture: &fixture,
        target: &target,
        probe: &probe,
        uv: changing,
    )!!;
    assert(lod_velocity_pixel(readback, changing).w == 1);
    assert(lod_velocity_pixel(readback, stable).w == 0);
    assert(fixture.renderer.views.get(fixture.view).history.valid);
    assert((resolved & 0xff) > 200 && ((resolved >> 8) & 0xff) < 30);
    state.transforms[1].position.x += 0.05f;
    target.scene.mark_lod_instances_dirty(target.mesh);
    stable = projected_uv(&matrices, state.transforms[1].position);
    render_lod_velocity(
        fixture: &fixture,
        target: &target,
        probe: &probe,
        uv: stable,
    )!!;
    Vec4 velocity = lod_velocity_pixel(readback, stable);
    Vec2 current = projected_uv(&matrices, { state.transforms[1].position.x, 0, 0.5f });
    Vec2 previous = projected_uv(&matrices, { state.transforms[1].position.x - 0.05f, 0, 0.5f });
    assert(velocity.w == 0 && math::abs(velocity.x - (current.x - previous.x)) < 1e-4f);
    assert(math::abs(velocity.y) < 1e-4f);
    check_validation(&fixture.renderer);
}

fn void test_lod_views_and_shadows_select_independently() @test {
    bool[2] modes = { false, true };
    foreach (single : modes) {
        Fixture fixture;
        create_fixture(allocator: mem, fixture: &fixture, shadow_resolution: 512)!!;
        defer destroy_fixture(&fixture);
        RenderTargetId output = render::create_render_target(&fixture.renderer, render::render_target_desc(512, 512))!!;
        fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
        fixture.second_view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
        DeformedScene target = create_lod_scene(&fixture, single, true)!!;
        defer scene::destroy_scene(&target.scene);
        LodGroup* group = target.scene.get(target.mesh, LodGroup);
        if (!single) {
            target.scene.resize_lod_instances(target.mesh, 1)!!;
            group.state.transforms[0] = maths::TRANSFORM_IDENTITY;
            target.scene.mark_lod_instances_dirty(target.mesh);
        }
        target.mesh.local.position = { 0, 3, 0 };
        MaterialId matte = fixture.assets.add_material(material::standard(SHADOW_GROUND_PARAMS))!!;
        Node* wall = target.scene.add_mesh(fixture.box, matte)!!;
        wall.local.position = { 0, 0, -2 };
        wall.local.scale = { 8, 8, 0.02f };
        target.scene.get(wall, Mesh).cast_shadow = false;
        Light sunlight = light::directional({ 1, 1, 1 }, 3);
        sunlight.shadow.cascades = 1;
        sunlight.shadow.max_distance = 12;
        Node* sun = target.scene.add_light(sunlight)!!;
        sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, (Vec3){ 0, -1, -0.5f }.normalize());
        gpu::MappedGpuSpan readback = create_lod_readback(&fixture.renderer)!!;
        defer free_lod_readback(&fixture.renderer, readback);
        uint[2] shadowed;
        for (uint view_index = 0; view_index < 2; view_index++) {
            ViewId view = view_index == 0 ? fixture.view : fixture.second_view;
            target.camera.local.position = { 0, 0, view_index == 0 ? 3 : 7 };
            target.camera.local.rotation = maths::look_rotation(((Vec3){ 0, -2, -2 } - target.camera.local.position).normalize(), { 0, 1, 0 });
            target.scene.update_world();
            CameraMatrices matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { 512, 512 });
            Aabb bounds = spatial::lod_world_bounds(&fixture.assets, target.mesh, group);
            assert(!maths::frustum_intersects_aabb(&matrices.frustum, bounds));
            Vec2 uv = projected_uv(&matrices, { 0.35f, -0.98f, -1.99f });
            for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
                shadowed[view_index] = render_lod_frame(
                    fixture: &fixture,
                    target: &target,
                    view: view,
                    readback: readback,
                    uv: uv,
                )!!;
            }
            uint selected = single ? fixture.renderer.views.get(view).lod_history.entries[target.mesh.id.index].committed.level
              : ((LodHistoryGpu*)readback.bytes.ptr)[0].level;
            assert(selected == view_index);
            assert(fixture.renderer.stats.shadow_layers == 1 && fixture.renderer.stats.lod_visible[0] == 0 && fixture.renderer.stats.lod_visible[1] == 0);
            LodLevel level = group.state.desc.levels[selected];
            Node*[3] reference_nodes;
            foreach (index, part : group.state.desc.parts[level.first_part:level.part_count]) {
                Node* node = target.scene.add_mesh(part.geometry, part.material)!!;
                node.local = maths::transform_from_affine(target.mesh.world.mul(part.local))!!;
                reference_nodes[index] = node;
            }
            target.mesh.visible = false;
            uint reference = render_at(
                fixture: &fixture,
                target: &target,
                view: view,
                time: 0,
                uv: uv,
            )!!;
            check_near_pixel(shadowed[view_index], reference);
            foreach (node : reference_nodes[:level.part_count]) target.scene.remove(node);
            target.mesh.visible = true;
        }
        assert(shade(shadowed[0]) + 30 < shade(shadowed[1]));
        check_validation(&fixture.renderer);
    }
}

fn GeometryId? flatten_lod_level(Fixture* fixture, LodPart[] parts, Aabb bounds) @private {
    @pool() {
        sz count;
        foreach (part : parts) count += fixture.assets.geometry(part.geometry).data.indices.len;
        Geometry geometry = {
            .positions = alloc::new_array(tmem, Vec3, count),
            .normals = alloc::new_array(tmem, Vec3, count),
            .bounds = bounds,
        };
        usz first;
        foreach (part : parts) {
            Geometry* source = &fixture.assets.geometry(part.geometry).data;
            Mat3 normal = maths::normal_matrix(part.local);
            bool mirrored = part.local.determinant() < 0;
            foreach (usz index, vertex : source.indices) {
                usz destination = first + index;
                if (mirrored && index % 3 != 0) destination = first + index - index % 3 + 3 - index % 3;
                geometry.positions[destination] = maths::transform_point(part.local, source.positions[vertex]);
                geometry.normals[destination] = (normal * source.normals[vertex]).normalize();
            }
            first += source.indices.len;
        }
        return fixture.assets.add_geometry(&geometry);
    };
}

fn void? capture_lod_effects(
    Fixture* fixture,
    DeformedScene* target,
    LodVelocityProbe* probe,
    RenderTargetId output,
    Vec4[] color,
    Vec4[] depth,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, fixture.view)!;
        if (frame + 1 == SETTLE_FRAMES) record_lod_target(fixture, probe, &renderer.views.get(fixture.view).depth)!;
        renderer.finish_view(fixture.view)!;
        renderer.end_frame()!;
    }
    renderer.read_render_target(output, ((char*)color.ptr)[:color.len * Vec4::size])!;
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!;
    mem::copy(depth.ptr, probe.readback.bytes.ptr, depth.len * Vec4::size);
}

fn void check_lod_images(Vec4[] actual, Vec4[] expected, float tolerance) @private {
    for (int y = 1; y + 1 < (int)LOD_EFFECT_SIZE; y++) {
        for (int x = 1; x + 1 < (int)LOD_EFFECT_SIZE; x++) {
            Vec4 pixel = actual[y * (int)LOD_EFFECT_SIZE + x];
            bool matched;
            for (int dy = -1; dy <= 1 && !matched; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    Vec4 delta = math::abs(pixel - expected[(y + dy) * (int)LOD_EFFECT_SIZE + x + dx]);
                    if (math::max(math::max(delta.x, delta.y), math::max(delta.z, delta.w)) <= tolerance) matched = true;
                }
            }
            assert(matched);
        }
    }
}

fn void test_lod_part_transforms_share_effect_anchor() @test {
    Fixture fixture;
    create_fixture(allocator: mem, fixture: &fixture, shadow_resolution: LOD_EFFECT_SIZE)!!;
    defer destroy_fixture(&fixture);
    RenderTargetId output = render::create_render_target(
        &fixture.renderer, render::render_target_desc(LOD_EFFECT_SIZE, LOD_EFFECT_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
    DeformedScene target;
    target.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 0.2f;
    target.camera = target.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    target.camera.local.position = { 0, 0.25f, 4 };
    MaterialId material = fixture.assets.add_material(material::standard(SHADOW_GROUND_PARAMS))!!;
    Node* wall = target.scene.add_mesh(fixture.box, material)!!;
    wall.local.position = { 0, 0, -2 };
    wall.local.scale = { 8, 8, 0.02f };
    target.scene.get(wall, Mesh).cast_shadow = false;
    Light sunlight = light::directional({ 1, 1, 1 }, 3);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = 12;
    Node* sun = target.scene.add_light(sunlight)!!;
    sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, (Vec3){ 0, -0.5f, -1 }.normalize());
    LodLevel[2] levels = {
        { .first_part = 0, .part_count = 2, .min_screen_size = 0.3f },
        { .first_part = 2, .part_count = 1, .min_screen_size = 0 },
    };
    Transform[3] locals = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    locals[0].scale = { 0.25f, 1, 0.25f };
    locals[1].scale = { -1, 0.5f, 1 };
    locals[1].position.y = 0.75f;
    locals[2].scale = { 1, 1.5f, 1 };
    locals[2].position.y = 0.25f;
    LodPart[3] parts;
    foreach (index, &part : parts) *part = { .geometry = fixture.box, .material = material, .local = locals[index].to_mat4() };
    Aabb bounds = { .min = { -0.5f, -0.5f, -0.5f }, .max = { 0.5f, 1, 0.5f } };
    GeometryId[2] references;
    foreach (index, level : levels) references[index] = flatten_lod_level(&fixture, parts[level.first_part:level.part_count], bounds)!!;
    LodEffects effects = {
        .sway = { .direction = { 1, 0, 0 }, .amplitude = 0.3f, .frequency = 0.5f,
            .lean = 0.3f, .wavelength = 5, .variation = 0.2f, .weight = SwayWeight.HEIGHT },
        .fade = { .start = 3.5f, .end = 6 },
        .cast_shadow = true,
        .receive_shadow = true,
    };
    gpu::AllocationDesc allocation = {
        .size = LOD_EFFECT_SIZE * LOD_EFFECT_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "lod_depth_readback",
    };
    LodVelocityProbe probe = {
        .readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &allocation)!!,
        .output = fixture.renderer.create_buffer({ .size = allocation.size, .debug_name = "lod_depth_output" })!!,
        .shader = add_compute_shader(&fixture, (String)PROBE_READBACK_SOURCE[..])!!,
    };
    defer free_lod_readback(&fixture.renderer, probe.readback);
    Vec4[] color = mem::new_array(Vec4, LOD_EFFECT_SIZE * LOD_EFFECT_SIZE);
    defer free(color);
    Vec4[] reference_color = mem::new_array(Vec4, color.len);
    defer free(reference_color);
    Vec4[] depth = mem::new_array(Vec4, color.len);
    defer free(depth);
    Vec4[] reference_depth = mem::new_array(Vec4, color.len);
    defer free(reference_depth);
    foreach (bool single : { false, true }) {
        Transform[2] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
        if (!single) {
            placements[0].position.x = -0.7f;
            placements[1].position.x = 0.7f;
            placements[1].scale.x = -1;
        }
        uint count = single ? 1 : 2;
        LodDesc desc = { .levels = levels[..], .parts = parts[..] };
        target.mesh = single ? target.scene.add_lod_group(&fixture.assets, desc)!!
          : target.scene.add_instanced_lod_group(
              assets: &fixture.assets,
              desc: desc,
              capacity: count,
              transforms: placements[:count],
          )!!;
        target.scene.set_lod_effects(target.mesh, effects);
        Node* reference = target.scene.add_instanced_mesh(
            geometry: references[0],
            material: material,
            capacity: count,
            transforms: placements[:count],
        )!!;
        InstancedMesh* batch = target.scene.get(reference, InstancedMesh);
        batch.sway = effects.sway;
        batch.fade = effects.fade;
        for (uint level = 0; level < 2; level++) {
            ViewDesc view = render::texture_view_desc(output);
            view.lod_bias = level == 0 ? 2 : -4;
            render::configure_view(&fixture.renderer, fixture.view, view)!!;
            reference.visible = false;
            target.mesh.visible = true;
            capture_lod_effects(
                fixture: &fixture,
                target: &target,
                probe: &probe,
                output: output,
                color: color,
                depth: depth,
            )!!;
            target.mesh.visible = false;
            reference.visible = true;
            batch.geometry = references[level];
            capture_lod_effects(
                fixture: &fixture,
                target: &target,
                probe: &probe,
                output: output,
                color: reference_color,
                depth: reference_depth,
            )!!;
            check_lod_images(color, reference_color, 0.004f);
            check_lod_images(reference_color, color, 0.004f);
            check_lod_images(depth, reference_depth, 1e-5f);
            check_lod_images(reference_depth, depth, 1e-5f);
        }
        target.scene.remove(reference);
        target.scene.remove(target.mesh);
    }
    check_validation(&fixture.renderer);
}
