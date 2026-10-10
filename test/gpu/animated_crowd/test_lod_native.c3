module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::io;
import std::math;

const Aabb CROWD_LOD_NATIVE_BOUNDS @private = {
    .min = { -1.5f, -0.1f, -1.5f }, .max = { 1.5f, 2.7f, 1.5f },
};
const float[3] CROWD_LOD_NATIVE_FORCE_BIASES @private = { 16, -2, -16 };
const uint[3] CROWD_LOD_NATIVE_TRIANGLES @private = { 13744, 6872, 3436 };

struct CrowdLodNativeDescriptor @private {
    LodLevel[3] levels;
    AnimatedLodPart[6] parts;
}

struct CrowdLodNativeSources @private {
    Node*[CROWD_NATIVE_INSTANCES] ordinary;
    AnimationActionId[CROWD_NATIVE_INSTANCES] actions;
    bool crowd;
}

struct CrowdLodNativeViews @private {
    CrowdNativeOutput[2] outputs;
    gpu::MappedGpuSpan[2] histories;
    Mat4[2] shadow_inverse;
}

fn void fill_crowd_lod_native_descriptor(
    Fixture* fixture,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeDescriptor* descriptor,
    MaterialId material = {},
) @private {
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    assert(template.meshes.len == animated_lod_fixtures::LOD_PRIMITIVES);
    assert(animated_lod_fixtures::LOD_PRIMITIVES == 2 && animated_lod_fixtures::LOD_LEVELS == 3);
    for (uint level = 0; level < animated_lod_fixtures::LOD_LEVELS; level++) {
        descriptor.levels[level] = {
            .first_part = level * animated_lod_fixtures::LOD_PRIMITIVES,
            .part_count = animated_lod_fixtures::LOD_PRIMITIVES,
            .min_screen_size = level == 0 ? 1 : (level == 1 ? 0.001f : 0),
        };
        uint triangles;
        foreach (uint primitive, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
            assert(skin.joint_nodes.len == 53);
            GeometryId geometry = corpus.levels[primitive][level];
            assert(corpus.layouts[primitive][level].index_count % 3 == 0);
            triangles += corpus.layouts[primitive][level].index_count / 3;
            descriptor.parts[level * animated_lod_fixtures::LOD_PRIMITIVES + primitive] = {
                .draw = {
                    .geometry = geometry,
                    .material = material.generation ? material : mesh.material,
                    .local = matrix::IDENTITY4,
                },
                .mesh_index = primitive,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
        assert(triangles == CROWD_LOD_NATIVE_TRIANGLES[level]);
        if (level) assert(triangles < CROWD_LOD_NATIVE_TRIANGLES[level - 1]);
    }
}

fn AnimatedLodDesc crowd_lod_native_desc(CrowdLodNativeDescriptor* descriptor) @private => {
    .levels = descriptor.levels[..],
    .parts = descriptor.parts[..],
    .has_bounds_override = true,
    .local_bounds = CROWD_LOD_NATIVE_BOUNDS,
};

fn void? attach_crowd_lod_native_sources(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
    bool crowd,
    ClipId clip,
    float middle_threshold = 0.001f,
) @private {
    sources.crowd = crowd;
    CrowdLodNativeDescriptor descriptor;
    if (crowd) {
        fill_crowd_lod_native_descriptor(
            fixture: fixture,
            corpus: corpus,
            descriptor: &descriptor,
            material: {},
        );
        descriptor.levels[1].min_screen_size = middle_threshold;
        AnimatedLodDesc desc = crowd_lod_native_desc(&descriptor);
        desc.has_bounds_override = false;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: desc,
        )!;
        return;
    }
    pair.scene.remove(pair.crowd);
    pair.crowd = pair.scene.add_node(name: "ordinary_lod_sources")!;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Node* actual = model::instantiate(
            assets: &fixture.assets,
            scene: &pair.scene,
            model: corpus.model,
            parent: pair.crowd,
        )!;
        actual.local = pair.ordinary[source].local;
        ModelInstance* reference = pair.scene.get(pair.ordinary[source], ModelInstance);
        ModelTemplate* template = &fixture.assets.model(corpus.model).data;
        foreach (uint part, mesh : template.meshes) {
            pair.scene.get(reference.present_node(reference.mesh_nodes[part]), Mesh).material = mesh.material;
        }
        fill_crowd_lod_native_descriptor(
            fixture: fixture,
            corpus: corpus,
            descriptor: &descriptor,
            material: {},
        );
        descriptor.levels[1].min_screen_size = middle_threshold;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: actual,
            desc: crowd_lod_native_desc(&descriptor),
        )!;
        Animator* animator = anim::add_animator(&pair.scene, actual);
        sources.actions[source] = animator.play(&fixture.assets, clip)!;
        sources.ordinary[source] = actual;
        animator.action(sources.actions[source]).speed = 0;
        animator.action(sources.actions[source]).loop = false;
    }
}

