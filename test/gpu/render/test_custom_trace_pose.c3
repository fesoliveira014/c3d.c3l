module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::io::file;
import std::math;
import std::math::quaternion;

const char[*] DISPLACE_VERTEX_SOURCE @private = $embed("displace.vert.glsl");
const char[*] DISPLACE_POSE_SOURCE @private = $embed("displace_pose.comp.glsl");
const char[*] DISPLACE_INCLUDE_SOURCE @private = $embed("displace.glsl");
const String DISPLACE_INCLUDE_NAME @private = "test/displace.glsl";
const float DISPLACE_AMPLITUDE @private = 0.3f;       // a tenth of the camera distance, far above the depth tolerance
const float DISPLACE_FREQUENCY @private = 3;          // about one wave across the two-unit surface
const float DISPLACE_RATE @private = 4;               // radians per second
const float STILL_RATE @private = 0;                  // a displacement that does not read the time
const float DISPLACE_INSTANCE_PHASE @private = 0.9f;  // radians per unit of the instance's world x
const float DISPLACE_BOUND @private = 0.35f;          // authored half height that holds the displacement
const float EDITED_AMPLITUDE @private = 0.2f;
const uint SURFACE_SEGMENTS @private = 16;
const float SLAB_DEPTH @private = 0.4f;               // as tall as the plane, so the height weight spans its face
const uint SLAB_SEGMENTS @private = 8;
const float LOD_PART_RAISE @private = 0.3f;           // moves the part in its object, which the height weight reads
const float SIDE_INSTANCE_X @private = 6;             // well outside the half width of 1.7 at the surface
const float SWAY_AMPLITUDE @private = 0.4f;
const float MASK_BEND_AMPLITUDE @private = 0.2f;
const float LOW_ALPHA @private = 0.1f;                // below the fixture mask's cutoff of 0.5
const double[3] POSE_TIMES @private = { 0.0, 0.4, 0.8 };
const double SWAY_FIRST_TIME @private = 0.3;
const double SWAY_SECOND_TIME @private = 0.6;
const uint TWO_INSTANCES @private = 2;
const bool[2] INSTANCED_MODES @private = { false, true };
const Vec3 FACING_AXIS @private = { 1, 0, 0 };
const Quat IDENTITY_ROTATION @private = maths::TRANSFORM_IDENTITY.rotation;

struct TraceRig @private {
    Fixture      fixture;
    PosedHarness harness;
    TraceKind    kind;
}

fn void? create_trace_rig(TraceRig* rig, bool ray_queries, uint max_posed_trace_instances = 0) @private {
    create_fixture(
        allocator:                 mem,
        fixture:                   &rig.fixture,
        ray_queries:               ray_queries,
        max_posed_trace_instances: max_posed_trace_instances,
    )!;
    defer catch destroy_fixture(&rig.fixture);
    posed_create_harness(&rig.fixture, &rig.harness)!;
    rig.kind = ray_queries ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
}

fn void destroy_trace_rig(TraceRig* rig) @private {
    posed_destroy_harness(&rig.fixture, &rig.harness);
    destroy_fixture(&rig.fixture);
}

fn void? render_rig(TraceRig* rig, double time) @private {
    return posed_render(
        fixture: &rig.fixture,
        harness: &rig.harness,
        kind:    rig.kind,
        time:    time,
    );
}

fn char[]? compile_displace_stage(
    Fixture* fixture,
    String source,
    ShaderStage stage,
    String[] defines,
) @private {
    asset::ShaderInclude[1] includes = {{ .name = DISPLACE_INCLUDE_NAME, .text = (String)DISPLACE_INCLUDE_SOURCE[..] }};
    return compile::compile_glsl(
        allocator: fixture.allocator,
        source:    source,
        stage:     stage,
        defines:   defines,
        includes:  includes[..],
    );
}

fn char[]? compile_displace_vertex(Fixture* fixture, bool depth, bool instanced) @private {
    String[2] defines;
    usz count;
    if (depth) defines[count++] = "DEPTH_ONLY";
    if (instanced) defines[count++] = "INSTANCED";
    return compile_displace_stage(
        fixture: fixture,
        source:  (String)DISPLACE_VERTEX_SOURCE[..],
        stage:   ShaderStage.VERTEX,
        defines: defines[:count],
    );
}

