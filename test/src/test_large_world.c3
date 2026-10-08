module c3d::test::large_world;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::pool;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import gpu;
import std::io;
import std::math;

const Vec3 ORIGIN @local = { 49920, 0, 49920 };
const double NDC_TOLERANCE @local = 0.00001;

fn Matrix4x4{double} widen(Mat4 source) @local {
    Matrix4x4{double} result;
    foreach (index, value : source.m) result.m[index] = value;
    return result;
}

fn double ndc_error(Vec4 actual, double[<4>] reference) @local {
    return math::max(
        math::abs((double)(actual.x / actual.w) - reference.x / reference.w),
        math::abs((double)(actual.y / actual.w) - reference.y / reference.w),
    );
}

fn void test_rebase_preserves_the_affine_basis() @test {
    Mat4 original = {
        .m01 = -3, .m03 = 50000,
        .m10 = -2, .m13 = 3,
        .m22 = 4, .m23 = -50000,
        .m33 = 1,
    };
    Mat4 converted = maths::rebase(original, { 49920, 0, -49920 });
    assert(maths::translation(converted) == (Vec3){ 80, 3, -80 });
    converted.m03 = original.m03;
    converted.m13 = original.m13;
    converted.m23 = original.m23;
    assert(converted == original);
    assert(maths::rebase(original, {}) == original);
}

fn void test_frame_origin_selects_nearest_cells_with_positive_ties() @test {
    Vec3[8] references = {
        {}, { 100, 3, -120 }, { 127.99999f, 128, 128.00002f },
        { -128.00002f, -128, -127.99999f }, { -384, -256, -129 },
        { 50000.4f, 20, -12345 }, { 100000, -100000, 65536 }, { 0, 0, 0 },
    };
    Vec3[8] expected = {
        {}, {}, { 0, 256, 256 }, { -256, 0, 0 }, { -256, -256, -256 },
        { 49920, 0, -12288 }, { 100096, -100096, 65536 }, {},
    };
    foreach (index, reference : references) {
        Vec3 origin = render::frame_origin_for(reference);
        assert(origin == expected[index]);
        assert(math::abs(reference.x - origin.x) <= 128);
        assert(math::abs(reference.y - origin.y) <= 128);
        assert(math::abs(reference.z - origin.z) <= 128);
    }
}

fn void test_relative_projection_preserves_nearby_detail_at_large_distances() @test {
    Camera[2] cameras = { camera::perspective_deg(60, 0.1f, 1000), camera::orthographic(16, 0.1f, 1000) };
    float[4] distances = { 0, 10000, 50000, 100000 };
    Vec4[3] vertices = { { 0.125f, 0.0625f, 0, 1 }, { -0.25f, 0.125f, 0.5f, 1 }, { 0.5f, -0.25f, -0.5f, 1 } };
    foreach (lens, camera : cameras) {
        foreach (distance : distances) {
            Mat4 camera_world = {
                .m00 = 0.8660254f, .m02 = 0.5f, .m03 = distance,
                .m11 = 1, .m13 = 3,
                .m20 = -0.5f, .m22 = 0.8660254f, .m23 = distance,
                .m33 = 1,
            };
            Mat4 model = camera_world.mul(matrix::IDENTITY4.translate({ 0.5f, 0.25f, -8 }));
            Vec3 origin = render::frame_origin_for(maths::translation(camera_world));
            CameraMatrices absolute = camera::derive_matrices(camera, camera_world, { 512, 512 });
            CameraMatrices relative = camera::derive_matrices(
                camera: camera,
                camera_world: maths::rebase(camera_world, origin),
                viewport: { 512, 512 },
            );
            Matrix4x4{double} inverse = widen(camera_world).inverse()!!;
            Matrix4x4{double} reference_matrix = widen(absolute.proj).mul(inverse).mul(widen(model));
            double absolute_error;
            double relative_error;
            foreach (vertex : vertices) {
                double[<4>] reference = reference_matrix.apply({ vertex.x, vertex.y, vertex.z, vertex.w });
                Vec4 old_clip = absolute.view_proj.apply(model.apply(vertex));
                Vec4 new_clip = relative.view_proj.apply(maths::rebase(model, origin).apply(vertex));
                absolute_error = math::max(absolute_error, ndc_error(old_clip, reference));
                relative_error = math::max(relative_error, ndc_error(new_clip, reference));
                if (distance == 0) assert(old_clip == new_clip);
            }
            io::printfn("lens=%d distance=%.0f absolute_error=%.12f relative_error=%.12f",
                lens, distance, absolute_error, relative_error);
            assert(relative_error <= NDC_TOLERANCE);
            if (lens == 0 && distance == 50000) assert(relative_error < absolute_error);
        }
    }
}