fn void set_crowd_lod_native_reference_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    uint level,
) @private {
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (uint primitive, mesh : template.meshes) {
            pair.scene.get(instance.present_node(mesh.node), Mesh).geometry = corpus.levels[primitive][level];
        }
    }
}

fn void set_crowd_lod_native_phase(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    float duration,
) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        float time = (0.125f + 0.25f * (float)source) * duration;
        Animator* reference = pair.scene.get(pair.ordinary[source], Animator);
        crowd_native_action_controls(reference.action(pair.ordinary_base[source]), time);
        if (sources.crowd) {
            CrowdPlayer player = crowd_native_player(pair, source)!!;
            crowd_native_action_controls(player.base_action()!!, time);
        } else {
            Animator* animator = pair.scene.get(sources.ordinary[source], Animator);
            crowd_native_action_controls(animator.action(sources.actions[source]), time);
        }
    }
    crowd_native_update(fixture, pair, 0);
}

fn void check_crowd_lod_native_sources_remain_base(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
) @private {
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    foreach (uint primitive, mesh : template.meshes) {
        assert(c3d::same_id(mesh.geometry, corpus.levels[primitive][0]));
        if (sources.crowd) {
            AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
            InstancedMesh* batch = pair.scene.world.get(crowd.parts[primitive].batch, InstancedMesh);
            assert(c3d::same_id(batch.geometry, corpus.levels[primitive][0]));
        } else {
            foreach (actual : sources.ordinary) {
                ModelInstance* instance = pair.scene.get(actual, ModelInstance);
                Mesh* source = pair.scene.get(instance.present_node(mesh.node), Mesh);
                assert(c3d::same_id(source.geometry, corpus.levels[primitive][0]));
            }
        }
    }
}

fn void check_crowd_lod_native_counts(Stats* stats, uint level, bool crowd) @private {
    assert(stats.cull_overflows == 0 && stats.sort_overflows == 0 && stats.lod_fallbacks == 0);
    if (crowd) {
        assert(stats.lod_counts_valid && stats.lod_instances_tested == CROWD_NATIVE_INSTANCES);
        io::printfn("selected levels: %s", stats.lod_selected);
        io::printfn("visible levels: %s", stats.lod_visible);
        for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
            uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
            assert(stats.lod_selected[choice] == expected && stats.lod_visible[choice] == expected);
        }
    } else {
        for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
            uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
            assert(stats.lod_objects_selected[choice] == expected && stats.lod_objects_visible[choice] == expected);
        }
    }
    io::printfn("animated LOD level=%s crowd=%s", level, crowd);
    io::printfn("selected visible sources=%s authored triangles=%s", CROWD_NATIVE_INSTANCES,
        CROWD_NATIVE_INSTANCES * CROWD_LOD_NATIVE_TRIANGLES[level]);
    io::printfn("recorded triangle work=%s LOD fallback=%s", stats.triangles, stats.lod_fallbacks);
}

