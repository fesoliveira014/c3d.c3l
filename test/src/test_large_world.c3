module c3d::test::large_world;

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

fn void test_shadow_texel_lattice_stays_fixed_across_origin_changes() @test {
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
            normal_bias: 0,
            origin: origin,
        );
        Vec3 point = (Vec3){ 50000, 0, 49990 } - origin;
        clips[index] = cascade.camera.view_proj.apply({ point.x, point.y, point.z, 1 });
    }
    assert(math::abs(clips[0].x - clips[1].x) < 0.000001f);
    assert(math::abs(clips[0].y - clips[1].y) < 0.000001f);
}