fn void test_relative_bounds_keep_thin_geometry_and_cull_in_camera_space() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    @pool() {
        Geometry shape = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry = assets.add_geometry(&shape)!!;
        MaterialId material = assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
        Node* thin = scene.add_mesh(geometry, material)!!;
        thin.local.position = { 50000, 0, 50000 };
        Mesh* mesh = scene.get(thin, Mesh);
        mesh.has_bounds_override = true;
        mesh.local_bounds = { .min = { -1.0f / 2048, -0.5f, -0.5f }, .max = { 1.0f / 2048, 0.5f, 0.5f } };
        Node* rear = scene.add_mesh(geometry, material)!!;
        rear.local.position = { 50000, 0, 50300 };
        scene.update_world();
        Aabb relative = spatial::mesh_world_bounds(
            assets: &assets,
            node: thin,
            mesh: mesh,
            skin: null,
            origin: ORIGIN,
        );
        assert(relative.max.x - relative.min.x == 1.0f / 1024);
        assert(relative.min == (Vec3){ 80 - 1.0f / 2048, -0.5f, 79.5f });
        Aabb absolute = spatial::mesh_world_bounds(
            assets: &assets,
            node: thin,
            mesh: mesh,
            skin: null,
        );
        assert(absolute.min == maths::aabb_transform(mesh.local_bounds, thin.world).min);
        CameraMatrices camera = camera::derive_matrices(
            camera::perspective_deg(60, 0.1f, 1000),
            matrix::IDENTITY4.translate({ 80, 0, 83 }),
            { 512, 512 },
        );
        ExtractCounts counts;
        MeshCandidate[] visible = render::extract_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            camera: &camera,
            layers: camera::ALL_LAYERS,
            counts: &counts,
            origin: ORIGIN,
        );
        assert(visible.len == 1 && visible[0].node == thin);
    };
}

fn void test_palette_stays_mesh_local_across_origin_changes() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* mesh = scene.add_node()!!;
    mesh.local = { .position = { 50000, 4, 50000 }, .rotation = quaternion::IDENTITY, .scale = { -2, 4, 0.5f } };
    Node* joint = scene.add_node()!!;
    joint.local.position = { 50000.25f, 4.5f, 49999.5f };
    scene.update_world();
    Node*[1] joints = { joint };
    Mat4[1] inverse_bind = { matrix::IDENTITY4 };
    SkinBinding binding = { .joints = joints[..] };
    Mat4f[1] first;
    Mat4f[1] second;
    render::evaluate_palette(
        palette: first[..],
        mesh_node: mesh,
        binding: &binding,
        inverse_bind: inverse_bind[..],
        origin: ORIGIN,
    );
    render::evaluate_palette(
        palette: second[..],
        mesh_node: mesh,
        binding: &binding,
        inverse_bind: inverse_bind[..],
        origin: ORIGIN + (Vec3){ 256, 0, -256 },
    );
    Mat4 expected = maths::inverse_affine(mesh.world).mul(joint.world);
    assert(bitcast(first[0], Mat4) == expected);
    assert(bitcast(second[0], Mat4) == expected);
}

fn void test_camera_clip_mapping_cancels_static_projection_translation() @test {
    Transform pose = maths::TRANSFORM_IDENTITY;
    pose.position = { -256, 1, 258 };
    pose.rotation = maths::look_rotation({ 0, -1, -3 }, { 0, 1, 0 });
    CameraMatrices camera = camera::derive_matrices(
        camera: camera::perspective_deg(60, 0.1f, 1000),
        camera_world: pose.to_mat4(),
        viewport: { 32, 32 },
    );
    Vec2 jitter = { 0.015625f, -0.0078125f };
    Mat4 mapping = render::camera_clip_reprojection(
        current_view_proj: camera.view_proj,
        previous_view_proj: camera.view_proj,
        previous_origin: ORIGIN,
        current_origin: ORIGIN,
        jitter: jitter,
    );
    Vec4 clip = { 0.25f, 0.5f, 0.125f, 1 };
    Vec4 previous = mapping.apply(clip);
    assert(previous == clip - (Vec4){ jitter.x, jitter.y, 0, 0 });
    Mat4 prior = camera.view_proj;
    prior.m03 += 0.125f;
    mapping = render::camera_clip_reprojection(
        current_view_proj: camera.view_proj,
        previous_view_proj: prior,
        previous_origin: ORIGIN,
        current_origin: ORIGIN,
        jitter: {},
    );
    Matrix4x4{double} inverse = widen(camera.view_proj).inverse()!!;
    double[<4>] expected = widen(prior).mul(inverse).apply({ clip.x, clip.y, clip.z, clip.w });
    assert(ndc_error(mapping.apply(clip), expected) < 0.000001);
}

