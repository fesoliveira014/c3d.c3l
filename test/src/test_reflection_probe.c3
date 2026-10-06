module c3d::test::reflection_probe;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const float WEIGHT_TOLERANCE @local = 1e-6f;
const float DIRECTION_TOLERANCE @local = 1e-5f;
const float TURN_DEGREES @local = 30;
const uint AHEAD_PROBES @local = 17;
const float AHEAD_SPACING @local = 3;
const uint FACE_SIZE @local = 8;
const Vec3 CAPTURE_ORIGIN @local = { 3, -2, 5 };

fn ReflectionProbeGpu placed_record(ReflectionProbe* probe, Vec3 center, Quat rotation) @local {
    Transform placement = maths::TRANSFORM_IDENTITY;
    placement.position = center;
    placement.rotation = rotation;
    return render::reflection_probe_record(
        probe:         probe,
        world:         placement.to_mat4(),
        origin:        {},
        specular_cube: {},
        sheen_cube:    {},
    );
}

fn ReflectionProbeGpu box_record(Vec3 center, Vec3 half_extents, float blend_distance) @local {
    ReflectionProbe probe = light::reflection_probe(half_extents, {});
    probe.blend_distance = blend_distance;
    return placed_record(&probe, center, quaternion::IDENTITY);
}

fn bool near(float value, float expected, float tolerance) @local {
    return math::abs(value - expected) <= tolerance;
}

fn void assert_shares_sum_to_one(ReflectionSelection selection) @local {
    float sum = selection.first_weight + selection.second_weight + selection.global_weight;
    assert(near(sum, 1, WEIGHT_TOLERANCE));
}

fn bool kept_holds(ReflectionCandidate[] kept, Node* node) @local {
    foreach (candidate : kept) {
        if (c3d::same_id(candidate.entity, node.id)) return true;
    }
    return false;
}

fn usz gather(
    Scene* scene,
    AssetStore* assets,
    ViewCamera* view_camera,
    ReflectionCandidate[] kept,
    ReflectionCounts* counts,
) @local {
    *counts = {};
    return render::gather_reflection_probes(
        scene:       scene,
        assets:      assets,
        view_camera: view_camera,
        kept:        kept,
        counts:      counts,
    );
}

fn void test_reflection_probe_validity() @test {
    ReflectionProbe probe = light::reflection_probe({ 2, 1, 3 }, {});
    assert(light::reflection_probe_valid(&probe));
    assert(probe.projection == ReflectionProjection.BOX && probe.intensity == 1 && probe.priority == 0);

    probe.capture_offset = { 1.9f, -0.9f, 2.9f };
    assert(light::reflection_probe_valid(&probe));
    probe.capture_offset = { 2, 0, 0 };
    assert(!light::reflection_probe_valid(&probe));
    probe.capture_offset = { 0, -1.5f, 0 };
    assert(!light::reflection_probe_valid(&probe));
    probe.capture_offset = { 0, 0, float::nan };
    assert(!light::reflection_probe_valid(&probe));

    probe.capture_offset = {};
    ReflectionProbe[6] broken = { probe, probe, probe, probe, probe, probe };
    broken[0].half_extents.x = 0;
    broken[1].half_extents.y = float::inf;
    broken[2].blend_distance = -0.1f;
    broken[3].blend_distance = float::nan;
    broken[4].intensity = -1;
    broken[5].intensity = float::inf;
    foreach (&copy : broken) assert(!light::reflection_probe_valid(copy));
}

fn void test_weights_at_faces_blends_and_overlaps_sum_to_one() @test {
    ReflectionProbeSetGpu set = {
        .count  = 2,
        .probes = {
            [0] = box_record({ 0, 0, 0 }, { 2, 2, 2 }, 0.5f),
            [1] = box_record({ 3.6f, 0, 0 }, { 2, 2, 2 }, 0.5f),
        },
    };
    ReflectionSelection centre = render::reflection_probe_select(&set, { 0, 0, 0 });
    assert(centre.count == 1 && centre.first == 0 && centre.first_weight == 1 && centre.global_weight == 0);

    ReflectionSelection blend_depth = render::reflection_probe_select(&set, { 0, 1.5f, 0 });
    assert(blend_depth.count == 1 && blend_depth.first_weight == 1);

    ReflectionSelection fading = render::reflection_probe_select(&set, { 0, 1.75f, 0 });
    assert(fading.count == 1 && near(fading.first_weight, 0.5f, WEIGHT_TOLERANCE));
    assert(near(fading.global_weight, 0.5f, WEIGHT_TOLERANCE));
    assert_shares_sum_to_one(fading);

    ReflectionSelection face = render::reflection_probe_select(&set, { 0, 2, 0 });
    assert(face.count == 0 && face.global_weight == 1);

    ReflectionSelection overlap = render::reflection_probe_select(&set, { 1.8f, 0, 0 });
    assert(overlap.count == 2 && overlap.first == 0 && overlap.second == 1);
    assert(near(overlap.first_weight, 0.4f, WEIGHT_TOLERANCE));
    assert(near(overlap.second_weight, 0.24f, WEIGHT_TOLERANCE));
    assert(near(overlap.global_weight, 0.36f, WEIGHT_TOLERANCE));
    assert_shares_sum_to_one(overlap);

    ReflectionSelection outside = render::reflection_probe_select(&set, { 0, 3, 0 });
    assert(outside.count == 0 && outside.first_weight == 0 && outside.global_weight == 1);
}