fn void? compare_crowd_lod_native_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
    CrowdNativeOutput* output,
    uint level,
) @private {
    set_crowd_lod_native_reference_level(
        fixture: fixture,
        pair: pair,
        corpus: corpus,
        level: level,
    );
    for (uint path = 0; path < 3; path++) {
        ViewDesc desc = render::texture_view_desc(output.target);
        desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.depth_prepass = path == 1;
        desc.lod_bias = CROWD_LOD_NATIVE_FORCE_BIASES[level];
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
        check_crowd_lod_native_counts(&output.actual.stats, level, sources.crowd);
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: false,
            images: &output.expected,
        )!;
        check_crowd_native_parity(&output.actual, &output.expected, false);
        if (path == 2) {
            assert(output.actual.has_normal && output.expected.has_normal);
            check_crowd_native_image(output.actual.normal, output.expected.normal, CROWD_NATIVE_COLOR_TOLERANCE);
            check_crowd_native_image(output.expected.normal, output.actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
            uint normal_coverage;
            foreach (index, depth : output.actual.depth) {
                if (depth.x > 0 && output.actual.normal[index].w > 0.5f) normal_coverage++;
            }
            assert(normal_coverage > 0);
        }
        check_crowd_lod_native_sources_remain_base(
            fixture: fixture,
            pair: pair,
            corpus: corpus,
            sources: sources,
        );
    }
}