fn void test_trace_factors_preserve_small_local_placements() @test {
    TraceInstance record = {
        .world = matrix::IDENTITY4.translate({ 50003, 0, 0 }),
        .local = matrix::IDENTITY4,
    };
    Vec3 origin = { 49920, 0, 0 };
    assert(maths::translation(render::trace_instance_world(&record, origin)) == (Vec3){ 83, 0, 0 });
    record.world.m00 = -2;
    record.world.m11 = 4;
    record.local.m03 = 1.0f / 2048;
    Mat4 relative = render::trace_instance_world(&record, origin);
    assert(relative.m03 == 83 - 1.0f / 1024);
    assert(maths::transform_point(maths::inverse_affine(relative), maths::translation(relative)) == (Vec3){});
    gpu::AccelerationStructureInstanceDesc hardware = render::tlas_instance_desc(&record, 3, origin);
    assert(hardware.transform_row_0 == (Vec4){ relative.m00, relative.m01, relative.m02, relative.m03 });
    assert(record.world.m03 == 50003 && record.local.m03 == 1.0f / 2048);
}

fn void test_sway_phase_and_plane_distance_survive_origin_changes() @test {
    InstanceSway sway = { .direction = { 3, 0, 4 }, .amplitude = 0.25f, .frequency = 0.75f, .wavelength = 32 };
    Vec3 anchor = { 50003, 4, 49997 };
    Vec3[2] origins = { ORIGIN, ORIGIN + (Vec3){ 256, 0, -256 } };
    double[2] times = { 1000.25, 1000.5 };
    foreach (time : times) {
        double[2] phases;
        foreach (index, origin : origins) {
            SwayGpu packed = render::pack_sway(sway, time, origin);
            Vec3 local = anchor - origin;
            Vec3 direction = packed.direction_amplitude.xyz;
            phases[index] = (double)packed.phase - ((double)local.x * direction.x
              + (double)local.y * direction.y + (double)local.z * direction.z) * packed.waves_per_unit;
        }
        assert(math::abs(math::sin(phases[0] * 2 * math::PI) - math::sin(phases[1] * 2 * math::PI)) < 0.00001);
        assert(math::abs(math::cos(phases[0] * 2 * math::PI) - math::cos(phases[1] * 2 * math::PI)) < 0.00001);
    }
    Plane plane = { .normal = { 0.6f, 0.8f, 0 }, .d = -30000 };
    foreach (origin : origins) {
        Plane relative = maths::rebase_plane(plane, origin);
        double expected = (double)plane.normal.x * anchor.x + (double)plane.normal.y * anchor.y + plane.d;
        Vec3 local = anchor - origin;
        double actual = (double)relative.normal.x * local.x + (double)relative.normal.y * local.y + relative.d;
        assert(math::abs(expected - actual) < 0.0001);
    }
}

fn void test_relative_light_position_matches_relative_geometry() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    Node* node = scene.add_light(light::point({ 1, 1, 1 }, 1, 10))!!;
    node.local.position = { 50002, 2, 50000 };
    scene.update_world();
    Frustum frustum;
    LightCounts counts;
    AtmosphereSelection atmosphere;
    @pool() {
        LightExtraction lights = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: camera::ALL_LAYERS,
            capacity: 1,
            counts: &counts,
            atmosphere: &atmosphere,
            altitude: 0,
            origin: ORIGIN,
        );
        assert(lights.lights.len == 1 && lights.lights[0].position_range == (Vec4){ 82, 2, 80, 10 });
    };
}