fn char[]? compile_displace_pose(Fixture* fixture, bool instanced) @private {
    String[1] defines = { "INSTANCED" };
    return compile_displace_stage(
        fixture: fixture,
        source:  (String)DISPLACE_POSE_SOURCE[..],
        stage:   ShaderStage.COMPUTE,
        defines: defines[:instanced ? 1 : 0],
    );
}

// posed leaves the trace-pose forms out; broken_fragment makes the backend reject the stage.
fn asset::ShaderDesc? displace_shader_desc(
    Fixture* fixture,
    bool reads_time,
    bool instanced,
    bool posed,
    bool broken_fragment,
) @private {
    String fragment = (String)file::load(tmem, repository_path(PULSE_FRAGMENT))!;
    asset::ShaderDesc desc = {
        .fragment         = broken_fragment
          ? published_broken_fragment(fixture)!
          : compile::compile_glsl(fixture.allocator, fragment, ShaderStage.FRAGMENT)!,
        .param_block_size = PulseBlock::size,
        .trace_pose       = { .reads_time = reads_time },
    };
    defer catch asset::free_shader_desc(fixture.allocator, &desc);
    desc.vertex.shaded = compile_displace_vertex(fixture, false, false)!;
    desc.vertex.depth = compile_displace_vertex(fixture, true, false)!;
    if (posed) desc.trace_pose.single = compile_displace_pose(fixture, false)!;
    if (instanced) {
        desc.vertex.instanced_shaded = compile_displace_vertex(fixture, false, true)!;
        desc.vertex.instanced_depth = compile_displace_vertex(fixture, true, true)!;
        if (posed) desc.trace_pose.instanced = compile_displace_pose(fixture, true)!;
    }
    return desc;
}

fn ShaderId? add_displace_shader(
    Fixture* fixture,
    bool reads_time,
    bool instanced = false,
    bool posed = true,
) @private {
    asset::ShaderDesc desc = displace_shader_desc(
        fixture:         fixture,
        reads_time:      reads_time,
        instanced:       instanced,
        posed:           posed,
        broken_fragment: false,
    )!;
    defer asset::free_shader_desc(fixture.allocator, &desc);
    return fixture.assets.add_shader(&desc);
}

fn MaterialId? add_displace_material(Fixture* fixture, ShaderId shader, float rate) @private {
    PulseBlock block = {
        .color  = { 1, 1, 1, 1 },
        .motion = { DISPLACE_AMPLITUDE, DISPLACE_FREQUENCY, rate, DISPLACE_INSTANCE_PHASE },
    };
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    return fixture.assets.add_material(material::custom(shader, material::@as_bytes(block), common: common));
}

// The plane's up axis faces the camera, so the displacement moves the surface along the view.
fn Quat facing_camera() @private => quaternion::from_axis_angle{float}(FACING_AXIS, math::deg_to_rad(90.0f));

fn GeometryId? add_displaced_surface(Fixture* fixture) @private {
    GeometryId surface;
    @pool() {
        Geometry plane = geometry::plane(
            allocator:  tmem,
            width:      2,
            depth:      2,
            segments_x: SURFACE_SEGMENTS,
            segments_z: SURFACE_SEGMENTS,
        );
        plane.bounds = { .min = { -1, -DISPLACE_BOUND, -1 }, .max = { 1, DISPLACE_BOUND, 1 } };
        surface = fixture.assets.add_geometry(&plane)!;
    };
    return surface;
}

fn GeometryId? add_tall_slab(Fixture* fixture) @private {
    GeometryId slab;
    @pool() {
        Geometry shape = geometry::box(
            allocator: tmem,
            width:     2,
            height:    2,
            depth:     SLAB_DEPTH,
            segments:  SLAB_SEGMENTS,
        );
        slab = fixture.assets.add_geometry(&shape)!;
    };
    return slab;
}