fn void test_animated_lod_native_quaternius_crowd_and_ordinary_forced_levels_match_selected_geometry() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    crowd_native_flat_source_materials(&fixture, corpus.model);
    ClipId walk = crowd_native_clip_named(&fixture, corpus.model, "Walk_Loop")!!;
    float duration = fixture.assets.clip(walk).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (bool crowd : { true, false }) {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: corpus.model,
            clip: walk,
            bounds: CROWD_LOD_NATIVE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(6, 0.1f, 100);
        pair.camera.local.position = { 0, 1, 12 };
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_crowd_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
            crowd: crowd,
            clip: walk,
        )!!;
        set_crowd_lod_native_phase(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            duration: duration,
        );
        CrowdNativeOutput output;
        create_crowd_native_output(&fixture, &output)!!;
        defer destroy_crowd_native_output(&fixture, &output);
        for (uint level = 0; level < animated_lod_fixtures::LOD_LEVELS; level++) {
            compare_crowd_lod_native_level(
                fixture: &fixture,
                pair: &pair,
                corpus: &corpus,
                sources: &sources,
                output: &output,
                level: level,
            )!!;
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn void? capture_crowd_lod_native_threshold_pair(
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
            pair.crowd.visible = index == 0;
            pair.references.visible = index != 0;
            pair.scene.update_world();
            renderer.render_view(&pair.scene, pair.camera, output.view)!;
            ViewRecord* record = renderer.views.get(output.view);
            record_crowd_native_target(
                fixture: fixture,
                probe: &output.probe,
                target: &record.depth,
                mapped: output.probe.depth,
            )!;
            record_crowd_native_target(
                fixture: fixture,
                probe: &output.probe,
                target: &record.velocity,
                mapped: output.probe.velocity,
            )!;
            output.actual.velocity_format = record.velocity.format;
            renderer.finish_view(output.view)!;
        }
        renderer.end_frame()!;
    }
    render::wait_frames(renderer)!;
    foreach (output : (CrowdNativeOutput*[2]){ actual, reference }) {
        gpu::invalidate_mapped_span(&renderer.device, output.probe.depth.span)!;
        gpu::invalidate_mapped_span(&renderer.device, output.probe.velocity.span)!;
        mem::copy(output.actual.depth.ptr, output.probe.depth.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
        mem::copy(output.actual.velocity.ptr, output.probe.velocity.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
        renderer.read_render_target(output.target, ((char*)output.actual.color.ptr)
            [:output.actual.color.len * Vec4::size])!;
        output.actual.stats = renderer.stats;
    }
}

fn void test_animated_lod_native_quaternius_threshold_traversal_retains_hysteresis() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    crowd_native_flat_source_materials(&fixture, corpus.model);
    ClipId walk = crowd_native_clip_named(&fixture, corpus.model, "Walk_Loop")!!;
    float duration = fixture.assets.clip(walk).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    float[8] screen_sizes = { 1.2f, 0.99f, 1.05f, 1.11f, 0.495f, 0.525f, 0.555f, 1.2f };
    uint[8] expected_levels = { 0, 1, 1, 0, 2, 2, 1, 0 };
    Vec3 scaled_half_extent = { 1.5f * 0.9f, 1.4f * 1.1f, 1.5f * 0.8f };
    float unbiassed_size = 2 * scaled_half_extent.length() / 6;
    foreach (bool crowd : { true, false }) {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: corpus.model,
            clip: walk,
            bounds: CROWD_LOD_NATIVE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(6, 0.1f, 100);
        pair.camera.local.position = { 0, 1, 12 };
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_crowd_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
            crowd: crowd,
            clip: walk,
            middle_threshold: 0.5f,
        )!!;
        set_crowd_lod_native_phase(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            duration: duration,
        );
        CrowdNativeOutput actual;
        create_crowd_native_output(&fixture, &actual)!!;
        defer destroy_crowd_native_output(&fixture, &actual);
        CrowdNativeOutput reference;
        create_crowd_native_output(&fixture, &reference)!!;
        defer destroy_crowd_native_output(&fixture, &reference);
        ViewDesc reference_desc = render::texture_view_desc(reference.target);
        reference_desc.post.motion_blur = true;
        render::configure_view(&fixture.renderer, reference.view, reference_desc)!!;
        ViewDesc actual_desc = render::texture_view_desc(actual.target);
        actual_desc.post.motion_blur = true;
        render::configure_view(&fixture.renderer, actual.view, actual_desc)!!;
        foreach (step, size : screen_sizes) {
            uint level = expected_levels[step];
            pair.scene.get(pair.camera, Camera).ortho_height = 6 * unbiassed_size / size;
            set_crowd_lod_native_reference_level(
                fixture: &fixture,
                pair: &pair,
                corpus: &corpus,
                level: level,
            );
            capture_crowd_lod_native_threshold_pair(
                fixture: &fixture,
                pair: &pair,
                actual: &actual,
                reference: &reference,
            )!!;
            check_crowd_lod_native_counts(&actual.actual.stats, level, crowd);
            check_crowd_native_parity(&actual.actual, &reference.actual, false);
            io::printfn("threshold size=%s expected level=%s", size, level);
            check_crowd_lod_native_sources_remain_base(
                fixture: &fixture,
                pair: &pair,
                corpus: &corpus,
                sources: &sources,
            );
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn gpu::MappedGpuSpan? allocate_crowd_lod_native_history(Renderer* renderer) @private {
    gpu::AllocationDesc desc = {
        .size = CROWD_NATIVE_INSTANCES * shader::LodHistoryGpu::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "animated_lod_view_history",
    };
    return gpu::allocate_mapped_memory(&renderer.device, &desc);
}

fn void free_crowd_lod_native_history(Renderer* renderer, gpu::MappedGpuSpan history) @private {
    render::wait_frames(renderer)!!;
    gpu::GpuAllocation allocation = history.span.allocation();
    gpu::free_allocation(&renderer.device, &allocation)!!;
}

fn void? create_crowd_lod_native_views(Fixture* fixture, CrowdLodNativeViews* views) @private {
    create_crowd_native_output(fixture, &views.outputs[0])!;
    defer catch destroy_crowd_native_output(fixture, &views.outputs[0]);
    create_crowd_native_output(fixture, &views.outputs[1])!;
    defer catch destroy_crowd_native_output(fixture, &views.outputs[1]);
    views.histories[0] = allocate_crowd_lod_native_history(&fixture.renderer)!;
    defer catch free_crowd_lod_native_history(&fixture.renderer, views.histories[0]);
    views.histories[1] = allocate_crowd_lod_native_history(&fixture.renderer)!;
    defer catch free_crowd_lod_native_history(&fixture.renderer, views.histories[1]);
}

fn void destroy_crowd_lod_native_views(Fixture* fixture, CrowdLodNativeViews* views) @private {
    foreach (history : views.histories) free_crowd_lod_native_history(&fixture.renderer, history);
    foreach (&output : views.outputs) destroy_crowd_native_output(fixture, output);
}

fn void? configure_crowd_lod_native_views(Fixture* fixture, CrowdLodNativeViews* views) @private {
    for (uint index = 0; index < 2; index++) {
        CrowdNativeOutput* output = &views.outputs[index];
        ViewDesc desc = render::texture_view_desc(output.target);
        desc.shading = ShadingPath.DEFERRED;
        desc.post.motion_blur = true;
        desc.lod_bias = CROWD_LOD_NATIVE_FORCE_BIASES[index == 0 ? 0 : 2];
        desc.share_shadows = false;
        render::configure_view(&fixture.renderer, output.view, desc)!;
    }
}

fn void? record_crowd_lod_native_history(
    Fixture* fixture,
    CrowdNativePair* pair,
    ViewId view,
    gpu::MappedGpuSpan readback,
) @private {
    Renderer* renderer = &fixture.renderer;
    render::LodHistoryEntry* history = &renderer.views.get(view).lod_history.entries[pair.crowd.id.index];
    assert(history.allocation.is_valid() && history.pending.valid && history.capacity == CROWD_NATIVE_INSTANCES);
    usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * shader::LodHistoryGpu::size;
    gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, history.allocation)!;
    gpu::Barrier produced = { .before = { .compute, .vertex_shader }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &produced)!;
    gpu::BufferCopyDesc copy = {
        .src = source.checked_subspan(offset, readback.bytes.len)!,
        .dst = readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;
}

fn void? record_crowd_lod_native_output(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* output,
    bool actual,
) @private {
    pair.crowd.visible = actual;
    pair.references.visible = !actual;
    pair.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    renderer.render_view(&pair.scene, pair.camera, output.view)!;
    ViewRecord* record = renderer.views.get(output.view);
    assert(record.desc.shading == ShadingPath.DEFERRED);
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &record.depth,
        mapped: output.probe.depth,
    )!;
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &record.velocity,
        mapped: output.probe.velocity,
    )!;
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS],
        mapped: output.probe.normal,
    )!;
    output.actual.has_normal = true;
    output.actual.velocity_format = record.velocity.format;
    output.actual.shadow_resolution = renderer.shadow_atlas.resolution;
    assert(renderer.shadow_set.layer_count == 1 && renderer.shadow_set.light_count == 1);
    uint layer = renderer.shadow_set.lights[0].first_layer;
    Target shadow = {
        .texture = renderer.shadow_atlas.texture,
        .view = renderer.shadow_atlas.layers[layer].view,
        .state = renderer.shadow_atlas.state,
        .format = gpu::Format.D32_FLOAT,
        .width = output.actual.shadow_resolution,
        .height = output.actual.shadow_resolution,
    };
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &shadow,
        mapped: output.probe.shadow,
    )!;
    renderer.shadow_atlas.state = shadow.state;
    renderer.finish_view(output.view)!;
}