fn Vec4[2] origin_shifted_clips(float normal_bias_texels) @local {
    Vec3[2] origins = { ORIGIN, ORIGIN + (Vec3){ 256, 0, -256 } };
    Vec4[2] clips;
    foreach (index, origin : origins) {
        Mat4 world = matrix::IDENTITY4.translate((Vec3){ 50000, 3, 50000 } - origin);
        CameraMatrices camera = camera::derive_matrices(camera::perspective_deg(60, 1, 30), world, { 512, 512 });
        ShadowCascade cascade = render::fit_directional_cascade(
            view: &camera,
            near_depth: 1,
            far_depth: 20,
            light_direction: (Vec3){ -1, -2, -1 }.normalize(),
            casters: {},
            resolution: 1024,
            normal_bias_texels: normal_bias_texels,
            origin: origin,
        );
        Vec3 point = (Vec3){ 50000, 0, 49990 } - origin;
        clips[index] = cascade.camera.view_proj.apply({ point.x, point.y, point.z, 1 });
    }
    return clips;
}

fn void test_shadow_texel_lattice_stays_fixed_across_origin_changes() @test {
    Vec4[2] clips = origin_shifted_clips(0);
    assert(math::abs(clips[0].x - clips[1].x) < 0.000001f);
    assert(math::abs(clips[0].y - clips[1].y) < 0.000001f);

    // The offset's wider fit rounds this 340 m relative point to about 1.5e-6 in float clip space.
    clips = origin_shifted_clips(light::DEFAULT_DIRECTIONAL_NORMAL_BIAS_TEXELS);
    assert(math::abs(clips[0].x - clips[1].x) < NDC_TOLERANCE);
    assert(math::abs(clips[0].y - clips[1].y) < NDC_TOLERANCE);
}

const Vec3 SHIFT @local = { 16384, 0, 16384 };

struct ShiftFixture @local {
    Renderer* renderer;
    Scene[2]  scenes;
    ViewId[2] views;
}

fn Mat4 relative_world(Mat4 world, Vec3 origin) @local {
    return maths::rebase(world, origin);
}

fn void create_shift_fixture(ShiftFixture* fixture) @local {
    fixture.renderer = alloc::new(mem, Renderer);
    fixture.renderer.allocator = mem;
    fixture.renderer.views = pool::create_pool{ViewRecord, ViewId}(mem, 4);
    fixture.renderer.instances = render::create_instance_table(mem, 4);
    fixture.renderer.scene_trace.baseline = alloc::new_array(mem, TraceInstance, 2);
    foreach (index, &scene : fixture.scenes) {
        *scene = scene::create_scene(mem, { .max_nodes = 8 });
        fixture.views[index] = fixture.renderer.views.add({ .live = true })!!;
        ViewHistory* history = &fixture.renderer.views.get(fixture.views[index]).history;
        history.models = alloc::new_array(mem, Mat4, scene.nodes.len);
        history.owners = alloc::new_array(mem, Entity, scene.nodes.len);
        history.seen = alloc::new_array(mem, ulong, scene.nodes.len);
        history.poses = alloc::new_array(mem, PoseRecord, scene.nodes.len);
        history.scene = scene.identity;
        history.valid = true;
        history.serial = 1;
        history.origin = ORIGIN;
    }
}

fn void destroy_shift_fixture(ShiftFixture* fixture) @local {
    foreach (index, &scene : fixture.scenes) {
        render::free_view_history(mem, &fixture.renderer.views.get(fixture.views[index]).history);
        scene::destroy_scene(scene);
    }
    alloc::free(mem, fixture.renderer.scene_trace.baseline.ptr);
    render::destroy_instance_table(&fixture.renderer.instances);
    pool::destroy_pool{ViewRecord, ViewId}(&fixture.renderer.views);
    alloc::free(mem, fixture.renderer);
}

fn void record_drawn(ShiftFixture* fixture, usz index, Node* node) @local {
    ViewHistory* history = &fixture.renderer.views.get(fixture.views[index]).history;
    history.models[node.id.index] = node.world;
    history.owners[node.id.index] = node.id;
    history.seen[node.id.index] = history.serial;
}