fn void test_zero_blend_reproduces_the_hard_rule() @test {
    ReflectionProbeSetGpu set = {
        .count  = 2,
        .probes = {
            [0] = box_record({ 0, 0, 0 }, { 2, 2, 2 }, 0),
            [1] = box_record({ 3.6f, 0, 0 }, { 2, 2, 2 }, 0),
        },
    };
    Vec3[4] points = { { 1.8f, 0, 0 }, { 2, 0, 0 }, { 2.01f, 0, 0 }, { 5.6f, 0, 0 } };
    uint[4] owners = { 0, 0, 1, 1 };
    foreach (index, point : points) {
        ReflectionSelection selection = render::reflection_probe_select(&set, point);
        assert(selection.count == 1 && selection.first == owners[index]);
        assert(selection.first_weight == 1 && selection.second_weight == 0 && selection.global_weight == 0);
    }
    assert(render::reflection_probe_select(&set, { 5.61f, 0, 0 }).count == 0);
}

fn void test_blend_is_clamped_and_scale_is_ignored() @test {
    ReflectionProbe probe = light::reflection_probe({ 4, 1, 4 }, {});
    probe.blend_distance = 5;
    Transform placement = maths::TRANSFORM_IDENTITY;
    placement.position = { 10, 2, -3 };
    placement.scale = { 2, 3, 4 };
    ReflectionProbeGpu record = render::reflection_probe_record(
        probe:         &probe,
        world:         placement.to_mat4(),
        origin:        { 8, 0, 0 },
        specular_cube: {},
        sheen_cube:    {},
    );
    assert(record.capture_blend.w == 1);
    assert(record.center_intensity.xyz == (Vec3){ 2, 2, -3 });
    assert(record.axis_x_extent == (Vec4f){ 1, 0, 0, 4 } && record.axis_y_extent == (Vec4f){ 0, 1, 0, 1 });
}

fn void test_sort_prefers_priority_then_volume_then_entity() @test {
    ReflectionProbe[5] probes;
    probes[2].priority = 1;
    float[5] volumes = { 8, 1, 64, 1, 1 };
    uint[5] indices = { 1, 2, 3, 5, 4 };
    ReflectionCandidate[5] candidates;
    foreach (index, &candidate : candidates) {
        *candidate = {
            .entity     = { .index = indices[index], .generation = 1 },
            .probe      = &probes[index],
            .box_volume = volumes[index],
        };
    }
    render::sort_reflection_candidates(&candidates);
    uint[5] expected = { 3, 2, 4, 5, 1 };
    foreach (index, candidate : candidates) assert(candidate.entity.index == expected[index]);
}