fn GeometryId? add_half_transparent_surface(Fixture* fixture) @private {
    GeometryId surface;
    @pool() {
        Geometry plane = geometry::plane(
            allocator:  tmem,
            width:      2,
            depth:      2,
            segments_x: SURFACE_SEGMENTS,
            segments_z: SURFACE_SEGMENTS,
        );
        plane.colors = alloc::new_array(tmem, Vec4, plane.positions.len);
        foreach (index, position : plane.positions) plane.colors[index] = { 1, 1, 1, position.x < 0 ? LOW_ALPHA : 1 };
        surface = fixture.assets.add_geometry(&plane)!;
    };
    return surface;
}

fn Node*? add_displaced_mesh(TraceRig* rig, MaterialId material) @private {
    GeometryId surface = add_displaced_surface(&rig.fixture)!;
    Node* node = rig.harness.scene.add_mesh(surface, material, name: "displaced")!;
    node.local.rotation = facing_camera();
    rig.harness.scene.update_world();
    return node;
}

// Instances at the origin and SIDE_INSTANCE_X; only the first is in view of the default camera.
fn Node*? add_side_by_side_batch(
    TraceRig* rig,
    GeometryId surface,
    MaterialId material,
    Quat rotation,
    uint count = TWO_INSTANCES,
) @private {
    Transform[TWO_INSTANCES] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    foreach (&transform : transforms) transform.rotation = rotation;
    transforms[1].position = { SIDE_INSTANCE_X, 0, 0 };
    Node* batch = rig.harness.scene.add_instanced_mesh(
        geometry:   surface,
        material:   material,
        capacity:   TWO_INSTANCES,
        transforms: transforms[:count],
        name:       "side_by_side",
    )!;
    rig.harness.scene.update_world();
    return batch;
}

fn Node*? add_facing_batch(TraceRig* rig, GeometryId surface, MaterialId material) @private {
    return add_side_by_side_batch(
        rig:      rig,
        surface:  surface,
        material: material,
        rotation: facing_camera(),
    );
}

fn Node*? add_upright_batch(TraceRig* rig, GeometryId surface, MaterialId material) @private {
    return add_side_by_side_batch(
        rig:      rig,
        surface:  surface,
        material: material,
        rotation: IDENTITY_ROTATION,
    );
}

fn void look_at_instance(TraceRig* rig, float x) @private {
    rig.harness.camera.local.position = { x, CAMERA_POSITION.y, CAMERA_POSITION.z };
    rig.harness.scene.update_world();
}

fn InstanceSway swaying_toward_the_camera(float amplitude, SwayWeight weight = SwayWeight.HEIGHT) @private {
    return {
        .direction = { 0, 0, 1 },
        .amplitude = amplitude,
        .frequency = 1,
        .lean      = 0.5f,
        .variation = 0.3f,
        .weight    = weight,
    };
}

fn void report_rest_agreement(ZString name, PosedAgreement* agreement) @private {
    io::eprintfn("%s: %d covered, %d mismatched, worst %f", name, agreement.covered, agreement.mismatched, agreement.worst);
}

fn void report_pose_counts(Renderer* renderer, ZString name) @private {
    Stats* stats = &renderer.stats;
    io::eprintfn(
        "%s: %d traced, %d posed, %d poses, %d refits, %d builds, %d updates, %d deform overflow, %d at rest",
        name,
        stats.trace_instances,
        stats.trace_posed_instances,
        stats.trace_poses,
        stats.trace_refits,
        stats.blas_builds,
        stats.blas_updates,
        stats.trace_deform_overflow,
        stats.trace_sway_at_rest,
    );
}

fn void test_custom_pose_traces_a_mesh_at_its_displaced_surface() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);
        print_adapter(&rig.fixture);
        ShaderId shader = add_displace_shader(&rig.fixture, true)!!;
        add_displaced_mesh(&rig, add_displace_material(&rig.fixture, shader, DISPLACE_RATE)!!)!!;
        Renderer* renderer = &rig.fixture.renderer;

        foreach (frame, time : POSE_TIMES) {
            render_rig(&rig, time)!!;
            posed_assert_agreement(rig.harness.results, "displaced mesh", flat_faces: false);
            report_pose_counts(renderer, "displaced mesh");
            assert(renderer.stats.trace_posed_instances == 1 && renderer.stats.trace_poses == 1);
            assert(renderer.stats.trace_deform_overflow == 0 && renderer.stats.trace_skipped == 0);
            assert(renderer.stats.trace_refits == (ray_queries ? 0 : 1));
            assert(renderer.stats.blas_builds == (ray_queries && frame == 0 ? 1 : 0));
            assert(renderer.stats.blas_updates == (ray_queries && frame > 0 ? 1 : 0));
        }
        check_validation(renderer);
    }
}