fn void test_shift_helpers_preserve_relative_history() @test {
    ViewHistory history = { .origin = ORIGIN };
    render::shift_view_history_origin(&history, SHIFT);
    assert(history.origin == ORIGIN - SHIFT);

    LodHistoryEntry entry;
    entry.committed = { .scene = 3, .origin = ORIGIN };
    entry.pending = { .scene = 3, .origin = ORIGIN + (Vec3){ 256, 0, 0 } };
    render::shift_lod_history(&entry, 3, SHIFT);
    assert(entry.committed.origin == ORIGIN - SHIFT && entry.pending.origin == ORIGIN + (Vec3){ 256, 0, 0 } - SHIFT);
    render::shift_lod_history(&entry, 4, SHIFT);
    assert(entry.committed.origin == ORIGIN - SHIFT);

    Mat4 world = matrix::IDENTITY4.translate({ 50003, 2, 50001.5f });
    GpuInstances slot = { .world = world, .origin = ORIGIN };
    render::shift_instance_slot(&slot, SHIFT);
    assert(slot.origin == ORIGIN - SHIFT);
    assert(relative_world(slot.world, slot.origin) == relative_world(world, ORIGIN));

    TraceInstance[2] baseline = {
        { .world = world, .local = matrix::IDENTITY4 },
        { .world = world.translate({ 8, 0, 0 }), .local = matrix::IDENTITY4 },
    };
    Mat4[2] before = { baseline[0].world, baseline[1].world };
    SceneTrace trace = { .origin = ORIGIN, .baseline = baseline[..], .baseline_count = 2 };
    render::shift_trace_baseline(&trace, SHIFT);
    assert(trace.origin == ORIGIN - SHIFT);
    foreach (index, record : baseline) {
        assert(relative_world(record.world, trace.origin) == relative_world(before[index], ORIGIN));
        assert(record.local.m03 == 0 && record.local.m00 == 1);
    }

    ProbeVolumeRes mirror = { .fill = { .traced_origin = ORIGIN }, .frame_fill = { .traced_origin = ORIGIN } };
    render::shift_probe_fill(&mirror, SHIFT);
    assert(mirror.fill.traced_origin == ORIGIN - SHIFT && mirror.frame_fill.traced_origin == ORIGIN - SHIFT);
}

fn void test_shift_plane_keeps_clipped_points() @test {
    Plane plane = { .normal = { 0.6f, 0, 0.8f }, .d = -60000 };
    Vec3[3] points = { { 50000, 3, 49984 }, { 50010, 0, 50000 }, { 49980, 5, 50013 } };
    Plane shifted = render::shift_plane(plane, SHIFT);
    foreach (point : points) {
        double before = (double)plane.normal.x * point.x + (double)plane.normal.y * point.y
          + (double)plane.normal.z * point.z + plane.d;
        Vec3 moved = point - SHIFT;
        double after = (double)shifted.normal.x * moved.x + (double)shifted.normal.y * moved.y
          + (double)shifted.normal.z * moved.z + shifted.d;
        assert(math::abs(before - after) < 0.01);
    }
    Plane none = render::shift_plane({}, SHIFT);
    assert(none.normal == (Vec3){} && none.d == 0);
}

fn void test_sway_phase_is_continuous_across_a_shift() @test {
    InstanceSway sway = { .direction = { 3, 0, 4 }, .amplitude = 0.25f, .frequency = 0.75f, .wavelength = 32 };
    double[<3>] total = { 256, 0, 512 };
    double[<3>] moved = { 16384, 0, 16384 };
    Vec3 origin = ORIGIN;
    SwayGpu before = render::pack_sway(sway, 1000.25, origin, total);
    SwayGpu after = render::pack_sway(sway, 1000.25, origin - SHIFT, total + moved);
    assert(before.phase == after.phase);
    assert(before.direction_amplitude == after.direction_amplitude);
    SwayGpu unshifted = render::pack_sway(sway, 1000.25, origin - SHIFT, total);
    assert(unshifted.phase != after.phase);
}

fn void test_nested_node_motion_after_a_shift_is_zero() @test {
    ShiftFixture fixture;
    create_shift_fixture(&fixture);
    defer destroy_shift_fixture(&fixture);
    Scene* scene = &fixture.scenes[0];
    Node* parent = scene.add_node()!!;
    Node* nested = scene.add_node(parent)!!;
    parent.local.position = { 50001.5f, 3, 50003.25f };
    nested.local.position = { 0.1f, 1, 0.3f };
    scene.update_world();
    record_drawn(&fixture, 0, nested);

    scene.shift_origin(SHIFT);
    scene.update_world();
    assert(nested.world != fixture.renderer.views.get(fixture.views[0]).history.models[nested.id.index]);
    fixture.renderer.shift_origin(scene, SHIFT);

    ViewHistory* history = &fixture.renderer.views.get(fixture.views[0]).history;
    assert(history.has_previous(scene, nested));
    assert(history.previous_model(scene, nested) == nested.world);
    assert(history.origin == ORIGIN - SHIFT);
}