fn void? read_crowd_lod_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    Renderer* renderer = &fixture.renderer;
    CrowdNativeImages* images = &output.actual;
    renderer.read_render_target(output.target, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!;
    gpu::invalidate_mapped_span(&renderer.device, output.probe.depth.span)!;
    gpu::invalidate_mapped_span(&renderer.device, output.probe.velocity.span)!;
    gpu::invalidate_mapped_span(&renderer.device, output.probe.normal.span)!;
    gpu::invalidate_mapped_span(&renderer.device, output.probe.shadow.span)!;
    mem::copy(images.depth.ptr, output.probe.depth.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    mem::copy(images.velocity.ptr, output.probe.velocity.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    mem::copy(images.normal.ptr, output.probe.normal.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    mem::copy(images.shadow.ptr, output.probe.shadow.bytes.ptr,
        (sz)images.shadow_resolution * images.shadow_resolution * Vec4::size);
    images.stats = renderer.stats;
}

fn void match_crowd_lod_native_shadow_bounds(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
) @private {
    Aabb aggregate;
    if (sources.crowd) {
        LodGroup* group = pair.scene.get(pair.crowd, LodGroup);
        model::sync_animated_lod(&fixture.assets, &pair.scene, pair.crowd)!!;
        aggregate = spatial::lod_world_bounds(
            assets: &fixture.assets,
            node: pair.crowd,
            group: group,
            scene: &pair.scene,
        );
    }
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (template_node : instance.mesh_nodes) {
            Node* mesh_node = instance.present_node(template_node);
            Mesh* mesh = pair.scene.get(mesh_node, Mesh);
            Mat4 mesh_local = maths::inverse_affine(root.world).mul(mesh_node.world);
            mesh.has_bounds_override = true;
            mesh.local_bounds = sources.crowd
                ? maths::aabb_transform(aggregate, maths::inverse_affine(mesh_node.world))
                : maths::aabb_transform(CROWD_LOD_NATIVE_BOUNDS, maths::inverse_affine(mesh_local));
        }
    }
}

fn void? capture_crowd_lod_native_simultaneous(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
    CrowdLodNativeViews* actual,
    CrowdLodNativeViews* reference,
) @private {
    Renderer* renderer = &fixture.renderer;
    match_crowd_lod_native_shadow_bounds(fixture, pair, sources);
    for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        for (uint index = 0; index < 2; index++) {
            CrowdNativeOutput* output = &actual.outputs[index];
            record_crowd_lod_native_output(
                fixture: fixture,
                pair: pair,
                output: output,
                actual: true,
            )!;
            actual.shadow_inverse[index] = renderer.shadow_frusta[0].inv_view_proj;
            if (sources.crowd) {
                record_crowd_lod_native_history(
                    fixture: fixture,
                    pair: pair,
                    view: output.view,
                    readback: actual.histories[index],
                )!;
            }
        }
        for (uint index = 0; index < 2; index++) {
            set_crowd_lod_native_reference_level(
                fixture: fixture,
                pair: pair,
                corpus: corpus,
                level: index == 0 ? 0 : 2,
            );
            record_crowd_lod_native_output(
                fixture: fixture,
                pair: pair,
                output: &reference.outputs[index],
                actual: false,
            )!;
            reference.shadow_inverse[index] = renderer.shadow_frusta[0].inv_view_proj;
        }
        if (sources.crowd) assert(renderer.deformation.animated_palettes.len() == 1);
        assert(renderer.stats.shadow_sets_recorded == 4 && renderer.stats.shadow_sets_shared == 0);
        assert(renderer.stats.shadow_layers == 4 && renderer.stats.shadow_requests_dropped == 0);
        renderer.end_frame()!;
    }
    render::wait_frames(renderer)!;
    for (uint index = 0; index < 2; index++) {
        read_crowd_lod_native_output(fixture, &actual.outputs[index])!;
        read_crowd_lod_native_output(fixture, &reference.outputs[index])!;
        uint level = index == 0 ? 0 : 2;
        if (sources.crowd) {
            gpu::invalidate_mapped_span(&renderer.device, actual.histories[index].span)!;
            shader::LodHistoryGpu[] rows = ((shader::LodHistoryGpu*)actual.histories[index].bytes.ptr)
                [:CROWD_NATIVE_INSTANCES];
            AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
            foreach (source, row : rows) {
                assert(row.level == level && row.reject_history == 0);
                assert(row.generation == crowd.playback.slots[source].generation);
                assert(row.model == bitcast(crowd.placements[source].to_mat4(), Mat4f));
            }
        } else {
            foreach (owner : sources.ordinary) {
                render::LodHistoryEntry* history = &renderer.views.get(actual.outputs[index].view)
                    .lod_history.entries[owner.id.index];
                assert(history.committed.valid && history.committed.level == level);
            }
        }
    }
    Stats* stats = &actual.outputs[0].actual.stats;
    assert(stats.lod_fallbacks == 0 && stats.cull_overflows == 0 && stats.sort_overflows == 0);
    for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
        uint selected = choice == 0 || choice == 2 ? CROWD_NATIVE_INSTANCES : 0;
        uint visible = choice == 0 || choice == 2 ? 2 : 0;
        if (sources.crowd) {
            assert(stats.lod_counts_valid && stats.lod_instances_tested == 2 * CROWD_NATIVE_INSTANCES);
            assert(stats.lod_selected[choice] == selected && stats.lod_visible[choice] == visible);
        } else {
            assert(stats.lod_objects_selected[choice] == selected && stats.lod_objects_visible[choice] == visible);
        }
    }
    io::printfn("simultaneous view levels=0/2 crowd=%s selected=3/3 visible=2/2", sources.crowd);
}