fn void test_custom_pose_without_time_poses_again_only_when_its_inputs_change() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);
        ShaderId shader = add_displace_shader(&rig.fixture, false)!!;
        MaterialId material = add_displace_material(&rig.fixture, shader, STILL_RATE)!!;
        add_displaced_mesh(&rig, material)!!;
        Renderer* renderer = &rig.fixture.renderer;

        render_rig(&rig, POSE_TIMES[0])!!;
        report_pose_counts(renderer, "no time, first frame");
        assert(renderer.stats.trace_poses == 1 && renderer.stats.blas_builds == (ray_queries ? 1 : 0));
        ulong revision = renderer.scene_trace.revision;

        render_rig(&rig, POSE_TIMES[1])!!;
        posed_assert_agreement(rig.harness.results, "no time, later frame", flat_faces: false);
        report_pose_counts(renderer, "no time, later frame");
        assert(renderer.stats.trace_poses == 0 && renderer.stats.trace_refits == 0);
        assert(renderer.stats.blas_builds == 0 && renderer.stats.blas_updates == 0);
        assert(renderer.scene_trace.revision == revision);

        PulseBlock edited = {
            .color  = { 1, 1, 1, 1 },
            .motion = { EDITED_AMPLITUDE, DISPLACE_FREQUENCY, STILL_RATE, DISPLACE_INSTANCE_PHASE },
        };
        rig.fixture.assets.@set_custom_params(material, edited)!!;
        render_rig(&rig, POSE_TIMES[1])!!;
        posed_assert_agreement(rig.harness.results, "no time, edited", flat_faces: false);
        report_pose_counts(renderer, "no time, edited");
        assert(renderer.stats.trace_poses == 1);
        assert(renderer.stats.blas_builds == (ray_queries ? 1 : 0) && renderer.stats.blas_updates == 0);
        check_validation(renderer);
    }
}

fn void test_custom_pose_poses_every_instance_including_one_off_camera() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);
        ShaderId shader = add_displace_shader(&rig.fixture, false, instanced: true)!!;
        MaterialId material = add_displace_material(&rig.fixture, shader, STILL_RATE)!!;
        add_facing_batch(&rig, add_displaced_surface(&rig.fixture)!!, material)!!;
        Renderer* renderer = &rig.fixture.renderer;

        render_rig(&rig, POSE_TIMES[0])!!;
        posed_assert_agreement(rig.harness.results, "first instance", flat_faces: false);
        report_pose_counts(renderer, "instanced, first instance in view");
        assert(renderer.stats.trace_posed_instances == 2 && renderer.stats.trace_poses == 2);
        assert(renderer.stats.trace_deform_overflow == 0 && renderer.stats.blas_builds == (ray_queries ? 2 : 0));

        look_at_instance(&rig, SIDE_INSTANCE_X);
        render_rig(&rig, POSE_TIMES[0])!!;
        posed_assert_agreement(rig.harness.results, "second instance", flat_faces: false);
        report_pose_counts(renderer, "instanced, second instance in view");
        assert(renderer.stats.trace_posed_instances == 2 && renderer.stats.trace_poses == 0);
        check_validation(renderer);
    }
}