fn void test_world_draw_child_has_zero_motion_after_a_shift() @test {
    ShiftFixture fixture;
    create_shift_fixture(&fixture);
    defer destroy_shift_fixture(&fixture);
    Scene* scene = &fixture.scenes[0];
    Node* owner = scene.add_node()!!;
    Node* draw = scene.add_node(owner)!!;
    owner.local.position = { 50001, 0, 50001 };
    draw.transform_space = TransformSpace.WORLD;
    scene.update_world();
    record_drawn(&fixture, 0, draw);

    scene.shift_origin(SHIFT);
    draw.local.position = {};
    scene.update_world();
    fixture.renderer.shift_origin(scene, SHIFT);

    ViewHistory* history = &fixture.renderer.views.get(fixture.views[0]).history;
    assert(history.previous_model(scene, draw) == draw.world && draw.world.m03 == 0 && draw.world.m00 == 1);
}

fn void test_shift_leaves_other_scenes_untouched() @test {
    ShiftFixture fixture;
    create_shift_fixture(&fixture);
    defer destroy_shift_fixture(&fixture);
    Renderer* renderer = fixture.renderer;
    Node*[2] nodes;
    foreach (index, &scene : fixture.scenes) {
        nodes[index] = scene.add_node()!!;
        nodes[index].local.position = { 50001, 0, 50001 };
        scene.update_world();
        record_drawn(&fixture, (usz)index, nodes[index]);
        renderer.views.get(fixture.views[index]).desc.clip_plane = { .normal = { 1, 0, 0 }, .d = -50000 };
        uint slot = renderer.instances.acquire({ .scene = scene.identity, .node = nodes[index].id }, 1)!!;
        renderer.instances.slots[slot].world = nodes[index].world;
        renderer.instances.slots[slot].origin = ORIGIN;
        renderer.probe_volumes[index] = {
            .scene = scene.identity,
            .entity = nodes[index].id,
            .fill = { .traced_origin = ORIGIN },
        };
    }
    renderer.scene_trace.scene = fixture.scenes[1].identity;
    renderer.scene_trace.origin = ORIGIN;
    renderer.scene_trace.baseline_count = 1;
    renderer.scene_trace.baseline[0].world = nodes[1].world;
    ViewRecord untouched_view = *renderer.views.get(fixture.views[1]);
    Mat4 untouched_model = untouched_view.history.models[nodes[1].id.index];
    GpuInstances untouched_slot = renderer.instances.slots[renderer.instances.lookup.get({
        .scene = fixture.scenes[1].identity, .node = nodes[1].id,
    })!!];

    fixture.scenes[0].shift_origin(SHIFT);
    fixture.scenes[0].update_world();
    renderer.shift_origin(&fixture.scenes[0], SHIFT);

    ViewRecord* other = renderer.views.get(fixture.views[1]);
    assert(other.history.origin == ORIGIN && other.history.models[nodes[1].id.index] == untouched_model);
    assert(other.desc.clip_plane.d == untouched_view.desc.clip_plane.d);
    assert(renderer.views.get(fixture.views[0]).history.origin == ORIGIN - SHIFT);
    assert(renderer.views.get(fixture.views[0]).desc.clip_plane.d != -50000);
    uint other_slot = renderer.instances.lookup.get({ .scene = fixture.scenes[1].identity, .node = nodes[1].id })!!;
    assert(renderer.instances.slots[other_slot].world == untouched_slot.world);
    assert(renderer.instances.slots[other_slot].origin == ORIGIN);
    uint own_slot = renderer.instances.lookup.get({ .scene = fixture.scenes[0].identity, .node = nodes[0].id })!!;
    assert(renderer.instances.slots[own_slot].origin == ORIGIN - SHIFT);
    assert(renderer.scene_trace.origin == ORIGIN && renderer.scene_trace.baseline[0].world == nodes[1].world);
    assert(renderer.probe_volumes[1].fill.traced_origin == ORIGIN);
    assert(renderer.probe_volumes[0].fill.traced_origin == ORIGIN - SHIFT);
}