fn void test_view_keeps_the_sixteen_nearest_probes() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 32 });
    defer scene::destroy_scene(&scene);
    EnvironmentId environment = assets.add_environment(light::solid_environment({ 1, 0, 0 }))!!;
    Node*[AHEAD_PROBES] ahead;
    foreach (index, &slot : ahead) {
        Node* node = scene.add_node(name: "ahead")!!;
        node.local.position = { 0, 0, -AHEAD_SPACING * (float)(index + 1) };
        scene.add(node, light::reflection_probe({ 1, 1, 1 }, environment));
        *slot = node;
    }
    scene.update_world();
    ViewCamera view_camera = { .camera = camera::perspective(1, 0.1f), .world = matrix::IDENTITY4 };
    ReflectionCandidate[shader::REFLECTION_PROBE_CAPACITY] kept;
    ReflectionCounts counts;

    usz count = gather(
        scene:       &scene,
        assets:      &assets,
        view_camera: &view_camera,
        kept:        &kept,
        counts:      &counts,
    );
    assert(count == 16 && counts.dropped == 1 && counts.dangling == 0);
    assert(!kept_holds(kept[:count], ahead[16]));

    Node* behind = scene.add_node(name: "behind")!!;
    behind.local.position = { 0, 0, 4 };
    scene.add(behind, light::reflection_probe({ 1, 1, 1 }, environment));
    scene.update_world();
    count = gather(
        scene:       &scene,
        assets:      &assets,
        view_camera: &view_camera,
        kept:        &kept,
        counts:      &counts,
    );
    assert(count == 16 && counts.dropped == 2);
    assert(kept_holds(kept[:count], behind) && !kept_holds(kept[:count], ahead[15]));

    Node* tie = scene.add_node(name: "tie")!!;
    tie.local.position = { 0, 0, AHEAD_SPACING * 15 };
    scene.add(tie, light::reflection_probe({ 1, 1, 1 }, environment));
    scene.update_world();
    assert(tie.id.index > ahead[14].id.index);
    count = gather(
        scene:       &scene,
        assets:      &assets,
        view_camera: &view_camera,
        kept:        &kept,
        counts:      &counts,
    );
    assert(count == 16 && counts.dropped == 3);
    assert(kept_holds(kept[:count], ahead[14]) && !kept_holds(kept[:count], tie));

    scene.get(ahead[5], ReflectionProbe).priority = 2;
    scene.get(ahead[9], ReflectionProbe).priority = 1;
    scene.get(ahead[0], ReflectionProbe).half_extents = { 2, 2, 2 };
    count = gather(
        scene:       &scene,
        assets:      &assets,
        view_camera: &view_camera,
        kept:        &kept,
        counts:      &counts,
    );
    render::sort_reflection_candidates(kept[:count]);
    assert(c3d::same_id(kept[0].entity, ahead[5].id) && c3d::same_id(kept[1].entity, ahead[9].id));
    assert(c3d::same_id(kept[count - 1].entity, ahead[0].id));
    for (usz index = 3; index < count - 1; index++) assert(kept[index - 1].entity.index < kept[index].entity.index);
}

fn void test_gather_skips_hidden_masked_excluded_and_empty_probes() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    EnvironmentId live = assets.add_environment(light::solid_environment({ 1, 0, 0 }))!!;
    EnvironmentId removed = assets.add_environment(light::solid_environment({ 0, 1, 0 }))!!;
    Node* seen = scene.add_node(name: "seen")!!;
    Node* hidden_parent = scene.add_node(name: "hidden_parent")!!;
    Node* hidden = scene.add_node(hidden_parent, "hidden")!!;
    Node* masked = scene.add_node(name: "masked")!!;
    Node* excluded = scene.add_node(name: "excluded")!!;
    Node* empty = scene.add_node(name: "empty")!!;
    Node* dangling = scene.add_node(name: "dangling")!!;
    hidden_parent.visible = false;
    masked.layers = 2;
    Node*[4] live_nodes = { seen, hidden, masked, excluded };
    foreach (node : live_nodes) scene.add(node, light::reflection_probe({ 1, 1, 1 }, live));
    scene.add(empty, light::reflection_probe({ 1, 1, 1 }, {}));
    scene.add(dangling, light::reflection_probe({ 1, 1, 1 }, removed));
    assets.remove_environment(removed);
    scene.update_world();

    ViewCamera view_camera = {
        .camera         = camera::perspective(1, 0.1f),
        .world          = matrix::IDENTITY4,
        .excluded_probe = excluded.id,
    };
    view_camera.camera.layers = 1;
    ReflectionCandidate[shader::REFLECTION_PROBE_CAPACITY] kept;
    ReflectionCounts counts;
    usz count = gather(
        scene:       &scene,
        assets:      &assets,
        view_camera: &view_camera,
        kept:        &kept,
        counts:      &counts,
    );
    assert(count == 1 && c3d::same_id(kept[0].entity, seen.id));
    assert(counts.dangling == 1 && counts.dropped == 0);
}