fn void check_crowd_lod_native_two_source_coverage(CrowdNativeImages* images) @private {
    uint[2] covered;
    uint normal_covered;
    foreach (index, depth : images.depth) {
        if (depth.x <= 0) continue;
        covered[(index % CROWD_NATIVE_WIDTH) < CROWD_NATIVE_WIDTH / 2 ? 0 : 1]++;
        if (images.normal[index].w > 0.5f) normal_covered++;
        assert(math::abs(images.velocity[index].x) < CROWD_NATIVE_STILL_TOLERANCE);
        assert(math::abs(images.velocity[index].y) < CROWD_NATIVE_STILL_TOLERANCE);
    }
    assert(covered[0] > 0 && covered[1] > 0 && normal_covered > 0);
}

fn void check_crowd_lod_native_view_parity(CrowdNativeImages* actual, CrowdNativeImages* reference) @private {
    check_crowd_lod_native_two_source_coverage(actual);
    check_crowd_lod_native_two_source_coverage(reference);
    check_crowd_native_image(actual.color, reference.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(reference.color, actual.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(actual.depth, reference.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(reference.depth, actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(actual.normal, reference.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(reference.normal, actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    assert(actual.shadow_resolution == reference.shadow_resolution && actual.shadow_resolution > 0);
    uint resolution = actual.shadow_resolution;
    uint actual_covered;
    uint reference_covered;
    for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
        if (actual.shadow[pixel].x > 0) actual_covered++;
        if (reference.shadow[pixel].x > 0) reference_covered++;
    }
    assert(actual_covered > 0 && reference_covered > 0);
    io::printfn("shadow coverage=%s/%s", actual_covered, reference_covered);
    check_crowd_native_image(
        actual: actual.shadow,
        expected: reference.shadow,
        tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
        width: resolution,
        height: resolution,
    );
    check_crowd_native_image(
        actual: reference.shadow,
        expected: actual.shadow,
        tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
        width: resolution,
        height: resolution,
    );
}

fn void test_animated_lod_native_quaternius_simultaneous_parent_levels_and_offscreen_shadows() @test {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        shadow_resolution: 128,
        max_shadow_layers: 1,
        max_views: 12,
        max_render_targets: 12,
    )!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    crowd_native_flat_source_materials(&fixture, corpus.model);
    ClipId walk = crowd_native_clip_named(&fixture, corpus.model, "Walk_Loop")!!;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    placements[0].position.x = -1.5f;
    placements[1].position.x = 1.5f;
    placements[2].position.x = 6;
    foreach (bool crowd : { true, false }) {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: corpus.model,
            clip: walk,
            bounds: CROWD_LOD_NATIVE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(6, 0.1f, 30);
        pair.camera.local.position = { 0, 1, 12 };
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_crowd_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
            crowd: crowd,
            clip: walk,
        )!!;
        set_crowd_lod_native_phase(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            duration: fixture.assets.clip(walk).data.duration,
        );
        Light sun = light::directional({ 1, 1, 1 }, 1);
        sun.shadow.cascades = 1;
        sun.shadow.max_distance = 25;
        Node* light_node = pair.scene.add_light(sun)!!;
        light_node.local.rotation = maths::look_rotation((Vec3){ -0.8f, -0.3f, -1 }.normalize(), { 0, 1, 0 });
        pair.scene.update_world();
        CrowdLodNativeViews actual;
        create_crowd_lod_native_views(&fixture, &actual)!!;
        defer destroy_crowd_lod_native_views(&fixture, &actual);
        CrowdLodNativeViews reference;
        create_crowd_lod_native_views(&fixture, &reference)!!;
        defer destroy_crowd_lod_native_views(&fixture, &reference);
        configure_crowd_lod_native_views(&fixture, &actual)!!;
        configure_crowd_lod_native_views(&fixture, &reference)!!;
        capture_crowd_lod_native_simultaneous(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        for (uint view = 0; view < 2; view++) {
            float[] actual_projection = ((float*)&actual.shadow_inverse[view])[:Mat4::size / float::size];
            float[] reference_projection = ((float*)&reference.shadow_inverse[view])[:Mat4::size / float::size];
            foreach (component, value : actual_projection) {
                assert(math::abs(value - reference_projection[component]) <= CROWD_NATIVE_DEPTH_TOLERANCE);
            }
            check_crowd_lod_native_view_parity(&actual.outputs[view].actual, &reference.outputs[view].actual);
            uint resolution = actual.outputs[view].actual.shadow_resolution;
            mem::copy(actual.outputs[view].expected.shadow.ptr, actual.outputs[view].actual.shadow.ptr,
                (sz)resolution * resolution * Vec4::size);
            mem::copy(actual.outputs[view].expected.depth.ptr, actual.outputs[view].actual.depth.ptr,
                CROWD_NATIVE_PIXELS * Vec4::size);
        }
        uint level_shadow_differences;
        uint resolution = reference.outputs[0].actual.shadow_resolution;
        for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
            if (math::abs(reference.outputs[0].actual.shadow[pixel].x
                - reference.outputs[1].actual.shadow[pixel].x) > CROWD_NATIVE_DEPTH_TOLERANCE) {
                level_shadow_differences++;
            }
        }
        assert(level_shadow_differences > 0, "Reduced parent shadow level is not discriminating");
        if (crowd) {
            AnimatedCrowd* animated = pair.scene.get(pair.crowd, AnimatedCrowd);
            animated.placements[2].position.x = 1000;
            pair.scene.write_crowd_batches(animated);
        } else {
            sources.ordinary[2].local.position.x = 1000;
        }
        pair.ordinary[2].local.position.x = 1000;
        crowd_native_update(&fixture, &pair, 0);
        capture_crowd_lod_native_simultaneous(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        for (uint view = 0; view < 2; view++) {
            float[] actual_projection = ((float*)&actual.shadow_inverse[view])[:Mat4::size / float::size];
            float[] reference_projection = ((float*)&reference.shadow_inverse[view])[:Mat4::size / float::size];
            foreach (component, value : actual_projection) {
                assert(math::abs(value - reference_projection[component]) <= CROWD_NATIVE_DEPTH_TOLERANCE);
            }
            check_crowd_lod_native_view_parity(&actual.outputs[view].actual, &reference.outputs[view].actual);
            check_crowd_native_image(actual.outputs[view].actual.depth, actual.outputs[view].expected.depth,
                CROWD_NATIVE_DEPTH_TOLERANCE);
            check_crowd_native_image(actual.outputs[view].expected.depth, actual.outputs[view].actual.depth,
                CROWD_NATIVE_DEPTH_TOLERANCE);
            uint offscreen_shadow_differences;
            for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
                if (math::abs(actual.outputs[view].actual.shadow[pixel].x
                    - actual.outputs[view].expected.shadow[pixel].x) > CROWD_NATIVE_DEPTH_TOLERANCE) {
                    offscreen_shadow_differences++;
                }
            }
            assert(offscreen_shadow_differences > 0, "Offscreen source did not contribute to its parent shadow");
            io::printfn("parent shadow view=%s offscreen changed pixels=%s", view, offscreen_shadow_differences);
        }
        check_crowd_lod_native_sources_remain_base(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
        );
        check_crowd_native_validation(&fixture.renderer);
    }
}