fn void test_swaying_instances_trace_at_their_swayed_pose_including_one_off_camera() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);
        Node* batch_node = add_upright_batch(&rig, add_tall_slab(&rig.fixture)!!, rig.fixture.plain)!!;
        InstancedMesh* batch = rig.harness.scene.get(batch_node, InstancedMesh);
        batch.sway = swaying_toward_the_camera(SWAY_AMPLITUDE);
        Renderer* renderer = &rig.fixture.renderer;

        render_rig(&rig, SWAY_FIRST_TIME)!!;
        PosedAgreement rest = posed_agreement(rig.harness.results);
        report_rest_agreement("swaying batch at rest", &rest);
        assert(rest.mismatched > POSED_EDGE_BUDGET || rest.worst > POSED_DEPTH_TOLERANCE);
        assert(renderer.stats.trace_sway_at_rest == 1 && renderer.stats.trace_posed_instances == 0);

        batch.trace_sway = true;
        render_rig(&rig, SWAY_FIRST_TIME)!!;
        posed_assert_agreement(rig.harness.results, "swayed first instance", flat_faces: false);
        report_pose_counts(renderer, "swaying, first instance in view");
        assert(renderer.stats.trace_posed_instances == 2 && renderer.stats.trace_poses == 2);
        assert(renderer.stats.trace_sway_at_rest == 0 && renderer.stats.blas_builds == (ray_queries ? 2 : 0));

        look_at_instance(&rig, SIDE_INSTANCE_X);
        render_rig(&rig, SWAY_SECOND_TIME)!!;
        posed_assert_agreement(rig.harness.results, "swayed second instance", flat_faces: false);
        report_pose_counts(renderer, "swaying, second instance in view");
        assert(renderer.stats.trace_poses == 2 && renderer.stats.blas_updates == (ray_queries ? 2 : 0));
        check_validation(renderer);
    }
}

fn void test_swaying_lod_groups_trace_at_their_swayed_pose() @test {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (instanced : INSTANCED_MODES) {
            TraceRig rig;
            create_trace_rig(&rig, ray_queries)!!;
            defer destroy_trace_rig(&rig);
            Transform placed = maths::TRANSFORM_IDENTITY;
            placed.position = { 0, LOD_PART_RAISE, 0 };
            LodPart[1] parts = {{
                .geometry = add_tall_slab(&rig.fixture)!!,
                .material = rig.fixture.plain,
                .local    = placed.to_mat4(),
            }};
            LodLevel[1] levels = {{ .first_part = 0, .part_count = 1 }};
            LodDesc desc = { .levels = levels[..], .parts = parts[..] };
            Scene* scene = &rig.harness.scene;
            Node* group;
            if (instanced) {
                Transform[TWO_INSTANCES] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
                transforms[1].position = { SIDE_INSTANCE_X, 0, 0 };
                group = scene.add_instanced_lod_group(
                    assets:     &rig.fixture.assets,
                    desc:       desc,
                    capacity:   TWO_INSTANCES,
                    transforms: transforms[..],
                )!!;
            } else {
                group = scene.add_lod_group(&rig.fixture.assets, desc)!!;
            }
            scene.update_world();
            LodEffects effects = scene.get(group, LodGroup).state.effects;
            effects.sway = swaying_toward_the_camera(SWAY_AMPLITUDE);
            scene.set_lod_effects(group, effects);
            Renderer* renderer = &rig.fixture.renderer;

            render_rig(&rig, SWAY_FIRST_TIME)!!;
            PosedAgreement rest = posed_agreement(rig.harness.results);
            report_rest_agreement("swaying group at rest", &rest);
            assert(rest.mismatched > POSED_EDGE_BUDGET || rest.worst > POSED_DEPTH_TOLERANCE);
            assert(renderer.stats.trace_sway_at_rest == 1 && renderer.stats.trace_posed_instances == 0);

            effects.trace_sway = true;
            scene.set_lod_effects(group, effects);
            render_rig(&rig, SWAY_FIRST_TIME)!!;
            posed_assert_agreement(rig.harness.results, "swayed group", flat_faces: false);
            report_pose_counts(renderer, "swaying group");
            assert(renderer.stats.trace_posed_instances == (instanced ? 2 : 1));
            assert(renderer.stats.trace_sway_at_rest == 0);
            check_validation(renderer);
        }
    }
}