fn void test_box_projection_twins() @test {
    ReflectionProbeGpu probe = box_record({ 0, 0, 0 }, { 2, 1, 3 }, 0);
    Vec3[3] directions = {
        { 1, 0, 0 },
        ((Vec3){ 0.3f, -0.5f, 0.8f }).normalize(),
        ((Vec3){ -0.6f, 0.6f, -0.5f }).normalize(),
    };
    foreach (direction : directions) {
        Vec3 aimed = render::reflection_box_direction(&probe, {}, direction).normalize();
        assert(aimed.distance(direction) <= DIRECTION_TOLERANCE);
    }

    Vec3 off_centre = render::reflection_box_direction(&probe, { 1, 0.5f, 0 }, { 0, 0, 1 }).normalize();
    assert(off_centre.distance(((Vec3){ 1, 0.5f, 3 }).normalize()) <= DIRECTION_TOLERANCE);

    Vec3 outward = render::reflection_box_direction(&probe, { 2, 0, 0 }, { 1, 0, 0 });
    Vec3 inward = render::reflection_box_direction(&probe, { 2, 0, 0 }, { -1, 0, 0 });
    assert(math::is_finite(outward.length()) && outward.length() > 0);
    assert(outward.normalize().distance({ 1, 0, 0 }) <= DIRECTION_TOLERANCE);
    assert(inward.normalize().distance({ -1, 0, 0 }) <= DIRECTION_TOLERANCE);

    ReflectionProbe offset = light::reflection_probe({ 2, 1, 3 }, {});
    offset.capture_offset = { 0.5f, -0.25f, 1 };
    Quat turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(TURN_DEGREES));
    ReflectionProbeGpu upright = placed_record(&offset, { 1, 2, 3 }, quaternion::IDENTITY);
    ReflectionProbeGpu turned = placed_record(&offset, { 1, 2, 3 }, turn);
    Vec3 local_position = { -1.2f, 0.3f, 2 };
    Vec3 direction = ((Vec3){ 0.4f, 0.2f, -0.9f }).normalize();
    Vec3 expected = render::reflection_box_direction(&upright, local_position, direction);
    Vec3 rotated = render::reflection_box_direction(&turned, local_position, turn.rotate_vec3(direction));
    assert(rotated.distance(turn.rotate_vec3(expected)) <= DIRECTION_TOLERANCE);

    offset.projection = ReflectionProjection.INFINITE;
    ReflectionProbeGpu infinite = placed_record(&offset, { 1, 2, 3 }, turn);
    assert(render::reflection_box_direction(&infinite, local_position, direction) == direction);
}

fn void test_capture_faces_match_the_cube_convention() @test {
    ulong[FACE_SIZE * FACE_SIZE] rendered;
    foreach (index, &texel : rendered) *texel = (ulong)index;
    ulong[FACE_SIZE * FACE_SIZE] assembled;
    render::mirror_capture_face(
        face:     ((char*)&assembled)[:assembled.len * ulong::size],
        rendered: ((char*)&rendered)[:rendered.len * ulong::size],
        size:     FACE_SIZE,
    );
    Camera face_camera = render::reflection_capture_camera(render::REFLECTION_CAPTURE_DESC_DEFAULT);
    Vec2 viewport = { FACE_SIZE, FACE_SIZE };
    foreach (face : CubeFace::values) {
        Mat4 world = render::reflection_capture_face_world(face, CAPTURE_ORIGIN);
        CameraMatrices matrices = camera::derive_matrices(face_camera, world, viewport);
        for (uint y = 0; y < FACE_SIZE; y++) {
            for (uint x = 0; x < FACE_SIZE; x++) {
                ulong source = assembled[y * FACE_SIZE + x];
                Vec2 pixel = { (float)(source % FACE_SIZE) + 0.5f, (float)(source / FACE_SIZE) + 0.5f };
                Vec3 seen = camera::screen_to_ray(&matrices, pixel, viewport).direction;
                Vec2 uv = { ((float)x + 0.5f) / FACE_SIZE, ((float)y + 0.5f) / FACE_SIZE };
                Vec3 expected = render::preview_face_direction(face, uv).normalize();
                assert(seen.distance(expected) <= DIRECTION_TOLERANCE);
            }
        }
    }
}

fn void test_capture_desc_validation() @test {
    assert(render::reflection_capture_desc_valid(render::REFLECTION_CAPTURE_DESC_DEFAULT));
    ReflectionCaptureDesc desc = render::REFLECTION_CAPTURE_DESC_DEFAULT;
    desc.size = 32;
    desc.far = 50;
    assert(render::reflection_capture_desc_valid(desc));
    desc.size = render::MAX_REFLECTION_CAPTURE_SIZE;
    assert(render::reflection_capture_desc_valid(desc));

    uint[4] sizes = { 0, 16, 48, render::MAX_REFLECTION_CAPTURE_SIZE * 2 };
    foreach (size : sizes) {
        ReflectionCaptureDesc sized = render::REFLECTION_CAPTURE_DESC_DEFAULT;
        sized.size = size;
        assert(!render::reflection_capture_desc_valid(sized));
    }
    float[3] nears = { 0, -1, float::nan };
    foreach (value : nears) {
        ReflectionCaptureDesc clipped = render::REFLECTION_CAPTURE_DESC_DEFAULT;
        clipped.near = value;
        assert(!render::reflection_capture_desc_valid(clipped));
    }
    float[3] fars = { render::DEFAULT_REFLECTION_CAPTURE_NEAR, 0.01f, float::inf };
    foreach (value : fars) {
        ReflectionCaptureDesc clipped = render::REFLECTION_CAPTURE_DESC_DEFAULT;
        clipped.far = value;
        assert(!render::reflection_capture_desc_valid(clipped));
    }
}