fn void test_masked_layer_with_a_vertex_alpha_bend_alpha_tests_like_raster() @test {
    foreach (ray_queries : TRACE_KINDS) {
        TraceRig rig;
        create_trace_rig(&rig, ray_queries)!!;
        defer destroy_trace_rig(&rig);
        Node* batch_node = add_side_by_side_batch(
            rig:      &rig,
            surface:  add_half_transparent_surface(&rig.fixture)!!,
            material: rig.fixture.masked,
            rotation: facing_camera(),
            count:    1,
        )!!;
        InstancedMesh* batch = rig.harness.scene.get(batch_node, InstancedMesh);

        batch.sway = swaying_toward_the_camera(0, SwayWeight.VERTEX_ALPHA);
        render_rig(&rig, SWAY_FIRST_TIME)!!;
        posed_assert_agreement(rig.harness.results, "vertex alpha bend at rest", flat_faces: false);

        batch.sway = swaying_toward_the_camera(MASK_BEND_AMPLITUDE, SwayWeight.VERTEX_ALPHA);
        batch.trace_sway = true;
        render_rig(&rig, SWAY_FIRST_TIME)!!;
        posed_assert_agreement(rig.harness.results, "vertex alpha bend swayed", flat_faces: false);
        assert(rig.fixture.renderer.stats.trace_posed_instances == 1);
        check_validation(&rig.fixture.renderer);
    }
}

fn void test_published_stage_the_store_no_longer_matches_leaves_its_row_out_and_counts_it() @test {
    TraceRig rig;
    create_trace_rig(&rig, false)!!;
    defer destroy_trace_rig(&rig);
    ShaderId shader = add_displace_shader(&rig.fixture, false, posed: false)!!;
    add_displaced_mesh(&rig, add_displace_material(&rig.fixture, shader, STILL_RATE)!!)!!;
    Renderer* renderer = &rig.fixture.renderer;

    render_rig(&rig, POSE_TIMES[0])!!;
    assert(renderer.stats.trace_instances == 0 && renderer.stats.trace_skipped == 0);

    // The newest revision poses the trace geometry, but the backend rejects it, so the published one still has no form.
    asset::ShaderDesc replacement = displace_shader_desc(
        fixture:         &rig.fixture,
        reads_time:      false,
        instanced:       false,
        posed:           true,
        broken_fragment: true,
    )!!;
    defer asset::free_shader_desc(rig.fixture.allocator, &replacement);
    rig.fixture.assets.replace_shader(shader, &replacement)!!;
    render_rig(&rig, POSE_TIMES[0])!!;
    report_pose_counts(renderer, "rejected replacement");
    assert(renderer.stats.shader_rejections == 1);
    assert(renderer.stats.trace_instances == 0 && renderer.stats.trace_skipped == 1);
    check_validation(renderer);
}

fn void test_posed_slots_run_out_per_kind() @test {
    TraceRig rig;
    create_trace_rig(&rig, false, max_posed_trace_instances: 1)!!;
    defer destroy_trace_rig(&rig);
    ShaderId shader = add_displace_shader(&rig.fixture, false, instanced: true)!!;
    MaterialId material = add_displace_material(&rig.fixture, shader, STILL_RATE)!!;
    Node* custom = add_facing_batch(&rig, add_displaced_surface(&rig.fixture)!!, material)!!;
    Renderer* renderer = &rig.fixture.renderer;

    posed_trace_frame(&rig.fixture, &rig.harness.scene)!!;
    report_pose_counts(renderer, "custom rows past one slot");
    assert(renderer.stats.trace_instances == 1 && renderer.stats.trace_posed_instances == 1);
    assert(renderer.stats.trace_deform_overflow == 1 && renderer.stats.trace_posed_overflow == 0);

    custom.visible = false;
    Node* swaying = add_upright_batch(&rig, rig.fixture.box, rig.fixture.plain)!!;
    InstancedMesh* batch = rig.harness.scene.get(swaying, InstancedMesh);
    batch.sway = swaying_toward_the_camera(SWAY_AMPLITUDE);
    batch.trace_sway = true;
    posed_trace_frame(&rig.fixture, &rig.harness.scene)!!;
    report_pose_counts(renderer, "sway rows past one slot");
    assert(renderer.stats.trace_instances == 2 && renderer.stats.trace_posed_instances == 1);
    assert(renderer.stats.trace_sway_at_rest == 1 && renderer.stats.trace_deform_overflow == 0);
    check_validation(renderer);
}
